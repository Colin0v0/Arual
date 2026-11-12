import AppKit
import SwiftUI
import Testing
import AuralCore
@testable import Aural

@MainActor
struct ApplicationPermissionLayoutTests {
    @Test func allPermissionStatesKeepTheAppSectionFreeOfInlinePermissionControls() throws {
        var referenceHeight: CGFloat?
        for access: SystemAudioCaptureAccess in [.authorized, .denied, .notDetermined, .unavailable] {
            let hardware = RoutingTestHardware()
            let environment = ApplicationAudioEnvironment(
                readApplications: { _ in ([], 0) }, hasMixerConflict: { false },
                makeSession: { _, _, _, _ in fatalError("布局测试不应创建音频会话") },
                now: Date.init, captureAccess: { access })
            let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                                 applicationAudio: environment)
            let host = NSHostingView(rootView: ApplicationVolumeSection(
                model: model, metersVisible: false, routingEnabled: false)
                .environment(\.appLanguage, .chinese)
                .frame(width: PanelMetrics.width))
            host.frame.size = host.fittingSize
            host.layoutSubtreeIfNeeded()
            if let referenceHeight {
                #expect(host.fittingSize.height == referenceHeight)
            } else { referenceHeight = host.fittingSize.height }
            // 空 APP 分区在任何权限状态下都没有授权、设置或重新检查按钮。
            #expect(descendants(of: host).compactMap { $0 as? PanelActionControl }.isEmpty)
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/aural-app-permission-\(access.rawValue).png"))
            #expect(model.shutdown())
        }
    }

    @Test func nativePermissionCopySupportsEnglishAndSystemLanguage() {
        for key in ["需要系统音频录制权限", "无法检查系统音频录制权限", "允许访问", "打开系统设置", "取消"] {
            #expect(L10n.text(key, language: .english) != key)
            #expect(L10n.text(key, language: .chinese) == key)
        }
        #expect(AppLanguage.system.resolved(systemLanguage: "en-US") == .english)
        #expect(AppLanguage.system.resolved(systemLanguage: "zh-Hans") == .chinese)
    }

    private func descendants(of view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants(of: $0) }
    }
}
