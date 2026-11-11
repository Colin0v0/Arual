import CoreAudio
import Testing
@testable import AuralCore

struct HeadphoneControlSelectionTests {
    private let mac = AudioOutput(id: 1, uid: "speaker", name: "Mac", transport: kAudioDeviceTransportTypeBuiltIn)
    private let apple = AudioOutput(id: 2, uid: "apple", name: "Podssss", transport: kAudioDeviceTransportTypeBluetooth)
    private let bw = AudioOutput(id: 3, uid: "bw", name: "Colin Px7 S3", transport: kAudioDeviceTransportTypeBluetooth)

    @Test func allSupportedHeadphonesAppearEvenWhenSpeakersAreSelected() {
        var selection = HeadphoneControlSelection()
        let speaker = AudioOutput(id: 4, uid: "bt-speaker", name: "Bluetooth Speaker", transport: kAudioDeviceTransportTypeBluetooth)
        let monitor = AudioOutput(id: 5, uid: "monitor", name: "Display", transport: kAudioDeviceTransportTypeDisplayPort)
        let audio = SystemAudioSnapshot(outputs: [mac, apple, speaker, monitor, bw], selectedID: mac.id, controls: [:])
        selection.update(snapshot: audio, supports: { [apple.uid, bw.uid].contains($0.uid) })
        #expect(selection.candidates == [apple, bw])
        #expect(audio.selectedID == mac.id)
        // 仅有音量或蓝牙传输均不足以入选；物理传输与协议能力必须同时满足。
        selection.update(snapshot: audio, supports: { _ in false })
        #expect(selection.candidates.isEmpty)
    }

    @Test func defaultOutputChangesDoNotChangeCandidatesButDeviceRemovalDoes() {
        var selection = HeadphoneControlSelection()
        for selected in [mac.id, apple.id, UInt32(100), UInt32(0)] {
            selection.update(snapshot: SystemAudioSnapshot(outputs: [mac, apple, bw], selectedID: selected, controls: [:]),
                             supports: { _ in true })
            #expect(selection.candidates == [apple, bw])
        }
        selection.update(snapshot: SystemAudioSnapshot(outputs: [mac, bw], selectedID: mac.id, controls: [:]), supports: { _ in true })
        #expect(selection.candidates == [bw])
        let reconnected = AudioOutput(id: 22, uid: apple.uid, name: apple.name, transport: apple.transport)
        selection.update(snapshot: SystemAudioSnapshot(outputs: [mac, reconnected, bw], selectedID: mac.id, controls: [:]), supports: { _ in true })
        #expect(selection.candidates == [reconnected, bw])
    }

    @Test func connectionGuardChecksIdentityAndLivenessInsteadOfPlaybackRoute() throws {
        try HeadphoneConnectionGuard.check("apple", deviceIDs: [1, 2],
                                          readUID: { $0 == 1 ? "speaker" : "apple" },
                                          isConnectedBluetoothOutput: { $0 == 2 })
        #expect(throws: AudioFailure.self) {
            try HeadphoneConnectionGuard.check("apple", deviceIDs: [1], readUID: { _ in "speaker" },
                                              isConnectedBluetoothOutput: { _ in true })
        }
        #expect(throws: AudioFailure.self) {
            try HeadphoneConnectionGuard.check("apple", deviceIDs: [2], readUID: { _ in "apple" },
                                              isConnectedBluetoothOutput: { _ in false })
        }
    }
}
