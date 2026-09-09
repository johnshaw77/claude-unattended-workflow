#!/usr/bin/env bash
# Stop hook：web 專案的「完成定義」把關
#   1. 這個 session 有改過檔案 → 測試必須全綠（含 typecheck，如果有的話）
#   2. 改到畫面相關檔案 → 必須用過 Chrome MCP 實際開瀏覽器驗證
# 通過就 exit 0 放行；沒通過就回 {"decision":"block"} 讓 Claude 繼續做。
#
# 逃生開關：專案根目錄放 .claude/.no-verify，或設 CLAUDE_SKIP_VERIFY=1
set -uo pipefail

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# 防無限迴圈：這次停止本來就是上一輪 hook 擋下來的，就放行
[ "$(j '.stop_hook_active // false')" = "true" ] && exit 0

cwd=$(j '.cwd // ""')
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0

block() { jq -n --arg r "$1" '{decision:"block", reason:$r}'; exit 0; }

# 逃生開關
[ -f .claude/.no-verify ] && exit 0
[ "${CLAUDE_SKIP_VERIFY:-}" = "1" ] && exit 0

# 不是 Node 專案就不管
[ -f package.json ] || exit 0

# 掃這次 session 的 transcript：有沒有改過檔案、有沒有動到 UI、有沒有開過瀏覽器
tp=$(j '.transcript_path // ""')
edited=0; ui_touched=0; browser_used=0
if [ -f "$tp" ]; then
  grep -q '"name":"\(Edit\|Write\|NotebookEdit\)"' "$tp" && edited=1
  grep -qE '"file_path":"[^"]+\.(tsx|jsx|vue|svelte|css|scss|less|html|astro)"' "$tp" && ui_touched=1
  grep -q 'mcp__claude-in-chrome__\|chrome-devtools__' "$tp" && browser_used=1
fi

# 這個 session 根本沒改過檔案（純問答 / 純查詢）→ 放行
[ "$edited" = "1" ] || exit 0

# --- 檢查 1：測試與型別 ---
run_capped() {  # run_capped <秒數> <輸出檔> <npm script 名稱>
  local secs=$1 out=$2 script=$3
  CI=true npm run "$script" --silent >"$out" 2>&1 </dev/null &
  local pid=$!
  # 看門狗必須切斷 stdout/stderr：否則它會持有 hook 的輸出管道，
  # 讓讀取端一直等不到 EOF（即使主指令早就結束）。
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
  local watcher=$!
  wait "$pid"; local rc=$?
  kill -9 "$watcher" 2>/dev/null
  wait "$watcher" 2>/dev/null          # 回收，避免殘留程序
  pkill -9 -P "$pid" 2>/dev/null       # 清掉逾時殺不到的子程序
  return $rc
}

for script in test typecheck; do
  jq -e --arg s "$script" '.scripts[$s] // empty' package.json >/dev/null 2>&1 || continue
  tmp=$(mktemp)
  if ! run_capped 300 "$tmp" "$script"; then
    # 濾掉 ANSI 色碼，訊息才讀得懂
    tail_out=$(tail -40 "$tmp" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g'); rm -f "$tmp"
    block "\`npm run $script\` 沒有通過，工作還沒完成。請看下面的輸出把問題修掉，全綠之後再結束（真的修不動的話，說明卡在哪、附上錯誤內容）。

--- $script 最後 40 行 ---
$tail_out"
  fi
  rm -f "$tmp"
done

# --- 檢查 2：UI 改動要有瀏覽器驗證 ---
if [ "$ui_touched" = "1" ] && [ "$browser_used" = "0" ]; then
  block "這個 session 改了畫面相關的檔案，但從頭到尾沒有用 Chrome MCP 實際開過瀏覽器。

請照下面做完再回報：
1. 啟動 dev server（跑在 tmux 裡，方便讀 log）
2. 用 mcp__claude-in-chrome 開對應頁面，**實際走一次使用流程**（不是只開起來看一眼）
3. 過程中截圖
4. 檢查 console：**不可以有任何 error 或 warning**，有就修掉
5. 回報你實際操作了什麼、看到什麼

只做 type-check 或「看起來應該沒問題」不算完成。
若這個專案沒辦法在瀏覽器驗證（例如純函式庫、無法啟動），直接說明原因即可。"
fi

exit 0
