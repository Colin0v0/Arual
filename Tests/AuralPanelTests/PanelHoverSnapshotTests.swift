import AppKit
import CoreAudio
import SwiftUI
import Testing
import AuralCore
@testable import Aural

struct PanelHoverSnapshotTests {
    @Test @MainActor func hoverEffectsRenderWithNativeControlsInBothAppearances() throws {
        let outputs = [
            AudioOutput(id: 1, uid: "headphones", name: "Colin Px7 S3", transport: kAudioDeviceTransportTypeBluetooth),
            AudioOutput(id: 2, uid: "speakers", name: "MacBook Air 扬声器", transport: kAudioDeviceTransportTypeBuiltIn),
            AudioOutput(id: 3, uid: "monitor", name: "Mi Monitor", transport: kAudioDeviceTransportTypeDisplayPort)
        ]
        var controls: [UInt32: AudioDeviceControlState] = [:]
        let volumes: [Float] = [0.2, 0, 0.7]
        for (index, output) in outputs.enumerated() {
            controls[output.id] = .available(
                volume: AudioDeviceVolume(scalar: volumes[index], writable: true),
                mute: AudioDeviceMute(muted: index == 1, writable: true)
            )
        }

        // 第三行在首帧就是悬停态，截图不必尝试伪造鼠标事件。
        let deviceList = VStack(spacing: 0) {
            AudioDeviceRow(device: outputs[0], control: controls[1]!, selected: true,
                           select: {}, setVolume: { _ in }, setMuted: { _ in })
            AudioDeviceRow(device: outputs[1], control: controls[2]!, selected: false,
                           select: {}, setVolume: { _ in }, setMuted: { _ in })
            AudioDeviceRow(device: outputs[2], control: controls[3]!, selected: false,
                           select: {}, setVolume: { _ in }, setMuted: { _ in },
                           initiallyHovered: true)
        }
        .frame(width: PanelMetrics.contentWidth)
        .background(PanelStyle.canvas)

        let settingsPage = VStack(alignment: .leading, spacing: 14) {
            SettingsCard(title: "通用") {
                SettingsRow(title: "界面语言", initiallyHovered: true) {
                    PanelSegmentedControl(items: AppLanguage.allCases,
                                          selection: .constant(AppLanguage.chinese),
                                          title: { language in
                        switch language {
                        case .system: return "跟随系统"
                        case .chinese: return "简体中文"
                        case .english: return "English"
                        }
                    })
                    .frame(width: SettingsMetrics.controlWidth)
                }
                PanelDivider()
                SettingsToggleRow(title: "开机启动",
                                  detail: "登录 Mac 后自动运行 Aural。",
                                  isOn: .constant(true))
            }
            SettingsCard(title: "功能") {
                SettingsToggleRow(title: "显示当前设备剩余电量",
                                  detail: "在菜单栏 Aural 图标右侧显示当前设备电量。",
                                  isOn: .constant(true),
                                  initiallyHovered: true)
            }
        }
        .padding(18)
        .frame(width: SettingsMetrics.width, alignment: .leading)
        .background(PanelStyle.canvas)

        let deviceCanvas = VStack(spacing: 0) {
            Text("输出设备 · 悬停效果")
                .font(PanelStyle.captionFont)
                .foregroundStyle(PanelStyle.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            deviceList
        }
        .frame(width: PanelMetrics.width)
        .background(PanelStyle.canvas)

        try render(deviceCanvas.preferredColorScheme(.light),
                   path: "/tmp/aural-device-hover-light.png", dark: false)
        try render(deviceCanvas.preferredColorScheme(.dark),
                   path: "/tmp/aural-device-hover-dark.png", dark: true)
        try render(settingsPage.preferredColorScheme(.light),
                   path: "/tmp/aural-settings-hover-light.png", dark: false)
        try render(settingsPage.preferredColorScheme(.dark),
                   path: "/tmp/aural-settings-hover-dark.png", dark: true)
        #expect(outputs.count == 3)
    }

    /// 原生 Picker、Toggle 和 NSButton 必须通过真实宿主绘制；ImageRenderer 会把它们画成禁止符号。
    @MainActor private func render<V: View>(_ view: V, path: String, dark: Bool) throws {
        // NSHostingView 不会从 preferredColorScheme 自动继承窗口外观；
        // 截图测试同时写入 SwiftUI colorScheme 和宿主 NSAppearance，动态 NSColor 才能解析成深色。
        let host = NSHostingView(rootView:
            view.environment(\.colorScheme, dark ? .dark : .light)
        )
        host.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        // 空跑一轮主循环，让 SwiftUI 完成首次挂载和原生控件排版后再抓取位图。
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.08))
        host.layoutSubtreeIfNeeded()

        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        try png.write(to: URL(fileURLWithPath: path))
    }
}
