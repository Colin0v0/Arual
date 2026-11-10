import Testing
@testable import AuralCore

struct AudioProcessesTests {
    @Test func vanishedProcessObjectIsSkippedAfterTheObjectListChanges() throws {
        var checks = 0
        let records = try AudioProcesses.readRecords(
            objectIDs: [100, 101],
            readPID: { object in
                if object == 101 { throw AudioFailure("进程已退出", status: HAL.badObjectStatus) }
                return 10
            },
            readRunningOutput: { _ in 1 },
            readBundleID: { object in "test.process.\(object)" },
            currentObjectIDs: {
                checks += 1
                // 旧进程对象在第二次核对前已经从 HAL 列表中消失，不能再让整份快照读取失败。
                return checks == 1 ? [100, 101] : [100]
            }
        )

        #expect(checks == 2)
        #expect(records.map(\.objectID) == [100])
        #expect(records.first?.bundleID == "test.process.100")
    }

    @Test func transientPropertyFailureRetriesTheSameLivingProcessOnce() throws {
        var pidReads = 0
        let records = try AudioProcesses.readRecords(
            objectIDs: [100],
            readPID: { _ in
                pidReads += 1
                if pidReads == 1 { throw AudioFailure("进程正在重建") }
                return 10
            },
            readRunningOutput: { _ in 0 },
            readBundleID: { _ in "test.process" },
            currentObjectIDs: { [100] }
        )

        #expect(pidReads == 2)
        #expect(records.map(\.objectID) == [100])
    }

    @Test func activeOutputsComeFromPlayingProcessesAndIgnoreVanishedObjects() throws {
        let devices = try AudioProcesses.readActiveOutputDeviceIDs(
            objectIDs: [100, 101, 102, 103],
            readPID: { object in
                if object == 102 { throw AudioFailure("进程已退出", status: HAL.badObjectStatus) }
                return 10
            },
            readRunningOutput: { object in object == 101 ? 0 : 1 },
            readDevices: { object in
                switch object {
                case 100: return [7, 8]
                case 103: return [8]
                default: return []
                }
            },
            currentObjectIDs: { [100, 101, 103] }
        )

        #expect(devices == [7, 8])
    }
}
