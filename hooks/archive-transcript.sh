#!/usr/bin/env bash
# SessionEnd hook：把這次對話轉成可離線調閱的 HTML。
#
#   1. 一律更新全域封存      ~/.claude/transcripts/
#   2. 專案若已「加入」，同時更新專案內的可分享版本
#      加入方式：在專案跑一次 /transcripts（會建立 docs/transcripts/，
#      那個資料夾的存在就是開關）
#
# 失敗絕不影響關閉流程（一律 exit 0）。
set -uo pipefail

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

tp=$(j '.transcript_path // ""')
cwd=$(j '.cwd // ""')
SCRIPT="${CLAUDE_PLUGIN_ROOT}/scripts/transcript2html.py"

[ -n "$tp" ] && [ -f "$tp" ] && [ -f "$SCRIPT" ] || exit 0
command -v python3 >/dev/null || exit 0

python3 "$SCRIPT" "$tp" >/dev/null 2>&1 || true

if [ -n "$cwd" ] && [ -d "$cwd/docs/transcripts" ]; then
  python3 "$SCRIPT" --here "$cwd" >/dev/null 2>&1 || true
fi

exit 0
