import Foundation
import Testing
@testable import AuralCore

struct OutputControlsTests {
    private var outputs: [AudioOutput] {
        [AudioOutput(id: 11, uid: "test-speaker", name: "扬声器", transport: 0),
         AudioOutput(id: 22, uid: "test-display-a", name: "Mi Monitor", transport: 0),
         AudioOutput(id: 33, uid: "test-display-b", name: "Mi Monitor", transport: 0)]
    }

    @Test func everyDeviceIsReadByItsOwnIDIncludingDuplicateNames() {
        var volumeIDs: [UInt32] = []
        var muteIDs: [UInt32] = []
        let controls = SystemAudio.readControls(for: outputs, readVolume: { id in
            volumeIDs.append(id)
            return AudioDeviceVolume(scalar: Float(id) / 100, writable: true)
        }, readMute: { id in
            muteIDs.append(id)
            return AudioDeviceMute(muted: id == 22, writable: true)
        })
        #expect(volumeIDs == [11, 22, 33])
        #expect(muteIDs == [11, 22, 33])
        #expect(controls.count == 3)
        #expect(controls[22] == .available(volume: AudioDeviceVolume(scalar: 0.22, writable: true),
                                          mute: AudioDeviceMute(muted: true, writable: true)))
        #expect(controls[33] == .available(volume: AudioDeviceVolume(scalar: 0.33, writable: true),
                                          mute: AudioDeviceMute(muted: false, writable: true)))
    }

    @Test func oneDeviceFailureDoesNotReplaceOtherReadings() {
        let controls = SystemAudio.readControls(for: outputs, readVolume: { id in
            if id == 22 { throw AudioFailure("测试设备已断开") }
            return AudioDeviceVolume(scalar: 0.15, writable: true)
        }, readMute: { _ in AudioDeviceMute(muted: false, writable: true) })
        #expect(controls[22] == .failed(message: "测试设备已断开"))
        #expect(controls[11] == controls[33])
        #expect(controls.count == 3)
    }

    @Test func unavailableControlsRemainUnknownNotZeroOrFullVolume() {
        let controls = SystemAudio.readControls(for: outputs, readVolume: { _ in
            AudioDeviceVolume(scalar: nil, writable: false)
        }, readMute: { _ in AudioDeviceMute(muted: nil, writable: false) })
        for id: UInt32 in [11, 22, 33] {
            #expect(controls[id] == .available(volume: AudioDeviceVolume(scalar: nil, writable: false),
                                               mute: AudioDeviceMute(muted: nil, writable: false)))
        }
    }

    @Test func snapshotRoundTripRetainsPerDeviceCapabilities() throws {
        let controls = SystemAudio.readControls(for: outputs, readVolume: { _ in
            AudioDeviceVolume(scalar: 0.5, writable: false)
        }, readMute: { _ in AudioDeviceMute(muted: nil, writable: false) })
        let snapshot = SystemAudioSnapshot(outputs: outputs, selectedID: 11, controls: controls)
        let decoded = try JSONDecoder().decode(SystemAudioSnapshot.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded.outputs == outputs)
        #expect(decoded.controls == controls)
        #expect(decoded.selectedID == 11)
    }
}
