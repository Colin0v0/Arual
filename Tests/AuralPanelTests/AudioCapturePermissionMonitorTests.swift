import Foundation
import Combine
import Testing
import AuralCore
@testable import Aural

@MainActor
struct AudioCapturePermissionMonitorTests {
    @Test func authorizedStateDoesNotRequestOrRestart() {
        let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.authorized)
        var requests = 0, restarts = 0, quits = 0
        let monitor = AudioCapturePermissionMonitor(
            access: access.eraseToAnyPublisher(), currentAccess: { access.value },
            requestDecision: { requests += 1; $0(.authorized) },
            restartAfterGrant: { restarts += 1 }, quitWithoutPermission: { quits += 1 })
        flush()
        access.send(.authorized)
        flush()
        #expect(requests == 0 && restarts == 0 && quits == 0)
        withExtendedLifetime(monitor) {}
    }

    @Test func explicitSystemRefusalQuitsWithoutASecondDialogOrRepeatedRequests() {
        let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.denied)
        var requests = 0, restarts = 0, quits = 0
        let monitor = AudioCapturePermissionMonitor(
            access: access.eraseToAnyPublisher(), currentAccess: { access.value },
            requestDecision: { requests += 1; $0(.denied) },
            restartAfterGrant: { restarts += 1 }, quitWithoutPermission: { quits += 1 })
        flush()
        for _ in 0..<4 { access.send(.denied); flush() }
        #expect(requests == 1 && restarts == 0 && quits == 1)
        withExtendedLifetime(monitor) {}
    }

    @Test func cachedUndeterminedValueCannotOverrideTheSystemGrantCallback() {
        let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.notDetermined)
        var restarts = 0, quits = 0
        let monitor = AudioCapturePermissionMonitor(
            access: access.eraseToAnyPublisher(), currentAccess: { access.value },
            requestDecision: { $0(.authorized) }, restartAfterGrant: { restarts += 1 },
            quitWithoutPermission: { quits += 1 })
        flush()
        access.send(.notDetermined)
        flush()
        #expect(restarts == 1 && quits == 0)
        withExtendedLifetime(monitor) {}
    }

    @Test func noConcurrentRequestsWhileTheSystemDialogIsPending() {
        let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.notDetermined)
        var requests = 0, quits = 0
        var finish: ((SystemAudioCaptureAccess) -> Void)?
        let monitor = AudioCapturePermissionMonitor(
            access: access.eraseToAnyPublisher(), currentAccess: { access.value },
            requestDecision: { requests += 1; finish = $0 }, restartAfterGrant: {},
            quitWithoutPermission: { quits += 1 })
        flush()
        access.send(.notDetermined)
        flush()
        #expect(requests == 1 && quits == 0)
        finish?(.denied)
        finish?(.authorized)
        #expect(quits == 1)
        withExtendedLifetime(monitor) {}
    }

    @Test func unavailablePermissionStateDoesNotOpenAnUnusableInterface() {
        let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.unavailable)
        var requests = 0, quits = 0
        let monitor = AudioCapturePermissionMonitor(
            access: access.eraseToAnyPublisher(), currentAccess: { access.value },
            requestDecision: { requests += 1; $0(.authorized) }, restartAfterGrant: {},
            quitWithoutPermission: { quits += 1 })
        flush()
        #expect(requests == 0 && quits == 1)
        withExtendedLifetime(monitor) {}
    }

    @Test func obsoleteQueuedDenialIsIgnoredAfterAuthorization() {
        let access = CurrentValueSubject<SystemAudioCaptureAccess, Never>(.denied)
        var requests = 0, quits = 0
        let monitor = AudioCapturePermissionMonitor(
            access: access.eraseToAnyPublisher(), currentAccess: { access.value },
            requestDecision: { requests += 1; $0(.denied) }, restartAfterGrant: {},
            quitWithoutPermission: { quits += 1 })
        access.send(.authorized)
        flush()
        #expect(requests == 0 && quits == 0)
        withExtendedLifetime(monitor) {}
    }

    private func flush() { RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.02)) }
}
