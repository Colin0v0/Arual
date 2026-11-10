import CoreAudio
import Foundation

/// 用户的播放意图不等于 HAL 已经完成的事实；单成员多输出仍保留模式身份。
public enum OutputRoutingIntent: Equatable {
    case single(String)
    case simultaneous([String])

    public var memberUIDs: [String] {
        switch self { case .single(let uid): return [uid]; case .simultaneous(let uids): return uids }
    }
    public var isSimultaneous: Bool {
        if case .simultaneous = self { return true }; return false
    }
}

public enum OutputRoutingPhase: Equatable {
    case stable, switching, awaitingHAL, awaitingMembers, confirmed, failed
    public var isBusy: Bool { self == .switching || self == .awaitingHAL }
}

public struct ConfirmedOutputRoute: Equatable {
    public let intent: OutputRoutingIntent
    public let output: AudioOutput
    public let aggregate: MultiOutputRoute?
}

/// 完成的步骤、实际默认输出及资源所有权分别报告，失败不冒充回滚成功。
public struct OutputRoutingState: Equatable {
    public init() {}
    public var phase: OutputRoutingPhase = .stable
    public var desired: OutputRoutingIntent?
    /// 用户勾选与当前生效成员分开保存；摘下耳机不能等同于用户取消勾选。
    public var configured: OutputRoutingIntent?
    public var configuredOutputs: [AudioOutput] = []
    public var unavailableMemberUIDs: [String] = []
    public var queued: OutputRoutingIntent?
    public var confirmed: ConfirmedOutputRoute?
    public var actualOutput: AudioOutput?
    public var actualSystemOutputID: AudioDeviceID?
    public var pendingCleanup: [AudioOutput] = []
    public var completedSteps: [String] = []
    public var error: String?
    /// 非失败提示：例如外部耳机持续抢占默认输出时，Aural 已跟随真实输出并停止争抢。
    public var warning: String?
    public var selectedMemberUIDs: [String] {
        guard phase != .failed else { return [] }
        if confirmed != nil || phase.isBusy || phase == .awaitingMembers {
            return configured?.memberUIDs ?? confirmed?.intent.memberUIDs ?? []
        }
        return []
    }
    public var isSimultaneous: Bool {
        guard phase != .failed else { return false }
        if confirmed != nil || phase.isBusy || phase == .awaitingMembers {
            return configured?.isSimultaneous ?? (confirmed?.intent.isSimultaneous == true)
        }
        return false
    }
}

/// 默认输出被外部设备抢占后的恢复节奏。
/// 第一次按真实播放通道恢复；同一设备很快再次抢占时停止争抢，避免扬声器与耳机之间反复断音。
private struct OutputPreemptionGuard {
    enum Decision: Equatable {
        case restore
        case yield(String)
    }

    private var takeoverUID: String?
    private var lastRestoreAt: Date?

    mutating func decide(stealingUID: String, at now: Date) -> Decision {
        if let lastRestoreAt, takeoverUID == stealingUID,
           now.timeIntervalSince(lastRestoreAt) < 30 {
            reset()
            return .yield("系统默认输出被反复抢占；Aural 已跟随真实输出并停止争抢。若为 AirPods，请在蓝牙设置中把“连接到此 Mac”改为“上次连接此 Mac 时”。")
        }
        takeoverUID = stealingUID
        self.lastRestoreAt = now
        return .restore
    }

    mutating func reset() {
        takeoverUID = nil
        lastRestoreAt = nil
    }
}

