import RealityKit
import SwiftUI
import UIKit

/// RealityKit 機器人模型顯示 view。
///
/// 使用 non-AR `ARView`，因此不會啟動相機，也不會影響 Camera Tab 的 ARKit session。
struct RobotRealityView: UIViewRepresentable {
    let runtime: RobotRuntime
    let jointPositions: [String: Double]

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeUIView(context: Context) -> ARView {
        let view = ARView(
            frame: .zero,
            cameraMode: .nonAR,
            automaticallyConfigureSession: false
        )
        view.environment.background = .color(.systemBackground)
        context.coordinator.configureScene(in: view)
        context.coordinator.setupGestures(on: view)
        return view
    }

    func updateUIView(_ uiView: ARView, context: Context) {
        context.coordinator.updateJointPositions(jointPositions)
        context.coordinator.load(runtime: runtime, in: uiView)
        context.coordinator.updateJoints(in: uiView)
    }

    static func dismantleUIView(_ uiView: ARView, coordinator: Coordinator) {
        coordinator.cancelLoading()
        uiView.scene.anchors.removeAll()
    }

    @MainActor
    final class Coordinator: NSObject {
        private let renderer = RealityKitRobotRenderer()
        // 用 ObjectIdentifier 區分同一個 runtime 是否已在 RealityKit 畫面中完成載入。
        private var loadingRuntimeID: ObjectIdentifier?
        private var renderedRuntimeID: ObjectIdentifier?
        private var loadTask: Task<Void, Never>?
        
        private weak var rootAnchor: AnchorEntity?
        private weak var pivotAnchor: Entity?
        
        private var activeRuntime: RobotRuntime?
        private var currentJointPositions: [String: Double] = [:]
        
        // 畫面操作狀態
        private var viewYaw: Float = .pi
        private var viewPitch: Float = 0.35
        private var viewScale: Float = 1.0
        private var viewPan: SIMD3<Float> = .zero

        private var panStartLocation: CGPoint?

        func configureScene(in view: ARView) {
            view.scene.anchors.removeAll()

            let root = AnchorEntity(world: .zero)
            root.name = "robot_scene_root"

            let camera = PerspectiveCamera()
            camera.name = "robot_camera"
            camera.position = SIMD3<Float>(0, 1.6, 4.0)
            camera.look(
                at: SIMD3<Float>(0, 0.6, 0),
                from: camera.position,
                relativeTo: nil
            )
            root.addChild(camera)

            let light = DirectionalLight()
            light.name = "robot_light"
            light.light.intensity = 3_000
            light.orientation = simd_quatf(
                angle: -.pi / 4,
                axis: SIMD3<Float>(1, 0, 0)
            )
            root.addChild(light)

            let pivot = Entity()
            pivot.name = "robot_pivot"
            root.addChild(pivot)

            // 加入平面網格與座標軸，提供模型尺度與方向參考。
            let gridEntity = makeGridEntity()
            pivot.addChild(gridEntity)

            view.scene.addAnchor(root)
            self.rootAnchor = root
            self.pivotAnchor = pivot
            
            updatePivotTransform()
        }

        private func makeGridEntity() -> Entity {
            let grid = Entity()
            grid.name = "world_grid"
            
            let lineThickness: Float = 0.002
            let gridExtent: Int = 5 // 10m x 10m 網格，從 -5 到 +5。
            let lineMaterial = SimpleMaterial(color: UIColor(white: 0.5, alpha: 1.0), isMetallic: false)

            // 產生 1m 間距的網格線
            for i in -gridExtent...gridExtent {
                let position = Float(i)
                
                // X 方向的線：與 X 軸平行，沿 Z 位移。
                let xLine = ModelEntity(
                    mesh: .generateBox(size: SIMD3<Float>(Float(gridExtent * 2), lineThickness, lineThickness)),
                    materials: [lineMaterial]
                )
                xLine.position = SIMD3<Float>(0, 0, position)
                grid.addChild(xLine)
                
                // Z 方向的線：與 Z 軸平行，沿 X 位移。
                let zLine = ModelEntity(
                    mesh: .generateBox(size: SIMD3<Float>(lineThickness, lineThickness, Float(gridExtent * 2))),
                    materials: [lineMaterial]
                )
                zLine.position = SIMD3<Float>(position, 0, 0)
                grid.addChild(zLine)
            }

            // 中心座標軸 (比一般網格線粗，凸顯原點，長度 1m)
            let axisLength: Float = 1.0
            let axisThickness: Float = 0.006

            // X 軸：紅色。
            let xAxis = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(axisLength, axisThickness, axisThickness)), materials: [SimpleMaterial(color: .red, isMetallic: false)])
            xAxis.position = SIMD3<Float>(axisLength / 2, 0, 0)
            grid.addChild(xAxis)

