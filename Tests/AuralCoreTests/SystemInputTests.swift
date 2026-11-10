import AudioToolbox
import CoreAudio
import Foundation
import Testing
@testable import AuralCore

struct SystemInputTests {
    @Test func inputAndOutputUseSeparateScopesWithTheSameExplicitBackend() {
        let inputVolume = AudioDeviceControls.volumeAddress(.input)
        let outputVolume = AudioDeviceControls.volumeAddress(.output)
        #expect(inputVolume.mSelector == kAudioHardwareServiceDeviceProperty_VirtualMainVolume)
        #expect(outputVolume.mSelector == inputVolume.mSelector)
        #expect(inputVolume.mScope == kAudioDevicePropertyScopeInput)
        #expect(outputVolume.mScope == kAudioDevicePropertyScopeOutput)
        #expect(inputVolume.mElement == kAudioObjectPropertyElementMain)
        #expect(AudioDeviceControls.muteAddress(.input).mScope == kAudioDevicePropertyScopeInput)
        #expect(AudioDeviceControls.muteAddress(.output).mScope == kAudioDevicePropertyScopeOutput)
    }

    @Test func defaultInputSelectorCannotChangeDefaultOutput() {
        #expect(SystemInput.defaultDeviceAddress.mSelector == kAudioHardwarePropertyDefaultInputDevice)
        #expect(SystemInput.defaultDeviceAddress.mSelector != kAudioHardwarePropertyDefaultOutputDevice)
        #expect(SystemInput.defaultDeviceAddress.mScope == kAudioObjectPropertyScopeGlobal)
    }

    @Test func invalidInputVolumeIsRejectedBeforeHardwareAccess() {
        for value: Float in [-1, 1.1, .nan, .infinity] {
            #expect(throws: (any Error).self) { try SystemInput.setVolume(value, on: 0) }
        }
    }

    @Test func microphoneSnapshotKeepsUnknownCapabilitiesAndNoDefaultSelection() throws {
        let inputs = [AudioInput(id: 11, uid: "fixture-mic", name: "测试麦克风", transport: 0)]
        let controls: [UInt32: AudioDeviceControlState] = [
            11: .available(volume: AudioDeviceVolume(scalar: nil, writable: false),
                           mute: AudioDeviceMute(muted: nil, writable: false))
        ]
        let snapshot = SystemInputSnapshot(inputs: inputs, selectedID: nil, controls: controls)
        let data = try JSONEncoder().encode(snapshot)
        let decoded = try JSONDecoder().decode(SystemInputSnapshot.self, from: data)
        #expect(decoded.selectedID == nil)
        #expect(decoded.inputs == inputs)
        #expect(decoded.controls == controls)
        #expect(inputs[0].direction == .input)
        #expect(inputs[0].symbol == "mic")
    }

    @Test func oneFailedInputDoesNotOverwriteAnotherMicrophonesVolume() {
        let controls = AudioDeviceControls.readControls(for: [11, 22], readVolume: { id in
            if id == 11 { throw AudioFailure("测试麦克风断开") }
            return AudioDeviceVolume(scalar: 0.7, writable: true)
        }, readMute: { _ in AudioDeviceMute(muted: false, writable: true) })
        #expect(controls[11] == .failed(message: "测试麦克风断开"))
        #expect(controls[22] == .available(volume: AudioDeviceVolume(scalar: 0.7, writable: true),
                                         mute: AudioDeviceMute(muted: false, writable: true)))
    }
}
