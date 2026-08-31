import SwiftUI

/// Settings 頁籤，負責 ROS 2 連線與功能啟用。
struct SettingsView: View {
    @ObservedObject var connectionViewModel: ConnectionViewModel
    @ObservedObject var cameraViewModel: CameraSensorViewModel
    @ObservedObject var imuViewModel: IMUSensorViewModel
    @ObservedObject var robotViewModel: RobotViewModel
    @ObservedObject var teleoperationViewModel: TeleoperationViewModel

    var body: some View {
        NavigationStack {
            Form {
                connectionSection
                rosSection
                teleoperationSection
                sensorSection
                robotSection
            }
            .navigationTitle("RoboSight")
            .task {
                await robotViewModel.refreshRobotListIfNeeded()
            }
        }
    }

    private var connectionSection: some View {
        SettingsSection("Connection") {
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

            SettingsValueRow(
                "Full Address",
                value: connectionViewModel.fullRouterAddress
            )
        }
    }

    private var rosSection: some View {
        SettingsSection("ROS 2") {
            SettingsValueRow("Topic", value: connectionViewModel.statusTopic)

            Toggle("Connection", isOn: connectionToggleBinding)
                .disabled(connectionViewModel.state.isBusy)

            if connectionViewModel.state.isBusy {
                ProgressView("\(connectionViewModel.state.title)...")
            }

            if let detail = connectionViewModel.state.detail {
                SettingsStatusText(detail, isError: true)
            }

            if let message = connectionViewModel.lastStatusMessage {
                SettingsStatusText(message)
            }
        }
    }

    private var teleoperationSection: some View {
        SettingsSection("Teleoperation") {
            Picker("Robot Type", selection: $teleoperationViewModel.mode) {
                ForEach(TeleoperationMode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }

            if teleoperationViewModel.isAMREnabled {
                SettingsValueRow(
                    "Topic",
                    value: TeleoperationViewModel.joyTopic
                )
                SettingsValueRow(
                    "Message Type",
                    value: TeleoperationViewModel.joyMessageType
                )

                Toggle("Teleoperation", isOn: teleoperationPublishingToggleBinding)
                    .disabled(!connectionViewModel.state.isConnected)

                SettingsStatusText(teleoperationStatusMessage)
            }
        }
    }

    private var sensorSection: some View {
        SettingsSection("Sensor") {
            Toggle("Device Pose", isOn: imuTFPublishingBinding)
                .disabled(!connectionViewModel.state.isConnected || !imuViewModel.isAvailable)

            Toggle("Camera", isOn: cameraToggleBinding)
                .disabled(!connectionViewModel.state.isConnected || !imuViewModel.isAvailable)

            Toggle("LiDAR", isOn: lidarToggleBinding)
                .disabled(
                    !connectionViewModel.state.isConnected ||
                    !imuViewModel.isAvailable ||
                    (!cameraViewModel.canEnableLiDAR && !cameraViewModel.isLiDAREnabled)
                )

            if let message = imuViewModel.lastStatusMessage {
                SettingsStatusText(message)
            }
        }
    }

    private var robotSection: some View {
        SettingsSection(
            "Robot",
            footer: "Robot models are loaded from Avery320/robosim_library."
        ) {
            if robotViewModel.availableRobots.isEmpty && robotViewModel.isFetchingLibrary {
                ProgressView("Loading robot library...")
            } else {
                Picker("Model", selection: selectedRobotBinding) {
                    Text("Select Robot").tag(RobotLibraryItem?.none)
                    ForEach(robotViewModel.availableRobots) { robot in
                        Text(robot.name).tag(Optional(robot))
                    }
                }
            }

            Toggle("/joint_states", isOn: jointStatesSubscriptionToggleBinding)
                .disabled(connectionViewModel.state.isBusy)

            if robotViewModel.selectionState.isLoading {
                ProgressView(robotViewModel.selectionState.title)
            }

            if let validationMessage = robotViewModel.selectionState.message {
                SettingsStatusText(
                    validationMessage,
                    isError: !robotViewModel.selectionState.isValid
                )
            }

            if let errorMessage = robotViewModel.robotLoadError ?? robotViewModel.libraryFetchError {
                SettingsStatusText(errorMessage, isError: true)
            }
        }
    }

    private var teleoperationStatusMessage: String {
        guard connectionViewModel.state.isConnected else {
            return "Connect to ROS 2 to start teleoperation."
        }

        return connectionViewModel.isJoyPublishingEnabled
            ? "Publishing /joy at 20 Hz."
            : "Ready to publish /joy."
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

    /// AMR 模式只選擇控制 profile；由這個 Toggle 明確啟停 `/joy` 資料流。
    private var teleoperationPublishingToggleBinding: Binding<Bool> {
        Binding(
            get: { connectionViewModel.isJoyPublishingEnabled },
            set: { isEnabled in
                teleoperationViewModel.resetJoystick()
                connectionViewModel.setJoyPublishingEnabled(isEnabled)
            }
        )
    }

    /// Camera toggle 控制相機影像資料流；ARKit runtime 由根層依功能開關啟動。
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
                if isEnabled {
                    cameraViewModel.setCameraEnabled(true)
                }
                cameraViewModel.setLiDAREnabled(isEnabled)
            }
        )
    }

    /// 控制 device_link TF；旋轉來自 IMU，位移來自 ARKit VIO。
    private var imuTFPublishingBinding: Binding<Bool> {
        Binding(
            get: { imuViewModel.isTFPublishingEnabled },
            set: { isEnabled in
                connectionViewModel.resetDeviceTF()
                if isEnabled {
                    cameraViewModel.resetDevicePositionTracking()
                    startIMUTFPublishing()
                } else {
                    imuViewModel.stopPublishing()
                }
            }
        )
    }

    private func startIMUTFPublishing() {
        imuViewModel.startPublishing { frame in
            connectionViewModel.publishIMUOrientationTF(frame)
        }
    }

    /// 將 robot picker 的 optional selection 橋接到 view model。
    private var selectedRobotBinding: Binding<RobotLibraryItem?> {
        Binding(
            get: { robotViewModel.selectedRobot },
            set: { robot in
                robotViewModel.selectRobot(robot)
            }
        )
    }

    /// 控制 ROS `/joint_states` 是否建立 subscription。
    private var jointStatesSubscriptionToggleBinding: Binding<Bool> {
        Binding(
            get: { connectionViewModel.isJointStatesSubscriptionEnabled },
            set: { isEnabled in
                Task {
                    await connectionViewModel.setJointStatesSubscriptionEnabled(isEnabled)
                }
            }
        )
    }
}
