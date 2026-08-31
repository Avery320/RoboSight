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
    static let tfTopic = "tf"
    static let jointStatesTopic = "joint_states"
    static let joyTopic = "joy"
    static let joyFrameId = "joy"
    static let worldFrameId = "world"
    static let arucoMarkerFrameId = "aruco_marker_link"
    static let deviceLinkFrameId = "device_link"
    static let cameraLinkFrameId = "camera_link"
    static let cameraOpticalFrameId = "robosight_camera_optical_frame"
    static let compressedImageFormat = "rgb8; jpeg compressed rgb8"

    private let distro: ROS2Distro
    private let connectionTimeout: TimeInterval

    private var context: ROS2Context?
    private var node: ROS2Node?
    private var statusPublisher: ROS2Publisher<StringMsg>?
    private var cameraImagePublisher: ROS2Publisher<CompressedImage>?
    private var cameraInfoPublisher: ROS2Publisher<CameraInfo>?
    private var tfPublisher: ROS2Publisher<TFMessage>?
    private var joyPublisher: ROS2Publisher<Joy>?
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
        let tfPublisher: ROS2Publisher<TFMessage>
        let joyPublisher: ROS2Publisher<Joy>
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
            tfPublisher = try await node.createPublisher(
                TFMessage.self,
                topic: Self.tfTopic
            )
            // 保持 ROS joy_node 使用的可靠 QoS 預設，讓 teleop_twist_joy 可直接訂閱。
            joyPublisher = try await node.createPublisher(
                Joy.self,
                topic: Self.joyTopic
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
        self.tfPublisher = tfPublisher
        self.joyPublisher = joyPublisher

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
        tfPublisher = nil
        joyPublisher = nil
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

        // 影像與 camera_info 使用同一個 timestamp / frame_id，RViz 才能在時間軸上對齊。
        let stamp = Self.rosTime(from: frame.timestamp)
        let header = Header(
            stamp: stamp,
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

    /// 發布 `aruco_marker_link -> device_link -> camera_link`。
    func publishDeviceTF(_ frame: DeviceTFFrame) async throws {
        guard context?.isConnected == true, let tfPublisher else {
            throw RobotTransportError.notConnected
        }

        let stamp = Self.rosTime(from: frame.timestamp)
        try tfPublisher.publish(Self.deviceTFMessage(stamp: stamp, frame: frame))
    }

    /// 將 RoboSight 的平面控制狀態轉成標準 ROS `sensor_msgs/msg/Joy`。
    ///
    /// 現階段沿用既有 AMR joystick profile：
    /// - `axes[0]`：轉向，左轉為正
    /// - `axes[3]`：前後，前進為正
    /// - `buttons[0]`：deadman / enable
    func publishJoy(_ state: JoyControlState) async throws {
        guard context?.isConnected == true, let joyPublisher else {
            throw RobotTransportError.notConnected
        }

        let message = Joy(
            header: Header(
                stamp: Self.rosTime(from: Date().timeIntervalSince1970),
                frameId: Self.joyFrameId
            ),
            axes: [state.turn, 0, 0, state.forward],
            buttons: [state.isEnabled ? 1 : 0]
        )
        try joyPublisher.publish(message)
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

    /// 產生目前唯一的 `/tf` 鏈：
    /// `world -> aruco_marker_link -> device_link -> camera_link -> robosight_camera_optical_frame`。
    private static func deviceTFMessage(stamp: Time, frame: DeviceTFFrame) -> TFMessage {
        let identity = Transform(
            translation: Vector3(),
            rotation: Quaternion(x: 0, y: 0, z: 0, w: 1)
        )
        let markerInWorld = Transform(
            translation: Vector3(x: 1, y: 0, z: 0),
            rotation: Quaternion(x: 0, y: 0, z: 0, w: 1)
        )
        let deviceInMarker = Transform(
            translation: Vector3(
                x: frame.translation.x,
                y: frame.translation.y,
                z: frame.translation.z
            ),
            rotation: Quaternion(
                x: frame.orientation.x,
                y: frame.orientation.y,
                z: frame.orientation.z,
                w: frame.orientation.w
            )
        )

        // camera_link 與 device_link 暫時共用原點與姿態；
        // optical frame 只負責符合 ROS 相機座標：+X 右、+Y 下、+Z 後鏡頭拍攝方向。
        let cameraOpticalInCamera = Transform(
            translation: Vector3(),
            rotation: Quaternion(x: 1, y: 0, z: 0, w: 0)
        )

        return TFMessage(
            transforms: [
                TransformStamped(
                    header: Header(stamp: stamp, frameId: Self.worldFrameId),
                    childFrameId: Self.arucoMarkerFrameId,
                    transform: markerInWorld
                ),
                TransformStamped(
                    header: Header(stamp: stamp, frameId: Self.arucoMarkerFrameId),
                    childFrameId: Self.deviceLinkFrameId,
                    transform: deviceInMarker
                ),
                TransformStamped(
                    header: Header(stamp: stamp, frameId: Self.deviceLinkFrameId),
                    childFrameId: Self.cameraLinkFrameId,
                    transform: identity
                ),
                TransformStamped(
                    header: Header(stamp: stamp, frameId: Self.cameraLinkFrameId),
                    childFrameId: Self.cameraOpticalFrameId,
                    transform: cameraOpticalInCamera
                )
            ]
        )
    }

}
