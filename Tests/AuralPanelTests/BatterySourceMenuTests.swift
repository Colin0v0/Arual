import AppKit
import CoreAudio
import SwiftUI
import Testing
import AuralCore
@testable import Aural

@MainActor
struct BatterySourceMenuTests {
    @Test func nativeMenuUsesSourceIdentityForIndependentItems() throws {
        let control = BatterySourceMenuControl()
        let selected = MenuBarBatterySource.pinned(deviceUID: "device-a")
        control.update(title: "Pinned: Same Name", selected: selected, items: [
            .init(title: "Don't Show", source: .off),
            .init(title: "Follow Current Output", source: .currentOutput),
            // 故意使用相同标题，证明勾选状态不能按标题猜测。
            .init(title: "Pinned: Same Name", source: .pinned(deviceUID: "device-a"),
                  separatorBefore: true),
            .init(title: "Pinned: Same Name", source: .pinned(deviceUID: "device-b"))
        ], onSelect: { _ in })

        let menu = control.makeMenu()
        #expect(!menu.autoenablesItems)
        #expect(menu.items.map(\.title) == [
            "Don't Show", "Follow Current Output", "", "Pinned: Same Name", "Pinned: Same Name"
        ])
        #expect(menu.items[2].isSeparatorItem)
        #expect(menu.items.map(\.state) == [.off, .off, .off, .on, .off])
    }

    @Test func disconnectedPinnedItemStaysVisibleButDisabled() throws {
        let control = BatterySourceMenuControl()
        control.update(title: "Pinned Device (Disconnected)",
                       selected: .pinned(deviceUID: "offline"), items: [
            .init(title: "Don't Show", source: .off),
            .init(title: "Pinned Device (Disconnected)",
                  source: .pinned(deviceUID: "offline"), enabled: false)
        ], onSelect: { _ in })

        let menu = control.makeMenu()
        let item = try #require(menu.items.last)
        #expect(!item.isEnabled)
        #expect(item.state == .on)
    }

    @Test func triggerWidthGrowsAndKeepsTheWholeTitleInsideItsBounds() throws {
        let control = BatterySourceMenuControl()
        control.update(title: "Don't Show", selected: .off, items: [
            .init(title: "Don't Show", source: .off)
        ], onSelect: { _ in })
        let shortWidth = control.intrinsicContentSize.width
        #expect(shortWidth < 116)

        let title = "Pinned: Colin Px7 S3"
        control.update(title: title, selected: .pinned(deviceUID: "px7"), items: [
            .init(title: title, source: .pinned(deviceUID: "px7"))
        ], onSelect: { _ in })
        let longWidth = control.intrinsicContentSize.width
        let cell = try #require(control.cell as? BatterySourceMenuCell)
        let titleRect = cell.titleRect(forBounds: NSRect(
            x: 0, y: 0, width: longWidth, height: BatterySourceMenuControl.height
        ))
        let titleWidth = ceil((title as NSString).size(
            withAttributes: [.font: BatterySourceMenuControl.font]
        ).width)

        #expect(longWidth > shortWidth)
        // 文字槽至少覆盖完整标题，不依赖配置框裁掉尾部再显示省略号。
        #expect(titleRect.width >= titleWidth)
        #expect(titleRect.maxX < longWidth)
    }

    @Test func pinnedDeviceTitleRendersInsideTheSettingsRow() throws {
        let suite = "Aural.BatterySourceMenuTests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        defer { defaults.removePersistentDomain(forName: suite) }

        let settings = AppSettings(defaults: defaults)
        settings.language = .chinese
        let output = AudioOutput(
            id: 31, uid: "fixture-bw", name: "Colin Px7 S3",
            transport: kAudioDeviceTransportTypeBluetooth
        )
        let group = HeadphoneControllerGroup(makeController: {
            HeadphoneController(appleHardware: AppleHeadphoneHardware(
                isSupported: { $0 == output.id },
                validateTarget: { _ in },
                snapshot: { _ in AppleHeadphoneSnapshot(
                    noiseMode: .transparency,
                    supportedNoiseModes: [.cancellation, .transparency],
                    wearState: .bothEars
                ) },
                requestMode: { _, _ in Issue.record("截图不得写入耳机状态") },
                waitForReadback: { await Task.yield() }
            ))
        })
        group.updateOutputs([output])
        defer { group.shutdown() }
        settings.menuBarBatterySource = .pinned(deviceUID: output.uid)
        #expect(group.entries.map(\.id) == [output.uid])

        for appearance in [AppAppearance.light, .dark] {
            let host = NSHostingView(rootView:
                MenuBarBatterySettingsRow(settings: settings, group: group)
                    .padding(SettingsMetrics.horizontalInset)
                    .frame(width: SettingsMetrics.width, alignment: .leading)
                    .background(PanelStyle.canvas)
                    .preferredColorScheme(appearance.colorScheme)
            )
            host.appearance = appearance.nsAppearance
            host.frame.size = NSSize(width: SettingsMetrics.width, height: 68)
            PanelTestSupport.flushLayout(host)

            let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            let png = try #require(bitmap.representation(using: .png, properties: [:]))
            try png.write(to: URL(
                fileURLWithPath: "/tmp/aural-battery-source-pinned-\(appearance.rawValue).png"
            ))
        }
    }
}
