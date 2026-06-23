import ARKit
import Foundation
import UIKit

/// 設備相機與 LiDAR 開關的 UI 狀態。
///
/// 實際 ARKit runtime 由根層畫面持有；這個 view model 只負責
/// Settings 中的功能開關狀態、最新感測狀態，以及相機原始資料 API 的派生資料。
@MainActor
final class CameraSensorViewModel: ObservableObject {
    @Published private(set) var isCameraEnabled = false
    @Published private(set) var isLiDAREnabled = false
    @Published private(set) var latestPreviewImage: UIImage?
    @Published var status = ARKitSensorStatus.idle

    private let devicePositionTracker = ARDevicePositionTracker()

    /// 檢查設備是否支援 ARKit scene depth。
    var isLiDARSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// 只有在相機 session 預期啟動時，才允許啟用 LiDAR。
    var canEnableLiDAR: Bool {
        isCameraEnabled && isLiDARSupported
    }

    /// 更新相機影像功能開關；停用時同步關閉相依的 LiDAR 與狀態資料。
    func setCameraEnabled(_ isEnabled: Bool) {
        isCameraEnabled = isEnabled

        if !isEnabled {
            isLiDAREnabled = false
            latestPreviewImage = nil
            status = .idle
        }
    }

    /// 只有在使用者意圖與硬體能力都允許時，才啟用 LiDAR。
    func setLiDAREnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            isLiDAREnabled = false
            return
        }

        isLiDAREnabled = canEnableLiDAR
    }

    /// 接收來自 ARKit 來源的 runtime 感測狀態。
    func updateStatus(_ status: ARKitSensorStatus) {
        self.status = status
    }

    /// 更新 Camera tab 使用的輔助預覽圖；ROS 發送仍直接使用 `CameraImageFrame`。
    func updatePreviewImage(_ frame: CameraImageFrame) {
        latestPreviewImage = UIImage(data: frame.image.data)
    }

    /// 依 ARKit raw frame 計算 device_link 相對啟動點的位移。
    func makeDevicePositionFrame(from rawFrame: CameraRawFrame) -> DevicePositionFrame {
        devicePositionTracker.makeFrame(from: rawFrame)
    }

    /// ARKit view 重新建立時，下一筆 frame 應重新作為 device_link 位移原點。
    func resetDevicePositionTracking() {
        devicePositionTracker.reset()
    }
}
