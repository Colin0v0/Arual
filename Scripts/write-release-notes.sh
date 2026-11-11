#!/bin/bash
set -euo pipefail
# 发布说明单独生成并在 PR 阶段实际运行；变量一律使用花括号，隔离相邻的中文标点。
: "${VERSION:?缺少发布版本}"
: "${TAG:?缺少发布标签}"
: "${REPOSITORY:?缺少发布仓库}"
: "${DMG:?缺少 DMG 路径}"
: "${ZIP:?缺少 ZIP 路径}"
cat <<EOF
## Aural ${VERSION} 开发预览

1. 关闭更新入口只跳过该版本的自动提示；之后手动检查更新仍会重新展示同一版本。
2. 主面板保留紫色更新胶囊；设置页使用轻量的“发现新版本”文字入口，避免胶囊贴近窗口底边。
3. 下载、准备、重启和失败重试继续使用胶囊展示明确状态，更新入口与设置页的信息层级保持一致。
4. Apple 耳机仅在双耳均确认入耳时显示降噪、通透和自适应控制；单耳、未佩戴或状态未知时仍显示耳机连接。
5. App 从自身 \`Contents/Resources/Aural_Aural.bundle\` 加载资源；发布流程继续校验 DMG、ZIP、签名和真实启动诊断。

### 安装与更新

- 适用于 macOS 15.4 或更新版本的 Apple Silicon Mac。
- Release 优化构建，版本 ${VERSION}；提供可拖入 Applications 的 DMG、旧版自动更新需要的 ZIP，以及各自 SHA-256 校验文件。
- 采用 ad-hoc 签名，未经过 Apple 公证，不等同于 Developer ID 签名。
- 合并 release/${VERSION} 后由 GitHub Actions 自动发布。

- 已经安装 0.1.13 或 0.1.14 的用户可以重新下载本版并覆盖安装；0.1.13 早期安装包若无法启动，请直接使用本版 DMG。
- 0.1.11 / 0.1.12 更新器仍需 ZIP 及 GitHub 资产 digest；本次同时发布兼容 ZIP。旧客户端的匿名 API 配额不会被远端发布修复，遇 403 请等待配额恢复或手动安装 DMG。

### 校验

下载后可在终端执行：

\`\`\`sh
gh release download ${TAG} --repo ${REPOSITORY}
shasum -a 256 -c $(basename "${DMG}").sha256
shasum -a 256 -c $(basename "${ZIP}").sha256
\`\`\`

### 请先了解

- 本版为开发预览，安装包未完成 Apple 公证。
- 如遇更新安装问题，请保留发布页、校验结果和系统版本信息以便定位。
EOF
