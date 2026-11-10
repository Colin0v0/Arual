import AppKit
import CoreAudio
import SwiftUI
import Testing
@testable import AuralCore
@testable import Aural

@MainActor
struct OutputRoutingErrorTests {
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
        #expect(fixture.selections == [fixture.outputs[0].id])
        #expect(model.multiOutputRoute == nil)
        #expect(model.singleOutputTargetUID == fixture.outputs[0].uid)
        #expect(model.multiOutputError == nil)
        #expect(!model.applicationAudioUnavailable)
    }

    @Test func singleDeviceTargetSurvivesBluetoothTakingTheDefaultOutput() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput([fixture.outputs[0].uid]))

        // 蓝牙耳机在系统层抢走默认输出后，刷新必须恢复用户保留的唯一设备。
        fixture.selected = fixture.outputs[1].id
        model.refresh()
        #expect(fixture.selections == [fixture.outputs[0].id, fixture.outputs[0].id])
        #expect(fixture.selected == fixture.outputs[0].id)
        #expect(model.audio?.selectedID == fixture.outputs[0].id)
        #expect(model.multiOutputError == nil)
    }

    @Test func stoppingSingleDeviceModeReleasesThePinWithoutChangingOutput() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput([fixture.outputs[0].uid]))
        model.stopSimultaneousOutput()
        #expect(model.singleOutputTargetUID == nil)
        #expect(fixture.selected == fixture.outputs[0].id)
        #expect(fixture.selections == [fixture.outputs[0].id])
        #expect(model.multiOutputRoute == nil)
    }

    @Test func explicitPhysicalDeviceSelectionEndsSingleDevicePin() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput([fixture.outputs[0].uid]))
        model.selectOutput(fixture.outputs[1].id)
        #expect(model.singleOutputTargetUID == nil)
        #expect(fixture.selected == fixture.outputs[1].id)
        #expect(fixture.selections == [fixture.outputs[0].id, fixture.outputs[1].id])
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

    private static let previousDevice = AudioOutput(id: 88, uid: "local.aural.multi.previous-session",
                                                    name: "Aural 同时输出", transport: kAudioDeviceTransportTypeAggregate)

    @Test func failedDraftCanBeCancelledWithoutAnotherAudioWrite() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        let selection = OutputRoutingSelection()
        selection.begin()
        selection.toggle(fixture.outputs[0].uid)
        selection.toggle(fixture.outputs[1].uid)
        fixture.failCreation = true
        #expect(!model.startSimultaneousOutput(selection.uids))
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

    @Test func successfulStopClearsActiveErrorAndItDoesNotReturnOnRefresh() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        fixture.offline.insert(fixture.outputs[1].id)
        model.refresh()
        #expect(model.multiOutputError != nil)
        #expect(model.multiOutputRoute != nil)
        model.stopSimultaneousOutput()
        model.refresh()
        #expect(model.multiOutputError == nil)
        #expect(model.multiOutputRoute == nil)
        #expect(fixture.selections == [99, fixture.outputs[0].id, fixture.outputs[0].id])
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
        #expect(fixture.selections == [99, fixture.outputs[0].id, fixture.outputs[0].id, 99])
        #expect(model.multiOutputError == nil)
    }

    @Test func releaseFailureCannotBeDismissedButSuccessfulRetryClearsIt() {
        let fixture = RoutingHardwareFixture()
        let model = AppModel(outputHardware: fixture.hardware, startsMonitoring: false)
        #expect(model.startSimultaneousOutput(fixture.outputs.map(\.uid)))
        fixture.failDestroy = true
        model.stopSimultaneousOutput()
        #expect(model.multiOutputRoute != nil)
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

    var snapshot: SystemAudioSnapshot {
        var current = outputs + unmanaged.filter { !destroyed.contains($0.id) }
        if let composition, let uid = composition[kAudioAggregateDeviceUIDKey] as? String {
            current.append(AudioOutput(id: 99, uid: uid, name: "测试同时输出", transport: kAudioDeviceTransportTypeAggregate))
        }
        return SystemAudioSnapshot(outputs: current, selectedID: selected, controls: [:])
    }

    var hardware: MultiOutputHardware {
        MultiOutputHardware(snapshot: { self.snapshot }, sampleRate: { _ in 48_000 },
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
                if id == 99 { self.composition = nil }
            })
    }
}
