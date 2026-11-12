import AppKit
import SwiftUI
import Testing
import AuralCore
@testable import Aural

@MainActor
struct AppSettingsTests {
    /// 全新安装不应主动显示耳机页或多设备输出入口，用户需要在设置里明确开启。
    @Test func freshInstallKeepsOptionalFeaturesOff() throws {
        let suite = "Aural.AppSettingsDefaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        #expect(!settings.showHeadphoneControls)
        #expect(!settings.showSimultaneousOutput)
        #expect(!settings.showCurrentDeviceBattery)
    }

    @Test func settingsPersistAcrossInstances() throws {
        let suite = "Aural.AppSettingsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.language = .english
        settings.appearance = .dark
        settings.showHeadphoneControls = false
        settings.showSimultaneousOutput = false
        settings.showCurrentDeviceBattery = true

        let restored = AppSettings(defaults: defaults)
        #expect(restored.language == .english)
        #expect(restored.appearance == .dark)
        #expect(!restored.showHeadphoneControls)
        #expect(!restored.showSimultaneousOutput)
        #expect(restored.showCurrentDeviceBattery)
    }

    @Test(arguments: ["zh-Hans", "zh-Hant", "en-US", "ja-JP"])
    func systemLanguageOnlyResolvesToSupportedLanguages(systemLanguage: String) {
        let resolved = AppLanguage.system.resolved(systemLanguage: systemLanguage)
        #expect(systemLanguage.hasPrefix("zh") ? resolved == .chinese : resolved == .english)
    }

    @Test func explicitLanguageDoesNotFollowSystem() {
        #expect(AppLanguage.chinese.resolved(systemLanguage: "en-US") == .chinese)
        #expect(AppLanguage.english.resolved(systemLanguage: "zh-Hans") == .english)
    }

    @Test func headphoneControlsCanBeRemovedFromNavigation() {
        #expect(AudioPanelPage.available(showHeadphoneControls: true) == AudioPanelPage.allCases)
        #expect(AudioPanelPage.available(showHeadphoneControls: false) == [.output, .microphone])
    }

    @Test func englishDictionaryCoversSettingsAndDeviceCopy() {
        #expect(L10n.text("Aural 设置", language: .english) == "Aural Settings")
        #expect(L10n.text("显示多设备输出", language: .english) == "Show Multi-Device Output")
        #expect(L10n.text("多设备输出", language: .english) == "Multi-Device Output")
        #expect(L10n.format("多设备输出 · %d 台", language: .english, arguments: [2])
                == "Multi-Device Output · 2 Devices")
        #expect(L10n.text("显示当前设备剩余电量", language: .english) == "Show Device Battery")
        #expect(L10n.text("检查更新…", language: .english) == "Check for Updates…")
        #expect(L10n.text("未发现新版本", language: .english) == "No Updates Available")
        #expect(L10n.text("开启", language: .english) == "On")
        #expect(L10n.text("关闭", language: .english) == "Off")
        #expect(L10n.text("检查失败，重试", language: .english) == "Check Failed, Retry")
        #expect(L10n.format("发现新版本 %@", language: .english, arguments: ["0.1.11"])
                == "Version 0.1.11 is available")
        #expect(L10n.text("设备未公开可写的硬件静音控制", language: .english)
                == "Device does not expose writable hardware mute")
        #expect(L10n.text("没有这个键", language: .chinese) == "没有这个键")
        #expect(L10n.text("全部输出（默认）", language: .english) == "All Outputs (Default)")
        #expect(L10n.text("已应用自定义路由", language: .english) == "Custom route applied")
    }

    @Test func appAudioRoutesPersistAcrossStoreInstances() throws {
        let suite = "Aural.AppAudioRouteStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let routes: [String: AppAudioRoute] = [
            "bundle:test.browser": .custom(deviceUIDs: ["speaker", "headphone"])
        ]
        try AppAudioRouteStore(defaults: defaults).save(routes)
        let restored = try AppAudioRouteStore(defaults: defaults).load()
        #expect(restored == routes)
    }

    @Test func damagedAppAudioRouteDataReportsAnExplicitReadError() throws {
        let suite = "Aural.AppAudioRouteStoreDamageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("{".utf8), forKey: "local.aural.settings.appAudioRoutes")
        #expect(throws: AppAudioRouteStoreError.self) {
            try AppAudioRouteStore(defaults: defaults).load()
        }
    }

    @Test func settingsWindowUsesTheDeclaredFixedSize() {
        let size = SettingsMetrics.size
        #expect(size.width == 500)
        #expect(size.height == 470)
    }

    @Test func englishSettingDescriptionsFitOneLine() {
        // 按设置窗口、分组和行的真实留白扣除控件宽度，不用缩小字号或截断掩盖换行。
        let availableWidth = SettingsMetrics.width - SettingsMetrics.horizontalInset * 2 - 32 - 12
            - SettingsMetrics.booleanControlWidth
        let keys = [
            "登录 Mac 后自动运行 Aural。",
            "关闭后，耳机控制从主面板隐藏。",
            "关闭后，多设备输出功能从输出面板隐藏。",
            "在菜单栏 Aural 图标右侧显示当前设备电量。"
        ]
        for key in keys {
            let text = L10n.text(key, language: .english)
            let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            #expect(width <= availableWidth)
        }
    }

    @Test @MainActor func segmentedAndBooleanControlsKeepNeutralUnselectedText() throws {
        let renderer = ImageRenderer(content:
            VStack(spacing: 8) {
                PanelSegmentedControl(items: AppAppearance.allCases,
                                      selection: .constant(AppAppearance.system),
                                      title: { appearance in
                    switch appearance {
                    case .system: return "跟随系统"
                    case .light: return "浅色"
                    case .dark: return "深色"
                    }
                })
                PanelBooleanControl(isOn: .constant(false))
            }
            .padding(8)
            .frame(width: SettingsMetrics.controlWidth)
            .background(PanelStyle.canvas)
            .preferredColorScheme(.light)
        )
        let image = try #require(renderer.nsImage)
        let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-settings-controls.png"))
        #expect(image.size.width == SettingsMetrics.controlWidth)
        #expect(SettingsMetrics.booleanControlWidth == 116)
    }

    @Test func settingsViewRendersAtFixedSizeInBothAppearances() throws {
        let suite = "Aural.SettingsViewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        let model = AppModel(startsMonitoring: false)
        for appearance in [AppAppearance.light, .dark] {
            settings.appearance = appearance
            let renderer = ImageRenderer(content:
                SettingsView(model: model, settings: settings)
                    .background(PanelStyle.canvas)
                    .preferredColorScheme(settings.appearance.colorScheme)
            )
            let image = try #require(renderer.nsImage)
            #expect(image.size == SettingsMetrics.size)
            let bitmap = try #require(image.tiffRepresentation.flatMap(NSBitmapImageRep.init(data:)))
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/aural-settings-\(appearance.rawValue).png"))
        }
    }
}
