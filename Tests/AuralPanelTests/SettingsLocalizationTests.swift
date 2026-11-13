import AppKit
import SwiftUI
import Testing
import Vision
import AuralCore
@testable import Aural

@MainActor
struct SettingsLocalizationTests {
    /// 直接识别设置页真实渲染结果，覆盖标题已翻译但“关闭 / 开启”仍因缺少环境语言而显示中文的回归。
    @Test func englishSettingsViewLocalizesBooleanControls() throws {
        let suite = "Aural.SettingsLocalizationTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.language = .english
        let model = AppModel(startsMonitoring: false)
        let renderer = ImageRenderer(content: SettingsView(model: model, settings: settings))
        // 设置页正文只有 12pt；提高渲染倍率后，短词 Off / On 才能被稳定识别。
        renderer.scale = 4
        let image = try #require(renderer.nsImage)
        var rect = NSRect(origin: .zero, size: image.size)
        let cgImage = try #require(image.cgImage(forProposedRect: &rect, context: nil, hints: nil))

        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = ["en-US"]
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: cgImage).perform([request])

        let renderedText = (request.results ?? []).compactMap {
            $0.topCandidates(1).first?.string
        }
        // 当前设置页有三组布尔控件；至少全部出现一次，才能证明语言环境确实传到了子视图。
        #expect(renderedText.filter { $0 == "Off" }.count >= 3)
        #expect(renderedText.filter { $0 == "On" }.count >= 3)
    }
}
