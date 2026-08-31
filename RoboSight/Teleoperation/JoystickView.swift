import SwiftUI
import SwiftUIJoystick

/// AMR 遠端操作頁籤；只有明確啟動 Teleoperation 後才開放搖桿輸入。
struct JoystickView: View {
    @ObservedObject var teleoperationViewModel: TeleoperationViewModel
    let isTeleoperationEnabled: Bool

    @StateObject private var joystickMonitor = JoystickMonitor()
    private let maximumDiameter: CGFloat = 280

    var body: some View {
        NavigationStack {
            Group {
                if teleoperationViewModel.isAMREnabled && isTeleoperationEnabled {
                    joystick
                } else if teleoperationViewModel.isAMREnabled {
                    ContentUnavailableView {
                        Label("Teleoperation Stopped", systemImage: "pause.circle")
                    } description: {
                        Text("Start Teleoperation from Settings to enable the joystick.")
                    }
                } else {
                    ContentUnavailableView {
                        Label("Joystick Disabled", systemImage: "circle.grid.cross")
                    } description: {
                        Text("Select AMR from Settings to enable the joystick.")
                    }
                }
            }
            .navigationTitle("Joystick")
            .navigationBarTitleDisplayMode(.inline)
        }
    }

    private var joystick: some View {
        GeometryReader { proxy in
            let diameter = min(maximumDiameter, proxy.size.width * 0.68)

            JoystickBuilder(
                monitor: joystickMonitor,
                width: diameter,
                shape: .circle,
                background: {
                    Circle()
                        .fill(Color(uiColor: .secondarySystemFill))
                        .overlay {
                            Circle()
                                .strokeBorder(.secondary.opacity(0.35), lineWidth: 2)
                        }
                },
                foreground: {
                    Circle()
                        .fill(.tint)
                        .shadow(color: .black.opacity(0.18), radius: 8, y: 4)
                },
                locksInPlace: false
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .accessibilityLabel("AMR Joystick")
            .accessibilityValue(accessibilityValue)
            .onReceive(joystickMonitor.$xyPoint) { position in
                teleoperationViewModel.updateJoystick(
                    normalizedPosition: normalizedPosition(
                        position,
                        controlDiameter: diameter
                    )
                )
            }
            .onDisappear {
                resetInput()
            }
        }
    }

    private var accessibilityValue: String {
        let state = teleoperationViewModel.joyControlState
        return String(
            format: "Turn %.2f, Forward %.2f",
            state.turn,
            state.forward
        )
    }

    /// SwiftUIJoystick 輸出 -diameter...diameter，轉成 ROS 使用的 -1...1。
    private func normalizedPosition(
        _ position: CGPoint,
        controlDiameter: CGFloat
    ) -> CGPoint {
        guard controlDiameter > 0 else { return .zero }

        return CGPoint(
            x: position.x / controlDiameter,
            y: position.y / controlDiameter
        )
    }

    private func resetInput() {
        joystickMonitor.xyPoint = .zero
        teleoperationViewModel.resetJoystick()
    }
}

#Preview {
    let viewModel = TeleoperationViewModel()
    viewModel.mode = .amr
    return JoystickView(
        teleoperationViewModel: viewModel,
        isTeleoperationEnabled: true
    )
}
