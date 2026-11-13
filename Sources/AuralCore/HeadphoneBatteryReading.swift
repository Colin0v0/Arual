import Foundation

/// 耳机协议实际返回的电量形状。
///
/// `single` 只用于协议本身只有一档电量的设备；左右耳和充电盒各自保留，
/// 不能把缺失部件补成 0，也不能从另一只耳机推断。
public struct HeadphoneBatteryReading: Equatable, Sendable {
    public var single: Int?
    public var left: Int?
    public var right: Int?
    public var caseLevel: Int?
    public var isCharging: Bool?

    public init(single: Int? = nil, left: Int? = nil, right: Int? = nil,
                caseLevel: Int? = nil, isCharging: Bool? = nil) {
        self.single = single
        self.left = left
        self.right = right
        self.caseLevel = caseLevel
        self.isCharging = isCharging
    }

    public var hasLevel: Bool {
        single != nil || left != nil || right != nil || caseLevel != nil
    }

    /// 菜单栏只允许使用协议明确上报的部件值。
    public var hasEarbudLevel: Bool {
        single != nil || left != nil || right != nil
    }
}

/// 菜单栏电量来源是用户明确选择，不用“当前连接了哪副耳机”偷偷替代。
public enum MenuBarBatterySource: Codable, Equatable, Hashable, Sendable {
    case off
    case currentOutput
    case pinned(deviceUID: String)

    /// 使用稳定设备 UID 持久化，HAL 重启后的临时 AudioDeviceID 不参与保存。
    public init?(storageValue: String) {
        switch storageValue {
        case "off":
            self = .off
        case "currentOutput":
            self = .currentOutput
        default:
            let prefix = "pinned:"
            guard storageValue.hasPrefix(prefix) else { return nil }
            let uid = String(storageValue.dropFirst(prefix.count))
            guard !uid.isEmpty else { return nil }
            self = .pinned(deviceUID: uid)
        }
    }

    public var storageValue: String {
        switch self {
        case .off: return "off"
        case .currentOutput: return "currentOutput"
        case .pinned(let deviceUID): return "pinned:\(deviceUID)"
        }
    }
}

/// 当前系统输出在电量选择中的真实形态。
public enum MenuBarBatteryCurrentOutput: Equatable, Sendable {
    case direct(deviceUID: String)
    case multiOutput(memberUIDs: [String])
    case unsupported
}

public struct MenuBarBatteryCandidate: Equatable, Sendable {
    public let deviceUID: String
    public let displayName: String
    public let reading: HeadphoneBatteryReading

    public init(deviceUID: String, displayName: String, reading: HeadphoneBatteryReading) {
        self.deviceUID = deviceUID
        self.displayName = displayName
        self.reading = reading
    }
}

/// 菜单栏电量目标解析只返回唯一、明确的耳机。
public enum MenuBarBatteryResolver {
    public static func resolve(
        source: MenuBarBatterySource,
        currentOutput: MenuBarBatteryCurrentOutput,
        candidates: [MenuBarBatteryCandidate]
    ) -> MenuBarBatteryCandidate? {
        switch source {
        case .off:
            return nil
        case .pinned(let deviceUID):
            return candidates.first { $0.deviceUID == deviceUID }
        case .currentOutput:
            switch currentOutput {
            case .direct(let deviceUID):
                return candidates.first { $0.deviceUID == deviceUID }
            case .multiOutput(let memberUIDs):
                let members = Set(memberUIDs)
                let matched = candidates.filter { members.contains($0.deviceUID) }
                // 多设备组里有多副可控耳机时没有唯一目标，不能替用户挑一副。
                return matched.count == 1 ? matched[0] : nil
            case .unsupported:
                return nil
            }
        }
    }
}
