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

1. Apple 耳机仅在双耳均确认入耳时显示降噪、通透和自适应控制；单耳、未佩戴或状态未知时仍显示耳机连接。
2. 通过系统蓝牙报告按真实设备地址读取左耳、右耳和充电盒电量，缺失部件保持未知，不补零或串用另一副耳机的数据。
3. 修复发布包内 \`Aural_Aural.bundle\` 被压平导致启动崩溃的问题，改为从源码资源确定性构造标准 bundle。
4. 发布流程会实际挂载 DMG、解压 ZIP，并验证资源结构、签名和启动诊断；异常安装包不会再通过发布门禁。
5. 重新发布 0.1.13 修复版安装包，并让 0.1.14 包含相同的资源包修复。

### 安装与更新

- 适用于 macOS 15.4 或更新版本的 Apple Silicon Mac。
- Release 优化构建，版本 ${VERSION}；提供可拖入 Applications 的 DMG、旧版自动更新需要的 ZIP，以及各自 SHA-256 校验文件。
- 采用 ad-hoc 签名，未经过 Apple 公证，不等同于 Developer ID 签名。
- 合并 release/${VERSION} 后由 GitHub Actions 自动发布。

- 已经安装旧 0.1.13 的用户可能无法启动，需要手动下载本版或重发后的 0.1.13 覆盖安装。
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
