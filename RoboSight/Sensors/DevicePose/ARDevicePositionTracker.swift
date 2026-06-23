import simd

/// 將 ARKit camera transform 轉成 RoboSight 的 device_link 相對位移。
///
/// 座標轉換沿用 ion206/iOS-ARKit-to-ROS2 的 ARKit -> ROS translation 對應：
/// ROS X = -AR Z、ROS Y = -AR X、ROS Z = AR Y。
/// 這裡只保留位置演算法，不搬入 rosbridge payload、odometry 或速度計算。
final class ARDevicePositionTracker {
    private var referencePosition: SIMD3<Float>?

    /// 清除啟動參考點；下一筆 frame 會重新作為原點。
    func reset() {
        referencePosition = nil
    }

    /// 產生相對於第一筆 ARKit pose 的位移。
    func makeFrame(from rawFrame: CameraRawFrame) -> DevicePositionFrame {
        let currentPosition = Self.rosPosition(from: rawFrame.cameraTransform)

        guard let referencePosition else {
            self.referencePosition = currentPosition
            return DevicePositionFrame(timestamp: rawFrame.timestamp, translation: .zero)
        }

        let relativePosition = currentPosition - referencePosition
        return DevicePositionFrame(
            timestamp: rawFrame.timestamp,
            translation: DeviceTranslation(
                x: Double(relativePosition.x),
                y: Double(relativePosition.y),
                z: Double(relativePosition.z)
            )
        )
    }

    /// 從 ARKit 4x4 transform 取出位置，並轉成目前 ROS / RViz 使用的座標排列。
    private static func rosPosition(from transform: simd_float4x4) -> SIMD3<Float> {
        let arTranslation = transform.columns.3
        return SIMD3<Float>(
            -arTranslation.z,
            -arTranslation.x,
            arTranslation.y
        )
    }
}
