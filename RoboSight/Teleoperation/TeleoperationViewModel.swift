import Combine
import CoreGraphics

/// Start Page 可選擇的遠端操作模式。
enum TeleoperationMode: String, CaseIterable, Identifiable {
    case none = "None"
    case amr = "AMR"

    var id: Self { self }
}

/// 後續對應 `sensor_msgs/Joy.axes` 的標準化平面輸入。
struct JoystickAxes {
    static let zero = JoystickAxes(x: 0, y: 0)

    let x: Float
    let y: Float
}

/// 管理 Start Page 與後續 Joystick Page 共用的操作模式。
@MainActor
final class TeleoperationViewModel: ObservableObject {
    static let joyTopic = "/joy"

    @Published var mode: TeleoperationMode = .none {
        didSet {
            if mode == .none {
                resetJoystick()
            }
        }
    }
    @Published private(set) var joystickAxes: JoystickAxes = .zero

    var isAMREnabled: Bool {
        mode == .amr
    }

    /// 接收 -1...1 的標準化畫面座標，並轉成向上為正 Y 的 Joy axes。
    func updateJoystick(normalizedPosition position: CGPoint) {
        guard isAMREnabled else {
            resetJoystick()
            return
        }

        joystickAxes = JoystickAxes(
            x: Float(position.x),
            y: Float(-position.y)
        )
    }

    func resetJoystick() {
        joystickAxes = .zero
    }
}
