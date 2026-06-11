import Foundation
import RealityKit
import simd

#if canImport(AppKit)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Robot 顯示階段需要的完整 runtime。
///
/// 這個型別是 URDF model、asset resolver、mesh loader、mimic resolver 與 FK 的邊界；
/// View/Renderer 不直接碰底層演算法，避免 UI 層出現補丁式邏輯。
public final class RobotRuntime: @unchecked Sendable {
    public let robot: RobotModel
    public let modelIndex: RobotModelIndex
    public let assetResolver: AssetResolver
    public let meshLoader: MeshLoader
    public let jointIndex: JointIndex

    private let mimicResolver: MimicResolver
    private let forwardKinematics: ForwardKinematics
    private let scene: RobotSceneDescription

    public init(
        robot: RobotModel,
        assetResolver: AssetResolver,
        meshLoader: MeshLoader
    ) throws {
        self.robot = robot
        self.modelIndex = robot.makeIndex()
        self.assetResolver = assetResolver
        self.jointIndex = JointIndex(robot: robot)
        self.mimicResolver = MimicResolver(jointIndex: jointIndex)
        self.forwardKinematics = try ForwardKinematics(robot: robot)
        self.meshLoader = meshLoader
        self.scene = RobotSceneDescription(robot: robot, index: modelIndex)
    }

    public func linkPoses(jointPositionsByID jointPositions: [Joint.ID: Double]) throws -> [Link.ID: Transform3D] {
        // 外部只需要傳入可控制 joint；mimic joint 與未指定 joint 在 runtime 內統一補齊。
        var independentPositions = zeroIndependentJointPositions()
        for (jointID, position) in jointPositions {
            independentPositions[jointID] = position
        }

        let fullPositions = try mimicResolver.expand(independent: independentPositions)
        return try forwardKinematics.linkPoses(jointPositionsByID: fullPositions)
    }

    fileprivate func initialLinkPoses() throws -> [Link.ID: Transform3D] {
        try linkPoses(jointPositionsByID: [:])
    }

    fileprivate func sceneDescription() -> RobotSceneDescription {
        scene
    }

    private func zeroIndependentJointPositions() -> [Joint.ID: Double] {
        Dictionary(uniqueKeysWithValues: jointIndex.independent.map { ($0, 0.0) })
    }
}

/// 將 RoboSight URDF runtime 轉成 RealityKit entity tree。
public final class RealityKitRobotRenderer: @unchecked Sendable {
    public init() {}

    @MainActor
    public func buildEntities(runtime: RobotRuntime) async throws -> Entity {
        try Task.checkCancellation()

        // Entity 階層依照 URDF link tree 建立；初始姿態由 FK 以 zero joint position 算出。
        let scene = runtime.sceneDescription()
        let poses = try runtime.initialLinkPoses()

        let rootEntity = Entity()
        rootEntity.name = "robot_\(runtime.robot.name)"

        try await buildEntityTree(
            node: scene.rootNode,
            parentEntity: rootEntity,
            parentWorldPose: .identity,
            scene: scene,
            poses: poses,
            runtime: runtime
        )

        return rootEntity
    }

    @MainActor
    public func updateTransforms(entityRoot: Entity, linkPoses: [Link.ID: Transform3D]) {
        updateEntityTransforms(entity: entityRoot, parentWorldPose: .identity, linkPoses: linkPoses)
    }

    @MainActor
    private func buildEntityTree(
        node: RobotNode,
        parentEntity: Entity,
        parentWorldPose: Transform3D,
        scene: RobotSceneDescription,
        poses: [Link.ID: Transform3D],
        runtime: RobotRuntime
    ) async throws {
        try Task.checkCancellation()

        let linkEntity = Entity()
        linkEntity.name = "link_\(node.linkID)"

        if let worldPose = poses[node.linkID] {
            let localPose = parentWorldPose.inverse.composed(with: worldPose)
            linkEntity.transform = realityKitTransform(from: localPose)
        }

        if let meshes = scene.meshes[node.linkID] {
            for (index, mesh) in meshes.enumerated() {
                try Task.checkCancellation()
                let geoEntity = try await createMeshEntity(mesh, runtime: runtime)
                geoEntity.name = "geo_\(node.linkID)_\(index)"

                if let link = runtime.modelIndex.linkByID[node.linkID],
                   index < link.visuals.count,
                   let origin = link.visuals[index].origin {
                    // visual origin 是 mesh 相對於 link 的局部 transform，不能混入 link FK。
                    let originTransform = transformFromOrigin(xyz: origin.xyz, rpy: origin.rpy)
                    var transform = realityKitTransform(from: originTransform)
                    transform.scale = geoEntity.transform.scale
                    geoEntity.transform = transform
                }

                linkEntity.addChild(geoEntity)
            }
        }

        parentEntity.addChild(linkEntity)

        let thisWorldPose = poses[node.linkID] ?? parentWorldPose
        for child in node.children {
            try await buildEntityTree(
                node: child,
                parentEntity: linkEntity,
                parentWorldPose: thisWorldPose,
                scene: scene,
                poses: poses,
                runtime: runtime
            )
        }
    }

