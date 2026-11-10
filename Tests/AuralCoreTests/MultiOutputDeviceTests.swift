import CoreAudio
import Foundation
import Testing
@testable import AuralCore

@MainActor
struct MultiOutputDeviceTests {
    @Test func nativeDescriptionMirrorsAndUsesFirstClockWithoutCapturingAudio() throws {
        let outputs = Fixture.outputs
        let plan = try MultiOutputPlan(outputs: Array(outputs.prefix(2)), sampleRates: ["first": 48_000, "second": 48_000])
        let description = plan.description(uid: "fixture-multi")
        #expect(description[kAudioAggregateDeviceIsStackedKey] as? Int == 1)
        // Core Audio 明确读取 CFNumber，不能仅用 as? Bool 验证桥接后的数值相等。
        for key in [kAudioAggregateDeviceIsStackedKey, kAudioAggregateDeviceIsPrivateKey] {
            let flag = try #require(description[key] as? NSNumber)
            #expect(CFGetTypeID(flag) == CFNumberGetTypeID())
        }
        #expect(description[kAudioAggregateDeviceIsPrivateKey] as? Int == 0)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "first")
        #expect(description[kAudioAggregateDeviceClockDeviceKey] == nil)
        #expect(description[kAudioAggregateDeviceTapListKey] == nil)
        let children = try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(children.compactMap { $0[kAudioSubDeviceUIDKey] as? String } == ["first", "second"])
        #expect(children.compactMap { $0[kAudioSubDeviceDriftCompensationKey] as? Int } == [0, 1])
        for child in children {
            let flag = try #require(child[kAudioSubDeviceDriftCompensationKey] as? NSNumber)
            #expect(CFGetTypeID(flag) == CFNumberGetTypeID())
        }
    }

