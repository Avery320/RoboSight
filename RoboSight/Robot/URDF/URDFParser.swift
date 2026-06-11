import Foundation

/// RoboSight 使用的輕量 URDF parser。
///
/// 本階段只解析 robot、link、visual mesh、material、joint、origin、axis、limit、mimic；
/// collision、inertial 與 transmission 先不納入，避免產品尚未使用的資料增加維護成本。
public struct URDFParser: Sendable {
    public init() {}

    public func parse(data: Data) throws -> RobotModel {
        let delegate = URDFParserDelegate()
        let xmlParser = XMLParser(data: data)
        xmlParser.delegate = delegate
        xmlParser.shouldProcessNamespaces = false

        guard xmlParser.parse() else {
            if let error = delegate.parseError {
                throw error
            }
            throw URDFParseError.malformedXML(xmlParser.parserError?.localizedDescription ?? "未知解析錯誤")
        }

        if let error = delegate.parseError {
            throw error
        }

        return try delegate.buildRobotModel()
    }

    public func parse(url: URL) throws -> RobotModel {
        try parse(data: Data(contentsOf: url))
    }
}

/// URDF 解析階段會回報的最小錯誤集合。
public enum URDFParseError: Error, Sendable, CustomStringConvertible {
    case malformedXML(String)
    case missingRequiredAttribute(element: String, attribute: String)
    case unknownLink(String)

    public var description: String {
        switch self {
        case .malformedXML(let detail):
            return "URDF XML 格式錯誤：\(detail)"
        case .missingRequiredAttribute(let element, let attribute):
            return "<\(element)> 缺少必要屬性 '\(attribute)'"
        case .unknownLink(let name):
            return "不存在的 link：'\(name)'"
        }
    }
}

private final class URDFParserDelegate: NSObject, XMLParserDelegate {
    var parseError: URDFParseError?

    // XMLParser 是串流式解析，因此用目前元素狀態累積 link / joint / visual。
    private var robotName = ""
    private var links: [Link] = []
    private var joints: [Joint] = []
    private var globalMaterials: [String: RobotMaterial] = [:]
    private var elementStack: [String] = []

    private var currentLinkName: String?
    private var currentVisuals: [Visual] = []
    private var currentVisualOrigin: Origin?
    private var currentVisualMeshRef: MeshRef?
    private var currentVisualMaterial: RobotMaterial?

    private var currentJointName: String?
    private var currentJointType: JointType?
    private var currentJointParent: LinkID?
    private var currentJointChild: LinkID?
    private var currentJointOrigin: Origin?
    private var currentJointAxis: Axis?
    private var currentJointLimit: JointLimit?
    private var currentJointMimic: Mimic?

    private var inVisual = false
    private var inJoint = false
    private var inGlobalMaterial = false
    private var currentMaterialName: String?
    private var currentMaterialColor: (r: Double, g: Double, b: Double, a: Double)?

    private var parentElement: String {
        elementStack.count >= 2 ? elementStack[elementStack.count - 2] : ""
    }

    func buildRobotModel() throws -> RobotModel {
        // URDF tree 的 root link 是沒有被任何 joint 當成 child 的 link。
        let childLinkNames = Set(joints.map(\.childLink))
        let rootLinks = links.filter { !childLinkNames.contains($0.id) }

        guard let rootLink = rootLinks.first else {
            throw URDFParseError.malformedXML("找不到 root link；所有 link 都被當成 child joint target。")
        }

        let linkNames = Set(links.map(\.id))
        for joint in joints {
            if !linkNames.contains(joint.parentLink) {
                throw URDFParseError.unknownLink(joint.parentLink.rawValue)
            }
            if !linkNames.contains(joint.childLink) {
                throw URDFParseError.unknownLink(joint.childLink.rawValue)
            }
        }

        return RobotModel(
            name: robotName,
            links: resolvedMaterialLinks(),
            joints: joints,
            rootLink: rootLink.id
        )
    }

