import Foundation
import Testing
@testable import AuralCore

struct AppAudioRouteTests {
    @Test func codableRoundTripUsesStableSortedDeviceUIDs() throws {
        let route = AppAudioRoute.custom(deviceUIDs: ["speaker.b", "speaker.a"])
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(route)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["kind"] as? String == "custom")
        #expect(object["deviceUIDs"] as? [String] == ["speaker.a", "speaker.b"])

        let decoded = try JSONDecoder().decode(AppAudioRoute.self, from: data)
        #expect(decoded == route)
        #expect(try JSONDecoder().decode(AppAudioRoute.self,
                                         from: JSONEncoder().encode(AppAudioRoute.allOutputs)) == .allOutputs)
    }

    @Test func allOutputsContinuesToFollowTheCurrentGroup() {
        let before = AppAudioRouteResolver.resolve(
            stored: .allOutputs,
            configuredDeviceUIDs: ["speaker", "headphone"],
            activeDeviceUIDs: ["speaker", "headphone"]
        )
        let after = AppAudioRouteResolver.resolve(
            stored: before.persisted,
            configuredDeviceUIDs: ["speaker", "headphone", "usb"],
            activeDeviceUIDs: ["speaker", "headphone", "usb"]
        )
        #expect(before.persisted == .allOutputs)
        #expect(before.effective == .allOutputs)
        #expect(after.persisted == .allOutputs)
        #expect(after.effective == .allOutputs)
    }

    @Test func customRouteDoesNotAutomaticallyIncludeAnAddedDevice() {
        let result = AppAudioRouteResolver.resolve(
            stored: .custom(deviceUIDs: ["speaker"]),
            configuredDeviceUIDs: ["speaker", "headphone", "usb"],
            activeDeviceUIDs: ["speaker", "headphone", "usb"]
        )
        #expect(result.persisted == .custom(deviceUIDs: ["speaker"]))
        #expect(result.effective == .custom(deviceUIDs: ["speaker"]))
    }

    @Test func customRoutePrunesOnlyDevicesRemovedFromTheGroup() {
        let result = AppAudioRouteResolver.resolve(
            stored: .custom(deviceUIDs: ["speaker", "headphone", "usb"]),
            configuredDeviceUIDs: ["headphone", "usb"],
            activeDeviceUIDs: ["headphone", "usb"]
        )
        #expect(result.persisted == .custom(deviceUIDs: ["headphone", "usb"]))
        #expect(result.effective == .custom(deviceUIDs: ["headphone", "usb"]))
    }

    @Test func temporarilyUnavailableUIDStaysSavedAndRestoresAfterReconnect() {
        let disconnected = AppAudioRouteResolver.resolve(
            stored: .custom(deviceUIDs: ["headphone"]),
            configuredDeviceUIDs: ["speaker", "headphone"],
            activeDeviceUIDs: ["speaker"]
        )
        #expect(disconnected.persisted == .custom(deviceUIDs: ["headphone"]))
        #expect(disconnected.effective == .allOutputs)
        #expect(disconnected.unavailableDeviceUIDs == ["headphone"])

        let reconnected = AppAudioRouteResolver.resolve(
            stored: disconnected.persisted,
            configuredDeviceUIDs: ["speaker", "headphone"],
            activeDeviceUIDs: ["speaker", "headphone"]
        )
        #expect(reconnected.persisted == .custom(deviceUIDs: ["headphone"]))
        #expect(reconnected.effective == .custom(deviceUIDs: ["headphone"]))
        #expect(reconnected.unavailableDeviceUIDs.isEmpty)
    }

    @Test func customRouteWithNoEffectiveDeviceUsesAllOutputsWithoutLosingIntent() {
        let result = AppAudioRouteResolver.resolve(
            stored: .custom(deviceUIDs: ["headphone", "usb"]),
            configuredDeviceUIDs: ["speaker", "headphone", "usb"],
            activeDeviceUIDs: ["speaker"]
        )
        #expect(result.persisted == .custom(deviceUIDs: ["headphone", "usb"]))
        #expect(result.effective == .allOutputs)
        #expect(result.unavailableDeviceUIDs == ["headphone", "usb"])
    }

    @Test func selectingEveryCurrentDeviceStillRemainsAnExplicitCustomRoute() {
        let result = AppAudioRouteResolver.resolve(
            stored: .custom(deviceUIDs: ["speaker", "headphone"]),
            configuredDeviceUIDs: ["speaker", "headphone", "usb"],
            activeDeviceUIDs: ["speaker", "headphone"]
        )
        #expect(result.persisted == .custom(deviceUIDs: ["speaker", "headphone"]))
        #expect(result.effective == .custom(deviceUIDs: ["speaker", "headphone"]))
    }
}
