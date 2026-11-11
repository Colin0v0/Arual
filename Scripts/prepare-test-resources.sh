#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Xcode 16.4 的 SwiftPM 会把资源包放在 AuralPackageTests.xctest 旁边，
# 而当前 CLT 会把它放进 .xctest/Contents/Resources。
# 测试前统一按标准 macOS bundle 布局写入测试宿主，让生产代码只保留一个资源入口。
BIN_DIR="$(swift build --show-bin-path)"
FOUND_TEST_BUNDLE=false
while IFS= read -r -d '' TEST_BUNDLE; do
    FOUND_TEST_BUNDLE=true
    RESOURCE_ROOT="$TEST_BUNDLE/Contents/Resources"
    RESOURCE_BUNDLE="$RESOURCE_ROOT/Aural_Aural.bundle"
    rm -rf "$RESOURCE_BUNDLE"
    mkdir -p "$RESOURCE_BUNDLE/Contents/Resources"
    cp Resources/Aural_Aural.bundle/Contents/Info.plist "$RESOURCE_BUNDLE/Contents/Info.plist"
    cp -R Sources/Aural/Resources/. "$RESOURCE_BUNDLE/Contents/Resources/"
    # 修改测试宿主内容后重新做临时签名，避免签名封条与新增资源不一致。
    codesign --force --sign - "$TEST_BUNDLE"
done < <(find "$BIN_DIR" -maxdepth 1 -type d -name '*.xctest' -print0)

if [[ "$FOUND_TEST_BUNDLE" != true ]]; then
    echo "未找到 SwiftPM 测试宿主：$BIN_DIR" >&2
    exit 1
fi

printf '测试资源包已写入：%s\n' "$BIN_DIR"
