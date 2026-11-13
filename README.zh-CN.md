<p align="center">
  <img src="Resources/AppIcon-1024.png" width="128" height="128" alt="Aural 应用图标" />
</p>

<h1 align="center">Aural</h1>

<p align="center"><strong>Your Mac. Your Sound. Your Rules.</strong></p>

<p align="center">
  <a href="README.md">English</a> · <strong>简体中文</strong>
</p>

<p align="center">
  <img src="https://img.shields.io/badge/macOS-15.4%2B-000000?logo=apple&logoColor=white" alt="macOS 15.4 或更新版本" />
  <a href="LICENSE"><img src="https://img.shields.io/badge/License-MIT-blue" alt="MIT License" /></a>
</p>

<p align="center">
  <a href="https://github.com/Colin0v0/Aural/releases"><strong>下载最新版本</strong></a>
  ·
  <a href="docs/HEADPHONE_COMPATIBILITY.md">耳机兼容性</a>
</p>

Aural 把 Mac 的声音控制收进菜单栏：切换设备、给每个 App 单独调音量、让声音同时从多个输出播放，也能查看耳机电量、切换降噪。想调整某个 App 的声音，打开它的「音效」窗口就好。

> **当前版本：0.3.0**
>
> Aural 目前直接分发，尚未经过 Apple 公证；首次打开时 macOS 可能要求确认。

## 你可以用它做什么

- **快速切换音频** — 从菜单栏直接选择输出或麦克风。
- **单独调节 App** — 为每个正在播放的 App 设置独立音量、静音状态和实时电平。
- **使用多设备输出** — 让系统声音同时从多个扬声器或耳机播放。
- **为 App 指定输出** — 让音乐留在耳机，把浏览器声音放到扬声器。
- **调整 App 音效** — 在独立窗口使用 10 段 EQ 推子、频响预览、自定义预设和原声对比，不改变原音量与输出路由。
- **控制兼容耳机** — 查看电量、切换噪声模式，并在一个面板里管理多副耳机。
- **按自己的方式使用** — 支持中文和英文、跟随系统外观，并按需开启功能。

应用音效、耳机控制与多设备输出默认关闭，可以在设置中按需开启。

## 多设备输出与应用路由

开启 **显示多设备输出** 后，选择两个或更多输出设备，Aural 会把它们作为一个多设备输出组使用。每台设备仍保留自己的音量和静音控制。

每个正在播放的 App 可以选择：

- **全部输出** — 跟随当前多设备输出组，之后加入的设备也会自动包含。
- **自定义输出** — 只从这个 App 选择的设备播放。

修改一个 App 的路由不会影响其他 App 或系统整体输出。Aural 会保存自定义路由，并在设备重新连接后恢复；设备加入或离开多设备组时，路由会自动按当前设备集合重新计算。

## 应用音效

从 App 行打开「音效」窗口：先选一个内置预设，保存当前配置，或用十段推子调整声音。选中自定义预设后，顶部会出现重命名和删除；「对比原声」用于快速听调整前后的差别。

音效按 App 记住，不改变原来的音量、静音和输出路由。功能可在设置中开启。

## 当前支持的耳机

连接耳机后，Aural 只显示耳机实际提供的控制项。可用功能会因型号、固件和 macOS 版本而不同。

| 耳机型号 | 可查看 / 控制 | 状态 |
| --- | --- | --- |
| Bowers & Wilkins Px7 S3 / Px8 | 电量，关闭、降噪、通透 | 上游已验证 |
| Bowers & Wilkins Px7 S2 / Pi5 / Pi6 / Pi7 / Pi8 | 电量，关闭、降噪、通透 | 实验性 |
| Sony WH-1000XM3 | 电量，关闭、降噪、通透，设备支持时可显示抗风噪 | 上游已验证 |
| Sony WH-1000XM5 / ULT WEAR | 电量，关闭、降噪、通透 | 上游已验证 |
| Sony WH-1000XM2 / XM4 / XM6、WH-CH720N、WF-1000XM3 / XM4 / XM5 / XM6、LinkBuds S、WF-SP800N、WI-SP600N、MDR-1000X | 确认匹配 Sony V1 或 V2 服务后显示控制 | 实验性 |
| OPPO Enco Air5s | 电量，关闭、降噪、通透 | 上游已验证 |
| AirPods / Beats（包括 AirPods Max） | 关闭，以及 macOS 公开的降噪、通透和自适应模式 | 取决于系统 |
| Bose QuietComfort Ultra Headphones (2nd Gen) / QuietComfort Headphones | 电量，Quiet、Aware | 上游已验证 |
| Bose QuietComfort Ultra Earbuds (2nd Gen) | 左耳、右耳和充电盒电量，Quiet、Aware | 上游已验证 |
| Bose QuietComfort 45 | 完成产品初始化后查看电量，切换 Quiet、Aware | 实验性 |
| Sennheiser ACCENTUM Wireless | 电量，关闭、降噪、通透 | 上游已验证 |

**上游已验证** 表示对应协议已在上游项目中用同型号设备测试过，Aural 仍需要独立硬件验收。**实验性** 表示型号已被识别，但当前版本尚未在对应真机上完成验证。

完整的协议依据、待研究型号和社区测试要求见 [耳机兼容性说明](docs/HEADPHONE_COMPATIBILITY.md)。

## 安装

1. 从 [GitHub Releases](https://github.com/Colin0v0/Aural/releases) 下载最新版本。
2. 打开 DMG，将 Aural 拖入“应用程序”文件夹。
3. 启动 Aural，按提示允许蓝牙或 App 音频权限。

Aural 需要 **macOS 15.4 或更新版本**，目前面向 **Apple Silicon Mac**。

## 使用前请了解

- 不同耳机公开的控制能力不同，固件更新也可能改变兼容性。
- 切换输出时可能出现很短的音频间隙。
- 同时使用多副蓝牙耳机时，延迟可能不同。
- 休眠、断开连接或音频错误后，部分 App 可能需要重新应用路由。
- 受保护音频和部分 App 的特殊音频方式可能无法处理。

## 隐私

Aural 只在本机处理音频，不保存录音、不上传音频、不需要账号，也不收集遥测数据。

诊断信息可能包含设备名称、编号或蓝牙地址；分享前请删除不希望公开的信息。

## 从源码构建

需要 Swift 6 工具链和 macOS 15.4 或更新版本。

```sh
./Scripts/check.sh
open dist/Aural.app
```

脚本会运行测试、构建应用、验证本地签名，并生成 `dist/Aural.app`。

第三方许可和致谢见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，版本记录见 [docs/CHANGELOG.md](docs/CHANGELOG.md)。

## 许可证

Aural 采用 [MIT License](LICENSE)。
