#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# 本地预览包默认使用 release 构建；仍可用 AURAL_BUILD_CONFIGURATION 显式指定 debug。
CONFIGURATION="${AURAL_BUILD_CONFIGURATION:-release}"
# PREVIEW_BUILD=1 只改最终包的显示版本，不改源码版本，避免本地预览冒充正式发布。
PREVIEW_BUILD="${AURAL_PREVIEW_BUILD:-0}"
ARCH="$(uname -m)"
case "$ARCH" in
    arm64|x86_64) ;;
    *) echo "不支持的处理器架构：$ARCH" >&2; exit 1 ;;
esac

AURAL_BUILD_CONFIGURATION="$CONFIGURATION" ./Scripts/build-app.sh

APP="dist/Aural.app"
VERSION="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$APP/Contents/Info.plist")"
BUILD_NUMBER="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleVersion' "$APP/Contents/Info.plist")"
if [[ "$PREVIEW_BUILD" == "1" ]]; then
    # 预览版使用“版本-preview”，保证仍能与同一源码版本的正式包区分；
    # Bundle Version 只接受数字段，额外追加时间戳，不把文字写进构建号。
    BUILD_SUFFIX="$(date '+%Y%m%d%H%M')"
    VERSION="${VERSION}-preview"
    BUILD_NUMBER="${BUILD_NUMBER}.${BUILD_SUFFIX}"
    /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$APP/Contents/Info.plist"
    /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$APP/Contents/Info.plist"
    # 改过 Info.plist 后必须重签，否则外层签名不再覆盖最终信息。
    codesign --force --sign - "$APP/Contents/Helpers/AuralUpdateHelper"
    codesign --force --sign - "$APP"
fi

OUTPUT="dist/Aural-${VERSION}-macOS-${ARCH}.dmg"
STAGING="$(mktemp -d "${TMPDIR:-/tmp}/aural-dmg.XXXXXX")"
MOUNT_DIR=""

cleanup() {
    if [[ -n "$MOUNT_DIR" ]] && mount | grep -q "on ${MOUNT_DIR} "; then
        hdiutil detach "$MOUNT_DIR" -quiet || true
    fi
    rm -rf "$STAGING"
}
trap cleanup EXIT

# DMG 只放应用和 Applications 链接；用户打开后可直接把 Aural 拖进 Applications。
mkdir -p "$STAGING/Aural"
ditto "$APP" "$STAGING/Aural/Aural.app"
ln -s /Applications "$STAGING/Aural/Applications"

RW_DMG="$STAGING/Aural-rw.dmg"
# 挂载卷名故意带版本，避免系统中已有同名旧卷时 Finder 自动追加 " 1"，
# 导致后续 AppleScript 找不到目标窗口、图标布局静默失效。
VOLUME_NAME="Aural ${VERSION}"
hdiutil create -quiet -srcfolder "$STAGING/Aural" -volname "$VOLUME_NAME" \
    -fs HFS+ -format UDRW -ov "$RW_DMG"

# 必须挂到 /Volumes 下让 Finder 正常登记卷；挂到临时目录时 Finder 不把它当作 disk。
MOUNT_OUTPUT="$(hdiutil attach "$RW_DMG" -nobrowse -noautoopen)"
MOUNT_DIR="$(printf '%s\n' "$MOUNT_OUTPUT" | awk -F '\t' '/Apple_HFS/ {print $NF; exit}')"
if [[ -z "$MOUNT_DIR" || ! -d "$MOUNT_DIR" ]]; then
    echo "无法取得 DMG 挂载点：$MOUNT_OUTPUT" >&2
    exit 1
fi

# 固定 Finder 图标位置和窗口大小；即使 AppleScript 无界面权限，也不阻断安装包生成。
# open 后 Finder 异步登记新卷，脚本显式等待 disk 出现，消除固定 sleep 的竞态。
open "$MOUNT_DIR"
if ! osascript - "$VOLUME_NAME" <<'APPLESCRIPT'
on run argv
    set volumeName to item 1 of argv
    tell application "Finder"
        repeat 20 times
            if exists disk volumeName then exit repeat
            delay 0.5
        end repeat
        tell disk volumeName
            open
            set current view of container window to icon view
            set toolbar visible of container window to false
            set statusbar visible of container window to false
            set the bounds of container window to {160, 120, 760, 520}
            set viewOptions to the icon view options of container window
            set arrangement of viewOptions to not arranged
            set icon size of viewOptions to 112
            set position of item "Aural.app" of container window to {150, 190}
            set position of item "Applications" of container window to {450, 190}
            update without registering applications
            delay 1
            close
        end tell
    end tell
end run
APPLESCRIPT
then
    echo "Finder 布局设置未执行，保留可用 DMG。" >&2
fi

sync
hdiutil detach "$MOUNT_DIR" -quiet
MOUNT_DIR=""
hdiutil convert "$RW_DMG" -format UDZO -imagekey zlib-level=9 -o "$OUTPUT" -ov -quiet
hdiutil verify "$OUTPUT" >/dev/null
# 校验文件只写下载后的文件名；写成 dist/... 会让发布页命令在用户目录中找不到目标。
(
    cd dist
    shasum -a 256 "$(basename "$OUTPUT")" > "$(basename "$OUTPUT").sha256"
)

trap - EXIT
cleanup
printf 'DMG 已生成：%s/%s\n' "$PWD" "$OUTPUT"