/// 唯一路由阶段机。HAL 写入只发一次，靠后续真实观察确认，不 sleep、不猜测输出、不抢回蓝牙选择。
@MainActor
public final class OutputRoutingController {
    public private(set) var state = OutputRoutingState() {
        didSet { if oldValue != state { didChange?(state) } }
    }
    public private(set) var latestSnapshot: SystemAudioSnapshot?
    public var didChange: ((OutputRoutingState) -> Void)?
    public var beforeChanging: (() throws -> Void)?
    /// APP 接管后声音由本进程重放；只要仍有活动会话在已确认路由，就属于真实播放事实。
    public var localPlaybackOnConfirmedRoute: (() -> Bool)?
    /// 用户正在控制中心或声音设置里明确选择输出时，外部变化属于用户意图，不能抢回。
    public var isUserSelectingOutput: (() -> Bool)?
    public var retainedRoute: MultiOutputRoute? { resources.route }
    public var hasPendingRelease: Bool { resources.hasPendingRelease }
    private let hardware: MultiOutputHardware
    private let resources: MultiOutputDevice
    private let confirmationTimeout: TimeInterval
    private var deadline: Date?
    private enum Step { case departure(AudioOutput), releasing(AudioOutput), cleanup(AudioOutput), activation(AudioOutput) }
    private var externalReleaseDeadline: Date?
    /// 外部媒体输出短暂换句柄时先等待同一目标恢复，不把一次蓝牙过渡锁成永久失败。
    private var externalAdoptionDeadline: Date?
    /// 一次显式切换只允许补写一次缺失的默认输出，避免 HAL 半写入后无限重试。
    private var alignmentRequested = false
    /// 组合成员重连时 HAL 可能短暂换句柄；等到期限再报告组合失效。
    private var routeValidationDeadline: Date?
    /// 默认输出变化时 HAL 会给整批设备换号，播放进程可能短暂仍报告旧句柄。
    private var routeHandleSettleDeadline: Date?
    /// 恢复需要两次相隔至少半秒的可用观察；同一次回调中的重复读取不算重新上线。
    private var memberRecoverySince: [String: Date] = [:]
    /// HAL 已停用但仍报告 alive 的成员，必须等到佩戴或离线再上线的正面证据，不能每轮盲目重建。
    private var memberRecoveryRequiresEvidence: Set<String> = []
    /// 默认输出被抢占但真实播放仍在原路由时，恢复一次默认输出，不拆正在工作的会话。
    private var preemption = OutputPreemptionGuard()
    /// 抢占提示只对触发它的那台设备有效；用户换到其他设备后不再显示旧提示。
    private var warningDeviceUID: String?
    private var step: Step?

    public init(hardware: MultiOutputHardware, confirmationTimeout: TimeInterval = 3) {
        self.hardware = hardware
        self.resources = MultiOutputDevice(hardware: hardware)
        self.confirmationTimeout = confirmationTimeout
    }

    public func unmanagedOutputs(in snapshot: SystemAudioSnapshot) -> [AudioOutput] {
        resources.unmanagedOutputs(in: snapshot)
    }

    /// 等待时合并到最后一次意图，所有硬件变更仍由当前阶段串行执行。
    public func request(_ intent: OutputRoutingIntent, at now: Date = Date()) {
        performRequest(intent, at: now, updatesConfiguration: true)
    }

    /// 同一条切换链同时处理显式勾选和已选成员的上下线；自动调整不覆盖用户原始勾选。
    private func performRequest(_ intent: OutputRoutingIntent, at now: Date,
                                updatesConfiguration: Bool) {
        if state.phase.isBusy { state.queued = intent; return }
        do {
            let snapshot = try hardware.snapshot()
            resources.recordUnmanagedOutputs(in: snapshot)
            try validateIntent(intent, snapshot: snapshot)
            if updatesConfiguration {
                state.configured = intent
                state.configuredOutputs = intent.memberUIDs.compactMap { uid in snapshot.outputs.first { $0.uid == uid } }
                state.unavailableMemberUIDs = []
                memberRecoverySince.removeAll()
                memberRecoveryRequiresEvidence.removeAll()
                state.queued = nil
            }
            if let confirmed = state.confirmed, confirmed.intent == intent,
               state.phase != .failed, state.pendingCleanup.isEmpty,
               snapshot.selectedID == confirmed.output.id,
               snapshot.outputs.contains(where: { $0.id == confirmed.output.id && $0.uid == confirmed.output.uid }),
               try hardware.selectedSystemOutputID() == confirmed.output.id {
                // 目标、两条默认输出与资源都已经吻合，不能仅因重复点击而停流和拆建同一路由。
                if confirmed.aggregate != nil { try resources.validate(snapshot: snapshot) }
                latestSnapshot = snapshot
                state.desired = intent
                state.phase = .confirmed
                state.error = nil
                return
            }
            resources.beginExplicitChange()
            externalReleaseDeadline = nil
            routeValidationDeadline = nil
            routeHandleSettleDeadline = nil
            preemption.reset()
            warningDeviceUID = nil
            // 验证请求之前不停止旧会话，也不破坏正在使用的组合。
            state.desired = intent
            state.confirmed = nil
            state.completedSteps = []
            state.error = nil
            state.warning = nil
            state.phase = .switching
            alignmentRequested = false
            try beforeChanging?()
            let selected = snapshot.outputs.first { $0.id == snapshot.selectedID }
            let systemID = try hardware.selectedSystemOutputID()
            let systemOutput = snapshot.outputs.first { $0.id == systemID }
            if resources.route != nil || selected?.isAggregate == true || systemOutput?.isAggregate == true {
                let departure = try member(intent.memberUIDs[0], in: snapshot)
                step = .departure(departure)
                deadline = now.addingTimeInterval(confirmationTimeout)
                try hardware.select(departure.id)
                state.completedSteps.append("已请求离开旧组合")
                state.phase = .awaitingHAL
            } else {
                try activate(intent, at: now)
            }
            observe(try hardware.snapshot(), at: now)
        } catch { failReadingActual(error, at: now) }
    }

