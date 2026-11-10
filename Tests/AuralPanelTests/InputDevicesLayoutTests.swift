import AppKit
import CoreAudio
import SwiftUI
import Testing
import AuralCore
@testable import Aural

struct InputDevicesLayoutTests {
    @Test @MainActor func microphoneRowsReuseSizesAndColorOnlyMuteHover() throws {
        let inputs = [
            AudioInput(id: 1, uid: "fixture-input-a", name: "MacBook Air 麦克风", transport: kAudioDeviceTransportTypeBuiltIn),
            AudioInput(id: 2, uid: "fixture-input-b", name: "USB 麦克风", transport: kAudioDeviceTransportTypeUSB)
        ]
        let available = AudioDeviceControlState.available(volume: AudioDeviceVolume(scalar: 0.7, writable: true),
                                                          mute: AudioDeviceMute(muted: false, writable: true))
        let snapshot = SystemInputSnapshot(inputs: inputs, selectedID: 1, controls: [1: available, 2: available])
        let host = NSHostingView(rootView:
            InputDevicesSection(audio: snapshot, select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in })
                .frame(width: PanelMetrics.width - 24).background(PanelStyle.canvas)
        )
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(host.frame.size == CGSize(width: PanelMetrics.contentWidth, height: 80))
        let buttons = actionButtons(in: host)
        #expect(buttons.count == 2)
        for button in buttons {
            #expect(button.bounds.size == PanelActionMetrics.square)
            #expect(button.hoverStyle == .foregroundOnly)
            button.highlight(true)
            #expect(button.layer?.backgroundColor == NSColor.clear.cgColor)
        }
        let bitmap = try #require(host.bitmapImageRepForCachingDisplay(in: host.bounds))
        host.cacheDisplay(in: host.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: "/tmp/aural-microphone-layout.png"))
    }

    @Test @MainActor func emptyInputListDoesNotProduceFakeMicrophoneControls() {
        let snapshot = SystemInputSnapshot(inputs: [], selectedID: nil, controls: [:])
        let host = NSHostingView(rootView:
            InputDevicesSection(audio: snapshot, select: { _ in }, setVolume: { _, _ in }, setMuted: { _, _ in })
                .frame(width: PanelMetrics.width - 24)
        )
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        #expect(actionButtons(in: host).isEmpty)
        #expect(host.frame.height > 0)
    }

    @MainActor private func actionButtons(in view: NSView) -> [PanelActionControl] {
        if let button = view as? PanelActionControl { return [button] }
        return view.subviews.flatMap { actionButtons(in: $0) }
    }
}
