import Foundation
import simd

/// 將 RoboSight 允許的相對 STL 路徑解析成本機檔案 URL。
public struct AssetResolver: Sendable {
    public let baseURL: URL

    public init(baseURL: URL) {
        self.baseURL = baseURL
    }

    /// URDF 已在 Settings 階段限制為相對路徑，因此這裡只負責接成本機 cache URL。
    public func resolve(_ uri: String) -> URL {
        baseURL.appendingPathComponent(uri)
    }
}

/// RealityKit 顯示 STL 需要的最小 mesh 資料。
public struct MeshData: Sendable {
    public var positions: [SIMD3<Float>]
    public var normals: [SIMD3<Float>]
    public var indices: [UInt32]

    public init(
        positions: [SIMD3<Float>],
        normals: [SIMD3<Float>],
        indices: [UInt32]
    ) {
        self.positions = positions
        self.normals = normals
        self.indices = indices
    }
}

public enum MeshLoadError: Error, Sendable, CustomStringConvertible {
    case unsupportedFormat(String)
    case fileNotFound(URL)
    case emptyMesh(URL)

    public var description: String {
        switch self {
        case .unsupportedFormat(let ext):
            "不支援的 mesh 格式：.\(ext)"
        case .fileNotFound(let url):
            "找不到 mesh 檔案：\(url.path)"
        case .emptyMesh(let url):
            "STL 檔案沒有可用頂點：\(url.path)"
        }
    }
}

/// 只支援 STL 的 mesh loader。RoboSight 目前不支援 DAE/OBJ/USDA，也不做格式轉換。
public final class MeshLoader: @unchecked Sendable {
    private let importer = STLMeshImporter()
    private var cache: [String: MeshData] = [:]
    private let lock = NSLock()

    public init() {}

    /// 載入單一 visual mesh。這裡是 STL-only 的最後一道防線，不做 DAE/OBJ 轉換。
    public func loadMesh(
        for meshRef: MeshRef,
        resolver: AssetResolver
    ) async throws -> MeshData {
        let url = resolver.resolve(meshRef.uri)
        let fileExtension = url.pathExtension.lowercased()
        guard fileExtension == "stl" else {
            throw MeshLoadError.unsupportedFormat(fileExtension)
        }

        if let cached = cachedMesh(for: url) {
            return cached
        }

        guard FileManager.default.fileExists(atPath: url.path) else {
            throw MeshLoadError.fileNotFound(url)
        }

        let mesh = try importer.load(url: url)
        setCachedMesh(mesh, for: url)
        return mesh
    }

    private func cachedMesh(for url: URL) -> MeshData? {
        lock.lock()
        defer { lock.unlock() }
        return cache[cacheKey(for: url)]
    }

    private func setCachedMesh(_ mesh: MeshData, for url: URL) {
        lock.lock()
        defer { lock.unlock() }
        cache[cacheKey(for: url)] = mesh
    }

    private func cacheKey(for url: URL) -> String {
        url.standardizedFileURL.path
    }
}

/// 解析 binary STL 與 ASCII STL，輸出 RealityKit 可直接使用的三角形資料。
private struct STLMeshImporter {
    func load(url: URL) throws -> MeshData {
        let data = try Data(contentsOf: url)

        if let mesh = parseBinarySTL(data), !mesh.positions.isEmpty {
            return mesh
        }

        if let mesh = parseASCIISTL(data), !mesh.positions.isEmpty {
            return mesh
        }

        throw MeshLoadError.emptyMesh(url)
    }

    /// Binary STL 格式：80 bytes header、4 bytes triangle count，後面每個 triangle 50 bytes。
    private func parseBinarySTL(_ data: Data) -> MeshData? {
        let headerByteCount = 80
        let triangleCountByteCount = 4
        let triangleByteCount = 50
        let minimumByteCount = headerByteCount + triangleCountByteCount

        guard data.count >= minimumByteCount else { return nil }

        let triangleCount = Int(data.littleEndianUInt32(at: headerByteCount))
        guard triangleCount > 0 else { return nil }

        let expectedByteCount = minimumByteCount + triangleCount * triangleByteCount
        guard data.count >= expectedByteCount else { return nil }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        positions.reserveCapacity(triangleCount * 3)
        normals.reserveCapacity(triangleCount * 3)
        indices.reserveCapacity(triangleCount * 3)

        for triangleIndex in 0..<triangleCount {
            let triangleOffset = minimumByteCount + triangleIndex * triangleByteCount
            let normal = data.vector3(at: triangleOffset)
            let v0 = data.vector3(at: triangleOffset + 12)
            let v1 = data.vector3(at: triangleOffset + 24)
            let v2 = data.vector3(at: triangleOffset + 36)

            appendTriangle(
                vertices: (v0, v1, v2),
                normal: normal,
                positions: &positions,
                normals: &normals,
                indices: &indices
            )
        }

        return MeshData(positions: positions, normals: normals, indices: indices)
    }

