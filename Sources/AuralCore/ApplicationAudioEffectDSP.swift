import Foundation

/// RBJ Audio EQ Cookbook 的双二阶系数。
/// 系数只在会话启动前预计算，音频线程只读取和插值，不执行 sin/cos/pow。
struct AppAudioEffectBiquad: Equatable {
    static let bypass = AppAudioEffectBiquad(b0: 1, b1: 0, b2: 0, a1: 0, a2: 0)

    let b0: Float
    let b1: Float
    let b2: Float
    let a1: Float
    let a2: Float

    /// 转置直接 II 型状态，浮点误差更小，并且每个声道每个频段只需要两个状态值。
    @inline(__always)
    func process(_ input: Float, state: inout AppAudioEffectBiquadState) -> Float {
        let output = b0 * input + state.z1
        state.z1 = b1 * input - a1 * output + state.z2
        state.z2 = b2 * input - a2 * output
        return output
    }
}

struct AppAudioEffectBiquadState {
    var z1: Float = 0
    var z2: Float = 0

    mutating func reset() {
        z1 = 0
        z2 = 0
    }
}

/// 参数变化时在 20ms 内线性插值系数，避免直接换系数产生可听咔哒声。
private struct AppAudioEffectCoefficientRamp {
    var current = AppAudioEffectBiquad.bypass
    var target = AppAudioEffectBiquad.bypass
    var start = AppAudioEffectBiquad.bypass
    var remainingFrames = 0
    var durationFrames = 0

    mutating func setTarget(_ next: AppAudioEffectBiquad, frames: Int) {
        guard next != target else { return }
        start = current
        target = next
        durationFrames = max(1, frames)
        remainingFrames = durationFrames
    }

    @inline(__always)
    mutating func advance() -> AppAudioEffectBiquad {
        guard remainingFrames > 0 else { return current }
        let elapsed = Float(max(1, durationFrames - remainingFrames + 1))
        let scale = elapsed / Float(durationFrames)
        current = AppAudioEffectBiquad(
            b0: start.b0 + (target.b0 - start.b0) * scale,
            b1: start.b1 + (target.b1 - start.b1) * scale,
            b2: start.b2 + (target.b2 - start.b2) * scale,
            a1: start.a1 + (target.a1 - start.a1) * scale,
            a2: start.a2 + (target.a2 - start.a2) * scale
        )
        remainingFrames -= 1
        if remainingFrames == 0 { current = target }
        return current
    }
}

/// 线性参数斜坡同样采用固定步长，不在回调中分配计时器或闭包。
private struct AppAudioEffectLinearRamp {
    var current: Float
    var target: Float
    let step: Float

    init(sampleRate: Double, initial: Float = 1) {
        current = initial
        target = initial
        step = Float(1 / max(1, sampleRate * 0.02))
    }

    mutating func setTarget(_ value: Float) {
        target = value
    }

    @inline(__always)
    mutating func advance() -> Float {
        if current < target { current = min(target, current + step) }
        if current > target { current = max(target, current - step) }
        return current
    }
}

/// 十段增益被压进一个 64 位原子字，音频回调每次只读一次。
/// 每段使用 0.5 dB 档位，共 49 档，十段占用 60 bit，另保留 1 bit 作为启用标志。
enum AppAudioEffectParameterWord {
    static let gainStepDB: Float = 0.5
    static let gainCount = 49
    static let bitsPerBand = 6

    static func index(for gainDB: Float) -> UInt64 {
        let clamped = min(max(gainDB, AppAudioEffectSettings.minimumGainDB),
                          AppAudioEffectSettings.maximumGainDB)
        let raw = ((clamped - AppAudioEffectSettings.minimumGainDB) / gainStepDB).rounded()
        return UInt64(min(max(Int(raw), 0), gainCount - 1))
    }

    static func gainDB(for index: UInt64) -> Float {
        AppAudioEffectSettings.minimumGainDB + Float(index) * gainStepDB
    }

