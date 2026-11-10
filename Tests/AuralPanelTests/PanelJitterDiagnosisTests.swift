import AppKit
import CoreGraphics
import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import Testing
@testable import Aural

private typealias CaptureFn = @convention(c) (CGRect, CGWindowListOption, CGWindowID, CGWindowImageOption) -> Unmanaged<CGImage>?

private func captureImage(_ rect: CGRect) -> CGImage? {
    guard let handle = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW),
          let symbol = dlsym(handle, "CGWindowListCreateImage") else { return nil }
    let fn = unsafeBitCast(symbol, to: CaptureFn.self)
    return fn(rect, .optionOnScreenOnly, kCGNullWindowID, [.bestResolution])?.takeRetainedValue()
}

/// 临时诊断：抓真实面板的逐帧像素，量窗口内内容是否整体移动/拉伸。
@MainActor
struct PanelJitterDiagnosisTests {
    @Test func realPanelContentJitter() throws {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.accessory)
        try? FileManager.default.removeItem(atPath: "/tmp/jitter-frames")
        try? FileManager.default.createDirectory(atPath: "/tmp/jitter-frames", withIntermediateDirectories: true)

        let model = AppModel()
        let layout = PanelPresentationLayout()
        layout.selectPage(AudioPanelPage.output)
        let size = layout.size
        let screen = NSScreen.main!
        let top = screen.visibleFrame.maxY - 20
        let originX = screen.frame.midX - size.width / 2
        let panel = StatusPopupPanel(contentRect: CGRect(x: originX, y: top - size.height, width: size.width, height: size.height),
                                     styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.isMovable = false
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.level = .popUpMenu
        panel.collectionBehavior = [.transient, .moveToActiveSpace, .fullScreenAuxiliary]
        panel.animationBehavior = .none
        let animator = PanelSizeAnimator()
        let topLeft = CGPoint(x: originX, y: top)
        let host = NSHostingController(rootView: StatusPopupSurface {
            AudioPanel(model: model, layout: layout, openSettings: {}, panelSizeChanged: { newSize in
                guard newSize == layout.size else { return }
                let target = StatusPopupMetrics.frame(topLeft: topLeft, size: newSize)
                // 诊断当前菜单栏浮层的真实路径：宿主完成布局后一次性落到目标外框。
                animator.settleAfterLayout(window: panel, to: target)
            }, surface: .popover)
        })
        host.sizingOptions = []
        host.view.setFrameSize(size)
        panel.contentViewController = host
        panel.orderFrontRegardless()
        layout.beginPresentation()
        model.setMeteringVisible(true, for: .popover)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
        print("DIAG settled layout=\(layout.size) frame=\(panel.frame) window=\(panel.windowNumber) host=\(host.view.frame)")

        let primaryHeight = NSScreen.screens[0].frame.height
        let margin: CGFloat = 20
        let region = CGRect(x: panel.frame.minX - margin,
                            y: primaryHeight - panel.frame.maxY - margin,
                            width: panel.frame.width + margin * 2,
                            height: panel.frame.height + margin * 2)
        let scale = screen.backingScaleFactor
        var frameIndex = 0

        func savePNG(_ image: CGImage, _ name: String) {
            let url = URL(fileURLWithPath: "/tmp/jitter-frames/\(name).png")
            guard let destination = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return }
            CGImageDestinationAddImage(destination, image, nil)
            CGImageDestinationFinalize(destination)
        }

        func sample(_ tag: String) {
            guard let image = captureImage(region) else { print("DIAG capture failed"); return }
            let width = image.width, height = image.height
            var data = [UInt8](repeating: 0, count: width * height * 4)
            guard let context = CGContext(data: &data, width: width, height: height, bitsPerComponent: 8,
                                          bytesPerRow: width * 4, space: CGColorSpaceCreateDeviceRGB(),
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return }
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            frameIndex += 1
            savePNG(image, String(format: "%03d-%@", frameIndex, tag))

            // 行投影：整宽统计"明显非背景"像素数，用来做帧间垂直互相关。
            var profile = [Int](repeating: 0, count: height)
            for row in 0..<height {
                var count = 0
                for col in 0..<width {
                    let i = row * width * 4 + col * 4
                    let r = Int(data[i]), g = Int(data[i + 1]), b = Int(data[i + 2])
                    let luminance = (r * 299 + g * 587 + b * 114) / 1000
                    if luminance < 170 { count += 1 }
                }
                profile[row] = count
            }
            // 页签白色胶囊：在第 2 段（y 24..80pt）找纯白行
            let whiteTop = Int(26 * scale), whiteBottom = Int(72 * scale)
            var pillRows: [Int] = []
            for row in whiteTop..<min(whiteBottom, height) {
                let i = row * width * 4 + (width / 2) * 4
                if data[i] > 250 && data[i + 1] > 250 && data[i + 2] > 250 { pillRows.append(row) }
            }
            let line = "\(tag) h=\(String(format: "%.2f", panel.frame.height)) top=\(Int(panel.frame.maxY)) "
                + "pill=\(pillRows.first ?? -1)...\(pillRows.last ?? -1) "
                + "hostY=\(String(format: "%.2f", host.view.frame.minY))=h\(String(format: "%.2f", host.view.frame.height)) "
                + "profile=\(profile.prefix(0).count)"
            print("DIAG", line)
            let url = URL(fileURLWithPath: "/tmp/jitter-frames/profile-\(String(format: "%03d", frameIndex)).txt")
            try? profile.map(String.init).joined(separator: ",").write(to: url, atomically: true, encoding: .utf8)
        }

        sample("initial")
        let tabWidth = (PanelMetrics.width - 24 - 8) / 3
        func clickTab(_ index: Int) {
            let x = 12 + tabWidth / 2 + CGFloat(index) * (tabWidth + 4)
            let y = panel.contentLayoutRect.height - 57
            let point = NSPoint(x: x, y: y)
            let now = ProcessInfo.processInfo.systemUptime
            let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [],
                                          timestamp: now, windowNumber: panel.windowNumber, context: nil,
                                          eventNumber: 0, clickCount: 1, pressure: 1)
            let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [],
                                        timestamp: now + 0.01, windowNumber: panel.windowNumber, context: nil,
                                        eventNumber: 1, clickCount: 1, pressure: 0)
            if let down { panel.sendEvent(down) }
            RunLoop.main.run(until: Date().addingTimeInterval(0.02))
            if let up { panel.sendEvent(up) }
        }

        for target in [1, 2, 0] {
            clickTab(target)
            let deadline = Date().addingTimeInterval(0.30)
            while Date() < deadline {
                RunLoop.main.run(until: Date().addingTimeInterval(0.008))
                sample("tab\(target)")
            }
            RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            sample("settled\(target)")
        }
        panel.orderOut(nil)
        model.setMeteringVisible(false, for: .popover)
    }
}
