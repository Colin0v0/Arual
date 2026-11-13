import SwiftUI
import Testing
@testable import Aural

struct PanelTypographyTests {
    // 在真实系统字体下测量布局，防止百分号再次被挤到第二行；不启动音频或耳机控制。
    @Test(arguments: [Float(0), 0.15, 0.99, 1])
    @MainActor func percentageFitsOneLine(value: Float) throws {
        let renderer = ImageRenderer(content: PanelPercentage(value: value))
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == PanelStyle.percentageWidth)
        #expect(image.size.height > 0)
        #expect(image.size.height <= 18)
    }

    @Test @MainActor func tabsRetainCompactHeight() throws {
        let renderer = ImageRenderer(content:
            PanelTabs(items: ["降噪", "透传", "抗风噪"], selection: "降噪", title: { $0 }, select: { _ in })
                .frame(width: 350)
        )
        let image = try #require(renderer.nsImage)
        #expect(image.size.width == 350)
        #expect(image.size.height == 27)
    }

    @Test @MainActor func unknownCurrentModeDoesNotFakeASelectedTab() throws {
        let width: CGFloat = 350
        let noSelection = Optional<String>.none
        let renderer = ImageRenderer(content:
            PanelTabs(items: ["降噪", "通透"], selection: noSelection, title: { $0 }, select: { _ in })
                .frame(width: width)
                .background(PanelStyle.canvas)
                .preferredColorScheme(.light)
        )
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let tabWidth = (width - 4) / 2
        for index in 0..<2 {
            let x = CGFloat(index) * (tabWidth + 4) + 16
            let pixelX = Int(CGFloat(bitmap.pixelsWide) * x / width)
            let color = try #require(
                bitmap.colorAt(x: pixelX, y: bitmap.pixelsHigh / 2)?
                    .usingColorSpace(.deviceRGB)
            )
            #expect(color.redComponent < 0.99)
        }
    }

    @Test(arguments: AudioPanelPage.allCases)
    @MainActor func selectedTabIsWhiteWhileOtherTwoKeepGrayCanvas(selection: AudioPanelPage) throws {
        let width = PanelMetrics.contentWidth
        let pages = AudioPanelPage.allCases
        let renderer = ImageRenderer(content:
            PanelTabs(items: pages, selection: selection, title: { $0.title }, select: { _ in })
                .frame(width: width).background(PanelStyle.canvas).preferredColorScheme(.light)
        )
        let image = try #require(renderer.nsImage)
        #expect(image.size == CGSize(width: PanelMetrics.contentWidth, height: 27))
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let tabWidth = (width - 8) / 3
        for (index, page) in pages.enumerated() {
            // 每个卡片左侧中线取样，避开标题，检查只有选中的一格是白色。
            let x = CGFloat(index) * (tabWidth + 4) + 16
            let pixelX = Int(CGFloat(bitmap.pixelsWide) * x / width)
            let color = try #require(bitmap.colorAt(x: pixelX, y: bitmap.pixelsHigh / 2)?.usingColorSpace(.deviceRGB))
            if page == selection {
                #expect(color.redComponent > 0.999)
                #expect(color.greenComponent > 0.999)
                #expect(color.blueComponent > 0.999)
            } else {
                #expect(color.redComponent < 0.99)
            }
        }
        if selection == .output {
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(fileURLWithPath: "/tmp/aural-three-tabs.png"))
        }
    }

    @Test func mainNavigationHasOneLevelAndKeepsAppControlsOnFirstTwoPages() {
        #expect(AudioPanelPage.allCases.map(\.title) == ["输出", "麦克风", "耳机控制"])
        #expect(AudioPanelPage.output.displaysApplications)
        #expect(AudioPanelPage.microphone.displaysApplications)
        #expect(!AudioPanelPage.headphones.displaysApplications)
    }

    @Test @MainActor func brandMarkUsesExtractedTemplateAtPanelAndStatusSizes() throws {
        let renderer = ImageRenderer(content:
            HStack(spacing: 12) {
                AuralBrandMark(size: 18)
                AuralBrandMark(size: 48)
            }
            .padding(12)
            .background(PanelStyle.canvas)
            .preferredColorScheme(.light)
        )
        let image = try #require(renderer.nsImage)
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-brand-mark.png"))

        let status = AuralStatusIcon.make()
        #expect(status.isTemplate)
        #expect(status.size == CGSize(width: 18, height: 18))
    }
}