    static func pack(_ settings: AppAudioEffectSettings?) -> UInt64 {
        let settings = settings ?? .disabled
        var word: UInt64 = settings.enabled ? 1 : 0
        for index in 0..<AppAudioEffectEQ.bandCount {
            word |= Self.index(for: settings.eq[index]) << UInt64(1 + index * bitsPerBand)
        }
        return word
    }

    @inline(__always)
    static func enabled(in word: UInt64) -> Bool {
        word & 1 == 1
    }

    @inline(__always)
    static func bandIndex(in word: UInt64, band: Int) -> UInt64 {
        (word >> UInt64(1 + band * bitsPerBand)) & 0x3F
    }
}

/// 应用级十段参数均衡器。
/// 所有系数表、滤波器状态和数组都在会话启动前分配；`beginBuffer`/`beginFrame`/`process`
/// 不访问 HAL、不写日志、不等待锁，也不在实时路径创建集合或对象。
struct AppAudioEffectDSP {
    private let smoothingFrames: Int
    private let coefficientTables: [[AppAudioEffectBiquad]]
    private let preampTable: [Float]
    private let limiterReleaseStep: Float

    private var lastWord: UInt64?
    private var ramps = Array(repeating: AppAudioEffectCoefficientRamp(),
                             count: AppAudioEffectEQ.bandCount)
    private var wetRamp: AppAudioEffectLinearRamp
    private var preampRamp: AppAudioEffectLinearRamp
    private var limiterGain: Float = 1
    private var filterStates = Array(
        repeating: AppAudioEffectBiquadState(),
        count: AppAudioEffectEQ.bandCount * 2
    )
    private var activeFrameCoefficients = Array(
        repeating: AppAudioEffectBiquad.bypass,
        count: AppAudioEffectEQ.bandCount
    )
    private var spatial: AppAudioSpatialDSP
    private(set) var isWet = false

    init(sampleRate: Double) {
        smoothingFrames = max(1, Int(sampleRate * 0.02))
        limiterReleaseStep = Float(1 / max(1, sampleRate * 0.08))
        coefficientTables = AppAudioEffectEQ.frequencies.indices.map { band in
            (0..<AppAudioEffectParameterWord.gainCount).map { index in
                let gain = AppAudioEffectParameterWord.gainDB(for: UInt64(index))
                let frequency = min(Double(AppAudioEffectEQ.frequencies[band]), sampleRate * 0.42)
                return Self.peaking(gainDB: gain, frequency: frequency, q: 1.1, sampleRate: sampleRate)
            }
        }
        preampTable = (0..<AppAudioEffectParameterWord.gainCount).map { index in
            let gain = AppAudioEffectParameterWord.gainDB(for: UInt64(index))
            return Float(pow(10, Double(-max(0, gain)) / 20))
        }
        wetRamp = AppAudioEffectLinearRamp(sampleRate: sampleRate, initial: 0)
        preampRamp = AppAudioEffectLinearRamp(sampleRate: sampleRate, initial: 1)
        spatial = AppAudioSpatialDSP(sampleRate: sampleRate)
    }

    /// 每个回调只检查一次 EQ 与空间参数；未变化时不做任何系数换算。
    mutating func beginBuffer(effectWord: UInt64, spatialWord: UInt64) {
        spatial.beginBuffer(word: spatialWord)
        guard effectWord != lastWord else { return }
        lastWord = effectWord
        guard AppAudioEffectParameterWord.enabled(in: effectWord) else {
            wetRamp.setTarget(0)
            return
        }
        var peakIndex: UInt64 = 0
        for band in 0..<AppAudioEffectEQ.bandCount {
            let index = AppAudioEffectParameterWord.bandIndex(in: effectWord, band: band)
            ramps[band].setTarget(coefficientTables[band][Int(index)], frames: smoothingFrames)
            peakIndex = max(peakIndex, index)
        }
        preampRamp.setTarget(preampTable[Int(peakIndex)])
        wetRamp.setTarget(1)
    }

