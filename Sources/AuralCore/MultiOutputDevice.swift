import CoreAudio
import Foundation

/// 某次真实 HAL 校验已经确认成员不可用，必须携带该次证据，不能立即重读并把抖动误当恢复。
public struct MultiOutputMembersUnavailable: LocalizedError {
    public let memberUIDs: [String]
    public init(_ memberUIDs: [String]) { self.memberUIDs = memberUIDs }
    public var errorDescription: String? { "部分已选设备的音频通道暂不可用" }
}

/// 系统多输出由 HAL 镜像音频，不创建 Process Tap，也不接管或重放各应用的样本。
public struct MultiOutputPlan {
    public let outputs: [AudioOutput]
    public let mainOutputUID: String
    public let sampleRate: Double

    public init(outputs: [AudioOutput], sampleRates: [String: Double]) throws {
        guard !outputs.isEmpty, Set(outputs.map(\.uid)).count == outputs.count,
              Set(outputs.map(\.id)).count == outputs.count else {
            throw AudioFailure("请至少选择一台输出设备")
        }
        guard outputs.allSatisfy(\.supportsSimultaneousOutput) else {
            throw AudioFailure("同时输出仅支持真实硬件设备，请勿选择聚合或虚拟设备")
        }
        guard let main = preferredMainOutput(in: outputs),
              let mainRate = sampleRates[main.uid], mainRate.isFinite, mainRate > 0,
              outputs.allSatisfy({
                  guard let rate = sampleRates[$0.uid] else { return false }
                  return rate.isFinite && rate > 0
              }) else {
            throw AudioFailure("无法读取所选设备的采样率，请重新连接后再试")
        }
        self.outputs = outputs
        mainOutputUID = main.uid
        // 聚合设备采用主设备时钟；从设备可使用不同采样率，由 HAL 在镜像时完成转换。
        sampleRate = mainRate
    }

    public func description(uid: String) -> [String: Any] {
        // 多输出群组必须把主设备列在首位；蓝牙不适合做时钟源，优先使用内置扬声器。
        let orderedOutputs = [outputs.first { $0.uid == mainOutputUID }!]
            + outputs.filter { $0.uid != mainOutputUID }
        return [
            // 这个名称会进入 macOS 输出设备列表，必须直接说明它来自 Aural。
            kAudioAggregateDeviceNameKey: "Aural 多设备输出",
            kAudioAggregateDeviceUIDKey: uid,
            kAudioAggregateDeviceIsPrivateKey: 0,
            // 与系统“多输出设备”一致；该模式才会让群组中的设备同时播放。
            kAudioAggregateDeviceIsStackedKey: 1,
            kAudioAggregateDeviceMainSubDeviceKey: mainOutputUID,
            // 主音频设备已提供时基；不能把 AudioDevice UID 当作独立 AudioClockDevice UID。
            kAudioAggregateDeviceSubDeviceListKey: orderedOutputs.map { output in
                // HAL 要求 CFNumber；Swift Bool 会桥接成 CFBoolean，实际会被忽略为未启用。
                [kAudioSubDeviceUIDKey: output.uid,
                 kAudioSubDeviceDriftCompensationKey: output.uid == mainOutputUID ? 0 : 1] as [String: Any]
            }
        ]
    }
}

/// 多输出群组优先由内置扬声器提供稳定时基，避免蓝牙可变延迟影响其他成员。
private func preferredMainOutput(in outputs: [AudioOutput]) -> AudioOutput? {
    outputs.first { $0.transport == kAudioDeviceTransportTypeBuiltIn }
        ?? outputs.first { !$0.isBluetooth }
        ?? outputs.first
}

/// 创建成功只代表获得句柄，必须再读取 HAL 实际采用的镜像、成员和时钟配置。
public struct MultiOutputConfiguration {
    public let mirrorsOutputs: Bool
    public let mainOutputUID: String
    public let outputUIDs: [String]
    public let activeOutputUIDs: [String]
    public let driftCompensatedUIDs: Set<String>

