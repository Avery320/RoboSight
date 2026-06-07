import ARKit
import CoreVideo
import Foundation
import RealityKit
import simd

struct ARKitSensorStatus: Equatable {
    var isRunning: Bool
    var isSceneDepthSupported: Bool
    var hasSceneDepth: Bool
    var rgbResolution: CGSize?
    var depthResolution: CGSize?
    var framesPerSecond: Double
    var trackingStateDescription: String
}

extension ARKitSensorStatus {
    static let idle = ARKitSensorStatus(
        isRunning: false,
        isSceneDepthSupported: false,
        hasSceneDepth: false,
        rgbResolution: nil,
        depthResolution: nil,
        framesPerSecond: 0,
        trackingStateDescription: "Stopped"
    )
}

struct ARKitSensorFrame: Sendable {
    let arTimestamp: TimeInterval
    let unixTimestamp: TimeInterval
    let colorImage: ARFrameCompressedImageData
    let cameraMatrix: [Double]
    let cameraTransform: simd_float4x4
}

final class ARKitSensorView: ARView, ARSessionDelegate {
    var onStatusUpdate: ((ARKitSensorStatus) -> Void)?
    var onFrameUpdate: ((ARKitSensorFrame) -> Void)?

    private let targetPublishInterval: TimeInterval = 1.0 / 10.0
    private let colorImageScale: CGFloat = 0.5
    private let jpegCompressionQuality: CGFloat = 0.75

    private var sessionTimeOffset: TimeInterval?
    private var lastPublishTime: TimeInterval = 0
    private var frameCounter: Int = 0
    private var fpsStartTime: TimeInterval = CACurrentMediaTime()
    private var latestFPS: Double = 0
    private var latestTrackingStateDescription: String = "Not started"
    private var isSessionRunning = false
    private var isSceneDepthEnabled = false

    required init(frame frameRect: CGRect) {
        super.init(frame: frameRect)
        session.delegate = self
    }

    @MainActor required dynamic init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func startSession(isSceneDepthEnabled: Bool) {
        self.isSessionRunning = true
        self.isSceneDepthEnabled = isSceneDepthEnabled
        runSession()
    }

    func setSceneDepthEnabled(_ isEnabled: Bool) {
        guard isSessionRunning, isEnabled != isSceneDepthEnabled else { return }

        isSceneDepthEnabled = isEnabled
        runSession()
    }

    private func runSession() {
        let configuration = ARWorldTrackingConfiguration()
        if isSceneDepthEnabled && Self.isSceneDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        session.run(configuration)
        publishStatus(
            hasSceneDepth: false,
            rgbResolution: nil,
            depthResolution: nil
        )
    }

    func pauseSession() {
        isSessionRunning = false
        session.pause()
        publishStatus(
            isRunning: false,
            hasSceneDepth: false,
            rgbResolution: nil,
            depthResolution: nil
        )
    }

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let arTimestamp = frame.timestamp
        guard (arTimestamp - lastPublishTime) >= targetPublishInterval else { return }

        if sessionTimeOffset == nil {
            sessionTimeOffset = Date().timeIntervalSince1970 - arTimestamp
        }

        guard let sessionTimeOffset else { return }

        guard let colorImage = ARFrameExtractor.extractJPEGImageData(
            from: frame.capturedImage,
            scale: colorImageScale,
            compressionQuality: jpegCompressionQuality
        ) else { return }

        let depthResolution = frame.sceneDepth.map { sceneDepth in
            let depthMap = sceneDepth.depthMap
            return CGSize(
                width: CVPixelBufferGetWidth(depthMap),
                height: CVPixelBufferGetHeight(depthMap)
            )
        }

        let sensorFrame = ARKitSensorFrame(
            arTimestamp: arTimestamp,
            unixTimestamp: sessionTimeOffset + arTimestamp,
            colorImage: colorImage,
            cameraMatrix: ARFrameExtractor.scaledPortraitCameraMatrix(from: frame, scale: colorImageScale),
            cameraTransform: frame.camera.transform
        )

        onFrameUpdate?(sensorFrame)
        updateFPS()

        publishStatus(
            hasSceneDepth: depthResolution != nil,
            rgbResolution: CGSize(width: colorImage.width, height: colorImage.height),
            depthResolution: depthResolution
        )

        lastPublishTime = arTimestamp
    }

    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        latestTrackingStateDescription = String(describing: camera.trackingState)
    }

    private static var isSceneDepthSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    private func updateFPS() {
        frameCounter += 1
        let currentTime = CACurrentMediaTime()
        let elapsedTime = currentTime - fpsStartTime

        guard elapsedTime >= 1.0 else { return }

        latestFPS = Double(frameCounter) / elapsedTime
        frameCounter = 0
        fpsStartTime = currentTime
    }

    private func publishStatus(
        isRunning: Bool = true,
        hasSceneDepth: Bool,
        rgbResolution: CGSize?,
        depthResolution: CGSize?
    ) {
        let status = ARKitSensorStatus(
            isRunning: isRunning,
            isSceneDepthSupported: Self.isSceneDepthSupported,
            hasSceneDepth: hasSceneDepth,
            rgbResolution: rgbResolution,
            depthResolution: depthResolution,
            framesPerSecond: latestFPS,
            trackingStateDescription: latestTrackingStateDescription
        )

        DispatchQueue.main.async { [onStatusUpdate] in
            onStatusUpdate?(status)
        }
    }
}
