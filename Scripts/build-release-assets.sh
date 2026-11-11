#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# DMG 是主要安装包；ZIP 是旧版更新器的明确协议格式，不是新客户端的下载降级路径。
./Scripts/build-dmg.sh
APP="dist/Aural.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
ARCH="$(uname -m)"
ZIP="dist/Aural-${VERSION}-macOS-${ARCH}.zip"
rm -f "$ZIP"
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
shasum -a 256 "$ZIP" > "$ZIP.sha256"

# 用旧更新器相同的 ditto 解压方式验证根目录布局、可执行文件和签名，防止上传不能升级的 ZIP。
CHECK="$(mktemp -d "${TMPDIR:-/tmp}/aural-legacy-zip.XXXXXX")"
trap 'rm -rf "$CHECK"' EXIT
/usr/bin/ditto -x -k "$ZIP" "$CHECK"
test -d "$CHECK/Aural.app"
cmp "$APP/Contents/Info.plist" "$CHECK/Aural.app/Contents/Info.plist"
cmp "$APP/Contents/MacOS/Aural" "$CHECK/Aural.app/Contents/MacOS/Aural"
codesign --verify --deep --strict "$CHECK/Aural.app"
shasum -a 256 -c "$ZIP.sha256"
printf '发布资产已生成：DMG + 旧版更新 ZIP + 各自 SHA-256（%s）。\n' "$VERSION"
