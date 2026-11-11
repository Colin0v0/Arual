import Foundation
import AuralCore

/// 更新文件始终放在应用同卷的隐藏目录，helper 替换后才能继续在同一路径重启。
enum AuralUpdateInstaller {
    struct Paths: Sendable {
        let stage: URL
        let archive: URL
        let extracted: URL
        let payload: URL
        let oldBundle: URL
    }

    static let stageDirectoryName = ".aural-update"

    static var appURL: URL {
        Bundle.main.bundleURL.standardizedFileURL
    }

    static var stageURL: URL {
        appURL.deletingLastPathComponent().appendingPathComponent(stageDirectoryName, isDirectory: true)
    }

    static func prepareStaging(for update: AuralAvailableUpdate) throws -> Paths {
        let parent = appURL.deletingLastPathComponent()
        guard FileManager.default.isWritableFile(atPath: parent.path) else {
            throw AuralUpdateError.appDirectoryNotWritable(parent.path)
        }
        removeStaging()
        let stage = stageURL
        let extracted = stage.appendingPathComponent("extracted", isDirectory: true)
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        let paths = Paths(stage: stage,
                          archive: stage.appendingPathComponent("Aural-\(update.version).\(update.archiveKind.rawValue)"),
                          extracted: extracted,
                          payload: stage.appendingPathComponent("payload", isDirectory: true),
                          oldBundle: stage.appendingPathComponent("old", isDirectory: true))
        try writeMetadata(update: update, paths: paths)
        return paths
    }

    static func verifyAndPrepareDownloadedArchive(update: AuralAvailableUpdate,
                                                   paths: Paths) throws {
        let digest = try AuralSHA256.hexDigest(at: paths.archive)
        guard digest == update.sha256 else {
            try? FileManager.default.removeItem(at: paths.archive)
            throw AuralUpdateError.checksumMismatch
        }
        let appBundle: URL?
        switch update.archiveKind {
        case .dmg:
            appBundle = try extractAppFromDMG(paths.archive, to: paths.extracted)
        case .zip:
            // 仅为升级安装旧版保留；新建发布和自动更新默认使用 DMG。
            appBundle = try extractAppFromZIP(paths.archive, to: paths.extracted)
        }
        guard let appBundle else { throw AuralUpdateError.invalidArchive }
        try validateBundle(at: appBundle, expectedVersion: update.version)
        try? FileManager.default.removeItem(at: paths.payload)
        try FileManager.default.moveItem(at: appBundle, to: paths.payload)
        try? FileManager.default.removeItem(at: paths.archive)
        try? FileManager.default.removeItem(at: paths.extracted)
    }