    public init(composition: [String: Any], activeOutputUIDs: [String]) throws {
        guard let stacked = composition[kAudioAggregateDeviceIsStackedKey] as? NSNumber,
              let main = composition[kAudioAggregateDeviceMainSubDeviceKey] as? String,
              let members = composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]] else {
            throw AudioFailure("无法确认系统多输出设备的实际配置")
        }
        var uids: [String] = []
        var compensated: Set<String> = []
        for member in members {
            guard let uid = member[kAudioSubDeviceUIDKey] as? String,
                  let drift = member[kAudioSubDeviceDriftCompensationKey] as? NSNumber else {
                throw AudioFailure("无法确认系统多输出成员的时钟配置")
            }
            uids.append(uid)
            if drift.intValue != 0 { compensated.insert(uid) }
        }
        mirrorsOutputs = stacked.intValue == 1
        mainOutputUID = main
        outputUIDs = uids
        self.activeOutputUIDs = activeOutputUIDs
        driftCompensatedUIDs = compensated
    }

    public func validate(outputs: [AudioOutput]) throws {
        let expected = Set(outputs.map(\.uid))
        guard let expectedMain = preferredMainOutput(in: outputs)?.uid,
              mirrorsOutputs, mainOutputUID == expectedMain else {
            throw AudioFailure("系统未确认镜像输出或时钟配置，请重新启动同时输出")
        }
        guard outputUIDs.count == outputs.count, Set(outputUIDs) == expected else {
            throw AudioFailure("系统多输出未启用全部所选设备，请重新连接后再试")
        }
        guard driftCompensatedUIDs == Set(outputs.filter { $0.uid != expectedMain }.map(\.uid)) else {
            throw AudioFailure("系统未启用从设备的时钟漂移补偿，请重新启动同时输出")
        }
        let active = Set(activeOutputUIDs)
        guard active.count == activeOutputUIDs.count, active.isSubset(of: expected) else {
            throw AudioFailure("系统多输出的活动成员配置异常")
        }
        let missing = outputs.filter { !active.contains($0.uid) }.map(\.uid)
        if !missing.isEmpty { throw MultiOutputMembersUnavailable(missing) }
    }
}

public extension AudioOutput {
    var isAggregate: Bool { transport == kAudioDeviceTransportTypeAggregate }

    /// 名称可被用户修改或与第三方设备重名，只用本应用的 UID 命名空间与设备类型识别。
    var isAuralMultiOutput: Bool { isAggregate && uid.hasPrefix("local.aural.multi.") }

    var supportsSimultaneousOutput: Bool {
        // 只接收已知硬件传输；不把未知、虚拟设备或已有聚合设备自动展开成另一套路径。
        let hardware: Set<UInt32> = [kAudioDeviceTransportTypeBuiltIn, kAudioDeviceTransportTypeUSB,
            kAudioDeviceTransportTypeBluetooth, kAudioDeviceTransportTypeBluetoothLE,
            kAudioDeviceTransportTypeDisplayPort, kAudioDeviceTransportTypeHDMI,
            kAudioDeviceTransportTypeThunderbolt, kAudioDeviceTransportTypeFireWire, kAudioDeviceTransportTypePCI]
        return hardware.contains(transport) && !uid.isEmpty
    }
}

public struct MultiOutputRoute: Equatable {
    public let deviceID: AudioDeviceID
    public let uid: String
    public let outputs: [AudioOutput]
    public let mainOutputUID: String
    public let previousOutputUID: String
    public let sampleRate: Double
}

