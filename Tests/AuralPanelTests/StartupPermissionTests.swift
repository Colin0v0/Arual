import Foundation
import Testing
import AuralCore
@testable import Aural

struct StartupPermissionTests {
    @Test @MainActor func firstLaunchRequestsSystemAudioDirectlyAndGrantedRelaunchDoesNotRepeat() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var access: SystemAudioCaptureAccess = .notDetermined
        var events: [String] = []
        let sequence = StartupPermissionSequence(defaults: defaults,
                                                requestBluetooth: { events.append("bluetooth"); return true },
                                                audioAccess: { access },
                                                requestAudio: { events.append("audio"); return true }, audioIsReleased: { true })
        let result = await sequence.run()
        #expect(result.errors.isEmpty && result.canEnterMainInterface)
        #expect(events == ["bluetooth", "audio"])
        #expect(result.didRequestAudio)
        #expect(result.grantedAudioDuringRequest)
        // 系统申请成功发出不等于用户已同意；授权事实由用户决定后从系统重新读取。
        #expect(access == .notDetermined)
        access = .authorized
        let nextLaunch = StartupPermissionSequence(defaults: defaults,
                                                  requestBluetooth: { events.append("unexpected-bluetooth"); return true },
                                                  audioAccess: { access },
                                                  requestAudio: { events.append("unexpected-audio"); return false }, audioIsReleased: { true })
        let nextResult = await nextLaunch.run()
        #expect(events == ["bluetooth", "audio"])
        #expect(!nextResult.didRequestAudio)
        #expect(!nextResult.grantedAudioDuringRequest)
    }

    @Test @MainActor func unavailableBluetoothDoesNotBlockAudioOrPretendItWasDetermined() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var audioRequests = 0
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { false },
                                                audioAccess: { .notDetermined },
                                                requestAudio: { audioRequests += 1; return false }, audioIsReleased: { true })
        _ = await sequence.run()
        #expect(!defaults.bool(forKey: StartupPermissionSequence.bluetoothKey))
        #expect(audioRequests == 1)
    }

    @Test @MainActor func audioFailureIsReportedWithoutPretendingAuthorization() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { true },
                                                audioAccess: { .notDetermined }, requestAudio: {
            requests += 1
            throw AudioFailure("测试申请失败")
        }, audioIsReleased: { true })
        let result = await sequence.run()
        #expect(result.errors == ["测试申请失败"])
        #expect(!result.canEnterMainInterface)
        #expect(requests == 1)
    }

    @Test @MainActor func quittingDuringBluetoothDoesNotQueryOrRequestAudio() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var audioRequests = 0
        var audioChecks = 0
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: {
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        }, audioAccess: { audioChecks += 1; return .notDetermined },
           requestAudio: { audioRequests += 1; return false }, audioIsReleased: { true })
        let task = Task { @MainActor in await sequence.run() }
        _ = await task.value
        #expect(audioRequests == 0 && audioChecks == 0)
        #expect(!defaults.bool(forKey: StartupPermissionSequence.bluetoothKey))
    }

    @Test @MainActor func cleanupFailureBlocksNormalStartup() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { true },
                                                audioAccess: { .notDetermined },
                                                requestAudio: { throw AudioFailure("停止授权输入失败") },
                                                audioIsReleased: { false })
        let result = await sequence.run()
        #expect(!result.canEnterMainInterface)
        #expect(result.errors == ["停止授权输入失败"])
    }

    @Test @MainActor func legacyRequestMarkerCannotSuppressARequiredSystemPrompt() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        // 旧构建遗留的标记不能替代当前包身份的 TCC 授权，也不能阻断重新申请。
        defaults.set(true, forKey: "Aural.StartupPermissions.AudioRequested.v1")
        var requests = 0
        for _ in 0..<2 {
            let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { true },
                                                    audioAccess: { .notDetermined },
                                                    requestAudio: { requests += 1; return false }, audioIsReleased: { true })
            let result = await sequence.run()
            #expect(result.errors.isEmpty && !result.canEnterMainInterface)
        }
        #expect(requests == 2)
    }

    @Test @MainActor func onlyAuthorizedStartupCanEnterTheMainInterface() async {
        for access: SystemAudioCaptureAccess in [.authorized, .denied, .unavailable] {
            let name = "Aural.StartupTests.\(UUID())"
            let defaults = UserDefaults(suiteName: name)!
            defer { defaults.removePersistentDomain(forName: name) }
            var requests = 0
            let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { true },
                                                    audioAccess: { access }, requestAudio: { requests += 1; return false },
                                                    audioIsReleased: { true })
            let result = await sequence.run()
            #expect(requests == (access == .denied ? 1 : 0))
            #expect(result.canEnterMainInterface == (access == .authorized))
            if access == .denied {
                #expect(result.audioPermissionDenied)
                #expect(result.errors.isEmpty)
            } else {
                #expect(!result.audioPermissionDenied)
            }
        }
    }

    @Test @MainActor func refusingTheSystemPromptIsReportedForTheCustomPermissionAlert() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { true },
                                                audioAccess: { .notDetermined },
                                                requestAudio: { requests += 1; return false }, audioIsReleased: { true })
        let result = await sequence.run()
        #expect(!result.canEnterMainInterface && !result.grantedAudioDuringRequest)
        #expect(result.audioPermissionDenied)
        #expect(result.errors.isEmpty)
        #expect(requests == 1)
    }

    @Test @MainActor func resetAuthorizationIsRequestedOnTheNextLaunch() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var access: SystemAudioCaptureAccess = .authorized
        var requests = 0
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { true },
                                                audioAccess: { access }, requestAudio: { requests += 1; return false },
                                                audioIsReleased: { true })
        _ = await sequence.run()
        #expect(requests == 0)
        access = .notDetermined
        _ = await sequence.run()
        #expect(requests == 1)
    }

    @Test func mandatoryPurposeStringsStayMinimalAndNonempty() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["NSAudioCaptureUsageDescription"] as? String == "用于调节应用音量、应用独立输出路由与应用音效。")
        #expect(plist["NSBluetoothAlwaysUsageDescription"] as? String == "用于控制蓝牙耳机。")
    }
}
