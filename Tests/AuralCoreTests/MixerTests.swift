import AudioToolbox
import Testing
@testable import AuralCore

struct MixerTests {
    @Test func rampIsBoundedAndReachesMute() {
        var ramp = GainRamp(sampleRate: 48_000)
        for _ in 0..<1_000 {
            let value = ramp.advance(toward: 0)
            #expect((0...1).contains(value))
        }
        #expect(ramp.current == 0)
        for _ in 0..<1_000 { _ = ramp.advance(toward: 0.65) }
        #expect(ramp.current == 0.65)
    }

    @Test @MainActor func onlySupportedFormatsPass() async throws {
        var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
                                                 mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                                                 mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8,
                                                 mChannelsPerFrame: 2, mBitsPerChannel: 32, mReserved: 0)
        try ProcessAudioSession.validate(format)
        format.mChannelsPerFrame = 6
        #expect(throws: (any Error).self) { try ProcessAudioSession.validate(format) }
        format.mChannelsPerFrame = 2; format.mBitsPerChannel = 16
        #expect(throws: (any Error).self) { try ProcessAudioSession.validate(format) }
    }
}

struct RenderCallbackTests {
    @Test func interleavedGainDoesNotAlterSource() {
        let frames = 1_200
        let source = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        source.initialize(repeating: 0.8, count: frames * 2)
        destination.initialize(repeating: 99, count: frames * 2)
        defer { source.deallocate(); destination.deallocate() }
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        defer { input.unsafeMutablePointer.deallocate(); output.unsafeMutablePointer.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: source)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: destination)
        let state = RenderState(sampleRate: 48_000)
        state.target.store(Float(0.5).bitPattern, ordering: .relaxed)
        var time = AudioTimeStamp()
        let status = auralAudioCallback(0, &time, input.unsafePointer, &time, output.unsafeMutablePointer, &time,
                                        Unmanaged.passUnretained(state).toOpaque())
        #expect(status == noErr)
        #expect(source[frames * 2 - 1] == 0.8)
        #expect(abs(destination[frames * 2 - 1] - 0.4) < 0.0001)
        #expect(destination[0] == destination[1])
        let fault = state.fault.load(ordering: .relaxed)
        #expect(!fault)
        #expect(state.callbacks.load(ordering: .relaxed) == 1)
    }

    @Test func layoutMismatchZerosOutputAndReportsFault() {
        let source = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        source.initialize(repeating: 1, count: 2)
        destination.initialize(repeating: 99, count: 2)
        defer { source.deallocate(); destination.deallocate() }
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        defer { input.unsafeMutablePointer.deallocate(); output.unsafeMutablePointer.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: 8, mData: source)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 8, mData: destination)
        let state = RenderState(sampleRate: 48_000)
        var time = AudioTimeStamp()
        _ = auralAudioCallback(0, &time, input.unsafePointer, &time, output.unsafeMutablePointer, &time,
                              Unmanaged.passUnretained(state).toOpaque())
        #expect(destination[0] == 0 && destination[1] == 0)
        let fault = state.fault.load(ordering: .relaxed)
        #expect(fault)
    }
}

struct SessionStateTests {
    @Test func multiOutputAcceptsAggregateAndMemberProcessRoutes() throws {
        let memberA = AudioOutput(id: 11, uid: "member.a", name: "成员 A",
                                  transport: kAudioDeviceTransportTypeBuiltIn)
        let memberB = AudioOutput(id: 12, uid: "member.b", name: "成员 B",
                                  transport: kAudioDeviceTransportTypeUSB)
        let aggregate = AudioOutput(id: 99, uid: "local.aural.multi.test", name: "Aural 多设备输出",
                                    transport: kAudioDeviceTransportTypeAggregate)
        let route = try ApplicationPlaybackRoute(output: aggregate, playbackOutputs: [memberA, memberB],
                                                 mainOutputUID: memberA.uid)
        // 公开聚合设备不能作为 Process Tap 的来源，捕获必须绑定真实主成员。
        #expect(route.tapDeviceUID == memberA.uid)
        // HAL 在真实进程中可能报告公开聚合，也可能只报告当前承载声音的成员。
        #expect(route.acceptsProcessRouteUIDs([aggregate.uid]))
        #expect(route.acceptsProcessRouteUIDs([memberA.uid]))
        #expect(route.acceptsProcessRouteUIDs([memberB.uid]))
        #expect(route.acceptsProcessRouteUIDs([memberA.uid, memberB.uid]))
        #expect(!route.acceptsProcessRouteUIDs([]))
        #expect(!route.acceptsProcessRouteUIDs(["third.party.output"]))
        #expect(!route.acceptsProcessRouteUIDs([memberA.uid, "third.party.output"]))
    }

