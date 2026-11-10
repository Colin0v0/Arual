# 第三方代码与协议来源

## HeadBridge — MIT

- 仓库：https://github.com/herenickname/HeadBridge
- 固定来源提交：`5e577cb4a91a515b95596fcc4b362a86ecb639a5`
- Copyright (c) 2026 HeadBridge contributors
- 许可全文：[ThirdParty/HeadBridge/LICENSE](ThirdParty/HeadBridge/LICENSE)，随本地 .app 一起分发。

派生文件：

| Aural 文件 | 上游文件 | 修改 |
|---|---|---|
| Sources/AuralCore/MessagePack.swift | Sources/HeadBridge/Protocol/MessagePack.swift | 保留编解码；浮点转整型改为精确转换，拒绝非有限值/非整数，不截断、不崩溃；补充中文说明 |
| Sources/AuralCore/BWRPC.swift | Sources/HeadBridge/Protocol/BWRPC.swift | 收窄命令表；明确 5/6 字节短响应与长帧格式；拒绝未知尾随数据、过大请求；错误中文化 |

独立实现的 Core Audio 和 BLE 生命周期代码不来自 FineTune。B&W 特征 UUID、命令编号和 ANC 线值依据 HeadBridge 的 `docs/BowersWilkinsRPC.md`。上游验证的 Px7 S3 固件为 `3.17.4.17`，不代表 Aural 已经过实机验证。

没有复制上游图标、界面素材、签名身份或其他项目源代码。Aural 自有代码采用根目录 LICENSE 中的 MIT 许可证；第三方代码保留原有版权和许可声明。

## pods-control — MIT

- 仓库：https://github.com/raulgg/pods-control
- Copyright (c) 2026 Raul
- 许可全文：[ThirdParty/PodsControl/LICENSE](ThirdParty/PodsControl/LICENSE)，随本地 `.app` 一起分发。
- Aural 仅依据其公开实现确认 BTAudio HAL 的 `lstm`/`lsms` 选择器及 `off=1`、`noise-cancellation=2`、`transparency=3`、`adaptive=4` 线值；Aural 的控制器、无 fallback 错误处理、异步写入与有界回读均为独立实现。

## FineTune：实现研究（不包含源代码）

本次阅读其音频进程监控与宿主归属思路，确认“音频进程不等于用户应用”、需要合并辅助进程并排除内部音频服务。Aural 没有复制其 GPL 源文件、私有 responsibility 查询或后备识别分支；自行使用公开 libproc 的进程信息、父 PID 与执行路径构造归属证据。

## 0.1.7 新增的 HeadBridge 驱动复用

固定来源仍为 `5e577cb4a91a515b95596fcc4b362a86ecb639a5`，适用同一 MIT 许可。

| Aural 文件 | 上游文件 | 修改 |
|---|---|---|
| Sources/AuralCore/HeadphoneModels.swift | Core/HeadphoneProvider.swift、Providers/BowersWilkins/BowersWilkinsProvider.swift | 复用厂商家族预筛选、LE_BWHP 通用广播规则与原代 Px8 ANC 线值；不复制 RSSI 后备选择 |
| Sources/AuralCore/HeadBridge/Sony/SonyMDRProtocol.swift | Providers/Sony/SonyMDRProtocol.swift | 保留帧、解析器、型号线值与能力表 |
| Sources/AuralCore/HeadBridge/Sony/SonyRFCOMMTransport.swift | Providers/Sony/SonyRFCOMMTransport.swift | 加入真实系统输出 UID 检查与可恢复传输错误分类，不在 V1 失败后尝试 V2 |
| Sources/AuralCore/HeadBridge/Sony/SonyV1Client.swift | Providers/Sony/SonyV1Client.swift | 保留 ACK/命令队列/响应解码；删除超时即认定初始化或就绪的分支及静默跳过超时命令；只请求基础状态；增加发送/验证事件与输出绑定 |
| Sources/AuralCore/HeadBridge/OPPO/OppoProtocol.swift | Providers/OPPO/OppoProtocol.swift | 保留基础帧、解析器、产品 ID/电量/噪声映射；类型接入 Aural，移除未使用的高级状态/响铃功能 |
| Sources/AuralCore/HeadBridge/OPPO/OppoRFCOMMTransport.swift | Providers/OPPO/OppoRFCOMMTransport.swift | 加入真实输出绑定与可恢复传输错误分类 |
| Sources/AuralCore/HeadBridge/TransportSupport.swift | Providers/BowersWilkins/BowersWilkinsProvider.swift 的 TransportLogEntry.Direction | 仅保留日志方向接口，其余为 Aural 的输出检查 |
| Tests/AuralCoreTests/HeadBridgeProtocolTests.swift | Tests/HeadBridgeTests/RPCCodecTests.swift、OppoProtocolTests.swift | 基础构帧/版本/噪声测试向量改用 Swift Testing，不将上游硬件结果当成本地实测 |

`HeadphoneController` 是 Aural 的状态整合层；`BowersWilkinsController` 继续采用 Aural 的串行 RPC/严格硬件地址核对，不是上游完整 B&W provider 的原样复制。没有复制上游完整 UI、高级设置、配置恢复、更新器、签名材料或安装脚本。

## Magpie：macOS 窗口动画实现研究（不包含上游源文件）

- 仓库：https://github.com/yetone/magpie ，MIT，Copyright (c) 2026 yetone。
- 对照提交：`3cabaab54fa2d6c77bbc491942d2ada9e2535577`（本机 0.1.3359 的构建提交）。
- 阅读 `internal/gui/glide_darwin.go`、页签切换与测量逻辑，确认 macOS 使用单次目标提交的 AppKit 原生窗口动画、固定顶边；不是其他平台的自写逐帧路径。
- Aural 自行用 Swift 调用公开 AppKit API，不包含上游 Go/Wails/WebView 源文件、私有 WebKit 路径、图标或商标。
