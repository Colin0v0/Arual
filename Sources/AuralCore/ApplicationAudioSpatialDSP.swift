import Foundation

/// 空间参数同样压进一个原子字。音频线程每块只读取一次，不接触界面模型或持久化数据。
enum AppAudioSpatialParameterWord {
    static let intensityCount: UInt64 = 101
    static let modeShift: UInt64 = 0
    static let intensityShift: UInt64 = 2

    static func intensityIndex(for intensity: Float) -> UInt64 {
        let index = (AppAudioSpatialSettings.snappedIntensity(intensity) * 100).rounded()
        return UInt64(min(max(Int(index), 0), Int(intensityCount - 1)))
    }

    static func intensity(for index: UInt64) -> Float {
        Float(min(index, intensityCount - 1)) / 100
    }

    static func pack(_ settings: AppAudioEffectSettings?) -> UInt64 {
        guard let settings, settings.enabled, settings.spatial.mode.isEnabled else { return 0 }
        let mode = settings.spatial.mode.parameterIndex
        let intensity = intensityIndex(for: settings.spatial.intensity)
        return mode | (intensity << intensityShift)
    }

    static func mode(in word: UInt64) -> AppAudioSpatialMode {
        AppAudioSpatialMode(parameterIndex: (word >> modeShift) & 0x3)
    }

    static func intensity(in word: UInt64) -> Float {
        intensity(for: (word >> intensityShift) & 0x7F)
    }
}

/// 单个空间模式仅改变反馈、阻尼、预延迟和立体声宽度。
/// 延迟线容量在会话启动前一次性分配，模式切换时只改参数并清空旧尾音。
private struct AppAudioSpatialTuning {
    let feedback: Float
    let damping: Float
    let preDelaySeconds: Double
    let width: Float
    let inputCrossFeed: Float

    static func value(for mode: AppAudioSpatialMode) -> AppAudioSpatialTuning {
        switch mode {
        case .off:
            return AppAudioSpatialTuning(feedback: 0, damping: 1,
                                         preDelaySeconds: 0, width: 0, inputCrossFeed: 0)
        case .room:
            return AppAudioSpatialTuning(feedback: 0.80, damping: 0.52,
                                         preDelaySeconds: 0.008, width: 0.82,
                                         inputCrossFeed: 0.14)
        case .hall:
            return AppAudioSpatialTuning(feedback: 0.90, damping: 0.34,
                                         preDelaySeconds: 0.030, width: 1.0,
                                         inputCrossFeed: 0.24)
        case .vocalSpace:
            return AppAudioSpatialTuning(feedback: 0.84, damping: 0.58,
                                         preDelaySeconds: 0.014, width: 0.64,
                                         inputCrossFeed: 0.10)
        }
    }
}

/// Freeverb 结构的固定八梳状滤波、四全通滤波实现。
/// 所有数组、索引和阻尼状态都在初始化时准备；实时路径没有分配、哈希查询或 HAL 访问。
struct AppAudioSpatialDSP {
    private static let combDelays = [1_116, 1_188, 1_277, 1_356,
                                     1_422, 1_491, 1_557, 1_617]
    private static let allpassDelays = [556, 441, 341, 225]
    private static let channelCount = 2
    private static let combCount = combDelays.count
    private static let allpassCount = allpassDelays.count
    private static let inputGain: Float = 0.015
    private static let wetOutputGain: Float = 2.8
    private static let silenceThreshold: Float = 0.000_001

    private let sampleRate: Double
    private let wetStep: Float
    private let silenceResetFrames: Int
    private let maxPreDelayFrames: Int

    private var combBuffers: [Float]
    private var combOffsets: [Int]
    private var combCounts: [Int]
    private var combWriteIndices: [Int]
    private var combDampingStates: [Float]
    private var allpassBuffers: [Float]
    private var allpassOffsets: [Int]
    private var allpassCounts: [Int]
    private var allpassWriteIndices: [Int]
    private var preDelayBuffers: [Float]
    private var preDelayOffsets: [Int]
    private var preDelayCounts: [Int]
    private var preDelayWriteIndices: [Int]

    private var activeMode: AppAudioSpatialMode = .off
    private var requestedMode: AppAudioSpatialMode = .off
    private var pendingMode: AppAudioSpatialMode?
    private var requestedIntensity: Float = 0
    private var lastWord: UInt64?
    private var tuning = AppAudioSpatialTuning.value(for: .off)
    private var activePreDelayFrames = 0
    private var wet: Float = 0
    private var wetTarget: Float = 0
    private var silentFrames = 0
    private var silenceHold = false
    private var tailNeedsReset = false

