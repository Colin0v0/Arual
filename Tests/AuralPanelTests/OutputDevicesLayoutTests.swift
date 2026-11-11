import AppKit
import CoreAudio
import SwiftUI
import Testing
import AuralCore
@testable import Aural

struct OutputDevicesLayoutTests {
    @Test func aggregateOutputsAreMovedIntoTheSingleRoutingEntry() {
        let physical = AudioOutput(id: 1, uid: "fixture-speaker",
                                   name: "MacBook Air 扬声器",
                                   transport: kAudioDeviceTransportTypeBuiltIn)
        let thirdPartyAggregate = AudioOutput(id: 2, uid: "fixture-stacked-output",
                                              name: "多输出设备",
                                              transport: kAudioDeviceTransportTypeAggregate)
        let auralAggregate = AudioOutput(id: 3, uid: "local.aural.multi.fixture",
                                         name: "Aural 同时输出",
                                         transport: kAudioDeviceTransportTypeAggregate)

        // 普通设备列表只保留真实硬件，系统、第三方和 Aural 聚合行都不能重复出现。
        let visible = OutputDevicesSection.visibleOutputs(
            [auralAggregate, thirdPartyAggregate, physical],
            hiddenUID: nil
        )
        #expect(visible.map(\.uid) == [physical.uid])
    }

    @Test func simultaneousMembersDoNotAppearAsTheSelectedDefaultOutput() {
        let headphones = Self.fixture.outputs[0]
        let speakers = Self.fixture.outputs[1]

        // 普通单设备模式仍由当前系统默认输出点亮图标。
        #expect(OutputDevicesSection.isSelected(output: headphones, selectedID: headphones.id,
                                                simultaneousUIDs: []))
        // 同时输出启用后，选中状态只属于聚合行，成员行不能继续亮蓝色。
        #expect(!OutputDevicesSection.isSelected(output: headphones, selectedID: 99,
                                                simultaneousUIDs: [headphones.uid, speakers.uid]))
        #expect(!OutputDevicesSection.isSelected(output: speakers, selectedID: 99,
                                                simultaneousUIDs: [headphones.uid, speakers.uid]))
    }

    @Test func simultaneousDraftMovesTheOnlySelectionToItsOwnRow() {
        let headphones = Self.fixture.outputs[0]

        // 草稿已勾选成员时，真实设备行全部熄灯，选中状态只属于下方组合入口。
        #expect(!OutputDevicesSection.isSelected(output: headphones, selectedID: headphones.id,
                                                simultaneousUIDs: [],
                                                selectionSuppressed: true))
        // 空草稿不抑制普通设备选择，界面不会出现 0 个亮灯项。
        #expect(OutputDevicesSection.isSelected(output: headphones, selectedID: headphones.id,
                                               simultaneousUIDs: [],
                                               selectionSuppressed: false))
    }

    @Test @MainActor func allFourDevicesFitOnSingleRowsWithoutEllipsis() throws {
        let snapshot = Self.fixture
        let view = OutputDevicesSection(audio: snapshot, select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in })
            .frame(width: PanelMetrics.width - 24).background(PanelStyle.canvas)
        let host = NSHostingView(rootView: view)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.width == PanelMetrics.contentWidth)
        #expect(host.frame.height == 160)
        let buttons = actionButtons(in: host)
        #expect(buttons.count == 4)
        for button in buttons {
            #expect(button.bounds.size == PanelActionMetrics.square)
            #expect(button.image != nil)
            #expect(button.hoverStyle == .foregroundOnly)
            #expect(button.toolTip?.contains("静音") == true)
        }
        try export(host, to: "/tmp/aural-all-outputs-layout.png")
    }

    @Test @MainActor func deviceIconKeeps28PointCircleAndOriginalLayoutSlot() throws {
        let renderer = ImageRenderer(content:
            AudioDeviceIcon(symbol: "headphones", selected: true).background(PanelStyle.canvas)
        )
        let image = try #require(renderer.nsImage)
        #expect(image.size == CGSize(width: 28, height: 28))
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let scale = CGFloat(bitmap.pixelsWide) / 28
        // 圆底仍覆盖 28pt 占位，边缘内侧应为蓝色，而不是缩小圆底后露出的面板底色。
        let edge = try #require(bitmap.colorAt(x: Int(scale), y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        let inside = try #require(bitmap.colorAt(x: Int(4 * scale), y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
        #expect(edge.redComponent < 0.2)
        #expect(edge.blueComponent > 0.8)
        #expect(inside.redComponent < 0.2)
        #expect(inside.blueComponent > 0.8)
    }

    @Test @MainActor func unsupportedAndFailedControlsDoNotInventSliders() throws {
        let snapshot = Self.fixture
        let first = snapshot.outputs[0]
        let host = NSHostingView(rootView:
            VStack(spacing: 0) {
                AudioDeviceRow(device: first, control: .available(volume: AudioDeviceVolume(scalar: nil, writable: false),
                                                                 mute: AudioDeviceMute(muted: nil, writable: false)),
                                selected: true, select: {}, setVolume: { _ in }, setMuted: { _ in })
                AudioDeviceRow(device: first, control: .failed(message: "设备读取失败测试"),
                                selected: false, select: {}, setVolume: { _ in }, setMuted: { _ in })
            }.frame(width: PanelMetrics.width - 24)
        )
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        let buttons = actionButtons(in: host)
        #expect(buttons.count == 1)
        #expect(buttons.first?.isEnabled == false)
        #expect(host.frame.height <= 80)
    }

    @Test func panelUsesOneHorizontalInsetForSymmetricContent() {
        // 内容宽度与顶栏、行内共用同一个常量，避免外层容器再叠加第二层水平缩进。
        #expect(PanelMetrics.contentWidth == PanelMetrics.width - PanelMetrics.horizontalInset * 2)
    }

    // 只用于布局测试的明确夹具，不写入产品数据源，不修改真实设备或默认输出。
    static var fixture: SystemAudioSnapshot {
        let outputs = [
            AudioOutput(id: 1, uid: "fixture-headphones", name: "Colin Px7 S3", transport: kAudioDeviceTransportTypeBluetooth),
            AudioOutput(id: 2, uid: "fixture-speakers", name: "MacBook Air 扬声器", transport: kAudioDeviceTransportTypeBuiltIn),
            AudioOutput(id: 3, uid: "fixture-monitor-a", name: "Mi Monitor", transport: kAudioDeviceTransportTypeDisplayPort),
            AudioOutput(id: 4, uid: "fixture-monitor-b", name: "Mi Monitor", transport: kAudioDeviceTransportTypeDisplayPort)
        ]
        let values: [Float] = [0.15, 0, 0.5, 1]
        var controls: [UInt32: AudioDeviceControlState] = [:]
        for (output, value) in zip(outputs, values) {
            controls[output.id] = .available(volume: AudioDeviceVolume(scalar: value, writable: true),
                                              mute: AudioDeviceMute(muted: output.id == 2, writable: true))
        }
        return SystemAudioSnapshot(outputs: outputs, selectedID: 1, controls: controls)
    }

    @MainActor private func actionButtons(in view: NSView) -> [PanelActionControl] {
        if let button = view as? PanelActionControl { return [button] }
        return view.subviews.flatMap { actionButtons(in: $0) }
    }

    @MainActor private func export(_ host: NSView, to path: String) throws {
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
