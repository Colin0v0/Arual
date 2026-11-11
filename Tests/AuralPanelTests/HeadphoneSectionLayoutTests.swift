import AppKit
import CoreAudio
import SwiftUI
import Testing
import AuralCore
@testable import Aural

struct HeadphoneSectionLayoutTests {
    @Test @MainActor func multipleControlTargetsRenderStackedCardsWithoutASelector() throws {
        let group = HeadphoneControllerGroup(makeController: {
            HeadphoneController(appleHardware: AppleHeadphoneHardware(
                isSupported: { _ in true }, validateTarget: { _ in },
                snapshot: { _ in AppleHeadphoneSnapshot(noiseMode: .transparency,
                    supportedNoiseModes: [.cancellation, .transparency], wearState: .bothEars) },
                requestMode: { _, _ in Issue.record("渲染卡片不得写入模式") },
                waitForReadback: { await Task.yield() }))
        })
        let candidates = [
            AudioOutput(id: 11, uid: "apple", name: "Podssss", transport: kAudioDeviceTransportTypeBluetooth),
            AudioOutput(id: 12, uid: "bw", name: "Colin Px7 S3", transport: kAudioDeviceTransportTypeBluetooth)
        ]
        group.updateOutputs(candidates)
        let host = NSHostingView(rootView: HeadphoneControlsSection(group: group).frame(width: PanelMetrics.contentWidth))
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(group.entries.map(\.id) == ["apple", "bw"])
        #expect(group.entries.map { $0.controller.boundOutputUID } == ["apple", "bw"])
        #expect(host.fittingSize.height > 160)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-headphones-stacked.png"))
        group.shutdown()
    }

    @Test @MainActor func restrictedAppleWearStatesKeepOnlyHeaderAndBattery() throws {
        var wear = AppleHeadphoneWearState.bothEars
        let controller = HeadphoneController(appleHardware: AppleHeadphoneHardware(
            isSupported: { _ in true }, validateTarget: { _ in },
            snapshot: { _ in AppleHeadphoneSnapshot(noiseMode: .transparency,
                supportedNoiseModes: [.cancellation, .transparency, .adaptive], wearState: wear) },
            requestMode: { _, _ in Issue.record("布局验证不得切换耳机模式") },
            waitForReadback: { await Task.yield() },
            battery: { _ in AppleHeadphoneBattery(left: 97, right: 90, caseLevel: 89) }))
        let output = AudioOutput(id: 11, uid: "fixture-apple", name: "Podssss", transport: kAudioDeviceTransportTypeBluetooth)
        var restrictedHeight: CGFloat?
        for state in [AppleHeadphoneWearState.singleEar, .notWorn, .unknown, .bothEars] {
            wear = state
            controller.updateOutput(output)
            let host = NSHostingView(rootView: HeadphoneSection(controller: controller, output: output)
                .frame(width: PanelMetrics.contentWidth)
                .background(PanelStyle.canvas)
                .environment(\.appLanguage, .chinese)
                .environment(\.colorScheme, .light))
            host.appearance = NSAppearance(named: .aqua)
            host.frame.size = host.fittingSize
            PanelTestSupport.flushLayout(host)
            if state == .bothEars {
                #expect(host.fittingSize.height > (try #require(restrictedHeight)) + 20)
            } else {
                #expect(host.fittingSize.height < 80)
                if let restrictedHeight { #expect(host.fittingSize.height == restrictedHeight) }
                else { restrictedHeight = host.fittingSize.height }
            }
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            let name = state == .bothEars ? "both-ears" : "restricted"
            try png.write(to: URL(fileURLWithPath: "/tmp/aural-apple-\(name).png"))
        }
        controller.shutdown()
    }

    /// 不支持的当前输出只显示耳机标题和连接按钮，删除说明文字后也不再保留空详情区域。
    @Test @MainActor func unsupportedOutputKeepsOnlyTheHeader() throws {
        let controller = HeadphoneController()
        let output = AudioOutput(id: 9, uid: "fixture-display",
                                 name: "Q27G4Z",
                                 transport: kAudioDeviceTransportTypeDisplayPort)
        let host = NSHostingView(rootView:
            HeadphoneSection(controller: controller, output: output)
                .frame(width: PanelMetrics.contentWidth)
                .background(PanelStyle.canvas)
        )
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()

        // 单行标题加内边距不会超过 80pt；加入过说明详情后会明显高于该值。
        #expect(host.frame.height < 80)

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-headphone-unsupported.png"))
    }
}