    init(sampleRate: Double) {
        self.sampleRate = sampleRate
        wetStep = Float(1 / max(1, sampleRate * 0.02))
        silenceResetFrames = max(1, Int(sampleRate * 0.35))
        maxPreDelayFrames = max(1, Int(sampleRate * 0.10))

        let ratio = sampleRate / 44_100
        let stereoSpread = max(1, Int(23 * ratio))
        combOffsets = Array(repeating: 0, count: Self.channelCount * Self.combCount)
        combCounts = Array(repeating: 0, count: Self.channelCount * Self.combCount)
        combWriteIndices = Array(repeating: 0, count: Self.channelCount * Self.combCount)
        combDampingStates = Array(repeating: 0, count: Self.channelCount * Self.combCount)
        allpassOffsets = Array(repeating: 0, count: Self.channelCount * Self.allpassCount)
        allpassCounts = Array(repeating: 0, count: Self.channelCount * Self.allpassCount)
        allpassWriteIndices = Array(repeating: 0, count: Self.channelCount * Self.allpassCount)
        let delayBufferFrames = max(1, Int(sampleRate * 0.10))
        // 每个声道使用独立的预延迟区域，避免左右声道互相读到对方的早期反射。
        preDelayOffsets = (0..<Self.channelCount).map { $0 * delayBufferFrames }
        preDelayCounts = Array(repeating: delayBufferFrames, count: Self.channelCount)
        preDelayWriteIndices = Array(repeating: 0, count: Self.channelCount)
        preDelayBuffers = Array(repeating: 0, count: delayBufferFrames * Self.channelCount)

        var combStorage: [Float] = []
        var allpassStorage: [Float] = []
        for channel in 0..<Self.channelCount {
            for (index, baseDelay) in Self.combDelays.enumerated() {
                let line = channel * Self.combCount + index
                let frames = max(1, Int(Double(baseDelay) * ratio)
                    + (channel == 1 ? stereoSpread : 0))
                combOffsets[line] = combStorage.count
                combCounts[line] = frames
                combStorage.append(contentsOf: repeatElement(0, count: frames))
            }
            for (index, baseDelay) in Self.allpassDelays.enumerated() {
                let line = channel * Self.allpassCount + index
                let frames = max(1, Int(Double(baseDelay) * ratio)
                    + (channel == 1 ? stereoSpread : 0))
                allpassOffsets[line] = allpassStorage.count
                allpassCounts[line] = frames
                allpassStorage.append(contentsOf: repeatElement(0, count: frames))
            }
        }
        combBuffers = combStorage
        allpassBuffers = allpassStorage
    }

    /// 每个音频块只解析一次参数。切换模式时先淡出旧湿声，再在新模式上从静默状态开始。
    mutating func beginBuffer(word: UInt64) {
        guard word != lastWord else { return }
        lastWord = word
        let nextMode = AppAudioSpatialParameterWord.mode(in: word)
        let nextIntensity = AppAudioSpatialParameterWord.intensity(in: word)
        requestedIntensity = nextIntensity
        guard nextMode != requestedMode else {
            if pendingMode == nil, !silenceHold {
                wetTarget = activeMode.isEnabled ? nextIntensity : 0
            }
            return
        }
        requestedMode = nextMode
        pendingMode = nextMode
        wetTarget = 0
    }

    /// 返回本帧是否需要运行音效链。空间模式开启后即使湿声暂时为 0 也要继续观察输入，
    /// 这样应用恢复播放时能够重新唤醒混响，而不需要重建 Process Tap。
    @inline(__always)
    mutating func beginFrame() -> Bool {
        if wet < wetTarget {
            wet = min(wetTarget, wet + wetStep)
        } else if wet > wetTarget {
            wet = max(wetTarget, wet - wetStep)
        }

        if let nextMode = pendingMode, wet == 0, wetTarget == 0 {
            pendingMode = nil
            activeMode = nextMode
            tuning = .value(for: nextMode)
            activePreDelayFrames = min(maxPreDelayFrames,
                                       Int(tuning.preDelaySeconds * sampleRate))
            resetTail()
            wetTarget = nextMode.isEnabled ? requestedIntensity : 0
        }
        return activeMode.isEnabled || pendingMode != nil || wet > 0 || wetTarget > 0
    }

