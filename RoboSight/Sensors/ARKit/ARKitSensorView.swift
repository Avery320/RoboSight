import ARKit
import CoreVideo
import Foundation
import RealityKit
import simd

/// ARKit 感測來源的執行時狀態。
///
/// 這裡只描述設備端 camera / depth 可用性，不應包含 ROS topic 狀態或傳輸層細節。
struct ARKitSensorStatus: Equatable {
    var isRunning: Bool
    var isSceneDepthSupported: Bool
    var hasSceneDepth: Bool
    var hasConfidenceMap: Bool
    var rgbResolution: CGSize?
    var depthResolution: CGSize?
    var confidenceResolution: CGSize?
    var framesPerSecond: Double
    var trackingStateDescription: String
}

extension ARKitSensorStatus {
    /// ARKit session 啟動前或停止後的預設狀態。
    static let idle = ARKitSensorStatus(
        isRunning: false,
        isSceneDepthSupported: false,
        hasSceneDepth: false,
        hasConfidenceMap: false,
        rgbResolution: nil,
        depthResolution: nil,
        confidenceResolution: nil,
        framesPerSecond: 0,
        trackingStateDescription: "Stopped"
    )
}

/// 單次同步的 ARKit 感測更新。
///
/// `rawCameraFrame` 是穩定的相機原始資料 API 輸出；
/// `cameraImage` 是由 raw frame 轉出的相機影像 API 輸出。
/// depth 欄位保持 optional，因為 scene depth 只在支援 LiDAR 的設備上可用。
struct ARKitSensorFrame {
    let arTimestamp: TimeInterval
    let rawCameraFrame: CameraRawFrame
    let cameraImage: CameraImageFrame
    let depthImage: ARDepthFrameData?
    let confidenceImage: ARDepthFrameData?
}

/// 由 ARKit 驅動的感測來源與預覽 view。
///
/// 職責：
/// - 啟動 / 停止 ARKit world tracking。
/// - 在設備支援 LiDAR 時啟用 scene depth。
/// - 將 ARKit 影格轉成 RoboSight raw sensor model。
/// - 將設備端狀態回報給 SwiftUI。
final class ARKitSensorView: ARView, ARSessionDelegate {
    var onStatusUpdate: ((ARKitSensorStatus) -> Void)?
    var onFrameUpdate: ((ARKitSensorFrame) -> Void)?

    /// 目前相機發送頻率。這會同時節流 ROS 影像發送與本來源的狀態更新。
    private let targetPublishInterval: TimeInterval = 1.0 / 10.0

    /// 預覽來源感測輸出共用的相機影像 API 設定。
    private let cameraImageConfiguration = CameraImageProcessingConfiguration.standard

    /// 用於將 ARKit session 相對時間轉成 Unix time 的 offset。
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

