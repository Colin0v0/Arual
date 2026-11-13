import Foundation

/// 内置预设只提供明确的听感起点；用户修改后的参数会单独保存，不会覆盖内置定义。
public enum AppAudioEffectPreset: String, Codable, CaseIterable, Sendable {
    case flat
    case voice
    case podcast
    case music
    case movie
    case bassBoost

    public var gains: AppAudioEffectEQ {
        switch self {
        case .flat:
            return .flat
        case .voice:
            return AppAudioEffectEQ(gainsDB: [-4, -3, -1, 1, 4, 4, 2, 0, -2, -3])
        case .podcast:
            return AppAudioEffectEQ(gainsDB: [-3, -2, 0, 2, 3, 2, 1, 0, -2, -3])
        case .music:
            return AppAudioEffectEQ(gainsDB: [1.5, 1, 0, -0.5, 0, 0.5, 1, 1.5, 1, 0.5])
        case .movie:
            return AppAudioEffectEQ(gainsDB: [3, 2, 1, 0, 0.5, 1, 2, 2, 1, 0])
        case .bassBoost:
            return AppAudioEffectEQ(gainsDB: [7, 6, 4, 2, 0, -1, -1, 0, 1, 1])
        }
    }
}

/// 当前预设既可能是内置项、用户保存的预设，也可能已经手动修改而不再对应任何预设。
public enum AppAudioEffectPresetSelection: Codable, Equatable, Sendable {
    case builtIn(AppAudioEffectPreset)
    case custom(UUID)
    case manual
}

/// 空间效果与 EQ 是两条独立的听感维度：EQ 调频响，空间效果只增加房间反射。
/// 模式顺序同时用于参数原子字编码，后续新增模式只能追加，不能插入到中间。
public enum AppAudioSpatialMode: String, Codable, CaseIterable, Sendable {
    case off
    case room
    case hall
    case vocalSpace

    public var isEnabled: Bool { self != .off }

    /// 实时原子字只搬运小型整数索引，不把字符串查询带进音频线程。
    var parameterIndex: UInt64 {
        switch self {
        case .off: return 0
        case .room: return 1
        case .hall: return 2
        case .vocalSpace: return 3
        }
    }

    init(parameterIndex: UInt64) {
        switch parameterIndex {
        case 1: self = .room
        case 2: self = .hall
        case 3: self = .vocalSpace
        default: self = .off
        }
    }
}

/// 混响强度与模式分开保存。切到“关闭”时保留用户上次的强度，重新开启不会恢复成默认值。
public struct AppAudioSpatialSettings: Codable, Equatable, Sendable {
    public static let minimumIntensity: Float = 0
    public static let maximumIntensity: Float = 1
    public static let defaultIntensity: Float = 0.2
    public static let intensityStep: Float = 0.01
    public static let disabled = AppAudioSpatialSettings()

    public var mode: AppAudioSpatialMode
    public var intensity: Float

    public init(mode: AppAudioSpatialMode = .off,
                intensity: Float = AppAudioSpatialSettings.defaultIntensity) {
        self.mode = mode
        self.intensity = Self.snappedIntensity(intensity)
    }

    public var isEnabled: Bool { mode.isEnabled }

    public static func snappedIntensity(_ value: Float) -> Float {
        guard value.isFinite else { return defaultIntensity }
        let clamped = min(max(value, minimumIntensity), maximumIntensity)
        return (clamped / intensityStep).rounded() * intensityStep
    }

    public var isValid: Bool {
        intensity.isFinite
            && (Self.minimumIntensity...Self.maximumIntensity).contains(intensity)
            && abs(intensity - Self.snappedIntensity(intensity)) < 0.001
    }

    public mutating func setIntensity(_ value: Float) {
        intensity = Self.snappedIntensity(value)
    }
}

/// 固定十个频段，数组顺序就是界面从左到右的顺序。
/// 使用固定长度而不是三条独立字段，避免界面、持久化和实时参数出现不同步。
public struct AppAudioEffectEQ: Codable, Equatable, Sendable {
    public static let frequencies: [Float] = [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000]
    public static let bandCount = frequencies.count
    public static let flat = AppAudioEffectEQ(gainsDB: Array(repeating: 0, count: bandCount))

    public var gainsDB: [Float]

    public init(gainsDB: [Float]) {
        precondition(gainsDB.count == Self.bandCount, "应用音效必须始终包含十个频段")
        self.gainsDB = gainsDB
    }

    /// 所有持久化与实时参数统一吸附到 0.5 dB，避免界面读数和 UInt64 原子字出现不同值。
    public static func snappedGain(_ gainDB: Float) -> Float {
        let clamped = min(max(gainDB, AppAudioEffectSettings.minimumGainDB),
                          AppAudioEffectSettings.maximumGainDB)
        return (clamped * 2).rounded() / 2
    }

