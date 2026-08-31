import SwiftUI
import UIKit

/// App 主要頁籤。用於管理長生命週期 runtime 是否應該啟動。
private enum AppTab: Hashable {
    case settings
    case camera
    case robot
    case joystick
}

/// SwiftUI 根畫面，包含 Settings、Camera、Robot 與 Joystick 頁籤。
struct ContentView: View {
    @Environment(\.scenePhase) private var scenePhase

    @StateObject private var connectionViewModel: ConnectionViewModel
    @StateObject private var cameraViewModel = CameraSensorViewModel()
    @StateObject private var imuViewModel = IMUSensorViewModel()
    @StateObject private var robotViewModel = RobotViewModel()
    @StateObject private var teleoperationViewModel = TeleoperationViewModel()
    @State private var selectedTab: AppTab = .settings

    /// 在 app 生命週期內只建立一次 connection view model。
    @MainActor
    init() {
        _connectionViewModel = StateObject(wrappedValue: ConnectionViewModel())
    }

    var body: some View {
        ZStack {
            TabView(selection: $selectedTab) {
                SettingsView(
                    connectionViewModel: connectionViewModel,
                    cameraViewModel: cameraViewModel,
                    imuViewModel: imuViewModel,
                    robotViewModel: robotViewModel,
                    teleoperationViewModel: teleoperationViewModel
                )
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(AppTab.settings)

                CameraView(
                    cameraViewModel: cameraViewModel
                )
                    .tabItem {
                        Label("Camera", systemImage: "camera.viewfinder")
                    }
                    .tag(AppTab.camera)

                RobotView(
                    robotViewModel: robotViewModel,
                    isActive: selectedTab == .robot
                )
                    .tabItem {
                        Label("Robot", systemImage: "cube.box")
                    }
                    .tag(AppTab.robot)

                JoystickView(
                    teleoperationViewModel: teleoperationViewModel,
                    isTeleoperationEnabled: connectionViewModel.isJoyPublishingEnabled
                )
                    .tabItem {
                        Label("Joystick", systemImage: "circle.grid.cross")
                    }
                    .tag(AppTab.joystick)
            }

            // ARKit runtime 必須在根層維持生命週期；Camera tab 只顯示由 frame 產生的輔助預覽。
            if isARKitRuntimeEnabled {
                ARKitPreviewView(
                    isLiDAREnabled: cameraViewModel.isLiDAREnabled,
                    onStatusUpdate: { status in
                        cameraViewModel.updateStatus(status)
                    },
                    onFrameUpdate: handleARKitFrame
                )
                .frame(width: 1, height: 1)
                .opacity(0)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
                .onAppear {
                    cameraViewModel.resetDevicePositionTracking()
                    connectionViewModel.resetDeviceTF()
                }
            }
        }
        .task {
            for await jointStates in connectionViewModel.jointStatesStream {
                robotViewModel.updateJointStates(jointStates)
            }
        }
        .onChange(of: connectionViewModel.state) { _, state in
            if !state.isConnected {
                cameraViewModel.setCameraEnabled(false)
                imuViewModel.stopPublishing()
                teleoperationViewModel.resetJoystick()
            }
        }
        .onChange(of: teleoperationViewModel.mode) { _, mode in
            if mode != .amr {
                connectionViewModel.setJoyPublishingEnabled(false)
            }
        }
        .onChange(of: teleoperationViewModel.joyControlState) { _, controlState in
            connectionViewModel.updateJoyControlState(controlState)
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase != .active else { return }
            teleoperationViewModel.resetJoystick()
            connectionViewModel.setJoyPublishingEnabled(false)
        }
    }

    /// Settings 的功能開關決定 ARKit runtime 是否啟動；tab 只決定是否顯示預覽。
    private var isARKitRuntimeEnabled: Bool {
        cameraViewModel.isCameraEnabled ||
        cameraViewModel.isLiDAREnabled ||
        imuViewModel.isTFPublishingEnabled
    }

    private var isCameraPreviewVisible: Bool {
        selectedTab == .camera && cameraViewModel.isCameraEnabled
    }