    @MainActor
    private func createMeshEntity(_ mesh: RenderableMesh, runtime: RobotRuntime) async throws -> Entity {
        let entity = Entity()
        let meshData = try await runtime.meshLoader.loadMesh(
            for: mesh.meshRef,
            resolver: runtime.assetResolver
        )
        let meshResource = try meshDataToMeshResource(meshData)
        let material = makeMaterial(from: mesh.material)
        entity.components.set(ModelComponent(mesh: meshResource, materials: [material]))

        if let scale = mesh.meshRef.scale {
            entity.scale = SIMD3<Float>(Float(scale.x), Float(scale.y), Float(scale.z))
        }

        return entity
    }

    @MainActor
    private func makeMaterial(from material: RobotMaterial?) -> RealityKit.Material {
        guard let material, let color = material.color else {
            return SimpleMaterial(color: .gray, isMetallic: false)
        }

        #if canImport(UIKit)
        let platformColor = UIColor(
            red: CGFloat(color.r),
            green: CGFloat(color.g),
            blue: CGFloat(color.b),
            alpha: CGFloat(color.a)
        )
        #elseif canImport(AppKit)
        let platformColor = NSColor(
            red: CGFloat(color.r),
            green: CGFloat(color.g),
            blue: CGFloat(color.b),
            alpha: CGFloat(color.a)
        )
        #endif

        return SimpleMaterial(color: platformColor, isMetallic: false)
    }

    @MainActor
    private func meshDataToMeshResource(_ meshData: MeshData) throws -> MeshResource {
        var descriptor = MeshDescriptor(name: "urdfMesh")
        descriptor.positions = MeshBuffer(meshData.positions)
        descriptor.normals = MeshBuffer(meshData.normals)
        descriptor.primitives = .triangles(meshData.indices)
        return try MeshResource.generate(from: [descriptor])
    }

    @MainActor
    private func updateEntityTransforms(
        entity: Entity,
        parentWorldPose: Transform3D,
        linkPoses: [Link.ID: Transform3D]
    ) {
        var nextParentWorldPose = parentWorldPose

        if entity.name.hasPrefix("link_") {
            // 更新時只改 link entity；visual mesh entity 保留自己的 visual origin。
            let linkID = LinkID(rawValue: String(entity.name.dropFirst(5)))
            if let worldPose = linkPoses[linkID] {
                let localPose = parentWorldPose.inverse.composed(with: worldPose)
                entity.transform = realityKitTransform(from: localPose)
                nextParentWorldPose = worldPose
            }
        }

        for child in entity.children {
            updateEntityTransforms(
                entity: child,
                parentWorldPose: nextParentWorldPose,
                linkPoses: linkPoses
            )
        }
    }

    @MainActor
    private func realityKitTransform(from pose: Transform3D) -> Transform {
        Transform(
            scale: .one,
            rotation: simd_quatf(
                ix: Float(pose.rotation.imag.x),
                iy: Float(pose.rotation.imag.y),
                iz: Float(pose.rotation.imag.z),
                r: Float(pose.rotation.real)
            ),
            translation: SIMD3<Float>(pose.translation)
        )
    }
}

/// 預先整理 renderer 需要的 link tree 與 link -> visual mesh 對照。
fileprivate struct RobotSceneDescription {
    var rootNode: RobotNode
    var meshes: [Link.ID: [RenderableMesh]]

    init(robot: RobotModel, index: RobotModelIndex) {
        self.rootNode = Self.nodeTree(index: index, linkID: robot.rootLink)

        var meshes: [Link.ID: [RenderableMesh]] = [:]
        for link in robot.links {
            let renderableMeshes = link.visuals.map {
                RenderableMesh(meshRef: $0.meshRef, material: $0.material)
            }
            if !renderableMeshes.isEmpty {
                meshes[link.id] = renderableMeshes
            }
        }
        self.meshes = meshes
    }

    private static func nodeTree(index: RobotModelIndex, linkID: Link.ID) -> RobotNode {
        let children = (index.childJointsByParent[linkID] ?? []).map { joint in
            nodeTree(index: index, linkID: joint.childLink)
        }
        return RobotNode(linkID: linkID, children: children)
    }
}

fileprivate struct RobotNode {
    var linkID: Link.ID
    var children: [RobotNode]
}

fileprivate struct RenderableMesh {
    var meshRef: MeshRef
    var material: RobotMaterial?
}
