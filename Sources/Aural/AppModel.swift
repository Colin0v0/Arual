import AppKit
import SwiftUI
import AuralCore

enum MeterSurface: Hashable { case popover, controlWindow }

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()
    let headphones = HeadphoneController()
    @Published private(set) var audio: SystemAudioSnapshot?
    @Published private(set) var audioError: String?
    @Published private(set) var inputAudio: SystemInputSnapshot?
    @Published private(set) var inputError: String?
    @Published private(set) var inputOperationError: String?
    @Published private(set) var applications: [ApplicationAudioRow] = []
    @Published private(set) var registeredProcessCount = 0
    @Published private(set) var processError: String?
    @Published private(set) var mixStates: [String: ApplicationMixState] = [:]
    @Published private(set) var sessions: [String: ProcessAudioSession] = [:]
    @Published private(set) var meterLevels: [String: Float] = [:]
    @Published var operationError: String?
    @Published private(set) var cleanupErrors: [String: String] = [:]
    @Published private(set) var multiOutputRoute: MultiOutputRoute?
    @Published private(set) var multiOutputError: String?
    /// 同时输出只剩一台时仍使用真实硬件，但需要短住在该目标上，防止蓝牙重连自动抢走默认输出。
    private(set) var singleOutputTargetUID: String?
    private let multiOutput: MultiOutputDevice
    private let outputHardware: MultiOutputHardware
    private let monitorsSystem: Bool
    private var timer: Timer?
    private var meterTimer: Timer?
    private var meterEnvelopes: [String: AudioLevelEnvelope] = [:]
    private var visibleMeterSurfaces: Set<MeterSurface> = []
    private var selectedMeterSections: Set<MeterSurface> = [.popover, .controlWindow]
    private var metersVisible: Bool { !visibleMeterSurfaces.isDisjoint(with: selectedMeterSections) }
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var isShutdown = false

    /// 正式应用在主线程显式取得 HAL，避免默认参数在非隔离上下文读取主线程状态。
    convenience init(startsMonitoring: Bool = true) {
        self.init(outputHardware: .live, startsMonitoring: startsMonitoring)
    }

    /// 测试可注入只驻留内存的 HAL，并关闭系统监听，避免测试修改用户的音频设置。
    init(outputHardware: MultiOutputHardware, startsMonitoring: Bool = true) {
        self.outputHardware = outputHardware
        self.monitorsSystem = startsMonitoring
        multiOutput = MultiOutputDevice(hardware: outputHardware)
        refresh()
        guard monitorsSystem else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
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

    func refresh() {
        guard !isShutdown else { return }
        refreshAudio()
        guard monitorsSystem else { return }
        refreshInputs()
        do {
            let records = try AudioProcesses.records()
            registeredProcessCount = records.count
            let retained = Set(mixStates.keys.filter { mixStates[$0]?.managed == true || sessions[$0] != nil })
            applications = RunningApplications.rows(records: records, retainedIDs: retained)
            processError = nil
        } catch {
            // 普通 App 身份仍是系统真实数据，但不能把失败的 HAL 枚举当作“没有音频流”。
            applications = RunningApplications.rows(records: [])
            registeredProcessCount = 0
            processError = error.localizedDescription
            pauseManagedApplications("音频进程读取失败：\(error.localizedDescription)")
        }
        for app in applications where mixStates[app.id] == nil { mixStates[app.id] = ApplicationMixState() }
        // 每次只读刷新都重新检查冲突事实，不把上一次错误当作当前进程仍存活的证据。
        let fineTuneRunning = isFineTuneRunning
        for key in Array(mixStates.keys) {
            mixStates[key]?.updateFineTuneAvailability(isRunning: fineTuneRunning)
        }
        reconcileSessions()
    }

    /// 写入任意设备后重新读取全部设备；同一套更新路径负责默认输出与耳机生命周期。
    private func refreshAudio() {
        do {
            var fresh = try outputHardware.snapshot()
            if multiOutput.route != nil, !multiOutput.requiresCleanup {
                do {
                    let restoredSelection = try multiOutput.reconcile(snapshot: fresh)
                    // 蓝牙设备抢占默认输出后已经恢复聚合设备，立即重读界面状态，避免短暂显示错误选中项。
                    if restoredSelection { fresh = try outputHardware.snapshot() }
                    multiOutputError = nil
                }
                catch { multiOutputError = error.localizedDescription }
                // 即便释放后还需报告成员断连，也不能把旧快照中的组合设备显示一轮。
                if multiOutput.route == nil { fresh = try outputHardware.snapshot() }
            }
            if multiOutput.route == nil, singleOutputTargetUID != nil {
                do {
                    fresh = try restoreSingleOutputIfBluetoothTookOver(fresh)
                    multiOutputError = nil
                } catch {
                    multiOutputError = error.localizedDescription
                }
            }
            multiOutputRoute = multiOutput.route
            if monitorsSystem { headphones.updateOutput(resolvedHeadphoneOutput(from: fresh)) }
            audio = fresh
            audioError = nil
            if let output = fresh.outputs.first(where: { $0.id == fresh.selectedID }) {
                // 不可见的已管理 App 也要暂停，不能在 X→Y→X 后悄悄恢复。
                for key in Array(mixStates.keys) {
                    if mixStates[key]?.pauseIfOutputChanged(currentUID: output.uid) == true,
                       cleanupErrors[key] == nil { stop(key) }
                }
            }
        } catch {
            audio = nil; audioError = error.localizedDescription
            headphones.outputUnavailable()
            pauseManagedApplications("系统音频状态读取失败：\(error.localizedDescription)")
        }
    }

    /// 单成员同时输出没有聚合设备可供 reconcile；蓝牙自动切回时，按用户最后保留的设备恢复一次。
    private func restoreSingleOutputIfBluetoothTookOver(_ snapshot: SystemAudioSnapshot) throws -> SystemAudioSnapshot {
        guard let targetUID = singleOutputTargetUID else { return snapshot }
        guard let target = snapshot.outputs.first(where: { $0.uid == targetUID }) else {
            singleOutputTargetUID = nil
            throw AudioFailure("同时输出保留的设备已断开，请重新选择")
        }
        guard snapshot.selectedID != target.id else { return snapshot }
        let current = snapshot.outputs.first { $0.id == snapshot.selectedID }
        guard current?.isBluetooth == true else {
            // 用户或其他应用明确切到非蓝牙设备时，以那次选择为准并结束保留状态。
            singleOutputTargetUID = nil
            return snapshot
        }
        try outputHardware.select(target.id)
        let verified = try outputHardware.snapshot()
        guard verified.selectedID == target.id else {
            throw AudioFailure("蓝牙设备仍在抢占输出，请重新选择设备")
        }
        return verified
    }

    /// 同时输出没有单一物理默认设备；只有成员里恰好一副可控耳机时才交给耳机页，
    /// 多副耳机并存时不做任意选择，避免把控制写到用户没有指定的设备。
    private func resolvedHeadphoneOutput(from snapshot: SystemAudioSnapshot) -> AudioOutput? {
        guard let selected = snapshot.outputs.first(where: { $0.id == snapshot.selectedID }) else { return nil }
        if headphones.supports(selected) { return selected }
        guard selected.isAuralMultiOutput, let route = multiOutput.route,
              route.deviceID == selected.id else { return nil }
        let candidates = route.outputs.filter { headphones.supports($0) }
        return candidates.count == 1 ? candidates[0] : nil
    }

    private func refreshInputs() {
        do { inputAudio = try SystemInput.snapshot(); inputError = nil }
        catch { inputAudio = nil; inputError = error.localizedDescription }
    }

    private var isFineTuneRunning: Bool {
        let bundleIDs = NSWorkspace.shared.runningApplications
            .filter { !$0.isTerminated }.compactMap(\.bundleIdentifier)
        return AudioMixerConflict.fineTuneIsRunning(bundleIDs: bundleIDs)
    }

    /// 展示过滤与会话生命周期分开，暂停后隐藏，但不会因列表移除而失去静音/增益。
    var playingApplications: [ApplicationAudioRow] {
        ApplicationCatalog.playingRows(from: applications)
    }

    private var selectedOutput: AudioOutput? {
        guard let audio else { return nil }
        return audio.outputs.first { $0.id == audio.selectedID }
    }

    var unmanagedMultiOutputs: [AudioOutput] {
        guard let audio else { return [] }
        return multiOutput.unmanagedOutputs(in: audio)
    }

    var applicationAudioUnavailableReason: String? {
        guard let output = selectedOutput, output.isAggregate else { return nil }
        if output.isAuralMultiOutput, output.uid != multiOutputRoute?.uid {
            return "选择上面的扬声器后，可调节 APP 音量与电平"
        }
        if output.uid == multiOutputRoute?.uid {
            return "同时输出时暂不支持 APP 独立音量与电平"
        }
        // 外部聚合输出也不能送入只支持单设备的处理链；只说明限制，不再要求用户先选扬声器。
        return "当前系统输出不支持 APP 独立音量与电平"
    }

    var applicationAudioUnavailable: Bool { applicationAudioUnavailableReason != nil }

    private func pauseManagedApplications(_ reason: String) {
        for key in Array(mixStates.keys) where mixStates[key]?.managed == true {
            mixStates[key]?.fail(reason)
        }
        // 自动生命周期处理只尝试一次；已知释放失败必须由用户明确重试。
        for key in Array(sessions.keys) where cleanupErrors[key] == nil { stop(key) }
    }

    private func reconcileSessions() {
        let visible = Set(applications.map(\.id))
        for key in Array(sessions.keys) where !visible.contains(key) && cleanupErrors[key] == nil { stop(key) }
        for key in Array(mixStates.keys) where !visible.contains(key) && (key.hasPrefix("pid:") || key.hasPrefix("unassigned:pid:")) {
            mixStates[key]?.fail("匿名音频进程已退出，请确认来源后重新应用。")
        }
        for app in applications { reconcile(app) }
    }

    private func reconcile(_ app: ApplicationAudioRow) {
        guard var state = mixStates[app.id], cleanupErrors[app.id] == nil else { return }
        guard processError == nil, let output = selectedOutput else { stop(app.id); return }
        // 原有回调只处理一对立体声缓冲；组合输出不启动旧 tap，避免嵌套聚合或漏播成员。
        guard !output.isAggregate else {
            if state.managed { mixStates[app.id]?.fail("组合输出暂不支持 APP 独立音量，请结束同时输出后重新应用。") }
            stop(app.id)
            return
        }
        guard let mode = ApplicationAudioIntent.mode(state: state, isPlaying: app.isRunningOutput, meterVisible: metersVisible) else {
            stop(app.id)
            return
        }
        if mode == .mixing, state.boundOutputUID != output.uid {
            state.fail("系统输出已改变；点重新应用后才会在新设备上处理。")
            mixStates[app.id] = state; stop(app.id); return
        }
        guard !isFineTuneRunning else {
            mixStates[app.id]?.blockForFineTune()
            stop(app.id)
            return
        }
        guard let group = app.group else { stop(app.id); return }
        if let session = sessions[app.id], session.mode == mode,
           session.group.objectIDs == group.objectIDs, session.output.uid == output.uid {
            do {
                if mode == .mixing { try session.setGain(state.gain); session.setMuted(state.muted) }
                try session.checkHealth(expectingAudio: app.isRunningOutput)
            } catch {
                mixStates[app.id]?.fail(error.localizedDescription)
                stop(app.id)
            }
        } else {
            // 计量与混音共享所有权检查；必须完整释放旧 tap 后才能改变 muteBehavior。
            guard stop(app.id) else { return }
            start(group, output: output, state: state, mode: mode)
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
            meterLevels = [:]; meterEnvelopes = [:]
        }
        reconcileSessions()
    }

    private func refreshMeters() {
        guard metersVisible, !isShutdown else { return }
        let now = ProcessInfo.processInfo.systemUptime
        var levels: [String: Float] = [:]
        for app in playingApplications {
            guard let peak = sessions[app.id]?.consumePeak() else {
                meterEnvelopes.removeValue(forKey: app.id)
                continue
            }
            if meterEnvelopes[app.id] == nil { meterEnvelopes[app.id] = AudioLevelEnvelope() }
            levels[app.id] = meterEnvelopes[app.id]?.update(peak: peak, at: now)
        }
        meterEnvelopes = meterEnvelopes.filter { levels[$0.key] != nil }
        // 安静时不让整个面板每秒重复刷新 30 次。
        if levels != meterLevels { meterLevels = levels }
    }

    func selectOutput(_ id: UInt32) {
        let wasPinnedSingleOutput = singleOutputTargetUID != nil
        if wasPinnedSingleOutput {
            singleOutputTargetUID = nil
            if audio?.selectedID == id, multiOutput.route == nil, unmanagedMultiOutputs.isEmpty {
                multiOutputError = nil
                refresh()
                return
            }
        }
        let isRoutingOperation = multiOutput.route != nil || !unmanagedMultiOutputs.isEmpty
        guard audio?.selectedID != id || isRoutingOperation else {
            // 点击当前普通输出也是明确退出失败草稿的意图，不能让旧提示一直挂着。
            dismissSimultaneousOutputError()
            return
        }
        guard stopAll() else { return }
        do {
            let fresh = try outputHardware.snapshot()
            guard let target = fresh.outputs.first(where: { $0.id == id }), !target.isAuralMultiOutput else {
                throw AudioFailure("请选择可用的真实输出设备，不要选择遗留的同时输出设备")
            }
            if multiOutput.route != nil {
                try multiOutput.stop(selecting: target.uid)
                multiOutputRoute = multiOutput.route
                multiOutputError = nil
            } else { try outputHardware.select(id) }
            // 用户已经明确选择目标，先完成切换，再清理旧设备；失败也不切回旧聚合设备。
            try multiOutput.cleanupUnmanagedOutputs()
            multiOutputError = nil
            operationError = nil
        }
        catch {
            // 同时输出的释放失败归属路由区域；释放成功后不会残留在全局错误栏。
            if isRoutingOperation { multiOutputError = error.localizedDescription }
            else { operationError = error.localizedDescription }
        }
        refresh()
    }

    @discardableResult
    func startSimultaneousOutput(_ outputUIDs: [String]) -> Bool {
        guard !outputUIDs.isEmpty else {
            multiOutputError = "请至少选择一台输出设备"
            refresh()
            return false
        }
        let previousSingleTarget = singleOutputTargetUID
        // 只选一台时直接使用真实硬件，不创建单成员聚合，APP 音量与电平继续可用。
        if outputUIDs.count == 1 {
            let selected = selectSingleSimultaneousOutput(outputUIDs[0])
            if selected {
                singleOutputTargetUID = outputUIDs[0]
            } else if multiOutput.route == nil {
                singleOutputTargetUID = previousSingleTarget
            }
            return selected
        }
        guard stopAll() else { return false }
        do {
            try multiOutput.start(outputUIDs: outputUIDs)
            multiOutputRoute = multiOutput.route
            singleOutputTargetUID = nil
            multiOutputError = nil
            refresh()
            return true
        } catch {
            multiOutputRoute = multiOutput.route
            multiOutputError = error.localizedDescription
            refresh()
            return false
        }
    }

    /// 更改成员时先结束旧组合再按新顺序建立组合，顺序只用于保持系统稳定的成员排列。
    func updateSimultaneousOutput(_ outputUIDs: [String]) -> Bool {
        // 缩到一台时直接切换到该硬件，并释放原组合设备。
        if outputUIDs.count <= 1 { return startSimultaneousOutput(outputUIDs) }
        guard multiOutput.route != nil else { return startSimultaneousOutput(outputUIDs) }
        guard stopAll() else { return false }
        do {
            try multiOutput.stop()
            multiOutputRoute = nil
        } catch {
            multiOutputRoute = multiOutput.route
            multiOutputError = error.localizedDescription
            refresh()
            return false
        }
        do {
            try multiOutput.start(outputUIDs: outputUIDs)
            multiOutputRoute = multiOutput.route
            singleOutputTargetUID = nil
            multiOutputError = nil
            refresh()
            return true
        } catch {
            multiOutputRoute = multiOutput.route
            multiOutputError = error.localizedDescription
            refresh()
            return false
        }
    }

    /// 单设备选择与普通输出切换共用真实硬件路径，不保留不必要的聚合设备。
    private func selectSingleSimultaneousOutput(_ uid: String) -> Bool {
        guard stopAll() else { return false }
        do {
            let fresh = try outputHardware.snapshot()
            guard let target = fresh.outputs.first(where: { $0.uid == uid }),
                  target.supportsSimultaneousOutput,
                  try outputHardware.isAlive(target.id) else {
                throw AudioFailure("所选设备已断开，请重新选择")
            }
            if multiOutput.route != nil {
                try multiOutput.stop(selecting: target.uid)
            } else {
                try outputHardware.select(target.id)
            }
            try multiOutput.cleanupUnmanagedOutputs()
            multiOutputRoute = nil
            multiOutputError = nil
            operationError = nil
            // 先建立单设备保留目标再刷新，确保本次刷新就能发现并纠正蓝牙抢回默认输出。
            singleOutputTargetUID = uid
            refresh()
            // 刷新可能发现蓝牙再次抢占；不能吞掉该错误并向界面报告切换成功。
            guard audio?.selectedID == target.id, multiOutputError == nil else {
                throw AudioFailure(multiOutputError ?? "系统未确认输出切换，请刷新后检查")
            }
            return true
        } catch {
            multiOutputRoute = multiOutput.route
            multiOutputError = error.localizedDescription
            refresh()
            return false
        }
    }

    func dismissSimultaneousOutputError() {
        // 只清除已无路由的操作错误。真实资源未释放时仍须保留错误和明确重试入口。
        guard multiOutput.route == nil, unmanagedMultiOutputs.isEmpty else { return }
        multiOutputError = nil
    }

    func stopSimultaneousOutput() {
        // 退出同时输出编辑或取消最后一个成员时，不再保留单设备目标。
        singleOutputTargetUID = nil
        guard stopAll() else { return }
        do {
            try multiOutput.stop()
            try multiOutput.cleanupUnmanagedOutputs()
            multiOutputError = nil
        }
        catch { multiOutputError = error.localizedDescription }
        multiOutputRoute = multiOutput.route
        refresh()
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

    /// 统一音量只在所有成员都能写出时才执行，避免只改动其中一台造成无声或突响。
    func setSimultaneousOutputVolume(_ value: Float) {
        guard let route = multiOutput.route else { return }
        let controlStates = route.outputs.map { audio?.controls[$0.id] }
        let allWritable = controlStates.allSatisfy { state in
            guard case .available(let volume, _) = state else { return false }
            return volume.scalar != nil && volume.writable
        }
        guard allWritable else {
            operationError = "同时输出中的设备不支持统一音量，请分别调节成员设备"
            return
        }
        do {
            for output in route.outputs { try SystemAudio.setVolume(value, on: output.id) }
            operationError = nil
        } catch {
            operationError = error.localizedDescription
        }
        refreshAudio()
    }

    /// 静音同样要求所有成员具备可写控制，不能把部分成功说成整体静音。
    func setSimultaneousOutputMuted(_ muted: Bool) {
        guard let route = multiOutput.route else { return }
        let controlStates = route.outputs.map { audio?.controls[$0.id] }
        let allWritable = controlStates.allSatisfy { state in
            guard case .available(_, let mute) = state else { return false }
            return mute.writable
        }
        guard allWritable else {
            operationError = "同时输出中的设备不支持统一静音，请分别调节成员设备"
            return
        }
        do {
            for output in route.outputs { try SystemAudio.setMute(muted, on: output.id) }
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
        guard var state = mixStates[id] else { return }
        do {
            try state.setGain(value)
            enableIfNeeded(&state)
            mixStates[id] = state
            if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
        } catch { operationError = error.localizedDescription }
    }

    func toggleApplicationMute(_ id: String) {
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
        guard stop(id), var state = mixStates[id] else { return }
        guard let output = selectedOutput else { mixStates[id]?.fail("当前没有可用系统输出"); return }
        state.enable(outputUID: output.uid); mixStates[id] = state
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    func retryMeter(_ id: String) {
        guard mixStates[id]?.managed == false, stop(id) else { return }
        mixStates[id]?.disable()
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    func stopManaging(_ id: String) {
        mixStates[id]?.disable()
        guard stop(id) else { return }
        if let app = applications.first(where: { $0.id == id }) { reconcile(app) }
    }

    private func start(_ group: AudioProcessGroup, output: AudioOutput, state: ApplicationMixState, mode: ApplicationAudioMode) {
        guard !AudioSessionOwnership.overlaps(requested: group.objectIDs, existing: sessions.values.map { $0.group.objectIDs }) else {
            mixStates[group.id]?.fail("该音频流仍被尚未释放的旧会话持有，请先释放资源再重新应用。")
            return
        }
        guard !isFineTuneRunning else {
            mixStates[group.id]?.blockForFineTune()
            return
        }
        let session = ProcessAudioSession(group: group, output: output, mode: mode)
        sessions[group.id] = session
        do {
            if mode == .mixing { try session.setGain(state.gain); session.setMuted(state.muted) }
            try session.start()
        } catch {
            mixStates[group.id]?.fail(error.localizedDescription)
            if session.isReleased { sessions.removeValue(forKey: group.id) }
            else { cleanupErrors[group.id] = "\(group.label)：\(error.localizedDescription)" }
        }
    }

    @discardableResult
    func stop(_ key: String) -> Bool {
        guard let session = sessions[key] else { return true }
        do {
            try session.stop(); sessions.removeValue(forKey: key); cleanupErrors.removeValue(forKey: key)
            meterLevels.removeValue(forKey: key); meterEnvelopes.removeValue(forKey: key)
            return true
        } catch {
            cleanupErrors[key] = "\(session.group.label)：\(error.localizedDescription)"
            mixStates[key]?.fail("音频资源未能释放，请点击重试释放。")
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
        // 先切回原输出再释放组合；失败不能直接退出并遗留由本进程创建的设备。
        do { try multiOutput.stop() }
        catch {
            multiOutputError = error.localizedDescription
            multiOutputRoute = multiOutput.route
            return false
        }
        isShutdown = true; headphones.shutdown()
        timer?.invalidate(); timer = nil
        meterTimer?.invalidate(); meterTimer = nil
        if let sleepObserver { NSWorkspace.shared.notificationCenter.removeObserver(sleepObserver) }
        if let wakeObserver { NSWorkspace.shared.notificationCenter.removeObserver(wakeObserver) }
        return true
    }
}
