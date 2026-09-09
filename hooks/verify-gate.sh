#!/usr/bin/env bash
# Stop hook：完成度守門員。
#
# 只在「這場對話真的改過檔案」時作動，然後檢查兩件事：
#   1. 被改到的每個子專案，測試與型別檢查都要過
#   2. 改了 UI 就要開過瀏覽器；改了 API 就要真的打過 endpoint
#
# 支援 monorepo：從改動的檔案往上找最近的專案根（package.json /
# pyproject.toml / go.mod / Cargo.toml），只跑被影響到的那些。
#
# 逃生開關：專案根放 .claude/.no-verify，或設 CLAUDE_SKIP_VERIFY=1
set -uo pipefail

# stdout 只能有我們要回傳的那一份 JSON。任何子指令不小心印到 stdout 的東西
# 都會弄壞它，所以把 fd 1 整個導到 stderr，另外留 fd 3 給真正的輸出。
exec 3>&1 1>&2

input=$(cat)
j() { printf '%s' "$input" | jq -r "$1" 2>/dev/null; }

# 這次停止本來就是上一輪 hook 擋下來的 → 放行，避免無限迴圈
[ "$(j '.stop_hook_active // false')" = "true" ] && exit 0

cwd=$(j '.cwd // ""')
[ -n "$cwd" ] && cd "$cwd" 2>/dev/null || exit 0

block() { jq -n --arg r "$1" '{decision:"block", reason:$r}' >&3; exit 0; }

[ -f .claude/.no-verify ] && exit 0
[ "${CLAUDE_SKIP_VERIFY:-}" = "1" ] && exit 0

# ---------- 掃 transcript：改了什麼、驗過什麼 ----------
tp=$(j '.transcript_path // ""')
[ -f "$tp" ] || exit 0

grep -q '"name":"\(Edit\|Write\|NotebookEdit\)"' "$tp" || exit 0   # 沒改過檔案

edited_files=$(grep -oE '"file_path":"[^"]+"' "$tp" | sed 's/"file_path":"//;s/"$//' | sort -u)
[ -n "$edited_files" ] || exit 0

ui_touched=0; api_touched=0
printf '%s\n' "$edited_files" | grep -qiE '\.(tsx|jsx|vue|svelte|css|scss|less|html|astro)$' && ui_touched=1
printf '%s\n' "$edited_files" \
  | grep -qiE '(^|/)(routes?|router|controllers?|handlers?|api|endpoints?|views|serializers)(/|\.)|(^|/)(urls|main|server|app)\.(py|js|ts)$' \
  && api_touched=1

browser_used=0; http_used=0
grep -q 'mcp__claude-in-chrome__\|chrome-devtools__' "$tp" && browser_used=1
grep -qE '\bcurl\b|\bhttpie\b|requests\.(get|post|put|delete)|\bfetch\(|TestClient|supertest|\bhttpx\b' "$tp" && http_used=1
# 開過瀏覽器就等於打過這個服務
[ "$browser_used" = "1" ] && http_used=1

# ---------- 找出被影響到的專案根 ----------
project_root_of() {   # 往上找最近含有專案標記檔的目錄
  local d; d=$(dirname "$1")
  while [ "$d" != "/" ] && [ -n "$d" ]; do
    for m in package.json pyproject.toml go.mod Cargo.toml; do
      [ -f "$d/$m" ] && { printf '%s\n' "$d"; return; }
    done
    d=$(dirname "$d")
  done
}

roots=$(while IFS= read -r f; do
          [ -n "$f" ] && project_root_of "$f"
        done <<< "$edited_files" | sort -u)
[ -n "$roots" ] || exit 0

