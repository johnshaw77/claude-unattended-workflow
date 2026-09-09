# claude-unattended-workflow

讓 Claude Code 能**一路做到底再回報**，而不是做兩步就停下來問你——並且把每次
對話存成可調閱的 HTML。

適合的情境：丟一份規格給它、去忙別的、回來看結果。

## 安裝

```
/plugin marketplace add johnshaw77/claude-unattended-workflow
/plugin install unattended-workflow
```

裝完**重開 Claude Code**（hook 設定在對話開始時載入）。

需要 `jq` 和 `python3`。轉檔功能只用 Python 標準庫，不必 pip install。

## 它做四件事

### 1. 常駐工作準則

每次對話開始時注入，不必在每個專案的 `CLAUDE.md` 重複寫：

- **決策**：遇到抉擇直接採用推薦方案繼續做，只有「不可逆損害」或「需求有兩種
  相反解讀」才問你。
- **Web 完成定義**：測試全綠 + UI 改動要用 Chrome MCP 實際走一次流程並截圖 +
  console 零 error/warning + 回報要具體。
- **後端完成定義**：改了 API 就要真的打一次 endpoint（正常與錯誤路徑都打）、
  看服務 log、確認 migration。框架不拘，Fastify / Express / FastAPI / Django / Go
  都適用。
- **Docker**：有 compose 就用 compose 跑，不要手動起服務。改了程式要確認容器
  真的重建。`down -v` 會刪資料，一定要先問。
- **文件分流**：README 保持精簡；取捨寫 `docs/DECISIONS.md`、驗證寫
  `docs/VERIFICATION.md`，兩者逐次追加不改寫。
- **Git**：互動開發時不自己 commit，永遠不自己 push。

> Plugin 無法寫入你的 `~/.claude/CLAUDE.md`，所以改用 SessionStart hook 注入，
> 效果相同。你自己的 CLAUDE.md 仍然有效，兩者會疊加。

### 2. 完成度守門員（Stop hook）

Claude 想結束回合時攔一次，檢查三件事：

**一、測試與型別**。支援多種語言，並且**認得 monorepo**——它會從這次改動的檔案
往上找最近的專案根，只跑被影響到的那些：

| 偵測到 | 執行 |
|---|---|
| `package.json` | `npm run test`、`npm run typecheck`（有才跑） |
| `pyproject.toml` / `pytest.ini` | `pytest -q` |
| `go.mod` | `go test ./...` |
| `Cargo.toml` | `cargo test` |

改 `frontend/` 不會被 `backend/` 的失敗連累，反之亦然。

**二、改了 UI 卻整場沒用過 Chrome MCP** → 擋下來要求實測。

**三、改了 API／路由卻整場沒打過任何 endpoint** → 擋下來要求真的呼叫一次。
（偵測 `curl`、`httpie`、`requests`、`fetch`、`TestClient`、`supertest`、`httpx`，
或用過瀏覽器。）

**只擋一次**（檢查 `stop_hook_active`），避免服務起不來時無限迴圈。
它是提醒，不是牢籠。

這場對話沒改過檔案、或找不到任何專案根，都會直接放行。
專案要豁免就建立 `.claude/.no-verify`。

### 3. 互動／無人值守模式切換

```
/unattended 把 SPEC.md 六項功能做完     開啟
/unattended off                          關閉
/unattended status                       查詢
```

開關是標記檔 `<專案>/.claude/UNATTENDED`——用檔案而不是靠語氣推測，因為
「要不要自動 commit」不該建立在猜測上。

| | 互動開發（預設） | 無人值守 |
|---|---|---|
| 遇到抉擇 | 可以問你 | 一律自己決定，理由寫進 `docs/DECISIONS.md` |
| commit | 不自動做 | 每完成一項 + 測試綠就 commit |
| 分支 | 你決定 | 一定在 `feat/*`，不動 `main` |
| push | 要你明說 | 永遠不做 |
| 卡住 | 問你 | 試兩次就跳過，最後在 README 說明 |

⚠️ **標記檔記得刪**，否則那個專案之後每次對話都會是無人值守。
不確定就跑 `/unattended status`。

### 4. 對話紀錄存成 HTML

```
/transcripts
```

把這個專案歷次對話轉成 HTML 放進 `docs/transcripts/`，含索引頁與全文搜尋。
提問與回覆直接展開，思考過程、工具呼叫、工具輸出預設摺疊。

跑過一次之後，`docs/transcripts/` 的存在就是**自動存檔的開關**——SessionEnd hook
每次對話結束都會自動更新。不想要就刪掉那個資料夾。

全域封存另外放在 `~/.claude/transcripts/`（所有專案）。

⚠️ **分享前務必檢查**：紀錄是逐字保留的，包含所有工具輸入輸出，可能含 `.env`
內容或 token。

```bash
grep -rioE "api[_-]key|secret|password|token|BEGIN.*PRIVATE KEY" docs/transcripts/*.html
```

## 搭配 tmux 使用

Claude Code 是終端機程序，關掉視窗就中斷。要真的走人，讓它住在 tmux 裡：

```bash
tmux new-session -s claude
cd <專案>
claude
# 貼任務，然後 Ctrl+b 放開再按 d 脫離，現在可以關掉編輯器
tmux attach -t claude   # 回來接上
```

被中斷了可以 `claude --resume` 或 `claude -c` 接續。

### 選配：一鍵啟動腳本

`bin/unattended` 把「建立標記檔 + 開 tmux + 啟動 Claude Code」包成一個指令。
它**不會自動安裝**（plugin 不能動你的 PATH），要用的話自己接上：

```bash
mkdir -p ~/.local/bin
cp <這個 repo>/bin/unattended ~/.local/bin/
chmod +x ~/.local/bin/unattended
# 確認 ~/.local/bin 在 PATH 裡，沒有的話加進 ~/.zshrc
```

然後：

```bash
cd <專案>
git checkout -b feat/xxx
unattended "把 SPEC.md 的六項功能做完"
tmux attach -t claude-<專案>      # 進去貼任務
```

它會先檢查 tmux 與 claude 存在、session 沒重複、目前不在 `main` 上，
並在 claude 結束時自動清掉標記檔。

不裝也完全沒差——`/unattended` 指令加上手動開 tmux 是一樣的效果。

## 走人前檢查清單

- [ ] Claude Code 跑在 tmux 裡
- [ ] 任務有**客觀的**完成條件（測試全綠 / 某個檔案產出）
- [ ] 已跑過 `/transcripts` 啟用存檔
- [ ] 已 `/unattended <備註>` 開啟無人值守
- [ ] 在分支上，不是 `main`
- [ ] dev server 的 port 沒被別的服務佔用（**驗證時先確認 `<title>` 是自己的專案**）

## 檔案結構

```
hooks/
  session-start.sh        注入常駐準則 + 偵測無人值守模式
  verify-gate.sh          Stop：測試沒綠、UI 沒驗過就擋
  archive-transcript.sh   SessionEnd：轉存 HTML
commands/
  unattended.md           /unattended
  transcripts.md          /transcripts
scripts/
  transcript2html.py      JSONL → HTML（純標準庫）
bin/
  unattended              選配：一鍵啟動（需自行放進 PATH）
```

## 遇到問題

看 [`docs/TROUBLESHOOTING.md`](docs/TROUBLESHOOTING.md)：守門員沒擋、改了 plugin
沒生效、**埠口衝突導致驗證假通過**、存檔沒產生、無人值守關不掉。

## 授權

MIT
