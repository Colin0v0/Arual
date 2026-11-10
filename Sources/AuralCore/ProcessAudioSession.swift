import CoreAudio
import AudioToolbox
import Foundation
import Synchronization

/// 每个声道共用同一个逐帧增益，避免左右声道的淡入进度不同。
public struct GainRamp {
    public private(set) var current: Float = 1
    public let step: Float
    public init(sampleRate: Double, initial: Float = 1) {
        current = initial
        step = Float(1 / (sampleRate * 0.02))
    }
    public mutating func advance(toward target: Float) -> Float {
        if current < target { current = min(target, current + step) }
        if current > target { current = max(target, current - step) }
        return current
    }
}

// 此对象在启动前分配，在 I/O 停止并销毁回调之后才释放。
// 回调不做 HAL 查询、日志、集合构造、锁等待或界面操作。
final class RenderState {
    let target = Atomic<UInt32>(Float(1).bitPattern)
    let fault = Atomic<Bool>(false)
    let callbacks = Atomic<UInt64>(0)
    let peak = AudioPeakMailbox()
    let mode: ApplicationAudioMode
    var ramp: GainRamp
    init(sampleRate: Double, initialGain: Float = 1, mode: ApplicationAudioMode = .mixing) {
        self.mode = mode
        ramp = GainRamp(sampleRate: sampleRate, initial: initialGain)
    }
}

let auralAudioCallback: AudioDeviceIOProc = { _, _, input, _, output, _, context in
    let outs = UnsafeMutableAudioBufferListPointer(output)
    // 每次先清空输出，任何不支持的布局都不会把未初始化内存送到扬声器。
    for buffer in outs {
        if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
    }
    guard let context else { return noErr }
    let state = Unmanaged<RenderState>.fromOpaque(context).takeUnretainedValue()
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
    guard !ins.isEmpty, ins.count == outs.count else { state.fault.store(true, ordering: .relaxed); return noErr }
    var frames: Int?
    for i in ins.indices {
        let source = ins[i], destination = outs[i]
        guard source.mNumberChannels > 0, source.mNumberChannels == destination.mNumberChannels,
              source.mDataByteSize == destination.mDataByteSize,
              source.mDataByteSize % (4 * source.mNumberChannels) == 0 else {
            state.fault.store(true, ordering: .relaxed); return noErr
        }
        let count = Int(source.mDataByteSize / (4 * source.mNumberChannels))
        if let frames, frames != count { state.fault.store(true, ordering: .relaxed); return noErr }
        frames = count
        // HAL 可用空指针表示尚未有输入；保持本次静音，不虚构音频样本。
        guard source.mData != nil, destination.mData != nil else { return noErr }
    }
    guard let frames else { return noErr }
    let target = Float(bitPattern: state.target.load(ordering: .relaxed))
    var peak: Float = 0
    for frame in 0..<frames {
        let gain = state.mode == .mixing ? state.ramp.advance(toward: target) : 1
        for i in ins.indices {
            let source = ins[i].mData!.assumingMemoryBound(to: Float.self)
            let destination = outs[i].mData!.assumingMemoryBound(to: Float.self)
            let channels = Int(ins[i].mNumberChannels)
            for channel in 0..<channels {
                let index = frame * channels + channel
                let sample = source[index] * gain
                if sample.isFinite { peak = max(peak, abs(sample)) }
                // 只读计量不重放捕获音频，避免原始声音与本进程的输出叠加。
                if state.mode == .mixing { destination[index] = sample }
            }
        }
    }
    state.peak.publish(peak)
    state.callbacks.wrappingAdd(1, ordering: .relaxed)
    return noErr
}

/// 一次用户明确启用的、指向固定输出的音频接管。
/// 不支持的格式直接拒绝，绝不另建 mixdown/后备输出链路。
@MainActor
public final class ProcessAudioSession {
    public let group: AudioProcessGroup
    public let output: AudioOutput
    public let mode: ApplicationAudioMode
    public private(set) var gain: Float = 1
    public private(set) var muted = false
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProc: AudioDeviceIOProcID?
    private var renderState: RenderState?
    private var started = false
    private var activityWatchdog = AudioActivityWatchdog()
    private var sampleRate: Double?
    public var isActive: Bool { started }
    public var isReleased: Bool { tapID == 0 && aggregateID == 0 && ioProc == nil }

