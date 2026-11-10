import Foundation

public enum MixSessionAction: Equatable {
    case inactive, awaitRegistration, start, keep, replace
}

/// 冲突与其他错误分开记录：冲突消失可以更新提示，但绝不自动解除失败锁存。
public enum ApplicationMixFailure: Equatable {
    case fineTuneRunning
    case fineTuneExited
    case other(String)

    public var message: String {
        switch self {
        case .fineTuneRunning: return "请先手动退出 FineTune，避免重复处理音频。"
        case .fineTuneExited: return "FineTune 已退出，音量配置尚未应用。"
        case .other(let message): return message
        }
    }
}

/// 只匹配已核实的混音器身份，不按名字包含关系误判其他应用或残留条目。
public enum AudioMixerConflict {
    public static func fineTuneIsRunning(bundleIDs: [String]) -> Bool {
        bundleIDs.contains { $0.lowercased() == "com.finetuneapp.finetune" }
    }
}

/// 这是用户设置的 Aural 增益，不是对目标 App 内部音量的读数。
/// 管理意图、实际会话、失败原因分开建模，避免滑杆已变而误报音频已应用。
public struct ApplicationMixState: Equatable {
    public private(set) var gain: Float = 1
    public private(set) var muted = false
    public private(set) var managed = false
    public private(set) var boundOutputUID: String?
    public private(set) var failureReason: ApplicationMixFailure?
    public var failure: String? { failureReason?.message }
    public init() {}

    public mutating func setGain(_ value: Float) throws {
        guard value.isFinite, (0...1).contains(value) else { throw AudioFailure("应用增益必须在 0～100% 之间") }
        gain = value
    }
    public mutating func toggleMute() { muted.toggle() }
    public mutating func enable(outputUID: String) {
        managed = true; boundOutputUID = outputUID; failureReason = nil
    }
    public mutating func disable() { managed = false; boundOutputUID = nil; failureReason = nil }
    public mutating func fail(_ message: String) { failureReason = .other(message) }
    public mutating func blockForFineTune() { failureReason = .fineTuneRunning }

    public mutating func updateFineTuneAvailability(isRunning: Bool) {
        // 只更新同一类冲突，不覆盖权限、路由、清理失败；退出后仍需明确重新应用。
        guard failureReason == .fineTuneRunning || failureReason == .fineTuneExited else { return }
        failureReason = isRunning ? .fineTuneRunning : .fineTuneExited
    }

    @discardableResult
    public mutating func pauseIfOutputChanged(currentUID: String) -> Bool {
        guard managed, boundOutputUID != currentUID else { return false }
        if failure == nil { fail("系统输出已改变；点重新应用后才会在新设备上处理。") }
        return true
    }

    public func action(group: AudioProcessGroup?, sessionObjectIDs: [UInt32]?) -> MixSessionAction {
        guard managed, failure == nil else { return .inactive }
        guard let group else { return .awaitRegistration }
        guard let sessionObjectIDs else { return .start }
        return sessionObjectIDs == group.objectIDs ? .keep : .replace
    }
}

/// 空闲期不启动“无音频回调”计时；输出活跃之后才检查是否持续没有进展。
public struct AudioActivityWatchdog {
    private var previousCallbacks: UInt64 = 0
    private var lastProgress: Date?
    public init() {}

    public mutating func isStalled(expectingAudio: Bool, callbacks: UInt64, at now: Date) -> Bool {
        guard expectingAudio else {
            previousCallbacks = callbacks; lastProgress = nil; return false
        }
        if lastProgress == nil || callbacks != previousCallbacks {
            lastProgress = now; previousCallbacks = callbacks; return false
        }
        guard let lastProgress else { return false }
        return now.timeIntervalSince(lastProgress) > 8
    }
}

/// 身份迁移不转移尚未释放的 HAL 资源所有权；行 ID 不同也不能重叠捕获。
public enum AudioSessionOwnership {
    public static func overlaps(requested: [UInt32], existing: [[UInt32]]) -> Bool {
        let requested = Set(requested)
        return existing.contains { !requested.isDisjoint(with: $0) }
    }
}
