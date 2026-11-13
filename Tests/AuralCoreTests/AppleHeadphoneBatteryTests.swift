import Foundation
import Testing
@testable import AuralCore

struct AppleHeadphoneBatteryTests {
    @Test func connectedBatteriesUseAddressesAndIgnoreOfflineReadings() throws {
        let data = Data(#"""
        {"SPBluetoothDataType":[{
          "device_connected":[
            {"Same Name":{"device_address":"AA-BB-CC-DD-EE-01","device_batteryLevelLeft":"97%","device_batteryLevelRight":"90%","device_batteryLevelCase":"89%"}},
            {"Same Name":{"device_address":"AA:BB:CC:DD:EE:02","device_batteryLevelRight":"60%"}}
          ],
          "device_not_connected":[{"Old":{"device_address":"AA-BB-CC-DD-EE-01","device_batteryLevelLeft":"100%"}}]
        }]}
        """#.utf8)
        let values = try AppleHeadphoneBatteryStore.parse(data)
        #expect(values.count == 2)
        #expect(values["AABBCCDDEE01"] == AppleHeadphoneBattery(left: 97, right: 90, caseLevel: 89))
        #expect(values["AABBCCDDEE01"]?.earbudLevel == 90)
        #expect(values["AABBCCDDEE02"] == AppleHeadphoneBattery(right: 60))
        #expect(values["AABBCCDDEE02"]?.earbudLevel == 60)
    }

    @Test func caseOnlyDoesNotInventEarbudBattery() throws {
        let data = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"Pods":{"device_address":"AA-BB-CC-DD-EE-01","device_batteryLevelCase":"30%"}}]}]}"#.utf8)
        let reading = try AppleHeadphoneBatteryStore.parse(data)["AABBCCDDEE01"]
        #expect(reading == AppleHeadphoneBattery(caseLevel: 30))
        #expect(reading?.earbudLevel == nil)
    }

    @Test func malformedPercentAndDuplicateIdentitiesFailExplicitly() {
        let bad = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"Pods":{"device_address":"AA-BB-CC-DD-EE-01","device_batteryLevelLeft":"101%"}}]}]}"#.utf8)
        #expect(throws: AudioFailure.self) { try AppleHeadphoneBatteryStore.parse(bad) }
        let duplicate = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"A":{"device_address":"AA-BB-CC-DD-EE-01","device_batteryLevelLeft":"10%"}},{"B":{"device_address":"AA-BB-CC-DD-EE-01","device_batteryLevelRight":"20%"}}]}]}"#.utf8)
        #expect(throws: AudioFailure.self) { try AppleHeadphoneBatteryStore.parse(duplicate) }
    }

    @Test func missingReadingsRemainUnknown() throws {
        let data = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"Pods":{"device_address":"AA-BB-CC-DD-EE-01"}}]}]}"#.utf8)
        #expect(try AppleHeadphoneBatteryStore.parse(data).isEmpty)
    }

    @Test func mainBatterySupportsHeadphonesWithoutInventingEarbudParts() throws {
        let data = Data(#"{"SPBluetoothDataType":[{"device_connected":[{"AirPods Max":{"device_address":"AA-BB-CC-DD-EE-01","device_batteryLevelMain":"82%"}}]}]}"#.utf8)
        let reading = try AppleHeadphoneBatteryStore.parse(data)["AABBCCDDEE01"]
        #expect(reading == AppleHeadphoneBattery(main: 82))
        #expect(reading?.left == nil)
        #expect(reading?.right == nil)
        #expect(reading?.caseLevel == nil)
    }
}
