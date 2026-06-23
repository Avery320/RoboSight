import Foundation

/// device_link 在父座標系中的三軸位移，單位為 meter。
struct DeviceTranslation: Sendable {
    let x: Double
    let y: Double
    let z: Double

    static let zero = DeviceTranslation(x: 0, y: 0, z: 0)
}

/// 由 ARKit VIO 估計出的設備相對位移。
///
/// 這個模型只描述位置，不處理旋轉；目前 device_link 旋轉仍由 IMU API 提供。
struct DevicePositionFrame: Sendable {
    /// Unix timestamp，單位為秒，用於對齊 ROS time。
    let timestamp: TimeInterval

    /// 相對於啟動時第一筆 ARKit pose 的位移。
    let translation: DeviceTranslation
}

/// 發布 `/tf` 時使用的完整 device_link pose。
///
/// 目前 translation 來自 ARKit，orientation 來自 CoreMotion IMU。
struct DeviceTFFrame: Sendable {
    /// Unix timestamp，單位為秒，用於對齊 ROS time。
    let timestamp: TimeInterval

    /// device_link 相對於 aruco_marker_link 的位移。
    let translation: DeviceTranslation

    /// device_link 相對於 aruco_marker_link 的姿態。
    let orientation: IMUQuaternion
}
