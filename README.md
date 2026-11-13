<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="Aural app icon" />
</p>

<h1 align="center">Aural</h1>

<p align="center"><strong>Your Mac. Your Sound. Your Rules.</strong></p>

<p align="center">
  <strong>English</strong> · <a href="README.zh-CN.md">简体中文</a>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.4%2B-000000?logo=apple&logoColor=white" alt="macOS 15.4 or later" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License" /></a>
</p>

Aural keeps everyday audio controls in one small menu bar panel: switch speakers or microphones, adjust apps separately, use multiple outputs, and control compatible Bluetooth headphones.

> **Stable release · 0.2.4**
>
> Aural is distributed directly and is not Apple-notarized yet. macOS may ask you to confirm the first launch.

## What you can do

- **Switch audio devices** — choose the output or microphone you want without opening System Settings.
- **Control volume and mute** — use the controls your connected device actually supports.
- **Adjust apps separately** — give each playing app its own volume, mute state, and live level meter.
- **Use multiple outputs** — play system audio through more than one speaker or headphone at the same time.
- **Send apps to different outputs** — keep music on your headphones while browser audio stays on your speakers.
- **Control compatible headphones** — check battery, switch noise modes, and manage several headphones in one place.
- **Make it yours** — choose Chinese or English, follow the system appearance, and turn optional features on or off.

Headphone controls and multi-device output are off by default. Turn them on in Settings when you need them.

## Multiple outputs and per-app sound

After you enable **Show Multi-Device Output**, choose two or more outputs from the Output page. Aural keeps them available as one group, while each device keeps its own volume and mute controls.

When apps are playing, each app row can use:

- **All Outputs** — follow every device in the current group. New devices are included automatically.
- **Custom output** — send this app only to the selected devices.

Changing one app's output does not affect other apps or the system-wide output. If a device disconnects temporarily, Aural remembers your choice and restores it when the device comes back.

> Changing an app's output really moves its sound; it is not just a visual setting. You may hear a short gap while the change is applied.

## Headphone support

Available controls vary by model and firmware.

| Headphones | What Aural can do |
| --- | --- |
| Bowers & Wilkins PX / PI | Battery and supported noise-control modes |
| Sony MDR V1 | Battery and supported noise-control modes |
| OPPO Enco | Battery and supported noise modes for identified models |
| AirPods / Beats | Supported listening modes exposed by macOS |

Upstream testing includes Px7 S3, original Px8, Sony WH-1000XM3, and OPPO Enco Air5s. This does not mean every model in the same family is supported.

## Install

1. Download the latest build from [GitHub Releases](https://github.com/Colin0v0/Aural/releases).
2. Open the DMG and drag Aural into Applications.
3. Launch Aural and allow the requested Bluetooth or system-audio permissions if you want to use those features.

Aural currently targets **macOS 15.4 or later on Apple Silicon**.

## Privacy

Aural processes audio locally. It does not save recordings, upload your audio, require an account, or collect telemetry.

Diagnostics may include device names, IDs, or Bluetooth addresses. Remove anything private before sharing diagnostic output.

## Things to know

- Some headphones expose only part of their controls, and compatibility can change with firmware or macOS updates.
- Output switching is not always completely seamless.
- Multiple Bluetooth headphones may have different latency and may not stay perfectly synchronized.
- Sleep, device disconnects, or audio errors can require an app to be applied again.
- Protected audio and some app-specific audio setups may not be supported.
- Sending apps to different outputs is still being tested with real speakers and headphones.

## For developers

Requirements: Swift 6 toolchain and macOS 15.4 or later.

```sh
./Scripts/check.sh
open dist/Aural.app
```

The script runs tests, builds the app, verifies the local signature, and creates `dist/Aural.app`.

Source layout:

- `Sources/Aural` — menu bar UI, settings, and interaction state
- `Sources/AuralCore` — audio devices, app audio processing, meters, and headphone controls
- `Tests` — panel and core test suites
- `ThirdParty` — third-party source notices

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for third-party credits and [docs/CHANGELOG.md](docs/CHANGELOG.md) for release history.

## License

Aural is released under the [MIT License](LICENSE).