    /// 返回本帧是否需要进入音效链；EQ 或空间任一开启都会继续处理。
    /// 关闭后仍会短暂处理，等待 20ms 淡出和空间尾音清空完成。
    @inline(__always)
    mutating func beginFrame() -> Bool {
        let spatialActive = spatial.beginFrame()
        guard wetRamp.current > 0 || wetRamp.target > 0 else {
            if isWet {
                resetFilterStates()
                limiterGain = 1
                isWet = false
            }
            for band in activeFrameCoefficients.indices {
                activeFrameCoefficients[band] = .bypass
            }
            return spatialActive
        }
        isWet = true
        _ = wetRamp.advance()
        if wetRamp.current == 0, wetRamp.target == 0 {
            resetFilterStates()
            limiterGain = 1
            isWet = false
            return spatialActive
        }
        _ = preampRamp.advance()
        for band in activeFrameCoefficients.indices {
            activeFrameCoefficients[band] = ramps[band].advance()
        }
        return true
    }

    /// 干声仍经过原本的逐 App 增益；湿声依次经过十个固定频点的峰值滤波器。
    @inline(__always)
    mutating func processPrelimiter(_ dry: Float, channel: Int) -> Float {
        guard isWet else { return dry }
        guard dry.isFinite else { return 0 }
        let channelOffset = min(max(channel, 0), 1) * AppAudioEffectEQ.bandCount
        var sample = dry
        for band in 0..<AppAudioEffectEQ.bandCount {
            sample = activeFrameCoefficients[band].process(
                sample,
                state: &filterStates[channelOffset + band]
            )
        }
        let wet = sample * preampRamp.current
        return dry + (wet - dry) * wetRamp.current
    }

    /// 空间处理位于 EQ 之后、Limiter 与多设备分发之前；每帧只生成一次混响湿声。
    @inline(__always)
    mutating func processSpatial(_ samples: inout (left: Float, right: Float),
                                 channels: Int) {
        let output = spatial.processFrame(left: samples.left,
                                          right: samples.right,
                                          channels: channels)
        samples = output
    }

    /// 前馈峰值 Limiter 在同一帧所有声道之间共享增益，避免左右声道音量像声像一样摆动。
    @inline(__always)
    mutating func limitFrame(_ samples: inout (left: Float, right: Float), channels: Int) -> (Float, Float) {
        let peak = max(abs(samples.left), channels > 1 ? abs(samples.right) : 0)
        if peak > 0.98 {
            limiterGain = min(limiterGain, 0.98 / peak)
        } else {
            limiterGain = min(1, limiterGain + (1 - limiterGain) * limiterReleaseStep)
        }
        samples.left *= limiterGain
        if channels > 1 { samples.right *= limiterGain }
        return (samples.left, samples.right)
    }

    private mutating func resetFilterStates() {
        for index in filterStates.indices { filterStates[index].reset() }
    }

    /// RBJ peaking filter。十个频段共用固定 Q，只改变目标频段，不整体染色。
    private static func peaking(gainDB: Float, frequency: Double,
                                q: Double, sampleRate: Double) -> AppAudioEffectBiquad {
        guard gainDB != 0 else { return .bypass }
        let amplitude = pow(10, Double(gainDB) / 40)
        let omega = 2 * Double.pi * frequency / sampleRate
        let cosine = cos(omega)
        let alpha = sin(omega) / (2 * q)
        let b0 = 1 + alpha * amplitude
        let b1 = -2 * cosine
        let b2 = 1 - alpha * amplitude
        let a0 = 1 + alpha / amplitude
        let a1 = -2 * cosine
        let a2 = 1 - alpha / amplitude
        let inverse = 1 / a0
        return AppAudioEffectBiquad(
            b0: Float(b0 * inverse),
            b1: Float(b1 * inverse),
            b2: Float(b2 * inverse),
            a1: Float(a1 * inverse),
            a2: Float(a2 * inverse)
        )
    }
}
