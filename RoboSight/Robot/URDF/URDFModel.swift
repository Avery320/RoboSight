import simd

/// URDF link 的強型別 ID，避免在 joint/link 查表時混用一般字串。
public struct LinkID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// URDF joint 的強型別 ID，後續 joint slider 與 ROS joint state 都會以此作為內部 key。
public struct JointID: Hashable, Sendable, CustomStringConvertible {
    public let rawValue: String

    public init(rawValue: String) {
        self.rawValue = rawValue
    }

    public var description: String { rawValue }
}

/// URDF origin，包含 xyz 平移與 rpy 旋轉。
public struct Origin: Sendable, Equatable {
    public var xyz: (x: Double, y: Double, z: Double)
    public var rpy: (roll: Double, pitch: Double, yaw: Double)

    public init(
        xyz: (x: Double, y: Double, z: Double) = (0, 0, 0),
        rpy: (roll: Double, pitch: Double, yaw: Double) = (0, 0, 0)
    ) {
        self.xyz = xyz
        self.rpy = rpy
    }

    public static func == (lhs: Origin, rhs: Origin) -> Bool {
        lhs.xyz.x == rhs.xyz.x && lhs.xyz.y == rhs.xyz.y && lhs.xyz.z == rhs.xyz.z &&
        lhs.rpy.roll == rhs.rpy.roll && lhs.rpy.pitch == rhs.rpy.pitch && lhs.rpy.yaw == rhs.rpy.yaw
    }
}

/// URDF visual mesh 參照。RoboSight 目前只允許 STL mesh。
public struct MeshRef: Sendable, Equatable {
    public var uri: String
    public var scale: (x: Double, y: Double, z: Double)?

    public init(uri: String, scale: (x: Double, y: Double, z: Double)? = nil) {
        self.uri = uri
        self.scale = scale
    }

    public static func == (lhs: MeshRef, rhs: MeshRef) -> Bool {
        guard lhs.uri == rhs.uri else { return false }
        switch (lhs.scale, rhs.scale) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return a.x == b.x && a.y == b.y && a.z == b.z
        default:
            return false
        }
    }
}

/// URDF visual material。RealityKit renderer 目前使用 color。
public struct RobotMaterial: Sendable, Equatable {
    public var name: String?
    public var color: (r: Double, g: Double, b: Double, a: Double)?

    public init(name: String? = nil, color: (r: Double, g: Double, b: Double, a: Double)? = nil) {
        self.name = name
        self.color = color
    }

    public static func == (lhs: RobotMaterial, rhs: RobotMaterial) -> Bool {
        guard lhs.name == rhs.name else { return false }
        switch (lhs.color, rhs.color) {
        case (nil, nil):
            return true
        case let (a?, b?):
            return a.r == b.r && a.g == b.g && a.b == b.b && a.a == b.a
        default:
            return false
        }
    }
}

/// URDF link。本階段只保留 visual，collision/inertial 先不納入產品功能。
public struct Link: Sendable, Equatable, Identifiable {
    public typealias ID = LinkID

    public var id: ID
    public var name: String { id.rawValue }
    public var visuals: [Visual]

    public init(name: String, visuals: [Visual] = []) {
        self.id = LinkID(rawValue: name)
        self.visuals = visuals
    }
}

/// URDF visual。每個 visual 對應一個 mesh、可選 origin 與 material。
public struct Visual: Sendable, Equatable {
    public var origin: Origin?
    public var meshRef: MeshRef
    public var material: RobotMaterial?

    public init(origin: Origin? = nil, meshRef: MeshRef, material: RobotMaterial? = nil) {
        self.origin = origin
        self.meshRef = meshRef
        self.material = material
    }
}

/// URDF joint。這裡保留完整運動學需要的 parent/child、origin、axis、limit 與 mimic。
public struct Joint: Sendable, Equatable, Identifiable {
    public typealias ID = JointID

    public var id: ID
    public var name: String { id.rawValue }
    public var type: JointType
    public var parentLink: Link.ID
    public var childLink: Link.ID
    public var origin: Origin?
    public var axis: Axis
    public var limit: JointLimit?
    public var mimic: Mimic?