    func parser(
        _ parser: XMLParser,
        didStartElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?,
        attributes attributeDict: [String: String]
    ) {
        elementStack.append(elementName)

        switch elementName {
        case "robot":
            robotName = attributeDict["name"] ?? "unnamed"

        case "link":
            currentLinkName = attributeDict["name"]
            currentVisuals = []
            if currentLinkName == nil {
                parseError = .missingRequiredAttribute(element: "link", attribute: "name")
                parser.abortParsing()
            }

        case "visual":
            inVisual = true
            currentVisualOrigin = nil
            currentVisualMeshRef = nil
            currentVisualMaterial = nil

        case "joint":
            inJoint = true
            currentJointName = attributeDict["name"]
            currentJointType = attributeDict["type"].flatMap(JointType.init(rawValue:))
            currentJointParent = nil
            currentJointChild = nil
            currentJointOrigin = nil
            currentJointAxis = nil
            currentJointLimit = nil
            currentJointMimic = nil
            if currentJointName == nil {
                parseError = .missingRequiredAttribute(element: "joint", attribute: "name")
                parser.abortParsing()
            }

        case "origin":
            let origin = parseOrigin(attributeDict)
            if inVisual {
                currentVisualOrigin = origin
            } else if inJoint {
                currentJointOrigin = origin
            }

        case "mesh":
            guard inVisual, let filename = attributeDict["filename"] else { break }
            var scale: (x: Double, y: Double, z: Double)?
            if let scaleText = attributeDict["scale"],
               let parsedScale = URDFNumberParser.parse3(scaleText) {
                scale = (x: parsedScale.0, y: parsedScale.1, z: parsedScale.2)
            }
            currentVisualMeshRef = MeshRef(uri: filename, scale: scale)

        case "material":
            if inVisual {
                currentVisualMaterial = RobotMaterial(name: attributeDict["name"])
            } else if parentElement == "robot" && !inJoint {
                inGlobalMaterial = true
                currentMaterialName = attributeDict["name"]
                currentMaterialColor = nil
            }

        case "color":
            guard let rgbaText = attributeDict["rgba"],
                  let rgba = URDFNumberParser.parse4(rgbaText) else { break }
            let color = (r: rgba.0, g: rgba.1, b: rgba.2, a: rgba.3)
            if inVisual {
                currentVisualMaterial = RobotMaterial(
                    name: currentVisualMaterial?.name,
                    color: color
                )
            } else if inGlobalMaterial {
                currentMaterialColor = color
            }

        case "parent":
            if inJoint, let link = attributeDict["link"] {
                currentJointParent = LinkID(rawValue: link)
            }

        case "child":
            if inJoint, let link = attributeDict["link"] {
                currentJointChild = LinkID(rawValue: link)
            }

        case "axis":
            if inJoint,
               let xyzText = attributeDict["xyz"],
               let xyz = URDFNumberParser.parse3(xyzText) {
                currentJointAxis = Axis(x: xyz.0, y: xyz.1, z: xyz.2)
            }

        case "limit":
            if inJoint {
                currentJointLimit = JointLimit(
                    lower: Double(attributeDict["lower"] ?? "0") ?? 0,
                    upper: Double(attributeDict["upper"] ?? "0") ?? 0,
                    effort: Double(attributeDict["effort"] ?? "0") ?? 0,
                    velocity: Double(attributeDict["velocity"] ?? "0") ?? 0
                )
            }

        case "mimic":
            if inJoint, let jointName = attributeDict["joint"] {
                currentJointMimic = Mimic(
                    jointName: JointID(rawValue: jointName),
                    multiplier: Double(attributeDict["multiplier"] ?? "1") ?? 1,
                    offset: Double(attributeDict["offset"] ?? "0") ?? 0
                )
            }

        default:
            break
        }
    }

