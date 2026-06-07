import Foundation
import SwiftROS2

actor SwiftROS2ZenohTransport: RobotTransport {
    static let nodeName = "robosight_ios"
    static let nodeNamespace = "/"
    static let statusTopic = "robosight/status"
    static let cameraImageTopic = "robosight/camera/image_raw/compressed"
    static let cameraInfoTopic = "robosight/camera/camera_info"
    static let cameraOpticalFrameId = "robosight_camera_optical_frame"
    static let compressedImageFormat = "rgb8; jpeg compressed rgb8"

    private let distro: ROS2Distro
    private let connectionTimeout: TimeInterval

    private var context: ROS2Context?
    private var statusPublisher: ROS2Publisher<StringMsg>?
    private var cameraImagePublisher: ROS2Publisher<CompressedImage>?
    private var cameraInfoPublisher: ROS2Publisher<CameraInfo>?

    init(
        distro: ROS2Distro = .jazzy,
        connectionTimeout: TimeInterval = 5.0
    ) {
        self.distro = distro
        self.connectionTimeout = connectionTimeout
    }

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
        self.statusPublisher = statusPublisher
        self.cameraImagePublisher = cameraImagePublisher
        self.cameraInfoPublisher = cameraInfoPublisher
    }

    func disconnect() async {
        statusPublisher = nil
        cameraImagePublisher = nil
        cameraInfoPublisher = nil

        if let context {
            await context.shutdown()
        }
        context = nil
    }

    func publishStatus(_ message: String) async throws {
        guard context?.isConnected == true, let statusPublisher else {
            throw RobotTransportError.notConnected
        }

        try statusPublisher.publish(StringMsg(data: message))
    }

    func publishCameraFrame(_ frame: ARKitSensorFrame) async throws {
        guard context?.isConnected == true, let cameraImagePublisher, let cameraInfoPublisher else {
            throw RobotTransportError.notConnected
        }

        let colorImage = frame.colorImage
        guard colorImage.width > 0,
              colorImage.height > 0,
              !colorImage.data.isEmpty,
              frame.cameraMatrix.count == 9 else {
            throw RobotTransportError.invalidCameraFrame
        }

        let header = Header(
            stamp: Self.rosTime(from: frame.unixTimestamp),
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

    private static func rosTime(from unixTimestamp: TimeInterval) -> Time {
        let seconds = floor(unixTimestamp)
        let clampedSeconds = min(max(seconds, Double(Int32.min)), Double(Int32.max))
        let fractionalSeconds = max(0, unixTimestamp - seconds)

        return Time(
            sec: Int32(clampedSeconds),
            nanosec: UInt32(fractionalSeconds * 1_000_000_000)
        )
    }

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
