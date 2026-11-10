import Foundation
import Testing
@testable import Aural

struct AuralUpdateCheckerTests {
    private let digest = "sha256:c55497f43fd177df00cd7dc8d4d0cb167b9ff65a6b73e8d40c752d48714339da"

    @Test func newestPublicReleaseWinsRegardlessOfResponseOrderAndSelectsArm64Zip() throws {
        let data = try jsonData("""
        [
          \(release("0.1.9")),
          \(release("0.1.11")),
          \(release("0.1.10"))
        ]
        """)

        let update = try AuralUpdateChecker.newestUpdate(from: data, currentVersion: "0.1.10")
        #expect(update?.version == "0.1.11")
        #expect(update?.pageURL.absoluteString == "https://example.com/0.1.11")
        #expect(update?.downloadURL.absoluteString == "https://example.com/Aural-0.1.11-macOS-arm64.zip")
        #expect(update?.assetSize == 1024)
        #expect(update?.sha256 == "c55497f43fd177df00cd7dc8d4d0cb167b9ff65a6b73e8d40c752d48714339da")
    }

    @Test func draftAndCurrentReleasesDoNotTriggerUpdate() throws {
        let draft = try jsonData("""
        [{"tag_name":"v0.1.12","html_url":"https://example.com/0.1.12","draft":true,"assets":[]}]
        """)
        let current = try jsonData("""
        [\(release("0.1.10"))]
        """)

        #expect(try AuralUpdateChecker.newestUpdate(from: draft, currentVersion: "0.1.10") == nil)
        #expect(try AuralUpdateChecker.newestUpdate(from: current, currentVersion: "0.1.10") == nil)
    }

    @Test func prereleaseStillCountsWhenItIsNewerThanInstalledBuild() throws {
        let data = try jsonData("""
        [\(release("0.1.11-beta.1"))]
        """)

        let update = try AuralUpdateChecker.newestUpdate(from: data, currentVersion: "0.1.10")
        #expect(update?.version == "0.1.11-beta.1")
    }

    @Test func missingArm64AssetIsRejectedInsteadOfFallingBackToWebPage() throws {
        let data = try jsonData("""
        [{
          "tag_name":"v0.1.11",
          "html_url":"https://example.com/0.1.11",
          "draft":false,
          "assets":[{
            "name":"Aural-0.1.11-macOS-x86_64.zip",
            "browser_download_url":"https://example.com/x86.zip",
            "size":1024,
            "digest":"\(digest)"
          }]
        }]
        """)

        #expect(throws: AuralUpdateError.self) {
            _ = try AuralUpdateChecker.newestUpdate(from: data, currentVersion: "0.1.10")
        }
    }

    @Test func missingDigestIsRejected() throws {
        let data = try jsonData("""
        [{
          "tag_name":"v0.1.11",
          "html_url":"https://example.com/0.1.11",
          "draft":false,
          "assets":[{
            "name":"Aural-0.1.11-macOS-arm64.zip",
            "browser_download_url":"https://example.com/Aural-0.1.11-macOS-arm64.zip",
            "size":1024
          }]
        }]
        """)

        #expect(throws: AuralUpdateError.self) {
            _ = try AuralUpdateChecker.newestUpdate(from: data, currentVersion: "0.1.10")
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
        let currentData = try jsonData("[\(release("0.1.11"))]")
        let newerData = try jsonData("[\(release("0.1.12"))]")
        let currentUpdate = try #require(
            try AuralUpdateChecker.newestUpdate(from: currentData, currentVersion: "0.1.10")
        )
        let newerUpdate = try #require(
            try AuralUpdateChecker.newestUpdate(from: newerData, currentVersion: "0.1.10")
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
        let archive = root.appendingPathComponent("Aural-0.1.11-macOS-arm64.zip")
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", bundle.path, archive.path])
        let size = try #require(
            (FileManager.default.attributesOfItem(atPath: archive.path)[.size] as? NSNumber)?.intValue
        )
        let update = AuralAvailableUpdate(
            version: "0.1.11",
            pageURL: URL(string: "https://example.com/0.1.11")!,
            downloadURL: URL(string: "https://example.com/update.zip")!,
            assetSize: size,
            sha256: try AuralSHA256.hexDigest(at: archive)
        )
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
        {
          "tag_name":"v\(version)",
          "html_url":"https://example.com/\(version)",
          "draft":false,
          "assets":[{
            "name":"Aural-\(version)-macOS-arm64.zip",
            "browser_download_url":"https://example.com/Aural-\(version)-macOS-arm64.zip",
            "size":1024,
            "digest":"\(digest)"
          }]
        }
        """
    }

    private func jsonData(_ value: String) throws -> Data {
        try #require(value.data(using: .utf8))
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
