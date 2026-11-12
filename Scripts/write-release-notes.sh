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

1. 新增应用级多设备路由：启用多设备输出后，每个 App 都能选择组内一个、多个或全部设备，原有独立音量和静音控制继续保留。
2. “全部输出”会自动包含新加入的设备；自定义选择按 App 保存，退出多设备模式时暂停，重新进入后恢复。
3. 路由菜单只保留全部输出和设备勾选，最后一台设备不能取消；多设备输出名称统一，应用行保持单行紧凑布局。
4. 系统音频录制未授权时先使用 macOS 原生授权框；拒绝后展示 Aural 原生说明框，可直接打开系统设置或退出，不进入不可用界面。运行期间权限失效时同样处理。
5. README 默认使用英文，提供简体中文版；保留标语 Your Mac. Your Sound. Your Rules.

### 安装与更新

- 适用于 macOS 15.4 或更新版本的 Apple Silicon Mac。
- Release 优化构建，版本 ${VERSION}；提供可拖入 Applications 的 DMG、旧版自动更新需要的 ZIP，以及各自 SHA-256 校验文件。
- 采用 ad-hoc 签名，未经过 Apple 公证，不等同于 Developer ID 签名。
- 合并 release/${VERSION} 后由 GitHub Actions 自动发布。

- 已安装旧版的用户可以通过应用内更新或下载 DMG 覆盖安装。重新签名后 macOS 可能要求重新允许系统音频录制。
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
- 应用路由仍在真实设备上持续验证；切换可能短暂断音，多副蓝牙耳机不保证同步，受保护音频可能无法处理。
- 权限状态检测使用 macOS 非公开接口；系统升级可能影响检测，无法检查时会明确提示，不假定已授权。
- 如遇更新安装问题，请保留发布页、校验结果和系统版本信息以便定位。
EOF