    public var snapped: AppAudioEffectEQ {
        AppAudioEffectEQ(gainsDB: gainsDB.map(Self.snappedGain))
    }

    public subscript(index: Int) -> Float {
        get { gainsDB[index] }
        set { gainsDB[index] = newValue }
    }

    public var maximumPositiveGainDB: Float {
        max(0, gainsDB.max() ?? 0)
    }

    public var isValid: Bool {
        gainsDB.count == Self.bandCount && gainsDB.allSatisfy {
            $0.isFinite
                && (AppAudioEffectSettings.minimumGainDB...AppAudioEffectSettings.maximumGainDB).contains($0)
                && abs($0 - Self.snappedGain($0)) < 0.001
        }
    }

    public func matches(_ preset: AppAudioEffectPreset) -> Bool {
        let expected = preset.gains.gainsDB
        return zip(gainsDB, expected).allSatisfy { abs($0 - $1) < 0.001 }
    }

    private enum CodingKeys: String, CodingKey {
        case gainsDB
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let gains = try container.decode([Float].self, forKey: .gainsDB)
        guard gains.count == Self.bandCount,
              gains.allSatisfy({
                  $0.isFinite
                      && (AppAudioEffectSettings.minimumGainDB...AppAudioEffectSettings.maximumGainDB).contains($0)
              }) else {
            throw DecodingError.dataCorruptedError(
                forKey: .gainsDB,
                in: container,
                debugDescription: "应用音效必须包含十个有效增益"
            )
        }
        // 早期十段原型曾写入任意浮点；读取时显式规范化到界面和实时参数共用的 0.5 dB 档位。
        gainsDB = gains.map(Self.snappedGain)
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(gainsDB, forKey: .gainsDB)
    }
}

/// 用户创建的音效预设全局共享；每个 App 只保存所选预设 ID 和自己当前的十段参数。
public struct AppAudioEffectCustomPreset: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var eq: AppAudioEffectEQ

    public init(id: UUID = UUID(), name: String, eq: AppAudioEffectEQ) {
        self.id = id
        self.name = name
        self.eq = eq.snapped
    }

    public var isValid: Bool {
        !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && name.count <= 40
            && eq.isValid
    }
}

/// 每个应用的音效意图按 bundle 身份持久化，不包含 PID、音频对象或设备句柄。
/// 未启用的记录仍可保留预设和频段位置，但绝不会进入音频回调的处理分支。
public struct AppAudioEffectSettings: Codable, Equatable, Sendable {
    public static let minimumGainDB: Float = -12
    public static let maximumGainDB: Float = 12

    public var enabled: Bool
    public var preset: AppAudioEffectPresetSelection
    public var eq: AppAudioEffectEQ
    public var spatial: AppAudioSpatialSettings

    public init(enabled: Bool = false,
                preset: AppAudioEffectPresetSelection = .builtIn(.flat),
                eq: AppAudioEffectEQ = .flat,
                spatial: AppAudioSpatialSettings = .disabled) {
        self.enabled = enabled
        self.preset = preset
        self.eq = eq.snapped
        self.spatial = spatial
    }

    public init(enabled: Bool = false, preset: AppAudioEffectPreset) {
        self.init(enabled: enabled, preset: .builtIn(preset), eq: preset.gains)
    }

    private enum CodingKeys: String, CodingKey {
        case enabled
        case preset
        case eq
        case spatial
        case lowGainDB
        case midGainDB
        case highGainDB
    }

    /// 0.3.0 原型曾把三段增益按三个独立字段保存；正式十段模型遇到该结构时按明确规则迁移。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try container.decode(Bool.self, forKey: .enabled)
        if container.contains(.eq) {
            preset = try container.decode(AppAudioEffectPresetSelection.self, forKey: .preset)
            eq = try container.decode(AppAudioEffectEQ.self, forKey: .eq)
            // 0.3.0 没有空间字段；旧记录明确迁移为关闭，不推测任何房间模式。
            spatial = container.contains(.spatial)
                ? try container.decode(AppAudioSpatialSettings.self, forKey: .spatial)
                : .disabled
        } else {
            let legacyPreset = try container.decode(String.self, forKey: .preset)
            let low = try container.decode(Float.self, forKey: .lowGainDB)
            let mid = try container.decode(Float.self, forKey: .midGainDB)
            let high = try container.decode(Float.self, forKey: .highGainDB)
            let legacyGains = [low, mid, high]
            guard legacyGains.allSatisfy({
                $0.isFinite
                    && (Self.minimumGainDB...Self.maximumGainDB).contains($0)
            }) else {
                throw DecodingError.dataCorruptedError(
                    forKey: .lowGainDB,
                    in: container,
                    debugDescription: "旧版应用音效增益无效"
                )
            }
            let migrated = Self.migrate(legacyPreset: legacyPreset,
                                        low: low, mid: mid, high: high)
            preset = migrated.preset
            eq = migrated.eq
            spatial = .disabled
        }
        guard isValid else {
            throw DecodingError.dataCorrupted(
                DecodingError.Context(codingPath: decoder.codingPath,
                                      debugDescription: "应用音效预设与十段参数不一致")
            )
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(enabled, forKey: .enabled)
        try container.encode(preset, forKey: .preset)
        try container.encode(eq, forKey: .eq)
        try container.encode(spatial, forKey: .spatial)
    }