    /// 监听与周期刷新都只观察同一阶段；迟到的旧路由通知不能确认新的目标。
    public func observe(_ snapshot: SystemAudioSnapshot, at now: Date = Date()) {
        latestSnapshot = snapshot
        resources.recordUnmanagedOutputs(in: snapshot)
        state.actualOutput = snapshot.outputs.first { $0.id == snapshot.selectedID }
        refreshConfirmedHandles(in: snapshot)
        // 蓝牙重连可能换掉 HAL 句柄；资源层也必须按 UID 跟随同一台设备。
        _ = resources.refreshHandles(snapshot: snapshot)
        do {
            let systemSelected = try hardware.selectedSystemOutputID()
            state.actualSystemOutputID = systemSelected
            if state.phase.isBusy, let step {
                // 资源释放有自己的确认阶段：不再用 destroy 后的第一份枚举判定永久失败。
                switch step {
                case .releasing:
                    guard try resources.release() else {
                        if let deadline, now >= deadline { throw AudioFailure("系统未在期限内释放组合设备，请重试释放") }
                        updateCleanup(snapshot)
                        return
                    }
                    state.completedSteps.append("已释放旧组合")
                    guard let intent = state.desired else { throw AudioFailure("路由切换意图丢失") }
                    try activate(intent, at: now)
                    observe(try hardware.snapshot(), at: now)
                    return
                case .cleanup:
                    guard try resources.cleanupUnmanagedOutputs() else {
                        if let deadline, now >= deadline { throw AudioFailure("系统未在期限内释放残留组合，请重试释放") }
                        updateCleanup(snapshot)
                        return
                    }
                    guard let intent = state.desired else { throw AudioFailure("路由切换意图丢失") }
                    try activate(intent, at: now)
                    observe(try hardware.snapshot(), at: now)
                    return
                case .departure, .activation: break
                }
                let target: AudioOutput
                switch step {
                case .departure(let output), .activation(let output): target = output
                case .releasing, .cleanup: return
                }
                guard snapshot.outputs.contains(where: { $0.id == target.id && $0.uid == target.uid }),
                      try hardware.isAlive(target.id) else { throw AudioFailure("等待确认的输出已断开") }
                let mediaMatches = snapshot.selectedID == target.id
                let systemMatches = systemSelected == target.id
                if !(mediaMatches && systemMatches) {
                    // macOS 偶尔只接受其中一条默认输出；确认到单边成功后补齐另一条，仍由后续观察验收。
                    if !alignmentRequested, mediaMatches != systemMatches {
                        alignmentRequested = true
                        try hardware.select(target.id)
                        state.completedSteps.append("已补齐媒体与提示音输出")
                        observe(try hardware.snapshot(), at: now)
                        return
                    }
                    if let deadline, now >= deadline { throw AudioFailure("系统未在期限内确认媒体与提示音输出") }
                    updateCleanup(snapshot)
                    return
                }
                alignmentRequested = false
                switch step {
                case .departure:
                    state.completedSteps.append("已确认离开旧组合")
                    self.step = .releasing(target)
                    deadline = now.addingTimeInterval(confirmationTimeout)
                    observe(snapshot, at: now)
                    return
                case .releasing, .cleanup: return
                case .activation:
                    if resources.route != nil { try resources.validate(snapshot: snapshot) }
                    guard let intent = state.desired else { throw AudioFailure("路由切换意图丢失") }
                    state.confirmed = ConfirmedOutputRoute(intent: intent, output: target, aggregate: resources.route)
                    state.phase = .confirmed
                    state.error = nil
                    state.completedSteps.append("已确认目标输出")
                    self.step = nil
                    deadline = nil
                    updateCleanup(snapshot)
                    drainQueue(at: now)
                    return
                }
            }
            // 失败保持可见，重新读回事实不等于重新执行请求或自动清除失败。
            if state.phase == .failed { updateCleanup(snapshot); return }
            // 先处理成员上下线，再判断默认输出抢占。摘耳导致通道消失不是另一台设备在争抢。
            if try reconcileConfiguredMembers(snapshot, at: now) { return }
            if let confirmed = state.confirmed {
                let selectedOutput = snapshot.outputs.first { $0.id == snapshot.selectedID }
                if let warningDeviceUID, selectedOutput?.uid != warningDeviceUID {
                    state.warning = nil
                    self.warningDeviceUID = nil
                }
                let sameMediaOutput = selectedOutput?.uid == confirmed.output.uid
                if sameMediaOutput {
                    externalAdoptionDeadline = nil
                    routeHandleSettleDeadline = nil
                    if confirmed.aggregate == nil, let old = resources.route, systemSelected != old.deviceID {
                        if try resources.release() {
                            externalReleaseDeadline = nil
                            observe(try hardware.snapshot(), at: now)
                            return
                        }
                        if externalReleaseDeadline == nil { externalReleaseDeadline = now.addingTimeInterval(confirmationTimeout) }
                        if let until = externalReleaseDeadline, now >= until {
                            throw AudioFailure("系统未在期限内释放组合设备，请重试释放")
                        }
                    }
                    // 两条默认输出可由 macOS 独立设置；仅提示音改变不使媒体会话失效。
                    if confirmed.aggregate != nil {
                        do {
                            try resources.validate(snapshot: snapshot)
                            routeValidationDeadline = nil
                        } catch {
                            if error is MultiOutputMembersUnavailable { throw error }
                            // 成员重连期间先观察同一组合，不能把一次蓝牙过渡立即判成永久失败。
                            if routeValidationDeadline == nil {
                                routeValidationDeadline = now.addingTimeInterval(confirmationTimeout)
                            }
                            if let until = routeValidationDeadline, now < until {
                                updateCleanup(snapshot)
                                return
                            }
                            throw error
                        }
                    }
                } else {
                    // 只相信当前枚举中仍存在的句柄；断开的旧 ID 不能证明声音还在原路由。
                    let presentIDs = Set(snapshot.outputs.map(\.id))
                    let routeIDs = confirmedDeviceIDs(confirmed, in: snapshot).intersection(presentIDs)
                    let knownIDs = Set(snapshot.outputs.map(\.id)).union(routeIDs)
                    let reportedIDs = try hardware.activePlaybackDeviceIDs()
                    let activeIDs = reportedIDs.filter { knownIDs.contains($0) }
                    let localPlayback = localPlaybackOnConfirmedRoute?() == true
                    let userSelecting = isUserSelectingOutput?() == true
                    if !userSelecting, !localPlayback, !reportedIDs.isEmpty, activeIDs.isEmpty,
                       reportedIDs.allSatisfy({ !presentIDs.contains($0) }) {
                        // 进程仍指着已经不在枚举中的旧句柄：先等 HAL 完成换号，不能把换号当成外部切换。
                        if routeHandleSettleDeadline == nil {
                            routeHandleSettleDeadline = now.addingTimeInterval(confirmationTimeout)
                        }
                        if let until = routeHandleSettleDeadline, now < until {
                            updateCleanup(snapshot)
                            return
                        }
                    }
                    routeHandleSettleDeadline = nil
                    if !userSelecting,
                       localPlayback || (!activeIDs.isEmpty && !Set(activeIDs).isDisjoint(with: routeIDs)) {
                        // Apple 耳机接入时可能只改写默认输出；真实进程仍播放原路由时恢复默认，不动会话。
                        switch preemption.decide(stealingUID: selectedOutput?.uid ?? "", at: now) {
                        case .restore:
                            state.actualOutput = confirmed.output
                            try hardware.select(confirmed.output.id)
                            state.completedSteps = ["已按真实播放通道恢复被抢占的默认输出"]
                            state.warning = nil
                            warningDeviceUID = nil
                            updateCleanup(snapshot)
                            return
                        case .yield(let message):
                            // 连续快速抢占说明系统或耳机在坚持自己的路由；此时跟随真实输出，
                            // 由正常收尾流程释放旧组合，避免留下“清理残留设备”的半失败状态。
                            state.warning = message
                            warningDeviceUID = selectedOutput?.uid
                            updateCleanup(snapshot)
                        }
                    } else {
                        preemption.reset()
                    }
                    // 媒体已经离开旧路由，先停止旧会话；随后只围绕真实媒体设备收尾。
                    try beforeChanging?()
                    guard let actual = state.actualOutput, !actual.isAggregate,
                          try hardware.isAlive(actual.id) else {
                        if let actual = state.actualOutput, !actual.isAggregate,
                           externalAdoptionDeadline == nil {
                            externalAdoptionDeadline = now.addingTimeInterval(confirmationTimeout)
                            updateCleanup(snapshot)
                            return
                        }
                        if let until = externalAdoptionDeadline, now < until {
                            updateCleanup(snapshot)
                            return
                        }
                        throw AudioFailure("当前媒体输出不可用或不支持 APP 接管")
                    }
                    externalAdoptionDeadline = nil
                    let systemOutput = snapshot.outputs.first { $0.id == systemSelected }
                    if systemOutput?.isAuralMultiOutput == true {
                        // 上一轮 Aural 组合仍占着提示音，复用显式单设备切换把两条默认输出和资源一起收尾。
                        request(.single(actual.uid), at: now)
                        return
                    }
                    // 外部选择是真实事实，不是 Aural 的失败请求。停止旧会话后跟随媒体输出，
                    // 不改写提示音，也不把两条默认设备不同当作错误。
                    let canReleaseOldGroup = resources.route != nil && systemSelected != resources.route?.deviceID
                    let oldGroupReleased = canReleaseOldGroup ? try resources.release() : false
                    if canReleaseOldGroup && !oldGroupReleased {
                        externalReleaseDeadline = now.addingTimeInterval(confirmationTimeout)
                    }
                    state.desired = nil
                    state.configured = nil
                    state.configuredOutputs = []
                    state.unavailableMemberUIDs = []
                    state.confirmed = ConfirmedOutputRoute(intent: .single(actual.uid), output: actual, aggregate: nil)
                    state.phase = .stable
                    state.error = nil
                    state.completedSteps = []
                    if oldGroupReleased {
                        // 释放改变了设备枚举；展示和资源清单必须使用释放后的同一份事实。
                        observe(try hardware.snapshot(), at: now)
                        return
                    }
                }
            } else if let actual = state.actualOutput, !actual.isAggregate, try hardware.isAlive(actual.id) {
                externalAdoptionDeadline = nil
                let systemOutput = snapshot.outputs.first { $0.id == systemSelected }
                if systemOutput?.isAuralMultiOutput == true {
                    // 应用重启后旧组合可能只剩提示音引用；媒体已在真实设备上，直接沿用同一恢复流程。
                    request(.single(actual.uid), at: now)
                    return
                }
                // 启动时只观察既有媒体输出，不要求用户把系统提示音也改到同一台设备。
                state.confirmed = ConfirmedOutputRoute(intent: .single(actual.uid), output: actual, aggregate: nil)
            }
            updateCleanup(snapshot)
        } catch { failReadingActual(error, at: now) }
    }