    func parser(
        _ parser: XMLParser,
        didEndElement elementName: String,
        namespaceURI: String?,
        qualifiedName qName: String?
    ) {
        defer {
            _ = elementStack.popLast()
        }

        switch elementName {
        case "link":
            if let name = currentLinkName {
                links.append(Link(name: name, visuals: currentVisuals))
            }
            currentLinkName = nil

        case "visual":
            if let meshRef = currentVisualMeshRef {
                currentVisuals.append(Visual(
                    origin: currentVisualOrigin,
                    meshRef: meshRef,
                    material: currentVisualMaterial
                ))
            }
            inVisual = false

        case "joint":
            if let name = currentJointName,
               let type = currentJointType,
               let parent = currentJointParent,
               let child = currentJointChild {
                joints.append(Joint(
                    name: name,
                    type: type,
                    parentLink: parent,
                    childLink: child,
                    origin: currentJointOrigin,
                    axis: currentJointAxis ?? .defaultAxis,
                    limit: currentJointLimit,
                    mimic: currentJointMimic
                ))
            }
            inJoint = false

        case "material":
            if inGlobalMaterial, let name = currentMaterialName {
                globalMaterials[name] = RobotMaterial(
                    name: name,
                    color: currentMaterialColor
                )
            }
            inGlobalMaterial = false

        default:
            break
        }
    }

    func parser(_ parser: XMLParser, parseErrorOccurred parseError: Error) {
        if self.parseError == nil {
            self.parseError = .malformedXML(parseError.localizedDescription)
        }
    }

    private func resolvedMaterialLinks() -> [Link] {
        // URDF 允許 visual 只引用全域 material name，這裡在 parser 階段先展開成可直接渲染的資料。
        var resolvedLinks = links
        for linkIndex in resolvedLinks.indices {
            for visualIndex in resolvedLinks[linkIndex].visuals.indices {
                if let materialName = resolvedLinks[linkIndex].visuals[visualIndex].material?.name,
                   resolvedLinks[linkIndex].visuals[visualIndex].material?.color == nil,
                   let globalMaterial = globalMaterials[materialName] {
                    resolvedLinks[linkIndex].visuals[visualIndex].material = globalMaterial
                }
            }
        }
        return resolvedLinks
    }

    private func parseOrigin(_ attributes: [String: String]) -> Origin {
        var xyz: (x: Double, y: Double, z: Double) = (0, 0, 0)
        var rpy: (roll: Double, pitch: Double, yaw: Double) = (0, 0, 0)

        if let xyzText = attributes["xyz"],
           let parsedXYZ = URDFNumberParser.parse3(xyzText) {
            xyz = (x: parsedXYZ.0, y: parsedXYZ.1, z: parsedXYZ.2)
        }
        if let rpyText = attributes["rpy"],
           let parsedRPY = URDFNumberParser.parse3(rpyText) {
            rpy = (roll: parsedRPY.0, pitch: parsedRPY.1, yaw: parsedRPY.2)
        }
        return Origin(xyz: xyz, rpy: rpy)
    }
}

private enum URDFNumberParser {
    /// URDF 數值常用空白分隔，這裡用最小 parser 避免為 xyz/rpy/rgba 引入額外依賴。
    private struct TokenIterator {
        private let string: String
        private var index: String.Index

        init(_ string: String) {
            self.string = string
            self.index = string.startIndex
        }

        mutating func nextDouble() -> Double? {
            skipWhitespace()
            guard index < string.endIndex else { return nil }

            let start = index
            while index < string.endIndex, !string[index].isWhitespace {
                index = string.index(after: index)
            }

            return Double(string[start..<index])
        }

        mutating func isAtEndAfterSkippingWhitespace() -> Bool {
            skipWhitespace()
            return index >= string.endIndex
        }

        private mutating func skipWhitespace() {
            while index < string.endIndex, string[index].isWhitespace {
                index = string.index(after: index)
            }
        }
    }

    static func parse3(_ str: String) -> (Double, Double, Double)? {
        var iterator = TokenIterator(str)
        guard let a = iterator.nextDouble(),
              let b = iterator.nextDouble(),
              let c = iterator.nextDouble(),
              iterator.isAtEndAfterSkippingWhitespace() else {
            return nil
        }
        return (a, b, c)
    }

    static func parse4(_ str: String) -> (Double, Double, Double, Double)? {
        var iterator = TokenIterator(str)
        guard let a = iterator.nextDouble(),
              let b = iterator.nextDouble(),
              let c = iterator.nextDouble(),
              let d = iterator.nextDouble(),
              iterator.isAtEndAfterSkippingWhitespace() else {
            return nil
        }
        return (a, b, c, d)
    }
}
