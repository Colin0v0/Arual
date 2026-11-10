import AppKit
import SwiftUI
import Testing
@testable import Aural

struct StatusPopupPlacementTests {
    @Test func changingContentHeightDoesNotChangeHorizontalPlacementOrTopAnchor() {
        let screen = CGRect(x: 0, y: 0, width: 1440, height: 876)
        for statusX: CGFloat in [12, 720, 1398] {
            let statusItem = CGRect(x: statusX, y: 876, width: 24, height: 24)
            let initial = StatusPopupMetrics.openingFrame(statusItem: statusItem, screen: screen,
                                                         contentSize: CGSize(width: PanelMetrics.width, height: 400))
            let topLeft = CGPoint(x: initial.minX, y: initial.maxY)
            for height: CGFloat in [300, 318.5, 368, 432.25, 464, 368, 300] {
                let size = CGSize(width: PanelMetrics.width, height: height)
                let frame = StatusPopupMetrics.frame(topLeft: topLeft, size: size)
                #expect(frame.minX == initial.minX)
                #expect(frame.maxY == statusItem.minY - StatusPopupMetrics.topGap)
                #expect(frame.width == PanelMetrics.width)
                #expect(frame.height == height)
            }
        }
    }

    @Test func openingOnlyClampsToCurrentScreenAndSupportsNegativeScreenCoordinates() {
        let screen = CGRect(x: -1440, y: 0, width: 1440, height: 876)
        for statusX: CGFloat in [-1436, -720, -36] {
            let statusItem = CGRect(x: statusX, y: 876, width: 24, height: 24)
            let frame = StatusPopupMetrics.openingFrame(statusItem: statusItem, screen: screen,
                                                       contentSize: CGSize(width: PanelMetrics.width, height: 400))
            #expect(frame.minX >= screen.minX + StatusPopupMetrics.screenInset)
            #expect(frame.maxX <= screen.maxX - StatusPopupMetrics.screenInset)
            #expect(frame.maxY == statusItem.minY - StatusPopupMetrics.topGap)
        }
    }

    @Test @MainActor func realNativePanelKeepsItsAnchorAtEveryAnimationFrame() {
        _ = NSApplication.shared
        let panel = StatusPopupPanel(contentRect: NSRect(x: 400, y: 300, width: PanelMetrics.width, height: 400),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        #expect(panel.canBecomeKey)
        #expect(!panel.canBecomeMain)
        let anchor = CGPoint(x: panel.frame.minX, y: panel.frame.maxY)
        let animator = PanelSizeAnimator()
        animator.resize(window: panel, to: StatusPopupMetrics.frame(topLeft: anchor, size: CGSize(width: PanelMetrics.width, height: 300)), animated: true)
        for _ in 0..<30 {
            RunLoop.main.run(until: Date().addingTimeInterval(0.012))
            #expect(panel.frame.minX == anchor.x)
            #expect(abs(panel.frame.maxY - anchor.y) < 0.001)
        }
        #expect(panel.frame.size == CGSize(width: PanelMetrics.width, height: 300))
    }

    @Test @MainActor func escapeUsesTheExplicitDismissAction() {
        _ = NSApplication.shared
        let panel = StatusPopupPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel],
                                    backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        var dismissed = false
        panel.dismiss = { dismissed = true }
        panel.cancelOperation(nil)
        #expect(dismissed)
    }

    @Test @MainActor func popupPaintsItsBackdropInTheNativeWindowLayer() throws {
        _ = NSApplication.shared
        let panel = StatusPopupPanel(contentRect: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 300),
                                    styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.isReleasedWhenClosed = false
        defer { panel.close() }
        panel.contentView = NSView(frame: NSRect(x: 0, y: 0, width: PanelMetrics.width, height: 300))
        panel.installNativeBackdrop()
        let layer = try #require(panel.contentView?.layer)
        // 与 Magpie 一样由原生图层承担底色和圆角，页面层可以保持透明。
        #expect(layer.backgroundColor == NSColor(PanelStyle.canvas).cgColor)
        #expect(layer.cornerRadius == StatusPopupMetrics.cornerRadius)
        #expect(layer.masksToBounds)
    }

    @Test @MainActor func popupSurfaceHasNoArrowOrReservedTopSpace() throws {
        let renderer = ImageRenderer(content:
            StatusPopupSurface {
                Text("浮层布局测试").frame(maxWidth: .infinity, maxHeight: .infinity).background(PanelStyle.canvas)
            }.frame(width: PanelMetrics.width, height: 300)
                .background(PanelStyle.canvas)
                .clipShape(RoundedRectangle(cornerRadius: StatusPopupMetrics.cornerRadius))
        )
        renderer.scale = 2
        let image = try #require(renderer.nsImage)
        #expect(image.size == CGSize(width: PanelMetrics.width, height: 300))
        let tiff = try #require(image.tiffRepresentation)
        let bitmap = try #require(NSBitmapImageRep(data: tiff))
        // 远离左右圆角的顶部和底部都应有背景，不再有一行透明区域和中间三角形。
        let x = Int(CGFloat(bitmap.pixelsWide) * 32 / PanelMetrics.width)
        for y in [1, bitmap.pixelsHigh - 2] {
            let pixel = try #require(bitmap.colorAt(x: x, y: y))
            #expect(pixel.alphaComponent > 0.99)
        }
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: "/tmp/aural-pinned-popup-surface.png"))
    }
}