    /// 明确结束模式时保留当前唯一设备；组合则请求原来那台设备，不猜断连后的替代目标。
    public func stop(at now: Date = Date()) {
        guard !state.phase.isBusy else { return }
        if let route = resources.route {
            if let actual = state.actualOutput, actual.id != route.deviceID, !actual.isAggregate {
                request(.single(actual.uid), at: now)
            } else { request(.single(route.previousOutputUID), at: now) }
        }
        else if let actual = state.actualOutput, !actual.isAggregate { request(.single(actual.uid), at: now) }
        else { failReadingActual(AudioFailure("请先明确选择一台真实输出设备"), at: now) }
    }

    public func dismissError() {
        guard !state.phase.isBusy, state.pendingCleanup.isEmpty else { return }
        state.error = nil
        state.warning = nil
        warningDeviceUID = nil
        // 清除提示不是重新接管；从真实默认输出重新观察，APP 仍需明确重新应用。
        state.phase = .stable
    }

    private func activate(_ intent: OutputRoutingIntent, at now: Date) throws {
        let snapshot = try hardware.snapshot()
        resources.recordUnmanagedOutputs(in: snapshot)
        guard try resources.cleanupUnmanagedOutputs() else {
            step = .cleanup(try member(intent.memberUIDs[0], in: snapshot))
            deadline = now.addingTimeInterval(confirmationTimeout)
            state.phase = .awaitingHAL
            return
        }
        let target: AudioOutput
        if intent.memberUIDs.count > 1 {
            try resources.prepare(outputUIDs: intent.memberUIDs)
            guard let route = resources.route else { throw AudioFailure("组合资源未建立") }
            state.completedSteps.append("已创建并校验新组合")
            target = AudioOutput(id: route.deviceID, uid: route.uid, name: "Aural 多设备输出", transport: kAudioDeviceTransportTypeAggregate)
        } else {
            target = try member(intent.memberUIDs[0], in: snapshot)
        }
        step = .activation(target)
        deadline = now.addingTimeInterval(confirmationTimeout)
        let systemSelected = try hardware.selectedSystemOutputID()
        if snapshot.selectedID != target.id || systemSelected != target.id {
            try hardware.select(target.id)
            state.completedSteps.append("已请求目标输出")
        }
        state.phase = .awaitingHAL
    }