/// 把真实 HAL 操作集中在一个接口，测试可注入设备快照，不连接耳机或切换用户输出。
@MainActor
public struct MultiOutputHardware {
    public var snapshot: () throws -> SystemAudioSnapshot
    public var selectedSystemOutputID: () throws -> AudioDeviceID
    /// 只用于识别真实播放通道；默认输出被抢占但声音仍留在旧路由时不能误拆会话。
    public var activePlaybackDeviceIDs: () throws -> [AudioDeviceID] = { [] }
    /// 只使用设备公开的佩戴证据；未知不等于离线，非 Apple 设备不进入入耳检测。
    public var isWorn: (AudioDeviceID) throws -> Bool? = { _ in nil }
    public var sampleRate: (AudioDeviceID) throws -> Double
    public var isAlive: (AudioDeviceID) throws -> Bool
    public var configuration: (AudioDeviceID) throws -> MultiOutputConfiguration
    public var create: ([String: Any]) throws -> AudioDeviceID
    public var select: (AudioDeviceID) throws -> Void
    public var destroy: (AudioDeviceID) throws -> Void

    public static var live: Self {
        Self(snapshot: SystemAudio.snapshot, selectedSystemOutputID: SystemAudio.selectedSystemOutputID,
             activePlaybackDeviceIDs: AudioProcesses.activeOutputDeviceIDs,
             isWorn: AppleHeadphoneHAL.isWorn, sampleRate: {
            try HAL.read($0, HAL.address(kAudioDevicePropertyNominalSampleRate), initial: Double(0))
        }, isAlive: {
            try HAL.read($0, HAL.address(kAudioDevicePropertyDeviceIsAlive), initial: UInt32(0)) != 0
        }, configuration: { id in
            let composition: CFDictionary = try HAL.read(id, HAL.address(kAudioAggregateDevicePropertyComposition),
                                                         initial: [:] as CFDictionary)
            guard let dictionary = composition as? [String: Any] else {
                throw AudioFailure("系统多输出配置格式不合法")
            }
            let uids = try readActiveOutputUIDs(
                readActiveIDs: { try HAL.ids(id, HAL.address(kAudioAggregateDevicePropertyActiveSubDeviceList)) },
                readUID: { try HAL.string($0, kAudioDevicePropertyDeviceUID) }
            )
            return try MultiOutputConfiguration(composition: dictionary, activeOutputUIDs: uids)
        }, create: { description in
            let interval = AudioSwitchTrace.begin("CreateAggregate")
            defer { AudioSwitchTrace.end("CreateAggregate", interval) }
            var id: AudioDeviceID = 0
            try HAL.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "创建同时输出设备")
            return id
        }, select: { deviceID in
            let interval = AudioSwitchTrace.begin("SetDefaultOutput")
            defer { AudioSwitchTrace.end("SetDefaultOutput", interval) }
            try SystemAudio.requestSelection(deviceID)
        }, destroy: { deviceID in
            let interval = AudioSwitchTrace.begin("DestroyAggregate")
            defer { AudioSwitchTrace.end("DestroyAggregate", interval) }
            try HAL.check(AudioHardwareDestroyAggregateDevice(deviceID), "释放同时输出设备")
        })
    }
}

/// 聚合成员重连时活动列表可能立即变化；只有仍存在的成员持续失败才报错。
func readActiveOutputUIDs(readActiveIDs: () throws -> [AudioObjectID],
                          readUID: (AudioObjectID) throws -> String) throws -> [String] {
    var activeIDs = try readActiveIDs()
    for attempt in 0..<2 {
        do {
            return try activeIDs.map { try readUID($0) }
        } catch {
            // 每次失败都重新取活动列表，不能继续使用已经过期的成员 ID 数组。
            activeIDs = try readActiveIDs()
            if attempt == 1 { throw error }
        }
    }
    throw AudioFailure("无法读取同时输出的活动成员")
}

/// 只拥有聚合资源，不决定系统默认输出；选择、确认、外部变化都由唯一协调器管理。
@MainActor
public final class MultiOutputDevice {
    public private(set) var route: MultiOutputRoute?
    public private(set) var requiresCleanup = false
    /// 本次操作首次发现、尚未成功确认消失的非自有资源；读取失败不能把它们当成已释放。
    public private(set) var unresolvedUnmanagedOutputs: [AudioOutput] = []
    private let hardware: MultiOutputHardware
    private var destroyRequests: Set<String> = []
    public var hasPendingRelease: Bool { !destroyRequests.isEmpty }

