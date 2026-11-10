import Foundation
import Testing
import AuralCore
@testable import Aural

struct StartupPermissionTests {
    @Test @MainActor func firstLaunchRequestsBluetoothThenAudioOnlyOnce() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var events: [String] = []
        let sequence = StartupPermissionSequence(defaults: defaults,
                                                requestBluetooth: { events.append("bluetooth"); return true },
                                                requestAudio: { events.append("audio") }, audioIsReleased: { true })
        let errors = await sequence.run()
        #expect(errors.errors.isEmpty)
        #expect(errors.canEnterMainInterface)
        #expect(events == ["bluetooth", "audio"])
        let nextLaunch = StartupPermissionSequence(defaults: defaults,
                                                  requestBluetooth: { events.append("unexpected-bluetooth"); return true },
                                                  requestAudio: { events.append("unexpected-audio") }, audioIsReleased: { true })
        _ = await nextLaunch.run()
        #expect(events == ["bluetooth", "audio"])
    }

    @Test @MainActor func unavailableBluetoothDoesNotBlockAudioOrPretendItWasDetermined() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var audioRequests = 0
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { false },
                                                requestAudio: { audioRequests += 1 }, audioIsReleased: { true })
        _ = await sequence.run()
        #expect(!defaults.bool(forKey: StartupPermissionSequence.bluetoothKey))
        #expect(defaults.bool(forKey: StartupPermissionSequence.audioKey))
        #expect(audioRequests == 1)
    }

    @Test @MainActor func audioFailureIsReportedAndNotMarkedAsCompleted() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var requests = 0
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { true }, requestAudio: {
            requests += 1
            throw AudioFailure("测试申请失败")
        }, audioIsReleased: { true })
        let errors = await sequence.run()
        #expect(errors.errors == ["测试申请失败"])
        #expect(errors.canEnterMainInterface)
        #expect(!defaults.bool(forKey: StartupPermissionSequence.audioKey))
        #expect(requests == 1)
    }

    @Test @MainActor func quittingDuringBluetoothDoesNotStartAudioOrCompleteFlags() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        var audioRequested = false
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: {
            withUnsafeCurrentTask { $0?.cancel() }
            return true
        }, requestAudio: { audioRequested = true }, audioIsReleased: { true })
        let task = Task { @MainActor in await sequence.run() }
        _ = await task.value
        #expect(!audioRequested)
        #expect(!defaults.bool(forKey: StartupPermissionSequence.bluetoothKey))
        #expect(!defaults.bool(forKey: StartupPermissionSequence.audioKey))
    }

    @Test @MainActor func cleanupFailureBlocksNormalStartupAndDoesNotCompleteAudioFlag() async {
        let name = "Aural.StartupTests.\(UUID())"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let sequence = StartupPermissionSequence(defaults: defaults, requestBluetooth: { true },
                                                requestAudio: { throw AudioFailure("停止授权输入失败") },
                                                audioIsReleased: { false })
        let result = await sequence.run()
        #expect(!result.canEnterMainInterface)
        #expect(result.errors == ["停止授权输入失败"])
        #expect(!defaults.bool(forKey: StartupPermissionSequence.audioKey))
    }

    @Test func mandatoryPurposeStringsStayMinimalAndNonempty() throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let data = try Data(contentsOf: root.appendingPathComponent("Resources/Info.plist"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["NSAudioCaptureUsageDescription"] as? String == "用于调节应用音量。")
        #expect(plist["NSBluetoothAlwaysUsageDescription"] as? String == "用于控制蓝牙耳机。")
    }
}
