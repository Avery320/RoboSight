import Foundation

protocol RobotTransport: Sendable {
    func connect(routerAddress: String, domainId: Int) async throws
    func disconnect() async
    func publishStatus(_ message: String) async throws
    func publishCameraFrame(_ frame: ARKitSensorFrame) async throws
}

enum RobotTransportError: LocalizedError {
    case invalidRouterAddress
    case invalidRouterPort
    case invalidDomainId
    case invalidCameraFrame
    case notConnected

    var errorDescription: String? {
        switch self {
        case .invalidRouterAddress:
            "Router address is empty."
        case .invalidRouterPort:
            "Router port must be a number from 1 to 65535."
        case .invalidDomainId:
            "Domain ID must be a number from 0 to 232."
        case .invalidCameraFrame:
            "Camera frame data is invalid."
        case .notConnected:
            "Transport is not connected."
        }
    }
}
