import Combine
import Foundation

/// 一副物理耳机独占自己的协议连接与命令队列，不能通过切换共享控制器实现多耳机界面。
public struct HeadphoneControlEntry: Identifiable {
    public var id: String { output.uid }
    public let output: AudioOutput
    public let controller: HeadphoneController
}

@MainActor
public final class HeadphoneControllerGroup: ObservableObject {
    @Published public private(set) var entries: [HeadphoneControlEntry] = []
    private let makeController: () -> HeadphoneController
    /// 按 UID 复用实例，使短暂路由过渡不丢失每副耳机的“停止控制”意图。
    private var controllers: [String: HeadphoneController] = [:]
    private var subscriptions: [String: AnyCancellable] = [:]
    private var suspended = false
    private var shuttingDown = false

    public convenience init() { self.init(makeController: { HeadphoneController() }) }
    public init(makeController: @escaping () -> HeadphoneController) {
        self.makeController = makeController
    }

    public func supports(_ output: AudioOutput) -> Bool {
        guard !shuttingDown, output.isBluetooth else { return false }
        return controller(for: output.uid).supports(output)
    }

    private func controller(for uid: String) -> HeadphoneController {
        if let existing = controllers[uid] { return existing }
        let created = makeController()
        if suspended { created.suspend() }
        controllers[uid] = created
        subscriptions[uid] = created.objectWillChange.receive(on: RunLoop.main).sink { [weak self] _ in
            self?.objectWillChange.send()
        }
        return created
    }

    public func updateOutputs(_ outputs: [AudioOutput]) {
        guard !shuttingDown else { return }
        // 即使调用方未预筛选，也不能为音箱、显示器或仅支持系统音量的设备创建控制卡片。
        let supported = outputs.filter { supports($0) }
        let activeUIDs = Set(supported.map(\.uid))
        for entry in entries where !activeUIDs.contains(entry.id) {
            entry.controller.outputUnavailable()
        }
        let next = supported.map { output in
            let driver = controller(for: output.uid)
            driver.updateOutput(output)
            return HeadphoneControlEntry(output: output, controller: driver)
        }
        if entries.map(\.output) != next.map(\.output) { entries = next }
    }

    /// 切换前后都存在的已就绪耳机保留连接；真正移除或尚未验证的耳机仍按原有生命周期释放。
    public func prepareRouteChange(retaining memberUIDs: [String]) {
        let retainedUIDs = Set(memberUIDs)
        let retained = entries.filter { entry in
            if retainedUIDs.contains(entry.id), entry.controller.pauseRouteAuthorization() { return true }
            entry.controller.outputUnavailable()
            return false
        }
        if entries.map(\.id) != retained.map(\.id) { entries = retained }
    }

    /// 菜单栏的单值电量仅在唯一耳机时显示，多副时在各自卡片里显示，避免冒充某个手选目标。
    public var battery: Int? { entries.count == 1 ? entries[0].controller.state.battery : nil }
    public var diagnosticLines: [String] {
        entries.flatMap { entry in
            let lines = entry.controller.diagnosticLines
            return lines.isEmpty ? [] : ["[\(entry.output.name)]"] + lines
        }
    }
    public func outputUnavailable() { updateOutputs([]) }
    public func suspend() {
        suspended = true
        for driver in controllers.values { driver.suspend() }
    }
    public func resume() {
        guard !shuttingDown else { return }
        suspended = false
        for driver in controllers.values { driver.resume() }
    }
    public func shutdown() {
        shuttingDown = true
        for driver in controllers.values { driver.shutdown() }
    }
}