    private func member(_ uid: String, in snapshot: SystemAudioSnapshot) throws -> AudioOutput {
        guard let output = snapshot.outputs.first(where: { $0.uid == uid }), output.supportsSimultaneousOutput,
              try hardware.isAlive(output.id) else { throw AudioFailure("所选真实输出已断开或不可用") }
        return output
    }

    private func validateIntent(_ intent: OutputRoutingIntent, snapshot: SystemAudioSnapshot) throws {
        let uids = intent.memberUIDs
        guard !uids.isEmpty, Set(uids).count == uids.count else { throw AudioFailure("请至少保留一台不重复的输出设备") }
        for uid in uids { _ = try member(uid, in: snapshot) }
    }

    public func observationFailed(_ error: Error) {
        fail(error, snapshot: nil, at: Date())
    }

    /// 仅在已有切换期限内等待 HAL 枚举收敛；不延长期限，不重发硬件写入，不确认旧快照。
    public func deferPendingObservation(_ error: Error, at now: Date) -> Bool {
        guard error is AudioSnapshotPending, state.phase.isBusy,
              let deadline, now < deadline else { return false }
        state.phase = .awaitingHAL
        return true
    }

    private func fail(_ error: Error, snapshot: SystemAudioSnapshot?, systemOutputID: AudioDeviceID? = nil, at now: Date) {
        latestSnapshot = snapshot
        state.actualSystemOutputID = systemOutputID
        state.phase = .failed
        state.confirmed = nil
        step = nil
        deadline = nil
        state.error = error.localizedDescription
        if let snapshot {
            state.actualOutput = snapshot.outputs.first { $0.id == snapshot.selectedID }
            updateCleanup(snapshot)
        } else {
            state.actualOutput = nil
            // 快照失败也不能丢失本进程持有的资源所有权。
            var unresolved = state.pendingCleanup
            for output in ownedOutputs() + resources.unresolvedUnmanagedOutputs where !unresolved.contains(where: { $0.uid == output.uid }) {
                unresolved.append(output)
            }
            state.pendingCleanup = unresolved
        }
        // 失败即停止本次操作链。不能在已经观察到外部输出或资源错误后继续执行旧队列。
        if state.queued != nil {
            state.error = "\(error.localizedDescription)；已取消等待中的后续切换"
            state.queued = nil
        }
    }

