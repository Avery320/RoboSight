import Foundation

/// ROS 2 傳輸層對使用者呈現的連線狀態。
enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed(String)

    /// Settings UI 使用的簡短狀態文字。
    var title: String {
        switch self {
        case .disconnected:
            "Disconnected"
        case .connecting:
            "Connecting"
        case .connected:
            "Connected"
        case .disconnecting:
            "Disconnecting"
        case .failed:
            "Failed"
        }
    }

    /// 僅在 failed 狀態顯示的錯誤細節。
    var detail: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }

    /// connect / disconnect 操作進行中時為 true。
    var isBusy: Bool {
        self == .connecting || self == .disconnecting
    }

    /// 傳輸層已建立且初始 status 發送成功後為 true。
    var isConnected: Bool {
        self == .connected
    }
}
