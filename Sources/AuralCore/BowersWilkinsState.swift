import Foundation

public enum NoiseMode: Int, CaseIterable, Identifiable, Sendable {
    case off = 0, cancellation = 1, transparency = 2, windReduction = 3, adaptive = 4
    public var id: Int { rawValue }
    public var title: String {
        switch self {
        case .off: return "关闭"
        case .cancellation: return "降噪"
        case .transparency: return "透传"
        case .windReduction: return "抗风噪"
        case .adaptive: return "自适应"
        }
    }
    public var symbol: String {
        switch self {
        case .off: return "waveform"
        case .cancellation: return "waveform.badge.minus"
        case .transparency: return "ear"
        case .windReduction: return "wind"
        case .adaptive: return "waveform.path.ecg"
        }
    }
}

/// 未读取不等于“关闭”或“没电”。数值只由成功、合法的真实响应赋值。
public struct BowersWilkinsState: Equatable {
    public private(set) var battery: Int?
    public private(set) var isCharging: Bool?
    public private(set) var noiseMode: NoiseMode?
    public init() {}

    /// 只有尚未确认过的可选 ANC 探测可以拒绝；已有读数后的拒绝必须按 RPC 错误处理。
    mutating func applyRefresh(_ message: BWRPCMessage, profile: BowersWilkinsNoiseProfile) throws -> Bool {
        // 充电能力尚未确认时，设备可以明确拒绝该可选查询。
        if message.command == BWRPCatalog.chargingGet, !message.succeeded, isCharging == nil { return false }
        if message.command == BWRPCatalog.ancGet, !message.succeeded, noiseMode == nil { return false }
        try apply(message, profile: profile)
        return true
    }

    mutating func apply(_ message: BWRPCMessage, profile: BowersWilkinsNoiseProfile = .standard) throws {
        guard message.succeeded else { throw AudioFailure("耳机拒绝命令 \(message.command.key)（错误 \(message.errorCode)）") }
        switch message.command {
        case BWRPCatalog.batteryGet:
            guard let value = message.payload?.intValue, (0...100).contains(value) else {
                throw AudioFailure("耳机返回了无效电量")
            }
            battery = value
        case BWRPCatalog.chargingGet:
            guard let value = message.payload?.boolValue else {
                throw AudioFailure("耳机返回了无效充电状态")
            }
            isCharging = value
        case BWRPCatalog.ancGet:
            guard let value = message.payload?.intValue, let mode = profile.mode(for: value) else {
                throw AudioFailure("耳机返回了未支持的降噪模式")
            }
            noiseMode = mode
        default: break
        }
    }

}