    private func ownedOutputs() -> [AudioOutput] {
        guard let route = resources.route else { return [] }
        return [AudioOutput(id: route.deviceID, uid: route.uid, name: "Aural 多设备输出", transport: kAudioDeviceTransportTypeAggregate)]
    }

    private func updateCleanup(_ snapshot: SystemAudioSnapshot) {
        let owned = !state.phase.isBusy && state.phase != .awaitingMembers
            && state.confirmed?.aggregate?.uid != resources.route?.uid ? ownedOutputs() : []
        state.pendingCleanup = owned + resources.unmanagedOutputs(in: snapshot)
    }

    /// 只在用户已经勾选的设备集合内继续播放，不选替代设备，也不把系统自动切走当成用户改意图。
    private func reconcileConfiguredMembers(_ snapshot: SystemAudioSnapshot, at now: Date) throws -> Bool {
        guard let configured = state.configured, configured.isSimultaneous,
              state.confirmed?.intent.isSimultaneous == true || state.phase == .awaitingMembers else { return false }
        var available: [String] = []
        var unavailable: [String] = []
        for uid in configured.memberUIDs {
            let output = snapshot.outputs.first(where: { $0.uid == uid })
            let alive = try output.map { try hardware.isAlive($0.id) } ?? false
            let worn: Bool?
            if let output, alive { worn = try hardware.isWorn(output.id) }
            else { worn = nil }
            if alive, worn != false {
                if memberRecoveryRequiresEvidence.contains(uid), worn != true {
                    unavailable.append(uid)
                    continue
                }
                memberRecoveryRequiresEvidence.remove(uid)
                if state.unavailableMemberUIDs.contains(uid) {
                    if let since = memberRecoverySince[uid], now.timeIntervalSince(since) >= 0.5 {
                        available.append(uid)
                    } else {
                        if memberRecoverySince[uid] == nil { memberRecoverySince[uid] = now }
                        unavailable.append(uid)
                    }
                } else { available.append(uid) }
            } else {
                memberRecoverySince.removeValue(forKey: uid)
                memberRecoveryRequiresEvidence.remove(uid)
                unavailable.append(uid)
            }
        }
        state.unavailableMemberUIDs = unavailable
        if (!unavailable.isEmpty || state.phase == .awaitingMembers
            || available != state.confirmed?.intent.memberUIDs), isUserSelectingOutput?() == true,
           let actual = state.actualOutput, !actual.isAggregate,
           actual.id != state.confirmed?.output.id, try hardware.isAlive(actual.id) {
            // 系统界面的明确选择仍优先；不因保留了旧勾选而反复改回组合。
            performRequest(.single(actual.uid), at: now, updatesConfiguration: true)
            return true
        }
        guard !available.isEmpty else {
            if state.phase != .awaitingMembers {
                try beforeChanging?()
                state.confirmed = nil
                state.desired = configured
                state.phase = .awaitingMembers
                state.error = nil
                state.warning = nil
                preemption.reset()
                warningDeviceUID = nil
            }
            updateCleanup(snapshot)
            return true
        }
        if state.phase == .awaitingMembers || available != state.confirmed?.intent.memberUIDs {
            // 沿用正常资源释放/创建/读回确认，不再在旧组合上反复抢默认输出。
            performRequest(.simultaneous(available), at: now, updatesConfiguration: false)
            return true
        }
        if let confirmed = state.confirmed, let actual = state.actualOutput,
           unavailable.contains(actual.uid), actual.id != confirmed.output.id {
            // 摘耳期间系统可能再次选中不可用成员；只恢复已验证的剩余路由，不计作设备抢占。
            if confirmed.aggregate != nil { try resources.validate(snapshot: snapshot) }
            step = .activation(confirmed.output)
            state.desired = confirmed.intent
            deadline = now.addingTimeInterval(confirmationTimeout)
            state.phase = .awaitingHAL
            try hardware.select(confirmed.output.id)
            observe(try hardware.snapshot(), at: now)
            return true
        }
        return false
    }

