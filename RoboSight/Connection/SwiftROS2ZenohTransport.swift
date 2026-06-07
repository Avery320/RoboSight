import Foundation
import SwiftROS2

actor SwiftROS2ZenohTransport: RobotTransport {
    static let nodeName = "robosight_ios"
    static let nodeNamespace = "/"
    static let statusTopic = "robosight/status"

    private let distro: ROS2Distro
    private let connectionTimeout: TimeInterval

    private var context: ROS2Context?
    private var statusPublisher: ROS2Publisher<StringMsg>?

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
        } catch {
            await context.shutdown()
            throw error
        }

        self.context = context
        self.statusPublisher = statusPublisher
    }

    func disconnect() async {
        statusPublisher = nil

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
}
