import Foundation

/// Robot 頁籤與 Settings robot picker 共用的狀態。
@MainActor
final class RobotViewModel: ObservableObject {
    @Published private(set) var availableRobots: [RobotLibraryItem] = []
    @Published private(set) var selectedRobot: RobotLibraryItem?
    @Published private(set) var selectionState: RobotSelectionState = .idle
    @Published private(set) var isFetchingLibrary: Bool = false
    @Published private(set) var libraryFetchError: String? = nil
    @Published private(set) var isLoadingRobot: Bool = false
    @Published private(set) var robotLoadError: String? = nil
    @Published private(set) var runtime: RobotRuntime?
    @Published private(set) var jointPositions: [String: Double] = [:]

    private let libraryClient: RobotLibraryClient
    private var validationTask: Task<Void, Never>?
    private var loadingTask: Task<Void, Never>?

    init(libraryClient: RobotLibraryClient = RobotLibraryClient()) {
        self.libraryClient = libraryClient
    }

    deinit {
        validationTask?.cancel()
        loadingTask?.cancel()
    }

    /// 載入 GitHub robosim_library 的 URDF 清單。
    func refreshRobotListIfNeeded() async {
        guard availableRobots.isEmpty else { return }

        isFetchingLibrary = true
        libraryFetchError = nil
        do {
            let robots = try await libraryClient.fetchRobotList()
            availableRobots = robots
            isFetchingLibrary = false
        } catch {
            libraryFetchError = error.localizedDescription
            isFetchingLibrary = false
        }
    }

    /// Settings 選擇 robot 時只做合規檢查，不直接載入模型。
    func selectRobot(_ robot: RobotLibraryItem?) {
        validationTask?.cancel()
        loadingTask?.cancel()

        selectedRobot = robot
        selectionState = .idle
        isLoadingRobot = false
        robotLoadError = nil
        runtime = nil
        jointPositions = [:]

        guard let robot else { return }

        selectionState = .validating(robot.name)
        validationTask = Task { [weak self] in
            await self?.validateSelectedRobot(robot)
        }
    }

    /// 使用 Settings 目前選到的 robot 載入 runtime。
    func loadSelectedRobot() {
        guard let selectedRobot else {
            robotLoadError = "尚未選擇 robot model。"
            return
        }

        guard selectionState.isValid else {
            robotLoadError = "請先在 Settings 選擇合規 STL 模型。"
            return
        }

        loadingTask?.cancel()
        loadingTask = Task { [weak self] in
            await self?.loadRobot(selectedRobot)
        }
    }

    private func loadRobot(_ item: RobotLibraryItem) async {
        isLoadingRobot = true
        robotLoadError = nil
        runtime = nil

        do {
            // Robot tab 載入時才下載與解析模型，避免 Settings 一次載入所有 URDF/mesh。
            let cachedModel = try await libraryClient.prepareRobot(item)
            try Task.checkCancellation()

            let robot = try URDFParser().parse(url: cachedModel.urdfURL)
            try Task.checkCancellation()

            let resolver = AssetResolver(baseURL: cachedModel.urdfURL.deletingLastPathComponent())
            let meshLoader = MeshLoader()
            let robotRuntime = try RobotRuntime(
                robot: robot,
                assetResolver: resolver,
                meshLoader: meshLoader
            )
            // 先在 ViewModel 階段驗證 STL 可解析，避免 RealityKit 建 entity 時才失敗。
            try await preloadVisualMeshes(for: robot, runtime: robotRuntime)
            runtime = robotRuntime
            isLoadingRobot = false
        } catch is CancellationError {
            if selectedRobot == item {
                isLoadingRobot = false
            }
        } catch {
            robotLoadError = error.localizedDescription
            isLoadingRobot = false
        }
    }

    /// 在顯示前先解析所有 visual mesh，避免 RealityKit 畫面階段才暴露 STL 解析錯誤。
    private func preloadVisualMeshes(
        for robot: RobotModel,
        runtime: RobotRuntime
    ) async throws {
        for link in robot.links {
            for visual in link.visuals {
                try Task.checkCancellation()
                _ = try await runtime.meshLoader.loadMesh(
                    for: visual.meshRef,
                    resolver: runtime.assetResolver
                )
            }
        }
    }

    private func validateSelectedRobot(_ item: RobotLibraryItem) async {
        do {
            let validation = try await libraryClient.validateRobot(item)
            try Task.checkCancellation()

            guard selectedRobot == item else { return }
            selectionState = .valid(meshCount: validation.visualMeshCount)
        } catch is CancellationError {
            guard selectedRobot == item else { return }
            selectionState = .idle
        } catch {
            guard selectedRobot == item else { return }
            selectionState = .invalid(error.localizedDescription)
        }
    }

    var canLoadSelectedRobot: Bool {
        selectedRobot != nil && selectionState.isValid && !isLoadingRobot
    }

    /// 目前保留給後續 joint slider / ROS joint state 更新使用。
    func updateJointStates(_ positions: [String: Double]) {
        self.jointPositions = positions
    }
}

/// Settings 中 robot model 的單一選擇狀態。
enum RobotSelectionState: Equatable {
    case idle
    case validating(String)
    case valid(meshCount: Int)
    case invalid(String)

    var title: String {
        switch self {
        case .idle:
            "尚未驗證"
        case .validating(let name):
            "驗證 \(name)"
        case .valid:
            "模型合規"
        case .invalid:
            "模型不合規"
        }
    }

    var isLoading: Bool {
        if case .validating = self {
            return true
        }
        return false
    }

    var isValid: Bool {
        if case .valid = self {
            return true
        }
        return false
    }

    var message: String? {
        switch self {
        case .idle:
            nil
        case .validating:
            nil
        case .valid:
            "Validation passed."
        case .invalid:
            "Validation failed. Only .stl models are supported."
        }
    }
}
