import AppKit
import AuralCore

/// 授权后的重启和更新安装分开处理；必须先让原实例正常释放音频资源。
@MainActor
final class ApplicationRelaunch {
    private(set) var isPending = false
    private let launchHelper: () throws -> Void
    private let cancelHelper: () -> Void
    private let terminateApplication: () -> Void

    init(launchHelper: @escaping () throws -> Void, cancelHelper: @escaping () -> Void,
         terminateApplication: @escaping () -> Void) {
        self.launchHelper = launchHelper
        self.cancelHelper = cancelHelper
        self.terminateApplication = terminateApplication
    }

    static var live: ApplicationRelaunch {
        let host = RelaunchHelperProcess()
        return ApplicationRelaunch(launchHelper: { try host.start() },
                                  cancelHelper: { host.cancel() },
                                  terminateApplication: { NSApp.terminate(nil) })
    }

    func request() throws {
        guard !isPending else { return }
        // helper 启动失败时不能退出当前应用，更不能把失败伪装成已经重启。
        try launchHelper()
        isPending = true
        terminateApplication()
    }

    func cancel() {
        guard isPending else { return }
        // applicationShouldTerminate 若因音频清理失败取消退出，同时取消等待中的重启。
        cancelHelper()
        isPending = false
    }

    static func helperArguments(app: URL, pid: Int32, version: String) -> [String] {
        ["--relaunch", "--pid", String(pid), "--app", app.path, "--version", version]
    }
}

@MainActor
private final class RelaunchHelperProcess {
    private var process: Process?

    func start() throws {
        let app = Bundle.main.bundleURL
        let helper = app.appendingPathComponent("Contents/Helpers/AuralUpdateHelper")
        guard Bundle.main.bundleIdentifier == "local.aural.app",
              app.pathExtension == "app",
              FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw AudioFailure("重启组件不可用，Aural 未退出")
        }
        let process = Process()
        process.executableURL = helper
        process.arguments = ApplicationRelaunch.helperArguments(
            app: app, pid: ProcessInfo.processInfo.processIdentifier, version: AuralVersion.current)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        self.process = process
    }

    func cancel() {
        if let process, process.isRunning { process.terminate() }
        process = nil
    }
}
