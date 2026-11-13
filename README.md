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

<p align="center">
  <a href="https://github.com/Colin0v0/Aural/releases"><strong>Download the latest release</strong></a>
  ·
  <a href="docs/HEADPHONE_COMPATIBILITY.md">Headphone compatibility</a>
</p>

Aural keeps your Mac’s sound close at hand, right from the menu bar. Switch
devices, give each app the level it needs, send audio to more than one place,
and check on your headphones. Open an app’s Effects window when you want to
shape its sound.

> **Current release: 0.3.1**
>
> Aural is distributed directly and is not notarized yet. macOS may ask you to
> confirm the first launch.

## What you can do

- **Switch audio quickly** — choose your output or microphone from the menu bar.
- **Mix apps independently** — give each playing app its own volume, mute state,
  and live level meter.
- **Use multiple outputs** — send system audio to more than one speaker or
  headphone at the same time.
- **Route apps separately** — keep music on your headphones while browser audio
  stays on your speakers.
- **Shape app sound** — open a dedicated window with a 10-band EQ fader bank,
  response preview, custom presets, and Compare Original without changing the
  app’s volume or output route.
- **Control headphones** — check battery, switch noise modes, and manage
  multiple headphones in one place.
- **Make it yours** — use English or Chinese, follow the system appearance, and
  enable only the features you need.

App effects, headphone controls, and multi-device output are off by default.
Turn on what you need in Settings.

## Multiple outputs, per-app routing

When you enable **Show Multi-Device Output**, choose two or more outputs and
Aural treats them as one group. Each device keeps its own volume and mute
controls.

Each playing app can use:

- **All Outputs** — follow the whole group, including devices added later.
- **Custom output** — play only through the devices you select.

Changing one app’s route does not change other apps or the system output.
Aural remembers custom routes across device disconnects and restores them when
the device returns.

## App effects

Open an app’s Effects window from its row in Aural. Start with one of six
built-in presets, save the current setup as your own, or use the ten faders to
shape the sound. Rename or delete a custom preset from the toolbar while it is
selected, and use Compare Original for a quick listen before and after.

Effects are remembered per app. Volume, mute, and output routing stay as they
were. Turn the feature on in Settings.

## Supported headphones

Aural shows controls only when the connected headphones provide them. What you
see can vary by model, firmware, and macOS version.

| Headphones | What Aural can do | Evidence |
| --- | --- | --- |
| Bowers & Wilkins Px7 S3 / Px8 | Battery, Off, cancellation, transparency | Upstream verified |
| Bowers & Wilkins Px7 S2 / Pi5 / Pi6 / Pi7 / Pi8 | Battery, Off, cancellation, transparency | Experimental |
| Sony WH-1000XM3 | Battery, Off, cancellation, transparency, optional wind reduction | Upstream verified |
| Sony WH-1000XM5 / ULT WEAR | Battery, Off, cancellation, transparency | Upstream verified |
| Sony WH-1000XM2 / XM4 / XM6, WH-CH720N, WF-1000XM3 / XM4 / XM5 / XM6, LinkBuds S, WF-SP800N, WI-SP600N, MDR-1000X | Controls only after the matching Sony V1 or V2 service is confirmed | Experimental |
| OPPO Enco Air5s | Battery and noise modes | Upstream verified |
| AirPods / Beats, including AirPods Max | Off plus the listening modes exposed by macOS, including adaptive when available | System-dependent |
| Bose QuietComfort Ultra Headphones (2nd Gen) / QuietComfort Headphones | Battery, Quiet, and Aware | Upstream verified |
| Bose QuietComfort Ultra Earbuds (2nd Gen) | Left, right, and case battery; Quiet and Aware | Upstream verified |
| Bose QuietComfort 45 | Battery, Quiet, and Aware after product initialization | Experimental |
| Sennheiser ACCENTUM Wireless | Battery, Off, cancellation, transparency | Upstream verified |

**Upstream verified** means the exact model was tested by the upstream protocol
project; Aural still needs independent hardware acceptance. **Experimental**
means the model is recognized, but the exact hardware has not been validated in
the current build.

See [Headphone compatibility](docs/HEADPHONE_COMPATIBILITY.md) for the full
evidence matrix, research backlog, and community test-report checklist.

## Install

1. Download the latest build from [GitHub Releases](https://github.com/Colin0v0/Aural/releases).
2. Open the DMG and drag Aural into Applications.
3. Launch Aural and allow Bluetooth or app-audio permissions when prompted.

Aural targets **macOS 15.4 or later on Apple Silicon**.

## Good to know

- Some headphones expose only part of their controls, and firmware updates can
  change compatibility.
- Output switching can produce a short audio gap.
- Multiple Bluetooth headphones may have different latency.
- Sleep, disconnects, or audio errors can require an app to be applied again.
- Protected audio and some app-specific audio setups may not be supported.

## Privacy

Aural processes audio locally. It does not save recordings, upload your audio,
require an account, or collect telemetry.

Diagnostics may include device names, IDs, or Bluetooth addresses. Remove
anything private before sharing diagnostic output.

## Build from source

Requirements: Swift 6 toolchain and macOS 15.4 or later.

```sh
./Scripts/check.sh
open dist/Aural.app
```

The script runs tests, builds the app, verifies the local signature, and creates
`dist/Aural.app`.

See [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for credits and
[docs/CHANGELOG.md](docs/CHANGELOG.md) for release history.

## License

Aural is released under the [MIT License](LICENSE).
