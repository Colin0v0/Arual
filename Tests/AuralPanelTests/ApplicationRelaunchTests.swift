import Foundation
import Testing
import AuralCore
@testable import Aural

@MainActor
struct ApplicationRelaunchTests {
    @Test func helperIsStartedBeforeRequestingNormalTermination() throws {
        var events: [String] = []
        let relaunch = ApplicationRelaunch(launchHelper: { events.append("helper") },
                                         cancelHelper: { events.append("cancel") },
                                         terminateApplication: { events.append("quit") })
        try relaunch.request()
        try relaunch.request()
        #expect(events == ["helper", "quit"])
        #expect(relaunch.isPending)
        // 退出清理失败时取消 helper，不会在用户稍后手动退出时意外重新启动。
        relaunch.cancel()
        relaunch.cancel()
        #expect(events == ["helper", "quit", "cancel"])
        #expect(!relaunch.isPending)
    }

    @Test func helperStartFailureDoesNotQuitTheApplication() {
        var quits = 0
        let relaunch = ApplicationRelaunch(launchHelper: { throw AudioFailure("测试 helper 启动失败") },
                                         cancelHelper: {}, terminateApplication: { quits += 1 })
        #expect(throws: (any Error).self) { try relaunch.request() }
        #expect(quits == 0 && !relaunch.isPending)
    }

    @Test func relaunchArgumentsNeverEnableUpdateInstallation() {
        let app = URL(fileURLWithPath: "/Applications/Aural Test.app")
        let args = ApplicationRelaunch.helperArguments(app: app, pid: 123, version: "0.2.2")
        #expect(args == ["--relaunch", "--pid", "123", "--app", app.path, "--version", "0.2.2"])
        #expect(!args.contains("--stage"))
    }
}
