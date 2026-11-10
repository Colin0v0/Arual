import Darwin
import Foundation

/// 独立 helper 不依赖正在运行的 App；等待旧进程退出后原子替换 bundle，再重新启动。
@main
enum AuralUpdateHelperMain {
    static func main() {
        // 让 helper 脱离 App 的会话/进程组，避免 App 退出时被 launchd 一并回收。
        _ = setsid()
        do {
            let options = try Options(arguments: CommandLine.arguments)
            try run(options: options)
            exit(0)
        } catch {
            appendLog("更新 helper 失败：\(error.localizedDescription)\n")
            exit(1)
        }
    }

    private static func run(options: Options) throws {
        appendLog("等待 Aural 退出，PID \(options.pid)\n")
        try waitForExit(pid: options.pid)
        try validatePayload(options: options)

        let fileManager = FileManager.default
        let appURL = URL(fileURLWithPath: options.appPath)
        let stage = URL(fileURLWithPath: options.stagePath, isDirectory: true)
        let payload = stage.appendingPathComponent("payload", isDirectory: true)
        let old = stage.appendingPathComponent("old", isDirectory: true)

        guard fileManager.fileExists(atPath: payload.path) else {
            throw HelperError.missingPayload
        }
        try? fileManager.removeItem(at: old)
        try fileManager.moveItem(at: appURL, to: old)
        do {
            try fileManager.moveItem(at: payload, to: appURL)
            // 下载来源可能带入隔离标记；已校验签名的更新不应再次被隔离检查拦住。
            _ = try? run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", appURL.path])
            let openResult = try run("/usr/bin/open", ["-n", "-g", appURL.path])
            appendLog("新版本启动命令已执行：\(openResult)\n")
            try? fileManager.removeItem(at: old)
            try? fileManager.removeItem(at: stage)
        } catch {
            // 替换后启动失败必须把旧版本放回原路径，不能留下不可启动的安装。
            try? fileManager.removeItem(at: appURL)
            try? fileManager.moveItem(at: old, to: appURL)
            throw error
        }
    }

    private static func validatePayload(options: Options) throws {
        let payload = URL(fileURLWithPath: options.stagePath, isDirectory: true)
            .appendingPathComponent("payload", isDirectory: true)
        let infoURL = payload.appendingPathComponent("Contents/Info.plist")
        guard let data = try? Data(contentsOf: infoURL),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else {
            throw HelperError.invalidPayload
        }
        guard plist["CFBundleIdentifier"] as? String == "local.aural.app" else {
            throw HelperError.invalidPayload
        }
        guard plist["CFBundleShortVersionString"] as? String == options.version else {
            throw HelperError.versionMismatch
        }
        _ = try run("/usr/bin/codesign", ["--verify", "--deep", "--strict", "--verbose=2", payload.path])
    }

    private static func waitForExit(pid: Int32) throws {
        // 最多等一分钟；正常退出通常只需几百毫秒。
        for _ in 0..<600 {
            if kill(pid, 0) != 0, errno == ESRCH { return }
            usleep(100_000)
        }
        throw HelperError.processStillRunning
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) throws -> String {
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
            throw HelperError.commandFailed(output.isEmpty ? "退出码 \(process.terminationStatus)" : output)
        }
        return output
    }

    private static func appendLog(_ message: String) {
        let logs = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Aural", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
            let logURL = logs.appendingPathComponent("update.log")
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
            // helper 日志失败不能阻断安装。
        }
    }
}

private struct Options {
    let pid: Int32
    let appPath: String
    let stagePath: String
    let version: String

    init(arguments: [String]) throws {
        func value(after key: String) throws -> String {
            guard let index = arguments.firstIndex(of: key),
                  arguments.indices.contains(index + 1) else {
                throw HelperError.invalidArguments
            }
            return arguments[index + 1]
        }
        guard let pid = Int32(try value(after: "--pid")) else {
            throw HelperError.invalidArguments
        }
        self.pid = pid
        appPath = try value(after: "--app")
        stagePath = try value(after: "--stage")
        version = try value(after: "--version")
    }
}

private enum HelperError: LocalizedError {
    case invalidArguments
    case processStillRunning
    case missingPayload
    case invalidPayload
    case versionMismatch
    case commandFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidArguments: return "更新 helper 参数无效"
        case .processStillRunning: return "等待旧 Aural 退出超时"
        case .missingPayload: return "暂存的新版本不存在"
        case .invalidPayload: return "暂存的新版本不是有效的 Aural"
        case .versionMismatch: return "暂存版本与目标版本不一致"
        case .commandFailed(let message): return message
        }
    }
}
