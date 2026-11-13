import AudioToolbox
import Foundation
import Testing
@testable import AuralCore

struct ApplicationAudioEffectSettingsTests {
    @Test func presetsApplyAndCurveEditingBecomesManual() {
        var settings = AppAudioEffectSettings(enabled: true)
        settings.apply(.voice)
        #expect(settings.eq.gainsDB.count == 10)
        #expect(settings.eq[4] == 4)
        #expect(settings.preset == .builtIn(.voice))

        settings.setGain(6, at: 4)
        #expect(settings.preset == .manual)
        #expect(settings.eq[4] == 6)

        settings.setGain(4, at: 4)
        settings.preset = .builtIn(.voice)
        #expect(settings.isValid)
    }

    @Test func automaticPreampOnlyCompensatesPositiveBoost() {
        let cuts = AppAudioEffectEQ(gainsDB: [-6, -2, -1, 0, 0, 0, 0, 0, 0, 0])
        let boost = AppAudioEffectEQ(gainsDB: [7, 6, 4, 2, 0, -1, -1, 0, 1, 1])
        #expect(AppAudioEffectSettings(eq: cuts).preampDB == 0)
        #expect(AppAudioEffectSettings(eq: boost).preampDB == -7)
        var invalid = AppAudioEffectEQ.flat
        invalid[0] = .infinity
        #expect(!AppAudioEffectSettings(eq: invalid).isValid)
        invalid[0] = 13
        #expect(!AppAudioEffectSettings(eq: invalid).isValid)
    }

    @Test func parameterWordRoundTripsTenQuantizedBandsAndEnableFlag() {
        let gains: [Float] = [-3.5, 2, 7.5, 0, -12, 12, 1.5, -1, 4.5, 0]
        let settings = AppAudioEffectSettings(enabled: true,
                                              preset: .manual,
                                              eq: AppAudioEffectEQ(gainsDB: gains))
        let word = AppAudioEffectParameterWord.pack(settings)
        #expect(AppAudioEffectParameterWord.enabled(in: word))
        for (band, expected) in gains.enumerated() {
            let index = AppAudioEffectParameterWord.bandIndex(in: word, band: band)
            #expect(AppAudioEffectParameterWord.gainDB(for: index) == expected)
        }

        let disabled = AppAudioEffectParameterWord.pack(.disabled)
        #expect(!AppAudioEffectParameterWord.enabled(in: disabled))
    }

    @Test func effectsRequireRealMixingEvenWithoutVolumeManagement() {
        let state = ApplicationMixState()
        #expect(ApplicationAudioIntent.mode(state: state, isPlaying: false,
                                            meterVisible: false,
                                            requiresEffects: true) == .mixing)
    }
}

struct ApplicationAudioEffectRenderTests {
    @Test func disabledEffectsKeepTheExactBypassPath() {
        let result = render(sampleAt: { _ in 0.5 }, frames: 256,
                            effect: .disabled)
        #expect(result.output.allSatisfy { abs($0 - 0.5) < 0.00001 })
    }

    @Test func enabledBassPresetChangesTheProcessedWaveform() {
        let processed = render(sampleAt: sine(frequency: 80, amplitude: 0.4),
                               frames: 4_096,
                               effect: AppAudioEffectSettings(enabled: true, preset: .bassBoost))
        let dry = render(sampleAt: sine(frequency: 80, amplitude: 0.4),
                         frames: 4_096,
                         effect: .disabled)
        let maximumDelta = zip(processed.output, dry.output).map { abs($0.0 - $0.1) }.max() ?? 0
        #expect(maximumDelta > 0.01)
        #expect(processed.output.allSatisfy { $0.isFinite })
    }

    @Test func limiterKeepsBoostedSignalInsideHeadroom() {
        let fullBoost = AppAudioEffectEQ(
            gainsDB: Array(repeating: 12, count: AppAudioEffectEQ.bandCount)
        )
        let result = render(sampleAt: { frame in frame.isMultiple(of: 2) ? 1 : -1 },
                            frames: 16_384,
                            effect: AppAudioEffectSettings(enabled: true,
                                                           preset: .manual,
                                                           eq: fullBoost))
        #expect(result.output.allSatisfy { $0.isFinite && abs($0) <= 0.9801 })
    }

    private func sine(frequency: Double, amplitude: Float) -> (Int) -> Float {
        { frame in
            amplitude * Float(sin(2 * Double.pi * frequency * Double(frame) / 48_000))
        }
    }

    private func render(sampleAt: (Int) -> Float, frames: Int,
                        effect: AppAudioEffectSettings) -> (output: [Float], peak: Float) {
        let source = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        let destination = UnsafeMutablePointer<Float>.allocate(capacity: frames * 2)
        source.initialize(repeating: 0, count: frames * 2)
        destination.initialize(repeating: 0, count: frames * 2)
        defer { source.deallocate(); destination.deallocate() }
        for frame in 0..<frames {
            let value = sampleAt(frame)
            source[frame * 2] = value
            source[frame * 2 + 1] = value
        }
        let input = AudioBufferList.allocate(maximumBuffers: 1)
        let output = AudioBufferList.allocate(maximumBuffers: 1)
        defer { input.unsafeMutablePointer.deallocate(); output.unsafeMutablePointer.deallocate() }
        input[0] = AudioBuffer(mNumberChannels: 2,
                               mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                               mData: source)
        output[0] = AudioBuffer(mNumberChannels: 2,
                                mDataByteSize: UInt32(frames * 2 * MemoryLayout<Float>.size),
                                mData: destination)
        let state = RenderState(sampleRate: 48_000, effect: effect)
        var time = AudioTimeStamp()
        _ = auralAudioCallback(0, &time, input.unsafePointer, &time,
                               output.unsafeMutablePointer, &time,
                               Unmanaged.passUnretained(state).toOpaque())
        let values = Array(UnsafeBufferPointer(start: destination, count: frames * 2))
        return (values, state.peak.consume())
    }
}
