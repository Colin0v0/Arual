import AppKit
import Combine
import CoreAudio
import SwiftUI
import Testing
@testable import AuralCore
@testable import Aural

@MainActor
struct OutputRoutingErrorTests {
    private static let previousDevice = AudioOutput(id: 88, uid: "local.aural.multi.previous-session",
                                                    name: "Aural 同时输出", transport: kAudioDeviceTransportTypeAggregate)

    @Test func unchangedRefreshDoesNotRepublishModelState() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        var updates = 0
        let cancellable = model.objectWillChange.sink { updates += 1 }

        // 定时轮询读到相同快照时不能触发隐藏面板重新布局。
        model.refresh()
        #expect(updates == 0)
        withExtendedLifetime(cancellable) {}
    }

    @Test func meterUpdatesStayInsideApplicationLevelSource() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        var modelUpdates = 0
        let modelCancellable = model.objectWillChange.sink { modelUpdates += 1 }
        let source = model.levelSource(for: "bundle:test.music")
        #expect(model.levelSource(for: "bundle:test.music") === source)

        var sourceUpdates = 0
        let sourceCancellable = source.objectWillChange.sink { sourceUpdates += 1 }
        source.update(0.7)
        source.update(0.7)

        // 30Hz 电平只能刷新自己的小视图，不能让整个面板和三个分区重新布局。
        #expect(sourceUpdates == 1)
        #expect(modelUpdates == 0)
        #expect(source.level == 0.7)
        withExtendedLifetime((modelCancellable, sourceCancellable)) {}
    }

    @Test func startupRecognizesPreviousDeviceWithoutRestoringOrChangingOutput() {
        let fixture = RoutingHardwareFixture()
        fixture.unmanaged = [Self.previousDevice]
        fixture.selected = Self.previousDevice.id
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.multiOutputRoute == nil)
        #expect(model.unmanagedMultiOutputs == [Self.previousDevice])
        #expect(model.applicationAudioUnavailableReason == "选择上面的扬声器后，可调节 APP 音量与电平")
        #expect(fixture.selections.isEmpty)
        #expect(fixture.destroyAttempts == 0)
        // 只读刷新不能假设旧组合正在使用，更不能擅自切换到第一台硬件。
        model.refresh()
        #expect(fixture.selected == Self.previousDevice.id)
        #expect(fixture.selections.isEmpty)
    }

    @Test func explicitHardwareSelectionRemovesPreviousDeviceAndRestoresAppControls() {
        let fixture = RoutingHardwareFixture()
        fixture.unmanaged = [Self.previousDevice]
        fixture.selected = Self.previousDevice.id
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        model.selectOutput(fixture.outputs[0].id)
        #expect(fixture.selections == [fixture.outputs[0].id])
        #expect(fixture.destroyed == [Self.previousDevice.id])
        #expect(model.unmanagedMultiOutputs.isEmpty)
        #expect(model.multiOutputRoute == nil)
        #expect(model.multiOutputError == nil)
        #expect(!model.applicationAudioUnavailable)
    }

    @Test func failedPreviousDeviceCleanupNeverRollsBackExplicitOutputOrRetriesOnRefresh() {
        let fixture = RoutingHardwareFixture()
        fixture.unmanaged = [Self.previousDevice]
        fixture.selected = Self.previousDevice.id
        fixture.failDestroy = true
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        model.selectOutput(fixture.outputs[0].id)
        #expect(fixture.selected == fixture.outputs[0].id)
        #expect(!model.applicationAudioUnavailable)
        #expect(model.multiOutputError != nil)
        model.dismissSimultaneousOutputError()
        model.refresh()
        #expect(model.multiOutputError != nil)
        #expect(fixture.destroyAttempts == 1)
        fixture.failDestroy = false
        model.stopSimultaneousOutput()
        #expect(model.unmanagedMultiOutputs.isEmpty)
        #expect(model.multiOutputError == nil)
        #expect(fixture.selections == [fixture.outputs[0].id])
    }

    @Test func previousSelectedDeviceCannotBeReSelectedOrDeletedWithoutExplicitTarget() {
        let fixture = RoutingHardwareFixture()
        fixture.unmanaged = [Self.previousDevice]
        fixture.selected = Self.previousDevice.id
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        model.stopSimultaneousOutput()
        model.selectOutput(Self.previousDevice.id)
        #expect(model.multiOutputError != nil)
        #expect(fixture.selections.isEmpty)
        #expect(fixture.destroyAttempts == 0)
    }

    @Test func inactivePreviousDeviceHasAnExplicitCleanupPath() {
        let fixture = RoutingHardwareFixture()
        fixture.unmanaged = [Self.previousDevice]
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(!model.applicationAudioUnavailable)
        model.stopSimultaneousOutput()
        #expect(fixture.selections.isEmpty)
        #expect(fixture.destroyed == [Self.previousDevice.id])
        #expect(model.unmanagedMultiOutputs.isEmpty)
    }

    @Test func thirdPartyAggregateIsNotMislabelledOrDeletedAsAuralRoute() {
        let fixture = RoutingHardwareFixture()
        let thirdParty = AudioOutput(id: 87, uid: "third.party.aggregate", name: "Aural 同时输出",
                                     transport: kAudioDeviceTransportTypeAggregate)
        fixture.unmanaged = [thirdParty]
        fixture.selected = thirdParty.id
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.unmanagedMultiOutputs.isEmpty)
        #expect(model.applicationAudioUnavailableReason == "当前系统输出不支持 APP 独立音量与电平")
        model.selectOutput(fixture.outputs[0].id)
        #expect(fixture.destroyed.isEmpty)
        #expect(!model.applicationAudioUnavailable)
    }

    @Test func selectingOneDeviceUsesRealHardwareInsteadOfCreatingAggregate() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput([fixture.outputs[0].uid]))
        #expect(fixture.composition == nil)
        #expect(fixture.selections.isEmpty)
        #expect(model.multiOutputRoute == nil)
        #expect(model.singleOutputTargetUID == fixture.outputs[0].uid)
        #expect(model.multiOutputError == nil)
        #expect(!model.applicationAudioUnavailable)
    }

    @Test func activeAuralMultiOutputKeepsPerAppControlsAvailable() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        #expect(model.multiOutputRoute?.deviceID == 99)
        #expect(model.audio?.selectedID == 99)
        // Aural 聚合是 APP 音频的捕获来源，具备真实成员后才能继续重放；
        // 因此当前路由不能再返回“不支持独立音量”的禁用原因。
        #expect(!model.applicationAudioUnavailable)
        #expect(model.applicationAudioUnavailableReason == nil)
    }

    @Test func externalBluetoothSelectionMigratesSingleModeWithoutStealingItBack() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput([fixture.outputs[0].uid]))

        // 外部选择无法可靠归因，Aural 不擅自抢回。
        fixture.selected = fixture.outputs[1].id
        model.refresh()
        #expect(fixture.selections.isEmpty)
        #expect(fixture.selected == fixture.outputs[1].id)
        #expect(model.audio?.selectedID == fixture.outputs[1].id)
        #expect(model.outputRouting.phase == .stable)
        #expect(model.multiOutputError == nil)
        #expect(model.outputRouting.confirmed?.output.id == fixture.outputs[1].id)
    }

    @Test func stoppingSingleDeviceModeOnlyChangesModeIdentity() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput([fixture.outputs[0].uid]))
        model.stopSimultaneousOutput()
        #expect(model.singleOutputTargetUID == nil)
        #expect(fixture.selected == fixture.outputs[0].id)
        #expect(fixture.selections.isEmpty)
        #expect(model.multiOutputRoute == nil)
    }

    @Test func explicitPhysicalDeviceSelectionEndsSingleDeviceMode() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput([fixture.outputs[0].uid]))
        model.selectOutput(fixture.outputs[1].id)
        #expect(model.singleOutputTargetUID == nil)
        #expect(fixture.selected == fixture.outputs[1].id)
        #expect(fixture.selections == [fixture.outputs[1].id])
    }

    @Test func shrinkingRouteToOneDeviceReleasesAggregateAndRestoresAppControls() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        #expect(model.updateSimultaneousOutput([fixture.outputs[1].uid]))
        #expect(fixture.composition == nil)
        #expect(fixture.destroyed == [99])
        #expect(fixture.selected == fixture.outputs[1].id)
        #expect(model.multiOutputRoute == nil)
        #expect(model.multiOutputError == nil)
        #expect(!model.applicationAudioUnavailable)
    }

    @Test func shrinkingRouteWaitsForDelayedAggregateRemovalWithoutAnError() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        fixture.keepAggregateAfterDestroy = true
        #expect(!model.updateSimultaneousOutput([fixture.outputs[1].uid]))
        #expect(model.outputRouting.phase == .awaitingHAL)
        #expect(model.multiOutputRoute == nil)
        #expect(model.multiOutputError == nil)
        fixture.keepAggregateAfterDestroy = false
        fixture.composition = nil // HAL 稍后完成移除，不是发出第二次销毁命令。
        model.refresh()
        #expect(model.outputRouting.phase == .confirmed)
        #expect(model.outputRouting.selectedMemberUIDs == [fixture.outputs[1].uid])
        #expect(model.outputRouting.pendingCleanup.isEmpty)
        #expect(fixture.destroyAttempts == 1)
    }

    @Test func failedDraftCanBeCancelledWithoutAnotherAudioWrite() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        let selection = OutputRoutingDisclosure()
        selection.isChoosing = true
        fixture.failCreation = true
        #expect(!model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        #expect(model.multiOutputError != nil)
        #expect(model.multiOutputRoute == nil)
        selection.cancel()
        model.dismissSimultaneousOutputError()
        model.refresh()
        #expect(!selection.isChoosing)
        #expect(model.multiOutputError == nil)
        #expect(fixture.selections.isEmpty)
        #expect(fixture.destroyed.isEmpty)
    }

    @Test func selectingCurrentSingleOutputAlsoClearsFailedDraft() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        fixture.failCreation = true
        #expect(!model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        model.selectOutput(fixture.selected)
        #expect(model.multiOutputError == nil)
        #expect(fixture.selections.isEmpty)
    }

    @Test func stoppingPartialPlaybackDoesNotLeaveAnErrorOrResidualGroup() {
        let fixture = RoutingHardwareFixture()
        var now = Date(timeIntervalSince1970: 1_000)
        let environment = ApplicationAudioEnvironment(
            readApplications: { _ in ([], 0) },
            hasMixerConflict: { false },
            makeSession: { _, _, _, _ in fatalError("该测试不创建音频会话") },
            now: { now }, captureAccess: { .authorized }
        )
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false,
                             applicationAudio: environment)
        #expect(model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        fixture.offline.insert(fixture.outputs[1].id)
        // 一副耳机离线时剩余扬声器继续播放，不要求用户清理残留设备。
        now = now.addingTimeInterval(0.2)
        model.refresh()
        #expect(model.multiOutputError == nil)
        #expect(model.outputRouting.confirmed?.output.uid == fixture.outputs[0].uid)
        now = now.addingTimeInterval(3.2)
        model.refresh()
        #expect(model.multiOutputError == nil)
        #expect(model.multiOutputRoute == nil)
        #expect(model.outputRouting.pendingCleanup.isEmpty)
        model.stopSimultaneousOutput()
        model.refresh()
        #expect(model.multiOutputError == nil)
        #expect(model.multiOutputRoute == nil)
        #expect(fixture.selections == [99, fixture.outputs[0].id])
        #expect(fixture.destroyed == [99])
    }

    @Test func changingMemberOrderRebuildsTheRouteWithTheNewPrimaryDevice() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        let reordered = [fixture.outputs[1].uid, fixture.outputs[0].uid]
        #expect(model.updateSimultaneousOutput(reordered))
        #expect(model.multiOutputRoute?.outputs.map(\.uid) == reordered)
        #expect(fixture.destroyed == [99])
        #expect(fixture.selections == [99, fixture.outputs[1].id, 99])
        #expect(model.multiOutputError == nil)
    }

    @Test func releaseFailureCannotBeDismissedButSuccessfulRetryClearsIt() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        fixture.failDestroy = true
        model.stopSimultaneousOutput()
        #expect(model.multiOutputRoute == nil)
        #expect(!model.outputRouting.pendingCleanup.isEmpty)
        #expect(model.multiOutputError != nil)
        model.dismissSimultaneousOutputError()
        model.refresh()
        #expect(model.multiOutputError != nil)
        #expect(fixture.destroyAttempts == 1)
        fixture.failDestroy = false
        model.stopSimultaneousOutput()
        #expect(model.multiOutputRoute == nil)
        #expect(model.multiOutputError == nil)
    }

    @Test func singleOutputSelectionClearsRoutingErrorWithoutLeavingGlobalError() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        fixture.failDestroy = true
        model.selectOutput(fixture.outputs[1].id)
        #expect(model.multiOutputError != nil)
        #expect(model.operationError == nil)
        fixture.failDestroy = false
        model.stopSimultaneousOutput()
        #expect(model.multiOutputError == nil)
        #expect(model.operationError == nil)
        #expect(fixture.selected == fixture.outputs[1].id)
    }

    @Test func errorMessageRemainsVisibleUnderIconOnlyLabelEnvironment() throws {
        let renderer = ImageRenderer(content:
            PanelError(text: "系统未启用从设备的时钟漂移补偿，请重新启动同时输出")
                .labelStyle(.iconOnly)
        )
        let image = try #require(renderer.nsImage)
        // 若继承 iconOnly，图像会只剩约 14pt 宽的感叹号，正文没有进入布局。
        #expect(image.size.width > 200)
        #expect(image.size.height > 0)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        try #require(bitmap.representation(using: .png, properties: [:]))
            .write(to: URL(fileURLWithPath: "/tmp/aural-multi-output-error-message.png"))
    }

    @Test func dismissibleErrorRowUsesCenteredActionHeight() {
        let host = NSHostingView(rootView:
            OutputRoutingErrorRow(text: "读取音频名称失败（Core Audio 2003332927）",
                                  canDismiss: true,
                                  dismiss: {})
                .frame(width: 416)
        )
        host.frame = NSRect(x: 0, y: 0, width: 416, height: PanelActionMetrics.size)
        host.layoutSubtreeIfNeeded()

        // 错误标题和 26pt 关闭按钮必须落在同一行，不能再用文字自身高度做顶部对齐。
        #expect(host.fittingSize.height == PanelActionMetrics.size)
        if let bitmap = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: bitmap)
            try? bitmap.representation(using: .png, properties: [:])?
                .write(to: URL(fileURLWithPath: "/tmp/aural-routing-error-row.png"))
        }
    }
}