# ---------- 執行測試 ----------
run_capped() {   # run_capped <秒> <輸出檔> <指令...>
  local secs=$1 out=$2; shift 2
  ( "$@" ) >"$out" 2>&1 </dev/null &
  local pid=$!
  # 看門狗必須切斷 stdout/stderr，否則會持有 hook 的輸出管道讓讀取端等不到 EOF
  ( sleep "$secs"; kill -9 "$pid" 2>/dev/null ) >/dev/null 2>&1 </dev/null &
  local w=$!
  wait "$pid"; local rc=$?
  # 先殺看門狗的子行程（那個 sleep），再殺看門狗本身。
  # 只殺 $w 的話，sleep 會變孤兒繼續跑滿秒數，一場對話下來會累積幾十個。
  pkill -9 -P "$w" 2>/dev/null
  kill -9 "$w" 2>/dev/null
  wait "$w" 2>/dev/null
  pkill -9 -P "$pid" 2>/dev/null
  return $rc
}

fail() {   # fail <專案根> <這步叫什麼> <輸出檔>
  local out; out=$(tail -40 "$3" | sed $'s/\033\\[[0-9;]*[a-zA-Z]//g')
  rm -f "$3"
  block "\`$2\`（在 $1）沒有通過，工作還沒完成。請把問題修掉，全綠之後再結束；
真的修不動的話，說明卡在哪並附上錯誤內容。

--- 最後 40 行 ---
$out"
}

while IFS= read -r root; do
  [ -n "$root" ] || continue
  tmp=$(mktemp)

  if [ -f "$root/package.json" ]; then
    for s in test typecheck; do
      jq -e --arg s "$s" '.scripts[$s] // empty' "$root/package.json" >/dev/null 2>&1 || continue
      run_capped 300 "$tmp" env CI=true npm --prefix "$root" run "$s" --silent \
        || fail "$root" "npm run $s" "$tmp"
    done

  elif [ -f "$root/pyproject.toml" ] || [ -f "$root/pytest.ini" ]; then
    if command -v pytest >/dev/null; then
      run_capped 300 "$tmp" sh -c "cd '$root' && pytest -q" \
        || fail "$root" "pytest" "$tmp"
    fi

  elif [ -f "$root/go.mod" ]; then
    run_capped 300 "$tmp" sh -c "cd '$root' && go test ./..." \
      || fail "$root" "go test ./..." "$tmp"

  elif [ -f "$root/Cargo.toml" ]; then
    run_capped 300 "$tmp" sh -c "cd '$root' && cargo test" \
      || fail "$root" "cargo test" "$tmp"
  fi

  rm -f "$tmp"
done <<< "$roots"

# ---------- 有沒有真的驗過 ----------
if [ "$ui_touched" = "1" ] && [ "$browser_used" = "0" ]; then
  block "這個 session 改了畫面相關的檔案，但從頭到尾沒有用 Chrome MCP 開過瀏覽器。

請照下面做完再回報：
1. 啟動服務（專案有 docker compose 就用 compose，否則跑在 tmux 裡方便讀 log）
2. 用 mcp__claude-in-chrome 開對應頁面，**先確認 <title> 是這個專案的**
   （埠口可能被別的服務佔用，連錯了會對著別人的畫面截圖）
3. **實際走一次使用流程**並截圖，不是只開起來看一眼
4. 檢查 console：不可以有任何 error 或 warning
5. 回報你實際操作了什麼、看到什麼

只做 type-check 或「看起來應該沒問題」不算完成。"
fi

if [ "$api_touched" = "1" ] && [ "$http_used" = "0" ]; then
  block "這個 session 改了 API／路由相關的檔案，但從頭到尾沒有真的打過任何 endpoint。

單元測試通過不等於服務跑得起來——啟動失敗、路由沒註冊、middleware 順序錯、
環境變數缺漏，這些單元測試都抓不到。請：

1. 把服務跑起來（有 docker compose 就 \`docker compose up -d\`）
2. 確認它活著：\`curl -s -o /dev/null -w '%{http_code}' http://localhost:<port>/health\`
3. **實際打一次你改到的 endpoint**，檢查狀態碼與回傳結構
4. 看服務 log 有沒有錯誤（\`docker compose logs --tail=50 <service>\`）
5. 回報你打了什麼、拿到什麼

若這次改動確實無法從外部呼叫（例如純內部工具函式），說明原因即可。"
fi

exit 0