    /// 设备身份以 UID 为准；快照中同一 UID 的新句柄才是当前真实播放设备。
    private func confirmedDeviceIDs(_ confirmed: ConfirmedOutputRoute,
                                    in snapshot: SystemAudioSnapshot) -> Set<AudioDeviceID> {
        guard let aggregate = confirmed.aggregate else {
            return [snapshot.outputs.first { $0.uid == confirmed.output.uid }?.id ?? confirmed.output.id]
        }
        var result: Set<AudioDeviceID> = [aggregate.deviceID]
        if let current = snapshot.outputs.first(where: { $0.uid == aggregate.uid }) {
            result.insert(current.id)
        }
        for member in aggregate.outputs {
            if let current = snapshot.outputs.first(where: { $0.uid == member.uid }) {
                result.insert(current.id)
            }
        }
        return result
    }

    /// 蓝牙重连后 AudioDeviceID 会变化，但物理设备 UID 不变。
    /// 已确认路由和控制目标都必须换到新句柄，不能把同一台耳机误判成外部切换。
    private func refreshConfirmedHandles(in snapshot: SystemAudioSnapshot) {
        guard let confirmed = state.confirmed else { return }
        let output = snapshot.outputs.first { $0.uid == confirmed.output.uid } ?? confirmed.output
        var aggregate = confirmed.aggregate
        if let route = aggregate {
            let aggregateOutput = snapshot.outputs.first { $0.uid == route.uid }
            let members = route.outputs.map { member in
                snapshot.outputs.first { $0.uid == member.uid } ?? member
            }
            if let aggregateOutput {
                aggregate = MultiOutputRoute(deviceID: aggregateOutput.id, uid: route.uid,
                                             outputs: members, mainOutputUID: route.mainOutputUID,
                                             previousOutputUID: route.previousOutputUID,
                                             sampleRate: route.sampleRate)
            } else if members != route.outputs {
                aggregate = MultiOutputRoute(deviceID: route.deviceID, uid: route.uid,
                                             outputs: members, mainOutputUID: route.mainOutputUID,
                                             previousOutputUID: route.previousOutputUID,
                                             sampleRate: route.sampleRate)
            }
        }
        if output != confirmed.output || aggregate != confirmed.aggregate {
            state.confirmed = ConfirmedOutputRoute(intent: confirmed.intent, output: output, aggregate: aggregate)
        }
    }

