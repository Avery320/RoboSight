import SwiftUI

/// SwiftUI 根畫面，包含 Settings 與 Camera 兩個頁籤。
struct ContentView: View {
    @StateObject private var connectionViewModel: ConnectionViewModel
    @StateObject private var cameraViewModel = CameraSensorViewModel()

    /// 在 app 生命週期內只建立一次 connection view model。
    @MainActor
    init() {
        _connectionViewModel = StateObject(wrappedValue: ConnectionViewModel())
    }

    var body: some View {
        TabView {
            SettingsView(
                connectionViewModel: connectionViewModel,
                cameraViewModel: cameraViewModel
            )
            .tabItem {
                Label("Settings", systemImage: "gearshape")
            }

            CameraView(
                cameraViewModel: cameraViewModel,
                connectionViewModel: connectionViewModel
            )
                .tabItem {
                    Label("Camera", systemImage: "camera.viewfinder")
                }
        }
    }
}

/// Settings 頁籤，負責 ROS 2 連線與感測功能啟用。
private struct SettingsView: View {
    @ObservedObject var connectionViewModel: ConnectionViewModel
    @ObservedObject var cameraViewModel: CameraSensorViewModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    LabeledContent("Router Address") {
                        TextField("Router Address", text: $connectionViewModel.routerHost)
                            .multilineTextAlignment(.trailing)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }

                    LabeledContent("Router Port") {
                        TextField("Router Port", text: $connectionViewModel.routerPort)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }

                    LabeledContent("Domain ID") {
                        TextField("Domain ID", text: $connectionViewModel.domainId)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.numberPad)
                    }

                    LabeledContent("Full Address") {
                        Text(connectionViewModel.fullRouterAddress)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }
                } header: {
                    Text("Connection")
                } footer: {
                    Text("Full Address is the Zenoh locator used by swift-ros2. Simulator can use 127.0.0.1; physical devices should use the Mac or ROS Docker host LAN IP.")
                }

                Section {
                    LabeledContent("Topic") {
                        Text(connectionViewModel.statusTopic)
                            .foregroundStyle(.secondary)
                            .textSelection(.enabled)
                    }

                    Toggle("Connection", isOn: connectionToggleBinding)
                        .disabled(connectionViewModel.state.isBusy)

                    if connectionViewModel.state.isBusy {
                        ProgressView("\(connectionViewModel.state.title)...")
                    }

                    if let detail = connectionViewModel.state.detail {
                        Text(detail)
                            .foregroundStyle(.red)
                    }

                    if let message = connectionViewModel.lastStatusMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                    }
                } header: {
                    Text("ROS 2")
                }

                Section {
                    Toggle("Camera", isOn: cameraToggleBinding)

                    Toggle("LiDAR", isOn: lidarToggleBinding)
                        .disabled(!cameraViewModel.canEnableLiDAR && !cameraViewModel.isLiDAREnabled)
                } header: {
                    Text("Camera / LiDAR")
                } footer: {
                    Text("Enable Camera before switching to the Camera tab. LiDAR is available only on supported devices and runs as ARKit scene depth.")
                }
            }
            .navigationTitle("RoboSight")
        }
    }

    /// 將非同步連線流程橋接到 iOS Toggle。
    private var connectionToggleBinding: Binding<Bool> {
        Binding(
            get: { connectionViewModel.isConnectionEnabled },
            set: { isEnabled in
                Task {
                    await connectionViewModel.setConnectionEnabled(isEnabled)
                }
            }
        )
    }

    /// 只更新使用者意圖；實際 ARKit session 會在 CameraView 啟動。
    private var cameraToggleBinding: Binding<Bool> {
        Binding(
            get: { cameraViewModel.isCameraEnabled },
            set: { isEnabled in
                cameraViewModel.setCameraEnabled(isEnabled)
            }
        )
    }

    /// 讓 LiDAR 狀態受相機啟用狀態與硬體支援限制。
    private var lidarToggleBinding: Binding<Bool> {
        Binding(
            get: { cameraViewModel.isLiDAREnabled },
            set: { isEnabled in
                cameraViewModel.setLiDAREnabled(isEnabled)
            }
        )
    }
}

/// Camera 頁籤，顯示 ARKit 預覽與簡易感測狀態。
private struct CameraView: View {
    @ObservedObject var cameraViewModel: CameraSensorViewModel
    @ObservedObject var connectionViewModel: ConnectionViewModel

    var body: some View {
        NavigationStack {
            Group {
                if cameraViewModel.isCameraEnabled {
                    ZStack(alignment: .bottom) {
                        ARKitPreviewView(
                            isLiDAREnabled: cameraViewModel.isLiDAREnabled,
                            onStatusUpdate: { status in
                                cameraViewModel.updateStatus(status)
                            },
                            onFrameUpdate: { frame in
                                let cameraImage = frame.cameraImage
                                Task {
                                    // 影像發送刻意由 Camera toggle 驅動：
                                    // 啟用預覽就代表啟用相機影像串流。
                                    await connectionViewModel.publishCameraImage(cameraImage)
                                }
                            }
                        )
                        .ignoresSafeArea(edges: .top)

                        CameraStatusPanel(
                            status: cameraViewModel.status,
                            isLiDAREnabled: cameraViewModel.isLiDAREnabled
                        )
                        .padding()
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
        }
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