            // Y 軸：綠色。
            let yAxis = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(axisThickness, axisLength, axisThickness)), materials: [SimpleMaterial(color: .green, isMetallic: false)])
            yAxis.position = SIMD3<Float>(0, axisLength / 2, 0)
            grid.addChild(yAxis)

            // Z 軸：藍色。
            let zAxis = ModelEntity(mesh: .generateBox(size: SIMD3<Float>(axisThickness, axisThickness, axisLength)), materials: [SimpleMaterial(color: .blue, isMetallic: false)])
            zAxis.position = SIMD3<Float>(0, 0, axisLength / 2)
            grid.addChild(zAxis)

            return grid
        }
        
        func setupGestures(on view: ARView) {
            // 長按拖曳用於平移視角。
            let panGesture = UILongPressGestureRecognizer(target: self, action: #selector(handlePan(_:)))
            panGesture.numberOfTapsRequired = 1
            panGesture.minimumPressDuration = 0.05
            view.addGestureRecognizer(panGesture)

            // 單指拖曳用於旋轉視角，需等平移手勢判定失敗後才啟動，避免衝突。
            let rotateGesture = UIPanGestureRecognizer(target: self, action: #selector(handleRotate(_:)))
            rotateGesture.maximumNumberOfTouches = 1
            rotateGesture.require(toFail: panGesture)
            view.addGestureRecognizer(rotateGesture)

            // 雙指縮放視角。
            let pinchGesture = UIPinchGestureRecognizer(target: self, action: #selector(handlePinch(_:)))
            view.addGestureRecognizer(pinchGesture)
        }

        @objc private func handleRotate(_ gesture: UIPanGestureRecognizer) {
            guard let view = gesture.view else { return }
            let translation = gesture.translation(in: view)
            gesture.setTranslation(.zero, in: view)

            if gesture.state == .changed {
                viewYaw += Float(translation.x) * 0.01
                viewPitch += Float(translation.y) * 0.01
                viewPitch = min(max(viewPitch, -1.2), 1.2)
                updatePivotTransform()
            }
        }

        @objc private func handlePan(_ gesture: UILongPressGestureRecognizer) {
            guard let view = gesture.view else { return }
            let location = gesture.location(in: view)

            switch gesture.state {
            case .began:
                panStartLocation = location
            case .changed:
                guard let startLocation = panStartLocation else { return }
                let dx = Float(location.x - startLocation.x)
                let dy = Float(location.y - startLocation.y)
                let metersPerPoint: Float = 0.01 / max(viewScale, 0.05)
                viewPan.x += dx * metersPerPoint
                viewPan.y -= dy * metersPerPoint
                panStartLocation = location
                updatePivotTransform()
            case .ended, .cancelled:
                panStartLocation = nil
            default: break
            }
        }

        @objc private func handlePinch(_ gesture: UIPinchGestureRecognizer) {
            if gesture.state == .changed {
                viewScale *= Float(gesture.scale)
                viewScale = min(max(viewScale, 0.05), 20.0)
                gesture.scale = 1.0
                updatePivotTransform()
            }
        }

        private func updatePivotTransform() {
            guard let pivot = pivotAnchor else { return }
            // 旋轉順序固定為 pitch * yaw，避免側面視角上下拖曳時產生非預期 roll。
            pivot.transform = Transform(
                scale: SIMD3<Float>(repeating: viewScale),
                rotation: simd_quatf(angle: viewPitch, axis: SIMD3<Float>(1, 0, 0))
                        * simd_quatf(angle: viewYaw, axis: SIMD3<Float>(0, 1, 0)),
                translation: viewPan
            )
        }

        func load(runtime: RobotRuntime, in view: ARView) {
            let runtimeID = ObjectIdentifier(runtime)
            guard renderedRuntimeID != runtimeID,
                  loadingRuntimeID != runtimeID else {
                return
            }

            loadingRuntimeID = runtimeID
            loadTask?.cancel()
            loadTask = Task { @MainActor [weak self, weak view] in
                guard let self, let view else { return }

                do {
                    try Task.checkCancellation()
                    let entity = try await renderer.buildEntities(runtime: runtime)
                    try Task.checkCancellation()
                    self.attachRobotEntity(entity, to: view)
                    self.renderedRuntimeID = runtimeID
                    self.activeRuntime = runtime
                    self.loadingRuntimeID = nil
                    self.updateJoints(in: view)
                } catch is CancellationError {
                    if self.loadingRuntimeID == runtimeID {
                        self.loadingRuntimeID = nil
                    }
                } catch {
                    // 載入失敗會由 RobotViewModel 呈現；這裡只避免 RealityKit view 崩潰。
                    if self.loadingRuntimeID == runtimeID {
                        self.loadingRuntimeID = nil
                    }
                }
            }
        }

        func cancelLoading() {
            loadTask?.cancel()
            loadTask = nil
            loadingRuntimeID = nil
            activeRuntime = nil
        }

        private func attachRobotEntity(_ entity: Entity, to view: ARView) {
            guard let pivot = pivotAnchor else { return }

            for child in pivot.children where child.name.hasPrefix("robot_") {
                child.removeFromParent()
            }

            entity.transform = urdfToRealityKitRootTransform
            pivot.addChild(entity)
        }

        func updateJointPositions(_ positions: [String: Double]) {
            self.currentJointPositions = positions
        }

        func updateJoints(in view: ARView) {
            guard let runtime = activeRuntime,
                  let pivot = pivotAnchor,
                  let root = pivot.children.first(where: { $0.name.hasPrefix("robot_") }) else {
                return
            }

            var jointPos: [Joint.ID: Double] = [:]
            for (name, val) in currentJointPositions {
                jointPos[Joint.ID(rawValue: name)] = val
            }

            do {
                let poses = try runtime.linkPoses(jointPositionsByID: jointPos)
                renderer.updateTransforms(entityRoot: root, linkPoses: poses)
            } catch {
                print("Failed to update joint poses: \(error)")
            }
        }

        private var urdfToRealityKitRootTransform: Transform {
            // URDF / ROS 慣例：+X forward、+Y left、+Z up。
            // RealityKit 慣例：+X right、+Y up、-Z forward。
            let matrix = simd_float3x3(
                SIMD3<Float>(0, 0, -1),
                SIMD3<Float>(-1, 0, 0),
                SIMD3<Float>(0, 1, 0)
            )
            return Transform(scale: .one, rotation: simd_quatf(matrix), translation: .zero)
        }
    }
}
