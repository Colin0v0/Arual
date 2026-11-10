import CoreAudio
import Foundation

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
            kAudioAggregateDeviceNameKey: "Aural 同时输出",
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
        guard outputUIDs.count == outputs.count, Set(outputUIDs) == expected,
              activeOutputUIDs.count == outputs.count, Set(activeOutputUIDs) == expected else {
            throw AudioFailure("系统多输出未启用全部所选设备，请重新连接后再试")
        }
        guard driftCompensatedUIDs == Set(outputs.filter { $0.uid != expectedMain }.map(\.uid)) else {
            throw AudioFailure("系统未启用从设备的时钟漂移补偿，请重新启动同时输出")
        }
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
    public var sampleRate: (AudioDeviceID) throws -> Double
    public var isAlive: (AudioDeviceID) throws -> Bool
    public var configuration: (AudioDeviceID) throws -> MultiOutputConfiguration
    public var create: ([String: Any]) throws -> AudioDeviceID
    public var select: (AudioDeviceID) throws -> Void
    public var destroy: (AudioDeviceID) throws -> Void

    public static var live: Self {
        Self(snapshot: SystemAudio.snapshot, sampleRate: {
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
            var id: AudioDeviceID = 0
            try HAL.check(AudioHardwareCreateAggregateDevice(description as CFDictionary, &id), "创建同时输出设备")
            return id
        }, select: SystemAudio.select, destroy: {
            try HAL.check(AudioHardwareDestroyAggregateDevice($0), "释放同时输出设备")
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

@MainActor
public final class MultiOutputDevice {
    public private(set) var route: MultiOutputRoute?
    public private(set) var requiresCleanup = false
    private let hardware: MultiOutputHardware

    public init(hardware: MultiOutputHardware) { self.hardware = hardware }

    /// 重启后不会伪造上一轮的路由或原输出；未被本实例持有的设备单独列为待清理。
    public func unmanagedOutputs(in snapshot: SystemAudioSnapshot) -> [AudioOutput] {
        snapshot.outputs.filter { $0.isAuralMultiOutput && $0.uid != route?.uid }
    }

    /// 只在用户明确选择单设备或点击清理后调用。仍被系统选中的设备不能直接删除。
    public func cleanupUnmanagedOutputs() throws {
        let snapshot = try hardware.snapshot()
        let unmanaged = unmanagedOutputs(in: snapshot)
        guard !unmanaged.contains(where: { $0.id == snapshot.selectedID }) else {
            throw AudioFailure("上次的同时输出设备仍被系统选中，请先选择一台真实输出设备")
        }
        for output in unmanaged {
            // 每次释放前重读身份与默认输出，不能用旧 ID 误删重连设备或正在使用的输出。
            let fresh = try hardware.snapshot()
            guard let current = fresh.outputs.first(where: { $0.uid == output.uid }) else { continue }
            guard current.id == output.id, current.isAuralMultiOutput,
                  current.uid != route?.uid, fresh.selectedID != current.id else {
                throw AudioFailure("待清理设备的状态已改变，请重新选择输出后再清理")
            }
            try hardware.destroy(current.id)
        }
    }

    public func start(outputUIDs: [String]) throws {
        guard route == nil else { throw AudioFailure("请先结束当前同时输出") }
        let snapshot = try hardware.snapshot()
        guard unmanagedOutputs(in: snapshot).isEmpty else {
            throw AudioFailure("请先选择一台扬声器，再重新设置同时输出")
        }
        guard let previous = snapshot.outputs.first(where: { $0.id == snapshot.selectedID }) else {
            throw AudioFailure("无法确认原输出设备，未启动同时输出")
        }
        let outputs = try outputUIDs.map { uid in
            guard let output = snapshot.outputs.first(where: { $0.uid == uid }), try hardware.isAlive(output.id) else {
                throw AudioFailure("所选设备已断开，请重新选择")
            }
            return output
        }
        var rates: [String: Double] = [:]
        for output in outputs { rates[output.uid] = try hardware.sampleRate(output.id) }
        let plan = try MultiOutputPlan(outputs: outputs, sampleRates: rates)
        let uid = "local.aural.multi.\(UUID().uuidString)"
        let id = try hardware.create(plan.description(uid: uid))
        // 外部聚合设备不能作为“原输出”恢复，否则结束同时输出后会重新落回多设备输出。
        let previousOutputUID = previous.isAggregate ? outputs[0].uid : previous.uid
        // 创建后立即保留句柄。后续选择或清理失败时不能丢失仍需释放的设备。
        route = MultiOutputRoute(deviceID: id, uid: uid, outputs: outputs, mainOutputUID: plan.mainOutputUID,
                                 previousOutputUID: previousOutputUID, sampleRate: plan.sampleRate)
        do {
            // 校验新组合实际采用的采样率；不偷偷改硬件设置来凑齐格式。
            guard try hardware.sampleRate(id) == plan.sampleRate else {
                throw AudioFailure("系统多输出设备未采用所选采样率，未切换输出")
            }
            // 不把“创建成功”误报成“两台均已启用”，也不尝试改用另一种音频后端。
            try hardware.configuration(id).validate(outputs: outputs)
            try hardware.select(id)
        }
        catch {
            let failure = error.localizedDescription
            do { try stop() }
            catch { throw AudioFailure("\(failure)；清理同时输出失败：\(error.localizedDescription)") }
            throw AudioFailure(failure)
        }
    }

    /// 明确结束时恢复原输出；用户点选普通设备时使用其明确选择，而非猜测另一台设备。
    public func stop(selecting outputUID: String? = nil) throws {
        guard let route else { return }
        var aggregateAbsenceConfirmed = false
        do {
            let snapshot = try hardware.snapshot()
            var target: AudioOutput?
            if outputUID != nil || snapshot.selectedID == route.deviceID {
                let targetUID = outputUID ?? route.previousOutputUID
                guard let selectedTarget = snapshot.outputs.first(where: { $0.uid == targetUID }),
                      selectedTarget.id != route.deviceID, try hardware.isAlive(selectedTarget.id) else {
                    throw AudioFailure("原输出或所选设备已断开，请选择可用输出设备后结束同时输出")
                }
                target = selectedTarget
                // 先离开聚合设备，系统才允许释放当前默认输出。
                try hardware.select(selectedTarget.id)
            }
            try hardware.destroy(route.deviceID)
            // destroy 返回成功不等于 HAL 已移除设备；必须从新的枚举结果确认 UID 消失。
            let afterDestroy = try hardware.snapshot()
            aggregateAbsenceConfirmed = !afterDestroy.outputs.contains { $0.uid == route.uid }
            guard aggregateAbsenceConfirmed else {
                throw AudioFailure("系统未确认释放同时输出设备，请重试释放")
            }
            // 某些 macOS 版本会在销毁聚合设备后重新把默认输出切回蓝牙设备；释放完成后再确认一次目标。
            self.route = nil
            requiresCleanup = false
            if let target {
                try hardware.select(target.id)
                let verified = try hardware.snapshot()
                guard verified.selectedID == target.id else {
                    throw AudioFailure("系统未确认切换回所选输出，请重新选择设备")
                }
            }
        } catch {
            // 聚合设备已经释放后发生的目标切换失败不能再被误报成“仍需释放聚合设备”。
            requiresCleanup = !aggregateAbsenceConfirmed
            throw error
        }
    }

    @discardableResult
    public func reconcile(snapshot: SystemAudioSnapshot) throws -> Bool {
        guard let route, !requiresCleanup else { return false }
        // 成员状态与系统默认输出是并列事实，先记录断连，避免系统同时切走时吞掉错误。
        var memberFailure: Error?
        do {
            try validateMembers(route, snapshot: snapshot)
            try hardware.configuration(route.deviceID).validate(outputs: route.outputs)
        }
        catch { memberFailure = error }
        if snapshot.selectedID != route.deviceID {
            let selectedOutput = snapshot.outputs.first { $0.id == snapshot.selectedID }
            if memberFailure == nil, selectedOutput?.isBluetooth == true {
                // macOS 会在蓝牙耳机连接时自动切换默认输出；同时输出仍有效时恢复聚合设备，
                // 不能让新连接或重连的蓝牙设备直接拆掉用户正在使用的整条路由。
                try hardware.select(route.deviceID)
                return true
            }
            // 切到无关设备仍视为用户明确选择，只释放本进程设备，不覆盖那次选择。
            try stop()
            if let memberFailure { throw memberFailure }
            return false
        }
        if let memberFailure { throw memberFailure }
        return false
    }

    private func validateMembers(_ route: MultiOutputRoute, snapshot: SystemAudioSnapshot) throws {
        guard try hardware.sampleRate(route.deviceID) == route.sampleRate else {
            throw AudioFailure("同时输出设备的采样率已改变，请重新配置同时输出")
        }
        for member in route.outputs {
            guard let current = snapshot.outputs.first(where: { $0.uid == member.uid }),
                  current.id == member.id, try hardware.isAlive(current.id) else {
                throw AudioFailure("同时输出中的“\(member.name)”已断开，请重新选择设备")
            }
            let memberRate = try hardware.sampleRate(current.id)
            guard memberRate.isFinite, memberRate > 0 else {
                throw AudioFailure("无法读取“\(member.name)”的采样率，请重新连接后再试")
            }
            // 只有主设备必须与聚合设备保持同一采样率；其他成员可由 HAL 重采样。
            if member.uid == route.mainOutputUID, memberRate != route.sampleRate {
                throw AudioFailure("“\(member.name)”的主时钟采样率已改变，请重新配置同时输出")
            }
        }
    }
}