    @Test func builtInSpeakerIsTheStableMainDeviceForBluetoothGroup() throws {
        let outputs = [Fixture.outputs[0], Fixture.outputs[2]]
        let plan = try MultiOutputPlan(
            outputs: outputs,
            sampleRates: ["first": 48_000, "third": 48_000]
        )
        let description = plan.description(uid: "fixture-multi")
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == "third")
        let children = try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(children.compactMap { $0[kAudioSubDeviceUIDKey] as? String } == ["third", "first"])
        #expect(children.compactMap { $0[kAudioSubDeviceDriftCompensationKey] as? Int } == [0, 1])
    }

    @Test func mixedSampleRatesUseTheMainClockAndKeepEveryMember() throws {
        let outputs = [Fixture.outputs[0], Fixture.outputs[2]]
        let plan = try MultiOutputPlan(
            outputs: outputs,
            sampleRates: ["first": 48_000, "third": 44_100]
        )
        // 聚合设备以稳定主设备的采样率为准，不能继续沿用用户勾选顺序中的第一台。
        #expect(plan.mainOutputUID == "third")
        #expect(plan.sampleRate == 44_100)
        let children = try #require(plan.description(uid: "fixture")[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
        #expect(children.compactMap { $0[kAudioSubDeviceUIDKey] as? String } == ["third", "first"])
    }

    @Test func unconfirmedClockOrInactiveMemberIsRejectedBeforeSwitchingOutput() {
        for missingDrift in [false, true] {
            let fixture = Fixture()
            if missingDrift { fixture.omitDriftCompensation = true }
            else { fixture.inactiveUIDs.insert("second") }
            let device = MultiOutputDevice(hardware: fixture.hardware)
            #expect(throws: (any Error).self) { try device.start(outputUIDs: ["first", "second"]) }
            #expect(fixture.selections.isEmpty)
            #expect(fixture.destroyed == [99])
            #expect(device.route == nil)
        }
    }

    @Test func systemClockConfigurationIsRecheckedWhileRouteIsActive() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        fixture.omitDriftCompensation = true
        #expect(throws: (any Error).self) { try device.reconcile(snapshot: fixture.snapshot) }
        // 校验失败保留明确结束入口，不自动删除成员、切换设备或创建第二套后端。
        #expect(device.route?.deviceID == 99)
        #expect(fixture.creations.count == 1)
        #expect(fixture.selected == 99)
    }

    @Test func actualConfigurationRejectsStackingWrongClockAndDuplicateMembers() throws {
        let outputs = Array(Fixture.outputs.prefix(2))
        let plan = try MultiOutputPlan(outputs: outputs, sampleRates: ["first": 48_000, "second": 48_000])
        for scenario in 0..<4 {
            var composition = plan.description(uid: "fixture")
            var active = ["first", "second"]
            switch scenario {
            case 0: composition[kAudioAggregateDeviceIsStackedKey] = 0
            case 1: composition[kAudioAggregateDeviceMainSubDeviceKey] = "second"
            case 2: active = ["first", "first"]
            default:
                composition[kAudioAggregateDeviceSubDeviceListKey] = [
                    [kAudioSubDeviceUIDKey: "first", kAudioSubDeviceDriftCompensationKey: 0],
                    [kAudioSubDeviceUIDKey: "first", kAudioSubDeviceDriftCompensationKey: 1]
                ]
            }
            let configuration = try MultiOutputConfiguration(composition: composition, activeOutputUIDs: active)
            #expect(throws: (any Error).self) { try configuration.validate(outputs: outputs) }
        }
        #expect(throws: (any Error).self) {
            try MultiOutputConfiguration(composition: [:], activeOutputUIDs: [])
        }
    }

    @Test func activeMemberUIDReadRetriesAfterReconnect() throws {
        var activeLists: [[AudioObjectID]] = [[101, 102], [101, 103]]
        var uidReads = 0
        let uids = try readActiveOutputUIDs(
            readActiveIDs: { activeLists.removeFirst() },
            readUID: { id in
                uidReads += 1
                if id == 102 { throw AudioFailure("成员正在重连") }
                return "member-\(id)"
            }
        )

        // 第一次读到旧成员 102 后重连，重新枚举活动列表应使用新的成员 ID。
        #expect(uids == ["member-101", "member-103"])
        #expect(uidReads == 4)
    }

    @Test func persistentActiveMemberFailureStillThrows() {
        #expect(throws: (any Error).self) {
            try readActiveOutputUIDs(
                readActiveIDs: { [101] },
                readUID: { _ in throw AudioFailure("成员属性持续失败") }
            )
        }
    }

    @Test func previousSessionDevicesAreIdentifiedByUIDAndNeverReactivated() {
        let fixture = Fixture()
        let old = AudioOutput(id: 88, uid: "local.aural.multi.previous", name: "用户改过的名字",
                              transport: kAudioDeviceTransportTypeAggregate)
        let unrelated = AudioOutput(id: 87, uid: "third-party", name: "Aural 同时输出",
                                    transport: kAudioDeviceTransportTypeAggregate)
        fixture.otherOutputs = [old, unrelated]
        let device = MultiOutputDevice(hardware: fixture.hardware)
        #expect(device.unmanagedOutputs(in: fixture.snapshot) == [old])
        #expect(throws: (any Error).self) { try device.start(outputUIDs: ["first", "second"]) }
        #expect(fixture.creations.isEmpty)
        #expect(fixture.selections.isEmpty)
        fixture.selected = old.id
        #expect(throws: (any Error).self) { try device.cleanupUnmanagedOutputs() }
        #expect(fixture.destroyAttempts == 0)
        fixture.selected = 1
        do { try device.cleanupUnmanagedOutputs() }
        catch { Issue.record(error) }
        #expect(fixture.destroyed == [old.id])
        #expect(fixture.selections.isEmpty)
    }

    @Test func activeOwnedRouteIsNotClassifiedAsPreviousSessionResidue() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        #expect(device.unmanagedOutputs(in: fixture.snapshot).isEmpty)
        try device.cleanupUnmanagedOutputs()
        #expect(fixture.destroyed.isEmpty)
        #expect(device.route?.deviceID == fixture.selected)
    }

    @Test func invalidSelectionNeverCreatesADevice() {
        for uids in [[], ["first", "first"], ["first", "missing"]] {
            let fixture = Fixture()
            let device = MultiOutputDevice(hardware: fixture.hardware)
            #expect(throws: (any Error).self) { try device.start(outputUIDs: uids) }
            #expect(fixture.creations.isEmpty)
            #expect(fixture.selections.isEmpty)
        }
    }

    @Test func singleDeviceRouteIsAccepted() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first"])
        #expect(device.route?.outputs.map(\.uid) == ["first"])
        #expect(fixture.selected == 99)
        try device.stop()
        #expect(fixture.selections == [99, 1, 1])
        #expect(fixture.destroyed == [99])
        #expect(device.route == nil)
    }

    @Test func offlineDeviceDoesNotChangeSystemOutput() {
        let fixture = Fixture()
        fixture.offline.insert(2)
        let device = MultiOutputDevice(hardware: fixture.hardware)
        #expect(throws: (any Error).self) { try device.start(outputUIDs: ["first", "second"]) }
        #expect(fixture.creations.isEmpty)
        #expect(fixture.selected == 1)
    }

    @Test func mixedRatesStartAndOnlyRejectAChangedMainClock() throws {
        let fixture = Fixture()
        fixture.rates[2] = 44_100
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        #expect(device.route?.sampleRate == 48_000)
        #expect(device.route?.mainOutputUID == "first")
        // 从设备采样率不同仍由 HAL 重采样，不能刷新一次就误判设备断开。
        try device.reconcile(snapshot: fixture.snapshot)
        fixture.rates[1] = 44_100
        #expect(throws: (any Error).self) { try device.reconcile(snapshot: fixture.snapshot) }
    }

    @Test func aggregateAndVirtualDevicesAreNotNested() {
        for transport in [kAudioDeviceTransportTypeAggregate, kAudioDeviceTransportTypeVirtual, UInt32(0)] {
            let output = AudioOutput(id: 9, uid: "aggregate", name: "fixture", transport: transport)
            #expect(!output.supportsSimultaneousOutput)
            #expect(throws: (any Error).self) {
                try MultiOutputPlan(outputs: [Fixture.outputs[0], output], sampleRates: ["first": 48_000, "aggregate": 48_000])
            }
        }
    }

    @Test func invalidRatesAndDuplicateHardwareAreRejected() {
        for rate in [Double.nan, .infinity, 0, -1] {
            #expect(throws: (any Error).self) {
                try MultiOutputPlan(outputs: Array(Fixture.outputs.prefix(2)), sampleRates: ["first": rate, "second": rate])
            }
        }
        let sameID = AudioOutput(id: 1, uid: "other", name: "fixture", transport: kAudioDeviceTransportTypeUSB)
        #expect(throws: (any Error).self) {
            try MultiOutputPlan(outputs: [Fixture.outputs[0], sameID], sampleRates: ["first": 48_000, "other": 48_000])
        }
    }

    @Test func threeOutputsKeepUserOrderAndStopRestoresPreviousOutput() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["second", "first", "third"])
        #expect(device.route?.outputs.map(\.uid) == ["second", "first", "third"])
        #expect(fixture.selected == 99)
        #expect(throws: (any Error).self) { try device.start(outputUIDs: ["first", "second"]) }
        try device.stop()
        #expect(fixture.selections == [99, 1, 1])
        #expect(fixture.destroyed == [99])
        #expect(device.route == nil)
        try device.stop() // 重复结束不再访问硬件。
        #expect(fixture.destroyed == [99])
    }

    @Test func explicitSingleOutputSelectionDoesNotRestoreOldDevice() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        try device.stop(selecting: "third")
        #expect(fixture.selections == [99, 3, 3])
        #expect(device.route == nil)
    }

    @Test func releaseReassertsTheExplicitTargetIfBluetoothTakesTheDefaultOutput() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        // 模拟 macOS 在销毁聚合设备后把默认输出切回已连接的蓝牙设备。
        fixture.selectionAfterDestroy = 2
        try device.stop(selecting: "third")
        #expect(fixture.selections == [99, 3, 3])
        #expect(fixture.selected == 3)
        #expect(device.route == nil)
    }

    @Test func unconfirmedAggregateReleaseRemainsRetryable() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        // 模拟 HAL 返回销毁成功但设备仍在枚举结果中：界面不能误报释放完成。
        fixture.keepAggregateAfterDestroy = true
        #expect(throws: (any Error).self) { try device.stop(selecting: "third") }
        #expect(device.route?.deviceID == 99)
        #expect(device.requiresCleanup)

        fixture.keepAggregateAfterDestroy = false
        try device.stop(selecting: "third")
        #expect(device.route == nil)
        #expect(!device.requiresCleanup)
        #expect(fixture.destroyed == [99, 99])
    }

    @Test func thirdPartyAggregateIsNotRestoredAfterStoppingNewRoute() throws {
        let fixture = Fixture()
        fixture.otherOutputs = [
            AudioOutput(id: 87, uid: "third.party.aggregate", name: "系统多输出设备",
                        transport: kAudioDeviceTransportTypeAggregate)
        ]
        fixture.selected = 87
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        // 从外部聚合设备启动时，结束后应回到首台真实成员，而不是再次恢复多设备输出。
        #expect(device.route?.previousOutputUID == "first")
        try device.stop()
        #expect(fixture.selections == [99, 1, 1])
        #expect(device.route == nil)
    }

    @Test func externalOutputSelectionIsNotOverwritten() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        fixture.selected = 3
        try device.reconcile(snapshot: fixture.snapshot)
        #expect(fixture.selections == [99])
        #expect(fixture.selected == 3)
        #expect(device.route == nil)
    }

    @Test func bluetoothAutoSelectionCannotBreakActiveSimultaneousOutput() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])

        // 非成员蓝牙设备连接时也可能把自己设为系统默认输出，不能让它拆掉聚合路由。
        fixture.otherOutputs = [
            AudioOutput(id: 4, uid: "new-bluetooth", name: "Podssss",
                        transport: kAudioDeviceTransportTypeBluetooth)
        ]
        fixture.selected = 4
        let restored = try device.reconcile(snapshot: fixture.snapshot)

        #expect(restored)
        #expect(fixture.selections == [99, 99])
        #expect(fixture.selected == 99)
        #expect(fixture.destroyed.isEmpty)
        #expect(device.route?.deviceID == 99)
    }

    @Test func connectedMemberCannotBreakActiveSimultaneousOutput() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])

        // 已勾选成员在重连时抢占默认输出，同样恢复聚合设备。
        fixture.selected = 2
        let restored = try device.reconcile(snapshot: fixture.snapshot)

        #expect(restored)
        #expect(fixture.selections == [99, 99])
        #expect(fixture.selected == 99)
        #expect(fixture.destroyed.isEmpty)
        #expect(device.route?.deviceID == 99)
    }

    @Test func unavailableMemberCannotUseAutoSelectionToKeepBrokenRoute() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])

        // 成员读取失败时不能仅因它抢占默认输出就恢复一个已经失效的聚合设备。
        fixture.offline.insert(2)
        fixture.selected = 2
        #expect(throws: (any Error).self) { try device.reconcile(snapshot: fixture.snapshot) }

        #expect(fixture.selections == [99])
        #expect(fixture.selected == 2)
        #expect(fixture.destroyed == [99])
        #expect(device.route == nil)
    }

    @Test func creationFailureDoesNotSelectAnything() {
        let fixture = Fixture()
        fixture.failCreation = true
        let device = MultiOutputDevice(hardware: fixture.hardware)
        #expect(throws: (any Error).self) { try device.start(outputUIDs: ["first", "second"]) }
        #expect(device.route == nil)
        #expect(fixture.selections.isEmpty)
    }

    @Test func selectionFailureReleasesNewDeviceWithoutChangingOriginal() {
        let fixture = Fixture()
        fixture.failSelection = true
        let device = MultiOutputDevice(hardware: fixture.hardware)
        #expect(throws: (any Error).self) { try device.start(outputUIDs: ["first", "second"]) }
        #expect(fixture.selected == 1)
        #expect(fixture.destroyed == [99])
        #expect(device.route == nil)
    }

    @Test func failedSelectionAfterSystemWriteRestoresOriginalBeforeDestroying() {
        let fixture = Fixture()
        fixture.failSelectionAfterWrite = true
        let device = MultiOutputDevice(hardware: fixture.hardware)
        #expect(throws: (any Error).self) { try device.start(outputUIDs: ["first", "second"]) }
        #expect(fixture.selections == [99, 1, 1])
        #expect(fixture.selected == 1)
        #expect(fixture.destroyed == [99])
    }

    @Test func cleanupFailureRetainsHandleAndRequiresExplicitRetry() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        fixture.failDestroy = true
        #expect(throws: (any Error).self) { try device.stop() }
        #expect(device.route?.deviceID == 99)
        #expect(device.requiresCleanup)
        let attempts = fixture.destroyAttempts
        try device.reconcile(snapshot: fixture.snapshot)
        #expect(fixture.destroyAttempts == attempts)
        fixture.failDestroy = false
        try device.stop()
        #expect(device.route == nil)
        #expect(!device.requiresCleanup)
    }

    @Test func startupCleanupFailureRetainsHandle() {
        let fixture = Fixture()
        fixture.failSelection = true
        fixture.failDestroy = true
        let device = MultiOutputDevice(hardware: fixture.hardware)
        #expect(throws: (any Error).self) { try device.start(outputUIDs: ["first", "second"]) }
        #expect(device.route?.deviceID == 99)
        #expect(device.requiresCleanup)
    }

    @Test func createdDeviceWithWrongRateIsReleasedBeforeAnyOutputSwitch() {
        let fixture = Fixture()
        fixture.rates[99] = 44_100
        let device = MultiOutputDevice(hardware: fixture.hardware)
        #expect(throws: (any Error).self) { try device.start(outputUIDs: ["first", "second"]) }
        #expect(fixture.selections.isEmpty)
        #expect(fixture.destroyed == [99])
        #expect(device.route == nil)
    }

    @Test func lostMemberNeverShrinksOrRecreatesTheGroup() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        fixture.offline.insert(2)
        #expect(throws: (any Error).self) { try device.reconcile(snapshot: fixture.snapshot) }
        #expect(device.route?.outputs.count == 2)
        #expect(fixture.creations.count == 1)
        #expect(fixture.selected == 99)
    }

    @Test func missingPreviousOutputDoesNotPickAnArbitraryReplacement() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        fixture.offline.insert(1)
        #expect(throws: (any Error).self) { try device.stop() }
        #expect(fixture.selections == [99])
        #expect(fixture.destroyed.isEmpty)
        try device.stop(selecting: "third")
        #expect(fixture.selected == 3)
        #expect(device.route == nil)
    }

    @Test func disconnectAlongsideSystemSwitchIsReportedWithoutOverwritingNewRoute() throws {
        let fixture = Fixture()
        let device = MultiOutputDevice(hardware: fixture.hardware)
        try device.start(outputUIDs: ["first", "second"])
        fixture.offline.insert(2)
        fixture.selected = 3
        #expect(throws: (any Error).self) { try device.reconcile(snapshot: fixture.snapshot) }
        #expect(fixture.selections == [99])
        #expect(fixture.selected == 3)
        #expect(fixture.destroyed == [99])
        #expect(device.route == nil)
    }
}

