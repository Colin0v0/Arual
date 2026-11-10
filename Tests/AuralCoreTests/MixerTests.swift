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
