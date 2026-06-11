import simd

public enum KinematicsError: Error, Sendable, CustomStringConvertible {
    case invalidGraph(String)
    case invalidJointPositionsCount(expected: Int, actual: Int)

    public var description: String {
        switch self {
        case .invalidGraph(let message):
            return "Robot kinematic graph 無效：\(message)"
        case .invalidJointPositionsCount(let expected, let actual):
            return "Joint position 數量錯誤：預期 \(expected)，實際 \(actual)"
        }
    }
}

/// 將 kinematic tree 預先整理成 parent 先於 child 的線性結構。
public struct CompiledKinematics: Sendable {
    public let linkIDs: [LinkID]
    public let jointIDs: [JointID]
    public let linkIndexByID: [LinkID: Int]
    public let jointIndexByID: [JointID: Int]
    public let rootLinkIndex: Int

    public let parentLinkIndexForJoint: [Int]
    public let childLinkIndexForJoint: [Int]
    public let jointType: [JointType]
    public let jointOrigin: [Transform3D]
    public let axisRaw: [SIMD3<Double>]
    public let axisUnit: [SIMD3<Double>]
    public let traversalJointOrder: [Int]

    public init(robot: RobotModel) throws {
        let modelIndex = robot.makeIndex()

        guard modelIndex.linkByID[robot.rootLink] != nil else {
            throw KinematicsError.invalidGraph("找不到 root link '\(robot.rootLink)'。")
        }

        var parentJointByChild: [LinkID: JointID] = [:]
        parentJointByChild.reserveCapacity(robot.links.count)

        for joint in robot.joints {
            if modelIndex.linkByID[joint.parentLink] == nil {
                throw KinematicsError.invalidGraph("Joint '\(joint.id)' 參照不存在的 parent link '\(joint.parentLink)'。")
            }
            if modelIndex.linkByID[joint.childLink] == nil {
                throw KinematicsError.invalidGraph("Joint '\(joint.id)' 參照不存在的 child link '\(joint.childLink)'。")
            }

            if joint.childLink == robot.rootLink {
                throw KinematicsError.invalidGraph("Root link '\(robot.rootLink)' 不能是 joint '\(joint.id)' 的 child。")
            }

            if let existing = parentJointByChild[joint.childLink] {
                throw KinematicsError.invalidGraph(
                    "Link '\(joint.childLink)' 有多個 parent joints：'\(existing)'、'\(joint.id)'。"
                )
            }
            parentJointByChild[joint.childLink] = joint.id
        }

        var visitedLinks = Set<LinkID>()
        visitedLinks.reserveCapacity(robot.links.count)

        var linkOrder: [LinkID] = []
        linkOrder.reserveCapacity(robot.links.count)

        var jointOrder: [Joint] = []
        jointOrder.reserveCapacity(robot.joints.count)

        var queue: [LinkID] = []
        queue.reserveCapacity(robot.links.count)

        visitedLinks.insert(robot.rootLink)
        linkOrder.append(robot.rootLink)
        queue.append(robot.rootLink)

        // 從 root link 做 BFS，確保 parent link 一定先於 child link 計算。
        var cursor = 0
        while cursor < queue.count {
            let parentLink = queue[cursor]
            cursor += 1

            let childJoints = (modelIndex.childJointsByParent[parentLink] ?? [])
                .sorted(by: { $0.id.rawValue < $1.id.rawValue })

            for joint in childJoints {
                jointOrder.append(joint)

                if visitedLinks.insert(joint.childLink).inserted {
                    linkOrder.append(joint.childLink)
                    queue.append(joint.childLink)
                }
            }
        }

        if visitedLinks.count != robot.links.count {
            let allIDs = Set(robot.links.map(\.id))
            let unreachable = allIDs.subtracting(visitedLinks).map(\.rawValue).sorted()
            throw KinematicsError.invalidGraph("Robot 存在未連通 link：\(unreachable.joined(separator: ", "))。")
        }

        if jointOrder.count != robot.joints.count {
            let visitedJointIDs = Set(jointOrder.map(\.id))
            let unreachable = robot.joints.map(\.id).filter { !visitedJointIDs.contains($0) }.map(\.rawValue).sorted()
            throw KinematicsError.invalidGraph("Robot 存在未連通 joint：\(unreachable.joined(separator: ", "))。")
        }

        if parentJointByChild.count != robot.links.count - 1 {
            throw KinematicsError.invalidGraph("每個非 root link 必須剛好有一個 parent joint。")
        }

        self.rootLinkIndex = 0
        self.linkIDs = linkOrder
        self.linkIndexByID = Dictionary(uniqueKeysWithValues: linkOrder.enumerated().map { ($0.element, $0.offset) })

        self.jointIDs = jointOrder.map(\.id)
        self.jointIndexByID = Dictionary(uniqueKeysWithValues: jointIDs.enumerated().map { ($0.element, $0.offset) })

        var parentIndices: [Int] = []
        var childIndices: [Int] = []
        var types: [JointType] = []
        var origins: [Transform3D] = []
        var rawAxes: [SIMD3<Double>] = []
        var unitAxes: [SIMD3<Double>] = []

        parentIndices.reserveCapacity(jointOrder.count)
        childIndices.reserveCapacity(jointOrder.count)
        types.reserveCapacity(jointOrder.count)
        origins.reserveCapacity(jointOrder.count)
        rawAxes.reserveCapacity(jointOrder.count)
        unitAxes.reserveCapacity(jointOrder.count)

        for joint in jointOrder {
            guard let p = linkIndexByID[joint.parentLink], let c = linkIndexByID[joint.childLink] else {
                throw KinematicsError.invalidGraph("Joint '\(joint.id)' 的內部索引建立失敗。")
            }
            parentIndices.append(p)
            childIndices.append(c)
            types.append(joint.type)

            if let origin = joint.origin {
                origins.append(transformFromOrigin(xyz: origin.xyz, rpy: origin.rpy))
            } else {
                origins.append(.identity)
            }

            // raw axis 給 prismatic 平移使用，unit axis 給 revolute/continuous 旋轉使用。
            let rawAxis = joint.axis.vector
            rawAxes.append(rawAxis)

            if simd_length_squared(rawAxis) > 0 {
                unitAxes.append(simd_normalize(rawAxis))
            } else {
                unitAxes.append(Axis.defaultAxis.vector)
            }
        }

        self.parentLinkIndexForJoint = parentIndices
        self.childLinkIndexForJoint = childIndices
        self.jointType = types
        self.jointOrigin = origins
        self.axisRaw = rawAxes
        self.axisUnit = unitAxes
        self.traversalJointOrder = Array(0..<jointOrder.count)
    }

