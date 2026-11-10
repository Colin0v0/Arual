import Foundation
import Testing
@testable import AuralCore

struct ApplicationMixStateTests {
    private let group = AudioProcessGroup(id: "test", bundleID: "test", processIDs: [10], objectIDs: [100])

    @Test func configurationIsNotAnAudioReadout() throws {
        var state = ApplicationMixState()
        #expect(!state.managed)
        #expect(state.action(group: group, sessionObjectIDs: nil) == .inactive)
        try state.setGain(0.35)
        state.toggleMute()
        state.enable(outputUID: "test-output")
        #expect(state.gain == 0.35 && state.muted)
        #expect(state.action(group: nil, sessionObjectIDs: nil) == .awaitRegistration)
        #expect(state.action(group: group, sessionObjectIDs: nil) == .start)
    }

    @Test func failuresRemainLatchedUntilExplicitEnable() throws {
        var state = ApplicationMixState()
        state.enable(outputUID: "test-output")
        state.fail("permission denied")
        try state.setGain(0.2)
        #expect(state.failure == "permission denied")
        #expect(state.action(group: group, sessionObjectIDs: nil) == .inactive)
        state.enable(outputUID: "test-output")
        #expect(state.failure == nil)
        #expect(state.action(group: group, sessionObjectIDs: nil) == .start)
    }

    @Test func processMembershipChangesRequireReplacementNotDuplicateTaps() {
        var state = ApplicationMixState()
        state.enable(outputUID: "test-output")
        #expect(state.action(group: group, sessionObjectIDs: [100]) == .keep)
        #expect(state.action(group: group, sessionObjectIDs: [101]) == .replace)
        state.disable()
        #expect(state.action(group: group, sessionObjectIDs: [100]) == .inactive)
    }

    @Test func invalidDesiredGainIsRejected() {
        var state = ApplicationMixState()
        for gain: Float in [.nan, .infinity, -0.1, 1.1] {
            #expect(throws: (any Error).self) { try state.setGain(gain) }
        }
        #expect(state.gain == 1)
    }

    @Test func pausedAudioDoesNotTripTheWatchdog() {
        var watchdog = AudioActivityWatchdog()
        let start = Date(timeIntervalSince1970: 100)
        let stalled1 = watchdog.isStalled(expectingAudio: false, callbacks: 0, at: start)
        #expect(!stalled1)
        let stalled2 = watchdog.isStalled(expectingAudio: false, callbacks: 0, at: start.addingTimeInterval(300))
        #expect(!stalled2)
        let stalled3 = watchdog.isStalled(expectingAudio: true, callbacks: 0, at: start.addingTimeInterval(301))
        #expect(!stalled3)
        let stalled4 = watchdog.isStalled(expectingAudio: true, callbacks: 0, at: start.addingTimeInterval(310))
        #expect(stalled4)
        let stalled5 = watchdog.isStalled(expectingAudio: true, callbacks: 1, at: start.addingTimeInterval(311))
        #expect(!stalled5)
        let stalled6 = watchdog.isStalled(expectingAudio: false, callbacks: 1, at: start.addingTimeInterval(400))
        #expect(!stalled6)
    }
}

struct MixLifecycleSafetyTests {
    @Test func outputChangeIsLatchedEvenIfItChangesBack() {
        var state = ApplicationMixState()
        state.enable(outputUID: "X")
        let changed = state.pauseIfOutputChanged(currentUID: "Y")
        #expect(changed)
        let back = state.pauseIfOutputChanged(currentUID: "X")
        #expect(!back)
        #expect(state.failure != nil)
        let group = AudioProcessGroup(id: "test", bundleID: "test", processIDs: [10], objectIDs: [100])
        #expect(state.action(group: group, sessionObjectIDs: nil) == .inactive)
    }

    @Test func ownershipDoesNotDependOnTheApplicationRowID() {
        #expect(AudioSessionOwnership.overlaps(requested: [100, 101], existing: [[101]]))
        #expect(!AudioSessionOwnership.overlaps(requested: [100, 101], existing: [[102]]))
        #expect(!AudioSessionOwnership.overlaps(requested: [100], existing: []))
    }
}

struct FineTuneConflictTests {
    private let group = AudioProcessGroup(id: "test", bundleID: "test", processIDs: [10], objectIDs: [100])

    @Test func exactIdentityOnly() {
        #expect(AudioMixerConflict.fineTuneIsRunning(bundleIDs: ["com.finetuneapp.FineTune"]))
        #expect(!AudioMixerConflict.fineTuneIsRunning(bundleIDs: ["org.example.finetune.editor"]))
        #expect(!AudioMixerConflict.fineTuneIsRunning(bundleIDs: ["com.finetuneapp.FineTune.helper"]))
        #expect(!AudioMixerConflict.fineTuneIsRunning(bundleIDs: []))
    }

    @Test func exitUpdatesMessageWithoutStartingAudio() throws {
        var state = ApplicationMixState()
        try state.setGain(0.79)
        state.toggleMute()
        state.enable(outputUID: "output")
        state.blockForFineTune()
        #expect(state.failureReason == .fineTuneRunning)
        state.updateFineTuneAvailability(isRunning: false)
        #expect(state.failureReason == .fineTuneExited)
        #expect(state.failure == "FineTune 已退出，音量配置尚未应用。")
        #expect(state.gain == 0.79 && state.muted)
        #expect(state.action(group: group, sessionObjectIDs: nil) == .inactive)
        // 继续拖动也不能偷偷重试，必须由重新应用操作解除锁存。
        try state.setGain(0.5)
        #expect(state.action(group: group, sessionObjectIDs: nil) == .inactive)
        state.enable(outputUID: "output")
        #expect(state.failureReason == nil)
        #expect(state.action(group: group, sessionObjectIDs: nil) == .start)
    }

    @Test func relaunchRestoresCurrentConflictMessage() {
        var state = ApplicationMixState()
        state.enable(outputUID: "output")
        state.blockForFineTune()
        state.updateFineTuneAvailability(isRunning: false)
        state.updateFineTuneAvailability(isRunning: true)
        #expect(state.failureReason == .fineTuneRunning)
        #expect(state.action(group: group, sessionObjectIDs: nil) == .inactive)
    }

    @Test func availabilityCannotClearOtherFailuresOrCreateConflicts() {
        var state = ApplicationMixState()
        state.updateFineTuneAvailability(isRunning: true)
        #expect(state.failure == nil)
        state.fail("permission denied")
        state.updateFineTuneAvailability(isRunning: false)
        #expect(state.failureReason == .other("permission denied"))
        state.updateFineTuneAvailability(isRunning: true)
        #expect(state.failure == "permission denied")
    }

    @Test func disablingClearsTypedConflict() {
        var state = ApplicationMixState()
        state.enable(outputUID: "output")
        state.blockForFineTune()
        state.disable()
        state.updateFineTuneAvailability(isRunning: false)
        #expect(state.failureReason == nil)
        #expect(!state.managed)
    }
}
