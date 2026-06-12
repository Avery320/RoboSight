import Combine
import Foundation
import simd

/// Settings 用的 IMU 發布狀態。
///
/// 這個 view model 只管理設備端 IMU 取樣生命週期。
/// ROS 發布仍交給 `ConnectionViewModel` 與傳輸層處理。
@MainActor
final class IMUSensorViewModel: ObservableObject {
    @Published private(set) var isTFPublishingEnabled = false
    @Published private(set) var lastStatusMessage: String?

    private let controller: IMUSensorController
    private var referenceOrientation: simd_quatd?

    init(controller: IMUSensorController = IMUSensorController()) {
        self.controller = controller
    }

    var isAvailable: Bool {
        controller.isAvailable
    }

    func startPublishing(onFrame: @escaping @MainActor (IMUSensorFrame) -> Void) {
        guard controller.isAvailable else {
            lastStatusMessage = IMUSensorError.deviceMotionUnavailable.localizedDescription
            isTFPublishingEnabled = false
            return
        }
        guard !isTFPublishingEnabled else { return }

        referenceOrientation = nil

        controller.start { [weak self] frame in
            Task { @MainActor in
                guard let relativeFrame = self?.frameRelativeToReference(frame) else { return }
                onFrame(relativeFrame)
            }
        } onError: { [weak self] error in
            Task { @MainActor in
                self?.controller.stop()
                self?.referenceOrientation = nil
                self?.lastStatusMessage = error.localizedDescription
                self?.isTFPublishingEnabled = false
            }
        }

        isTFPublishingEnabled = true
        lastStatusMessage = "Publishing device_link TF relative to the start pose."
    }

    func stopPublishing() {
        controller.stop()
        referenceOrientation = nil
        isTFPublishingEnabled = false
        lastStatusMessage = "IMU TF publishing stopped."
    }

    /// 將 CoreMotion 絕對姿態轉成相對於啟動當下的姿態。
    ///
    /// CoreMotion 的參考座標來自磁北與重力，不是 RoboSight 的 `aruco_marker_link`。
    /// 因此 `/tf` 發布不能直接使用原始 quaternion；啟動 Publish /tf 的第一筆姿態
    /// 會被視為 identity，後續只發布相對旋轉。
    private func frameRelativeToReference(_ frame: IMUSensorFrame) -> IMUSensorFrame {
        let currentOrientation = simd_quatd(frame.orientation).normalized

        guard let referenceOrientation else {
            self.referenceOrientation = currentOrientation
            return frame.replacingOrientation(.identity)
        }

        let relativeOrientation = referenceOrientation.inverse * currentOrientation
        return frame.replacingOrientation(IMUQuaternion(relativeOrientation))
    }
}

private extension IMUQuaternion {
    static let identity = IMUQuaternion(x: 0, y: 0, z: 0, w: 1)

    init(_ quaternion: simd_quatd) {
        self.init(
            x: quaternion.imag.x,
            y: quaternion.imag.y,
            z: quaternion.imag.z,
            w: quaternion.real
        )
    }
}

private extension simd_quatd {
    init(_ quaternion: IMUQuaternion) {
        self.init(
            ix: quaternion.x,
            iy: quaternion.y,
            iz: quaternion.z,
            r: quaternion.w
        )
    }
}

private extension IMUSensorFrame {
    func replacingOrientation(_ orientation: IMUQuaternion) -> IMUSensorFrame {
        IMUSensorFrame(
            timestamp: timestamp,
            sensorTimestamp: sensorTimestamp,
            orientation: orientation,
            angularVelocity: angularVelocity,
            gravity: gravity,
            linearAcceleration: linearAcceleration,
            magneticField: magneticField,
            heading: heading
        )
    }
}
