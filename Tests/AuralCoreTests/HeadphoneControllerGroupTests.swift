import CoreAudio
import Foundation
import Testing
@testable import AuralCore

@MainActor
struct HeadphoneControllerGroupTests {
    @Test func unsupportedOutputsNeverBecomeControlEntries() {
        let fixture = GroupHardwareFixture()
        let group = HeadphoneControllerGroup(makeController: fixture.makeController)
        let speaker = AudioOutput(id: 70, uid: "speaker", name: "Bluetooth Speaker", transport: kAudioDeviceTransportTypeBluetooth)
        let monitor = AudioOutput(id: 71, uid: "display", name: "Display", transport: kAudioDeviceTransportTypeDisplayPort)
        group.updateOutputs([speaker, first, monitor])
        #expect(group.entries.map(\.id) == [first.uid])
        group.shutdown()
    }

    @Test func routeTransitionKeepsVerifiedIdleControllersWithoutAllowingCommands() throws {
        let fixture = GroupHardwareFixture()
        let group = HeadphoneControllerGroup(makeController: fixture.makeController)
        group.updateOutputs([first, second])
        let firstDriver = try #require(group.entries.first?.controller)
        let secondDriver = try #require(group.entries.last?.controller)
        group.prepareRouteChange(retaining: [first.uid, second.uid])
        group.prepareRouteChange(retaining: [first.uid, second.uid])
        #expect(group.entries.count == 2)
        #expect(firstDriver.phase == .ready && secondDriver.phase == .ready)
        #expect(!firstDriver.isRouteAuthorized && !secondDriver.isRouteAuthorized)
        firstDriver.setNoiseMode(.cancellation)
        secondDriver.setNoiseMode(.cancellation)
        #expect(fixture.writes.isEmpty)
        group.updateOutputs([first, second])
        #expect(group.entries.first?.controller === firstDriver)
        #expect(group.entries.last?.controller === secondDriver)
        #expect(firstDriver.isRouteAuthorized && secondDriver.isRouteAuthorized)
        #expect(fixture.createdCount == 2)
        group.prepareRouteChange(retaining: [first.uid])
        #expect(group.entries.map(\.id) == [first.uid])
        #expect(secondDriver.boundOutputUID == nil)
        group.shutdown()
    }

    private let first = AudioOutput(id: 21, uid: "first", name: "First AirPods",
                                    transport: kAudioDeviceTransportTypeBluetooth)
    private let second = AudioOutput(id: 22, uid: "second", name: "Second AirPods",
                                     transport: kAudioDeviceTransportTypeBluetooth)

    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(predicate())
    }

    @Test func simultaneousCommandsUseIndependentQueuesAndConfirmedReadings() async throws {
        let fixture = GroupHardwareFixture()
        let group = HeadphoneControllerGroup(makeController: fixture.makeController)
        group.updateOutputs([first, second])
        let firstDriver = try #require(group.entries.first?.controller)
        let secondDriver = try #require(group.entries.last?.controller)
        #expect(firstDriver !== secondDriver)
        #expect(fixture.createdCount == 2)
        firstDriver.setNoiseMode(.cancellation)
        secondDriver.setNoiseMode(.off)
        #expect(firstDriver.busy && secondDriver.busy)
        try await settle { !firstDriver.busy && !secondDriver.busy }
        #expect(fixture.writes == ["first", "second"])
        #expect(firstDriver.state.noiseMode == .cancellation)
        #expect(secondDriver.state.noiseMode == .off)
        #expect(firstDriver.boundOutputUID == first.uid)
        #expect(secondDriver.boundOutputUID == second.uid)
        #expect(group.battery == nil)
        group.shutdown()
    }

    @Test func failureAndStopOnOneHeadphoneDoNotDisableTheOther() async throws {
        let fixture = GroupHardwareFixture()
        let group = HeadphoneControllerGroup(makeController: fixture.makeController)
        group.updateOutputs([first, second])
        let firstDriver = try #require(group.entries.first?.controller)
        let secondDriver = try #require(group.entries.last?.controller)
        fixture.failedUID = first.uid
        firstDriver.setNoiseMode(.cancellation)
        secondDriver.setNoiseMode(.cancellation)
        try await settle { !firstDriver.busy && !secondDriver.busy }
        #expect(firstDriver.errorMessage != nil)
        #expect(secondDriver.errorMessage == nil)
        #expect(secondDriver.state.noiseMode == .cancellation)
        firstDriver.disconnect()
        group.updateOutputs([first, second])
        #expect(firstDriver.isControlSuppressed)
        #expect(secondDriver.phase == .ready)
        #expect(secondDriver.boundOutputUID == second.uid)
        group.outputUnavailable()
        group.updateOutputs([first, second])
        #expect(group.entries.first?.controller === firstDriver)
        #expect(firstDriver.isControlSuppressed)
        #expect(group.entries.last?.controller === secondDriver)
        #expect(secondDriver.phase == .ready)
        group.shutdown()
    }

    @Test func removingMemberCancelsOnlyItsQueuedWriteAndReusesOtherController() async throws {
        let fixture = GroupHardwareFixture()
        let group = HeadphoneControllerGroup(makeController: fixture.makeController)
        group.updateOutputs([first, second])
        let firstDriver = try #require(group.entries.first?.controller)
        let secondDriver = try #require(group.entries.last?.controller)
        firstDriver.setNoiseMode(.cancellation)
        secondDriver.setNoiseMode(.cancellation)
        group.updateOutputs([second])
        try await settle { !secondDriver.busy }
        #expect(fixture.writes == ["second"])
        #expect(firstDriver.boundOutputUID == nil)
        #expect(group.entries.first?.controller === secondDriver)
        #expect(secondDriver.state.noiseMode == .cancellation)
        group.shutdown()
    }

    @Test func suspendedGroupDoesNotActivateNewMembersAndShutdownCannotRestartThem() {
        let fixture = GroupHardwareFixture()
        let group = HeadphoneControllerGroup(makeController: fixture.makeController)
        group.updateOutputs([first])
        group.suspend()
        group.updateOutputs([first, second])
        #expect(group.entries.allSatisfy { $0.controller.phase != .ready })
        group.resume()
        group.updateOutputs([first, second])
        #expect(group.entries.allSatisfy { $0.controller.phase == .ready })
        group.shutdown()
        let count = fixture.createdCount
        group.resume()
        group.updateOutputs([first, second])
        #expect(fixture.createdCount == count)
        #expect(!group.supports(first))
    }
}

@MainActor
private final class GroupHardwareFixture {
    var createdCount = 0
    var writes: [String] = []
    var failedUID: String?
    private var modes: [AudioDeviceID: NoiseMode] = [21: .transparency, 22: .transparency]

    func makeController() -> HeadphoneController {
        createdCount += 1
        return HeadphoneController(appleHardware: AppleHeadphoneHardware(
            isSupported: { self.modes[$0] != nil }, validateTarget: { _ in },
            snapshot: { deviceID in
                let mode = try #require(self.modes[deviceID])
                return AppleHeadphoneSnapshot(noiseMode: mode,
                    supportedNoiseModes: [.off, .cancellation, .transparency])
            }, requestMode: { mode, output in
                if self.failedUID == output.uid { throw AudioFailure("该耳机控制写入失败") }
                self.writes.append(output.uid)
                self.modes[output.id] = mode
            }, waitForReadback: { await Task.yield() }))
    }
}
