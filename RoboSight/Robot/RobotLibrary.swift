import Foundation

/// `robosim_library` 中可選擇的 URDF 模型。
///
/// `urdfPath` 使用 GitHub repository 內的相對路徑。
struct RobotLibraryItem: Identifiable, Equatable, Hashable {
    let id: String
    let name: String
    let urdfPath: String

    init(urdfPath: String) {
        self.id = urdfPath
        self.urdfPath = urdfPath
        self.name = URL(fileURLWithPath: urdfPath)
            .deletingPathExtension()
            .lastPathComponent
    }
}

/// 單一 URDF 模型的合規檢查結果。
struct RobotModelValidation: Equatable {
    let visualMeshCount: Int
}

/// 已下載到本機 cache 的合規機器人模型。
struct CachedRobotModel {
    let urdfURL: URL
}

/// 從 GitHub `Avery320/robosim_library` 取得 URDF 清單、驗證單一模型並下載必要資產。
///
/// 產品規格目前收斂為「只支援 visual mesh 全部為 STL 的 URDF」；
struct RobotLibraryClient {
    private let owner = "Avery320"
    private let repository = "robosim_library"
    private let branch = "main"
    private let urlSession: URLSession
    private let fileManager: FileManager

    init(
        urlSession: URLSession = .shared,
        fileManager: FileManager = .default
    ) {
        self.urlSession = urlSession
        self.fileManager = fileManager
    }