    public static let disabled = AppAudioEffectSettings()

    /// 自动 Preamp 只抵消最大的正增益。负增益不会被反向放大，避免安静预设反而更响。
    public var preampDB: Float {
        -eq.maximumPositiveGainDB
    }

    /// 持久化层在写入和回读时都使用同一套范围校验，拒绝损坏数据而不是静默修正。
    public var isValid: Bool {
        guard eq.isValid, spatial.isValid else { return false }
        if case .builtIn(let preset) = self.preset {
            return eq.matches(preset)
        }
        return true
    }

    public mutating func apply(_ preset: AppAudioEffectPreset) {
        self.preset = .builtIn(preset)
        eq = preset.gains
    }

    public mutating func apply(custom preset: AppAudioEffectCustomPreset) {
        self.preset = .custom(preset.id)
        eq = preset.eq.snapped
    }

    public mutating func setGain(_ value: Float, at index: Int) {
        guard eq.gainsDB.indices.contains(index) else { return }
        var next = eq
        next[index] = AppAudioEffectEQ.snappedGain(value)
        eq = next
        // 调整任一频段都进入手动状态；custom 需要保留具体用户预设 ID，不能用单一 case 表达。
        preset = .manual
    }

    public static func matchingBuiltInPreset(for eq: AppAudioEffectEQ) -> AppAudioEffectPreset? {
        AppAudioEffectPreset.allCases.first { eq.matches($0) }
    }

    /// 旧命名预设映射到新的十段起点；手动三段参数按低、中、高频附近展开，保留用户原本的音色倾向。
    private static func migrate(legacyPreset: String, low: Float, mid: Float,
                                high: Float) -> (preset: AppAudioEffectPresetSelection,
                                                 eq: AppAudioEffectEQ) {
        guard let known = LegacyAppAudioEffectPreset(rawValue: legacyPreset),
              known.matches(low: low, mid: mid, high: high) else {
            return (.manual, Self.expandedLegacyEQ(low: low, mid: mid, high: high))
        }
        return (known.selection, known.eq)
    }

    private static func expandedLegacyEQ(low: Float, mid: Float,
                                         high: Float) -> AppAudioEffectEQ {
        let values: [Float] = [
            low,
            low,
            low * 0.8,
            mid * 0.35,
            mid,
            mid,
            mid * 0.6,
            high * 0.55,
            high,
            high
        ]
        return AppAudioEffectEQ(gainsDB: values.map(AppAudioEffectEQ.snappedGain(_:)))
    }
}

/// 旧三段模型中的预设名称与增益组合，只用于一次性数据迁移，不进入新 UI 或实时音频路径。
private enum LegacyAppAudioEffectPreset: String {
    case flat
    case voice
    case music
    case movie
    case bassBoost
    case custom

    var gains: (low: Float, mid: Float, high: Float) {
        switch self {
        case .flat: return (0, 0, 0)
        case .voice: return (-2, 4, -1)
        case .music: return (2, 0, 2)
        case .movie: return (2, 1, 1)
        case .bassBoost: return (7, 0, 1)
        case .custom: return (0, 0, 0)
        }
    }

    var selection: AppAudioEffectPresetSelection {
        switch self {
        case .flat: return .builtIn(.flat)
        case .voice: return .builtIn(.voice)
        case .music: return .builtIn(.music)
        case .movie: return .builtIn(.movie)
        case .bassBoost: return .builtIn(.bassBoost)
        case .custom: return .manual
        }
    }

    var eq: AppAudioEffectEQ {
        switch self {
        case .flat: return AppAudioEffectPreset.flat.gains
        case .voice: return AppAudioEffectPreset.voice.gains
        case .music: return AppAudioEffectPreset.music.gains
        case .movie: return AppAudioEffectPreset.movie.gains
        case .bassBoost: return AppAudioEffectPreset.bassBoost.gains
        case .custom: return .flat
        }
    }

    func matches(low: Float, mid: Float, high: Float) -> Bool {
        guard self != .custom else { return false }
        let expected = gains
        return abs(expected.low - low) < 0.001
            && abs(expected.mid - mid) < 0.001
            && abs(expected.high - high) < 0.001
    }
}
