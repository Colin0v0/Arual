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

Aural 把常用音频控制放进菜单栏，不必反复打开系统设置：切换扬声器和麦克风、单独调节每个 App、让声音同时从多个设备播放，并管理兼容的蓝牙耳机。

> **正式版 · 0.3.0**
>
> Aural 目前采用直接分发，尚未经过 Apple 公证；首次打开时 macOS 可能要求确认。

## 你可以用它做什么

- **切换音频设备** — 不用打开系统设置，直接选择输出或输入设备。
- **调节音量和静音** — 只显示设备真正支持的硬件控制。
- **单独调节 App** — 每个正在播放的 App 都可以有自己的音量、静音和实时电平。
- **同时使用多个输出** — 让系统声音同时从多个扬声器或耳机播放。
- **给 App 单独指定输出** — 例如让音乐留在耳机，浏览器声音从扬声器播放。
- **控制兼容耳机** — 查看电量、切换降噪或通透模式，并在一个面板里管理多副耳机。
- **按自己的习惯使用** — 支持中文和英文、跟随系统外观，可选功能也能按需开启。

耳机控制和多设备输出默认关闭，可以在设置中打开。

## 多个输出，每个 App 单独播放

在设置中开启“显示多设备输出”后，可以在输出页选择两个或多个设备。Aural 会把它们作为一个多设备组使用，同时保留每个设备自己的音量和静音控制。

正在播放的 App 可以选择：

- **全部输出** — 跟随当前多设备组，之后加入的设备也会自动包含。
- **自定义输出** — 只从这个 App 选择的设备播放。

修改一个 App 的输出，不会改变其他 App，也不会改变系统整体输出。设备暂时断开时，Aural 会记住原来的选择，并在设备重新连接后恢复。

> 单独指定输出会真正改变该 App 的声音去向，而不只是改变界面状态。切换时仍可能出现很短的音频间隙。

## 耳机支持

具体可用功能会因耳机型号和固件而不同。

| 耳机 | 状态 | Aural 可以做什么 |
| --- | --- | --- |
| Bowers & Wilkins Px7 S3 / Px8 | 上游已验证 | 查看电量，切换三个支持的噪声模式 |
| Bowers & Wilkins Px7 S2 / Pi5 / Pi6 / Pi7 / Pi8 | 实验性 | 查看电量，切换三个支持的噪声模式 |
| Sony WH-1000XM3 | 上游已验证 | 查看电量、切换噪声模式，并在设备支持时显示抗风噪 |
| Sony WH-1000XM5 / ULT WEAR | 上游已验证 | 通过 Sony V2 查看电量，切换关闭、降噪和透传 |
| Sony WH-1000XM2 / XM4 及部分 WF/WI/MDR 型号 | 实验性 | 只有设备确认匹配的 V1 或 V2 服务后才提供控制 |
| OPPO Enco Air5s | 上游已验证 | 为已识别产品 ID 查看电量并切换噪声模式 |
| AirPods / Beats | 取决于系统 | 使用关闭，以及 macOS 公开的降噪、通透和自适应模式 |
| Bose QuietComfort、Fast Pair 电量 | 计划中 | 当前版本尚不可用 |

Aural 会先根据系统输出名称选择型号 profile，再等待耳机真实确认能力。界面显示几个噪声模式，就代表协议实际确认了几档，而不是固定显示三档。

Sony V2 由 RFCOMM SDP 服务决定，不根据宣传型号名称猜协议。Apple 的聆听模式来自 BTAudio HAL，因此 AirPods 可以显示关闭、降噪、通透和自适应，不会套用 Bowers & Wilkins 的三档列表。

完整的验证记录、计划中的协议和社区测试提交要求见
[耳机兼容性说明](docs/HEADPHONE_COMPATIBILITY.md)。“实验性”表示已经登记型号，
但当前版本还没有在对应真机上完成验收。

## 安装

1. 从 [GitHub Releases](https://github.com/Colin0v0/Aural/releases) 下载最新版本。
2. 打开 DMG，把 Aural 拖进“应用程序”文件夹。
3. 启动 Aural；如果需要蓝牙控制或 App 音频功能，再按提示允许相应权限。

目前适用于 **macOS 15.4 或更新版本，以及 Apple Silicon Mac**。

## 隐私

Aural 只在本机处理音频，不保存录音、不上传音频、不需要账号，也不收集遥测数据。

诊断信息可能包含设备名称、编号或蓝牙地址。分享前请先删除不希望公开的信息。

## 使用前请了解

- 不同耳机公开的控制能力不同，固件或 macOS 更新也可能影响兼容性。
- 输出切换不保证完全无缝，有时会出现短暂停顿。
- 同时使用两副蓝牙耳机时，延迟可能不同，也不保证长期完全同步。
- 休眠、设备断开或音频错误后，部分 App 可能需要重新应用。
- 受保护音频和部分 App 的特殊音频方式可能无法处理。
- 为不同 App 指定不同输出，仍在真实扬声器和耳机上持续验证。

## 开发者

需要 Swift 6 工具链和 macOS 15.4 或更新版本。

```sh
./Scripts/check.sh
open dist/Aural.app
```

脚本会运行测试、构建应用、验证本地签名，并生成 `dist/Aural.app`。

源码结构：

- `Sources/Aural` — 菜单栏界面、设置和交互状态
- `Sources/AuralCore` — 音频设备、App 音频处理、电平和耳机控制
- `Tests` — 面板与核心测试
- `ThirdParty` — 第三方来源说明

第三方许可和致谢见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，版本记录见 [docs/CHANGELOG.md](docs/CHANGELOG.md)。

## 许可证

Aural 采用 [MIT 许可证](LICENSE)。
