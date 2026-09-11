---
description: "把這個專案的對話紀錄轉成可分享的 HTML（並啟用自動存檔）"
argument-hint: "[open]"
allowed-tools: ["Bash(python3:*)", "Bash(ls:*)", "Bash(open:*)", "Bash(du:*)"]
---

# 匯出對話紀錄

使用者輸入：`$ARGUMENTS`

## 做什麼

用 Bash 執行：

```bash
python3 "${CLAUDE_PLUGIN_ROOT}/scripts/transcript2html.py" --here
```

這會把**這個專案**歷次對話轉成 HTML，輸出到 `<專案>/docs/transcripts/`，
並產生索引頁。

`docs/transcripts/` 這個資料夾的存在同時也是**自動存檔的開關**——建立之後，
hook 會自動更新，不必再手動跑：每輪回合結束時更新這一場，對話結束時整個專案
重掃一遍。

## 執行後要回報

1. 轉出幾個 session、輸出在哪、佔多少空間（`du -sh`）。
2. 提醒自動存檔已啟用（因為資料夾現在存在了）。
3. **分享前的安全提醒**——這一點一定要講，不要省略：

> 對話紀錄是逐字保留的，包含所有工具的輸入與輸出。可能含 `.env` 內容、
> API key、內部主機名。commit 或分享之前先掃一次：
>
> ```bash
> grep -rioE "api[_-]key|secret|password|token|BEGIN.*PRIVATE KEY" docs/transcripts/*.html
> ```
>
> 要排除某一場對話，刪掉那個 .html 再重建索引即可。

4. 如果參數含 `open`，用 `open docs/transcripts/index.html` 幫忙打開。

## 注意

不要用 `--all`（那會轉出使用者**所有專案**的對話，通常不是這裡想要的）。
