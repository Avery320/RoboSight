import SwiftUI

struct ARKitPreviewView: UIViewRepresentable {
    var isLiDAREnabled: Bool
    var onStatusUpdate: (ARKitSensorStatus) -> Void = { _ in }
    var onFrameUpdate: (ARKitSensorFrame) -> Void = { _ in }

    func makeUIView(context: Context) -> ARKitSensorView {
        let view = ARKitSensorView(frame: .zero)
        view.onStatusUpdate = onStatusUpdate
        view.onFrameUpdate = onFrameUpdate
        view.startSession(isSceneDepthEnabled: isLiDAREnabled)
        return view
    }

    func updateUIView(_ uiView: ARKitSensorView, context: Context) {
        uiView.onStatusUpdate = onStatusUpdate
        uiView.onFrameUpdate = onFrameUpdate
        uiView.setSceneDepthEnabled(isLiDAREnabled)
    }

    static func dismantleUIView(_ uiView: ARKitSensorView, coordinator: ()) {
        uiView.pauseSession()
    }
}
