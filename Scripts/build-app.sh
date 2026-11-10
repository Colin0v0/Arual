#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
# 这是显式的本地开发构建：不尝试其他签名身份，也不绕过隔离检查。
swift build
BIN_DIR="$(swift build --show-bin-path)"
APP="dist/Aural.app"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources/Licenses"
cp "$BIN_DIR/Aural" "$APP/Contents/MacOS/Aural"
cp Resources/Info.plist "$APP/Contents/Info.plist"
# SwiftPM 的资源包承载从平面图标抠出的品牌模板，必须随可执行文件一起进入 App。
ditto "$BIN_DIR/Aural_Aural.bundle" "$APP/Contents/Resources/Aural_Aural.bundle"
# 品牌图标必须随应用包一起复制，Finder 与 Dock 才能读取用户指定的 App 图标。
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
# 许可声明是分发必需品；缺失时构建失败，不生成缺声明的应用。
cp LICENSE "$APP/Contents/Resources/Licenses/Aural-LICENSE.txt"
cp ThirdParty/HeadBridge/LICENSE "$APP/Contents/Resources/Licenses/HeadBridge-LICENSE.txt"
cp ThirdParty/PodsControl/LICENSE "$APP/Contents/Resources/Licenses/PodsControl-LICENSE.txt"
cp THIRD_PARTY_NOTICES.md "$APP/Contents/Resources/Licenses/THIRD_PARTY_NOTICES.md"
codesign --force --sign - "$APP"
/usr/libexec/PlistBuddy -c 'Print CFBundleIdentifier' "$APP/Contents/Info.plist"
printf '本地应用已生成：%s/%s\n' "$PWD" "$APP"
