/// 版本定义独立于界面，便于诊断入口与菜单栏共用。
public enum AuralVersion {
    public static let current = "0.1.15"
}

/// 发布标签与 App 版号共用同一套比较规则，正确处理 0.1.10 大于 0.1.9。
public struct AuralVersionNumber: Comparable, Sendable, CustomStringConvertible {
    public let components: [Int]
    public let prerelease: String?

    public init?(_ rawValue: String) {
        var value = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.lowercased().hasPrefix("v") { value.removeFirst() }
        let split = value.split(separator: "-", maxSplits: 1, omittingEmptySubsequences: false)
        guard let core = split.first, !core.isEmpty else { return nil }
        let parsed = core.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
        guard parsed.allSatisfy({ $0 != nil }) else { return nil }
        let components = parsed.compactMap { $0 }
        guard !components.isEmpty, components.allSatisfy({ $0 >= 0 }) else { return nil }
        self.components = components
        prerelease = split.count == 2 && !split[1].isEmpty ? String(split[1]).lowercased() : nil
    }

    public var description: String {
        let base = components.map(String.init).joined(separator: ".")
        return prerelease.map { "\(base)-\($0)" } ?? base
    }

    /// 正式版高于同一数值的预发布版；其余分段先按数字比较，再按标识文本比较。
    public static func < (lhs: Self, rhs: Self) -> Bool {
        let count = max(lhs.components.count, rhs.components.count)
        for index in 0..<count {
            let left = index < lhs.components.count ? lhs.components[index] : 0
            let right = index < rhs.components.count ? rhs.components[index] : 0
            if left != right { return left < right }
        }
        switch (lhs.prerelease, rhs.prerelease) {
        case (nil, nil): return false
        case (nil, _): return false
        case (_, nil): return true
        case let (left?, right?):
            return comparePrerelease(left, right)
        }
    }

    private static func comparePrerelease(_ lhs: String, _ rhs: String) -> Bool {
        let left = lhs.split(separator: ".")
        let right = rhs.split(separator: ".")
        for (leftPart, rightPart) in zip(left, right) {
            if leftPart == rightPart { continue }
            if let leftNumber = Int(leftPart), let rightNumber = Int(rightPart) {
                return leftNumber < rightNumber
            }
            return String(leftPart).localizedStandardCompare(String(rightPart)) == .orderedAscending
        }
        return left.count < right.count
    }
}