    private func failReadingActual(_ operationError: Error, at now: Date) {
        if deferPendingObservation(operationError, at: now) { return }
        do {
            let snapshot = try hardware.snapshot()
            resources.recordUnmanagedOutputs(in: snapshot)
            if let unavailable = operationError as? MultiOutputMembersUnavailable,
               let configured = state.configured, configured.isSimultaneous,
               !unavailable.memberUIDs.isEmpty,
               Set(unavailable.memberUIDs).isSubset(of: Set(configured.memberUIDs)),
               state.phase != .failed {
                // 稳态、创建后校验、激活确认三个入口都回到同一成员续播流程，不能各自锁存失败。
                do {
                    if state.confirmed != nil { try beforeChanging?() }
                    for uid in unavailable.memberUIDs {
                        memberRecoverySince.removeValue(forKey: uid)
                        if let output = snapshot.outputs.first(where: { $0.uid == uid }),
                           try hardware.isAlive(output.id), try hardware.isWorn(output.id) != true {
                            memberRecoveryRequiresEvidence.insert(uid)
                        }
                    }
                    state.unavailableMemberUIDs = configured.memberUIDs.filter {
                        state.unavailableMemberUIDs.contains($0) || unavailable.memberUIDs.contains($0)
                    }
                    state.confirmed = nil
                    state.desired = configured
                    state.phase = .awaitingMembers
                    state.actualOutput = snapshot.outputs.first { $0.id == snapshot.selectedID }
                    state.error = nil
                    state.warning = nil
                    step = nil
                    deadline = nil
                    preemption.reset()
                    warningDeviceUID = nil
                    _ = try reconcileConfiguredMembers(snapshot, at: now)
                    return
                } catch {
                    fail(error, snapshot: snapshot, at: now)
                    return
                }
            }
            do {
                let system = try hardware.selectedSystemOutputID()
                fail(operationError, snapshot: snapshot, systemOutputID: system, at: now)
            } catch {
                fail(AudioFailure("\(operationError.localizedDescription)；无法确认提示音输出：\(error.localizedDescription)"),
                     snapshot: snapshot, at: now)
            }
        } catch {
            fail(AudioFailure("\(operationError.localizedDescription)；无法读回实际输出：\(error.localizedDescription)"),
                 snapshot: nil, at: now)
        }
    }

    private func drainQueue(at now: Date) {
        guard let queued = state.queued else { return }
        state.queued = nil
        request(queued, at: now)
    }
}
