import Foundation
import Darwin
import Testing
@testable import AuralCore

struct ProcessOwnershipTests {
    private let chrome = RunningApplicationInfo(processID: 10, bundleID: "com.google.Chrome", name: "Google Chrome",
                                                bundleURL: URL(fileURLWithPath: "/Applications/Google Chrome.app"))

    @Test func nonAppKitHelperIsMergedByVerifiedParentGraph() {
        let helper = AudioProcessRecord(objectID: 101, processID: 12, bundleID: "com.google.Chrome.helper", isRunningOutput: true)
        let rows = ApplicationCatalog.rows(applications: [chrome], records: [helper], executableURLs: [:],
                                            parentPIDs: [12: 11, 11: 10, 10: 1], processNames: [12: "Chrome Helper"])
        let playing = ApplicationCatalog.playingRows(from: rows)
        #expect(playing.count == 1)
        #expect(playing[0].label == "Google Chrome")
        #expect(playing[0].applicationURL == chrome.bundleURL)
        #expect(playing[0].group?.objectIDs == [101])
    }

    @Test func executablePathAndParentEvidenceMergeIntoOneHost() {
        let records = [AudioProcessRecord(objectID: 100, processID: 10, bundleID: "com.google.Chrome", isRunningOutput: false),
                       AudioProcessRecord(objectID: 101, processID: 12, bundleID: "com.google.Chrome.helper", isRunningOutput: true)]
        let rows = ApplicationCatalog.rows(applications: [chrome], records: records,
                                            executableURLs: [12: URL(fileURLWithPath: "/Applications/Google Chrome.app/Contents/Helper")],
                                            parentPIDs: [12: 10], processNames: [12: "Chrome Helper"])
        #expect(rows.count == 1)
        #expect(rows[0].group?.objectIDs == [100, 101])
    }

    @Test func mixersAndTheirHelpersNeverBecomeAudioSources() {
        let mixer = RunningApplicationInfo(processID: 20, bundleID: "com.finetuneapp.FineTune", name: "FineTune",
                                           bundleURL: URL(fileURLWithPath: "/Applications/FineTune.app"))
        let records = [AudioProcessRecord(objectID: 100, processID: 20, bundleID: "com.finetuneapp.FineTune", isRunningOutput: true),
                       AudioProcessRecord(objectID: 101, processID: 21, bundleID: "some.helper", isRunningOutput: true),
                       AudioProcessRecord(objectID: 102, processID: 22, bundleID: "local.aural.app", isRunningOutput: true)]
        let rows = ApplicationCatalog.rows(applications: [mixer, chrome], records: records, executableURLs: [:],
                                            parentPIDs: [21: 20], processNames: [21: "MixerHelper"])
        #expect(ApplicationCatalog.playingRows(from: rows).isEmpty)
        #expect(!rows.contains { $0.bundleID == mixer.bundleID })
    }

    @Test func systemSoundAndAudioDaemonsAreNotApps() {
        let records = [AudioProcessRecord(objectID: 100, processID: 20, bundleID: "systemsoundserverd", isRunningOutput: true),
                       AudioProcessRecord(objectID: 101, processID: 21, bundleID: "", isRunningOutput: true)]
        let rows = ApplicationCatalog.rows(applications: [chrome], records: records, executableURLs: [:],
                                            processNames: [20: "systemsoundserverd", 21: "coreaudiod"])
        #expect(ApplicationCatalog.playingRows(from: rows).isEmpty)
    }

    @Test func realAppleApplicationsAreNotBlanketFiltered() {
        let music = RunningApplicationInfo(processID: 20, bundleID: "com.apple.Music", name: "音乐", bundleURL: nil)
        let record = AudioProcessRecord(objectID: 100, processID: 20, bundleID: "com.apple.Music", isRunningOutput: true)
        let rows = ApplicationCatalog.rows(applications: [music], records: [record], executableURLs: [:])
        #expect(ApplicationCatalog.playingRows(from: rows).first?.label == "音乐")
    }

    @Test func unknownSourceUsesAKernelNameNotAnOpaqueBundleID() {
        let record = AudioProcessRecord(objectID: 100, processID: 20, bundleID: "org.unknown.bundle", isRunningOutput: true)
        let rows = ApplicationCatalog.rows(applications: [], records: [record], executableURLs: [:], processNames: [20: "AudioPlayer"])
        #expect(rows.first?.label == "AudioPlayer")
        #expect(ApplicationCatalog.rows(applications: [], records: [record], executableURLs: [:]).isEmpty)
    }

    @Test func publicProcessInventoryReadsTheCurrentProcess() {
        let facts = ProcessInventory.capture(processIDs: [getpid()])
        #expect(facts.parentPIDs[getpid()] != nil)
        #expect(facts.executableURLs[getpid()] != nil)
        #expect(facts.names[getpid()]?.isEmpty == false)
    }
}