    static func validateReadyInstall(expectedVersion: String) throws {
        let paths = currentPaths(version: expectedVersion)
        guard FileManager.default.fileExists(atPath: paths.payload.path) else {
            throw AuralUpdateError.readyInstallMissing
        }
        try validateBundle(at: paths.payload, expectedVersion: expectedVersion)
        let helper = helperURL
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AuralUpdateError.helperMissing(helper.path)
        }
    }

    static func launchHelper(expectedVersion: String) throws {
        try validateReadyInstall(expectedVersion: expectedVersion)
        let helper = helperURL
        let process = Process()
        process.executableURL = helper
        process.arguments = ["--pid", "\(ProcessInfo.processInfo.processIdentifier)",
                             "--app", appURL.path,
                             "--stage", stageURL.path,
                             "--version", expectedVersion]
        process.standardInput = FileHandle.nullDevice
        try process.run()
    }

    static func removeStaging() {
        try? FileManager.default.removeItem(at: stageURL)
    }

    static func appendLog(_ message: String) {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Aural", isDirectory: true)
        let logURL = logs.appendingPathComponent("update.log")
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let data = Data(message.utf8)
            if FileManager.default.fileExists(atPath: logURL.path) {
                let handle = try FileHandle(forWritingTo: logURL)
                try handle.seekToEnd()
                try handle.write(contentsOf: data)
                try handle.close()
            } else {
                try data.write(to: logURL, options: .atomic)
            }
        } catch {
            // 日志失败不能影响更新主流程。
        }
    }

    /// 在替换前验证 Bundle Identifier、版本、可执行文件和代码签名结构。
    static func validateBundle(at appURL: URL, expectedVersion: String) throws {
        let infoURL = appURL.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw AuralUpdateError.invalidBundle
        }
        let identifier = plist["CFBundleIdentifier"] as? String
        guard identifier == "local.aural.app" else {
            throw AuralUpdateError.bundleIdentifierMismatch(identifier ?? "缺失")
        }
        let actualVersion = (plist["CFBundleShortVersionString"] as? String) ?? "缺失"
        guard let expected = AuralVersionNumber(expectedVersion),
              let actual = AuralVersionNumber(actualVersion),
              expected == actual else {
            throw AuralUpdateError.bundleVersionMismatch(expected: expectedVersion, actual: actualVersion)
        }
        guard let executable = plist["CFBundleExecutable"] as? String,
              FileManager.default.isExecutableFile(
                atPath: appURL.appendingPathComponent("Contents/MacOS/\(executable)").path) else {
            throw AuralUpdateError.invalidBundle
        }
        do {
            _ = try runProcess("/usr/bin/codesign",
                               ["--verify", "--deep", "--strict", "--verbose=2", appURL.path])
        } catch {
            throw AuralUpdateError.invalidSignature(error.localizedDescription)
        }
    }

    private static var helperURL: URL {
        appURL.appendingPathComponent("Contents/Helpers/AuralUpdateHelper")
    }

    private static func currentPaths(version: String) -> Paths {
        let stage = stageURL
        return Paths(stage: stage,
                     archive: stage.appendingPathComponent("Aural-\(version).dmg"),
                     extracted: stage.appendingPathComponent("extracted", isDirectory: true),
                     payload: stage.appendingPathComponent("payload", isDirectory: true),
                     oldBundle: stage.appendingPathComponent("old", isDirectory: true))
    }

    private static func writeMetadata(update: AuralAvailableUpdate, paths: Paths) throws {
        let metadata: [String: Any] = [
            "version": update.version,
            "sha256": update.sha256,
            "downloadURL": update.downloadURL.absoluteString
        ]
        let data = try PropertyListSerialization.data(fromPropertyList: metadata, format: .xml, options: 0)
        try data.write(to: paths.stage.appendingPathComponent("metadata.plist"), options: .atomic)
    }

    /// DMG 是新的更新包格式；只读挂载后复制 Aural.app，避免执行镜像内的其他内容。
    private static func extractAppFromDMG(_ archive: URL, to directory: URL) throws -> URL? {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let mount = directory.appendingPathComponent("mount", isDirectory: true)
        try FileManager.default.createDirectory(at: mount, withIntermediateDirectories: true)
        _ = try runProcess("/usr/bin/hdiutil",
                           ["attach", archive.path, "-mountpoint", mount.path,
                            "-nobrowse", "-noautoopen", "-readonly", "-quiet"])
        defer { _ = try? runProcess("/usr/bin/hdiutil", ["detach", mount.path, "-quiet"]) }

        let appBundles = try FileManager.default.contentsOfDirectory(at: mount,
                                                                     includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
        guard appBundles.count == 1, let appBundle = appBundles.first else {
            return nil
        }
        let destination = directory.appendingPathComponent(appBundle.lastPathComponent)
        _ = try runProcess("/usr/bin/ditto", [appBundle.path, destination.path])
        return destination
    }

    /// 只有旧版发布才会走到这里；解压仍然只接受唯一一个 .app。
    private static func extractAppFromZIP(_ archive: URL, to directory: URL) throws -> URL? {
        try? FileManager.default.removeItem(at: directory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        _ = try runProcess("/usr/bin/ditto", ["-x", "-k", archive.path, directory.path])
        let appBundles = try FileManager.default.contentsOfDirectory(at: directory,
                                                                     includingPropertiesForKeys: nil)
            .filter { $0.pathExtension.lowercased() == "app" }
        guard appBundles.count == 1 else { return nil }
        return appBundles[0]
    }

    private static func runProcess(_ executable: String, _ arguments: [String]) throws -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let output = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard process.terminationStatus == 0 else {
            throw AuralUpdateError.commandFailed(output.isEmpty ? "退出码 \(process.terminationStatus)" : output)
        }
        return output
    }
}