    /// ASCII STL 格式以 facet/vertex 文字描述三角形；只取 visual mesh 必需的頂點與法向量。
    private func parseASCIISTL(_ data: Data) -> MeshData? {
        guard let text = String(data: data, encoding: .utf8) else {
            return nil
        }

        var positions: [SIMD3<Float>] = []
        var normals: [SIMD3<Float>] = []
        var indices: [UInt32] = []
        var facetNormal = SIMD3<Float>(0, 0, 0)
        var facetVertices: [SIMD3<Float>] = []

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let parts = rawLine.split(whereSeparator: \.isWhitespace)
            guard let keyword = parts.first?.lowercased() else { continue }

            if keyword == "facet",
               parts.count >= 5,
               parts[1].lowercased() == "normal",
               let normal = vector3(parts[2], parts[3], parts[4]) {
                facetNormal = normal
                facetVertices.removeAll(keepingCapacity: true)
                continue
            }

            if keyword == "vertex",
               parts.count >= 4,
               let vertex = vector3(parts[1], parts[2], parts[3]) {
                facetVertices.append(vertex)
            }

            if facetVertices.count == 3 {
                appendTriangle(
                    vertices: (facetVertices[0], facetVertices[1], facetVertices[2]),
                    normal: facetNormal,
                    positions: &positions,
                    normals: &normals,
                    indices: &indices
                )
                facetVertices.removeAll(keepingCapacity: true)
            }
        }

        guard !positions.isEmpty else { return nil }

        return MeshData(positions: positions, normals: normals, indices: indices)
    }

    private func vector3(
        _ x: Substring,
        _ y: Substring,
        _ z: Substring
    ) -> SIMD3<Float>? {
        guard let x = Float(x), let y = Float(y), let z = Float(z) else {
            return nil
        }
        return SIMD3<Float>(x, y, z)
    }

    private func appendTriangle(
        vertices: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>),
        normal: SIMD3<Float>,
        positions: inout [SIMD3<Float>],
        normals: inout [SIMD3<Float>],
        indices: inout [UInt32]
    ) {
        let resolvedNormal = resolvedNormal(normal, vertices: vertices)

        let baseIndex = UInt32(positions.count)
        positions.append(vertices.0)
        positions.append(vertices.1)
        positions.append(vertices.2)
        normals.append(resolvedNormal)
        normals.append(resolvedNormal)
        normals.append(resolvedNormal)
        indices.append(baseIndex)
        indices.append(baseIndex + 1)
        indices.append(baseIndex + 2)
    }

    /// STL 法向量可能是零向量或非法值，必要時用三角形頂點重新計算。
    private func resolvedNormal(
        _ normal: SIMD3<Float>,
        vertices: (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>)
    ) -> SIMD3<Float> {
        if normal.isFiniteVector, simd_length_squared(normal) > 1e-12 {
            return simd_normalize(normal)
        }

        let calculated = simd_cross(
            vertices.1 - vertices.0,
            vertices.2 - vertices.0
        )
        guard calculated.isFiniteVector,
              simd_length_squared(calculated) > 1e-12 else {
            return SIMD3<Float>(0, 1, 0)
        }

        return simd_normalize(calculated)
    }
}

private extension Data {
    func littleEndianUInt32(at offset: Int) -> UInt32 {
        var value: UInt32 = 0
        for index in 0..<4 {
            value |= UInt32(self[offset + index]) << UInt32(index * 8)
        }
        return value
    }

    func littleEndianFloat32(at offset: Int) -> Float {
        Float(bitPattern: littleEndianUInt32(at: offset))
    }

    func vector3(at offset: Int) -> SIMD3<Float> {
        SIMD3<Float>(
            littleEndianFloat32(at: offset),
            littleEndianFloat32(at: offset + 4),
            littleEndianFloat32(at: offset + 8)
        )
    }
}

private extension SIMD3 where Scalar == Float {
    var isFiniteVector: Bool {
        x.isFinite && y.isFinite && z.isFinite
    }
}
