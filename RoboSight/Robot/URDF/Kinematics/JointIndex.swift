/// 將 joint 分成可直接控制的 independent joint 與 mimic joint。
public struct JointIndex: Sendable {
    public let independent: [Joint.ID]
    public let full: [Joint.ID]
    public let mimicDependencies: [Joint.ID: Joint.ID]
    public let mimicParameters: [Joint.ID: Mimic]

    public init(robot: RobotModel) {
        var indep: [Joint.ID] = []
        var deps: [Joint.ID: Joint.ID] = [:]
        var params: [Joint.ID: Mimic] = [:]

        func jointHasControllableDOF(_ joint: Joint) -> Bool {
            // fixed/floating/planar 先不進入產品控制；revolute/prismatic 必須有有效範圍才進 slider。
            switch joint.type {
            case .revolute, .prismatic:
                if let limit = joint.limit {
                    return abs(limit.upper - limit.lower) > 1e-12
                }
                return true
            case .continuous:
                return true
            case .fixed:
                return false
            case .floating, .planar:
                return false
            }
        }

        for joint in robot.joints {
            if let mimic = joint.mimic {
                // mimic joint 由 driver joint 計算，不應成為使用者直接控制的 slider。
                deps[joint.id] = mimic.jointName
                params[joint.id] = mimic
            } else {
                if jointHasControllableDOF(joint) {
                    indep.append(joint.id)
                }
            }
        }

        self.independent = indep
        self.full = robot.joints.map(\.id)
        self.mimicDependencies = deps
        self.mimicParameters = params
    }
}
