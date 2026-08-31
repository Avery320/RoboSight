import SwiftUI
import SwiftUIJoystick

/// AMR 遠端操作頁籤；目前只建立搖桿 UI 與輸入狀態。
struct JoystickView: View {
    @ObservedObject var teleoperationViewModel: TeleoperationViewModel
    @StateObject private var joystickMonitor = JoystickMonitor()
    @State private var hapticPhase: HapticPhase = .inactive

    private let maximumDiameter: CGFloat = 280

    private enum HapticPhase: Equatable {
        case inactive
        case centered
        case active
        case outerEdge
    }

    var body: some View {
        NavigationStack {
            Group {
                if teleoperationViewModel.isAMREnabled {
                    GeometryReader { proxy in
                        let diameter = min(maximumDiameter, proxy.size.width * 0.68)

                        JoystickBuilder(
                            monitor: joystickMonitor,
                            width: diameter,
                            shape: .circle,
                            background: {
                                joystickBackground(diameter: diameter)
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
                        .onReceive(joystickMonitor.$xyPoint) { rawPosition in
                            let position = normalizedPosition(
                                rawPosition,
                                controlDiameter: diameter
                            )
                            updateHapticPhase(distance: hypot(position.x, position.y))
                            teleoperationViewModel.updateJoystick(normalizedPosition: position)
                        }
                        .onDisappear {
                            resetInput()
                        }
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
        .sensoryFeedback(trigger: hapticPhase) { oldPhase, newPhase in
            switch (oldPhase, newPhase) {
            case (.centered, .active):
                return .impact(weight: .medium, intensity: 1.6)
            case (.active, .outerEdge):
                return .impact(weight: .heavy, intensity: 2.5)
            case (.active, .centered), (.outerEdge, .centered):
                return .impact(flexibility: .solid, intensity: 1.8)
            default:
                return nil
            }
        }
    }

    private var accessibilityValue: String {
        let axes = teleoperationViewModel.joystickAxes
        return String(format: "X %.2f, Y %.2f", axes.x, axes.y)
    }

    /// 將套件輸出的 -diameter...diameter 座標轉成 -1...1。
    private func normalizedPosition(
        _ position: CGPoint,
        controlDiameter: CGFloat
    ) -> CGPoint {
        guard controlDiameter > 0 else {
            return .zero
        }

        return CGPoint(
            x: position.x / controlDiameter,
            y: position.y / controlDiameter
        )
    }

    /// 只在離開中心、首次抵達外圈及回到中心時更新觸覺狀態。
    private func updateHapticPhase(distance: CGFloat) {
        let centerThreshold: CGFloat = 0.04
        let deadZone: CGFloat = 0.12
        let outerEdge: CGFloat = 0.95

        switch hapticPhase {
        case .inactive:
            hapticPhase = .centered
        case .centered where distance >= deadZone:
            hapticPhase = .active
        case .active where distance >= outerEdge:
            hapticPhase = .outerEdge
        case .active where distance <= centerThreshold:
            hapticPhase = .centered
        case .outerEdge where distance <= centerThreshold:
            hapticPhase = .centered
        default:
            break
        }
    }

    /// 建立搖桿底座與中心到拖曳點的半透明彈性連接。
    private func joystickBackground(diameter: CGFloat) -> some View {
        let position = normalizedPosition(
            joystickMonitor.xyPoint,
            controlDiameter: diameter
        )
        let radius = diameter / 2
        let displacement = CGSize(
            width: position.x * radius,
            height: position.y * radius
        )

        return ZStack {
            Circle()
                .fill(Color(uiColor: .secondarySystemFill))

            ElasticBubble(
                displacement: displacement,
                thumbDiameter: diameter / 4
            )

            Circle()
                .strokeBorder(.secondary.opacity(0.35), lineWidth: 2)
        }
        .clipShape(Circle())
        .animation(
            .interactiveSpring(response: 0.18, dampingFraction: 0.76),
            value: displacement
        )
    }

    /// 離開頁籤或停用 AMR 時，不保留上一次的移動命令。
    private func resetInput() {
        hapticPhase = .inactive
        joystickMonitor.xyPoint = .zero
        teleoperationViewModel.resetJoystick()
    }
}

/// 在同一畫布繪製兩個圓與內縮連接橋，避免交疊處出現透明破洞。
private struct ElasticBubble: View, Animatable {
    var displacement: CGSize
    let thumbDiameter: CGFloat

    var animatableData: AnimatablePair<CGFloat, CGFloat> {
        get { AnimatablePair(displacement.width, displacement.height) }
        set { displacement = CGSize(width: newValue.first, height: newValue.second) }
    }

    var body: some View {
        Canvas { context, size in
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let end = CGPoint(
                x: center.x + displacement.width,
                y: center.y + displacement.height
            )
            let distance = hypot(displacement.width, displacement.height)
            let progress = min(distance / max(min(size.width, size.height) / 2, 1), 1)
            let endRadius = thumbDiameter * 0.60
            let centerRadius = thumbDiameter * (0.54 - 0.20 * progress)
            let fill = GraphicsContext.Shading.color(Color.accentColor)
            let circle = { (point: CGPoint, radius: CGFloat) in
                Path(ellipseIn: CGRect(
                    x: point.x - radius,
                    y: point.y - radius,
                    width: radius * 2,
                    height: radius * 2
                ))
            }

            let edgeRatio: CGFloat = 0.74
            let insetRatio = sqrt(1 - edgeRatio * edgeRatio)
            let startWidth = centerRadius * edgeRatio
            let endWidth = endRadius * edgeRatio
            let startInset = centerRadius * insetRatio
            let endInset = endRadius * insetRatio
            let bridgeLength = distance - startInset - endInset

            context.fill(circle(center, centerRadius), with: fill)
            context.fill(circle(end, endRadius), with: fill)

            guard bridgeLength > 0 else {
                return
            }

            let handle = min(bridgeLength * 0.42, startWidth * 1.15)
            let handleX = edgeRatio * handle
            let handleY = insetRatio * handle
            let endX = distance - endInset

            var bridge = Path()
            bridge.move(to: CGPoint(x: startInset, y: -startWidth))
            bridge.addCurve(
                to: CGPoint(x: endX, y: -endWidth),
                control1: CGPoint(x: startInset + handleX, y: -startWidth + handleY),
                control2: CGPoint(x: endX - handleX, y: -endWidth + handleY)
            )
            bridge.addLine(to: CGPoint(x: endX, y: endWidth))
            bridge.addCurve(
                to: CGPoint(x: startInset, y: startWidth),
                control1: CGPoint(x: endX - handleX, y: endWidth - handleY),
                control2: CGPoint(x: startInset + handleX, y: startWidth - handleY)
            )
            bridge.closeSubpath()

            context.translateBy(x: center.x, y: center.y)
            context.rotate(by: .radians(atan2(displacement.height, displacement.width)))
            context.fill(bridge, with: fill)
        }
        .opacity(0.22)
    }
}

#Preview {
    let viewModel = TeleoperationViewModel()
    viewModel.mode = .amr
    return JoystickView(teleoperationViewModel: viewModel)
}
