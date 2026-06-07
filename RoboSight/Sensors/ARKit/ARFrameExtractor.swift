import ARKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation
import UIKit

struct ARFrameCompressedImageData: Sendable {
    let data: Data
    let width: Int
    let height: Int
}

struct ARFrameExtractor {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func extractJPEGImageData(
        from pixelBuffer: CVPixelBuffer,
        scale: CGFloat = 0.5,
        compressionQuality: CGFloat = 0.75
    ) -> ARFrameCompressedImageData? {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
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

        return ARFrameCompressedImageData(data: data, width: width, height: height)
    }

    static func scaledPortraitCameraMatrix(from frame: ARFrame, scale: CGFloat) -> [Double] {
        let intrinsics = frame.camera.intrinsics
        let scaleValue = Double(scale)
        let scaledImageHeight = Double(frame.camera.imageResolution.height) * scaleValue

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
