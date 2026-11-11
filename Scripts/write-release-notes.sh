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

1. 主面板改用局部图标、读数和选择圆圈的轻量悬停反馈，移除整行灰框，并对齐首尾可见内容边距。
2. 设置页移除卡片底和整行悬停，统一中性分段控件、分组对齐与简短英文文案；右键仅保留打开、设置和退出。
3. 耳机控制列出所有已连接且支持协议的耳机，不要求作为当前输出；控制降噪不会切换媒体或提示音输出。
4. 新增 release/* PR 合并后自动构建、校验并发布 DMG 与 SHA-256 的工作流。
5. 更新检查改用 GitHub Releases Atom 源，避开匿名 REST API 配额，并支持从 DMG 安装更新。

### 安装与更新

- 适用于 macOS 15.4 或更新版本的 Apple Silicon Mac。
- Release 优化构建，版本 ${VERSION}；提供可拖入 Applications 的 DMG、旧版自动更新需要的 ZIP，以及各自 SHA-256 校验文件。
- 采用 ad-hoc 签名，未经过 Apple 公证，不等同于 Developer ID 签名。
- 合并 release/${VERSION} 后由 GitHub Actions 自动发布。

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
