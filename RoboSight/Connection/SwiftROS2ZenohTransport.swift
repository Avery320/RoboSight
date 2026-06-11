import Foundation
import SwiftROS2

/// 以 Zenoh 作為底層通訊的 swift-ros2 傳輸層實作。
///
/// 這個 actor 負責持有 ROS context、node 與發布器。
/// 輸入端接收 RoboSight 的感測資料模型，輸出端轉成 ROS 訊息型別。
actor SwiftROS2ZenohTransport: RobotTransport {
    /// ROS node 與 topic 常數集中管理，方便 RViz 與 CLI 驗證。
    static let nodeName = "robosight_ios"
    static let nodeNamespace = "/"
    static let statusTopic = "robosight/status"
    static let cameraImageTopic = "robosight/camera/image_raw/compressed"
    static let cameraInfoTopic = "robosight/camera/camera_info"
    static let jointStatesTopic = "joint_states"
    static let cameraOpticalFrameId = "robosight_camera_optical_frame"
    static let compressedImageFormat = "rgb8; jpeg compressed rgb8"

    private let distro: ROS2Distro
    private let connectionTimeout: TimeInterval

    private var context: ROS2Context?
    private var node: ROS2Node?
    private var statusPublisher: ROS2Publisher<StringMsg>?
    private var cameraImagePublisher: ROS2Publisher<CompressedImage>?
    private var cameraInfoPublisher: ROS2Publisher<CameraInfo>?
    private var jointStatesSubscription: ROS2Subscription<JointState>?
    private var jointStatesSubscriptionTask: Task<Void, Never>?
    private var isJointStatesSubscriptionEnabled = false
    private var jointStatesContinuation: AsyncStream<[String: Double]>.Continuation?
    nonisolated let jointStatesStream: AsyncStream<[String: Double]>

    init(
        distro: ROS2Distro = .jazzy,
        connectionTimeout: TimeInterval = 5.0
    ) {
        self.distro = distro
        self.connectionTimeout = connectionTimeout

        var escapeContinuation: AsyncStream<[String: Double]>.Continuation?
        self.jointStatesStream = AsyncStream { continuation in
            escapeContinuation = continuation
        }
        self.jointStatesContinuation = escapeContinuation
    }

    /// 使用傳入的 Zenoh locator 建立 ROS 2 context、node 與發布器。
    func connect(routerAddress: String, domainId: Int) async throws {
        let locator = routerAddress.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !locator.isEmpty else {
            throw RobotTransportError.invalidRouterAddress
        }
        guard (0...232).contains(domainId) else {
            throw RobotTransportError.invalidDomainId
        }

        await disconnect()

        let transport = TransportConfig.zenoh(
            locator: locator,
            domainId: domainId,
            wireMode: distro,
            connectionTimeout: connectionTimeout
        )
        let context = try await ROS2Context(transport: transport, distro: distro)

        let node: ROS2Node
        let statusPublisher: ROS2Publisher<StringMsg>
        let cameraImagePublisher: ROS2Publisher<CompressedImage>
        let cameraInfoPublisher: ROS2Publisher<CameraInfo>
        do {
            node = try await context.createNode(
                name: Self.nodeName,
                namespace: Self.nodeNamespace,
                options: ROS2NodeOptions(startParameterServices: false)
            )
            statusPublisher = try await node.createPublisher(
                StringMsg.self,
                topic: Self.statusTopic
            )
            cameraImagePublisher = try await node.createPublisher(
                CompressedImage.self,
                topic: Self.cameraImageTopic,
                qos: .sensorData
            )
            cameraInfoPublisher = try await node.createPublisher(
                CameraInfo.self,
                topic: Self.cameraInfoTopic,
                qos: .sensorData
            )
        } catch {
            await context.shutdown()
            throw error
        }

        self.context = context
        self.node = node
        self.statusPublisher = statusPublisher
        self.cameraImagePublisher = cameraImagePublisher
        self.cameraInfoPublisher = cameraInfoPublisher

        do {
            if isJointStatesSubscriptionEnabled {
                try await startJointStatesSubscriptionIfNeeded()
            }
        } catch {
            await disconnect()
            throw error
        }
    }

    private func yieldJointStates(_ positions: [String: Double]) {
        jointStatesContinuation?.yield(positions)
    }

    /// 依照使用者設定建立或釋放 `/joint_states` subscription。
    func setJointStatesSubscriptionEnabled(_ isEnabled: Bool) async throws {
        isJointStatesSubscriptionEnabled = isEnabled
        if isEnabled {
            try await startJointStatesSubscriptionIfNeeded()
        } else {
            stopJointStatesSubscription()
        }
    }

    private func startJointStatesSubscriptionIfNeeded() async throws {
        guard jointStatesSubscription == nil else { return }
        guard context?.isConnected == true, let node else { return }

        let subscription = try await node.createSubscription(
            JointState.self,
            topic: Self.jointStatesTopic,
            qos: .sensorData
        )
        jointStatesSubscription = subscription
        jointStatesSubscriptionTask = Task { [weak self, subscription] in
            for await message in subscription.messages {
                guard let self else { break }
                let jointPositions = Self.jointPositions(from: message)
                await self.yieldJointStates(jointPositions)
            }
        }
    }

    private func stopJointStatesSubscription() {
        jointStatesSubscriptionTask?.cancel()
        jointStatesSubscriptionTask = nil
        jointStatesSubscription = nil
    }

    private static func jointPositions(from message: JointState) -> [String: Double] {
        let count = min(message.name.count, message.position.count)
        var positions: [String: Double] = [:]
        positions.reserveCapacity(count)

        for index in 0..<count {
            positions[message.name[index]] = message.position[index]
        }

        return positions
    }

    /// 先釋放發布器，再關閉 ROS context。
    func disconnect() async {
        stopJointStatesSubscription()
        statusPublisher = nil
        cameraImagePublisher = nil
        cameraInfoPublisher = nil
        node = nil

        if let context {
            await context.shutdown()
        }
        context = nil
    }

    /// 發送簡單 status 字串，用於連線診斷。
    func publishStatus(_ message: String) async throws {
        guard context?.isConnected == true, let statusPublisher else {
            throw RobotTransportError.notConnected
        }

        try statusPublisher.publish(StringMsg(data: message))
    }

    /// 將相機影像 API 的輸出轉成 ROS `CompressedImage` 與 `CameraInfo`。
    func publishCameraImage(_ frame: CameraImageFrame) async throws {
        guard context?.isConnected == true, let cameraImagePublisher, let cameraInfoPublisher else {
            throw RobotTransportError.notConnected
        }

        let colorImage = frame.image
        guard colorImage.width > 0,
              colorImage.height > 0,
              !colorImage.data.isEmpty,
              frame.cameraMatrix.count == 9 else {
            throw RobotTransportError.invalidCameraFrame
        }

        // 影像與 camera_info 必須使用相同 timestamp / frame_id，RViz 才能正確對齊。
        let header = Header(
            stamp: Self.rosTime(from: frame.timestamp),
            frameId: Self.cameraOpticalFrameId
        )
        let cameraInfo = CameraInfo(
            header: header,
            height: UInt32(colorImage.height),
            width: UInt32(colorImage.width),
            distortionModel: "plumb_bob",
            d: [0, 0, 0, 0, 0],
            k: frame.cameraMatrix,
            r: [
                1, 0, 0,
                0, 1, 0,
                0, 0, 1
            ],
            p: Self.projectionMatrix(from: frame.cameraMatrix)
        )
        let image = CompressedImage(
            header: header,
            format: Self.compressedImageFormat,
            data: colorImage.data
        )

        try cameraInfoPublisher.publish(cameraInfo)
        try cameraImagePublisher.publish(image)
    }

    /// 將 Unix 秒數轉成 ROS builtin time。
    private static func rosTime(from unixTimestamp: TimeInterval) -> Time {
        let seconds = floor(unixTimestamp)
        let clampedSeconds = min(max(seconds, Double(Int32.min)), Double(Int32.max))
        let fractionalSeconds = max(0, unixTimestamp - seconds)

        return Time(
            sec: Int32(clampedSeconds),
            nanosec: UInt32(fractionalSeconds * 1_000_000_000)
        )
    }

    /// 將 3x3 相機內參矩陣展開成 ROS CameraInfo 使用的 3x4 projection matrix。
    private static func projectionMatrix(from cameraMatrix: [Double]) -> [Double] {
        guard cameraMatrix.count == 9 else {
            return Array(repeating: 0, count: 12)
        }

        return [
            cameraMatrix[0], cameraMatrix[1], cameraMatrix[2], 0,
            cameraMatrix[3], cameraMatrix[4], cameraMatrix[5], 0,
            cameraMatrix[6], cameraMatrix[7], cameraMatrix[8], 0
        ]
    }
}
