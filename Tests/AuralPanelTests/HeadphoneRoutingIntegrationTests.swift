import CoreAudio
import Testing
@testable import AuralCore
@testable import Aural

@MainActor
struct HeadphoneRoutingIntegrationTests {
    private func controller(_ hardware: RoutingTestHardware) -> HeadphoneController {
        HeadphoneController(appleHardware: AppleHeadphoneHardware(
            isSupported: { [2, 4].contains($0) },
            validateTarget: { output in
                // 控制资格由在线身份决定，不读取默认输出或聚合成员。
                guard hardware.outputs.contains(where: { $0.id == output.id && $0.uid == output.uid }) else {
                    throw AudioFailure("耳机已断开")
                }
            },
            snapshot: { _ in AppleHeadphoneSnapshot(noiseMode: .transparency, supportedNoiseModes: [.cancellation, .transparency], wearState: .bothEars) },
            requestMode: { _, _ in Issue.record("仅枚举控制对象不应发送降噪命令") },
            waitForReadback: { await Task.yield() }))
    }

    @Test func headphonesStayAvailableWhenDefaultOutputAndAggregateMembershipChange() {
        let hardware = RoutingTestHardware()
        hardware.outputs.append(AudioOutput(id: 4, uid: "second-head", name: "Second AirPods", transport: kAudioDeviceTransportTypeBluetooth))
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             headphoneControllerFactory: { controller(hardware) })
        #expect(hardware.selected == 1)
        #expect(hardware.selections.isEmpty)
        #expect(model.headphones.entries.map(\.id) == ["headphone", "second-head"])
        let first = model.headphones.entries[0].controller
        let second = model.headphones.entries[1].controller
        #expect(model.startSimultaneousOutput(["speaker", "headphone", "second-head"]))
        #expect(model.updateSimultaneousOutput(["speaker", "headphone"]))
        // 移出播放路由不等于蓝牙断开，仍保留独立控制。
        #expect(model.headphones.entries.map(\.id) == ["headphone", "second-head"])
        #expect(second.boundOutputUID == "second-head")
        model.selectOutput(1)
        #expect(first.phase == .ready && second.phase == .ready)
        #expect(model.headphones.entries[0].controller === first)
        hardware.outputs.removeAll { $0.id == 4 }
        model.refresh()
        #expect(model.headphones.entries.map(\.id) == ["headphone"])
        #expect(second.boundOutputUID == nil)
        #expect(model.shutdown())
    }

    @Test func playbackTransitionDoesNotRevokeConnectedHeadphoneControl() {
        let hardware = RoutingTestHardware()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             headphoneControllerFactory: { controller(hardware) })
        let driver = model.headphones.entries[0].controller
        hardware.deferSelection = true
        #expect(!model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(model.outputRouting.phase == .awaitingHAL)
        #expect(model.headphoneControl.candidates.map(\.uid) == ["headphone"])
        #expect(driver.isRouteAuthorized)
        #expect(driver.phase == .ready)
        hardware.deferSelection = false
        hardware.commitSelection()
        model.refresh()
        #expect(model.headphones.entries.first?.controller === driver)
        #expect(model.shutdown())
    }

    @Test func changingNoiseModeWhileSpeakersPlayNeverSelectsHeadphones() async throws {
        let hardware = RoutingTestHardware()
        var mode = NoiseMode.transparency
        var writes: [String] = []
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             headphoneControllerFactory: {
            HeadphoneController(appleHardware: AppleHeadphoneHardware(
                isSupported: { $0 == 2 },
                validateTarget: { output in
                    guard hardware.outputs.contains(output) else { throw AudioFailure("耳机已断开") }
                },
                snapshot: { _ in AppleHeadphoneSnapshot(noiseMode: mode, supportedNoiseModes: [.cancellation, .transparency], wearState: .bothEars) },
                requestMode: { target, output in mode = target; writes.append(output.uid) },
                waitForReadback: { await Task.yield() }))
        })
        let driver = try #require(model.headphones.entries.first?.controller)
        let playbackWrites = hardware.selections
        driver.setNoiseMode(.cancellation)
        for _ in 0..<200 where driver.busy { try await Task.sleep(for: .milliseconds(1)) }
        #expect(!driver.busy)
        #expect(driver.state.noiseMode == .cancellation)
        #expect(writes == ["headphone"])
        #expect(hardware.selected == 1)
        #expect(hardware.systemSelected == 1)
        #expect(hardware.selections == playbackWrites)
        #expect(model.shutdown())
    }
}