/// 仅测试夹具。设备创建、选择与销毁都记录在内存，绝不调用真实 HAL 写入。
@MainActor
private final class Fixture {
    static let outputs = [
        AudioOutput(id: 1, uid: "first", name: "耳机 A", transport: kAudioDeviceTransportTypeBluetooth),
        AudioOutput(id: 2, uid: "second", name: "耳机 B", transport: kAudioDeviceTransportTypeBluetooth),
        AudioOutput(id: 3, uid: "third", name: "扬声器", transport: kAudioDeviceTransportTypeBuiltIn)
    ]
    var otherOutputs: [AudioOutput] = []
    var selected: AudioDeviceID = 1
    var rates: [AudioDeviceID: Double] = [1: 48_000, 2: 48_000, 3: 48_000, 99: 48_000]
    var offline: Set<AudioDeviceID> = []
    var creations: [[String: Any]] = []
    var selections: [AudioDeviceID] = []
    var destroyed: [AudioDeviceID] = []
    var destroyAttempts = 0
    var inactiveUIDs: Set<String> = []
    var omitDriftCompensation = false
    var failCreation = false
    var failSelection = false
    var failSelectionAfterWrite = false
    var failDestroy = false
    var keepAggregateAfterDestroy = false
    var selectionAfterDestroy: AudioDeviceID?