/// 路由回归测试只修改内存；不连接蓝牙、不切换真实默认输出、不创建 HAL 设备。
@MainActor
private final class RoutingHardwareFixture {
    let outputs = [
        AudioOutput(id: 1, uid: "fixture-speaker", name: "测试扬声器", transport: kAudioDeviceTransportTypeBuiltIn),
        AudioOutput(id: 2, uid: "fixture-headphones", name: "测试耳机", transport: kAudioDeviceTransportTypeBluetooth)
    ]
    var unmanaged: [AudioOutput] = []
    var selected: AudioDeviceID = 1
    var composition: [String: Any]?
    var offline: Set<AudioDeviceID> = []
    var selections: [AudioDeviceID] = []
    var destroyed: [AudioDeviceID] = []
    var destroyAttempts = 0
    var failCreation = false
    var failDestroy = false
    var keepAggregateAfterDestroy = false

    var snapshot: SystemAudioSnapshot {
        var current = outputs + unmanaged.filter { !destroyed.contains($0.id) }
        if let composition, let uid = composition[kAudioAggregateDeviceUIDKey] as? String {
            current.append(AudioOutput(id: 99, uid: uid, name: "测试同时输出", transport: kAudioDeviceTransportTypeAggregate))
        }
        return SystemAudioSnapshot(outputs: current, selectedID: selected, controls: [:])
    }

    var hardware: MultiOutputHardware {
        MultiOutputHardware(snapshot: { self.snapshot }, selectedSystemOutputID: { self.selected }, sampleRate: { _ in 48_000 },
            isAlive: { !self.offline.contains($0) }, configuration: { _ in
                let composition = try #require(self.composition)
                let active = self.outputs.filter { !self.offline.contains($0.id) }.map(\.uid)
                return try MultiOutputConfiguration(composition: composition, activeOutputUIDs: active)
            }, create: { composition in
                if self.failCreation { throw AudioFailure("创建同时输出失败") }
                self.composition = composition
                return 99
            }, select: { id in
                self.selections.append(id)
                self.selected = id
            }, destroy: { id in
                self.destroyAttempts += 1
                if self.failDestroy { throw AudioFailure("释放同时输出失败") }
                self.destroyed.append(id)
                if self.keepAggregateAfterDestroy { return }
                if id == 99 { self.composition = nil }
            })
    }
}
