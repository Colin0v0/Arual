import Foundation
import Testing
@testable import AuralCore

struct HeadphoneAutoConnectionTests {
    @Test func onlyOneAttemptPerAudioAttachment() {
        var policy = HeadphoneAutoConnection()
        let absent = policy.takeInitialAttempt()
        #expect(!absent)
        policy.updateOutput("test-output")
        let first = policy.takeInitialAttempt()
        let duplicate = policy.takeInitialAttempt()
        #expect(first && !duplicate)
        policy.updateOutput("test-output")
        let unchanged = policy.takeInitialAttempt()
        #expect(!unchanged)
        policy.updateOutput(nil); policy.updateOutput("test-output")
        let reattached = policy.takeInitialAttempt()
        #expect(reattached)
    }

    @Test func manualDisconnectIsNotUndoneByPollingOrWake() {
        var policy = HeadphoneAutoConnection()
        policy.updateOutput("test-output"); policy.suppress(); policy.radioOrWakeRecovered()
        let attempt = policy.takeInitialAttempt()
        let delay = policy.nextReconnectDelay()
        #expect(!attempt && delay == nil)
        policy.manualAttempt()
        #expect(!policy.userSuppressed)
    }

    @Test func fatalRPCFailureRequiresAnExplicitOrPhysicalReset() {
        var policy = HeadphoneAutoConnection()
        policy.updateOutput("test-output"); policy.recordFailure()
        let attempt = policy.takeInitialAttempt()
        let delay = policy.nextReconnectDelay()
        #expect(!attempt && delay == nil)
        policy.updateOutput("test-output")
        #expect(policy.failed)
        policy.manualAttempt()
        #expect(!policy.failed)
    }

    @Test func reconnectsHaveABoundedSchedule() {
        var policy = HeadphoneAutoConnection()
        policy.updateOutput("test-output")
        let delays = (0..<4).map { _ in policy.nextReconnectDelay() }
        #expect(delays == [2, 5, 10, nil])
        policy.confirmedConnection()
        let fresh = policy.nextReconnectDelay()
        #expect(fresh == 2)
    }

    @Test func newlyAdvertisedUUIDIsNotRejectedAsAnOldBinding() {
        let id = UUID()
        let candidate = HeadphoneCandidate(id: id, name: "LE_BWHP")
        #expect(HeadphoneIdentity.selection(outputName: "Px8", candidates: [candidate]) == .choose(id))
    }

    @Test func firstConnectionUsesUniqueTransportThenVerifiesHardware() {
        let id = UUID()
        let exact = HeadphoneCandidate(id: id, name: "My Px7 S3")
        #expect(HeadphoneIdentity.selection(outputName: "My-Px7 S3", candidates: [exact]) == .choose(id))
        #expect(HeadphoneIdentity.selection(outputName: "Someone Px7 S3", candidates: [exact]) == .choose(id))
        #expect(HeadphoneIdentity.selection(outputName: "My Px7 S3", 
                                            candidates: [exact, HeadphoneCandidate(id: UUID(), name: "My Px7 S3")]) == .ambiguous)
    }

    @Test func unknownSnapshotCanResumeTransportButKeepsPhysicalIdentity() {
        var policy = HeadphoneAutoConnection()
        policy.updateOutput("hardware-address:output")
        let first = policy.takeInitialAttempt()
        policy.observe(.unavailable)
        policy.observe(.confirmed("hardware-address:output"))
        let resumed = policy.takeInitialAttempt()
        #expect(first && resumed)
        #expect(policy.outputUID == "hardware-address:output")
    }

}

struct HeadphoneRecoveryIdentityTests {
    @Test func unknownSnapshotDoesNotUndoManualSuppression() {
        var policy = HeadphoneAutoConnection()
        policy.updateOutput("X"); policy.suppress()
        let unknown = policy.observe(.unavailable)
        let recovered = policy.observe(.confirmed("X"))
        let attempt = policy.takeInitialAttempt()
        #expect(!unknown && !recovered && !attempt)
        #expect(policy.userSuppressed)
    }

    @Test func unknownSnapshotDoesNotClearFatalFailure() {
        var policy = HeadphoneAutoConnection()
        policy.updateOutput("X"); policy.recordFailure()
        policy.observe(.unavailable); policy.observe(.confirmed("X"))
        #expect(policy.failed)
        let attempt = policy.takeInitialAttempt()
        #expect(!attempt)
    }

    @Test func reconnectKeepsHardwareOutputWithoutPinningBleUUID() {
        var policy = HeadphoneAutoConnection()
        policy.updateOutput("11-22-33-44-55-66:output")
        let delay = policy.nextReconnectDelay()
        #expect(delay == 2)
        #expect(policy.outputUID == "11-22-33-44-55-66:output")
        policy.updateOutput(nil)
        #expect(policy.outputUID == nil)
    }
}
