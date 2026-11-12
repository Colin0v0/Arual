import Foundation

/// 应用路由保存的是用户意图，而不是当时那一组设备的快照。
/// `allOutputs` 会在多设备组变化时自动跟随；`custom` 只保留用户明确勾选的设备集合。
public enum AppAudioRoute: Codable, Equatable, Sendable {
    case allOutputs
    case custom(deviceUIDs: Set<String>)

    public var customDeviceUIDs: Set<String> {
        guard case .custom(let deviceUIDs) = self else { return [] }
        return deviceUIDs
    }

    public var isCustom: Bool {
        if case .custom = self { return true }
        return false
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case deviceUIDs
    }

    private enum Kind: String, Codable {
        case allOutputs
        case custom
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decode(Kind.self, forKey: .kind) {
        case .allOutputs:
            self = .allOutputs
        case .custom:
            let values = try container.decode([String].self, forKey: .deviceUIDs)
            // 路由集合必须稳定且可复现；重复或空 UID 是损坏数据，不能静默修正。
            guard !values.isEmpty,
                  values.allSatisfy({ !$0.isEmpty }),
                  Set(values).count == values.count else {
                throw DecodingError.dataCorruptedError(
                    forKey: .deviceUIDs,
                    in: container,
                    debugDescription: "应用路由包含空值或重复设备 UID"
                )
            }
            self = .custom(deviceUIDs: Set(values))
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .allOutputs:
            try container.encode(Kind.allOutputs, forKey: .kind)
        case .custom(let deviceUIDs):
            guard !deviceUIDs.isEmpty, deviceUIDs.allSatisfy({ !$0.isEmpty }) else {
                throw EncodingError.invalidValue(
                    deviceUIDs,
                    EncodingError.Context(
                        codingPath: container.codingPath,
                        debugDescription: "应用路由不能保存空设备集合"
                    )
                )
            }
            try container.encode(Kind.custom, forKey: .kind)
            // Set 没有稳定顺序；排序后再编码，避免相同配置产生不同持久化结果。
            try container.encode(deviceUIDs.sorted(), forKey: .deviceUIDs)
        }
    }
}

/// 路由解析同时返回“应该保存什么”和“这一轮真正能播放什么”。
/// 两者分开是为了保留暂时断开的设备意图，同时不让当前音频因设备离线而静音。
public struct ResolvedAppAudioRoute: Equatable, Sendable {
    public let persisted: AppAudioRoute
    public let effective: AppAudioRoute
    public let unavailableDeviceUIDs: Set<String>

    public init(persisted: AppAudioRoute,
                effective: AppAudioRoute,
                unavailableDeviceUIDs: Set<String>) {
        self.persisted = persisted
        self.effective = effective
        self.unavailableDeviceUIDs = unavailableDeviceUIDs
    }
}

/// 纯函数路由约束，避免设备变化时在音频回调或 SwiftUI 视图中做集合决策。
public enum AppAudioRouteResolver {
    /// - Parameters:
    ///   - stored: 用户之前保存的路由意图。
    ///   - configuredDeviceUIDs: 当前多设备组中仍被用户勾选的设备，允许暂时离线。
    ///   - activeDeviceUIDs: 当前已确认可播放的组成员。
    public static func resolve(stored: AppAudioRoute,
                               configuredDeviceUIDs: [String],
                               activeDeviceUIDs: [String]) -> ResolvedAppAudioRoute {
        let configured = Set(configuredDeviceUIDs.filter { !$0.isEmpty })
        let active = Set(activeDeviceUIDs.filter { configured.contains($0) })

        switch stored {
        case .allOutputs:
            return ResolvedAppAudioRoute(persisted: .allOutputs,
                                         effective: .allOutputs,
                                         unavailableDeviceUIDs: [])

        case .custom(let requested):
            // 用户已经从多设备组移除的设备不再属于配置；暂时离线但仍被勾选的 UID 会继续保留。
            let retained = requested.intersection(configured)
            guard !retained.isEmpty else {
                return ResolvedAppAudioRoute(persisted: .allOutputs,
                                             effective: .allOutputs,
                                             unavailableDeviceUIDs: [])
            }

            let effectiveTargets = retained.intersection(active)
            let unavailable = retained.subtracting(active)
            if effectiveTargets.isEmpty {
                // 明确按任务约定回退到全部输出，避免设备切换期间应用被永久静音。
                // 保存意图仍保留，设备按稳定 UID 重连后会重新恢复自定义路由。
                return ResolvedAppAudioRoute(persisted: .custom(deviceUIDs: retained),
                                             effective: .allOutputs,
                                             unavailableDeviceUIDs: unavailable)
            }

            return ResolvedAppAudioRoute(
                persisted: .custom(deviceUIDs: retained),
                effective: .custom(deviceUIDs: effectiveTargets),
                unavailableDeviceUIDs: unavailable
            )
        }
    }
}
