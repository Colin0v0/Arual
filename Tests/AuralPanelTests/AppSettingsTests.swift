import AppKit
import SwiftUI
import Testing
@testable import Aural

@MainActor
struct AppSettingsTests {
    /// 全新安装不应主动显示耳机页或同时输出入口，用户需要在设置里明确开启。
    @Test func freshInstallKeepsOptionalFeaturesOff() throws {
        let suite = "Aural.AppSettingsDefaults.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)

        #expect(!settings.showHeadphoneControls)
        #expect(!settings.showSimultaneousOutput)
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

        let restored = AppSettings(defaults: defaults)
        #expect(restored.language == .english)
        #expect(restored.appearance == .dark)
        #expect(!restored.showHeadphoneControls)
        #expect(!restored.showSimultaneousOutput)
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
        #expect(L10n.text("设备未公开可写的硬件静音控制", language: .english)
                == "Device does not expose writable hardware mute")
        #expect(L10n.text("没有这个键", language: .chinese) == "没有这个键")
    }

    @Test func settingsWindowUsesTheDeclaredFixedSize() {
        let size = SettingsMetrics.size
        #expect(size.width == 500)
        #expect(size.height == 430)
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
