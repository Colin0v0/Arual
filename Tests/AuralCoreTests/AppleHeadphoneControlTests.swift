import CoreAudio
import Foundation
import Testing
@testable import AuralCore

@MainActor
struct AppleHeadphoneControlTests {
    @Test func rejectedModeWriteKeepsActualReadingsAndDoesNotRetryTheSet() async throws {
        let fixture = AppleControlFixture()
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        fixture.writeError = AudioFailure("写入音频属性失败", status: kAudioHardwareIllegalOperationError)
        controller.setNoiseMode(.cancellation)
        try await settle { !controller.busy }
        #expect(controller.phase == .ready)
        #expect(controller.state.noiseMode == .transparency)
        #expect(controller.boundOutputUID == fixture.a.uid)
        #expect(controller.identityVerified)
        #expect(controller.pendingNoiseMode == nil)
        #expect(controller.errorMessage != nil)
        #expect(fixture.writes.count == 1)
        controller.updateOutput(fixture.a)
        #expect(fixture.writes.count == 1)
        #expect(controller.state.noiseMode == .transparency)
        controller.shutdown()
    }

    @Test func notWornHeadphoneDoesNotReceiveModeWritesAndWearRecoveryOnlyReads() {
        let fixture = AppleControlFixture()
        fixture.worn = false
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        #expect(controller.isAwaitingWear)
        #expect(controller.errorMessage == nil)
        #expect(!controller.identityVerified)
        controller.setNoiseMode(.cancellation)
        #expect(fixture.writes.isEmpty)
        fixture.worn = true
        controller.updateOutput(fixture.a)
        #expect(controller.phase == .ready)
        #expect(!controller.isAwaitingWear)
        #expect(controller.state.noiseMode == .transparency)
        #expect(fixture.writes.isEmpty)
        controller.shutdown()
    }

    @Test func removalBetweenModeActionAndTaskDoesNotSendTheQueuedSet() async throws {
        let fixture = AppleControlFixture()
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        controller.setNoiseMode(.cancellation)
        fixture.worn = false
        try await settle { !controller.busy }
        #expect(controller.isAwaitingWear)
        #expect(controller.errorMessage == nil)
        #expect(fixture.writes.isEmpty)
        fixture.worn = true
        controller.updateOutput(fixture.a)
        #expect(controller.phase == .ready)
        #expect(controller.state.noiseMode == .transparency)
        #expect(fixture.writes.isEmpty)
        controller.shutdown()
    }

    private func settle(_ predicate: () -> Bool) async throws {
        for _ in 0..<200 {
            if predicate() { return }
            try await Task.sleep(for: .milliseconds(1))
        }
        #expect(predicate())
    }

    @Test func confirmedHalSignatureOverridesAnEditedManufacturerName() {
        let fixture = AppleControlFixture()
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        let renamed = AudioOutput(id: fixture.a.id, uid: fixture.a.uid, name: "Colin Px7 S3", transport: fixture.a.transport)
        controller.updateOutput(renamed)
        #expect(controller.family == .apple)
        #expect(controller.phase == .ready)
        #expect(controller.boundOutputUID == fixture.a.uid)
        controller.shutdown()
    }