    var snapshot: SystemAudioSnapshot {
        var outputs = Self.outputs + otherOutputs.filter { !destroyed.contains($0.id) }
        if let description = creations.last, keepAggregateAfterDestroy || !destroyed.contains(99),
           let uid = description[kAudioAggregateDeviceUIDKey] as? String {
            outputs.append(AudioOutput(id: 99, uid: uid, name: "测试同时输出", transport: kAudioDeviceTransportTypeAggregate))
        }
        return SystemAudioSnapshot(outputs: outputs, selectedID: selected, controls: [:])
    }

    var hardware: MultiOutputHardware {
        MultiOutputHardware(snapshot: { self.snapshot }, sampleRate: { id in
            guard let rate = self.rates[id] else { throw AudioFailure("缺少采样率") }
            return rate
        }, isAlive: { !self.offline.contains($0) }, configuration: { _ in
            guard var composition = self.creations.last else { throw AudioFailure("缺少组合配置") }
            var members = try #require(composition[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])
            if self.omitDriftCompensation {
                for index in members.indices { members[index][kAudioSubDeviceDriftCompensationKey] = 0 }
                composition[kAudioAggregateDeviceSubDeviceListKey] = members
            }
            let uids = members.compactMap { $0[kAudioSubDeviceUIDKey] as? String }
                .filter { !self.inactiveUIDs.contains($0) }
            return try MultiOutputConfiguration(composition: composition, activeOutputUIDs: uids)
        }, create: {
            if self.failCreation { throw AudioFailure("创建失败") }
            self.creations.append($0)
            return 99
        }, select: { id in
            if id == 99 && self.failSelection { throw AudioFailure("切换失败") }
            self.selections.append(id)
            self.selected = id
            if id == 99 && self.failSelectionAfterWrite { throw AudioFailure("读回失败") }
        }, destroy: { id in
            self.destroyAttempts += 1
            if self.failDestroy { throw AudioFailure("销毁失败") }
            self.destroyed.append(id)
            if self.keepAggregateAfterDestroy { return }
            if let selectionAfterDestroy = self.selectionAfterDestroy {
                self.selected = selectionAfterDestroy
            }
        })
    }
}
