import Combine
import Foundation

@MainActor
final class ConnectionViewModel: ObservableObject {
    @Published var routerHost: String
    @Published var routerPort: String
    @Published var domainId: String
    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var lastStatusMessage: String?

    private let transport: any RobotTransport
    private var heartbeatTask: Task<Void, Never>?

    init(
        routerHost: String = "127.0.0.1",
        routerPort: String = "7447",
        domainId: String = "0",
        transport: any RobotTransport = SwiftROS2ZenohTransport()
    ) {
        self.routerHost = routerHost
        self.routerPort = routerPort
        self.domainId = domainId
        self.transport = transport
    }

    var fullRouterAddress: String {
        let host = normalizedRouterHost
        let port = normalizedRouterPort
        guard !host.isEmpty, !port.isEmpty else { return "" }
        return "tcp/\(host):\(port)"
    }

    var statusTopic: String {
        "/robosight/status"
    }

    var canConnect: Bool {
        !state.isBusy && !state.isConnected
    }

    var canDisconnect: Bool {
        state.isConnected
    }

    func connect() async {
        guard canConnect else { return }

        state = .connecting
        lastStatusMessage = nil

        do {
            let routerAddress = try validatedRouterAddress()
            let domainId = try validatedDomainId()
            try await transport.connect(routerAddress: routerAddress, domainId: domainId)
            let message = makeStatusMessage()
            try await transport.publishStatus(message)
            state = .connected
            lastStatusMessage = "Publishing heartbeat on \(statusTopic)."
            startHeartbeat()
        } catch {
            stopHeartbeat()
            state = .failed(error.localizedDescription)
        }
    }

    func disconnect() async {
        guard canDisconnect else { return }

        state = .disconnecting
        stopHeartbeat()
        await transport.disconnect()
        state = .disconnected
        lastStatusMessage = "Disconnected."
    }

    private func startHeartbeat() {
        stopHeartbeat()
        heartbeatTask = Task { [weak self] in
            while !Task.isCancelled {
                do {
                    try await Task.sleep(for: .seconds(1))
                } catch {
                    break
                }

                guard !Task.isCancelled else { break }
                await self?.publishHeartbeat()
            }
        }
    }

    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    private func publishHeartbeat() async {
        do {
            let message = makeStatusMessage()
            try await transport.publishStatus(message)
            lastStatusMessage = "Sent: \(message)"
        } catch {
            stopHeartbeat()
            state = .failed(error.localizedDescription)
        }
    }

    private func makeStatusMessage() -> String {
        "robosight/status \(ISO8601DateFormatter().string(from: Date()))"
    }

    private var normalizedRouterHost: String {
        let trimmed = routerHost.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.hasPrefix("tcp://") {
            return String(trimmed.dropFirst("tcp://".count))
        }
        if trimmed.hasPrefix("tcp/") {
            return String(trimmed.dropFirst("tcp/".count))
        }
        return trimmed
    }

    private var normalizedRouterPort: String {
        routerPort.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func validatedRouterAddress() throws -> String {
        let host = normalizedRouterHost
        guard !host.isEmpty else {
            throw RobotTransportError.invalidRouterAddress
        }

        guard let port = Int(normalizedRouterPort), (1...65535).contains(port) else {
            throw RobotTransportError.invalidRouterPort
        }

        return "tcp/\(host):\(port)"
    }

    private func validatedDomainId() throws -> Int {
        guard let value = Int(domainId.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...232).contains(value) else {
            throw RobotTransportError.invalidDomainId
        }
        return value
    }
}
