/// 根據 joint position 計算各 link 在世界座標中的姿態。
public struct ForwardKinematics: Sendable {
    private let compiled: CompiledKinematics

    public init(robot: RobotModel) throws {
        self.compiled = try CompiledKinematics(robot: robot)
    }

    /// 回傳每個 link 的世界座標姿態。
    public func linkPoses(jointPositionsByID: [Joint.ID: Double]) throws -> [Link.ID: Transform3D] {
        try compiled.linkPosesByID(jointPositionsByID: jointPositionsByID)
    }
}
