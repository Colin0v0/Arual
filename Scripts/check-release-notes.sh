#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

TEMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TEMP_DIR"' EXIT
mkdir -p "$TEMP_DIR/releases"
export LC_ALL=en_US.UTF-8

# 用两个不同版本验证文案确实按版本读取，而不是继续复用固定正文。
printf '%s\n' \
    '**中文**' \
    '' \
    '- **新增** 0.2.4 专属更新。' \
    '- **修复** 0.2.4 专属问题。' \
    '' \
    '**English**' \
    '' \
    '- **Added** Version-specific 0.2.4 update.' \
    '- **Fixed** Version-specific 0.2.4 issue.' \
    > "$TEMP_DIR/releases/0.2.4.md"
printf '%s\n' \
    '**中文**' \
    '' \
    '- **新增** 0.12.345 专属更新。' \
    '- **修复** 0.12.345 专属问题。' \
    '' \
    '**English**' \
    '' \
    '- **Added** Version-specific 0.12.345 update.' \
    '- **Fixed** Version-specific 0.12.345 issue.' \
    > "$TEMP_DIR/releases/0.12.345.md"

for version in 0.2.4 0.12.345; do
    NOTES="$TEMP_DIR/${version}.txt"
    VERSION="$version" RELEASE_NOTES_DIR="$TEMP_DIR/releases" \
        ./Scripts/write-release-notes.sh > "$NOTES"
    grep -Fxq '**中文**' "$NOTES"
    grep -Fxq '**English**' "$NOTES"
    grep -Fq "**新增** ${version} 专属更新。" "$NOTES"
    grep -Fq "**修复** ${version} 专属问题。" "$NOTES"
    grep -Fq "**Added** Version-specific ${version} update." "$NOTES"
    grep -Fq "**Fixed** Version-specific ${version} issue." "$NOTES"
    if grep -Eq '^#{1,6}[[:space:]]' "$NOTES"; then
        printf '发布文案不应包含重复标题：%s\n' "$version" >&2
        exit 1
    fi
done

# 旧模板把历史功能反复写进新版本；新的发布文案必须彻底移除这些段落。
if grep -Eq '提供系统输出、麦克风|安装与更新|0\.1\.11 / 0\.1\.12|版本提升到' \
    "$TEMP_DIR/0.2.4.txt" "$TEMP_DIR/0.12.345.txt"; then
    printf '发布文案仍包含旧的重复模板内容\n' >&2
    exit 1
fi

# 缺少当前版本文案必须直接失败，不能悄悄生成通用内容或回退到历史段落。
if VERSION="9.9.9" RELEASE_NOTES_DIR="$TEMP_DIR/releases" \
    ./Scripts/write-release-notes.sh >/dev/null 2>&1; then
    printf '缺少版本文案时不应成功生成 Release\n' >&2
    exit 1
fi

# 当前源码版本必须已经有对应的正式文案，不能等合并 release 分支后才发现遗漏。
SOURCE_VERSION="$(sed -n 's/.*public static let current = "\([^"]*\)".*/\1/p' \
    Sources/AuralCore/AuralVersion.swift)"
test -n "$SOURCE_VERSION"
VERSION="$SOURCE_VERSION" ./Scripts/write-release-notes.sh >/dev/null

printf '发布文案检查通过：%s 及后续版本只输出各自的新增与修复。\n' "$SOURCE_VERSION"
