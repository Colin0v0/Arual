// 部分规则与 ANC 线值派生自 HeadBridge（MIT）。
// Upstream: 5e577cb4a91a515b95596fcc4b362a86ecb639a5
// 来源：Core/HeadphoneProvider.swift、Providers/BowersWilkins/BowersWilkinsProvider.swift。
import Foundation

/// 型号名称只负责选择驱动；连接后的真实协议响应才决定可用能力。
public enum HeadphoneFamily: String, CaseIterable, Sendable {
    case bowersWilkins, sony, oppo, apple

    public var title: String {
        switch self {
        case .bowersWilkins: return "Bowers & Wilkins"
        case .sony: return "Sony MDR"
        case .oppo: return "OPPO Enco"
        case .apple: return "Apple / Beats"
        }
    }

    public static func recognize(_ name: String) -> Self? {
        let normalized = HeadphoneIdentity.normalizedName(name)
        if ["px7", "px8", "pi5", "pi6", "pi7", "pi8"].contains(where: normalized.contains)
            || (normalized.contains("bowerswilkins") && (normalized.contains("headphone") || normalized.contains("headset"))) {
            return .bowersWilkins
        }
        // 与上游 Sony provider 相同的型号家族预筛选，不把所有 Sony 电子设备当成耳机。
        let lower = name.lowercased()
        if ["wh-", "wf-", "wi-", "mdr-", "linkbuds", "ult wear", "ultwear"].contains(where: lower.contains)
            || (lower.contains("sony") && (lower.contains("headphone") || lower.contains("headset"))) {
            return .sony
        }
        if normalized.contains("oppo") && normalized.contains("enco") { return .oppo }
        return nil
    }

    static func isBowersWilkinsAdvertisement(_ name: String) -> Bool {
        recognize(name) == .bowersWilkins || HeadphoneIdentity.normalizedName(name) == "lebwhp"
    }
}

/// ANC 线值不是跨型号通用常量；原代 Px8 与 Px7 S3 不同，不能直接写 rawValue。
enum BowersWilkinsNoiseProfile: Equatable {
    case standard, originalPx8, unverified

    static func identify(outputName: String, advertisedName: String) -> Self {
        let name = HeadphoneIdentity.normalizedName(outputName)
        if name.hasSuffix("px8") { return .originalPx8 }
        if HeadphoneIdentity.normalizedName(advertisedName) == "lebwhp" { return .unverified }
        return .standard
    }

    func wireValue(for mode: NoiseMode) -> Int? {
        guard mode != .windReduction, mode != .adaptive else { return nil }
        switch self {
        case .standard: return mode.rawValue
        case .originalPx8: return mode.rawValue + 1
        case .unverified: return nil
        }
    }

    func mode(for value: Int) -> NoiseMode? {
        let mode: NoiseMode?
        switch self {
        case .standard: mode = NoiseMode(rawValue: value)
        case .originalPx8: mode = NoiseMode(rawValue: value - 1)
        case .unverified: mode = nil
        }
        guard mode != .windReduction, mode != .adaptive else { return nil }
        return mode
    }
}
