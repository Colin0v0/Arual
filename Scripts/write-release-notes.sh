#!/bin/bash
set -euo pipefail

: "${VERSION:?缺少发布版本}"

# GitHub Release 只展示该版本的用户可见变化，文案按版本独立维护。
# 测试可通过 RELEASE_NOTES_DIR 指向临时目录，正式发布固定读取 docs/releases。
RELEASE_NOTES_DIR="${RELEASE_NOTES_DIR:-docs/releases}"
NOTES_FILE="${RELEASE_NOTES_DIR}/${VERSION}.md"

if [[ ! -f "$NOTES_FILE" ]]; then
    printf '缺少 %s 的发布文案：%s\n' "$VERSION" "$NOTES_FILE" >&2
    exit 1
fi
if [[ ! -s "$NOTES_FILE" ]]; then
    printf '%s 的发布文案为空：%s\n' "$VERSION" "$NOTES_FILE" >&2
    exit 1
fi
if ! grep -Eq '^-[[:space:]]+[^[:space:]]' "$NOTES_FILE"; then
    printf '%s 的发布文案必须至少包含一条更新列表\n' "$VERSION" >&2
    exit 1
fi

# Release 必须同时提供中文与 English 两段，并且每段都有实际更新条目。
if ! awk '
    /^\*\*中文\*\*$/ { zh = 1; next }
    /^\*\*English\*\*$/ { en = 1; next }
    /^- / {
        if (zh == 1 && en == 0) zh_items = 1
        if (en == 1) en_items = 1
    }
    END { exit !(zh && en && zh_items && en_items) }
' "$NOTES_FILE"; then
    printf '%s 的发布文案必须包含“**中文**”和“**English**”两段更新列表\n' "$VERSION" >&2
    exit 1
fi

# Release 标题已经包含版本号；正文不再重复标题和其他章节，
# 避免 GitHub 生成重复目录，也避免把历史功能再次写进当前版本。
if grep -Eq '^#{1,6}[[:space:]]' "$NOTES_FILE"; then
    printf '%s 的发布文案只能包含本次更新列表，不要添加标题：%s\n' \
        "$VERSION" "$NOTES_FILE" >&2
    exit 1
fi

cat "$NOTES_FILE"
