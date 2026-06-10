import Combine
import Foundation

/// ROS 2 連線狀態的主要 UI 協調器。
///
/// 這個型別持有使用者輸入的 router 設定，並將實際網路通訊交給 `RobotTransport`。
/// 它只接收相機影像 API 影格，不直接接收 ARKit 影格。
@MainActor
final class ConnectionViewModel: ObservableObject {
    /// Settings 表單中顯示的 router host。
    @Published var routerHost: String

    /// Settings 表單中顯示的 router port。
    @Published var routerPort: String

    /// Settings 表單中顯示的 ROS domain ID。
    @Published var domainId: String

    @Published private(set) var state: ConnectionState = .disconnected
    @Published private(set) var lastStatusMessage: String?

    private let transport: any RobotTransport
    private var heartbeatTask: Task<Void, Never>?
    private var isPublishingCameraImage = false

    init(
        routerHost: String = "172.20.10.5",
        routerPort: String = "7447",
        domainId: String = "0",
        transport: any RobotTransport = SwiftROS2ZenohTransport()
    ) {
        self.routerHost = routerHost
        self.routerPort = routerPort
        self.domainId = domainId
        self.transport = transport
    }

    /// 由 host 與 port 欄位組合出的完整 Zenoh locator。
    var fullRouterAddress: String {
        let host = normalizedRouterHost
        let port = normalizedRouterPort
        guard !host.isEmpty, !port.isEmpty else { return "" }
        return "tcp/\(host):\(port)"
    }

    /// Settings UI 顯示的目前 status topic。
    var statusTopic: String {
        "/robosight/status"
    }

    /// 只有在沒有連線且沒有操作進行中時，才允許 connect。
    var canConnect: Bool {
        !state.isBusy && !state.isConnected
    }

    /// 只有在成功連線後，才允許 disconnect。
    var canDisconnect: Bool {
        state.isConnected
    }

    /// iOS Toggle 使用的 binding adapter。
    var isConnectionEnabled: Bool {
        switch state {
        case .connecting, .connected:
            true
        case .disconnected, .disconnecting, .failed:
            false
        }
    }

    /// 處理 Toggle 變更，並轉送到非同步 connect / disconnect 流程。
    func setConnectionEnabled(_ isEnabled: Bool) async {
        if isEnabled {
            await connect()
        } else {
            await disconnect()
        }
    }

    /// 驗證設定、開啟 ROS 2 傳輸層，並開始發送 heartbeat。
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

    /// 停止 heartbeat 並關閉 ROS 2 傳輸層。
    func disconnect() async {
        guard canDisconnect else { return }

        state = .disconnecting
        stopHeartbeat()
        isPublishingCameraImage = false
        await transport.disconnect()
        state = .disconnected
        lastStatusMessage = "Disconnected."
    }

    /// 傳輸層已連線時，發送一筆已處理的相機影像影格。
    func publishCameraImage(_ frame: CameraImageFrame) async {
        guard state.isConnected, !isPublishingCameraImage else { return }

        isPublishingCameraImage = true
        defer {
            isPublishingCameraImage = false
        }

        do {
            try await transport.publishCameraImage(frame)
        } catch {
            guard state.isConnected else { return }
            stopHeartbeat()
            state = .failed(error.localizedDescription)
        }
    }

    /// 啟動每秒一次的 heartbeat，讓 ROS 端可以確認 app 仍保持連線。
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

    /// 取消目前 heartbeat task。
    private func stopHeartbeat() {
        heartbeatTask?.cancel()
        heartbeatTask = nil
    }

    /// 透過目前啟用的傳輸層發送 status heartbeat。
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

    /// status payload 刻意保持簡單，用於早期 ROS 連線確認。
    private func makeStatusMessage() -> String {
        "robosight/status \(ISO8601DateFormatter().string(from: Date()))"
    }

    /// 接受有無 Zenoh `tcp/` prefix 的 host 輸入。
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

    /// 移除 port 文字欄位前後空白。
    private var normalizedRouterPort: String {
        routerPort.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 建立已驗證的 Zenoh locator 字串，供 swift-ros2 使用。
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

    /// 依 DDS / ROS 2 支援範圍驗證 ROS domain ID。
    private func validatedDomainId() throws -> Int {
        guard let value = Int(domainId.trimmingCharacters(in: .whitespacesAndNewlines)),
              (0...232).contains(value) else {
            throw RobotTransportError.invalidDomainId
        }
        return value
    }
}
