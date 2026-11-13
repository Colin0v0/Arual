import AppKit
import CoreAudio
import CoreGraphics
import SwiftUI
import AuralCore
import OSLog

enum MeterSurface: Hashable { case popover, controlWindow }

/// 用户正在系统界面选择输出时，默认变化应被视为明确意图，而不是 AirPods 抢占。
private enum SystemOutputPicker {
    static func isInUse() -> Bool {
        if NSWorkspace.shared.frontmostApplication?.bundleIdentifier == "com.apple.systempreferences" {
            return true
        }
        let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
        let controlCenterPIDs = Set(NSRunningApplication.runningApplications(
            withBundleIdentifier: "com.apple.controlcenter"
        ).map(\.processIdentifier))
        let menuBarLayer = Int(CGWindowLevelForKey(.statusWindow))
        return windows.contains { window in
            guard let pid = window[kCGWindowOwnerPID as String] as? pid_t,
                  controlCenterPIDs.contains(pid) else { return false }
            return (window[kCGWindowLayer as String] as? Int) != menuBarLayer
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    private static let audioLog = Logger(subsystem: "local.aural.app", category: "ApplicationAudio")
    let headphones: HeadphoneControllerGroup
    private let observesHeadphones: Bool
    @Published private(set) var headphoneControl = HeadphoneControlSelection()
    @Published private(set) var audio: SystemAudioSnapshot?
    @Published private(set) var audioError: String?
    @Published private(set) var inputAudio: SystemInputSnapshot?
    @Published private(set) var inputError: String?
    @Published private(set) var inputOperationError: String?
    @Published private(set) var applications: [ApplicationAudioRow] = []
    /// 展示列表独立于实时进程目录；切路由时保留行身份，不用短暂的停流驱动界面增删。
    @Published private(set) var playingApplications: [ApplicationAudioRow] = []
    @Published private(set) var registeredProcessCount = 0
    @Published private(set) var audioCaptureAccess: SystemAudioCaptureAccess = .notDetermined
    @Published private(set) var processError: String?
    @Published private(set) var mixStates: [String: ApplicationMixState] = [:]
    @Published private(set) var sessions: [String: any ApplicationAudioSession] = [:]
    /// 仅按稳定 bundle 身份保存；界面行 ID 可能是临时的 unassigned/pid 身份。
    @Published private(set) var appAudioRoutes: [String: AppAudioRoute] = [:]
    @Published private(set) var appAudioRoutePersistenceError: String?
    @Published var operationError: String?
    @Published private(set) var cleanupErrors: [String: String] = [:]
    @Published private(set) var outputRouting = OutputRoutingState()
    var multiOutputRoute: MultiOutputRoute? { outputRouting.confirmed?.aggregate }
    var multiOutputError: String? { outputRouting.error }
    var singleOutputTargetUID: String? {
        guard let confirmed = outputRouting.confirmed, confirmed.intent.isSimultaneous,
              confirmed.intent.memberUIDs.count == 1 else { return nil }
        return confirmed.output.uid
    }
    private let routing: OutputRoutingController
    private let applicationEnvironment: ApplicationAudioEnvironment?
    private let appAudioRouteStore: AppAudioRouteStore
    private var routingNow: Date {
        if let applicationEnvironment { return applicationEnvironment.now() }
        return Date()
    }
    private var routeConfirmationTimer: Timer?
    /// 蓝牙重连时 HAL 会在短时间内先切换默认句柄、后补齐输出流；只在这个有界窗口内等待收敛。
    private var pendingAudioSnapshotDeadline: Date?
    private var sessionRouteWaitSince: [String: Date] = [:]
    /// 仅用于界面稳定：路由确认后给音频进程三秒重新注册，绝不用于创建或保活音频会话。
    private var applicationListSettleDeadline: Date?
    /// 用户明确要求的 APP 重试绑定到这一次目标路由；HAL 尚未确认时不清错、不提前建会话。
    private var pendingApplicationReapplies: [String: OutputRoutingIntent] = [:]
    private let outputHardware: MultiOutputHardware
    private let monitorsSystem: Bool
    private var timer: Timer?
    private var meterTimer: Timer?
    private var meterEnvelopes: [String: AudioLevelEnvelope] = [:]
    /// 只记录每个会话首次读到真实非零峰值，便于区分“已授权”和“确实收到音频”。
    private var observedAudioSignals: Set<String> = []
    /// 每个应用拥有独立发布源，30Hz 电平不会触发 AppModel 的全局 objectWillChange。
    private var levelSources: [String: ApplicationLevelSource] = [:]
    private var visibleMeterSurfaces: Set<MeterSurface> = []
    private var selectedMeterSections: Set<MeterSurface> = [.popover, .controlWindow]
    private var metersVisible: Bool { !visibleMeterSurfaces.isDisjoint(with: selectedMeterSections) }
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var activationObserver: NSObjectProtocol?
    private var outputRouteListener: AudioObjectPropertyListenerBlock?
    private var mediaOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var systemOutputAddress = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice,
        mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain
    )
    private var isShutdown = false

    /// 正式应用在主线程显式取得 HAL，避免默认参数在非隔离上下文读取主线程状态。
    convenience init(startsMonitoring: Bool = true) {
        self.init(outputHardware: .live, startsMonitoring: startsMonitoring)
    }

    /// 测试可注入只驻留内存的 HAL，并关闭系统监听，避免测试修改用户的音频设置。
    init(outputHardware: MultiOutputHardware, startsMonitoring: Bool = true,
         applicationAudio: ApplicationAudioEnvironment? = nil,
         headphoneControllerFactory: (() -> HeadphoneController)? = nil,
         userIsSelectingOutput: (() -> Bool)? = nil,
         appAudioRouteStore: AppAudioRouteStore? = nil) {
        if let headphoneControllerFactory {
            self.headphones = HeadphoneControllerGroup(makeController: headphoneControllerFactory)
        } else { self.headphones = HeadphoneControllerGroup() }
        self.observesHeadphones = startsMonitoring || headphoneControllerFactory != nil
        self.outputHardware = outputHardware
        self.monitorsSystem = startsMonitoring
        let routeStore = appAudioRouteStore ?? AppAudioRouteStore()
        self.appAudioRouteStore = routeStore
        if let applicationAudio { self.applicationEnvironment = applicationAudio }
        else if startsMonitoring { self.applicationEnvironment = .live }
        else { self.applicationEnvironment = nil }
        routing = OutputRoutingController(hardware: outputHardware)
        routing.localPlaybackOnConfirmedRoute = { [weak self] in
            guard let self, let confirmed = self.outputRouting.confirmed else { return false }
            return self.sessions.values.contains { $0.output.uid == confirmed.output.uid && $0.isActive }
        }
        routing.isUserSelectingOutput = userIsSelectingOutput ?? SystemOutputPicker.isInUse
        routing.beforeChanging = { [weak self] in
            guard let self, self.stopAll() else { throw AudioFailure("旧 APP 音频资源尚未释放，未切换输出") }
            self.sessionRouteWaitSince.removeAll()
        }
        routing.didChange = { [weak self] state in
            guard let self else { return }
            let wasBusy = self.outputRouting.phase.isBusy
            let beganSwitch = !wasBusy && state.phase.isBusy
            let finishedSwitch = wasBusy && !state.phase.isBusy && state.phase != .failed
            let changedRoute = self.outputRouting.confirmed != nil && state.confirmed != nil
                && self.outputRouting.confirmed?.output.uid != state.confirmed?.output.uid
            if beganSwitch || finishedSwitch || changedRoute {
                self.applicationListSettleDeadline = self.routingNow.addingTimeInterval(3)
            }
            if state.phase == .failed { self.applicationListSettleDeadline = nil }
            if self.outputRouting != state { self.outputRouting = state }
        }
        do {
            appAudioRoutes = try routeStore.load()
        } catch {
            appAudioRoutePersistenceError = error.localizedDescription
            operationError = error.localizedDescription
        }
        refresh()
        guard monitorsSystem else { return }
        // 从系统设置返回后复查授权，不信任首次启动的“已经申请过”标记。
        activationObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
        installOutputRouteListener()
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshForPeriodicTimer() }
        }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.willSleepNotification,
                                                                          object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.headphones.suspend()
                self.pauseManagedApplications("已在休眠前暂停应用音量；唤醒后请点重新应用。")
            }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification,
                                                                         object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in
                guard let self, !self.isShutdown else { return }
                self.headphones.resume()
                self.refresh()
            }
        }
    }

    /// 蓝牙重连可能瞬间改写默认输出。监听 HAL 通知后立即纠正，不能只等两秒轮询。
    private func installOutputRouteListener() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            Task { @MainActor [weak self] in self?.refreshForPeriodicTimer() }
        }
        outputRouteListener = listener
        _ = AudioObjectAddPropertyListenerBlock(HAL.system, &mediaOutputAddress, DispatchQueue.main, listener)
        _ = AudioObjectAddPropertyListenerBlock(HAL.system, &systemOutputAddress, DispatchQueue.main, listener)
    }

    private func removeOutputRouteListener() {
        guard let outputRouteListener else { return }
        _ = AudioObjectRemovePropertyListenerBlock(HAL.system, &mediaOutputAddress,
                                                   DispatchQueue.main, outputRouteListener)
        _ = AudioObjectRemovePropertyListenerBlock(HAL.system, &systemOutputAddress,
                                                   DispatchQueue.main, outputRouteListener)
        self.outputRouteListener = nil
    }

    func refresh() {
        guard !isShutdown else { return }
        refreshAudio()
        guard applicationEnvironment != nil else { return }
        refreshApplicationState()
    }

    /// 隐藏且没有用户管理的音频会话时，周期任务只刷新输出路由；
    /// 进程归属和输入设备枚举留给面板打开或用户主动操作，避免空闲时反复做完整扫描。
    private func refreshForPeriodicTimer() {
        guard !isShutdown else { return }
        refreshAudio()
        guard applicationEnvironment != nil, shouldRefreshApplicationStateDuringPolling else { return }
        refreshApplicationState()
    }

    private var shouldRefreshApplicationStateDuringPolling: Bool {
        !visibleMeterSurfaces.isEmpty
            || !sessions.isEmpty
            || mixStates.values.contains { $0.managed }
    }

    private func refreshApplicationState() {
        guard let applicationEnvironment else { return }
        refreshAudioCaptureAccess()
        if monitorsSystem { refreshInputs() }
        do {
            let retained = Set(mixStates.keys.filter { mixStates[$0]?.managed == true || sessions[$0] != nil })
            let observation = try applicationEnvironment.readApplications(retained)
            if registeredProcessCount != observation.processCount { registeredProcessCount = observation.processCount }
            let nextApplications = observation.rows
            if applications != nextApplications { applications = nextApplications }
            updateApplicationList(from: nextApplications)
            prepareLevelSources(for: playingApplications)
            if processError != nil { processError = nil }
        } catch {
            // 枚举失败就报告失败并暂停；不换另一份进程来源，也不把读取失败伪装成零个进程。
            for source in levelSources.values { source.update(nil) }
            if processError != error.localizedDescription { processError = error.localizedDescription }
            pauseManagedApplications("音频进程读取失败：\(error.localizedDescription)")
        }
        // 轮询结果未变化时不能写回 @Published 字典，否则整个面板会每两秒无意义重算一次。
        var nextMixStates = mixStates
        var mixStatesChanged = false
        for app in applications where nextMixStates[app.id] == nil {
            nextMixStates[app.id] = ApplicationMixState()
            mixStatesChanged = true
        }
        // 每次只读刷新都重新检查冲突事实，不把上一次错误当作当前进程仍存活的证据。
        let fineTuneRunning = isFineTuneRunning
        for key in Array(nextMixStates.keys) {
            guard var state = nextMixStates[key] else { continue }
            let previous = state
            state.updateFineTuneAvailability(isRunning: fineTuneRunning)
            if state != previous {
                nextMixStates[key] = state
                mixStatesChanged = true
            }
        }
        if mixStatesChanged { mixStates = nextMixStates }
        reconcileSessions()
    }

    /// 权限由独立提示控制器展示，不向每个应用锁存同一条错误。
    /// 撤销权限时先停止静音/重放会话，保留音量与路由意图；授权后再重新协调。
    @discardableResult
    private func refreshAudioCaptureAccess() -> Bool {
        guard let applicationEnvironment else { return false }
        let access = applicationEnvironment.captureAccess()
        if audioCaptureAccess != access { audioCaptureAccess = access }
        if !access.allowsApplicationAudio {
            for key in Array(sessions.keys) where cleanupErrors[key] == nil { stop(key) }
            for source in levelSources.values { source.update(nil) }
            meterEnvelopes.removeAll()
        }
        return access.allowsApplicationAudio
    }

    @discardableResult
    func openAudioCaptureSettings() -> Bool {
        if !NSWorkspace.shared.open(AudioCapturePermissionAlert.systemSettingsURL) {
            operationError = "未能打开系统设置，请手动进入隐私与安全性 → 屏幕与系统音频录制。"
            return false
        }
        return true
    }

    /// 保留可见行的电平源身份；路由切换可以中断真实电平，但不应重建整行的订阅对象。
    private func prepareLevelSources(for nextApplications: [ApplicationAudioRow]) {
        let nextIDs = Set(nextApplications.map(\.id))
        for applicationID in Array(levelSources.keys) where !nextIDs.contains(applicationID) {
            levelSources.removeValue(forKey: applicationID)
            meterEnvelopes.removeValue(forKey: applicationID)
        }
        for applicationID in nextIDs where levelSources[applicationID] == nil {
            levelSources[applicationID] = ApplicationLevelSource()
        }
    }

    /// 界面和 APP 只消费阶段机确认过的事实，刷新本身不抢回任何外部默认输出。
    private func refreshAudio() {
        do {
            let fresh = try outputHardware.snapshot()
            pendingAudioSnapshotDeadline = nil
            let previous = outputRouting.confirmed
            routing.observe(fresh, at: routingNow)
            guard let observed = routing.latestSnapshot else { throw AudioFailure("无法读回当前路由快照") }
            if audio != observed { audio = observed }
            if audioError != nil { audioError = nil }
            if let confirmed = outputRouting.confirmed, !outputRouting.phase.isBusy {
                if previous != confirmed {
                    sessionRouteWaitSince.removeAll()
                    if outputRouting.phase == .stable { pendingApplicationReapplies.removeAll() }
                }
                // 明确请求确认后，以及外部媒体路由变化后，都跟随真实目标；真实 APP 错误仍不清除。
                rebindManagedApplications(to: confirmed.output.uid)
                if outputRouting.phase == .confirmed { completePendingApplicationReapplies(on: confirmed) }
            } else {
                // 切换期只暂停会话；真正失败保留意图与资源错误，不再伪装成已经应用。
                for key in Array(sessions.keys) where cleanupErrors[key] == nil { stop(key) }
                if outputRouting.phase == .failed {
                    pendingApplicationReapplies.removeAll()
                    for key in Array(mixStates.keys) where mixStates[key]?.managed == true && mixStates[key]?.failure == nil {
                        mixStates[key]?.markOutputChanged()
                    }
                }
            }
            normalizeApplicationAudioRoutes()
            if observesHeadphones { updateHeadphoneControl(from: observed) }
            updateRouteConfirmationActivity()
        } catch {
            // 切换中的旧对象尚未从 HAL 列表移除时，继续由同一阶段和原期限确认，不能锁存全局失败。
            if routing.deferPendingObservation(error, at: routingNow) {
                updateRouteConfirmationActivity()
                return
            }
            // 稳定状态下的蓝牙重连也可能短暂读到“默认设备还未出现在输出列表”。
            // 保持现有界面并短周期重读，避免一次正常的 HAL 过渡被锁存成红色失败。
            if error is AudioSnapshotPending,
               !outputRouting.phase.isBusy,
               outputRouting.phase != .failed {
                if pendingAudioSnapshotDeadline == nil {
                    pendingAudioSnapshotDeadline = routingNow.addingTimeInterval(3)
                }
                if let deadline = pendingAudioSnapshotDeadline, routingNow < deadline {
                    updateRouteConfirmationActivity()
                    return
                }
            }
            pendingAudioSnapshotDeadline = nil
            routing.observationFailed(error)
            pendingApplicationReapplies.removeAll()
            updateRouteConfirmationActivity()
            if audio != nil { audio = nil }
            if audioError != error.localizedDescription { audioError = error.localizedDescription }
            headphoneControl = HeadphoneControlSelection()
            headphones.outputUnavailable()
            pauseManagedApplications("系统音频状态读取失败：\(error.localizedDescription)")
        }
    }

    /// 只在等待 HAL 时短周期读取同一目标；不重复发出写请求，也不阻塞 UI 主线程。
    private func updateRouteConfirmationActivity() {
        guard monitorsSystem,
              outputRouting.phase.isBusy
                || routing.hasPendingRelease && outputRouting.phase != .failed
                || pendingAudioSnapshotDeadline != nil else {
            routeConfirmationTimer?.invalidate(); routeConfirmationTimer = nil
            return
        }
        guard routeConfirmationTimer == nil else { return }
        let timer = Timer(timeInterval: 0.05, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refreshAudio()
                // 过渡期间只观察路由；不能以 20Hz 反复枚举全部 APP、输入设备或启动 tap。
                if !self.outputRouting.phase.isBusy, !self.routing.hasPendingRelease, self.applicationEnvironment != nil {
                    self.refreshApplicationState()
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        routeConfirmationTimer = timer
    }

    /// 耳机页与驱动共用全部可控物理设备；播放路由切换不撤销仍在线耳机的控制资格。
    private func updateHeadphoneControl(from snapshot: SystemAudioSnapshot) {
        var next = headphoneControl
        next.update(snapshot: snapshot, supports: { headphones.supports($0) })
        if next != headphoneControl { headphoneControl = next }
        headphones.updateOutputs(next.candidates)
    }

    private func refreshInputs() {
        do {
            let nextInput = try SystemInput.snapshot()
            if inputAudio != nextInput { inputAudio = nextInput }
            if inputError != nil { inputError = nil }
        } catch {
            if inputAudio != nil { inputAudio = nil }
            if inputError != error.localizedDescription { inputError = error.localizedDescription }
        }
    }

    private var isFineTuneRunning: Bool { applicationEnvironment?.hasMixerConflict() == true }

    /// 只稳定列表展示，不改变实时目录中的播放标记和进程对象，不能让旧流获得写入资格。
    private func updateApplicationList(from rows: [ApplicationAudioRow]) {
        let active = ApplicationCatalog.playingRows(from: rows)
        let activeIDs = Set(active.map(\.id))
        let current = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0) })
        let settling = outputRouting.phase.isBusy
            || applicationListSettleDeadline.map { routingNow < $0 } == true
        if !settling { applicationListSettleDeadline = nil }

        // 已有行保持相对顺序，新播放的应用追加；切换窗口内的短暂停流不触发行的移除动画。
        var next = playingApplications.compactMap { previous -> ApplicationAudioRow? in
            guard settling || activeIDs.contains(previous.id) else { return nil }
            if let observed = current[previous.id] { return observed }
            // 只保留图标与名称，明确撤销已消失的流，不用旧 group 冒充当前进程。
            return ApplicationAudioRow(id: previous.id, bundleID: previous.bundleID,
                                       name: previous.name, applicationURL: previous.applicationURL,
                                       group: nil, isRunningOutput: false)
        }
        let retainedIDs = Set(next.map(\.id))
        next.append(contentsOf: active.filter { !retainedIDs.contains($0.id) })
        if playingApplications != next { playingApplications = next }
    }

    /// 行视图按应用身份取得稳定的电平源；首次读取时建立，之后只更新电平叶子节点。
    func levelSource(for applicationID: String) -> ApplicationLevelSource {
        if let source = levelSources[applicationID] { return source }
        let source = ApplicationLevelSource()
        levelSources[applicationID] = source
        return source
    }

    private var selectedOutput: AudioOutput? {
        guard let audio else { return nil }
        return audio.outputs.first { $0.id == audio.selectedID }
    }

    var unmanagedMultiOutputs: [AudioOutput] {
        guard let audio else { return [] }
        return routing.unmanagedOutputs(in: audio)
    }

    var applicationAudioUnavailableReason: String? {
        // 正在离开或重建 Aural 组合时，不能用中间默认设备把整个 APP 区替换成限制文案。
        if outputRouting.phase.isBusy, !playingApplications.isEmpty { return nil }
        guard let output = selectedOutput, output.isAggregate else { return nil }
        if output.isAuralMultiOutput, output.uid != multiOutputRoute?.uid {
            return "选择上面的扬声器后，可调节 APP 音量与电平"
        }
        if output.uid == multiOutputRoute?.uid {
            // 当前 Aural 聚合有完整成员信息，APP 捕获与重放会走多设备镜像路由。
            return nil
        }
        // 外部聚合输出也不能送入只支持单设备的处理链；只说明限制，不再要求用户先选扬声器。
        return "当前系统输出不支持 APP 独立音量与电平"
    }

    var applicationAudioUnavailable: Bool { applicationAudioUnavailableReason != nil }

    /// 路由入口只在已确认、稳定的多设备组中出现；切换中的半成品组合不允许用户误选。
    var applicationAudioRoutingEnabled: Bool {
        guard audioCaptureAccess.allowsApplicationAudio,
              outputRouting.phase != .failed,
              !outputRouting.phase.isBusy,
              outputRouting.isSimultaneous,
              let confirmed = outputRouting.confirmed,
              confirmed.intent.isSimultaneous,
              confirmed.aggregate != nil else { return false }
        let configured = outputRouting.configured?.memberUIDs ?? confirmed.intent.memberUIDs
        return Set(configured.filter { !$0.isEmpty }).count > 1
    }

    /// 菜单只展示当前真实可播放的组成员；暂时离线但仍在组内的 UID 会保留在持久化意图里。
    var availableApplicationRouteOutputs: [AudioOutput] {
        applicationRouteContext?.activeOutputs ?? []
    }

    func hasStableApplicationRouteIdentity(_ applicationID: String) -> Bool {
        applicationRouteStorageKey(for: applicationID) != nil
    }

    func applicationAudioRoute(for applicationID: String) -> AppAudioRoute {
        guard let key = applicationRouteStorageKey(for: applicationID) else { return .allOutputs }
        guard let context = applicationRouteContext else {
            return appAudioRoutes[key] ?? .allOutputs
        }
        return AppAudioRouteResolver.resolve(
            stored: appAudioRoutes[key] ?? .allOutputs,
            configuredDeviceUIDs: context.configuredUIDs,
            activeDeviceUIDs: context.activeOutputs.map(\.uid)
        ).persisted
    }

    func effectiveApplicationAudioRoute(for applicationID: String) -> AppAudioRoute {
        guard let key = applicationRouteStorageKey(for: applicationID) else { return .allOutputs }
        // 退出多设备模式后只暂停实际音频路由；保存的自定义意图仍由 applicationAudioRoute 读取。
        guard let context = applicationRouteContext else { return .allOutputs }
        return AppAudioRouteResolver.resolve(
            stored: appAudioRoutes[key] ?? .allOutputs,
            configuredDeviceUIDs: context.configuredUIDs,
            activeDeviceUIDs: context.activeOutputs.map(\.uid)
        ).effective
    }

    func applicationRouteUnavailableDeviceUIDs(for applicationID: String) -> Set<String> {
        guard let key = applicationRouteStorageKey(for: applicationID),
              let context = applicationRouteContext else { return [] }
        return AppAudioRouteResolver.resolve(
            stored: appAudioRoutes[key] ?? .allOutputs,
            configuredDeviceUIDs: context.configuredUIDs,
            activeDeviceUIDs: context.activeOutputs.map(\.uid)
        ).unavailableDeviceUIDs
    }

    /// 设置自定义路由会实际创建/重建应用的 Process Tap 重放链，而不是只改界面勾选。
    func setApplicationAudioRoute(_ route: AppAudioRoute, for applicationID: String) {
        guard refreshAudioCaptureAccess() else { return }
        guard applicationAudioRoutingEnabled, let context = applicationRouteContext else {
            operationError = "应用路由仅在多设备输出模式下可用"
            return
        }
        guard let key = applicationRouteStorageKey(for: applicationID) else {
            operationError = "该应用没有稳定身份，不能设置持久应用路由"
            return
        }

        if case .custom(let deviceUIDs) = route {
            guard !deviceUIDs.isEmpty else {
                operationError = "至少选择一台输出设备"
                return
            }
            guard deviceUIDs.isSubset(of: Set(context.configuredUIDs)) else {
                operationError = "应用路由目标必须来自当前多设备输出组"
                return
            }
        }

        var nextRoutes = appAudioRoutes
        if route == .allOutputs {
            nextRoutes.removeValue(forKey: key)
        } else {
            nextRoutes[key] = route
        }
        do {
            try appAudioRouteStore.save(nextRoutes)
        } catch {
            appAudioRoutePersistenceError = error.localizedDescription
            operationError = error.localizedDescription
            return
        }

        appAudioRoutes = nextRoutes
        appAudioRoutePersistenceError = nil
        operationError = nil
        if let app = applications.first(where: { $0.id == applicationID }) {
            reconcile(app)
        }
    }

    /// 复选框只操作当前可播放成员；暂时离线设备会在按 UID 重连后自动回到自定义集合。
    func toggleApplicationAudioRouteDevice(_ deviceUID: String, for applicationID: String) {
        guard refreshAudioCaptureAccess() else { return }
        guard applicationAudioRoutingEnabled, let context = applicationRouteContext else {
            operationError = "应用路由仅在多设备输出模式下可用"
            return
        }
        guard context.activeOutputs.contains(where: { $0.uid == deviceUID }) else {
            operationError = "应用路由目标必须来自当前多设备输出组"
            return
        }

        let current = applicationAudioRoute(for: applicationID)
        var selected = current.isCustom
            ? current.customDeviceUIDs
            : Set(context.activeOutputs.map(\.uid))
        if selected.contains(deviceUID) {
            // 最后一个输出不允许从应用路由中移除；这是无效操作，不产生顶部错误提示。
            guard selected.count > 1 else { return }
            selected.remove(deviceUID)
        } else {
            selected.insert(deviceUID)
        }
        setApplicationAudioRoute(.custom(deviceUIDs: selected), for: applicationID)
    }

    func resetApplicationAudioRoute(for applicationID: String) {
        setApplicationAudioRoute(.allOutputs, for: applicationID)
    }

    private var applicationRouteContext: (configuredUIDs: [String], activeOutputs: [AudioOutput])? {
        guard outputRouting.phase != .failed,
              !outputRouting.phase.isBusy,
              outputRouting.isSimultaneous,
              let confirmed = outputRouting.confirmed,
              confirmed.intent.isSimultaneous,
              let aggregate = confirmed.aggregate else { return nil }
        let configured = outputRouting.configured?.memberUIDs ?? confirmed.intent.memberUIDs
        let unavailable = Set(outputRouting.unavailableMemberUIDs)
        let active = aggregate.outputs.filter { !unavailable.contains($0.uid) }
        return (configured.filter { !$0.isEmpty }, active)
    }

    private func applicationRouteStorageKey(for applicationID: String) -> String? {
        let app = applications.first { $0.id == applicationID }
            ?? playingApplications.first { $0.id == applicationID }
        guard let app, !app.bundleID.isEmpty else { return nil }
        return "bundle:\(app.bundleID)"
    }

    /// 组成员移除后清理持久意图；设备仅暂时不可用时保留 UID，等待重连恢复。
    private func normalizeApplicationAudioRoutes() {
        guard !outputRouting.phase.isBusy,
              outputRouting.phase != .failed,
              outputRouting.isSimultaneous,
              let confirmed = outputRouting.confirmed,
              confirmed.intent.isSimultaneous,
              let aggregate = confirmed.aggregate else { return }
        let configured = outputRouting.configured?.memberUIDs ?? confirmed.intent.memberUIDs
        let unavailable = Set(outputRouting.unavailableMemberUIDs)
        let active = aggregate.outputs.map(\.uid).filter { !unavailable.contains($0) }

        var nextRoutes = appAudioRoutes
        var changed = false
        for (key, route) in appAudioRoutes {
            let normalized = AppAudioRouteResolver.resolve(
                stored: route,
                configuredDeviceUIDs: configured,
                activeDeviceUIDs: active
            ).persisted
            if normalized == .allOutputs {
                nextRoutes.removeValue(forKey: key)
                changed = true
            } else if normalized != route {
                nextRoutes[key] = normalized
                changed = true
            }
        }
        guard changed else { return }
        do {
            try appAudioRouteStore.save(nextRoutes)
            appAudioRoutes = nextRoutes
            appAudioRoutePersistenceError = nil
        } catch {
            appAudioRoutePersistenceError = error.localizedDescription
            operationError = error.localizedDescription
        }
    }

    private func pauseManagedApplications(_ reason: String) {
        // 进程读取、休眠等新失效撤销旧的重试授权，不能在确认后把后来发生的真实错误清掉。
        pendingApplicationReapplies.removeAll()
        for key in Array(mixStates.keys) where mixStates[key]?.managed == true {
            latchApplicationFailure(reason, for: key)
        }
        // 自动生命周期处理只尝试一次；已知释放失败必须由用户明确重试。
        for key in Array(sessions.keys) where cleanupErrors[key] == nil { stop(key) }
    }

    private func reconcileSessions() {
        let visible = Set(applications.map(\.id))
        for key in Array(sessions.keys) where !visible.contains(key) && cleanupErrors[key] == nil { stop(key) }
        for key in Array(mixStates.keys) where !visible.contains(key) && (key.hasPrefix("pid:") || key.hasPrefix("unassigned:pid:")) {
            latchApplicationFailure("匿名音频进程已退出，请确认来源后重新应用。", for: key)
        }
        for app in applications { reconcile(app) }
    }

    private func reconcile(_ app: ApplicationAudioRow) {
        guard audioCaptureAccess.allowsApplicationAudio else { return }
        guard var state = mixStates[app.id], cleanupErrors[app.id] == nil else { return }
        guard !outputRouting.phase.isBusy, outputRouting.phase != .failed,
              let confirmed = outputRouting.confirmed,
              processError == nil else { stop(app.id); return }
        let output = confirmed.output
        if output.isAggregate {
            // 只有本进程刚建立、且仍与当前快照一致的 Aural 聚合才能被接管；
            // 第三方聚合和上次启动遗留的聚合都缺少可信成员镜像，不能猜测音频路线。
            guard let route = multiOutputRoute,
                  route.deviceID == output.id,
                  route.uid == output.uid else {
                if state.managed {
                    latchApplicationFailure("当前组合输出没有可用的 Aural 路由，请结束组合后重新应用。", for: app.id)
                }
                stop(app.id)
                return
            }
        }
        let requiresRouting = effectiveApplicationAudioRoute(for: app.id).isCustom
        guard let mode = ApplicationAudioIntent.mode(
            state: state,
            isPlaying: app.isRunningOutput,
            meterVisible: metersVisible,
            requiresRouting: requiresRouting
        ) else {
            stop(app.id)
            return
        }
        // 已确认路由是唯一可启动目标；未经确认的旧 UID 绝不能继续重放。
        if mode == .mixing, state.managed, state.boundOutputUID != output.uid {
            state.markOutputChanged()
            mixStates[app.id] = state; stop(app.id); return
        }
        guard !isFineTuneRunning else {
            mixStates[app.id]?.blockForFineTune()
            stop(app.id)
            return
        }
        guard let group = app.group else { stop(app.id); return }
        let requestedPlaybackRoute: ApplicationPlaybackRoute?
        do {
            requestedPlaybackRoute = try applicationPlaybackRoute(for: output, appID: app.id)
        } catch {
            latchApplicationFailure(error.localizedDescription, for: app.id)
            stop(app.id)
            return
        }
        let expectedPlaybackRoute = requestedPlaybackRoute ?? .single(output)
        if let session = sessions[app.id], session.mode == mode,
           session.group.objectIDs == group.objectIDs, session.output.uid == output.uid,
           session.playbackRoute == expectedPlaybackRoute {
            do {
                if mode == .mixing { try session.setGain(state.gain); session.setMuted(state.muted) }
                try session.checkHealth(expectingAudio: app.isRunningOutput)
            } catch {
                recordSessionFailure(error, for: app.id)
                stop(app.id)
            }
        } else {
            // 计量与混音共享所有权检查；必须完整释放旧 tap 后才能改变 muteBehavior。
            guard stop(app.id) else { return }
            start(group, output: output, state: state, mode: mode,
                  playbackRoute: requestedPlaybackRoute)
        }
    }

    func setMeteringVisible(_ visible: Bool, for surface: MeterSurface) {
        if visible { visibleMeterSurfaces.insert(surface) }
        else { visibleMeterSurfaces.remove(surface) }
        updateMeteringActivity()
    }

    func setApplicationMetersSelected(_ selected: Bool, for surface: MeterSurface) {
        if selected { selectedMeterSections.insert(surface) }
        else { selectedMeterSections.remove(surface) }
        updateMeteringActivity()
    }

    private func updateMeteringActivity() {
        guard !isShutdown else { return }
        refreshAudioCaptureAccess()
        if metersVisible {
            if meterTimer == nil {
                // 隐藏期间的峰值不是“此刻”的电平，重新显示前丢弃历史邮箱。
                for session in sessions.values { _ = session.consumePeak() }
                meterEnvelopes = [:]
                let timer = Timer(timeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
                    Task { @MainActor in self?.refreshMeters() }
                }
                RunLoop.main.add(timer, forMode: .common)
                meterTimer = timer
            }
        } else {
            meterTimer?.invalidate(); meterTimer = nil
            for source in levelSources.values { source.update(nil) }
            meterEnvelopes = [:]
        }
        reconcileSessions()
    }

    private func refreshMeters() {
        guard metersVisible, !isShutdown else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var activeIDs: Set<String> = []
        for app in playingApplications {
            activeIDs.insert(app.id)
            guard let peak = sessions[app.id]?.consumePeak() else {
                meterEnvelopes.removeValue(forKey: app.id)
                levelSources[app.id]?.update(nil)
                continue
            }
            if peak > 0, observedAudioSignals.insert(app.id).inserted {
                // 在主线程记录状态，不在实时回调中写日志，也不记录或保存音频样本。
                Self.audioLog.notice("Received real audio signal for \(app.id, privacy: .public)")
            }
            if meterEnvelopes[app.id] == nil { meterEnvelopes[app.id] = AudioLevelEnvelope() }
            let level = meterEnvelopes[app.id]?.update(peak: peak, at: now)
            levelSources[app.id]?.update(level)
        }
        meterEnvelopes = meterEnvelopes.filter { activeIDs.contains($0.key) }
    }

    func selectOutput(_ id: UInt32) {
        guard let target = audio?.outputs.first(where: { $0.id == id }), !target.isAggregate else {
            operationError = "请选择真实输出设备"; return
        }
        requestOutput(.single(target.uid))
    }

    private func requestOutput(_ intent: OutputRoutingIntent) {
        // 新的设备选择取代先前尚未完成的 APP 恢复操作，不能在另一路由上偷偷清除权限错误。
        pendingApplicationReapplies.removeAll()
        routing.request(intent, at: routingNow)
        refresh()
    }

    /// 返回值只表示已经确认，不把等待中的请求冒充成功；视图直接观察阶段，不用 Bool 回滚勾选。
    @discardableResult
    func startSimultaneousOutput(_ outputUIDs: [String]) -> Bool {
        requestOutput(.simultaneous(outputUIDs))
        return outputRouting.phase == .confirmed
    }

    @discardableResult
    func updateSimultaneousOutput(_ outputUIDs: [String]) -> Bool {
        startSimultaneousOutput(outputUIDs)
    }

    func toggleSimultaneousMember(_ uid: String) {
        // 连点基于协调器最后的意图计算，而非视图里另存的旧勾选。
        let base: [String]
        if let queued = outputRouting.queued { base = queued.memberUIDs }
        else if outputRouting.phase.isBusy, let desired = outputRouting.desired { base = desired.memberUIDs }
        else if outputRouting.isSimultaneous { base = outputRouting.selectedMemberUIDs }
        else { base = [] }
        guard base != [uid] else { return }
        var next = base
        if next.contains(uid) { next.removeAll { $0 == uid } } else { next.append(uid) }
        requestOutput(.simultaneous(next))
    }

    func dismissSimultaneousOutputError() { routing.dismissError(); refresh() }

    func stopSimultaneousOutput() { routing.stop(at: routingNow); refresh() }

    /// 这些状态只来自用户在本界面发起的路由切换。
    /// 先把 APP 绑定迁移到新输出，再刷新，不能把主动切换误报成外部设备变化。
    private func rebindManagedApplications(to outputUID: String?) {
        guard let outputUID else { return }
        var nextMixStates = mixStates
        var changed = false
        for key in Array(nextMixStates.keys) {
            guard var state = nextMixStates[key], state.managed else { continue }
            let previous = state
            state.rebind(outputUID: outputUID)
            if state != previous {
                nextMixStates[key] = state
                changed = true
            }
        }
        if changed { mixStates = nextMixStates }
    }

    func setOutputVolume(_ value: Float, on id: UInt32) {
        guard audio?.outputs.contains(where: { $0.id == id }) == true else {
            operationError = "所选输出设备已断开，请刷新。"; return
        }
        do { try SystemAudio.setVolume(value, on: id); operationError = nil }
        catch { operationError = error.localizedDescription }
        refreshAudio()
    }

    func setOutputMuted(_ muted: Bool, on id: UInt32) {
        guard audio?.outputs.contains(where: { $0.id == id }) == true else {
            operationError = "所选输出设备已断开，请刷新。"; return
        }
        do { try SystemAudio.setMute(muted, on: id); operationError = nil }
        catch { operationError = error.localizedDescription }
        refreshAudio()
    }

    private var simultaneousOutputs: [AudioOutput] {
        guard let confirmed = outputRouting.confirmed, confirmed.intent.isSimultaneous else { return [] }
        if let aggregate = confirmed.aggregate { return aggregate.outputs }
        return [confirmed.output]
    }

    /// 统一音量只在所有成员都能写出时才执行，避免只改动其中一台造成无声或突响。
    func setSimultaneousOutputVolume(_ value: Float) {
        let outputs = simultaneousOutputs
        guard !outputs.isEmpty else { return }
        let controlStates = outputs.map { audio?.controls[$0.id] }
        let allWritable = controlStates.allSatisfy { state in
            guard case .available(let volume, _) = state else { return false }
            return volume.scalar != nil && volume.writable
        }
        guard allWritable else {
            operationError = "多设备输出中的设备不支持统一音量，请分别调节成员设备"
            return
        }
        do {
            for output in outputs { try SystemAudio.setVolume(value, on: output.id) }
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
        refreshAudio()
    }

    /// 静音同样要求所有成员具备可写控制，不能把部分成功说成整体静音。
    func setSimultaneousOutputMuted(_ muted: Bool) {
        let outputs = simultaneousOutputs
        guard !outputs.isEmpty else { return }
        let controlStates = outputs.map { audio?.controls[$0.id] }
        let allWritable = controlStates.allSatisfy { state in
            guard case .available(_, let mute) = state else { return false }
            return mute.writable
        }
        guard allWritable else {
            operationError = "多设备输出中的设备不支持统一静音，请分别调节成员设备"
            return
        }
        do {
            for output in outputs { try SystemAudio.setMute(muted, on: output.id) }
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
        refreshAudio()
    }

    func selectInput(_ id: UInt32) {
        guard inputAudio?.selectedID != id else { return }
        do { try SystemInput.select(id); inputOperationError = nil }
        catch { inputOperationError = error.localizedDescription }
        // 输入选择不调用 stopAll，不主动改变应用输出增益或默认输出。
        refresh()
    }

    func setInputVolume(_ value: Float, on id: UInt32) {
        guard inputAudio?.inputs.contains(where: { $0.id == id }) == true else {
            inputOperationError = "所选麦克风已断开，请刷新。"; return
        }
        do { try SystemInput.setVolume(value, on: id); inputOperationError = nil }
        catch { inputOperationError = error.localizedDescription }
        refreshInputs()
    }

    func setInputMuted(_ muted: Bool, on id: UInt32) {
        guard inputAudio?.inputs.contains(where: { $0.id == id }) == true else {
            inputOperationError = "所选麦克风已断开，请刷新。"; return
        }
        do { try SystemInput.setMute(muted, on: id); inputOperationError = nil }
        catch { inputOperationError = error.localizedDescription }
        refreshInputs()
    }

    func setApplicationGain(_ value: Float, for id: String) {
        guard refreshAudioCaptureAccess() else { return }
        guard var state = mixStates[id] else { return }
        do {
            try state.setGain(value)
            enableIfNeeded(&state)
            mixStates[id] = state
            if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
        } catch { operationError = error.localizedDescription }
    }

    func toggleApplicationMute(_ id: String) {
        guard refreshAudioCaptureAccess() else { return }
        guard var state = mixStates[id] else { return }
        state.toggleMute(); enableIfNeeded(&state); mixStates[id] = state
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    private func enableIfNeeded(_ state: inout ApplicationMixState) {
        // 调整滑杆是明确的管理意图；已锁存的失败不会因为拖动而被偷偷重试。
        guard !state.managed, state.failure == nil else { return }
        guard let output = selectedOutput else { state.fail("当前没有可用系统输出，请恢复后点重新应用。"); return }
        state.enable(outputUID: output.uid)
    }

    func applyApplication(_ id: String) {
        guard refreshAudioCaptureAccess() else { return }
        guard !outputRouting.phase.isBusy else {
            if let desired = outputRouting.desired { pendingApplicationReapplies[id] = desired }
            return
        }
        // “重新应用”是明确的恢复意图：外部已切到真实设备时先确认该设备并清理旧组合，
        // 不把 APP 错误清掉后又被失败路由 guard 静默拦住。
        if outputRouting.phase == .failed || outputRouting.confirmed == nil {
            guard let actual = outputRouting.actualOutput, !actual.isAggregate else {
                operationError = "请先选择一台真实输出设备，再重新应用"; return
            }
            let intent = OutputRoutingIntent.single(actual.uid)
            pendingApplicationReapplies[id] = intent
            routing.request(intent, at: routingNow)
            refreshAudio()
        }
        guard let confirmed = outputRouting.confirmed, !outputRouting.phase.isBusy,
              stop(id), var state = mixStates[id] else { return }
        sessionRouteWaitSince.removeValue(forKey: id)
        state.enable(outputUID: confirmed.output.uid)
        mixStates[id] = state
        operationError = nil
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    /// 路由确认后继续完成同一次显式 APP 重试，用户不需要第二次点击。
    private func completePendingApplicationReapplies(on confirmed: ConfirmedOutputRoute) {
        let pending = pendingApplicationReapplies
        pendingApplicationReapplies.removeAll()
        for (id, intent) in pending where intent == confirmed.intent {
            sessionRouteWaitSince.removeValue(forKey: id)
            mixStates[id]?.enable(outputUID: confirmed.output.uid)
        }
    }

    func retryMeter(_ id: String) {
        guard refreshAudioCaptureAccess() else { return }
        pendingApplicationReapplies.removeValue(forKey: id)
        guard mixStates[id]?.managed == false, stop(id) else { return }
        sessionRouteWaitSince.removeValue(forKey: id)
        mixStates[id]?.disable()
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    func stopManaging(_ id: String) {
        pendingApplicationReapplies.removeValue(forKey: id)
        sessionRouteWaitSince.removeValue(forKey: id)
        guard clearApplicationAudioRoute(for: id) else { return }
        mixStates[id]?.disable()
        guard stop(id) else { return }
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    private func start(_ group: AudioProcessGroup, output: AudioOutput,
                       state: ApplicationMixState, mode: ApplicationAudioMode,
                       playbackRoute: ApplicationPlaybackRoute?) {
        guard !AudioSessionOwnership.overlaps(requested: group.objectIDs, existing: sessions.values.map { $0.group.objectIDs }) else {
            latchApplicationFailure("该音频流仍被尚未释放的旧会话持有，请先释放资源再重新应用。", for: group.id)
            return
        }
        guard !isFineTuneRunning else {
            mixStates[group.id]?.blockForFineTune()
            return
        }
        guard let applicationEnvironment else { return }
        let session = applicationEnvironment.makeSession(group, output, playbackRoute, mode)
        sessions[group.id] = session
        do {
            if mode == .mixing { try session.setGain(state.gain); session.setMuted(state.muted) }
            try session.start()
            sessionRouteWaitSince.removeValue(forKey: group.id)
        } catch {
            recordSessionFailure(error, for: group.id)
            if session.isReleased { sessions.removeValue(forKey: group.id) }
            else { cleanupErrors[group.id] = "\(group.label)：\(error.localizedDescription)" }
        }
    }

    private func latchApplicationFailure(_ message: String, for key: String) {
        pendingApplicationReapplies.removeValue(forKey: key)
        guard mixStates[key]?.failure != message else { return }
        // 只记录本机错误元数据，不记录音频。下次可直接读取确切失败，不再只靠截图中的红点猜测。
        Self.audioLog.error("Application \(key, privacy: .public) processing failed: \(message, privacy: .public)")
        mixStates[key]?.fail(message)
    }

    private func recordSessionFailure(_ error: Error, for key: String) {
        guard let pending = error as? ApplicationRoutePending, let applicationEnvironment else {
            latchApplicationFailure(error.localizedDescription, for: key)
            return
        }
        let now = applicationEnvironment.now()
        if let since = sessionRouteWaitSince[key] {
            if now.timeIntervalSince(since) >= 3 {
                let message = pending.reason == .formatChange
                    ? "应用捕获与输出的音频格式尚未一致，请重新应用"
                    : "应用未在期限内跟随已确认输出，请重新应用"
                latchApplicationFailure(message, for: key)
            }
        } else {
            sessionRouteWaitSince[key] = now
            if let detail = pending.detail {
                Self.audioLog.notice("Application \(key, privacy: .public) waiting for audio: \(detail, privacy: .public)")
            }
        }
    }

    /// Aural 聚合只负责捕获来源；重放必须回到它的真实硬件成员，
    /// 不能把公开多输出设备再次嵌套成私有聚合的子设备。
    private func applicationPlaybackRoute(for output: AudioOutput,
                                          appID: String) throws -> ApplicationPlaybackRoute? {
        guard output.isAuralMultiOutput else { return nil }
        guard let route = multiOutputRoute,
              route.deviceID == output.id,
              route.uid == output.uid else {
            throw AudioFailure("Aural 多设备输出缺少当前成员信息，请重新配置组合")
        }
        let effective = effectiveApplicationAudioRoute(for: appID)
        let playbackOutputs: [AudioOutput]
        if case .custom(let targetUIDs) = effective {
            playbackOutputs = route.outputs.filter { targetUIDs.contains($0.uid) }
            guard !playbackOutputs.isEmpty else {
                throw AudioFailure("应用自定义路由的所选设备当前不可用")
            }
        } else {
            playbackOutputs = route.outputs
        }
        return try ApplicationPlaybackRoute(output: output,
                                            playbackOutputs: playbackOutputs,
                                            groupOutputs: route.outputs,
                                            mainOutputUID: route.mainOutputUID)
    }

    private func clearApplicationAudioRoute(for applicationID: String) -> Bool {
        guard let key = applicationRouteStorageKey(for: applicationID),
              appAudioRoutes[key] != nil else { return true }
        var nextRoutes = appAudioRoutes
        nextRoutes.removeValue(forKey: key)
        do {
            try appAudioRouteStore.save(nextRoutes)
        } catch {
            appAudioRoutePersistenceError = error.localizedDescription
            operationError = error.localizedDescription
            return false
        }
        appAudioRoutes = nextRoutes
        appAudioRoutePersistenceError = nil
        return true
    }

    @discardableResult
    func stop(_ key: String) -> Bool {
        guard let session = sessions[key] else { return true }
        do {
            try session.stop(); sessions.removeValue(forKey: key); cleanupErrors.removeValue(forKey: key)
            observedAudioSignals.remove(key)
            levelSources[key]?.update(nil); meterEnvelopes.removeValue(forKey: key)
            return true
        } catch {
            cleanupErrors[key] = "\(session.group.label)：\(error.localizedDescription)"
            latchApplicationFailure("音频资源未能释放，请点击重试释放。", for: key)
            return false
        }
    }
    @discardableResult
    func stopAll() -> Bool {
        for key in Array(sessions.keys) { stop(key) }
        return sessions.isEmpty
    }

    func shutdown() -> Bool {
        guard stopAll() else { return false }
        if routing.retainedRoute != nil || !outputRouting.pendingCleanup.isEmpty {
            routing.stop(at: routingNow)
            refreshAudio()
            guard !outputRouting.phase.isBusy, outputRouting.phase != .failed,
                  routing.retainedRoute == nil, outputRouting.pendingCleanup.isEmpty else { return false }
        }
        routeConfirmationTimer?.invalidate(); routeConfirmationTimer = nil
        isShutdown = true; headphones.shutdown()
        timer?.invalidate(); timer = nil
        meterTimer?.invalidate(); meterTimer = nil
        removeOutputRouteListener()
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        if let activationObserver { NotificationCenter.default.removeObserver(activationObserver) }
        return true
    }
}
