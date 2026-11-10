<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="Aural app icon" />
</p>

<h1 align="center">Aural</h1>

<p align="center">Native macOS menu bar audio control</p>

<p align="center">
  <strong>English</strong> · <a href="README.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.4%2B-000000?logo=apple&logoColor=white" alt="macOS 15.4 or later" />
  <img src="https://img.shields.io/badge/Swift-6-F05138?logo=swift&logoColor=white" alt="Swift 6" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License" /></a>
</p>

Aural brings system outputs, microphones, per-app volume, and Bluetooth headphone controls into one menu bar panel. The interface is built with SwiftUI, device and application audio are managed through Core Audio, and supported headphones use their respective Bluetooth protocols or macOS system properties.

> **Development preview · 0.1.9**
>
> The source tree is still under validation. Protocol integration does not mean every device has completed compatibility testing. When a production installer is published, refer to the release notes for that version.

## Features

| Capability | Description |
| --- | --- |
| Output devices | View system outputs, change the default output, and adjust hardware volume or mute where exposed |
| Microphone | Change the default input and adjust supported input volume or hardware mute |
| Per-app audio | Adjust volume and mute independently for apps playing audio, with live peak meters |
| Headphone controls | Read supported headphone state and switch listening modes according to device capabilities |
| Multi-device output | Select one or more outputs from one entry and adjust each member's volume |
| Preferences | Chinese and English UI, system/light/dark appearance, optional feature visibility, and launch at login |

Headphone controls, the multi-device output entry, and launch at login are off by default.

## System audio

The Output and Microphone pages manage default output and input independently. Volume and mute capabilities are read from the hardware. If a device does not expose a writable property, the corresponding control is unavailable rather than filled with a guessed value.

- Click a device name to change the system route.
- Moving a volume slider affects only that device.
- Apps that select their own audio device may not follow the system default output.
- The Microphone page manages system input devices without recording microphone audio.

## Per-app audio

Aural shows apps based on Core Audio playback activity and merges helper processes only when their ownership can be verified. Paused apps are hidden, while volume and mute settings remain for the current Aural session.

- **Volume range:** 0–100%. 100% means no attenuation; it is not the app's internal volume and does not provide gain boost.
- **Live meters:** peak level, not speaker SPL. Managed-app levels reflect audio after Aural's gain and mute processing.
- **State changes:** output changes, sleep, or processing errors may pause management until the user applies it again.
- **Format support:** the current processing path requires a supported Float32 stereo format. Protected audio such as DRM content is not guaranteed.

Avoid enabling application-audio management in another utility for the same apps at the same time.

## Headphone compatibility

The table below describes current protocol integration, not a complete certification list. Actual features depend on the headphone model, firmware, macOS version, and capabilities exposed by the device.

| Family or protocol | State readout | Listening-mode control | Scope |
| --- | --- | --- | --- |
| Bowers & Wilkins PX / PI family | Battery, mode | Noise cancellation / ambient mode on identified models | BLE RPC control with hardware identity verification; unknown mode mappings are not written |
| Sony MDR V1 | Battery, mode | Noise cancellation / ambient mode according to protocol capability | V1 only; Sony V2 / Link2 is not supported |
| OPPO Enco | Battery, mode | Noise modes for identified products | Noise-control writes are not enabled for unknown product IDs |
| AirPods / Beats | System-exposed listening state | Noise cancellation / transparency / adaptive modes where available | BTAudio HAL control; battery and all modes are not universally guaranteed |

HeadBridge upstream has recorded validation for **Px7 S3, original Px8, Sony WH-1000XM3, and OPPO Enco Air5s**. Those records are not Aural's local test results and do not imply that every model in the same family is compatible.

Headphone controls are bound to the current system output. Mode writes require a real readback confirmation. Aural does not perform firmware updates, factory reset, or unconfirmed mode writes.

## Multi-device output

After enabling **Show Multi-Device Output** in Settings, a single entry appears at the bottom of the Output page. Expand it to choose devices and adjust member volumes.

