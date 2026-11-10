import AppKit
import CoreAudio
import SwiftUI
import Testing
import AuralCore
@testable import Aural

struct HeadphoneSectionLayoutTests {
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