    @Test func changingTargetBeforeQueuedTaskRunsPreventsTheOldWrite() async throws {
        let fixture = AppleControlFixture()
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        controller.setNoiseMode(.cancellation)
        fixture.allowed = fixture.b
        controller.updateOutput(fixture.b)
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.writes.isEmpty)
        #expect(controller.boundOutputUID == fixture.b.uid)
        #expect(controller.state.noiseMode == .transparency)
        controller.shutdown()
    }

    @Test func routeChangeBetweenUiActionAndTaskExecutionRejectsTheWrite() async throws {
        let fixture = AppleControlFixture()
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        controller.setNoiseMode(.cancellation)
        fixture.allowed = nil // HAL 已变更，但主模型的下一次刷新尚未到达。
        try await settle { controller.errorMessage != nil }
        #expect(fixture.writes.isEmpty)
        #expect(!controller.identityVerified)
        controller.shutdown()
    }

    @Test func lateReadbackCannotOverwriteTheNewHeadphoneState() async throws {
        let fixture = AppleControlFixture()
        fixture.holdReadback = true
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        controller.setNoiseMode(.cancellation)
        try await settle { !fixture.waits.isEmpty }
        #expect(fixture.writes.map(\.uid) == [fixture.a.uid])
        fixture.allowed = fixture.b
        controller.updateOutput(fixture.b)
        let oldReads = fixture.reads.filter { $0 == fixture.a.id }.count
        fixture.resume()
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.reads.filter { $0 == fixture.a.id }.count == oldReads)
        #expect(controller.boundOutputUID == fixture.b.uid)
        #expect(controller.state.noiseMode == .transparency)
        #expect(controller.pendingNoiseMode == nil)
        #expect(!controller.busy)
        controller.shutdown()
    }

    @Test func sameUidWithANewDeviceIdInvalidatesTheOldTaskAndRebinds() async throws {
        let fixture = AppleControlFixture()
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        controller.setNoiseMode(.cancellation)
        let reconnected = AudioOutput(id: 22, uid: fixture.a.uid, name: fixture.a.name, transport: fixture.a.transport)
        fixture.allowed = reconnected
        controller.updateOutput(reconnected)
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.writes.isEmpty)
        #expect(fixture.reads.last == 22)
        #expect(controller.phase == .ready)
        controller.shutdown()
    }

    @Test func onlyConfirmedReadbackPublishesTheRequestedMode() async throws {
        let fixture = AppleControlFixture()
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        controller.setNoiseMode(.cancellation)
        #expect(controller.state.noiseMode == .transparency)
        try await settle { !controller.busy }
        #expect(fixture.writes.map(\.uid) == [fixture.a.uid])
        #expect(controller.state.noiseMode == .cancellation)
        #expect(controller.errorMessage == nil)
        controller.shutdown()
    }

    @Test func missingConfirmationFailsWithoutRepeatedWrites() async throws {
        let fixture = AppleControlFixture()
        fixture.confirmWrite = false
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        controller.setNoiseMode(.cancellation)
        try await settle { controller.errorMessage != nil }
        #expect(fixture.writes.count == 1)
        #expect(controller.pendingNoiseMode == nil)
        #expect(!controller.busy)
        #expect(!controller.identityVerified)
        controller.updateOutput(fixture.a) // 周期观察不能静默解除一次真实命令失败。
        #expect(controller.errorMessage != nil)
        fixture.confirmWrite = true
        controller.retryAutomaticConnection(output: fixture.a)
        #expect(controller.phase == .ready)
        controller.setNoiseMode(.cancellation)
        try await settle { !controller.busy }
        #expect(controller.errorMessage == nil)
        #expect(controller.state.noiseMode == .cancellation)
        #expect(fixture.writes.count == 2)
        controller.shutdown()
    }

    @Test func stoppingControlCancelsPendingCommandsAndDoesNotResumeOnPollingOrRouteTransitions() async throws {
        let fixture = AppleControlFixture()
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        controller.setNoiseMode(.cancellation)
        controller.disconnect()
        for _ in 0..<10 { await Task.yield() }
        #expect(fixture.writes.isEmpty)
        #expect(controller.isControlSuppressed)
        #expect(controller.boundOutputUID == nil)
        controller.updateOutput(nil) // 音频路由正在重建，不应丢掉用户的暂停授权。
        controller.updateOutput(fixture.a)
        #expect(controller.isControlSuppressed)
        #expect(controller.phase == .idle)
        #expect(controller.boundOutputUID == nil)
        controller.retryAutomaticConnection(output: fixture.a)
        #expect(!controller.isControlSuppressed)
        #expect(controller.phase == .ready)
        #expect(controller.boundOutputUID == fixture.a.uid)
        controller.shutdown()
    }

    @Test func staleRetryFromAnOldViewCannotRebindTheController() {
        let fixture = AppleControlFixture()
        let controller = HeadphoneController(appleHardware: fixture.hardware)
        controller.updateOutput(fixture.a)
        fixture.allowed = fixture.b
        controller.updateOutput(fixture.b)
        controller.retryAutomaticConnection(output: fixture.a)
        #expect(controller.boundOutputUID == fixture.b.uid)
        #expect(controller.phase == .ready)
        controller.outputUnavailable()
        #expect(controller.boundOutputUID == nil)
        #expect(controller.family == nil)
        #expect(controller.supportedNoiseModes.isEmpty)
        controller.shutdown()
    }
}

@MainActor
private final class AppleControlFixture {
    let a = AudioOutput(id: 11, uid: "apple-a", name: "AirPods A", transport: kAudioDeviceTransportTypeBluetooth)
    let b = AudioOutput(id: 12, uid: "apple-b", name: "AirPods B", transport: kAudioDeviceTransportTypeBluetooth)
    var allowed: AudioOutput?
    var modes: [AudioDeviceID: NoiseMode] = [:]
    var reads: [AudioDeviceID] = []
    var writes: [AudioOutput] = []
    var holdReadback = false
    var confirmWrite = true
    var writeError: Error?
    var worn: Bool?
    var waits: [CheckedContinuation<Void, Error>] = []
    init() { allowed = a }
    func resume() { if !waits.isEmpty { waits.removeFirst().resume() } }
    var hardware: AppleHeadphoneHardware {
        AppleHeadphoneHardware(isSupported: { [11, 12, 22].contains($0) }, validateTarget: { output in
            guard self.allowed?.uid == output.uid, self.allowed?.id == output.id else {
                throw AudioFailure("控制目标已经离开当前路由")
            }
        }, snapshot: { id in
            self.reads.append(id)
            return AppleHeadphoneSnapshot(noiseMode: self.modes[id] ?? .transparency,
                                          supportedNoiseModes: [.cancellation, .transparency, .adaptive], isWorn: self.worn)
        }, requestMode: { mode, output in
            if self.worn == false { throw AppleHeadphoneNotWorn() }
            self.writes.append(output)
            if let writeError = self.writeError { throw writeError }
            if self.confirmWrite { self.modes[output.id] = mode }
        }, waitForReadback: {
            if self.holdReadback {
                try await withCheckedThrowingContinuation { self.waits.append($0) }
            } else { await Task.yield() }
        })
    }
}
