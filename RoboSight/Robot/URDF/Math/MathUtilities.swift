import Foundation
import simd

/// 將 URDF 的 roll-pitch-yaw 旋轉轉成 quaternion。
/// 使用 ZYX 慣例：yaw 繞 Z、pitch 繞 Y、roll 繞 X。
public func rpyToQuaternion(roll: Double, pitch: Double, yaw: Double) -> simd_quatd {
    let cr = cos(roll / 2)
    let sr = sin(roll / 2)
    let cp = cos(pitch / 2)
    let sp = sin(pitch / 2)
    let cy = cos(yaw / 2)
    let sy = sin(yaw / 2)

    let w = cr * cp * cy + sr * sp * sy
    let x = sr * cp * cy - cr * sp * sy
    let y = cr * sp * cy + sr * cp * sy
    let z = cr * cp * sy - sr * sp * cy

    return simd_quatd(ix: x, iy: y, iz: z, r: w)
}

/// 將 URDF origin 轉成內部 Transform3D。
public func transformFromOrigin(
    xyz: (x: Double, y: Double, z: Double),
    rpy: (roll: Double, pitch: Double, yaw: Double)
) -> Transform3D {
    let q = rpyToQuaternion(roll: rpy.roll, pitch: rpy.pitch, yaw: rpy.yaw)
    return Transform3D(
        translation: SIMD3<Double>(xyz.x, xyz.y, xyz.z),
        rotation: q
    )
}
