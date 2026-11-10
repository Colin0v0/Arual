import Foundation

/// 自动连接只负责时机；不改变音量、噪声模式或路由。
/// 失败锁存与用户主动断开分开，避免两秒一次的设备刷新变成无限重试。
public enum HeadphoneOutputObservation {
    case unavailable
    case confirmed(String?)
}

public struct HeadphoneAutoConnection {
    public private(set) var outputUID: String?
    public private(set) var attempted = false
    public private(set) var userSuppressed = false
    public private(set) var failed = false
    public private(set) var reconnectCount = 0
    public init() {}

    @discardableResult
    public mutating func observe(_ observation: HeadphoneOutputObservation) -> Bool {
        switch observation {
        case .unavailable:
            // 允许快照恢复后重新建立同一控制链；不撤销手动断开或协议失败。
            attempted = false
            return false
        case .confirmed(let uid): return updateOutput(uid)
        }
    }


    @discardableResult
    public mutating func updateOutput(_ uid: String?) -> Bool {
        guard uid != outputUID else { return false }
        outputUID = uid
        attempted = false; userSuppressed = false; failed = false; reconnectCount = 0
        return true
    }

    public mutating func takeInitialAttempt() -> Bool {
        guard outputUID != nil, !attempted, !userSuppressed, !failed else { return false }
        attempted = true
        return true
    }

    public mutating func manualAttempt() {
        userSuppressed = false; failed = false; attempted = true; reconnectCount = 0
    }
    public mutating func suppress() { userSuppressed = true }
    public mutating func recordFailure() { failed = true }
    public mutating func confirmedConnection() { reconnectCount = 0 }

    public mutating func radioOrWakeRecovered() {
        attempted = false; failed = false; reconnectCount = 0
        // 手动断开的意图不能被蓝牙回调或唤醒撤销。
    }

    public mutating func nextReconnectDelay() -> TimeInterval? {
        let delays: [TimeInterval] = [2, 5, 10]
        guard outputUID != nil, !userSuppressed, !failed, reconnectCount < delays.count else { return nil }
        let delay = delays[reconnectCount]
        reconnectCount += 1
        return delay
    }
}

public enum HeadphoneAutoSelection: Equatable {
    case none, choose(UUID), ambiguous
}

public enum HeadphoneIdentity {
    public static func normalizedName(_ name: String) -> String {
        name.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    public static func selection(outputName: String, candidates: [HeadphoneCandidate]) -> HeadphoneAutoSelection {
        // 这里只选择待核验的传输，不认定硬件身份；后续必须通过 RPC 地址严格比对。
        if candidates.count == 1, let candidate = candidates.first { return .choose(candidate.id) }
        let name = normalizedName(outputName)
        guard !name.isEmpty else { return .none }
        let matches = candidates.filter { normalizedName($0.name) == name }
        if matches.count > 1 { return .ambiguous }
        guard let candidate = matches.first else { return .none }
        return .choose(candidate.id)
    }
}

