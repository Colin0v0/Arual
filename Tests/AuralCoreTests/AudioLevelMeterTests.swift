import AudioToolbox
import Foundation
import Testing
@testable import AuralCore

struct AudioLevelMeterTests {
    @Test func mailboxRetainsThePeakBetweenRefreshesAndResetsAfterRead() {
        let mailbox = AudioPeakMailbox()
        mailbox.publish(0.2)
        mailbox.publish(0.8)
        mailbox.publish(0.3)
        mailbox.publish(.nan)
        mailbox.publish(.infinity)
        #expect(mailbox.consume() == 0.8)
        #expect(mailbox.consume() == 0)
    }

    @Test func logarithmicScaleIsNotTheSliderPercentage() {
        #expect(AudioLevelEnvelope.normalized(0) == 0)
        #expect(AudioLevelEnvelope.normalized(0.001) == 0)
        #expect(abs(AudioLevelEnvelope.normalized(0.01) - 1.0 / 3) < 0.0001)
        #expect(abs(AudioLevelEnvelope.normalized(0.1) - 2.0 / 3) < 0.0001)
        #expect(AudioLevelEnvelope.normalized(1) == 1)
        #expect(AudioLevelEnvelope.normalized(2) == 1)
    }

    @Test func envelopeRespondsImmediatelyAndFallsWithoutSyntheticActivity() {
        var envelope = AudioLevelEnvelope()
        let initial = envelope.update(peak: 1, at: 0)
        let falling = envelope.update(peak: 0, at: 0.25)
        let silence = envelope.update(peak: 0, at: 3)
        #expect(initial == 1)
        #expect(falling < initial && falling > 0)
        #expect(silence == 0)
    }

    @Test func visibilityOnlyControlsUnmanagedMeteringNotUserMixing() {
        var state = ApplicationMixState()
        #expect(ApplicationAudioIntent.mode(state: state, isPlaying: true, meterVisible: true) == .metering)
        #expect(ApplicationAudioIntent.mode(state: state, isPlaying: false, meterVisible: true) == nil)
        #expect(ApplicationAudioIntent.mode(state: state, isPlaying: true, meterVisible: false) == nil)
        state.enable(outputUID: "output")
        #expect(ApplicationAudioIntent.mode(state: state, isPlaying: false, meterVisible: false) == .mixing)
        state.fail("permission denied")
        #expect(ApplicationAudioIntent.mode(state: state, isPlaying: true, meterVisible: true) == nil)
    }

    @Test func failedManagementCanBeExplicitlyDisabledBackToMetering() throws {
        var state = ApplicationMixState()
        try state.setGain(0.35)
        state.enable(outputUID: "output")
        state.fail("启动失败")
        state.disable()
        #expect(!state.managed && state.failure == nil)
        #expect(state.gain == 0.35)
        #expect(ApplicationAudioIntent.mode(state: state, isPlaying: true, meterVisible: true) == .metering)
    }

    @Test func meteringDoesNotRewriteSourceOrReplayItsSignal() {
        let result = render(sample: 0.8, gain: 0.2, mode: .metering)
        #expect(result.source == 0.8)
        #expect(result.output == 0)
        #expect(result.peak == 0.8)
    }

    @Test func mixingMeterUsesActualGainAndMuteNotInputLoudness() {
        let quiet = render(sample: 0.8, gain: 0.25, mode: .mixing)
        #expect(abs(quiet.output - 0.2) < 0.0001)
        #expect(abs(quiet.peak - 0.2) < 0.0001)
        let muted = render(sample: 0.8, gain: 0, mode: .mixing)
        #expect(muted.output == 0)
        #expect(muted.peak == 0)
    }

    @Test @MainActor func unstartedMeterIsUnavailableNotPretendSilence() {
        let group = AudioProcessGroup(id: "test", bundleID: "test", processIDs: [], objectIDs: [])
        let output = AudioOutput(id: 0, uid: "test", name: "test", transport: 0)
        let session = ProcessAudioSession(group: group, output: output, mode: .metering)
        #expect(session.consumePeak() == nil)
        #expect(session.mode == .metering)
    }

    private func render(sample: Float, gain: Float, mode: ApplicationAudioMode) -> (source: Float, output: Float, peak: Float) {
        let inputSamples = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        let outputSamples = UnsafeMutablePointer<Float>.allocate(capacity: 2)
        inputSamples.initialize(repeating: sample, count: 2)
        outputSamples.initialize(repeating: 99, count: 2)
        defer { inputSamples.deallocate(); outputSamples.deallocate() }
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        defer { input.unsafeMutablePointer.deallocate(); output.unsafeMutablePointer.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 8, mData: inputSamples)
        output[0] = AudioBuffer(mNumberChannels: 2, mDataByteSize: 8, mData: outputSamples)
        let state = RenderState(sampleRate: 48_000, initialGain: gain, mode: mode)
        state.target.store(gain.bitPattern, ordering: .relaxed)
        var time = AudioTimeStamp()
        _ = auralAudioCallback(0, &time, input.unsafePointer, &time, output.unsafeMutablePointer, &time,
                              Unmanaged.passUnretained(state).toOpaque())
        return (inputSamples[0], outputSamples[0], state.peak.consume())
    }
}
