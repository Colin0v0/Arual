import CoreAudio
import Testing
@testable import AuralCore

struct AudioPermissionProbeTests {
    @Test @MainActor func permissionTapIsPrivateAndDoesNotMuteAudio() {
        // 仅检查描述对象，不创建 tap 或触发本机权限。
        let description = AudioPermissionProbe.tapDescription()
        #expect(description.isPrivate)
        #expect(description.muteBehavior == .unmuted)
        #expect(description.processes.isEmpty)
        #expect(description.isExclusive)
    }

    @Test @MainActor func permissionAggregateHasNoPhysicalPlaybackDevice() {
        let description = AudioPermissionProbe.tapDescription()
        let aggregate = AudioPermissionProbe.aggregateDescription(tapUUID: description.uuid)
        #expect(aggregate[kAudioAggregateDeviceIsPrivateKey] as? Bool == true)
        #expect(aggregate[kAudioAggregateDeviceSubDeviceListKey] == nil)
        #expect(aggregate[kAudioAggregateDeviceMainSubDeviceKey] == nil)
        let taps = aggregate[kAudioAggregateDeviceTapListKey] as? [[String: Any]]
        #expect(taps?.count == 1)
        #expect(taps?.first?[kAudioSubTapUIDKey] as? String == description.uuid.uuidString)
    }

    @Test @MainActor func unusedProbeCanBeClosedWithoutRequestingAnything() throws {
        let probe = AudioPermissionProbe()
        #expect(probe.isReleased)
        try probe.stop()
        #expect(probe.isReleased)
    }
}