    /// 此 view 由 SwiftUI 建立，因此不支援 storyboard 初始化。
    @MainActor required dynamic init?(coder decoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// 啟動 ARKit session，並視需求請求 scene depth。
    func startSession(isSceneDepthEnabled: Bool) {
        self.isSessionRunning = true
        self.isSceneDepthEnabled = isSceneDepthEnabled
        runSession()
    }

    /// 僅在 scene-depth 設定實際改變時重新執行 ARKit。
    func setSceneDepthEnabled(_ isEnabled: Bool) {
        guard isSessionRunning, isEnabled != isSceneDepthEnabled else { return }

        isSceneDepthEnabled = isEnabled
        runSession()
    }

    /// 建立並執行 ARKit world-tracking 設定。
    private func runSession() {
        let configuration = ARWorldTrackingConfiguration()
        if isSceneDepthEnabled && Self.isSceneDepthSupported {
            configuration.frameSemantics.insert(.sceneDepth)
        }

        session.run(configuration)
        publishStatus(
            hasSceneDepth: false,
            hasConfidenceMap: false,
            rgbResolution: nil,
            depthResolution: nil,
            confidenceResolution: nil
        )
    }

    /// 停止感測串流並重置已發布的感測狀態。
    func pauseSession() {
        isSessionRunning = false
        session.pause()
        publishStatus(
            isRunning: false,
            hasSceneDepth: false,
            hasConfidenceMap: false,
            rgbResolution: nil,
            depthResolution: nil,
            confidenceResolution: nil
        )
    }

    /// 接收 ARKit frame，先轉成 raw sensor model，再建立產品功能需要的資料。
    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        let arTimestamp = frame.timestamp
        guard (arTimestamp - lastPublishTime) >= targetPublishInterval else { return }

        if sessionTimeOffset == nil {
            sessionTimeOffset = Date().timeIntervalSince1970 - arTimestamp
        }

        guard let sessionTimeOffset else { return }

        let unixTimestamp = sessionTimeOffset + arTimestamp
        let rawCameraFrame = CameraRawFrame(
            timestamp: unixTimestamp,
            pixelBuffer: frame.capturedImage,
            imageResolution: frame.camera.imageResolution,
            cameraIntrinsics: frame.camera.intrinsics,
            cameraTransform: frame.camera.transform
        )

        // 相機影像 API 從 raw frame 產生 JPEG 與對齊後的 camera matrix。
        guard let cameraImage = CameraImageProcessor.makeFrame(
            from: rawCameraFrame,
            configuration: cameraImageConfiguration
        ) else { return }

        // depth 擷取是 optional；不支援的設備會直接輸出 nil depth 欄位。
        let depthImage = frame.sceneDepth.flatMap(ARDepthFrameExtractor.extractDepthData)
        let confidenceImage = frame.sceneDepth.flatMap(ARDepthFrameExtractor.extractConfidenceData)

        let sensorFrame = ARKitSensorFrame(
            arTimestamp: arTimestamp,
            rawCameraFrame: rawCameraFrame,
            cameraImage: cameraImage,
            depthImage: depthImage,
            confidenceImage: confidenceImage
        )

        onFrameUpdate?(sensorFrame)
        updateFPS()

        publishStatus(
            hasSceneDepth: depthImage != nil,
            hasConfidenceMap: confidenceImage != nil,
            rgbResolution: CGSize(width: cameraImage.image.width, height: cameraImage.image.height),
            depthResolution: Self.resolution(from: depthImage),
            confidenceResolution: Self.resolution(from: confidenceImage)
        )

        lastPublishTime = arTimestamp
    }

    /// 追蹤 ARKit 定位品質，用於 UI 診斷。
    func session(_ session: ARSession, cameraDidChangeTrackingState camera: ARCamera) {
        latestTrackingStateDescription = String(describing: camera.trackingState)
    }

    /// 檢查硬體是否支援 LiDAR scene depth。
    private static var isSceneDepthSupported: Bool {
        ARWorldTrackingConfiguration.supportsFrameSemantics(.sceneDepth)
    }

    /// 將 depth payload metadata 轉成 UI 友善的解析度。
    private static func resolution(from image: ARDepthFrameData?) -> CGSize? {
        guard let image else { return nil }
        return CGSize(width: image.width, height: image.height)
    }

    /// 測量節流後的來源影格吞吐量。
    private func updateFPS() {
        frameCounter += 1
        let currentTime = CACurrentMediaTime()
        let elapsedTime = currentTime - fpsStartTime

        guard elapsedTime >= 1.0 else { return }

        latestFPS = Double(frameCounter) / elapsedTime
        frameCounter = 0
        fpsStartTime = currentTime
    }

    /// 在 main queue 將狀態更新回傳給 SwiftUI。
    private func publishStatus(
        isRunning: Bool = true,
        hasSceneDepth: Bool,
        hasConfidenceMap: Bool,
        rgbResolution: CGSize?,
        depthResolution: CGSize?,
        confidenceResolution: CGSize?
    ) {
        let status = ARKitSensorStatus(
            isRunning: isRunning,
            isSceneDepthSupported: Self.isSceneDepthSupported,
            hasSceneDepth: hasSceneDepth,
            hasConfidenceMap: hasConfidenceMap,
            rgbResolution: rgbResolution,
            depthResolution: depthResolution,
            confidenceResolution: confidenceResolution,
            framesPerSecond: latestFPS,
            trackingStateDescription: latestTrackingStateDescription
        )

        DispatchQueue.main.async { [onStatusUpdate] in
            onStatusUpdate?(status)
        }
    }
}