    /// 只有新的明确操作才允许再次请求销毁；等待 HAL 移除期间绝不重复发 destroy。
    public func beginExplicitChange() { destroyRequests.removeAll() }

    public init(hardware: MultiOutputHardware) { self.hardware = hardware }

    public func unmanagedOutputs(in snapshot: SystemAudioSnapshot) -> [AudioOutput] {
        snapshot.outputs.filter { $0.isAuralMultiOutput && $0.uid != route?.uid }
    }

    /// 每次成功读到完整枚举就登记发现事实；只有成功枚举才能确认旧记录已经消失。
    public func recordUnmanagedOutputs(in snapshot: SystemAudioSnapshot) {
        if let owned = route, destroyRequests.contains(owned.uid),
           !snapshot.outputs.contains(where: { $0.uid == owned.uid }) {
            // 只确认本实例已经请求过销毁的资源消失；不把刚创建尚未注册的设备当作已释放。
            route = nil
            requiresCleanup = false
        }
        unresolvedUnmanagedOutputs = unmanagedOutputs(in: snapshot)
        // 完整枚举已确认消失的 UID 不再占用等待计时，不把旧销毁请求永久留在轮询里。
        destroyRequests.formIntersection(Set(snapshot.outputs.map(\.uid)))
    }

    /// 资源层的完整枚举统一经过这里，包含销毁后的确认读取，避免遗漏刚发现的其他残留。
    private func readSnapshot() throws -> SystemAudioSnapshot {
        let snapshot = try hardware.snapshot()
        recordUnmanagedOutputs(in: snapshot)
        return snapshot
    }

    @discardableResult
    public func cleanupUnmanagedOutputs() throws -> Bool {
        _ = try readSnapshot()
        for output in unresolvedUnmanagedOutputs {
            let fresh = try readSnapshot()
            guard let current = fresh.outputs.first(where: { $0.uid == output.uid }) else {
                destroyRequests.remove(output.uid)
                unresolvedUnmanagedOutputs.removeAll { $0.uid == output.uid }
                continue
            }
            guard current.id == output.id, current.isAuralMultiOutput,
                  fresh.selectedID != current.id, try hardware.selectedSystemOutputID() != current.id else {
                throw AudioFailure("残留组合仍被系统使用，请明确选择真实输出后再释放")
            }
            if !destroyRequests.contains(current.uid) {
                try hardware.destroy(current.id)
                destroyRequests.insert(current.uid)
            }
            if try readSnapshot().outputs.contains(where: { $0.uid == current.uid }) { return false }
            destroyRequests.remove(current.uid)
            unresolvedUnmanagedOutputs.removeAll { $0.uid == current.uid }
        }
        return true
    }

    /// 创建与校验不改变默认输出。创建后的任何失败都保留句柄，绝不隐式恢复另一条路由。
    public func prepare(outputUIDs: [String]) throws {
        guard route == nil else { throw AudioFailure("旧组合尚未释放") }
        let snapshot = try readSnapshot()
        guard unmanagedOutputs(in: snapshot).isEmpty else { throw AudioFailure("请先释放残留组合设备") }
        guard let previous = snapshot.outputs.first(where: { $0.id == snapshot.selectedID }) else {
            throw AudioFailure("无法确认当前系统输出")
        }
        let outputs = try outputUIDs.map { uid in
            guard let output = snapshot.outputs.first(where: { $0.uid == uid }),
                  try hardware.isAlive(output.id) else { throw AudioFailure("所选设备已断开，请重新选择") }
            return output
        }
        guard outputs.count > 1 else { throw AudioFailure("单成员模式应直接使用真实设备") }
        var rates: [String: Double] = [:]
        for output in outputs { rates[output.uid] = try hardware.sampleRate(output.id) }
        let plan = try MultiOutputPlan(outputs: outputs, sampleRates: rates)
        let uid = "local.aural.multi.\(UUID().uuidString)"
        let id = try hardware.create(plan.description(uid: uid))
        route = MultiOutputRoute(deviceID: id, uid: uid, outputs: outputs, mainOutputUID: plan.mainOutputUID,
                                 previousOutputUID: previous.uid, sampleRate: plan.sampleRate)
        do { try validate(snapshot: readSnapshot()) }
        catch { requiresCleanup = true; throw error }
    }

