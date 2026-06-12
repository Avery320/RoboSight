import Foundation

/// App 功能與 ROS 2 通訊之間的傳輸層邊界。
///
/// 功能層應傳入穩定的 RoboSight 資料模型，而不是 ARKit 影格型別。
protocol RobotTransport: Sendable {
    /// 使用 Zenoh locator 與 ROS domain ID 開啟 ROS 2 傳輸層。
    func connect(routerAddress: String, domainId: Int) async throws

    /// 關閉發布器與傳輸層 context。
    func disconnect() async

    /// 發送輕量 status heartbeat。
    func publishStatus(_ message: String) async throws

    /// 發送一筆相機影像資料內容與對應 camera info metadata。
    func publishCameraImage(_ frame: CameraImageFrame) async throws

    /// 發送一筆由 IMU 姿態建立的 `/tf`。
    func publishIMUTF(_ frame: IMUSensorFrame) async throws

    /// 啟用或停用 `/joint_states` 訂閱。
    func setJointStatesSubscriptionEnabled(_ isEnabled: Bool) async throws

    /// 接收來自 ROS 2 的關節狀態數據串流。
    var jointStatesStream: AsyncStream<[String: Double]> { get }
}

/// 傳輸層級的驗證與執行時錯誤。
enum RobotTransportError: LocalizedError {
    case invalidRouterAddress
    case invalidRouterPort
    case invalidDomainId
    case invalidCameraFrame
    case notConnected

    /// 顯示在 Settings UI 的使用者可讀錯誤文字。
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
