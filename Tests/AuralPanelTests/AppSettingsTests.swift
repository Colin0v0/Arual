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
        #expect(!settings.appAudioEffectsEnabled)
        #expect(settings.menuBarBatterySource == .off)
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
        settings.appAudioEffectsEnabled = true
        settings.menuBarBatterySource = .pinned(deviceUID: "Bluetooth:AA-BB-CC-DD-EE-01")

        let restored = AppSettings(defaults: defaults)
        #expect(restored.language == .english)
        #expect(restored.appearance == .dark)
        #expect(!restored.showHeadphoneControls)
        #expect(!restored.showSimultaneousOutput)
        #expect(restored.appAudioEffectsEnabled)
        #expect(restored.menuBarBatterySource == .pinned(deviceUID: "Bluetooth:AA-BB-CC-DD-EE-01"))
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
        #expect(L10n.text("菜单栏电量", language: .english) == "Menu Bar Battery")
        #expect(L10n.text("跟随当前输出", language: .english) == "Follow Current Output")
        #expect(L10n.text("不显示", language: .english) == "Don't Show")
        #expect(L10n.format("固定：%@", language: .english, arguments: ["AirPods"])
                == "Pinned: AirPods")
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
        #expect(L10n.text("启用应用音效", language: .english) == "Enable App Effects")
        #expect(L10n.text("低音增强", language: .english) == "Bass Boost")
        #expect(L10n.text("自动防削波", language: .english) == "Automatic clipping protection")
        #expect(L10n.text("语音增强", language: .english) == "Voice Boost")
        #expect(L10n.text("播客", language: .english) == "Podcast")
        #expect(L10n.text("我的预设", language: .english) == "My Presets")
        #expect(L10n.text("自定义", language: .english) == "Custom")
        #expect(L10n.text("重命名", language: .english) == "Rename")
        #expect(L10n.text("删除", language: .english) == "Delete")
        #expect(L10n.text("另存为预设", language: .english) == "Save as Preset")
        #expect(L10n.text("保存当前配置", language: .english) == "Save current configuration")
        #expect(L10n.text("对比原声", language: .english) == "Compare Original")
        #expect(L10n.text("频响曲线预览；使用下方推子调整",
                          language: .english)
                == "Response curve preview; use the faders below to adjust")
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

    @Test func appAudioEffectsPersistAcrossStoreInstances() throws {
        let suite = "Aural.AppAudioEffectStoreTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        var settings = AppAudioEffectSettings(enabled: true)
        settings.setGain(4, at: 4)
        let values = ["bundle:test.browser": settings]
        try AppAudioEffectStore(defaults: defaults).save(values)
        let restored = try AppAudioEffectStore(defaults: defaults).load()
        #expect(restored == values)
    }

    @Test func damagedAppAudioEffectDataReportsAnExplicitReadError() throws {
        let suite = "Aural.AppAudioEffectStoreDamageTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(Data("{".utf8), forKey: "local.aural.settings.appAudioEffects")
        #expect(throws: AppAudioEffectStoreError.self) {
            try AppAudioEffectStore(defaults: defaults).load()
        }
    }

    @Test func legacyThreeBandEffectDataMigratesToTenBands() throws {
        let suite = "Aural.AppAudioEffectLegacyMigrationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = #"{"bundle:com.apple.Music":{"enabled":false,"highGainDB":0,"lowGainDB":0,"midGainDB":0,"preset":"flat"}}"#.data(using: .utf8)!
        defaults.set(legacy, forKey: "local.aural.settings.appAudioEffects")

        let store = AppAudioEffectStore(defaults: defaults)
        let settings = try store.load()
        let restored = try #require(settings["bundle:com.apple.Music"])
        #expect(restored.preset == .builtIn(.flat))
        #expect(restored.eq == .flat)
        #expect(!restored.enabled)

        // 读回时已经写回新格式；第二次读取不再经过旧字段解析。
        let rewritten = try #require(defaults.data(forKey: "local.aural.settings.appAudioEffects"))
        let decoded = try JSONSerialization.jsonObject(with: rewritten) as? [String: [String: Any]]
        #expect(decoded?["bundle:com.apple.Music"]?["gainsDB"] == nil)
        #expect(decoded?["bundle:com.apple.Music"]?["eq"] != nil)
        #expect(try AppAudioEffectStore(defaults: defaults).load() == settings)
    }

    @Test func legacyCustomEffectDataKeepsToneIntentAndBecomesManual() throws {
        let suite = "Aural.AppAudioEffectLegacyCustomTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let legacy = #"{"bundle:com.google.Chrome":{"enabled":true,"highGainDB":-1,"lowGainDB":4,"midGainDB":2,"preset":"custom"}}"#.data(using: .utf8)!
        defaults.set(legacy, forKey: "local.aural.settings.appAudioEffects")

        let restored = try AppAudioEffectStore(defaults: defaults).load()["bundle:com.google.Chrome"]
        let settings = try #require(restored)
        #expect(settings.enabled)
        #expect(settings.preset == .manual)
        #expect(settings.eq[0] == 4)
        #expect(settings.eq[9] == -1)
        #expect(settings.preampDB == -4)
    }

    @Test func settingsWindowUsesTheDeclaredFixedSize() {
        let size = SettingsMetrics.size
        #expect(size.width == 500)
        #expect(size.height == 520)
    }

    @Test func englishSettingDescriptionsFitOneLine() {
        // 按设置窗口、分组和行的真实留白扣除控件宽度，不用缩小字号或截断掩盖换行。
        let availableWidth = SettingsMetrics.width - SettingsMetrics.horizontalInset * 2 - 32 - 12
            - SettingsMetrics.booleanControlWidth
        let keys = [
            "登录 Mac 后自动运行 Aural。",
            "关闭后，耳机控制从主面板隐藏。",
            "关闭后，多设备输出功能从输出面板隐藏。",
            "为每个应用提供 10 段均衡器和预设。",
            "固定设备断开后隐藏。"
        ]
        for key in keys {
            let text = L10n.text(key, language: .english)
            let width = (text as NSString).size(withAttributes: [.font: NSFont.systemFont(ofSize: 11)]).width
            #expect(width <= availableWidth)
        }
    }

    @Test func legacyBooleanBatterySettingMigratesExplicitly() throws {
        let suite = "Aural.AppSettingsBatteryMigration.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        defaults.set(true, forKey: "local.aural.settings.showCurrentDeviceBattery")
        let enabled = AppSettings(defaults: defaults)
        #expect(enabled.menuBarBatterySource == .currentOutput)
        #expect(defaults.string(forKey: "local.aural.settings.menuBarBatterySource") == "currentOutput")

        defaults.removePersistentDomain(forName: suite)
        defaults.set(false, forKey: "local.aural.settings.showCurrentDeviceBattery")
        let disabled = AppSettings(defaults: defaults)
        #expect(disabled.menuBarBatterySource == .off)
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
        // 截图使用有内容的“跟随当前输出”，同时覆盖最长默认选项在固定宽度内的布局。
        settings.menuBarBatterySource = .currentOutput
        for appearance in [AppAppearance.light, .dark] {
            settings.appearance = appearance
            let host = NSHostingView(rootView:
                SettingsView(model: model, settings: settings)
                    .background(PanelStyle.canvas)
                    .preferredColorScheme(settings.appearance.colorScheme)
            )
            host.appearance = appearance.nsAppearance
            host.frame = NSRect(origin: .zero, size: SettingsMetrics.size)
            PanelTestSupport.flushLayout(host)
            #expect(host.frame.size == SettingsMetrics.size)

            // NSViewRepresentable 的原生菜单按钮必须经真实 AppKit 宿主绘制；ImageRenderer 会显示禁止符号。
            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/aural-settings-\(appearance.rawValue).png"))
        }
    }
}
