#!/usr/bin/env bash
# SessionStart hook：把工作準則注入這次對話。
#
# Plugin 沒辦法寫入使用者的 ~/.claude/CLAUDE.md，所以改用這個 hook 把
# 「常駐規則」以 additionalContext 的形式送進脈絡，效果等同。
#
# 另外偵測 <專案>/.claude/UNATTENDED，有的話追加無人值守的行為準則。
set -uo pipefail

input=$(cat)
cwd=$(printf '%s' "$input" | jq -r '.cwd // ""' 2>/dev/null)
[ -n "$cwd" ] || cwd="$PWD"

base='## 決策：不要停下來問

- 需要在幾個方案之間抉擇時，直接採用你會推薦的那一個繼續執行。動手前用一兩句話
  說明「選了哪個、為什麼」，不要停下來等回答。
- 只有這兩種情況才問：(1) 選錯會造成不可逆損害；(2) 需求本身有兩種完全相反的解讀。
- 其餘一律自行判斷、寫清楚假設、繼續往下做。

## Web 專案的完成定義

三點同時滿足才算做完，沒滿足就繼續做，不要先回報：

1. 測試全綠（`npm test`）；專案若有 `typecheck` 也要通過。
2. UI 改動驗證（強制）：動到任何前端後，用 Chrome MCP 實際走一次使用流程並截圖。
   只做 type-check 不算數。console 不可以有任何 error 或 warning。
3. 回報要具體：說明「驗證了什麼、看到什麼結果」，不要用「應該可以了」這種說法。

開頁面後先確認 <title> 是這個專案的——埠口可能被別的服務佔用，連錯了會對著
別人的畫面截圖還以為驗證通過。

## 文件要寫到對的地方

README.md 給第一次看到專案的人讀：這是什麼、怎麼跑、結構。保持精簡穩定，
每次是「改寫」不是「追加」。

會逐次累積的東西分流出去（沒有就建立）：

| 檔案 | 放什麼 |
|---|---|
| `docs/DECISIONS.md` | 自行判斷的取捨：決定什麼、為什麼、代價 |
| `docs/VERIFICATION.md` | 每輪驗證實際看到什麼 |

追加時不要改寫既有條目——過去的判斷即使後來被推翻，也是有用的脈絡。

## Git

**一般互動開發：不要自己 commit，等使用者說。** 他常常想先看過改動再決定。
（無人值守模式的規則不同，見下方——那時要每完成一項就 commit。）

規則：

- **永遠不要自己 `push`。** commit 是本地的、可以反悔；push 是對外動作，
  一定要使用者明說。
- commit 訊息用祈使句寫「做了什麼」，必要時空一行補「為什麼」。
- commit 前先確認 `git status`，不要順手把不相干的檔案一起帶進去。
- 開新 repo 時尊重使用者既有的分支慣例（看 `git config init.defaultBranch`）。

`docs/transcripts/` 若要進版控，先掃過一次再 commit——那是逐字紀錄，
可能含 `.env` 內容、API key、內部主機名：

```
grep -rioE "api[_-]key|secret|password|token|BEGIN.*PRIVATE KEY" docs/transcripts/*.html
```'

marker="$cwd/.claude/UNATTENDED"
if [ -f "$marker" ]; then
  note=$(head -1 "$marker" 2>/dev/null)
  extra='

---

⚠️ 【無人值守模式】（偵測到 .claude/UNATTENDED）

使用者不在電腦前，不會回答任何問題。上面的規則之外，追加：

1. 絕對不要停下來問問題。抉擇自己做，理由寫進 docs/DECISIONS.md。
2. 每完成一個功能項目、且測試全綠時 commit 一次。切分點是功能項目，不是檔案。
3. 在分支上做（feat/<項目>），不要直接動 main。
4. 永遠不要 push。
5. 卡住超過兩次嘗試就跳過該項、繼續下一項，最後在 README 的「未完成事項」說明。
6. 全部做完後回報：完成什麼、跳過什麼、產生哪些 commit。

結束無人值守：刪掉 .claude/UNATTENDED。'
  [ -n "$note" ] && extra="$extra

本次任務備註：$note"
  base="$base$extra"
fi

jq -n --arg c "$base" \
  '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
exit 0
