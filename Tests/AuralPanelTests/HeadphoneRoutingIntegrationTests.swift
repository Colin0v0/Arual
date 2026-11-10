import CoreAudio
import Testing
@testable import AuralCore
@testable import Aural

@MainActor
struct HeadphoneRoutingIntegrationTests {
    private func controller(_ hardware: RoutingTestHardware) -> HeadphoneController {
        let apple = AppleHeadphoneHardware(isSupported: { [2, 4].contains($0) }, validateTarget: { output in
            let current = hardware.snapshot
            if current.selectedID == output.id { return }
            guard let group = hardware.compositions[current.selectedID],
                  let members = group[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]],
                  members.contains(where: { $0[kAudioSubDeviceUIDKey] as? String == output.uid }) else {
                throw AudioFailure("耳机不在当前输出路由")
            }
        }, snapshot: { _ in AppleHeadphoneSnapshot(noiseMode: .transparency, supportedNoiseModes: [.cancellation, .transparency]) },
            requestMode: { _, _ in Issue.record("仅选择控制对象不应发送降噪写命令") },
            waitForReadback: { await Task.yield() })
        return HeadphoneController(appleHardware: apple)
    }

    @Test func singleHeadphoneAndUniqueAggregateMemberShareTheSameUiAndDriverTarget() {
        let hardware = RoutingTestHardware()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             headphoneControllerFactory: { controller(hardware) })
        model.selectOutput(2)
        let driver = model.headphones.entries[0].controller
        #expect(model.headphoneControl.candidates.first?.uid == "headphone")
        #expect(driver.boundOutputUID == model.headphoneControl.candidates.first?.uid)
        #expect(model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(model.audio?.selectedID != 2)
        #expect(model.headphoneControl.candidates.first?.id == 2) // 耳机页收到真实成员，绝不是聚合ID。
        #expect(driver.boundOutputUID == "headphone")
        #expect(driver.phase == .ready)
        model.selectOutput(1)
        #expect(model.headphoneControl.candidates.isEmpty)
        #expect(driver.boundOutputUID == nil)
        #expect(driver.supportedNoiseModes.isEmpty)
        #expect(model.shutdown())
    }

    @Test func twoHeadphonesBindIndependentlyWithoutSelectingAndRemovalRevokesOnlyItsBinding() {
        let hardware = RoutingTestHardware()
        hardware.outputs.append(AudioOutput(id: 4, uid: "second-head", name: "Second AirPods", transport: kAudioDeviceTransportTypeBluetooth))
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             headphoneControllerFactory: { controller(hardware) })
        #expect(model.startSimultaneousOutput(["speaker", "headphone", "second-head"]))
        #expect(model.headphoneControl.candidates.count == 2)
        #expect(model.headphones.entries.map(\.id) == ["headphone", "second-head"])
        let first = model.headphones.entries[0].controller
        let second = model.headphones.entries[1].controller
        #expect(first !== second)
        let defaultOutput = hardware.selected
        let writes = hardware.selections.count
        #expect(first.boundOutputUID == "headphone")
        #expect(second.boundOutputUID == "second-head")
        model.refresh()
        #expect(hardware.selected == defaultOutput)
        #expect(hardware.selections.count == writes)
        #expect(model.updateSimultaneousOutput(["speaker", "headphone"]))
        #expect(model.headphones.entries.map(\.id) == ["headphone"])
        #expect(model.headphones.entries[0].controller === first)
        #expect(first.boundOutputUID == "headphone")
        #expect(second.boundOutputUID == nil)
        #expect(model.shutdown())
    }

    @Test func unconfirmedRouteRetainsIdleConnectionButRevokesAllWriteAuthorization() {
        let hardware = RoutingTestHardware()
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             headphoneControllerFactory: { controller(hardware) })
        model.selectOutput(2)
        let driver = model.headphones.entries[0].controller
        hardware.deferSelection = true
        #expect(!model.startSimultaneousOutput(["speaker", "headphone"]))
        #expect(model.outputRouting.phase == .awaitingHAL)
        #expect(model.headphoneControl.candidates.isEmpty)
        #expect(driver.boundOutputUID == "headphone")
        #expect(!driver.isRouteAuthorized)
        #expect(model.headphones.entries.first?.controller === driver)
        driver.setNoiseMode(.cancellation) // 注入驱动会在收到任何写入时让测试失败。
        hardware.deferSelection = false
        hardware.commitSelection()
        model.refresh()
        #expect(driver.boundOutputUID == "headphone")
        #expect(driver.isRouteAuthorized)
        #expect(model.headphones.entries.first?.controller === driver)
        #expect(model.headphoneControl.candidates.first?.uid == driver.boundOutputUID)
        #expect(model.shutdown())
    }
}