    /// 在 EQ 处理后、Limiter 和输出分发前处理一帧。多设备输出只调用这一遍。
    @inline(__always)
    mutating func processFrame(left: Float, right: Float,
                               channels: Int) -> (Float, Float) {
        let dryLeft = left.isFinite ? left : 0
        let dryRight = channels > 1 && right.isFinite ? right : 0
        observeSilence(left: dryLeft, right: dryRight, channels: channels)

        guard activeMode.isEnabled else { return (dryLeft, dryRight) }
        if wet == 0, wetTarget == 0 {
            if tailNeedsReset {
                resetTail()
                tailNeedsReset = false
            }
            return (dryLeft, dryRight)
        }

        let inputLeft = dryLeft + dryRight * tuning.inputCrossFeed
        let inputRight = dryRight + dryLeft * tuning.inputCrossFeed
        let wetLeft = processChannel(input: inputLeft, channel: 0)
        let wetRight = processChannel(input: inputRight,
                                      channel: channels > 1 ? 1 : 0)
        tailNeedsReset = true

        let sameChannel = 0.5 + tuning.width * 0.5
        let crossChannel = (1 - tuning.width) * 0.5
        let mixedLeft = wetLeft * sameChannel + wetRight * crossChannel
        let mixedRight = wetRight * sameChannel + wetLeft * crossChannel
        let outputGain = wet * Self.wetOutputGain
        return (dryLeft + mixedLeft * outputGain,
                dryRight + mixedRight * outputGain)
    }

    private mutating func observeSilence(left: Float, right: Float, channels: Int) {
        let magnitude = max(abs(left), channels > 1 ? abs(right) : 0)
        if magnitude > Self.silenceThreshold {
            silentFrames = 0
            silenceHold = false
            if wet == 0, wetTarget == 0, activeMode.isEnabled {
                wetTarget = requestedIntensity
            }
            return
        }
        guard !silenceHold else { return }
        guard silentFrames < silenceResetFrames else { return }
        silentFrames += 1
        if silentFrames >= silenceResetFrames {
            // 停止播放后先让当前尾音在 20ms 内淡出，再清空全部延迟线。
            silenceHold = true
            wetTarget = 0
        }
    }

    private mutating func processChannel(input: Float, channel: Int) -> Float {
        let preDelayed = processPreDelay(input: input * Self.inputGain,
                                         channel: channel)
        let combBase = channel * Self.combCount
        let damp1 = tuning.damping
        let damp2 = 1 - damp1
        var combined: Float = 0

        for index in 0..<Self.combCount {
            let line = combBase + index
            let offset = combOffsets[line]
            let count = combCounts[line]
            var write = combWriteIndices[line]
            var read = write - count
            if read < 0 { read += count }

            let delayed = combBuffers[offset + read]
            let filtered = delayed * damp2 + combDampingStates[line] * damp1
            combDampingStates[line] = filtered
            combBuffers[offset + write] = preDelayed + filtered * tuning.feedback
            write += 1
            if write == count { write = 0 }
            combWriteIndices[line] = write
            combined += delayed
        }

        let allpassBase = channel * Self.allpassCount
        var wet = combined
        for index in 0..<Self.allpassCount {
            let line = allpassBase + index
            let offset = allpassOffsets[line]
            let count = allpassCounts[line]
            var write = allpassWriteIndices[line]
            var read = write - count
            if read < 0 { read += count }

            let delayed = allpassBuffers[offset + read]
            allpassBuffers[offset + write] = wet + delayed * 0.5
            write += 1
            if write == count { write = 0 }
            allpassWriteIndices[line] = write
            wet = delayed - wet
        }
        return wet
    }

    private mutating func processPreDelay(input: Float, channel: Int) -> Float {
        let offset = preDelayOffsets[channel]
        let count = preDelayCounts[channel]
        var write = preDelayWriteIndices[channel]
        var read = write - activePreDelayFrames
        while read < 0 { read += count }
        let delayed = preDelayBuffers[offset + read]
        preDelayBuffers[offset + write] = input
        write += 1
        if write == count { write = 0 }
        preDelayWriteIndices[channel] = write
        return delayed
    }

    /// 清空所有反馈状态，避免切换模式、停止播放或旁路后残留旧房间的尾音。
    private mutating func resetTail() {
        for index in combBuffers.indices { combBuffers[index] = 0 }
        for index in allpassBuffers.indices { allpassBuffers[index] = 0 }
        for index in preDelayBuffers.indices { preDelayBuffers[index] = 0 }
        for index in combWriteIndices.indices { combWriteIndices[index] = 0 }
        for index in allpassWriteIndices.indices { allpassWriteIndices[index] = 0 }
        for index in preDelayWriteIndices.indices { preDelayWriteIndices[index] = 0 }
        for index in combDampingStates.indices { combDampingStates[index] = 0 }
        silentFrames = 0
        tailNeedsReset = false
    }
}
