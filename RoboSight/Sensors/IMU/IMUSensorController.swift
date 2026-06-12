import CoreMotion
import Foundation

/// RoboSight 的 CoreMotion IMU 取樣器。
///
/// 演算法來源：
/// PyojinKim/CoreLocationMotion-Data-Logger 的 `startIMUUpdate()`。
/// 這裡只保留 `CMDeviceMotion` 取樣邏輯，移除原專案的 UI、CSV、GPS 與檔案紀錄。
final class IMUSensorController {
    /// 原始演算法使用 200 Hz。實際 iOS 裝置可能會依硬體與系統負載降到較低頻率。
    private let sampleFrequency: TimeInterval

    /// 原始演算法將 g 轉成 m/s^2 使用的重力常數。
    private let gravity: Double

    private let motionManager: CMMotionManager
    private let operationQueue: OperationQueue

    init(
        sampleFrequency: TimeInterval = 200,
        gravity: Double = 9.81,
        motionManager: CMMotionManager = CMMotionManager()
    ) {
        self.sampleFrequency = sampleFrequency
        self.gravity = gravity
        self.motionManager = motionManager
        self.operationQueue = OperationQueue()
        self.operationQueue.qualityOfService = .userInitiated
        self.operationQueue.maxConcurrentOperationCount = 1
    }

    var isAvailable: Bool {
        motionManager.isDeviceMotionAvailable
    }

    /// 開始接收 CoreMotion 已融合的 device motion 資料。
    ///
    /// 參考來源使用 `.xMagneticNorthZVertical`，可讓姿態以磁北與垂直方向作為參考座標。
    func start(
        onFrame: @escaping (IMUSensorFrame) -> Void,
        onError: @escaping (Error) -> Void
    ) {
        guard motionManager.isDeviceMotionAvailable else {
            onError(IMUSensorError.deviceMotionUnavailable)
            return
        }
        guard !motionManager.isDeviceMotionActive else { return }

        let updateInterval = 1.0 / sampleFrequency
        motionManager.deviceMotionUpdateInterval = updateInterval
        motionManager.showsDeviceMovementDisplay = true

        motionManager.startDeviceMotionUpdates(
            using: .xMagneticNorthZVertical,
            to: operationQueue
        ) { [weak self] motion, error in
            if let error {
                onError(error)
                return
            }

            guard let self, let motion else { return }
            onFrame(Self.makeFrame(from: motion, gravity: self.gravity))
        }
    }

    func stop() {
        guard motionManager.isDeviceMotionActive else { return }
        motionManager.stopDeviceMotionUpdates()
    }

    /// 將 `CMDeviceMotion` 轉成 RoboSight 穩定資料模型。
    private static func makeFrame(from motion: CMDeviceMotion, gravity: Double) -> IMUSensorFrame {
        let quaternion = motion.attitude.quaternion
        let rotationRate = motion.rotationRate
        let gravityVector = motion.gravity
        let userAcceleration = motion.userAcceleration
        let magneticField = motion.magneticField.field

        return IMUSensorFrame(
            timestamp: Date().timeIntervalSince1970,
            sensorTimestamp: motion.timestamp,
            orientation: IMUQuaternion(
                x: quaternion.x,
                y: quaternion.y,
                z: quaternion.z,
                w: quaternion.w
            ),
            angularVelocity: IMUVector3(
                x: rotationRate.x,
                y: rotationRate.y,
                z: rotationRate.z
            ),
            gravity: IMUVector3(
                x: gravityVector.x * gravity,
                y: gravityVector.y * gravity,
                z: gravityVector.z * gravity
            ),
            linearAcceleration: IMUVector3(
                x: userAcceleration.x * gravity,
                y: userAcceleration.y * gravity,
                z: userAcceleration.z * gravity
            ),
            magneticField: IMUVector3(
                x: magneticField.x,
                y: magneticField.y,
                z: magneticField.z
            ),
            heading: motion.heading
        )
    }
}

enum IMUSensorError: LocalizedError {
    case deviceMotionUnavailable

    var errorDescription: String? {
        switch self {
        case .deviceMotionUnavailable:
            "Device motion is not available on this device."
        }
    }
}
