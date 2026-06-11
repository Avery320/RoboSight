import simd

/// 3D 剛體轉換，包含平移與旋轉。
public struct Transform3D: Sendable, Equatable {
    public var translation: SIMD3<Double>
    public var rotation: simd_quatd

    public static let identity = Transform3D(
        translation: .zero,
        rotation: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
    )

    public init(translation: SIMD3<Double>, rotation: simd_quatd) {
        self.translation = translation
        self.rotation = rotation
    }

    /// 合成兩個 transform，順序為 self * other。
    public func composed(with other: Transform3D) -> Transform3D {
        let newRotation = self.rotation * other.rotation
        let rotatedTranslation = self.rotation.act(other.translation)
        return Transform3D(
            translation: self.translation + rotatedTranslation,
            rotation: newRotation
        )
    }

    /// 回傳反向 transform。
    public var inverse: Transform3D {
        let invRotation = rotation.inverse
        let invTranslation = invRotation.act(-translation)
        return Transform3D(translation: invTranslation, rotation: invRotation)
    }
}
