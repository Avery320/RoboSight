import Foundation

/// IMU 使用的三軸向量。
///
/// 單位由欄位語意決定：
/// - angular velocity: rad/s
/// - linear acceleration / gravity: m/s^2
/// - magnetic field: microtesla
struct IMUVector3: Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double
}

/// CoreMotion 融合後的設備姿態 quaternion。
struct IMUQuaternion: Equatable, Sendable {
    let x: Double
    let y: Double
    let z: Double
    let w: Double
}

/// RoboSight 的 IMU 原始資料 API 輸出。
///
/// 這個模型刻意與 CoreMotion 和 ROS message 型別解耦。
/// 後續產品功能或 ROS 傳輸層應消費這個模型，而不是直接依賴 `CMDeviceMotion`。
struct IMUSensorFrame: Equatable, Sendable {
    /// Unix timestamp，單位為秒，用於對齊 ROS time。
    let timestamp: TimeInterval

    /// CoreMotion timestamp，單位為秒，來源為裝置開機後的單調時間。
    let sensorTimestamp: TimeInterval

    /// 設備姿態，來源為 `CMDeviceMotion.attitude.quaternion`。
    ///
    /// RoboSight 目前定義 `device_link` 與 iOS 裝置本體軸一致：
    /// +X 為螢幕右側，+Y 為螢幕上方，+Z 為螢幕正面。
    let orientation: IMUQuaternion

    /// 角速度，單位 rad/s，來源為 `CMDeviceMotion.rotationRate`。
    let angularVelocity: IMUVector3

    /// 重力向量，單位 m/s^2。
    let gravity: IMUVector3

    /// 已扣除重力的使用者加速度，單位 m/s^2。
    let linearAcceleration: IMUVector3

    /// 磁場向量，單位 microtesla。
    let magneticField: IMUVector3

    /// 依 CoreMotion 參考座標計算的 heading。
    let heading: Double
}
