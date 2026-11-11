import Foundation
import Testing
@testable import Aural

struct AuralUpdateCheckerTests {
    private let digest = "sha256:c55497f43fd177df00cd7dc8d4d0cb167b9ff65a6b73e8d40c752d48714339da"
    private let repository = "example/Aural"

    @Test func newestReleaseWinsRegardlessOfFeedOrderAndUsesArm64DMG() throws {
        let data = try atomFeed([release("0.1.9"), release("0.1.11"), release("0.1.10")])

        let update = try AuralUpdateChecker.newestUpdate(from: data, currentVersion: "0.1.10",
                                                          repository: repository)
        #expect(update?.version == "0.1.11")
        #expect(update?.pageURL.absoluteString == "https://example.com/0.1.11")
        #expect(update?.downloadURL.absoluteString
                == "https://github.com/example/Aural/releases/download/v0.1.11/Aural-0.1.11-macOS-arm64.dmg")
    }

    @Test func currentReleaseDoesNotTriggerUpdate() throws {
        let current = try atomFeed([release("0.1.10")])
        #expect(try AuralUpdateChecker.newestUpdate(from: current, currentVersion: "0.1.10",
                                                    repository: repository) == nil)
    }

    @Test func prereleaseStillCountsWhenItIsNewerThanInstalledBuild() throws {
        let data = try atomFeed([release("0.1.11-beta.1")])

        let update = try AuralUpdateChecker.newestUpdate(from: data, currentVersion: "0.1.10",
                                                          repository: repository)
        #expect(update?.version == "0.1.11-beta.1")
    }

    @Test func malformedFeedIsRejected() throws {
        let data = try #require("<feed><entry>".data(using: .utf8))
        #expect(throws: AuralUpdateError.self) {
            _ = try AuralUpdateChecker.newestUpdate(from: data, currentVersion: "0.1.10",
                                                    repository: repository)
        }
    }

    @Test func checksumFileUsesFirstDigestField() throws {
        #expect(try AuralUpdateChecker.parseChecksumFile(
            "c55497f43fd177df00cd7dc8d4d0cb167b9ff65a6b73e8d40c752d48714339da  Aural.dmg\n"
        ) == "c55497f43fd177df00cd7dc8d4d0cb167b9ff65a6b73e8d40c752d48714339da")
        #expect(throws: AuralUpdateError.self) {
            _ = try AuralUpdateChecker.parseChecksumFile("not-a-digest")
        }
    }

    @Test(arguments: [
        "bad",
        "md5:c55497f43fd177df00cd7dc8d4d0cb167b9ff65a6b73e8d40c752d48714339da",
        "sha256:not-a-hash"
    ])
    func malformedDigestIsRejected(value: String) {
        #expect(throws: AuralUpdateError.self) {
            _ = try AuralUpdateChecker.parseSHA256Digest(value)
        }
    }

    @Test func skippedVersionHidesOnlyThatVersion() throws {
        let currentData = try atomFeed([release("0.1.11")])
        let newerData = try atomFeed([release("0.1.12")])
        let currentUpdate = try #require(
            try AuralUpdateChecker.newestUpdate(from: currentData, currentVersion: "0.1.10",
                                                repository: repository)
        )
        let newerUpdate = try #require(
            try AuralUpdateChecker.newestUpdate(from: newerData, currentVersion: "0.1.10",
                                                repository: repository)
        )

        #expect(!AuralUpdateChecker.shouldPresent(update: currentUpdate, skippedVersion: "0.1.11"))
        #expect(AuralUpdateChecker.shouldPresent(update: newerUpdate, skippedVersion: "0.1.11"))
        #expect(AuralUpdateChecker.shouldPresent(update: currentUpdate, skippedVersion: nil))
    }

    @Test func sha256MatchesKnownFileContent() throws {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuralUpdateDigest-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: url) }
        try Data("abc".utf8).write(to: url)

        #expect(try AuralSHA256.hexDigest(at: url)
            == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    }

    @Test func installerRejectsWrongBundleIdentifier() throws {
        let bundle = try makeBundle(identifier: "example.invalid", version: "0.1.11", executable: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(throws: AuralUpdateError.self) {
            try AuralUpdateInstaller.validateBundle(at: bundle, expectedVersion: "0.1.11")
        }
    }

    @Test func installerRejectsWrongBundleVersion() throws {
        let bundle = try makeBundle(identifier: "local.aural.app", version: "0.1.10", executable: true)
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(throws: AuralUpdateError.self) {
            try AuralUpdateInstaller.validateBundle(at: bundle, expectedVersion: "0.1.11")
        }
    }

    @Test func installerRejectsBundleWithoutExecutable() throws {
        let bundle = try makeBundle(identifier: "local.aural.app", version: "0.1.11", executable: false)
        defer { try? FileManager.default.removeItem(at: bundle) }

        #expect(throws: AuralUpdateError.self) {
            try AuralUpdateInstaller.validateBundle(at: bundle, expectedVersion: "0.1.11")
        }
    }

    @Test func installerVerifiesDigestAndStagesSignedBundle() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuralUpdateStage-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let bundle = try makeBundle(identifier: "local.aural.app", version: "0.1.11", executable: true)
        defer { try? FileManager.default.removeItem(at: bundle) }
        try run("/usr/bin/codesign", ["--force", "--sign", "-", bundle.path])
        // 更新源现在必须是能挂载的 DMG；构造最小可挂载镜像，验证真实挂载、复制和签名流程。
        let source = root.appendingPathComponent("source", isDirectory: true)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: bundle, to: source.appendingPathComponent("Aural.app"))
        let archive = root.appendingPathComponent("Aural-0.1.11-macOS-arm64.dmg")
        try run("/usr/bin/hdiutil", ["create", "-quiet", "-srcfolder", source.path,
                                     "-volname", "Aural", "-fs", "HFS+", "-format", "UDRW",
                                     "-ov", archive.path])
        let size = try #require(
            (FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue
        )
        let update = AuralAvailableUpdate(
            version: "0.1.11",
            pageURL: URL(string: "https://example.com/0.1.11")!,
            downloadURL: URL(string: "https://example.com/update.dmg")!,
            sha256: try AuralSHA256.hexDigest(at: archive),
            archiveKind: .dmg
        )
        #expect(size > 0)
        let paths = AuralUpdateInstaller.Paths(
            stage: root.appendingPathComponent("stage"),
            archive: archive,
            extracted: root.appendingPathComponent("extracted"),
            payload: root.appendingPathComponent("payload"),
            oldBundle: root.appendingPathComponent("old")
        )
        try FileManager.default.createDirectory(at: paths.extracted, withIntermediateDirectories: true)

        try AuralUpdateInstaller.verifyAndPrepareDownloadedArchive(update: update, paths: paths)

        #expect(FileManager.default.fileExists(
            atPath: paths.payload.appendingPathComponent("Contents/Info.plist").path
        ))
        #expect(!FileManager.default.fileExists(atPath: paths.archive.path))
    }

    private func release(_ version: String) -> String {
        """
        <entry>
          <updated>2026-11-11T06:59:38Z</updated>
          <link rel="alternate" type="text/html" href="https://example.com/\(version)"/>
          <id>tag:github.com,2008:Repository/1452297452/v\(version)</id>
          <title>Aural \(version) — Development Preview</title>
        </entry>
        """
    }

    private func atomFeed(_ entries: [String]) throws -> Data {
        let value = """
        <?xml version="1.0" encoding="UTF-8"?>
        <feed xmlns="http://www.w3.org/2005/Atom">
          <title>Release notes from Aural</title>
          \(entries.joined())
        </feed>
        """
        return try #require(value.data(using: .utf8))
    }

    private func makeBundle(identifier: String, version: String, executable: Bool) throws -> URL {
        let bundle = FileManager.default.temporaryDirectory
            .appendingPathComponent("AuralUpdateBundle-\(UUID().uuidString).app", isDirectory: true)
        let contents = bundle.appendingPathComponent("Contents", isDirectory: true)
        let macOS = contents.appendingPathComponent("MacOS", isDirectory: true)
        try FileManager.default.createDirectory(at: macOS, withIntermediateDirectories: true)
        let plist: [String: Any] = [
            "CFBundleIdentifier": identifier,
            "CFBundleShortVersionString": version,
            "CFBundleExecutable": "Aural"
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: plist, format: .xml, options: 0)
        try data.write(to: contents.appendingPathComponent("Info.plist"))
        if executable {
            let target = macOS.appendingPathComponent("Aural")
            try FileManager.default.copyItem(at: URL(fileURLWithPath: "/usr/bin/true"), to: target)
        }
        return bundle
    }

    private func run(_ executable: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
    }
}
