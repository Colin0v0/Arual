import AppKit
import SwiftUI
import Testing
@testable import Aural

struct AuralUpdateBadgeSnapshotTests {
    @Test func onlyAvailableAndFailedCanBeSkippedWhileEnglishCopyFits() {
        #expect(AuralUpdateBadge.showsDismiss(.available))
        #expect(AuralUpdateBadge.showsDismiss(.failed("失败")))
        #expect(!AuralUpdateBadge.showsDismiss(.downloading(progress: 0.5)))
        #expect(!AuralUpdateBadge.showsDismiss(.preparing))
        #expect(!AuralUpdateBadge.showsDismiss(.ready))
        #expect(!AuralUpdateBadge.showsDismiss(.idle))
        #expect(!AuralUpdateBadge.usesTextPresentation(.available, presentation: .capsule))
        #expect(AuralUpdateBadge.usesTextPresentation(.available, presentation: .text))
        #expect(!AuralUpdateBadge.usesTextPresentation(.failed("失败"), presentation: .text))
        #expect(!AuralUpdateBadge.usesTextPresentation(.downloading(progress: 0.5), presentation: .text))
        #expect(!AuralUpdateBadge.usesTextPresentation(.preparing, presentation: .text))
        #expect(!AuralUpdateBadge.usesTextPresentation(.ready, presentation: .text))
        #expect(!AuralUpdateBadge.usesTextPresentation(.idle, presentation: .text))
        #expect(L10n.text("未发现新版本", language: .english) == "No Updates Available")
    }

    @Test @MainActor func rendersBadgeStatesForVisualReview() throws {
        let view = VStack(alignment: .leading, spacing: 10) {
            AuralUpdateBadge(phase: .available, version: "0.1.12", language: .chinese,
                             action: {}, skip: {})
            AuralUpdateBadge(phase: .available, version: "0.1.12", language: .chinese,
                             action: {}, skip: {}, presentation: .text)
            AuralUpdateBadge(phase: .downloading(progress: 0.64), version: "0.1.12", language: .chinese,
                             action: {}, skip: {})
            AuralUpdateBadge(phase: .preparing, version: "0.1.12", language: .chinese,
                             action: {}, skip: {})
            AuralUpdateBadge(phase: .ready, version: "0.1.12", language: .chinese,
                             action: {}, skip: {})
            AuralUpdateBadge(phase: .failed("网络不可用"), version: "0.1.12", language: .chinese,
                             action: {}, skip: {})
        }
        .padding(20)
        .background(PanelStyle.canvas)
        .environment(\.colorScheme, .light)
        .frame(width: 240, alignment: .leading)

        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        guard let image = renderer.nsImage else {
            Issue.record("无法渲染浅色更新胶囊")
            return
        }
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/aural-update-badge-light.png"))

        let darkView = VStack(alignment: .leading, spacing: 10) {
            AuralUpdateBadge(phase: .available, version: "0.1.12", language: .english,
                             action: {}, skip: {})
            AuralUpdateBadge(phase: .available, version: "0.1.12", language: .english,
                             action: {}, skip: {}, presentation: .text)
            AuralUpdateBadge(phase: .downloading(progress: 0.64), version: "0.1.12", language: .english,
                             action: {}, skip: {})
            AuralUpdateBadge(phase: .preparing, version: "0.1.12", language: .english,
                             action: {}, skip: {})
            AuralUpdateBadge(phase: .ready, version: "0.1.12", language: .english,
                             action: {}, skip: {})
            AuralUpdateBadge(phase: .failed("Network unavailable"), version: "0.1.12", language: .english,
                             action: {}, skip: {})
        }
        .padding(20)
        .background(PanelStyle.canvas)
        .environment(\.colorScheme, .dark)
        .frame(width: 280, alignment: .leading)
        let darkRenderer = ImageRenderer(content: darkView)
        darkRenderer.scale = 2
        let darkImage = try #require(darkRenderer.nsImage)
        let darkTiff = try #require(darkImage.tiffRepresentation)
        let darkBitmap = try #require(NSBitmapImageRep(data: darkTiff))
        let darkData = try #require(darkBitmap.representation(using: .png, properties: [:]))
        try darkData.write(to: URL(fileURLWithPath: "/tmp/aural-update-badge-dark.png"))
        #expect(image.size.width > 0)
    }

    @Test @MainActor func availableUpdateUsesInlineTextInPanelAndSettings() throws {
        let suite = "Aural.UpdatePromptSnapshots.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let originalAppearance = settings.appearance
        settings.appearance = .light
        defer {
            // AppSettings 会同步修改 NSApp 外观，截图后必须恢复，避免影响原生颜色测试。
            settings.appearance = originalAppearance
            settings.applyApplicationAppearance()
        }
        settings.language = .chinese
        let model = AppModel(startsMonitoring: false)
        let checker = AuralUpdateChecker.shared
        checker.installPreviewUpdate(version: "0.1.14")
        defer { checker.clearPreviewUpdate() }

        for appearance in [AppAppearance.light, .dark] {
            settings.appearance = appearance
            // 主面板只保留真实顶栏排版与共同更新组件，避免 AppKit 图标在离屏渲染中变成占位符。
            let panelView = VStack(spacing: 0) {
                HStack(spacing: 7) {
                    AuralBrandMark(size: 18)
                    Text("Aural").font(PanelStyle.titleFont)
                    Spacer()
                    AuralUpdateBadge(phase: .available, version: "0.1.14", language: .chinese,
                                     action: {}, skip: {})
                    Image(systemName: "gearshape")
                        .font(.system(size: 15, weight: .regular))
                        .foregroundStyle(PanelStyle.secondary)
                        .frame(width: 26, height: 26)
                }
                .padding(.horizontal, PanelMetrics.horizontalInset)
                .frame(height: 44)
                PanelTabs(items: ["输出", "麦克风"], selection: "输出",
                          title: { $0 }, select: { _ in })
                    .padding(.horizontal, PanelMetrics.horizontalInset)
                    .padding(.bottom, 9)
                Spacer(minLength: 0)
            }
            .frame(width: PanelMetrics.width, height: 150)
            .background(PanelStyle.canvas)
            .overlay { RoundedRectangle(cornerRadius: StatusPopupMetrics.cornerRadius)
                .strokeBorder(PanelStyle.line, lineWidth: 1) }
            .preferredColorScheme(appearance.colorScheme)
            try writeSnapshot(panelView,
                              path: "/tmp/aural-update-text-panel-\(appearance.rawValue).png")

            // 设置页使用真实 500×470 窗口，重点检查页脚不再被胶囊撑到底边。
            let settingsView = SettingsView(model: model, settings: settings)
                .preferredColorScheme(appearance.colorScheme)
            try writeSnapshot(settingsView,
                              path: "/tmp/aural-update-text-settings-\(appearance.rawValue).png")
        }
    }

    @MainActor
    private func writeSnapshot<V: View>(_ view: V, path: String) throws {
        let renderer = ImageRenderer(content: view)
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
