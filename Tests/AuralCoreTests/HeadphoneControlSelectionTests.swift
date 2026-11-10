import CoreAudio
import Testing
@testable import AuralCore

struct HeadphoneControlSelectionTests {
    private let mac = AudioOutput(id: 1, uid: "speaker", name: "Mac", transport: kAudioDeviceTransportTypeBuiltIn)
    private let apple = AudioOutput(id: 2, uid: "apple", name: "Podssss", transport: kAudioDeviceTransportTypeBluetooth)
    private let bw = AudioOutput(id: 3, uid: "bw", name: "Colin Px7 S3", transport: kAudioDeviceTransportTypeBluetooth)
    private let aggregate = AudioOutput(id: 100, uid: "local.aural.multi.test", name: "组合", transport: kAudioDeviceTransportTypeAggregate)

    private func group(_ members: [AudioOutput]) -> ConfirmedOutputRoute {
        let route = MultiOutputRoute(deviceID: aggregate.id, uid: aggregate.uid, outputs: members,
            mainOutputUID: members[0].uid, previousOutputUID: mac.uid, sampleRate: 48_000)
        return ConfirmedOutputRoute(intent: .simultaneous(members.map(\.uid)), output: aggregate, aggregate: route)
    }
    private func snapshot(_ members: [AudioOutput], selected: AudioDeviceID = 100) -> SystemAudioSnapshot {
        SystemAudioSnapshot(outputs: members + [aggregate], selectedID: selected, controls: [:])
    }
    private func supports(_ output: AudioOutput) -> Bool { [apple.uid, bw.uid].contains(output.uid) }

    @Test func appleAndBowersUseIdenticalSingleAndUniqueMemberSelectionRules() {
        for headphone in [apple, bw] {
            var selection = HeadphoneControlSelection()
            let single = ConfirmedOutputRoute(intent: .single(headphone.uid), output: headphone, aggregate: nil)
            selection.update(confirmed: single, snapshot: snapshot([mac, headphone], selected: headphone.id), supports: supports)
            #expect(selection.candidates == [headphone])
            selection.update(confirmed: group([mac, headphone]), snapshot: snapshot([mac, headphone]), supports: supports)
            #expect(selection.candidates == [headphone])
            #expect(selection.candidates.allSatisfy { !$0.isAggregate })
        }
    }

    @Test func multipleHeadphonesAreAllAuthorizedWithoutAnExplicitChoice() {
        var selection = HeadphoneControlSelection()
        let members = [mac, bw, apple]
        let audio = snapshot(members)
        selection.update(confirmed: group(members), snapshot: audio, supports: supports)
        #expect(selection.candidates.map(\.uid) == [bw.uid, apple.uid])
        #expect(audio.selectedID == aggregate.id) // 解析所有控制对象不改变声音路由。
        selection.update(confirmed: group(members), snapshot: audio, supports: supports)
        #expect(selection.candidates == [bw, apple])
        selection.update(confirmed: nil, snapshot: audio, supports: supports)
        #expect(selection.candidates.isEmpty) // 过渡期没有写入资格。
        selection.update(confirmed: group(members), snapshot: audio, supports: supports)
        #expect(selection.candidates == [bw, apple])
    }

    @Test func removedMemberLosesControlAndConfirmedReturnRestoresItsOwnCard() {
        var selection = HeadphoneControlSelection()
        selection.update(confirmed: group([mac, apple, bw]), snapshot: snapshot([mac, apple, bw]), supports: supports)
        selection.update(confirmed: group([mac, bw]), snapshot: snapshot([mac, bw]), supports: supports)
        #expect(selection.candidates == [bw])
        selection.update(confirmed: group([mac, apple, bw]), snapshot: snapshot([mac, apple, bw]), supports: supports)
        #expect(selection.candidates == [apple, bw])
    }

    @Test func staleMemberIdentityAndStaleDefaultCannotAuthorizeControls() {
        var selection = HeadphoneControlSelection()
        let reconnected = AudioOutput(id: 22, uid: apple.uid, name: apple.name, transport: apple.transport)
        selection.update(confirmed: group([mac, apple]), snapshot: snapshot([mac, reconnected]), supports: supports)
        #expect(selection.candidates.isEmpty)
        selection.update(confirmed: group([mac, reconnected]), snapshot: snapshot([mac, reconnected]), supports: supports)
        #expect(selection.candidates.first?.id == 22)
        selection.update(confirmed: group([mac, reconnected]), snapshot: snapshot([mac, reconnected], selected: mac.id), supports: supports)
        #expect(selection.candidates.isEmpty)
    }
}