    public init(
        name: String,
        type: JointType,
        parentLink: Link.ID,
        childLink: Link.ID,
        origin: Origin? = nil,
        axis: Axis = .defaultAxis,
        limit: JointLimit? = nil,
        mimic: Mimic? = nil
    ) {
        self.id = JointID(rawValue: name)
        self.type = type
        self.parentLink = parentLink
        self.childLink = childLink
        self.origin = origin
        self.axis = axis
        self.limit = limit
        self.mimic = mimic
    }
}

/// URDF joint type。本階段 FK 實作會處理 revolute、continuous、prismatic、fixed。
public enum JointType: String, Sendable, Equatable {
    case revolute
    case continuous
    case prismatic
    case fixed
    case floating
    case planar
}

/// Joint 運動軸。URDF 預設軸為 X 軸。
public struct Axis: Sendable, Equatable {
    public var xyz: (x: Double, y: Double, z: Double)

    public init(x: Double, y: Double, z: Double) {
        self.xyz = (x, y, z)
    }

    public static let defaultAxis = Axis(x: 1, y: 0, z: 0)

    public var vector: SIMD3<Double> {
        SIMD3<Double>(xyz.x, xyz.y, xyz.z)
    }

    public static func == (lhs: Axis, rhs: Axis) -> Bool {
        lhs.xyz.x == rhs.xyz.x && lhs.xyz.y == rhs.xyz.y && lhs.xyz.z == rhs.xyz.z
    }
}

/// Joint 限制。revolute/prismatic 的 slider 範圍會使用 lower/upper。
public struct JointLimit: Sendable, Equatable {
    public var lower: Double
    public var upper: Double
    public var effort: Double
    public var velocity: Double

    public init(lower: Double = 0, upper: Double = 0, effort: Double = 0, velocity: Double = 0) {
        self.lower = lower
        self.upper = upper
        self.effort = effort
        self.velocity = velocity
    }
}

/// URDF mimic joint 關係：目前 joint = driver joint * multiplier + offset。
public struct Mimic: Sendable, Equatable {
    public var jointName: JointID
    public var multiplier: Double
    public var offset: Double

    public init(jointName: JointID, multiplier: Double = 1.0, offset: Double = 0.0) {
        self.jointName = jointName
        self.multiplier = multiplier
        self.offset = offset
    }
}

/// RoboSight 內部使用的 URDF robot model。
public struct RobotModel: Sendable, Equatable {
    public var links: [Link]
    public var joints: [Joint]
    public var rootLink: Link.ID
    public var name: String

    public init(name: String, links: [Link], joints: [Joint], rootLink: Link.ID) {
        self.name = name
        self.links = links
        self.joints = joints
        self.rootLink = rootLink
    }
}

/// Robot model 的查表索引。`jointByID` 與 `parentJointByChild` 會給後續 joint slider / IK 使用。
public struct RobotModelIndex: Sendable {
    public let linkByID: [Link.ID: Link]
    public let jointByID: [Joint.ID: Joint]
    public let childJointsByParent: [Link.ID: [Joint]]
    public let parentJointByChild: [Link.ID: Joint]

    public init(robot: RobotModel) {
        self.linkByID = Dictionary(uniqueKeysWithValues: robot.links.map { ($0.id, $0) })
        self.jointByID = Dictionary(uniqueKeysWithValues: robot.joints.map { ($0.id, $0) })

        var childMap: [Link.ID: [Joint]] = [:]
        childMap.reserveCapacity(robot.links.count)

        var parentMap: [Link.ID: Joint] = [:]
        parentMap.reserveCapacity(robot.links.count)

        for joint in robot.joints {
            childMap[joint.parentLink, default: []].append(joint)
            parentMap[joint.childLink] = joint
        }

        self.childJointsByParent = childMap
        self.parentJointByChild = parentMap
    }
}

public extension RobotModel {
    func makeIndex() -> RobotModelIndex {
        RobotModelIndex(robot: self)
    }
}