    /// 只能释放已经离开媒体和提示音默认输出的聚合；不在释放函数里擅自切换设备。
    @discardableResult
    public func release() throws -> Bool {
        guard let route else { return true }
        do {
            let snapshot = try readSnapshot()
            if let current = snapshot.outputs.first(where: { $0.uid == route.uid }) {
                guard current.id == route.deviceID, snapshot.selectedID != current.id,
                      try hardware.selectedSystemOutputID() != current.id else {
                    throw AudioFailure("组合仍是系统输出，尚未释放")
                }
                if !destroyRequests.contains(route.uid) {
                    try hardware.destroy(route.deviceID)
                    destroyRequests.insert(route.uid)
                }
            }
            // Destroy 返回后 HAL 枚举可能暂时仍包含该 UID；这是等待确认，不是立即失败。
            if try readSnapshot().outputs.contains(where: { $0.uid == route.uid }) { return false }
            destroyRequests.remove(route.uid)
            self.route = nil
            requiresCleanup = false
            return true
        } catch {
            // 枚举尚未收敛不是资源释放失败；保留销毁请求，下一次观察只确认移除，不重复销毁。
            if !(error is AudioSnapshotPending) { requiresCleanup = true }
            throw error
        }
    }

    public func validate(snapshot: SystemAudioSnapshot) throws {
        guard let route, !requiresCleanup else { throw AudioFailure("组合资源尚未就绪或待释放") }
        guard snapshot.outputs.contains(where: { $0.id == route.deviceID && $0.uid == route.uid }),
              try hardware.sampleRate(route.deviceID) == route.sampleRate else {
            throw AudioFailure("组合设备或主时钟已改变，请重新配置")
        }
        for member in route.outputs {
            guard snapshot.outputs.contains(where: { $0.uid == member.uid && $0.id == member.id }),
                  try hardware.isAlive(member.id) else {
                throw MultiOutputMembersUnavailable([member.uid])
            }
            let rate = try hardware.sampleRate(member.id)
            guard rate.isFinite, rate > 0,
                  member.uid != route.mainOutputUID || rate == route.sampleRate else {
                throw AudioFailure("同时输出成员的时钟无效，请重新配置")
            }
        }
        try hardware.configuration(route.deviceID).validate(outputs: route.outputs)
    }

    /// 蓝牙重连会换 AudioDeviceID，但聚合和成员的 UID 不变。
    /// 只有全部成员都仍在枚举中时才刷新句柄；成员短暂消失时保留旧记录，交由 validate 的等待期限处理。
    @discardableResult
    public func refreshHandles(snapshot: SystemAudioSnapshot) -> Bool {
        guard let route else { return true }
        guard let aggregate = snapshot.outputs.first(where: { $0.uid == route.uid }) else { return false }
        var members: [AudioOutput] = []
        for member in route.outputs {
            guard let current = snapshot.outputs.first(where: { $0.uid == member.uid }) else { return false }
            members.append(current)
        }
        self.route = MultiOutputRoute(deviceID: aggregate.id, uid: route.uid,
                                      outputs: members, mainOutputUID: route.mainOutputUID,
                                      previousOutputUID: route.previousOutputUID,
                                      sampleRate: route.sampleRate)
        return true
    }
}
