import AppKit
import CoreAudio
import SwiftUI
import Testing
@testable import AuralCore
@testable import Aural

@MainActor
struct OutputRoutingTests {
    @Test func disclosureHasNoPlaybackSelectionOrStopSideEffect() {
        let disclosure = OutputRoutingDisclosure()
        disclosure.isChoosing = true
        disclosure.cancel()
        #expect(!disclosure.isChoosing)
    }

    @Test @MainActor func simultaneousEntryUsesTheSameRowPitchAsTheMicrophonePage() throws {
        let output = OutputDevicesLayoutTests.fixture.outputs[0]
        let outputSnapshot = SystemAudioSnapshot(
            outputs: [output],
            selectedID: output.id,
            controls: [output.id: try #require(OutputDevicesLayoutTests.fixture.controls[output.id])]
        )
        let routing = NSHostingView(rootView:
            OutputRoutingSection(audio: outputSnapshot, routing: routingFixture(snapshot: outputSnapshot),
                                 select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in },
                                 stop: {}, dismissError: {}, toggleMember: { _ in })
                .frame(width: PanelMetrics.contentWidth)
        )
        routing.frame.size = routing.fittingSize
        routing.layoutSubtreeIfNeeded()

        let inputs = [
            AudioInput(id: 1, uid: "fixture-input-a", name: "MacBook Air 麦克风",
                       transport: kAudioDeviceTransportTypeBuiltIn),
            AudioInput(id: 2, uid: "fixture-input-b", name: "USB 麦克风",
                       transport: kAudioDeviceTransportTypeUSB)
        ]
        let control = try #require(OutputDevicesLayoutTests.fixture.controls[output.id])
        let microphone = NSHostingView(rootView:
            InputDevicesSection(audio: SystemInputSnapshot(inputs: inputs, selectedID: 1,
                                                           controls: [1: control, 2: control]),
                                select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in })
                .frame(width: PanelMetrics.contentWidth)
        )
        microphone.frame.size = microphone.fittingSize
        microphone.layoutSubtreeIfNeeded()

