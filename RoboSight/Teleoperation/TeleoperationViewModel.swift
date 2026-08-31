import Combine
import CoreGraphics

/// Start Page 可選擇的遠端操作模式。
enum TeleoperationMode: String, CaseIterable, Identifiable {
    case none = "None"
    case amr = "AMR"

    var id: Self { self }
}

/// 管理 Start Page 與後續 Joystick Page 共用的操作模式。
@MainActor
final class TeleoperationViewModel: ObservableObject {
    static let joyTopic = "/joy"
    static let joyMessageType = "sensor_msgs/msg/Joy"
    private static let deadzone: Float = 0.05

    @Published var mode: TeleoperationMode = .none {
        didSet {
            if mode == .none {
                resetJoystick()
            }
        }
    }
    @Published private(set) var joyControlState = JoyControlState.neutral

    var isAMREnabled: Bool {
        mode == .amr
    }

    /// 接收套件提供的 -1...1 畫面座標，轉成 ROS 的前進與左轉正方向。
    func updateJoystick(normalizedPosition position: CGPoint) {
        guard isAMREnabled else {
            resetJoystick()
            return
        }

        let turn = -Float(position.x)
        let forward = Float(-position.y)
        joyControlState = JoyControlState(
            turn: abs(turn) < Self.deadzone ? 0 : turn,
            forward: abs(forward) < Self.deadzone ? 0 : forward
        )
    }

    func resetJoystick() {
        joyControlState = .neutral
    }
}
