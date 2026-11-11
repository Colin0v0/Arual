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
        #expect(L10n.text("未发现新版本", language: .english) == "No Updates Available")
    }

    @Test @MainActor func rendersBadgeStatesForVisualReview() throws {
        let view = VStack(alignment: .leading, spacing: 10) {
            AuralUpdateBadge(phase: .available, version: "0.1.12", language: .chinese,
                             action: {}, skip: {})
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
}
