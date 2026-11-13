import AppKit
import CoreAudio
import IOBluetooth
import SwiftUI
import Testing
@testable import AuralCore
@testable import Aural

@MainActor
struct BoseEarbudPresentationTests {
    /// 测试回包走真实控制器和格式化链路；截图不是 Bose 真机验收结果。
    @Test func earbudPacketsRenderThroughTheExistingPanelAndMenuBar() throws {
        let transport = BoseEarbudUITestTransport()
        let controller = HeadphoneController(
            appleHardware: AppleHeadphoneHardware(
                isSupported: { _ in false }, validateTarget: { _ in },
                snapshot: { _ in throw AudioFailure("不得读取真实硬件") },
                requestMode: { _, _ in Issue.record("截图不得发送模式命令") },
                waitForReadback: { await Task.yield() }),
            boseTransport: transport, validateClassicTarget: { _ in })
        defer { controller.shutdown() }
        let output = AudioOutput(id: 91, uid: "11-22-33-44-55-66:output",
                                 name: "Bose QC Ultra Earbuds II", transport: kAudioDeviceTransportTypeBluetooth)
        controller.updateOutput(output)
        transport.onStatusChange?(.connected)
        transport.onData?(Data([0, 3, 3, 3, 0x40, 0x62, 1]))
        transport.onData?(Data([2, 2, 3, 12, 79, 255, 255, 1, 82, 255, 255, 2, 65, 255, 255, 3]))
        transport.onData?(Data([31, 3, 3, 1, 0]))
        let reading = try #require(controller.state.battery)
        #expect(controller.phase == .ready)
        #expect(controller.supportedNoiseModes == [.cancellation, .transparency])
        #expect(StatusItemBatteryText.title(reading: reading) == "L82 / R79")
        #expect(HeadphoneBatteryText.detail(reading, language: .chinese) == "左 82% · 右 79% · 盒 65%")
        #expect(HeadphoneBatteryText.detail(reading, language: .english) == "L 82% · R 79% · Case 65%")
        #expect(transport.sent.allSatisfy { $0.count == 4 && $0[2] == 1 })

        for appearance in [AppAppearance.light, .dark] {
            let host = NSHostingView(rootView:
                HeadphoneSection(controller: controller, output: output)
                    .frame(width: PanelMetrics.contentWidth)
                    .background(PanelStyle.canvas)
                    .environment(\.appLanguage, .chinese)
                    .preferredColorScheme(appearance.colorScheme))
            host.appearance = appearance.nsAppearance
            host.frame.size = host.fittingSize
            PanelTestSupport.flushLayout(host)
            #expect(host.frame.width == PanelMetrics.contentWidth)
            #expect(host.fittingSize.height < 150)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/aural-bose-earbuds-fixture-\(appearance.rawValue).png"))
        }
    }
}

@MainActor
private final class BoseEarbudUITestTransport: BoseControlTransport {
    var onStatusChange: ((BoseRFCOMMStatus) -> Void)?
    var onData: ((Data) -> Void)?
    var sent: [Data] = []
    func connect(address: String, outputUID: String, endpoint: BoseControlEndpoint) { onStatusChange?(.connecting) }
    func disconnect() { onStatusChange?(.idle) }
    func send(_ data: Data) -> IOReturn { sent.append(data); return kIOReturnSuccess }
}