    /// 將 joint ID dictionary 打包成 compiled joint order 的陣列，未知 joint 會被忽略。
    public func packJointPositions(_ jointPositionsByID: [JointID: Double]) -> [Double] {
        var q = Array(repeating: 0.0, count: jointIDs.count)
        for (id, value) in jointPositionsByID {
            if let i = jointIndexByID[id] {
                q[i] = value
            }
        }
        return q
    }

    /// 依照 `linkIDs` 順序回傳各 link pose。
    public func linkPoses(jointPositions: [Double]) throws -> [Transform3D] {
        guard jointPositions.count == jointIDs.count else {
            throw KinematicsError.invalidJointPositionsCount(expected: jointIDs.count, actual: jointPositions.count)
        }

        var poses = Array(repeating: Transform3D.identity, count: linkIDs.count)
        poses[rootLinkIndex] = .identity

        for j in traversalJointOrder {
            let parentIndex = parentLinkIndexForJoint[j]
            let childIndex = childLinkIndexForJoint[j]

            let parentPose = poses[parentIndex]
            let origin = jointOrigin[j]

            let motion = jointMotionTransform(
                type: jointType[j],
                position: jointPositions[j],
                rawAxis: axisRaw[j],
                unitAxis: axisUnit[j]
            )

            poses[childIndex] = parentPose
                .composed(with: origin)
                .composed(with: motion)
        }

        return poses
    }

    public func linkPosesByID(jointPositionsByID: [JointID: Double]) throws -> [LinkID: Transform3D] {
        let q = packJointPositions(jointPositionsByID)
        let poses = try linkPoses(jointPositions: q)
        var dict: [LinkID: Transform3D] = [:]
        dict.reserveCapacity(linkIDs.count)
        for (i, id) in linkIDs.enumerated() {
            dict[id] = poses[i]
        }
        return dict
    }

    private func jointMotionTransform(
        type: JointType,
        position: Double,
        rawAxis: SIMD3<Double>,
        unitAxis: SIMD3<Double>
    ) -> Transform3D {
        switch type {
        case .revolute, .continuous:
            return Transform3D(translation: .zero, rotation: simd_quatd(angle: position, axis: unitAxis))
        case .prismatic:
            return Transform3D(translation: rawAxis * position, rotation: .init(ix: 0, iy: 0, iz: 0, r: 1))
        case .fixed:
            return .identity
        case .floating, .planar:
            // 這兩種 joint 尚未作為產品控制目標；目前以固定姿態處理，避免錯誤位移。
            return .identity
        }
    }
}