    /// 只取得 repository 中的 URDF 清單，不下載每一個模型內容。
    func fetchRobotList() async throws -> [RobotLibraryItem] {
        let tree = try await fetchRepositoryTree()
        return tree.tree
            .filter { node in
                node.type == "blob" && node.path.hasSuffix(".urdf")
            }
            .map { RobotLibraryItem(urdfPath: $0.path) }
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// 只驗證使用者選到的單一模型是否符合 RoboSight 目前的 STL-only 規格。
    func validateRobot(_ item: RobotLibraryItem) async throws -> RobotModelValidation {
        let repositoryTree = try await fetchRepositoryTree()
        let availableRepositoryPaths = repositoryPaths(from: repositoryTree)
        let urdfData = try await fetchFileData(path: item.urdfPath)
        let visualMeshPaths = try Self.validateSTLVisualMeshes(
            urdfData: urdfData,
            urdfPath: item.urdfPath,
            availableRepositoryPaths: availableRepositoryPaths
        )

        return RobotModelValidation(visualMeshCount: visualMeshPaths.count)
    }

    /// 下載已合規的單一模型 URDF 與其 visual STL mesh。
    ///
    /// 這裡會再次驗證，避免外部呼叫繞過 Settings 的合規檢查。
    func prepareRobot(_ item: RobotLibraryItem) async throws -> CachedRobotModel {
        try Task.checkCancellation()

        let repositoryTree = try await fetchRepositoryTree()
        let availableRepositoryPaths = repositoryPaths(from: repositoryTree)
        let urdfData = try await fetchFileData(path: item.urdfPath)
        let visualMeshPaths = try Self.validateSTLVisualMeshes(
            urdfData: urdfData,
            urdfPath: item.urdfPath,
            availableRepositoryPaths: availableRepositoryPaths
        )

        let robotRoot = cacheRoot
            .appendingPathComponent(item.name, isDirectory: true)
        let urdfURL = robotRoot.appendingPathComponent(item.urdfPath)

        try createDirectoryIfNeeded(urdfURL.deletingLastPathComponent())
        try urdfData.write(to: urdfURL, options: .atomic)

        for meshPath in visualMeshPaths {
            let destinationURL = robotRoot.appendingPathComponent(meshPath)
            try await downloadFileIfNeeded(path: meshPath, destinationURL: destinationURL)
        }

        return CachedRobotModel(urdfURL: urdfURL)
    }

    private var cacheRoot: URL {
        let baseURL = fileManager.urls(for: .cachesDirectory, in: .userDomainMask)[0]
        return baseURL.appendingPathComponent("RobotLibrary", isDirectory: true)
    }

    private func fetchRepositoryTree() async throws -> GitTreeResponse {
        try Task.checkCancellation()

        // 只讀 Git tree 取得檔案清單；模型內容等使用者選定後才下載。
        guard let url = URL(string: "https://api.github.com/repos/\(owner)/\(repository)/git/trees/\(branch)?recursive=1") else {
            throw RobotLibraryError.invalidRemoteURL
        }

        let (data, response) = try await urlSession.data(from: url)
        try Task.checkCancellation()
        try validateHTTPResponse(response)
        return try JSONDecoder().decode(GitTreeResponse.self, from: data)
    }

    private func fetchFileData(path: String) async throws -> Data {
        try Task.checkCancellation()

        guard let url = rawFileURL(path: path) else {
            throw RobotLibraryError.invalidRemoteURL
        }

        let (data, response) = try await urlSession.data(from: url)
        try Task.checkCancellation()
        try validateHTTPResponse(response)
        return data
    }

    private func downloadFileIfNeeded(path: String, destinationURL: URL) async throws {
        try Task.checkCancellation()

        if fileManager.fileExists(atPath: destinationURL.path) {
            return
        }

        try createDirectoryIfNeeded(destinationURL.deletingLastPathComponent())
        let data = try await fetchFileData(path: path)
        try data.write(to: destinationURL, options: .atomic)
    }

    private func rawFileURL(path: String) -> URL? {
        // GitHub raw URL 需要逐段編碼，避免資料夾或檔名中的特殊字元破壞路徑。
        let encodedPath = path
            .split(separator: "/")
            .map { segment in
                String(segment).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String(segment)
            }
            .joined(separator: "/")

        return URL(string: "https://raw.githubusercontent.com/\(owner)/\(repository)/\(branch)/\(encodedPath)")
    }

    private func repositoryPaths(from tree: GitTreeResponse) -> Set<String> {
        Set(
            tree.tree
                .filter { $0.type == "blob" }
                .map(\.path)
        )
    }

    private func validateHTTPResponse(_ response: URLResponse) throws {
        guard let httpResponse = response as? HTTPURLResponse,
              (200...299).contains(httpResponse.statusCode) else {
            throw RobotLibraryError.invalidHTTPResponse
        }
    }

    private func createDirectoryIfNeeded(_ url: URL) throws {
        if !fileManager.fileExists(atPath: url.path) {
            try fileManager.createDirectory(
                at: url,
                withIntermediateDirectories: true
            )
        }
    }

    private static func validateSTLVisualMeshes(
        urdfData: Data,
        urdfPath: String,
        availableRepositoryPaths: Set<String>
    ) throws -> Set<String> {
        guard let xmlString = String(data: urdfData, encoding: .utf8) else {
            throw RobotLibraryError.invalidURDFEncoding
        }

        let visualBlocks = xmlString.matches(pattern: #"<visual\b[\s\S]*?</visual>"#)
        // 目前 renderer 只吃 mesh；URDF primitive geometry 不進入 Robot tab，直接標示不合規。
        if visualBlocks.contains(where: { block in
            block.contains(pattern: #"<(box|cylinder|sphere)\b"#)
        }) {
            throw RobotLibraryError.unsupportedVisualGeometry
        }

        let parser = URDFParser()
        let robot = try parser.parse(data: urdfData)

        let urdfDirectory = normalizedDirectoryPath(for: urdfPath)
        var meshPaths = Set<String>()

        for link in robot.links {
            for visual in link.visuals {
                let filename = visual.meshRef.uri
                let repositoryPath = try normalizedRepositoryPath(
                    meshFilename: filename,
                    urdfDirectory: urdfDirectory
                )

                guard repositoryPath.lowercased().hasSuffix(".stl") else {
                    throw RobotLibraryError.unsupportedVisualMeshFormat(repositoryPath)
                }

                guard availableRepositoryPaths.contains(repositoryPath) else {
                    throw RobotLibraryError.missingVisualMesh(repositoryPath)
                }

                meshPaths.insert(repositoryPath)
            }
        }

        guard !meshPaths.isEmpty else {
            throw RobotLibraryError.noVisualMesh
        }

        return meshPaths
    }

    private static func normalizedRepositoryPath(
        meshFilename: String,
        urdfDirectory: String
    ) throws -> String {
        let lowercasedFilename = meshFilename.lowercased()
        // 為了讓 app 可以從 robosim_library cache 中穩定解析資產，目前只接受 repository 相對路徑。
        guard !meshFilename.hasPrefix("/") else {
            throw RobotLibraryError.unsupportedMeshURI(meshFilename)
        }

        guard !lowercasedFilename.hasPrefix("package://"),
              !lowercasedFilename.hasPrefix("file://"),
              !lowercasedFilename.hasPrefix("http://"),
              !lowercasedFilename.hasPrefix("https://") else {
            throw RobotLibraryError.unsupportedMeshURI(meshFilename)
        }

        let combined = "\(urdfDirectory)/\(meshFilename)"
        return normalizedComponents(combined).joined(separator: "/")
    }

    private static func normalizedDirectoryPath(for repositoryPath: String) -> String {
        var components = normalizedComponents(repositoryPath)
        _ = components.popLast()
        return components.joined(separator: "/")
    }

    private static func normalizedComponents(_ path: String) -> [String] {
        var components: [String] = []
        for component in path.split(separator: "/").map(String.init) {
            switch component {
            case "", ".":
                continue
            case "..":
                _ = components.popLast()
            default:
                components.append(component)
            }
        }
        return components
    }
}

private struct GitTreeResponse: Decodable {
    let tree: [GitTreeNode]
}

private struct GitTreeNode: Decodable {
    let path: String
    let type: String
}

private enum RobotLibraryError: LocalizedError {
    case invalidRemoteURL
    case invalidHTTPResponse
    case invalidURDFEncoding
    case noVisualMesh
    case unsupportedVisualGeometry
    case unsupportedMeshURI(String)
    case unsupportedVisualMeshFormat(String)
    case missingVisualMesh(String)

    var errorDescription: String? {
        switch self {
        case .invalidRemoteURL:
            "Robot library URL 無效。"
        case .invalidHTTPResponse:
            "無法從 GitHub 取得 robot library。"
        case .invalidURDFEncoding:
            "Robot URDF 不是有效的 UTF-8 文字。"
        case .noVisualMesh:
            "此 URDF 不合規：沒有可載入的 visual mesh。"
        case .unsupportedVisualGeometry:
            "此 URDF 不合規：visual geometry 只支援 STL mesh。"
        case .unsupportedMeshURI(let path):
            "此 URDF 不合規：目前只支援相對路徑 STL，不支援 \(path)。"
        case .unsupportedVisualMeshFormat(let path):
            "此 URDF 不合規：visual mesh 只支援 .stl，實際為 \(path)。"
        case .missingVisualMesh(let path):
            "此 URDF 不合規：找不到 visual STL 檔案 \(path)。"
        }
    }
}

private extension String {
    func contains(pattern: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return false
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.firstMatch(in: self, range: range) != nil
    }

    func matches(pattern: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else {
            return []
        }

        let range = NSRange(startIndex..<endIndex, in: self)
        return regex.matches(in: self, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: self) else {
                return nil
            }
            return String(self[matchRange])
        }
    }
}
