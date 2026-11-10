import Foundation
import Synchronization

/// 同一条 Process Tap 的两种明确用途，不在失败后切换模式或后端。
public enum ApplicationAudioMode: Equatable, Sendable {
    case metering
    case mixing
}

/// 音频线程单次原子取最大值，主线程交换归零，保留两次刷新之间的短暂峰值。
/// 正的 Float 位模式与数值同序；不传递样本、分配内存或等待互斥锁。
final class AudioPeakMailbox {
    private let peak = Atomic<UInt32>(0)

    func publish(_ value: Float) {
        guard value.isFinite, value > 0 else { return }
        _ = peak.max(value.bitPattern, ordering: .relaxed)
    }

    func consume() -> Float {
        Float(bitPattern: peak.exchange(0, ordering: .relaxed))
    }
}

/// 快速上升、约 250ms 回落；先在幅值域平滑，再映射到 -60…0 dBFS。
public struct AudioLevelEnvelope {
    private var amplitude: Float = 0
    private var previousTime: TimeInterval?
    public init() {}

    public mutating func update(peak: Float, at time: TimeInterval) -> Float {
        let elapsed = previousTime.map { max(0, time - $0) } ?? 0
        previousTime = time
        let falling = amplitude * Float(exp(-elapsed / 0.25))
        amplitude = max(peak.isFinite ? max(0, peak) : 0, falling)
        return Self.normalized(amplitude)
    }

    public static func normalized(_ amplitude: Float) -> Float {
        guard amplitude.isFinite, amplitude > 0 else { return 0 }
        let decibels = 20 * log10(amplitude)
        return min(1, max(0, (decibels + 60) / 60))
    }
}

/// 把播放、可见性与用户管理意图区分开；只读计量不意味着启用音量接管。
public enum ApplicationAudioIntent {
    public static func mode(state: ApplicationMixState, isPlaying: Bool, meterVisible: Bool) -> ApplicationAudioMode? {
        guard state.failure == nil else { return nil }
        if state.managed { return .mixing }
        return isPlaying && meterVisible ? .metering : nil
    }
}
