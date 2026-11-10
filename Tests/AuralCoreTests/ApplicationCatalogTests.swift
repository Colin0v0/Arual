import Foundation
import Testing
@testable import AuralCore

struct ApplicationCatalogTests {
    // 以下均为合成身份，仅用于验证归属规则，不是用户机器的检测结果。
    private let browser = RunningApplicationInfo(processID: 10, bundleID: "test.browser", name: "测试浏览器",
                                                  bundleURL: URL(fileURLWithPath: "/Applications/Browser.app"))

    @Test func idleRegisteredApplicationsAreNotFilteredOut() {
        let process = AudioProcessRecord(objectID: 100, processID: 10, bundleID: "test.browser", isRunningOutput: false)
        let rows = ApplicationCatalog.rows(applications: [browser], records: [process], executableURLs: [:])
        #expect(rows.count == 1)
        #expect(rows[0].group?.objectIDs == [100])
        #expect(!rows[0].isRunningOutput)
        #expect(rows[0].registrationLabel == "音频流空闲")
    }

    @Test func appWithoutHALObjectStillHasAnHonestRow() {
        let rows = ApplicationCatalog.rows(applications: [browser], records: [], executableURLs: [:])
        #expect(rows.count == 1)
        #expect(rows[0].group == nil)
        #expect(rows[0].registrationLabel == "等待应用创建音频流")
    }

    @Test func helperOwnershipRequiresRealBundleContainment() {
        let records = [AudioProcessRecord(objectID: 100, processID: 10, bundleID: "test.browser", isRunningOutput: false),
                       AudioProcessRecord(objectID: 101, processID: 11, bundleID: "test.browser.helper", isRunningOutput: true)]
        let executables = [Int32(11): URL(fileURLWithPath: "/Applications/Browser.app/Contents/Frameworks/Helper.app/Contents/MacOS/Helper")]
        let rows = ApplicationCatalog.rows(applications: [browser], records: records, executableURLs: executables)
        #expect(rows.count == 1)
        #expect(rows[0].group?.objectIDs == [100, 101])
        #expect(rows[0].isRunningOutput)
    }

    @Test func bundlePrefixIsNotOwnershipEvidence() {
        let record = AudioProcessRecord(objectID: 101, processID: 11, bundleID: "test.browser.helper", isRunningOutput: true)
        let rows = ApplicationCatalog.rows(applications: [browser], records: [record], executableURLs: [:], processNames: [11: "BrowserHelper"])
        #expect(rows.count == 2)
        #expect(rows.first { $0.id == "bundle:test.browser" }?.group == nil)
        #expect(rows.first { $0.id == "unassigned:bundle:test.browser.helper" }?.group?.objectIDs == [101])
    }

    @Test func pathPrefixDoesNotMatchSiblingApplication() {
        let record = AudioProcessRecord(objectID: 101, processID: 11, bundleID: "unknown", isRunningOutput: true)
        let rows = ApplicationCatalog.rows(applications: [browser], records: [record],
                                            executableURLs: [11: URL(fileURLWithPath: "/Applications/Browser.app.other/Contents/MacOS/Other")], processNames: [11: "Other"])
        #expect(rows.count == 2)
        #expect(rows.first { $0.id == "bundle:test.browser" }?.group == nil)
    }

    @Test func ambiguousNestedAppsAreNotMerged() {
        let nested = RunningApplicationInfo(processID: 12, bundleID: "test.child", name: "子应用",
                                            bundleURL: URL(fileURLWithPath: "/Applications/Browser.app/Contents/Child.app"))
        let record = AudioProcessRecord(objectID: 101, processID: 11, bundleID: "test.child", isRunningOutput: true)
        let rows = ApplicationCatalog.rows(applications: [browser, nested], records: [record],
                                            executableURLs: [11: URL(fileURLWithPath: "/Applications/Browser.app/Contents/Child.app/Contents/MacOS/Child")], processNames: [11: "Child"])
        #expect(rows.count == 3)
        #expect(rows.filter { $0.group != nil }.count == 1)
        #expect(rows.first { $0.group != nil }?.id.hasPrefix("unassigned:") == true)
    }

    @Test func inactiveUnownedDaemonsDoNotFloodTheList() {
        let record = AudioProcessRecord(objectID: 101, processID: 11, bundleID: "test.daemon", isRunningOutput: false)
        #expect(ApplicationCatalog.rows(applications: [browser], records: [record], executableURLs: [:]).count == 1)
    }
}

struct RetainedAudioSourceTests {
    @Test func managedUnassignedSourceStaysVisibleWhenIdle() {
        let record = AudioProcessRecord(objectID: 101, processID: 11, bundleID: "test.daemon", isRunningOutput: false)
        let rows = ApplicationCatalog.rows(applications: [], records: [record], executableURLs: [:],
                                            retainedIDs: ["unassigned:bundle:test.daemon"], processNames: [11: "AudioSource"])
        #expect(rows.count == 1)
        #expect(rows[0].group?.objectIDs == [101])
        #expect(!rows[0].isRunningOutput)
    }
}
