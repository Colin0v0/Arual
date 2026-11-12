import Testing
@testable import AuralCore

struct SystemAudioCaptureAccessTests {
    @Test func audioOnlyOrScreenCaptureGrantIsAccepted() {
        #expect(SystemAudioCaptureAccess.resolve(audio: 0, screen: 1) == .authorized)
        #expect(SystemAudioCaptureAccess.resolve(audio: 1, screen: 0) == .authorized)
        #expect(SystemAudioCaptureAccess.resolve(audio: 2, screen: 0) == .authorized)
    }

    @Test func explicitAudioDenialIsNotHiddenByUndeterminedScreenAccess() {
        #expect(SystemAudioCaptureAccess.resolve(audio: 1, screen: 1) == .denied)
        #expect(SystemAudioCaptureAccess.resolve(audio: 1, screen: 2) == .denied)
    }

    @Test func unknownStatusIsNotPermissionDenialOrAuthorization() {
        #expect(SystemAudioCaptureAccess.resolve(audio: 2, screen: 2) == .notDetermined)
        #expect(SystemAudioCaptureAccess.resolve(audio: -1, screen: 1) == .unavailable)
        #expect(SystemAudioCaptureAccess.resolve(audio: 99, screen: 99) == .unavailable)
    }

    @Test func missingQueryIsExplicitlyUnavailable() {
        #expect(SystemAudioCaptureAccess.resolve(audio: nil, screen: nil) == .unavailable)
        for access: SystemAudioCaptureAccess in [.denied, .notDetermined, .unavailable] {
            #expect(!access.allowsApplicationAudio)
        }
        #expect(SystemAudioCaptureAccess.authorized.allowsApplicationAudio)
    }
}
