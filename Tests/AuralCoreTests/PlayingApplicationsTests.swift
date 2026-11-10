import Foundation
import Testing
@testable import AuralCore

struct PlayingApplicationsTests {
    private let app = RunningApplicationInfo(processID: 10, bundleID: "test.player", name: "测试播放器", bundleURL: nil)

    @Test func merelyRunningAppIsHidden() {
        let catalog = ApplicationCatalog.rows(applications: [app], records: [], executableURLs: [:])
        #expect(catalog.count == 1)
        #expect(ApplicationCatalog.playingRows(from: catalog).isEmpty)
    }

    @Test func registeredButIdleAppIsHidden() {
        let record = AudioProcessRecord(objectID: 100, processID: 10, bundleID: "test.player", isRunningOutput: false)
        let catalog = ApplicationCatalog.rows(applications: [app], records: [record], executableURLs: [:])
        #expect(catalog[0].group?.objectIDs == [100])
        #expect(ApplicationCatalog.playingRows(from: catalog).isEmpty)
    }

    @Test func playingAppIsVisible() {
        let record = AudioProcessRecord(objectID: 100, processID: 10, bundleID: "test.player", isRunningOutput: true)
        let catalog = ApplicationCatalog.rows(applications: [app], records: [record], executableURLs: [:])
        #expect(ApplicationCatalog.playingRows(from: catalog).map(\.id) == ["bundle:test.player"])
    }

    @Test func activeHelperMakesItsOwnerVisible() {
        let browser = RunningApplicationInfo(processID: 10, bundleID: "test.browser", name: "浏览器",
                                              bundleURL: URL(fileURLWithPath: "/Applications/Browser.app"))
        let record = AudioProcessRecord(objectID: 101, processID: 11, bundleID: "test.browser.helper", isRunningOutput: true)
        let catalog = ApplicationCatalog.rows(applications: [browser], records: [record],
                                              executableURLs: [11: URL(fileURLWithPath: "/Applications/Browser.app/Contents/Helper")])
        #expect(ApplicationCatalog.playingRows(from: catalog).map(\.id) == ["bundle:test.browser"])
    }

    @Test func retainedIdleSourceIsOnlyKeptInBackendCatalog() {
        let record = AudioProcessRecord(objectID: 100, processID: 10, bundleID: "test.source", isRunningOutput: false)
        let catalog = ApplicationCatalog.rows(applications: [], records: [record], executableURLs: [:],
                                              retainedIDs: ["unassigned:bundle:test.source"], processNames: [10: "AudioSource"])
        #expect(catalog.count == 1)
        #expect(ApplicationCatalog.playingRows(from: catalog).isEmpty)
        // 展示过滤不能删除生命周期管理所需的成员。
        #expect(catalog[0].group?.objectIDs == [100])
    }

    @Test func pauseAndResumeOnlyChangeVisibility() throws {
        var state = ApplicationMixState()
        try state.setGain(0.35)
        state.toggleMute()
        state.enable(outputUID: "test-output")
        for playing in [true, false, true] {
            let record = AudioProcessRecord(objectID: 100, processID: 10, bundleID: "test.player", isRunningOutput: playing)
            let catalog = ApplicationCatalog.rows(applications: [app], records: [record], executableURLs: [:])
            #expect(ApplicationCatalog.playingRows(from: catalog).count == (playing ? 1 : 0))
            #expect(state.action(group: catalog[0].group, sessionObjectIDs: [100]) == .keep)
            #expect(state.gain == 0.35 && state.muted)
        }
    }
}
