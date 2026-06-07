import ARKit
import Foundation

@MainActor
final class CameraSensorViewModel: ObservableObject {
    @Published private(set) var isCameraEnabled = false
    @Published private(set) var isLiDAREnabled = false
    @Published var status = ARKitSensorStatus.idle

    var isLiDARSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    var canEnableLiDAR: Bool {
        isCameraEnabled && isLiDARSupported
    }

    func setCameraEnabled(_ isEnabled: Bool) {
        isCameraEnabled = isEnabled

        if !isEnabled {
            isLiDAREnabled = false
            status = .idle
        }
    }

    func setLiDAREnabled(_ isEnabled: Bool) {
        guard isEnabled else {
            isLiDAREnabled = false
            return
        }

        isLiDAREnabled = canEnableLiDAR
    }

    func updateStatus(_ status: ARKitSensorStatus) {
        self.status = status
    }
}