    @Test func multiOutputIgnoresInactiveHelperRoutes() throws {
        let memberA = AudioOutput(id: 11, uid: "member.a", name: "成员 A",
                                  transport: kAudioDeviceTransportTypeBuiltIn)
        let memberB = AudioOutput(id: 12, uid: "member.b", name: "成员 B",
                                  transport: kAudioDeviceTransportTypeUSB)
        let aggregate = AudioOutput(id: 99, uid: "local.aural.multi.test", name: "Aural 多设备输出",
                                    transport: kAudioDeviceTransportTypeAggregate)
        let route = try ApplicationPlaybackRoute(output: aggregate, playbackOutputs: [memberA, memberB],
                                                 mainOutputUID: memberA.uid)
        let routes = [
            ProcessOutputRoute(isRunningOutput: false, deviceUIDs: ["third.party.output"]),
            ProcessOutputRoute(isRunningOutput: true, deviceUIDs: [memberA.uid, memberB.uid]),
            ProcessOutputRoute(isRunningOutput: false, deviceUIDs: [])
        ]
        // Chrome 等 App 会保留空闲 helper 的旧路由，不能因此阻断正在播放的音频对象。
        #expect(route.acceptsActiveProcessRoutes(routes))
    }

    @Test func activeProcessRequiresStableAllowedRoute() throws {
        let memberA = AudioOutput(id: 11, uid: "member.a", name: "成员 A",
                                  transport: kAudioDeviceTransportTypeBuiltIn)
        let memberB = AudioOutput(id: 12, uid: "member.b", name: "成员 B",
                                  transport: kAudioDeviceTransportTypeUSB)
        let aggregate = AudioOutput(id: 99, uid: "local.aural.multi.test", name: "Aural 多设备输出",
                                    transport: kAudioDeviceTransportTypeAggregate)
        let route = try ApplicationPlaybackRoute(output: aggregate, playbackOutputs: [memberA, memberB],
                                                 mainOutputUID: memberA.uid)
        #expect(route.acceptsActiveProcessRoutes([]))
        #expect(!route.acceptsActiveProcessRoutes([
            ProcessOutputRoute(isRunningOutput: true, deviceUIDs: [])
        ]))
        #expect(!route.acceptsActiveProcessRoutes([
            ProcessOutputRoute(isRunningOutput: true, deviceUIDs: ["third.party.output"])
        ]))
    }

    @Test func singleOutputOnlyAcceptsItsOwnProcessRoute() {
        let output = AudioOutput(id: 21, uid: "single.output", name: "单设备",
                                 transport: kAudioDeviceTransportTypeBuiltIn)
        let route = ApplicationPlaybackRoute.single(output)
        #expect(route.acceptsProcessRouteUIDs([output.uid]))
        #expect(!route.acceptsProcessRouteUIDs(["other.output"]))
    }

    @Test @MainActor func unstartedSessionIsNotReportedAsActive() async throws {
        let group = AudioProcessGroup(id: "test", bundleID: "test", processIDs: [], objectIDs: [])
        let output = AudioOutput(id: 0, uid: "test", name: "test", transport: 0)
        let session = ProcessAudioSession(group: group, output: output)
        #expect(!(session.isActive))
        #expect(session.isReleased)
        // 必须在读取任何 HAL 属性前拒绝未启动会话；测试不接触硬件。
        #expect(throws: (any Error).self) { try session.checkHealth() }
        try session.stop()
        #expect(session.isReleased)
    }
}

