#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 这是显式的本地开发构建：不尝试其他签名身份，也不绕过隔离检查。
CONFIGURATION="${AURAL_BUILD_CONFIGURATION:-debug}"
case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "不支持的构建配置：$CONFIGURATION" >&2; exit 1 ;;
esac
swift build --configuration "$CONFIGURATION"
BIN_DIR="$(swift build --configuration "$CONFIGURATION" --show-bin-path)"
APP="dist/Aural.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses" "$APP/Contents/Helpers"
cp "$BIN_DIR/Aural" "$APP/Contents/MacOS/Aural"
cp "$BIN_DIR/AuralUpdateHelper" "$APP/Contents/Helpers/AuralUpdateHelper"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# 更新仓库地址从当前 Git remote 注入最终应用包，避免源码或资源文件写死账号名。
REMOTE_URL="$(git remote get-url origin)"
UPDATE_REPOSITORY="$(printf '%s' "$REMOTE_URL" | sed -E 's#^git@github.com:##; s#^https://github.com/##; s#\.git$##')"
case "$UPDATE_REPOSITORY" in
    */*) ;;
    *) echo "无法从 origin 识别 GitHub 仓库：$REMOTE_URL" >&2; exit 1 ;;
esac
/usr/libexec/PlistBuddy -c "Add :AuralUpdateRepository string $UPDATE_REPOSITORY" "$APP/Contents/Info.plist"
# SwiftPM 在部分工具链上会把资源包输出成平面目录，导致 Bundle.module 无法识别。
# 这里不复制工具链产物，而是从源码资源确定性地构造标准 macOS bundle 结构。
RESOURCE_BUNDLE="$APP/Contents/Resources/Aural_Aural.bundle"
rm -rf "$RESOURCE_BUNDLE"
mkdir -p "$RESOURCE_BUNDLE/Contents/Resources"
cp Resources/Aural_Aural.bundle/Contents/Info.plist "$RESOURCE_BUNDLE/Contents/Info.plist"
cp -R Sources/Aural/Resources/. "$RESOURCE_BUNDLE/Contents/Resources/"
# 品牌图标必须随应用包一起复制，Finder 与 Dock 才能读取用户指定的 App 图标。
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 许可声明是分发必需品；缺失时构建失败，不生成缺声明的应用。
cp LICENSE "$APP/Contents/Resources/Licenses/Aural-LICENSE.txt"
cp ThirdParty/HeadBridge/LICENSE "$APP/Contents/Resources/Licenses/HeadBridge-LICENSE.txt"
cp ThirdParty/PodsControl/LICENSE "$APP/Contents/Resources/Licenses/PodsControl-LICENSE.txt"
cp ThirdParty/SonyULTCtl/LICENSE "$APP/Contents/Resources/Licenses/SonyULTCtl-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$APP/Contents/Helpers/AuralUpdateHelper"
codesign --force --sign - "$APP"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
printf '本地应用已生成：%s/%s\n' "$PWD" "$APP"
