import ARKit
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

struct ARKitSensorFrame {
    let arTimestamp: TimeInterval
    let unixTimestamp: TimeInterval
    let rgbImage: ARFrameImageData
    let depthImage: ARFrameImageData?
    let cameraMatrix: [Double]
    let cameraTransform: simd_float4x4
}

final class ARKitSensorView: ARView, ARSessionDelegate {
    var onStatusUpdate: ((ARKitSensorStatus) -> Void)?
    var onFrameUpdate: ((ARKitSensorFrame) -> Void)?

    private let targetPublishInterval: TimeInterval = 1.0 / 10.0
    private let rgbScale: CGFloat = 0.1
    private let depthScale: CGFloat = 0.75

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

        let rgbImage = ARFrameExtractor.extractDownsampledRGB8Data(
            from: frame.capturedImage,
            scale: rgbScale
        )

        let depthImage = frame.sceneDepth.map {
            ARFrameExtractor.extractDownscaledDepthData(from: $0, scale: depthScale)
        }

        let sensorFrame = ARKitSensorFrame(
            arTimestamp: arTimestamp,
            unixTimestamp: sessionTimeOffset + arTimestamp,
            rgbImage: rgbImage,
            depthImage: depthImage,
            cameraMatrix: ARFrameExtractor.scaledCameraMatrix(from: frame, scale: rgbScale),
            cameraTransform: frame.camera.transform
        )

        onFrameUpdate?(sensorFrame)
        updateFPS()

        publishStatus(
            hasSceneDepth: depthImage != nil,
            rgbResolution: CGSize(width: rgbImage.width, height: rgbImage.height),
            depthResolution: depthImage.map { CGSize(width: $0.width, height: $0.height) }
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