    public init(group: AudioProcessGroup, output: AudioOutput, mode: ApplicationAudioMode = .mixing) {
        self.group = group; self.output = output; self.mode = mode
    }

    /// 只消费最近音频回调的真实峰值；未启动或布局失效时不伪造静音读数。
    public func consumePeak() -> Float? {
        guard started, let renderState,
              !renderState.fault.load(ordering: .relaxed),
              renderState.callbacks.load(ordering: .relaxed) > 0 else { return nil }
        return renderState.peak.consume()
    }

    public func start() throws {
        guard !group.objectIDs.isEmpty else { throw AudioFailure("应用尚未创建音频流") }
        guard tapID == 0, aggregateID == 0 else { throw AudioFailure("该应用已接管，不能重复启动") }
        guard !output.isAggregate else {
            throw AudioFailure("组合输出暂不支持 APP 独立音量或实时电平，请使用单个输出设备")
        }
        do {
            guard try HAL.ids(output.id, HAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeInput)).isEmpty else {
                throw AudioFailure("本阶段仅支持独立输出设备，不接管带输入流的双工音频接口")
            }
            guard try HAL.ids(output.id, HAL.address(kAudioDevicePropertyStreams, scope: kAudioDevicePropertyScopeOutput)).count == 1 else {
                throw AudioFailure("本阶段仅支持单个输出流的设备")
            }
            try validateRoutes()
            // 独立输出设备没有输入流，且仅有一个输出流，因此它的全局 stream 索引为 0。
            // 显式限定来源，绝不把进程在其他设备上的声音混到系统默认输出。
            let description = CATapDescription(processes: group.objectIDs, deviceUID: output.uid, stream: 0)
            description.uuid = UUID()
            description.name = "Aural application audio"
            description.isPrivate = true
            // 计量不静音来源；混音才由本进程接管并重放音频。
            description.muteBehavior = mode == .mixing ? .mutedWhenTapped : .unmuted
            try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "创建应用音频捕获（请检查系统音频录制权限）")
            let format: AudioStreamBasicDescription = try HAL.read(tapID, HAL.address(kAudioTapPropertyFormat), initial: AudioStreamBasicDescription())
            try Self.validate(format)
            sampleRate = format.mSampleRate
            let composition: [String: Any] = [
                kAudioAggregateDeviceNameKey: "Aural Application Output",
                kAudioAggregateDeviceUIDKey: "local.aural.tap.\(UUID().uuidString)",
                kAudioAggregateDeviceIsPrivateKey: true,
                kAudioAggregateDeviceIsStackedKey: false,
                kAudioAggregateDeviceMainSubDeviceKey: output.uid,
                kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: output.uid]],
                kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: description.uuid.uuidString,
                                                  kAudioSubTapDriftCompensationKey: true]]
            ]
            try HAL.check(AudioHardwareCreateAggregateDevice(composition as CFDictionary, &aggregateID), "创建应用输出设备")
            let actual: AudioStreamBasicDescription = try HAL.read(aggregateID, HAL.address(kAudioDevicePropertyStreamFormat, scope: kAudioDevicePropertyScopeOutput), initial: AudioStreamBasicDescription())
            try Self.validate(actual)
            guard format.mSampleRate == actual.mSampleRate,
                  format.mFormatFlags == actual.mFormatFlags else {
                throw AudioFailure("捕获与输出格式不一致，本阶段不做重采样或格式转换")
            }
            // 从零平滑到用户预设，避免首次拖到低音量时先瞬间按 100% 播放。
            let state = RenderState(sampleRate: format.mSampleRate, initialGain: 0, mode: mode)
            state.target.store((muted ? Float(0) : gain).bitPattern, ordering: .relaxed)
            renderState = state
            try HAL.check(AudioDeviceCreateIOProcID(aggregateID, auralAudioCallback,
                                                    Unmanaged.passUnretained(state).toOpaque(), &ioProc), "创建实时音频回调")
            try HAL.check(AudioDeviceStart(aggregateID, ioProc), "启动应用音频处理")
            started = true
        } catch {
            let failure = error.localizedDescription
            do { try stop() }
            catch { throw AudioFailure("\(failure)；清理资源时：\(error.localizedDescription)") }
            throw AudioFailure(failure)
        }
    }

    public static func validate(_ format: AudioStreamBasicDescription) throws {
        guard format.mFormatID == kAudioFormatLinearPCM,
              format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mFormatFlags & kAudioFormatFlagIsBigEndian == 0,
              format.mFormatFlags & kAudioFormatFlagIsPacked != 0,
              format.mBitsPerChannel == 32, format.mChannelsPerFrame == 2,
              format.mFramesPerPacket == 1,
              format.mBytesPerFrame == (format.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0 ? 4 : 8),
              format.mBytesPerPacket == format.mBytesPerFrame,
              format.mSampleRate.isFinite, format.mSampleRate > 0 else {
            throw AudioFailure("当前仅支持原生 Float32 双声道 PCM；未启用音频接管")
        }
    }

    public func setGain(_ value: Float) throws {
        guard value.isFinite, (0...1).contains(value) else { throw AudioFailure("应用增益必须在 0～100% 之间") }
        gain = value; publishGain()
    }
    public func setMuted(_ value: Bool) { muted = value; publishGain() }
    private func publishGain() { renderState?.target.store((muted ? Float(0) : gain).bitPattern, ordering: .relaxed) }

    private func validateRoutes() throws {
        for object in group.objectIDs {
            let routes = try HAL.ids(object, HAL.address(kAudioProcessPropertyDevices, scope: kAudioObjectPropertyScopeOutput))
            let running: UInt32 = try HAL.read(object, HAL.address(kAudioProcessPropertyIsRunningOutput), initial: 0)
            // 已注册但暂停的进程可以没有输出路由；不为它猜测另一台设备。
            if routes.isEmpty && running == 0 { continue }
            guard !routes.isEmpty, routes.allSatisfy({ $0 == output.id }) else {
                throw AudioFailure("该应用正在使用其他或多个输出设备，本阶段不改变其路由")
            }
        }
    }

    public func checkHealth(expectingAudio: Bool = true) throws {
        guard started else { throw AudioFailure("音频接管未成功启动，正在重试释放残留资源") }
        try validateRoutes()
        let actualRate = try HAL.read(output.id, HAL.address(kAudioDevicePropertyNominalSampleRate), initial: Double(0))
        guard actualRate == sampleRate else { throw AudioFailure("输出采样率已改变，请重新启用应用接管") }
        if renderState?.fault.load(ordering: .relaxed) == true {
            throw AudioFailure("实时输入/输出缓冲布局不匹配，已请求停止接管")
        }
        if let state = renderState,
           activityWatchdog.isStalled(expectingAudio: expectingAudio,
                                      callbacks: state.callbacks.load(ordering: .relaxed), at: Date()) {
            throw AudioFailure("未收到音频回调，请检查录制授权和应用播放状态")
        }
    }

    public func stop() throws {
        // 清理按依赖顺序进行。若停止失败，保留状态对象，避免回调访问释放内存。
        if started {
            try HAL.check(AudioDeviceStop(aggregateID, ioProc), "停止音频回调")
            started = false
        }
        if let ioProc {
            try HAL.check(AudioDeviceDestroyIOProcID(aggregateID, ioProc), "释放音频回调")
            self.ioProc = nil
        }
        renderState = nil
        if aggregateID != 0 {
            try HAL.check(AudioHardwareDestroyAggregateDevice(aggregateID), "释放应用输出设备")
            aggregateID = 0
        }
        if tapID != 0 {
            try HAL.check(AudioHardwareDestroyProcessTap(tapID), "释放应用音频捕获")
            tapID = 0
        }
    }
}
