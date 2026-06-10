import Foundation
import simd

/// 已編碼的 RGB 影像資料內容。
///
/// 對應標準功能：
/// - RGB 影像擷取：`data`
/// - 影像解析度：`width`, `height`
struct CameraCompressedImageData: Sendable {
    /// JPEG 壓縮後的影像 bytes。
    let data: Data

    /// 編碼後影像寬度，單位為 pixel。
    let width: Int

    /// 編碼後影像高度，單位為 pixel。
    let height: Int
}

/// 產品功能與 ROS 發送共用的相機影像影格。
///
/// 這個模型刻意與 ARKit 和 ROS message 型別解耦。
/// ARKit 來源程式碼產生它，功能模組與傳輸層程式碼消費它。
struct CameraImageFrame: Sendable {
    /// Unix timestamp，單位為秒。
    ///
    /// 對應標準功能：frame 時間戳。
    let timestamp: TimeInterval

    /// 壓縮後的 RGB 影像資料內容。
    ///
    /// 對應標準功能：RGB 影像擷取、色彩影像編碼、影像解析度。
    let image: CameraCompressedImageData

    /// 依照編碼影像方向與縮放比例調整後的 3x3 相機內參矩陣。
    ///
    /// 對應標準功能：相機內參。
    let cameraMatrix: [Double]

    /// ARKit world 座標中的相機姿態。
    ///
    /// 對應標準功能：相機姿態 / 外參。
    let cameraTransform: simd_float4x4
}