    /// ARKit runtime 的 frame 統一在根層處理，再依功能 toggle 分流。
    private func handleARKitFrame(_ frame: ARKitSensorFrame) {
        if imuViewModel.isTFPublishingEnabled {
            let devicePosition = cameraViewModel.makeDevicePositionFrame(
                from: frame.rawCameraFrame
            )
            connectionViewModel.publishDevicePositionTF(devicePosition)
        }

        if cameraViewModel.isCameraEnabled {
            if isCameraPreviewVisible {
                cameraViewModel.updatePreviewImage(frame.cameraImage)
            }
            connectionViewModel.publishCameraImage(frame.cameraImage)
        }
    }
}

/// Camera 頁籤只做輔助檢視；啟用後顯示由 ARKit runtime 產生的最新影像 frame。
private struct CameraView: View {
    @ObservedObject var cameraViewModel: CameraSensorViewModel

    var body: some View {
        NavigationStack {
            Group {
                if cameraViewModel.isCameraEnabled {
                    CameraPreviewImage(image: cameraViewModel.latestPreviewImage)
                        .ignoresSafeArea(edges: .top)
                        .safeAreaInset(edge: .bottom, spacing: 0) {
                            CameraStatusPanel(
                                status: cameraViewModel.status,
                                isLiDAREnabled: cameraViewModel.isLiDAREnabled
                            )
                            .padding(.horizontal)
                            .padding(.bottom, 8)
                        }
                } else {
                    VStack(spacing: 12) {
                        Image(systemName: "camera.slash")
                            .font(.largeTitle)
                            .foregroundStyle(.secondary)
                        Text("Camera Stopped")
                            .font(.headline)
                        Text("Enable Camera from Settings to show the ARKit preview.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding()
                }
            }
            .navigationTitle("Camera")
            .navigationBarTitleDisplayMode(.inline)
            .toolbarBackground(.hidden, for: .navigationBar)
        }
    }
}

/// Camera tab 的輔助預覽。這裡顯示已處理後的 JPEG frame，不直接持有 ARKit session。
private struct CameraPreviewImage: View {
    let image: UIImage?

    var body: some View {
        Group {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .scaledToFill()
            } else {
                ProgressView("Waiting for camera frame...")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black.opacity(0.9))
                    .foregroundStyle(.white)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .clipped()
    }
}

/// 顯示設備端相機與 depth 狀態的簡易浮層。
private struct CameraStatusPanel: View {
    let status: ARKitSensorStatus
    let isLiDAREnabled: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent("RGB") {
                Text(resolutionText(status.rgbResolution))
            }

            LabeledContent("LiDAR") {
                Text(lidarStatusText)
            }

            LabeledContent("Depth") {
                Text(isLiDAREnabled ? resolutionText(status.depthResolution) : "-")
            }

            LabeledContent("Confidence") {
                Text(confidenceStatusText)
            }

            LabeledContent("FPS") {
                Text(status.framesPerSecond.formatted(.number.precision(.fractionLength(1))))
            }
        }
        .font(.footnote)
        .padding()
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 14))
    }

    /// 將可選的影像尺寸格式化為預覽浮層文字。
    private func resolutionText(_ resolution: CGSize?) -> String {
        guard let resolution else { return "-" }
        return "\(Int(resolution.width)) x \(Int(resolution.height))"
    }

    /// 顯示 ARKit scene depth 是否受支援，且目前是否正在產生資料。
    private var lidarStatusText: String {
        guard isLiDAREnabled else { return "Disabled" }
        guard status.isSceneDepthSupported else { return "Unsupported" }
        return status.hasSceneDepth ? "Receiving" : "Waiting"
    }

    /// 僅在 LiDAR 啟用且受支援時，顯示 confidence map 狀態。
    private var confidenceStatusText: String {
        guard isLiDAREnabled else { return "Disabled" }
        guard status.isSceneDepthSupported else { return "Unsupported" }
        guard status.hasConfidenceMap else { return "Waiting" }
        return resolutionText(status.confidenceResolution)
    }
}

#Preview {
    ContentView()
}
