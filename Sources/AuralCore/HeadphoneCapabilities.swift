import Foundation

/// 电量能力只描述界面能够呈现的数据形状，不表示当前已经读到电量。
public enum HeadphoneBatteryCapability: String, Codable, Sendable {
    case single
    case earbudsWithCase
}

/// 某副耳机已经确认的噪声控制能力。
///
/// `modes` 的顺序就是界面显示顺序；`currentMode` 必须来自设备回读，
/// 不能因为界面默认值或上一次连接状态而提前填充。
public struct HeadphoneNoiseCapability: Equatable, Sendable {
    public var modes: [NoiseMode]
    public var currentMode: NoiseMode?
    public var ambientLevelRange: ClosedRange<Int>?

    public init(
        modes: [NoiseMode],
        currentMode: NoiseMode?,
        ambientLevelRange: ClosedRange<Int>? = nil
    ) {
        self.modes = modes
        self.currentMode = currentMode
        self.ambientLevelRange = ambientLevelRange
    }

    public var modeCount: Int { modes.count }
}

/// 控制器只发布这里明确存在的能力。
///
/// 型号表可以提供候选模式，但电池、当前降噪模式和可选模式仍要由协议回包确认。
public struct HeadphoneCapabilities: Equatable, Sendable {
    public var battery: HeadphoneBatteryCapability?
    public var noise: HeadphoneNoiseCapability?

    public init(
        battery: HeadphoneBatteryCapability? = nil,
        noise: HeadphoneNoiseCapability? = nil
    ) {
        self.battery = battery
        self.noise = noise
    }

    public static let none = HeadphoneCapabilities()

    public var noiseModes: [NoiseMode] { noise?.modes ?? [] }
    public var noiseModeCount: Int { noise?.modeCount ?? 0 }
}

/// 兼容性只描述验证证据，不参与协议分支。
public enum HeadphoneCompatibilityStatus: String, Codable, Sendable {
    /// Aural 当前版本在对应硬件上完成过验收。
    case verified
    /// 上游项目或协议资料在对应硬件上验证过，Aural 仍需独立复验。
    case upstreamVerified
    /// 社区成员在对应硬件上完成过基础验证。
    case communityTested
    /// 已按公开协议实现或登记，但还没有完成真机验证。
    case experimental
}

/// 型号表只负责把可编辑的设备名称映射到已知能力形状。
///
/// 真正的驱动选择仍由 `HeadphoneFamily` 负责；连接成功后的协议回包才决定
/// 某项能力是否可以出现在界面上。
public struct HeadphoneModelProfile: Equatable, Sendable, Identifiable {
    public let id: String
    public let family: HeadphoneFamily
    public let displayName: String
    public let compatibility: HeadphoneCompatibilityStatus
    public let battery: HeadphoneBatteryCapability?
    /// 型号预期的全部模式；可选模式仍要等待设备明确回报。
    public let noiseModes: [NoiseMode]
    /// 只有设备回报支持时才展示的模式，例如 Sony 的抗风噪。
    public let optionalNoiseModes: Set<NoiseMode>
    let matchTerms: [String]

    public init(
        id: String,
        family: HeadphoneFamily,
        displayName: String,
        compatibility: HeadphoneCompatibilityStatus,
        battery: HeadphoneBatteryCapability?,
        noiseModes: [NoiseMode],
        optionalNoiseModes: Set<NoiseMode> = [],
        matchTerms: [String]
    ) {
        self.id = id
        self.family = family
        self.displayName = displayName
        self.compatibility = compatibility
        self.battery = battery
        self.noiseModes = noiseModes
        self.optionalNoiseModes = optionalNoiseModes
        self.matchTerms = matchTerms.map(HeadphoneIdentity.normalizedName)
    }

    public var noiseModeCount: Int { noiseModes.count }

    /// 从型号预期模式中移除尚未得到设备确认的可选模式。
    public func resolvedNoiseModes(confirmedOptionalModes: Set<NoiseMode>) -> [NoiseMode] {
        noiseModes.filter { mode in
            !optionalNoiseModes.contains(mode) || confirmedOptionalModes.contains(mode)
        }
    }

    func matchedTermLength(in outputName: String) -> Int? {
        let normalized = HeadphoneIdentity.normalizedName(outputName)
        return matchTerms
            .filter { !$0.isEmpty && normalized.contains($0) }
            .map(\.count)
            .max()
    }
}