        // 一台输出 + 同时输出入口，必须与两台麦克风行占用同样的垂直空间。
        #expect(routing.fittingSize.height == 80)
        #expect(microphone.fittingSize.height == 80)
    }

    @Test func routingEntryRendersWithoutWritingAudioSettings() throws {
        var starts = 0
        var stops = 0
        let host = NSHostingView(rootView: OutputRoutingSection(audio: OutputDevicesLayoutTests.fixture,
            routing: routingFixture(snapshot: OutputDevicesLayoutTests.fixture), select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in },
            stop: { stops += 1 }, dismissError: {}, toggleMember: { _ in })
            .frame(width: PanelMetrics.contentWidth).background(PanelStyle.canvas))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.width == PanelMetrics.contentWidth)
        #expect(host.frame.height <= 220)
        #expect(starts == 0)
        #expect(stops == 0)
        // 组合入口沿用普通设备行的外观，但未启动时不写入任何硬件设置。
        #expect(findButtons(host).count == OutputDevicesLayoutTests.fixture.outputs.count)
        try export(host, to: "/tmp/aural-multi-output-entry.png")
    }

    @Test func activeRouteKeepsPhysicalControlsAndCompactSummary() throws {
        let fixture = OutputDevicesLayoutTests.fixture
        let route = MultiOutputRoute(deviceID: 99, uid: "fixture-multi", outputs: Array(fixture.outputs.prefix(2)),
                                     mainOutputUID: fixture.outputs[0].uid,
                                     previousOutputUID: fixture.outputs[0].uid, sampleRate: 48_000)
        let aggregate = AudioOutput(id: 99, uid: route.uid, name: "Aural 同时输出", transport: kAudioDeviceTransportTypeAggregate)
        let snapshot = SystemAudioSnapshot(outputs: fixture.outputs + [aggregate], selectedID: 99, controls: fixture.controls)
        let host = NSHostingView(rootView: OutputRoutingSection(audio: snapshot, routing: routingFixture(snapshot: snapshot, route: route),
            select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in }, stop: {}, dismissError: {}, toggleMember: { _ in })
            .frame(width: PanelMetrics.contentWidth).background(PanelStyle.canvas))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        // 四台物理设备各有静音按钮，组合行也提供统一静音；成员选择折叠时不额外占高度。
        #expect(findButtons(host).count == 5)
        #expect(findButtons(host).contains { $0.toolTip == "静音同时输出" })
        #expect(host.frame.height <= 220)
        try export(host, to: "/tmp/aural-multi-output-active.png")
    }

    @Test func expandedRouteEditorRetainsOrderWithoutManualActions() throws {
        let fixture = OutputDevicesLayoutTests.fixture
        let route = MultiOutputRoute(deviceID: 99, uid: "fixture-multi", outputs: Array(fixture.outputs.prefix(2)),
                                     mainOutputUID: fixture.outputs[0].uid,
                                     previousOutputUID: fixture.outputs[0].uid, sampleRate: 48_000)
        let selected = Set(route.outputs.map(\.uid))
        var stops = 0
        var muteWrites: [(Bool, UInt32)] = []
        let host = NSHostingView(rootView:
            SimultaneousOutputEditor(outputs: fixture.outputs, controls: fixture.controls,
                                     selectedUIDs: selected, toggleMember: { _ in },
                                     setVolume: { _, _ in }, setMuted: { muteWrites.append(($0, $1)) })
                .frame(width: PanelMetrics.contentWidth)
                .background(PanelStyle.canvas)
        )
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let buttons = findButtons(host)
        // 展开后的每个成员仍保留自己的静音与音量控制，不把成员音量藏在聚合总音量里。
        #expect(buttons.count == fixture.outputs.count)
        let headphoneMute = try #require(buttons.first { $0.toolTip == "Colin Px7 S3 静音" })
        headphoneMute.performClick(nil)
        #expect(muteWrites.count == 1)
        #expect(muteWrites.first?.0 == true)
        #expect(muteWrites.first?.1 == fixture.outputs[0].id)
        #expect(selected == Set(route.outputs.map(\.uid)))
        try export(host, to: "/tmp/aural-multi-output-editor.png")
        #expect(stops == 0)
    }

    @Test func expandedNewRouteEditorKeepsCompactHierarchy() throws {
        let fixture = OutputDevicesLayoutTests.fixture
        let selected: Set<String> = [fixture.outputs[0].uid]
        let host = NSHostingView(rootView:
            SimultaneousOutputEditor(outputs: fixture.outputs, controls: fixture.controls,
                                     selectedUIDs: selected, toggleMember: { _ in },
                                     setVolume: { _, _ in }, setMuted: { _, _ in })
                .frame(width: PanelMetrics.contentWidth)
                .background(PanelStyle.canvas)
        )
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.height <= 190)
        #expect(findButtons(host).count == fixture.outputs.count)
        try export(host, to: "/tmp/aural-multi-output-editor-new.png")
    }

    @Test func simultaneousChooserHidesHardwareWithoutWritableVolume() {
        let fixture = OutputDevicesLayoutTests.fixture
        let unsupported = fixture.outputs[2]
        var controls = fixture.controls
        controls[unsupported.id] = .available(
            volume: AudioDeviceVolume(scalar: nil, writable: false),
            mute: AudioDeviceMute(muted: nil, writable: false)
        )

        let visible = SimultaneousOutputEditor.visibleOutputs(
            outputs: fixture.outputs,
            controls: controls,
            selectedUIDs: []
        )
        #expect(!visible.contains { $0.uid == unsupported.uid })
        #expect(visible.count == fixture.outputs.count - 1)

        // 旧组合中的成员必须保留一行，否则用户无法把它从同时输出中移除。
        let retained = SimultaneousOutputEditor.visibleOutputs(
            outputs: fixture.outputs,
            controls: controls,
            selectedUIDs: [unsupported.uid]
        )
        #expect(retained.contains { $0.uid == unsupported.uid })
    }

    @Test func previousSelectedAggregateDoesNotAppearAsOrdinarySpeakerOrActiveRoute() throws {
        let fixture = OutputDevicesLayoutTests.fixture
        let previous = AudioOutput(id: 88, uid: "local.aural.multi.previous-session", name: "Aural 同时输出",
                                   transport: kAudioDeviceTransportTypeAggregate)
        let snapshot = SystemAudioSnapshot(outputs: fixture.outputs + [previous], selectedID: previous.id,
                                           controls: fixture.controls)
        var writes = 0
        let host = NSHostingView(rootView: OutputRoutingSection(audio: snapshot, routing: routingFixture(snapshot: snapshot),
            select: { _ in writes += 1 }, setVolume: { _, _ in writes += 1 }, setMuted: { _, _ in writes += 1 },
            stop: { writes += 1 }, dismissError: {}, toggleMember: { _ in })
            .frame(width: PanelMetrics.contentWidth).background(PanelStyle.canvas))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let buttons = findButtons(host)
        #expect(buttons.count == fixture.outputs.count)
        #expect(!buttons.contains {
            $0.toolTip == "同时输出设备" || $0.toolTip == "结束同时输出"
        })
        #expect(writes == 0)
        try export(host, to: "/tmp/aural-previous-output-recovery.png")
    }

    @Test func inactivePreviousDeviceOffersCleanupWithoutClaimingSimultaneousPlayback() throws {
        let fixture = OutputDevicesLayoutTests.fixture
        let previous = AudioOutput(id: 88, uid: "local.aural.multi.previous-session", name: "Aural 同时输出",
                                   transport: kAudioDeviceTransportTypeAggregate)
        let snapshot = SystemAudioSnapshot(outputs: fixture.outputs + [previous], selectedID: fixture.selectedID,
                                           controls: fixture.controls)
        var cleanups = 0
        let host = NSHostingView(rootView: OutputRoutingSection(audio: snapshot, routing: routingFixture(snapshot: snapshot),
            select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in },
            stop: { cleanups += 1 }, dismissError: {}, toggleMember: { _ in }).frame(width: PanelMetrics.contentWidth))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let cleanup = try #require(findButtons(host).first { $0.toolTip == "清理残留设备" })
        #expect(!findButtons(host).contains {
            $0.toolTip == "同时输出设备" || $0.toolTip == "结束同时输出"
        })
        cleanup.performClick(nil)
        #expect(cleanups == 1)
    }

    @Test func aggregateIsRejectedBeforeLegacyTapTouchesHardware() {
        let aggregate = AudioOutput(id: 99, uid: "fixture-multi", name: "组合", transport: kAudioDeviceTransportTypeAggregate)
        let group = AudioProcessGroup(id: "fixture", bundleID: "test.audio", processIDs: [42], objectIDs: [123])
        let session = ProcessAudioSession(group: group, output: aggregate)
        #expect(throws: (any Error).self) { try session.start() }
        #expect(session.isReleased)
        #expect(!session.isActive)
    }

    @Test func multiOutputPlaybackRouteMirrorsRealMembersWithTheSelectedMainClock() throws {
        let members = Array(OutputDevicesLayoutTests.fixture.outputs.prefix(2))
        let aggregate = AudioOutput(id: 99, uid: "local.aural.multi.fixture",
                                    name: "Aural 多设备输出",
                                    transport: kAudioDeviceTransportTypeAggregate)
        let route = try ApplicationPlaybackRoute(output: aggregate,
                                                 playbackOutputs: members,
                                                 mainOutputUID: members[1].uid)
        let description = route.aggregateDescription(tapUUID: UUID(),
                                                     aggregateUID: "local.aural.tap.fixture")
        let devices = try #require(description[kAudioAggregateDeviceSubDeviceListKey] as? [[String: Any]])

        // Process Tap 必须挂在聚合设备真实的主设备上；直接监听公开聚合 UID
        // 会在多设备路由里得到持续为 0 的回调。重放成员仍是真实硬件。
        #expect(route.tapDeviceUID == members[1].uid)
        #expect(route.playbackDeviceUIDs == members.map(\.uid))
        #expect(route.mainDeviceUID == members[1].uid)
        #expect(route.isStacked)
        #expect(description[kAudioAggregateDeviceMainSubDeviceKey] as? String == members[1].uid)
        #expect(devices.count == 2)
        #expect((devices[0][kAudioSubDeviceDriftCompensationKey] as? NSNumber)?.intValue == 1)
        #expect((devices[1][kAudioSubDeviceDriftCompensationKey] as? NSNumber)?.intValue == 0)
    }

    @Test func retainedButInactiveRouteShowsCleanupInsteadOfClaimingPlayback() {
        let snapshot = OutputDevicesLayoutTests.fixture
        let route = MultiOutputRoute(deviceID: 99, uid: "fixture-multi", outputs: Array(snapshot.outputs.prefix(2)),
                                     mainOutputUID: snapshot.outputs[0].uid,
                                     previousOutputUID: snapshot.outputs[0].uid, sampleRate: 48_000)
        let host = NSHostingView(rootView: OutputRoutingSection(audio: snapshot, routing: routingFixture(snapshot: snapshot, route: route, error: "释放失败"),
            select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in }, stop: {}, dismissError: {}, toggleMember: { _ in })
            .frame(width: PanelMetrics.contentWidth))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(findButtons(host).contains { $0.toolTip == "清理残留设备" })
        #expect(!findButtons(host).contains { $0.toolTip == "结束同时输出" })
    }

    private func findButtons(_ view: NSView) -> [PanelActionControl] {
        if let button = view as? PanelActionControl { return [button] }
        return view.subviews.flatMap(findButtons)
    }

    private func export(_ host: NSView, to path: String) throws {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        try #require(bitmap.representation(using: .png, properties: [:])).write(to: URL(fileURLWithPath: path))
    }
}

/// 测试显式构造已经观察确认的状态，视图不再从 route 是否非空推导实际勾选。
@MainActor
func routingFixture(snapshot: SystemAudioSnapshot, route: MultiOutputRoute? = nil, error: String? = nil) -> OutputRoutingState {
    var state = OutputRoutingState()
    state.actualOutput = snapshot.outputs.first { $0.id == snapshot.selectedID }
    state.error = error
    if let route, let actual = state.actualOutput, actual.id == route.deviceID, error == nil {
        state.confirmed = ConfirmedOutputRoute(intent: .simultaneous(route.outputs.map(\.uid)), output: actual, aggregate: route)
        state.phase = .confirmed
    } else {
        state.pendingCleanup = snapshot.outputs.filter(\.isAuralMultiOutput)
        if let route, state.pendingCleanup.isEmpty {
            state.pendingCleanup = [AudioOutput(id: route.deviceID, uid: route.uid, name: "残留组合", transport: kAudioDeviceTransportTypeAggregate)]
        }
    }
    return state
}
