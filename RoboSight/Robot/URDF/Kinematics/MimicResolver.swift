/// Mimic joint 展開時可能發生的錯誤。
public enum MimicError: Error, Sendable, CustomStringConvertible {
    case missingDriver(mimicJoint: JointID, driver: JointID)
    case cyclicMimicChain([JointID])

    public var description: String {
        switch self {
        case .missingDriver(let mimic, let driver):
            return "Mimic joint '\(mimic)' 找不到 driver joint '\(driver)'"
        case .cyclicMimicChain(let chain):
            return "偵測到循環 mimic chain：\(chain.map(\.rawValue).joined(separator: " → "))"
        }
    }
}

/// 將獨立 joint position 展開為包含 mimic joint 的完整 joint position。
public struct MimicResolver: Sendable {
    private let jointIndex: JointIndex
    private let mimicOrder: [Joint.ID]
    private let cycleError: MimicError?

    public init(jointIndex: JointIndex) {
        self.jointIndex = jointIndex
        let result = Self.computeMimicOrderAndCycle(dependencies: jointIndex.mimicDependencies)
        self.mimicOrder = result.order
        self.cycleError = result.cycle.map { MimicError.cyclicMimicChain($0) }
    }

    /// 使用 `q_mimic = multiplier * q_driver + offset` 補齊 mimic joint。
    public func expand(independent: [Joint.ID: Double]) throws -> [Joint.ID: Double] {
        if let cycleError {
            throw cycleError
        }

        var full = independent

        for mimicID in mimicOrder {
            guard let driverID = jointIndex.mimicDependencies[mimicID],
                  let params = jointIndex.mimicParameters[mimicID]
            else { continue }

            guard let driverValue = full[driverID] else {
                throw MimicError.missingDriver(mimicJoint: mimicID, driver: driverID)
            }

            full[mimicID] = params.multiplier * driverValue + params.offset
        }

        for jointID in jointIndex.full where full[jointID] == nil {
            full[jointID] = 0.0
        }

        return full
    }

    private static func computeMimicOrderAndCycle(
        dependencies: [Joint.ID: Joint.ID]
    ) -> (order: [Joint.ID], cycle: [Joint.ID]?) {
        enum VisitState {
            case visiting
            case visited
        }

        var state: [Joint.ID: VisitState] = [:]
        state.reserveCapacity(dependencies.count)

        var order: [Joint.ID] = []
        order.reserveCapacity(dependencies.count)

        var stack: [Joint.ID] = []
        stack.reserveCapacity(dependencies.count)

        func visit(_ jointID: Joint.ID) -> [Joint.ID]? {
            if let s = state[jointID] {
                switch s {
                case .visiting:
                    if let start = stack.firstIndex(of: jointID) {
                        return Array(stack[start...]) + [jointID]
                    }
                    return [jointID, jointID]
                case .visited:
                    return nil
                }
            }

            state[jointID] = .visiting
            stack.append(jointID)

            if let driver = dependencies[jointID], dependencies[driver] != nil {
                if let cycle = visit(driver) {
                    return cycle
                }
            }

            _ = stack.popLast()
            state[jointID] = .visited
            order.append(jointID)
            return nil
        }

        for mimicID in dependencies.keys.sorted(by: { $0.rawValue < $1.rawValue }) {
            if state[mimicID] == nil {
                if let cycle = visit(mimicID) {
                    return ([], cycle)
                }
            }
        }

        return (order, nil)
    }
}