struct PresetRenderTests {
    @Test func firstBufferFadesFromSilenceToDesiredGain() {
        let frames = 1200
        let source = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        source.initialize(repeating: 0.8, count: frames * 2)
        destination.initialize(repeating: 0, count: frames * 2)
        defer { source.deallocate(); destination.deallocate() }
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        defer { input.unsafeMutablePointer.deallocate(); output.unsafeMutablePointer.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: source)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: UInt32(frames * 8), mData: destination)
        let state = RenderState(sampleRate: 48000, initialGain: 0)
        state.target.store(Float(0.2).bitPattern, ordering: .relaxed)
        var time = AudioTimeStamp()
        _ = auralAudioCallback(0, &time, input.unsafePointer, &time, output.unsafeMutablePointer, &time,
                               Unmanaged.passUnretained(state).toOpaque())
        #expect(destination[0] > 0 && destination[0] < 0.01)
        for index in 0..<(frames * 2) { #expect(destination[index] <= 0.16001) }
        #expect(abs(destination[frames * 2 - 1] - 0.16) < 0.0001)
    }
}

/// 使用本机微信 + Px7 只读探针观察到的原生 HFP 格式，不把它转换成虚构立体声。
struct BluetoothVoiceFormatTests {
    private func pcm(rate: Double, channels: UInt32, planar: Bool = false) -> AudioStreamBasicDescription {
        let bytes: UInt32 = planar ? 4 : 4 * channels
        return AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked | (planar ? kAudioFormatFlagIsNonInterleaved : 0),
            mBytesPerPacket: bytes, mFramesPerPacket: 1, mBytesPerFrame: bytes,
            mChannelsPerFrame: channels, mBitsPerChannel: 32, mReserved: 0)
    }

    @Test @MainActor func nativeMonoAndStereoAreBothSupportedWithoutConversion() throws {
        for rate: Double in [16_000, 24_000, 44_100, 48_000] {
            for channels: UInt32 in [1, 2] {
                for planar in [false, true] {
                    let format = pcm(rate: rate, channels: channels, planar: planar)
                    try ProcessAudioSession.validate(format)
                    try ProcessAudioSession.requireMatchingPCM(captured: format, current: format)
                }
            }
        }
    }

    @Test @MainActor func bluetoothProfileChangeRequestsRebuildRatherThanPermanentFailure() {
        let stereo = pcm(rate: 48_000, channels: 2)
        let voice = pcm(rate: 16_000, channels: 1)
        #expect(throws: ApplicationRoutePending.self) {
            try ProcessAudioSession.requireMatchingPCM(captured: stereo, current: voice)
        }
        #expect(throws: ApplicationRoutePending.self) {
            try ProcessAudioSession.requireMatchingPCM(captured: voice, current: stereo)
        }
        var unsupported = voice
        unsupported.mBitsPerChannel = 16
        #expect(throws: AudioFailure.self) {
            try ProcessAudioSession.requireMatchingPCM(captured: voice, current: unsupported)
        }
    }

    @Test func monoVoiceRenderRecoversFromZeroWithoutAlteringTheSource() {
        let frames = 640
        let source = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: frames)
        source.initialize(repeating: 0.8, count: frames)
        destination.initialize(repeating: 99, count: frames)
        defer { source.deallocate(); destination.deallocate() }
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        defer { input.unsafeMutablePointer.deallocate(); output.unsafeMutablePointer.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: source)
        output[0] = AudioBuffer(mNumberChannels: 1, mDataByteSize: UInt32(frames * 4), mData: destination)
        let state = RenderState(sampleRate: 16_000, initialGain: 0)
        var timestamp = AudioTimeStamp()
        func render(_ gain: Float) {
            state.target.store(gain.bitPattern, ordering: .relaxed)
            _ = auralAudioCallback(0, &timestamp, input.unsafePointer, &timestamp, output.unsafeMutablePointer, &timestamp,
                                   Unmanaged.passUnretained(state).toOpaque())
        }
        render(0)
        #expect(destination[frames - 1] == 0)
        #expect(state.peak.consume() == 0)
        render(0.5)
        #expect(abs(destination[frames - 1] - 0.4) < 0.0001)
        #expect(abs(state.peak.consume() - 0.4) < 0.0001)
        #expect(source[frames - 1] == 0.8)
        let fault = state.fault.load(ordering: .relaxed)
        #expect(!fault)
    }
}
