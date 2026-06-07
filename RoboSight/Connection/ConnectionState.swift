import Foundation

enum ConnectionState: Equatable {
    case disconnected
    case connecting
    case connected
    case disconnecting
    case failed(String)

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

    var detail: String? {
        if case .failed(let message) = self {
            return message
        }
        return nil
    }

    var isBusy: Bool {
        self == .connecting || self == .disconnecting
    }

    var isConnected: Bool {
        self == .connected
    }
}