- **Selection applies immediately:** there is no separate Start button, and at least one output must remain selected.
- **Single-device mode:** selecting one device uses the physical hardware directly without creating a one-member aggregate device.
- **Multi-device mode:** selecting two or more devices creates a Core Audio multi-output device.
- **Member volume:** each member keeps its own hardware volume and mute controls.
- **Leaving the route:** click an ordinary output device to stop the aggregate route and switch to that device.

Per-app volume and live meters are paused while a multi-device aggregate is active. They remain available when using one eligible physical device.

Bluetooth and speakers may have different fixed latency. Stable playback through two Bluetooth headsets at the same time is not guaranteed. Disconnects, sample-rate changes, or clock configuration changes may make the aggregate route unavailable.

> **Validation notice:** AirPods were reported to keep playing after being deselected. Routing and state verification have been updated, but the latest fix still requires confirmation by listening on hardware.

## Settings

| Setting | Options or behavior |
| --- | --- |
| Interface language | System, Simplified Chinese, English |
| Appearance | System, Light, Dark |
| Show headphone controls | Controls whether the headphone entry appears in the main panel; off by default |
| Show multi-device output | Controls whether the output entry appears on the Output page; off by default |
| Launch at login | Managed through the macOS login item service; off by default |

Clicking the gear opens Settings directly. Left-clicking the menu bar icon toggles the panel. The context menu provides Open, Settings, and Quit actions.

## Requirements

- macOS **15.4 or later**.
- The current local build targets **Apple Silicon (arm64)**. Intel has not been validated.
- Building requires a Swift 6 toolchain. The package uses Swift 5 language mode and has no external Swift package dependencies.

## Build and verification

Use the following commands for local development and validation:

```sh
./Scripts/check.sh
open dist/Aural.app
```

The script runs unit tests, builds the app, checks the local signature, and runs read-only device diagnostics. It produces `dist/Aural.app` with an ad-hoc local signature, which is not equivalent to Developer ID signing and Apple notarization.

## Permissions and privacy

| Permission | Purpose |
| --- | --- |
| Bluetooth | Discover and control supported Bluetooth headphones |
| System audio access | Per-app volume processing and real-time level metering |

First launch triggers the related permission requests. Denying access may make the corresponding features unavailable; requesting permission does not by itself prove that it was granted.

Audio is processed locally in real time. Aural does not save recordings or upload audio, and it has no accounts, telemetry, or automatic updater. Diagnostics may contain device UIDs, Bluetooth addresses, and app information; redact them before sharing.

## Known limitations

- Protocol integration is not the same as hardware validation for every supported model.
- Multi-device output cannot guarantee zero latency differences or long-term synchronization between two Bluetooth headsets.
- Output changes, sleep, or processing errors may interrupt per-app audio management and require the user to apply it again.
- Devices without a writable hardware volume property do not receive simulated volume controls.
- Per-app processing does not cover every audio format or protected content.
- AirPods deselection behavior in multi-device output still requires confirmation on the latest build.

## Architecture

| Module | Responsibility |
| --- | --- |
| `Sources/Aural` | SwiftUI menu bar UI, Settings, panel state, and interaction coordination |
| `Sources/AuralCore` | Core Audio device access, per-app processing, meters, and headphone controls |
| `Tests/AuralPanelTests` | Panel layout, interaction state, and settings tests |
| `Tests/AuralCoreTests` | Audio lifecycle, protocols, device state, and control logic tests |
| `ThirdParty` | Third-party source provenance and license texts |

## Acknowledgments

- [HeadBridge](https://github.com/herenickname/HeadBridge) for headphone protocol research and the upstream B&W, Sony, and OPPO protocol implementations.
- [pods-control](https://github.com/raulgg/pods-control) for its public reference implementation of BTAudio HAL listening-mode controls for AirPods / Beats.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for the exact reuse scope, modifications, and license terms. These acknowledgments do not imply upstream endorsement or a compatibility guarantee.

## License

Aural is licensed under the [MIT License](LICENSE). Third-party code retains its respective copyright and license notices; the app bundle includes the corresponding license files.
