import ARKit
import Foundation

/// 設備相機與 LiDAR 開關的 UI 狀態。
///
/// 實際感測資料串流由 `ARKitSensorView` 持有；這個 view model 只負責
/// 使用者可見的啟用狀態，以及暴露最新感測狀態。
@MainActor
final class CameraSensorViewModel: ObservableObject {
    @Published private(set) var isCameraEnabled = false
    @Published private(set) var isLiDAREnabled = false
    @Published var status = ARKitSensorStatus.idle

    /// 檢查設備是否支援 ARKit scene depth。
    var isLiDARSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// 只有在相機 session 預期啟動時，才允許啟用 LiDAR。
    var canEnableLiDAR: Bool {
        isCameraEnabled && isLiDARSupported
    }

    /// 更新相機開關；停用時同步重置相依的 LiDAR 與狀態資料。
    func setCameraEnabled(_ isEnabled: Bool) {
        isCameraEnabled = isEnabled

        if !isEnabled {
            isLiDAREnabled = false
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
}
