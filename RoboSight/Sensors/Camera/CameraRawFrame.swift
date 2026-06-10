import CoreGraphics
import CoreVideo
import Foundation
import simd

/// 相機原始感測資料 frame。
///
/// 這是產品功能應優先共用的相機原始資料 API。ARKit 來源層負責產生它；
/// 相機影像、ArUco、後續定位演算法都應從這個資料模型取得一致的時間戳、
/// 影像 buffer、相機內參與相機姿態。
struct CameraRawFrame {
    /// Unix timestamp，單位為秒。
    let timestamp: TimeInterval

    /// 未壓縮的相機影像 buffer。
    ///
    /// 對應標準功能：Pixel Buffer Access。
    let pixelBuffer: CVPixelBuffer

    /// ARKit 回報的相機影像解析度。
    ///
    /// 對應標準功能：Image Resolution。
    let imageResolution: CGSize

    /// ARKit 原始相機內參矩陣。
    ///
    /// 對應標準功能：Camera Intrinsics。
    let cameraIntrinsics: simd_float3x3

    /// ARKit world 座標中的相機姿態。
    ///
    /// 對應標準功能：Camera Pose / Extrinsics。
    let cameraTransform: simd_float4x4
}
