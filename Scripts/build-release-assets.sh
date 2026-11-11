#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# DMG 是主要安装包；ZIP 是旧版更新器的明确协议格式，不是新客户端的下载降级路径。
./Scripts/build-dmg.sh
APP="dist/Aural.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
DMG="dist/Aural-${VERSION}-macOS-${ARCH}.dmg"
ZIP="dist/Aural-${VERSION}-macOS-${ARCH}.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"

# 更新包必须同时验证标准 bundle 结构、外层签名和真实启动，避免再次发布启动即崩溃的安装包。
CHECK="$(mktemp -d "${TMPDIR:-/tmp}/aural-legacy-zip.XXXXXX")"
DMG_MOUNT=""
DMG_ATTACHED=0
cleanup() {
    if [[ "$DMG_ATTACHED" == "1" ]]; then
        hdiutil detach "$DMG_MOUNT" -quiet || true
    fi
    rm -rf "$CHECK"
}
trap cleanup EXIT

verify_app() {
    local candidate="$1"
    local resource_bundle="$candidate/Contents/Resources/Aural_Aural.bundle"
    test -f "$candidate/Contents/Info.plist"
    test -x "$candidate/Contents/MacOS/Aural"
    test -f "$resource_bundle/Contents/Info.plist"
    test -f "$resource_bundle/Contents/Resources/AuralMarkTemplate.png"
    test "$(plutil -extract CFBundlePackageType raw -o - \
        "$resource_bundle/Contents/Info.plist")" == "BNDL"
    test "$(plutil -extract CFBundleIdentifier raw -o - \
        "$resource_bundle/Contents/Info.plist")" == "aural.Aural.resources"
    cmp Sources/Aural/Resources/AuralMarkTemplate.png \
        "$resource_bundle/Contents/Resources/AuralMarkTemplate.png"
    codesign --verify --deep --strict "$candidate"
    "$candidate/Contents/MacOS/Aural" --diagnose-resources >/dev/null
}

verify_app "$APP"

# 用旧更新器相同的 ditto 解压方式验证根目录布局、资源结构和签名。
/usr/bin/ditto -x -k "$ZIP" "$CHECK"
test -d "$CHECK/Aural.app"
cmp "$APP/Contents/Info.plist" "$CHECK/Aural.app/Contents/Info.plist"
cmp "$APP/Contents/MacOS/Aural" "$CHECK/Aural.app/Contents/MacOS/Aural"
verify_app "$CHECK/Aural.app"
shasum -a 256 -c "$ZIP.sha256"

# DMG 也必须从真实挂载内容验证，不能只相信构建目录中的 app。
DMG_MOUNT="$CHECK/dmg"
mkdir -p "$DMG_MOUNT"
hdiutil attach "$DMG" -nobrowse -noautoopen -readonly -mountpoint "$DMG_MOUNT" -quiet
DMG_ATTACHED=1
DMG_APPS="$(find "$DMG_MOUNT" -maxdepth 1 -type d -name '*.app' -print)"
DMG_APP_COUNT="$(printf '%s\n' "$DMG_APPS" | sed '/^$/d' | wc -l | tr -d ' ')"
test "$DMG_APP_COUNT" == "1"
DMG_APP="$(printf '%s\n' "$DMG_APPS" | sed -n '1p')"
verify_app "$DMG_APP"
hdiutil detach "$DMG_MOUNT" -quiet
DMG_ATTACHED=0

shasum -a 256 -c "$DMG.sha256"
printf '发布资产已生成：DMG + 旧版更新 ZIP + 各自 SHA-256（%s）。\n' "$VERSION"
