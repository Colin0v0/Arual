#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."
NOTES="$(mktemp)"
trap 'rm -f "$NOTES"' EXIT
# 明确使用 UTF-8 复现 Bash 将紧邻中文标点读入变量名的环境，不仅检查 shell 语法。
export LC_ALL=en_US.UTF-8
for version in 0.2.1 0.12.345; do
    VERSION="$version" TAG="v$version" REPOSITORY="test/aural" \
        DMG="dist/Aural-${version}-macOS-arm64.dmg" \
        ZIP="dist/Aural-${version}-macOS-arm64.zip" \
        ./Scripts/write-release-notes.sh > "$NOTES"
    grep -Fq "## Aural $version 开发预览" "$NOTES"
    grep -Fq "版本 ${version}；" "$NOTES"
    grep -Fq "应用级多设备路由" "$NOTES"
    grep -Fq "原生说明框" "$NOTES"
    grep -Fq "全新的 ${version} 发布资产" "$NOTES"
    grep -Fq "gh release download v$version --repo test/aural" "$NOTES"
    grep -Fq "shasum -a 256 -c Aural-${version}-macOS-arm64.dmg.sha256" "$NOTES"
    grep -Fq "shasum -a 256 -c Aural-${version}-macOS-arm64.zip.sha256" "$NOTES"
done
printf '发布说明生成检查通过：UTF-8 中文标点、动态版本和两种资产的校验命令。\n'
