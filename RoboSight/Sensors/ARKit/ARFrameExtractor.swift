import ARKit
import CoreGraphics
import CoreImage
import CoreVideo
import Foundation

struct ARFrameImageData {
    let data: Data
    let width: Int
    let height: Int
    let bytesPerPixel: Int

    var step: Int {
        width * bytesPerPixel
    }
}

struct ARFrameExtractor {
    private static let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    static func extractRawDepthData(from depthData: ARDepthData) -> ARFrameImageData {
        let depthPixelBuffer = depthData.depthMap
        let width = CVPixelBufferGetWidth(depthPixelBuffer)
        let height = CVPixelBufferGetHeight(depthPixelBuffer)

        CVPixelBufferLockBaseAddress(depthPixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(depthPixelBuffer, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(depthPixelBuffer) else {
            return ARFrameImageData(data: Data(), width: width, height: height, bytesPerPixel: MemoryLayout<Float32>.size)
        }

        let byteCount = width * height * MemoryLayout<Float32>.size
        return ARFrameImageData(
            data: Data(bytes: baseAddress, count: byteCount),
            width: width,
            height: height,
            bytesPerPixel: MemoryLayout<Float32>.size
        )
    }

    static func extractDownscaledDepthData(from depthData: ARDepthData, scale: CGFloat = 0.75) -> ARFrameImageData {
        let depthPixelBuffer = depthData.depthMap
        let sourceImage = CIImage(cvPixelBuffer: depthPixelBuffer)

        let width = max(1, Int(CGFloat(CVPixelBufferGetWidth(depthPixelBuffer)) * scale))
        let height = max(1, Int(CGFloat(CVPixelBufferGetHeight(depthPixelBuffer)) * scale))
        let rowBytes = width * MemoryLayout<Float32>.size

        var data = Data(count: rowBytes * height)
        let scaledImage = sourceImage
            .samplingNearest()
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ciContext.render(
                scaledImage,
                toBitmap: baseAddress,
                rowBytes: rowBytes,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .Rf,
                colorSpace: nil
            )
        }

        return ARFrameImageData(
            data: data,
            width: width,
            height: height,
            bytesPerPixel: MemoryLayout<Float32>.size
        )
    }

    static func extractDownsampledRGB8Data(from pixelBuffer: CVPixelBuffer, scale: CGFloat = 0.1) -> ARFrameImageData {
        let sourceImage = CIImage(cvPixelBuffer: pixelBuffer)
        let width = max(1, Int(CGFloat(CVPixelBufferGetWidth(pixelBuffer)) * scale))
        let height = max(1, Int(CGFloat(CVPixelBufferGetHeight(pixelBuffer)) * scale))

        let rgbaBytesPerPixel = 4
        var rgbaData = Data(count: width * height * rgbaBytesPerPixel)
        let scaledImage = sourceImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))

        rgbaData.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else { return }
            ciContext.render(
                scaledImage,
                toBitmap: baseAddress,
                rowBytes: width * rgbaBytesPerPixel,
                bounds: CGRect(x: 0, y: 0, width: width, height: height),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
        }

        var rgbData = Data(capacity: width * height * 3)
        rgbaData.withUnsafeBytes { buffer in
            let rgba = buffer.bindMemory(to: UInt8.self)
            for index in stride(from: 0, to: width * height * rgbaBytesPerPixel, by: rgbaBytesPerPixel) {
                rgbData.append(rgba[index])
                rgbData.append(rgba[index + 1])
                rgbData.append(rgba[index + 2])
            }
        }

        return ARFrameImageData(data: rgbData, width: width, height: height, bytesPerPixel: 3)
    }

    static func scaledCameraMatrix(from frame: ARFrame, scale: CGFloat) -> [Double] {
        let intrinsics = frame.camera.intrinsics
        let scaleValue = Double(scale)

        let fx = Double(intrinsics[0, 0]) * scaleValue
        let fy = Double(intrinsics[1, 1]) * scaleValue
        let cx = Double(intrinsics[2, 0]) * scaleValue
        let cy = Double(intrinsics[2, 1]) * scaleValue

        return [
            fx, 0.0, cx,
            0.0, fy, cy,
            0.0, 0.0, 1.0
        ]
    }
}
