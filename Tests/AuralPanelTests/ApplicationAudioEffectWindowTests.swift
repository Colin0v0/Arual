import AppKit
import SwiftUI
import Testing
@testable import Aural
@testable import AuralCore

@MainActor
struct ApplicationAudioEffectWindowTests {
    @Test func tenBandEffectWindowUsesTheDeclaredProfessionalLayout() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioEffectWindowTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: AppAudioEffectStore(defaults: defaults),
                             appAudioEffectsEnabled: true)
        var effect = AppAudioEffectSettings(enabled: true, preset: .flat)
        effect.setGain(5, at: 0)
        effect.setGain(3, at: 1)
        effect.setGain(-2, at: 8)
        effect.setGain(-3.5, at: 9)
        model.setApplicationAudioEffect(effect, for: audio.row.id)
        #expect(model.createApplicationAudioEffectPreset(
            named: "预设 1",
            eq: AppAudioEffectPreset.voice.gains
        ) != nil)
        let view = ApplicationAudioEffectView(
            model: model,
            applicationID: audio.row.id,
            appName: audio.row.label,
            applicationURL: nil
        )
        .environment(\.appLanguage, .chinese)
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame.size = ApplicationAudioEffectMetrics.size
        PanelTestSupport.flushLayout(host)

        #expect(host.bounds.width == ApplicationAudioEffectMetrics.width)
        #expect(host.bounds.height == ApplicationAudioEffectMetrics.height)
        #expect(ApplicationAudioEffectMetrics.width >= 640)
        // 曲线网格、频率标签和十根推子共用同一套左右列坐标，不再各自定义内缩。
        let contentWidth = ApplicationAudioEffectMetrics.width - EqualizerLayoutMetrics.padding * 2
        for index in 0..<AppAudioEffectEQ.bandCount {
            let gridX = EqualizerLayoutMetrics.gridX(index, width: contentWidth)
            let faderX = EqualizerLayoutMetrics.faderCenter(index, width: contentWidth)
            #expect(abs(gridX - faderX) < 0.001)
        }
        let heights = EqualizerLayoutMetrics.flexibleHeights(
            in: ApplicationAudioEffectMetrics.height - EqualizerLayoutMetrics.padding * 2,
            hasNotice: false, hasError: false
        )
        #expect(heights.curve >= EqualizerLayoutMetrics.minimumCurveHeight)
        #expect(heights.fader >= EqualizerLayoutMetrics.minimumFaderHeight)
        let bottom = EqualizerLayoutMetrics.padding
            + EqualizerLayoutMetrics.headerHeight
            + EqualizerLayoutMetrics.pageTabHeight
            + EqualizerLayoutMetrics.toolbarHeight
            + EqualizerLayoutMetrics.spacing * 4
            + heights.curve + heights.fader
        #expect(abs(bottom - (ApplicationAudioEffectMetrics.height - EqualizerLayoutMetrics.padding)) < 0.001)
        #expect(AppAudioEffectEQ.bandCount == 10)
        #expect(AppAudioEffectEQ.frequencies == [32, 64, 125, 250, 500, 1_000, 2_000, 4_000, 8_000, 16_000])
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-app-effects-window-light.png"))
        #expect(model.shutdown())
    }

    @Test func tenBandEffectWindowRendersDarkAppearance() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioEffectWindowDarkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: AppAudioEffectStore(defaults: defaults),
                             appAudioEffectsEnabled: true)
        var darkEffect = AppAudioEffectSettings(enabled: true, preset: .music)
        darkEffect.setGain(-2, at: 0)
        darkEffect.setGain(2.5, at: 5)
        darkEffect.setGain(4, at: 8)
        model.setApplicationAudioEffect(darkEffect, for: audio.row.id)
        let view = ApplicationAudioEffectView(
            model: model,
            applicationID: audio.row.id,
            appName: audio.row.label,
            applicationURL: nil
        )
        .environment(\.appLanguage, .english)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame.size = ApplicationAudioEffectMetrics.size
        PanelTestSupport.flushLayout(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-app-effects-window-dark.png"))
        #expect(model.shutdown())
    }

    @Test func spatialPageRendersAndPersistsItsOwnSettings() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioSpatialWindowTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppAudioEffectStore(defaults: defaults)
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: store,
                             appAudioEffectsEnabled: true)
        var effect = AppAudioEffectSettings(enabled: true, preset: .flat)
        effect.spatial = AppAudioSpatialSettings(mode: .hall, intensity: 0.2)
        model.setApplicationAudioEffect(effect, for: audio.row.id)

        let view = ApplicationAudioEffectView(
            model: model,
            applicationID: audio.row.id,
            appName: audio.row.label,
            applicationURL: nil,
            initialPage: .spatial
        )
        .environment(\.appLanguage, .chinese)
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame.size = ApplicationAudioEffectMetrics.size
        PanelTestSupport.flushLayout(host)
        #expect(host.bounds.size == ApplicationAudioEffectMetrics.size)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-app-effects-window-spatial-light.png"))

        #expect(try store.load()["bundle:test.music"]?.spatial == effect.spatial)
        #expect(model.applicationAudioEffect(for: audio.row.id).preset == .builtIn(.flat))
        #expect(model.shutdown())
    }

    @Test func spatialPageRendersDarkAppearance() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioSpatialWindowDarkTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: AppAudioEffectStore(defaults: defaults),
                             appAudioEffectsEnabled: true)
        var effect = AppAudioEffectSettings(enabled: true, preset: .music)
        effect.spatial = AppAudioSpatialSettings(mode: .vocalSpace, intensity: 0.35)
        model.setApplicationAudioEffect(effect, for: audio.row.id)
        let view = ApplicationAudioEffectView(
            model: model,
            applicationID: audio.row.id,
            appName: audio.row.label,
            applicationURL: nil,
            initialPage: .spatial
        )
        .environment(\.appLanguage, .english)
        .environment(\.colorScheme, .dark)
        let host = NSHostingView(rootView: view)
        host.frame.size = ApplicationAudioEffectMetrics.size
        PanelTestSupport.flushLayout(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-app-effects-window-spatial-dark.png"))
        #expect(model.shutdown())
    }

    @Test func closingWindowClearsRuntimeBypass() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioEffectWindowCloseTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: AppAudioEffectStore(defaults: defaults),
                             appAudioEffectsEnabled: true)
        let controller = ApplicationAudioEffectWindowController(model: model)
        let applicationID = audio.row.id
        model.setApplicationAudioEffect(
            AppAudioEffectSettings(enabled: true, preset: .music),
            for: applicationID
        )
        model.setApplicationAudioEffectBypassed(true, for: applicationID)

        controller.show(applicationID: applicationID, appName: audio.row.label,
                        applicationURL: nil)
        let effectWindow = try #require(
            Mirror(reflecting: controller).children.first { $0.label == "window" }?.value
                as? ApplicationAudioEffectWindow
        )
        // 窗口标题只保留功能名，内容区左上角才单独显示应用名，避免两处重复拼接。
        #expect(effectWindow.title == L10n.text("音效", language: AppSettings.shared.resolvedLanguage))
        #expect(!effectWindow.title.contains(audio.row.label))
        effectWindow.close()
        #expect(!model.isApplicationAudioEffectBypassed(for: applicationID))
        #expect(audio.sessions.last?.effect == model.applicationAudioEffect(for: applicationID))
        #expect(model.shutdown())
    }

    @Test func customPresetsPersistAndRemainSharedAcrossStoreInstances() throws {
        let suite = "Aural.AppAudioEffectPresetTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let store = AppAudioEffectStore(defaults: defaults)
        let preset = AppAudioEffectCustomPreset(name: "预设 1", eq: AppAudioEffectPreset.voice.gains)
        try store.savePresets([preset])
        let restored = try AppAudioEffectStore(defaults: defaults).loadPresets()
        #expect(restored == [preset])
    }

    @Test func inlinePresetActionsOnlyAppearForSelectedCustomPreset() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioEffectInlineActionsTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: AppAudioEffectStore(defaults: defaults),
                             appAudioEffectsEnabled: true)
        let applicationID = audio.row.id
        let preset = try #require(model.createApplicationAudioEffectPreset(
            named: "预设 1", eq: AppAudioEffectPreset.voice.gains))
        var settings = AppAudioEffectSettings(enabled: true, preset: .custom(preset.id), eq: preset.eq)
        model.setApplicationAudioEffect(settings, for: applicationID)

        let customView = ApplicationAudioEffectView(model: model, applicationID: applicationID,
                                                   appName: audio.row.label, applicationURL: nil)
        #expect(customView.selectedCustomPreset?.id == preset.id)

        settings.apply(.flat)
        model.setApplicationAudioEffect(settings, for: applicationID)
        let builtInView = ApplicationAudioEffectView(model: model, applicationID: applicationID,
                                                    appName: audio.row.label, applicationURL: nil)
        #expect(builtInView.selectedCustomPreset == nil)

        settings.setGain(1, at: 0)
        model.setApplicationAudioEffect(settings, for: applicationID)
        let manualView = ApplicationAudioEffectView(model: model, applicationID: applicationID,
                                                   appName: audio.row.label, applicationURL: nil)
        #expect(manualView.selectedCustomPreset == nil)
        #expect(model.shutdown())
    }

    @Test func selectedCustomPresetCanBeRenamedAndDeleted() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioEffectInlinePresetMutationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: AppAudioEffectStore(defaults: defaults),
                             appAudioEffectsEnabled: true)
        let applicationID = audio.row.id
        let preset = try #require(model.createApplicationAudioEffectPreset(
            named: "预设 1", eq: AppAudioEffectPreset.voice.gains))
        model.setApplicationAudioEffect(
            AppAudioEffectSettings(enabled: true, preset: .custom(preset.id), eq: preset.eq),
            for: applicationID
        )

        model.renameApplicationAudioEffectPreset(preset.id, to: "人声")
        #expect(model.appAudioEffectCustomPresets == [
            AppAudioEffectCustomPreset(id: preset.id, name: "人声", eq: preset.eq)
        ])

        model.deleteApplicationAudioEffectPreset(preset.id)
        #expect(model.appAudioEffectCustomPresets.isEmpty)
        #expect(model.applicationAudioEffect(for: applicationID).preset == .manual)
        #expect(model.shutdown())
    }

    @Test func customPresetToolbarRendersWithoutBottomPresetManagement() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioEffectInlineActionsSnapshotTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: AppAudioEffectStore(defaults: defaults),
                             appAudioEffectsEnabled: true)
        let preset = try #require(model.createApplicationAudioEffectPreset(
            named: "预设 1", eq: AppAudioEffectPreset.voice.gains))
        model.setApplicationAudioEffect(
            AppAudioEffectSettings(enabled: true, preset: .custom(preset.id), eq: preset.eq),
            for: audio.row.id
        )
        let view = ApplicationAudioEffectView(
            model: model,
            applicationID: audio.row.id,
            appName: audio.row.label,
            applicationURL: nil
        )
        .environment(\.appLanguage, .chinese)
        .environment(\.colorScheme, .light)
        let host = NSHostingView(rootView: view)
        host.frame.size = ApplicationAudioEffectMetrics.size
        PanelTestSupport.flushLayout(host)
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-app-effects-window-custom-preset.png"))
        #expect(model.shutdown())
    }

    @Test func draggingAFaderPreviewsRealTimeDSPBeforeWritingSettings() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioEffectLivePreviewTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = AppAudioEffectStore(defaults: defaults)
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: store,
                             appAudioEffectsEnabled: true)
        let applicationID = audio.row.id
        let original = AppAudioEffectSettings(enabled: true, preset: .flat)
        model.setApplicationAudioEffect(original, for: applicationID)

        var preview = original
        preview.setGain(6, at: 4)
        model.previewApplicationAudioEffect(preview, for: applicationID)

        #expect(audio.sessions.last?.effect == preview)
        #expect(model.applicationAudioEffect(for: applicationID) == original)
        #expect(try store.load()["bundle:test.music"] == original)

        model.setApplicationAudioEffect(preview, for: applicationID)
        #expect(try store.load()["bundle:test.music"] == preview)
        #expect(model.shutdown())
    }

    @Test func aBByassChangesOnlyRuntimeEffectAndKeepsPersistedSettings() throws {
        let hardware = RoutingTestHardware()
        let audio = SessionFixture()
        let suite = "Aural.AppAudioEffectBypassTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }
        let model = AppModel(outputHardware: hardware.hardware, startsMonitoring: false,
                             applicationAudio: audio.environment,
                             appAudioEffectStore: AppAudioEffectStore(defaults: defaults),
                             appAudioEffectsEnabled: true)
        let applicationID = audio.row.id
        let effect = AppAudioEffectSettings(enabled: true, preset: .voice)
        model.setApplicationAudioEffect(effect, for: applicationID)
        #expect(audio.sessions.last?.effect == effect)

        model.setApplicationAudioEffectBypassed(true, for: applicationID)
        #expect(audio.sessions.last?.effect == nil)
        #expect(model.applicationAudioEffect(for: applicationID) == effect)

        model.setApplicationAudioEffectBypassed(false, for: applicationID)
        #expect(audio.sessions.last?.effect == effect)
        #expect(model.shutdown())
    }
}