/// 当前内置型号表。
///
/// 这张表可以按型号记录不同档数，但不能把未验证型号写成已验证。新增协议后，
/// 优先补充这里和 `docs/HEADPHONE_COMPATIBILITY.md`，不要继续堆品牌分支。
public enum HeadphoneModelCatalog {
    public static let profiles: [HeadphoneModelProfile] = [
        // Bowers & Wilkins 当前公开的 ANC 控制均为关闭、降噪、透传三档。
        HeadphoneModelProfile(
            id: "bw-px7-s3",
            family: .bowersWilkins,
            displayName: "Bowers & Wilkins Px7 S3",
            compatibility: .upstreamVerified,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["px7s3"]
        ),
        HeadphoneModelProfile(
            id: "bw-px7-s2",
            family: .bowersWilkins,
            displayName: "Bowers & Wilkins Px7 S2",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["px7s2"]
        ),
        HeadphoneModelProfile(
            id: "bw-px8",
            family: .bowersWilkins,
            displayName: "Bowers & Wilkins Px8",
            compatibility: .upstreamVerified,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["px8"]
        ),
        HeadphoneModelProfile(
            id: "bw-pi5",
            family: .bowersWilkins,
            displayName: "Bowers & Wilkins Pi5",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["pi5"]
        ),
        HeadphoneModelProfile(
            id: "bw-pi6",
            family: .bowersWilkins,
            displayName: "Bowers & Wilkins Pi6",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["pi6"]
        ),
        HeadphoneModelProfile(
            id: "bw-pi7",
            family: .bowersWilkins,
            displayName: "Bowers & Wilkins Pi7",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["pi7"]
        ),
        HeadphoneModelProfile(
            id: "bw-pi8",
            family: .bowersWilkins,
            displayName: "Bowers & Wilkins Pi8",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["pi8"]
        ),

        // Sony V1 的基础模式固定，抗风噪必须由设备回报 NC type 后才显示。
        HeadphoneModelProfile(
            id: "sony-wh-1000xm3",
            family: .sony,
            displayName: "Sony WH-1000XM3",
            compatibility: .upstreamVerified,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency, .windReduction],
            optionalNoiseModes: [.windReduction],
            matchTerms: ["wh1000xm3"]
        ),
        HeadphoneModelProfile(
            id: "sony-wh-1000xm2",
            family: .sony,
            displayName: "Sony WH-1000XM2",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency, .windReduction],
            optionalNoiseModes: [.windReduction],
            matchTerms: ["wh1000xm2"]
        ),
        HeadphoneModelProfile(
            id: "sony-wh-1000xm4",
            family: .sony,
            displayName: "Sony WH-1000XM4",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency, .windReduction],
            optionalNoiseModes: [.windReduction],
            matchTerms: ["wh1000xm4"]
        ),
        HeadphoneModelProfile(
            id: "sony-wf-1000xm3",
            family: .sony,
            displayName: "Sony WF-1000XM3",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency, .windReduction],
            optionalNoiseModes: [.windReduction],
            matchTerms: ["wf1000xm3"]
        ),
        HeadphoneModelProfile(
            id: "sony-wf-sp800n",
            family: .sony,
            displayName: "Sony WF-SP800N",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency, .windReduction],
            optionalNoiseModes: [.windReduction],
            matchTerms: ["wfsp800n"]
        ),
        HeadphoneModelProfile(
            id: "sony-wi-sp600n",
            family: .sony,
            displayName: "Sony WI-SP600N",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency, .windReduction],
            optionalNoiseModes: [.windReduction],
            matchTerms: ["wi-sp600n"]
        ),
        HeadphoneModelProfile(
            id: "sony-mdr-1000x",
            family: .sony,
            displayName: "Sony MDR-1000X",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency, .windReduction],
            optionalNoiseModes: [.windReduction],
            matchTerms: ["mdr1000x"]
        ),

        // Sony V2 使用新的 RFCOMM 服务和 0x17 噪声控制子类型。
        // V2 的三种基础模式已经被 ULT WEAR 的 MIT 实测资料和 XM5 的
        // 公开抓包确认；未在 Aural 的本机硬件上复验前不能标为 verified。
        HeadphoneModelProfile(
            id: "sony-wh-1000xm5",
            family: .sony,
            displayName: "Sony WH-1000XM5",
            compatibility: .upstreamVerified,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["wh1000xm5"]
        ),
        HeadphoneModelProfile(
            id: "sony-wh-1000xm6",
            family: .sony,
            displayName: "Sony WH-1000XM6",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["wh1000xm6"]
        ),
        HeadphoneModelProfile(
            id: "sony-wf-1000xm4",
            family: .sony,
            displayName: "Sony WF-1000XM4",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["wf1000xm4"]
        ),
        HeadphoneModelProfile(
            id: "sony-wf-1000xm5",
            family: .sony,
            displayName: "Sony WF-1000XM5",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["wf1000xm5"]
        ),
        HeadphoneModelProfile(
            id: "sony-wf-1000xm6",
            family: .sony,
            displayName: "Sony WF-1000XM6",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["wf1000xm6"]
        ),
        HeadphoneModelProfile(
            id: "sony-wh-ch720n",
            family: .sony,
            displayName: "Sony WH-CH720N",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["whch720n"]
        ),
        HeadphoneModelProfile(
            id: "sony-ult-wear",
            family: .sony,
            displayName: "Sony ULT WEAR",
            compatibility: .upstreamVerified,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["ultwear"]
        ),
        HeadphoneModelProfile(
            id: "sony-linkbuds-s",
            family: .sony,
            displayName: "Sony LinkBuds S",
            compatibility: .experimental,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["linkbudss", "wfls900n"]
        ),

        HeadphoneModelProfile(
            id: "oppo-enco-air5s",
            family: .oppo,
            displayName: "OPPO Enco Air5s",
            compatibility: .upstreamVerified,
            battery: .single,
            noiseModes: [.off, .cancellation, .transparency],
            matchTerms: ["oppoencoair5s"]
        ),
    ]

    /// 型号名可能互相包含，因此选择匹配词最长的 profile。
    public static func profile(for outputName: String, family: HeadphoneFamily) -> HeadphoneModelProfile? {
        profiles
            .filter { $0.family == family }
            .compactMap { profile in
                profile.matchedTermLength(in: outputName).map { (profile, $0) }
            }
            .max { lhs, rhs in lhs.1 < rhs.1 }?
            .0
    }
}
