import ARKit
import CoreVideo
import Foundation

/// 從 ARKit 擷取出的原始類深度影像資料內容。
///
/// 這個模型以資料格式為中心，後續可映射成 ROS depth image message
/// 或用於點雲生成，且不需要依賴 ARKit 型別。
struct ARDepthFrameData: Sendable {
    /// 逐列緊密排列的影像 bytes。
    let data: Data

    /// 影像寬度，單位為 pixel。
    let width: Int

    /// 影像高度，單位為 pixel。
    let height: Int

    /// 用於計算 ROS-style `step` 的 pixel stride。
    let bytesPerPixel: Int

    /// 與 ROS image 慣例相容的 encoding 名稱。
    let encoding: String

    /// 重新排列後每列的 byte 數。
    var step: UInt32 {
        UInt32(width * bytesPerPixel)
    }
}

/// 將 ARKit scene depth 與 confidence map 擷取成穩定的 RoboSight 資料內容。
struct ARDepthFrameExtractor {
    /// 從 ARKit scene depth 擷取公尺單位的 depth 數值。
    static func extractDepthData(from depthData: ARDepthData) -> ARDepthFrameData? {
        copyPixelBuffer(
            depthData.depthMap,
            bytesPerPixel: MemoryLayout<Float32>.size,
            encoding: "32FC1"
        )
    }

    /// 在設備提供 confidence map 時，擷取 ARKit confidence 數值。
    static func extractConfidenceData(from depthData: ARDepthData) -> ARDepthFrameData? {
        guard let confidenceMap = depthData.confidenceMap else { return nil }

        return copyPixelBuffer(
            confidenceMap,
            bytesPerPixel: MemoryLayout<UInt8>.size,
            encoding: "mono8"
        )
    }

    /// 將可能含有 padding 的 `CVPixelBuffer` 複製成緊密排列的 row-major data。
    ///
    /// ARKit buffer 的 `bytesPerRow` 可能大於 `width * bytesPerPixel`。
    /// 在這裡重新排列後，下游程式可以取得可預期的資料配置。
    private static func copyPixelBuffer(
        _ pixelBuffer: CVPixelBuffer,
        bytesPerPixel: Int,
        encoding: String
    ) -> ARDepthFrameData? {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        guard width > 0, height > 0 else { return nil }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else {
            return nil
        }

        let sourceRowBytes = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let destinationRowBytes = width * bytesPerPixel
        var data = Data(count: destinationRowBytes * height)

        data.withUnsafeMutableBytes { destinationBuffer in
            guard let destinationBaseAddress = destinationBuffer.baseAddress else { return }

            for row in 0..<height {
                let sourceRow = baseAddress.advanced(by: row * sourceRowBytes)
                let destinationRow = destinationBaseAddress.advanced(by: row * destinationRowBytes)
                destinationRow.copyMemory(from: sourceRow, byteCount: destinationRowBytes)
            }
        }

        return ARDepthFrameData(
            data: data,
            width: width,
            height: height,
            bytesPerPixel: bytesPerPixel,
            encoding: encoding
        )
    }
}
