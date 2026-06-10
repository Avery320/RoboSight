import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UIKit

/// 相機影像 API 的影像處理設定。
///
/// 這些數值會同時影響傳輸影像尺寸與相機矩陣縮放。
struct CameraImageProcessingConfiguration: Sendable {
    /// 修正影像方向後套用的輸出縮放比例。
    let scale: CGFloat

    /// JPEG 壓縮品質，範圍為 0.0 到 1.0。
    let compressionQuality: CGFloat

    /// 目前針對 ROS 視覺化延遲與 payload 大小調整的基準設定。
    static let standard = CameraImageProcessingConfiguration(
        scale: 0.5,
        compressionQuality: 0.75
    )
}

/// 將相機原始感測資料轉成 RoboSight 穩定的相機影像 API 模型。
///
/// 這個處理器不直接依賴 ARKit frame，而是消費 `CameraRawFrame`。
/// 影像壓縮與直式矩陣重映射集中在這裡，讓 ROS 與產品功能不需要重複實作。
struct CameraImageProcessor {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// 從單一相機原始 frame 建立相機影像 frame。
    static func makeFrame(
        from rawFrame: CameraRawFrame,
        configuration: CameraImageProcessingConfiguration = .standard
    ) -> CameraImageFrame? {
        guard let image = makeCompressedImage(
            from: rawFrame.pixelBuffer,
            scale: configuration.scale,
            compressionQuality: configuration.compressionQuality
        ) else {
            return nil
        }

        return CameraImageFrame(
            timestamp: rawFrame.timestamp,
            image: image,
            cameraMatrix: portraitCameraMatrix(from: rawFrame, scale: configuration.scale),
            cameraTransform: rawFrame.cameraTransform
        )
    }

    /// 將相機來源提供的 pixel buffer 編碼成直式 JPEG 影像。
    private static func makeCompressedImage(
        from pixelBuffer: CVPixelBuffer,
        scale: CGFloat,
        compressionQuality: CGFloat
    ) -> CameraCompressedImageData? {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)

        // RoboSight 目前將相機輸出標準化為直式。
        // 相同的方向假設也必須反映在 `portraitCameraMatrix`。
        let scaledImage = sourceImage
            .oriented(.right)
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        let extent = scaledImage.extent.integral
        let width = max(1, Int(extent.width))
        let height = max(1, Int(extent.height))
        let outputImage = scaledImage.transformed(
            by: CGAffineTransform(translationX: -extent.origin.x, y: -extent.origin.y)
        )

        guard let cgImage = ciContext.createCGImage(
            outputImage,
            from: CGRect(x: 0, y: 0, width: width, height: height)
        ) else {
            return nil
        }

        let quality = min(max(compressionQuality, 0), 1)
        guard let data = UIImage(cgImage: cgImage).jpegData(compressionQuality: quality) else {
            return nil
        }

        return CameraCompressedImageData(data: data, width: width, height: height)
    }

    /// 將來源相機內參重映射到 RoboSight 的直式編碼影像。
    ///
    /// 這可以讓 `/camera_info` 與發送到 ROS 的 JPEG 保持一致。
    private static func portraitCameraMatrix(from rawFrame: CameraRawFrame, scale: CGFloat) -> [Double] {
        let intrinsics = rawFrame.cameraIntrinsics
        let scaleValue = Double(scale)
        let scaledImageHeight = Double(rawFrame.imageResolution.height) * scaleValue

        let fx = Double(intrinsics[0, 0]) * scaleValue
        let fy = Double(intrinsics[1, 1]) * scaleValue
        let cx = Double(intrinsics[2, 0]) * scaleValue
        let cy = Double(intrinsics[2, 1]) * scaleValue

        return [
            fy, 0.0, scaledImageHeight - 1.0 - cy,
            0.0, fx, cx,
            0.0, 0.0, 1.0
        ]
    }
}
