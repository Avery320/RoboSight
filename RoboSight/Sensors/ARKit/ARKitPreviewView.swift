import SwiftUI

/// ARKit 感測來源的 SwiftUI 包裝層。
///
/// 這裡負責隔離 UIKit / RealityKit 的生命週期細節。
/// 它不只服務 Camera tab，也提供 Device Pose 與 LiDAR 共用的 ARKit runtime。
struct ARKitPreviewView: UIViewRepresentable {
    var isLiDAREnabled: Bool
    var onStatusUpdate: (ARKitSensorStatus) -> Void = { _ in }
    var onFrameUpdate: (ARKitSensorFrame) -> Void = { _ in }

    /// 當 SwiftUI 插入 runtime view 時，建立並啟動 ARKit 感測來源。
    func makeUIView(context: Context) -> ARKitSensorView {
        let view = ARKitSensorView(frame: .zero)
        view.onStatusUpdate = onStatusUpdate
        view.onFrameUpdate = onFrameUpdate
        view.startSession(isSceneDepthEnabled: isLiDAREnabled)
        return view
    }

    /// 當 SwiftUI 狀態改變時，更新回呼與 LiDAR 狀態。
    func updateUIView(_ uiView: ARKitSensorView, context: Context) {
        uiView.onStatusUpdate = onStatusUpdate
        uiView.onFrameUpdate = onFrameUpdate
        uiView.setSceneDepthEnabled(isLiDAREnabled)
    }

    /// 當 runtime view 離開檢視階層時，暫停 ARKit。
    static func dismantleUIView(_ uiView: ARKitSensorView, coordinator: ()) {
        uiView.pauseSession()
    }
}
