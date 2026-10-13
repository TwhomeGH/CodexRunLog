# Codex 運行日誌 — 改動說明

## 2026.10.14 01:27 新增 GitHub Pages（changelogkit 匯出）與 .gitattributes

**類型**: 工具 · **檔案**: `.github/workflows/pages.yml`

### 問題 - 沒有線上的更新歷史、換行不一致

更新歷史只在本機；且 Windows `core.autocrlf` 讓每次 `git add` 都出現 LF→CRLF 警告，跨平台換行不一致。

### 修改 - 部署 Pages 並統一換行

- 新增 `.github/workflows/pages.yml`：以 `python -m pip install changelogkit` 安裝，`changelogkit export _site --branch main` 後部署到 GitHub Pages（`actions/configure-pages`／`upload-pages-artifact`／`deploy-pages`）。
- 需在 repo Settings → Pages → Source 選「GitHub Actions」。
- 新增 `.gitattributes`（`* text=auto eol=lf`）統一換行，消除 CRLF 警告。

**相關文件**: [Codex運行日誌.md](Codex運行日誌.md)

---

## 2026.10.14 01:23 新增測試向量與 CI（PSScriptAnalyzer＋跨平台）

**類型**: 測試 · **檔案**: `scripts/check.ps1`

### 問題 - 缺固定測資與自動化檢查

測試直接內嵌字串、沒有可重用的 rollout 樣本；也沒有分析器或自動化檢查把關。

### 修改 - 加入 fixtures、檢查腳本與 CI

- 新增 `tests/fixtures/sessions/…` rollout 樣本，涵蓋新版 `custom_tool_call/exec` 與舊版 `function_call/exec_command|shell_command`，並補上端到端整合測試（現共 47 個測試）。
- 新增 `scripts/check.ps1`：PSScriptAnalyzer → Pester → 冒煙測試，失敗以非 0 結束。
- 新增 `PSScriptAnalyzerSettings.psd1`，只排除 `Write-Host`／`PSUseSingularNouns`／`PSUseBOMForUnicodeEncodedFile` 並註明理由；同時修掉空 catch（改 `Write-Verbose`）與 `Set-IniValue` 的 `ShouldProcess`。
- 新增 `.github/workflows/ci.yml`：Windows／Ubuntu／macOS 三平台執行。
- 測試 fixture 路徑與預設 sessions 目錄改用 `/` 分隔，提升跨平台性。

**相關文件**: [Codex運行日誌.md](Codex運行日誌.md)

---

## 2026.10.14 01:19 新增單元測試（Pester）：轉義、擷取、語言判斷、語句展開

**類型**: 測試 · **檔案**: `tests/CodexRunlog.Tests.ps1`

### 問題 - 核心邏輯沒有測試保護

轉義、擷取、語言判斷、語句展開都是純函式，先前卻沒有測試；日後調整容易無聲改壞輸出。

### 修改 - 導入 Pester 5 單元測試

- 新增 `tests/CodexRunlog.Tests.ps1`，共 41 個測試，涵蓋 `ConvertFrom-EscapedString`、`Get-JsField`／`Get-ExecFromJs`／`Get-CommandEventsFromLine`、`Get-CodeLanguage`、`Expand-PowerShellStatements`、`Format-Line`。
- 主腳本加入 **dot-source 守衛**：`if ($MyInvocation.InvocationName -eq '.') { return }`，讓測試只載入函式、不觸發主流程。
- 執行：`Invoke-Pester .\tests\CodexRunlog.Tests.ps1 -Output Detailed`（已寫入說明文件）。

**相關文件**: [Codex運行日誌.md](Codex運行日誌.md)

---

## 2026.10.14 01:14 新增 TODO.md：跨平台與 Web 頁面規劃

**類型**: 文件 · **檔案**: `TODO.md`

### 問題 - 未開始的規劃散落無處

目前只有 Windows/PowerShell 實作，Linux／macOS 對應產物與 Web 頁面等構想沒有地方集中記錄。

### 修改 - 建立 TODO.md 統整待辦

- 收錄跨平台（Linux/macOS、`CODEX_HOME`、`NO_COLOR`）、Web 頁面（本機唯讀 GUI、即時 tail）、資料完整性、UX、工程品質等未開始項目。
- 與 `Docs/ChangeHistory.md`（已完成）互補，並在 `Docs/Codex運行日誌.md` 交叉連結。

**相關文件**: [TODO.md](../TODO.md)

---

## 2026.10.14 01:01 導入 changelogkit 建立更新歷史

**類型**: 工具 · **檔案**: `.changelog.toml`

### 問題 - 專案沒有可追蹤的更新歷史

工具演進很快，卻沒有地方記錄「改過什麼、為什麼改」，難以回頭理解脈絡。

### 修改 - 以 changelogkit 管理

- 新增 `.changelog.toml`：設定標題、`history = Docs/ChangeHistory.md`、來源 `codexrunlog`。
- 以 `changelogkit add` 建立各筆骨架，再補上問題／根因／修改內文。
- 可用 `changelogkit list`、`show`、`serve`（網頁 GUI）、`export` 檢索與匯出。

**相關文件**: [Codex運行日誌.md](Codex運行日誌.md)

---

## 2026.10.14 00:58 新增 Docs/Codex運行日誌.md 使用說明

**類型**: 文件 · **檔案**: `Docs/Codex運行日誌.md`

### 問題 - 缺少使用說明

參數、資料來源與上色規則只存在腦中，換人接手或換台電腦就難以操作。

### 修改 - 撰寫完整說明文件

- 說明緣起、資料來源（rollout JSONL 與新舊兩代格式）、用法與參數。
- 附輸出範例、上色圖例、運作原理、疑難排解、限制與待辦。

**相關文件**: [Codex運行日誌.md](Codex運行日誌.md)

---

## 2026.10.14 00:55 sessions 目錄改用 %USERPROFILE% 並支援 CodexRunlog.ini

**類型**: 功能 · **檔案**: `Codex運行日誌.ps1`

### 問題 - sessions 路徑寫死單一使用者

原字串硬編 `C:\Users\agp05\.codex\sessions`，換一台 Windows 電腦就找不到目標。

### 修改 - 自動解析並記錄設定檔

- 解析順序：`-SessionsDir` 參數 → `CodexRunlog.ini` → `%USERPROFILE%\.codex\sessions`。
- 三者皆無時提示手動輸入，並把結果寫回 `CodexRunlog.ini`（UTF-8 無 BOM）。
- ini 指到的路徑若失效會自動忽略，改找本機預設，維持可攜。
- `-SessionsDir` 為明確指定，路徑不存在時直接報錯，不退回自動解析。

**相關文件**: [Codex運行日誌.md](Codex運行日誌.md)

---

## 2026.10.14 00:50 修正被 Codex 佔用中的 rollout 檔讀取失敗

**類型**: 修復 · **檔案**: `Codex運行日誌.ps1`

### 問題 - 讀取進行中的 session 檔會直接拋錯

執行到一半出現 `The process cannot access the file ... because it is being used by another process`，整個程式中止。

### 根因 - 開檔共享模式太嚴

`[System.IO.File]::ReadLines` 與預設的 `Get-Content` 用了與 Codex 正在寫入相衝突的共享模式。

### 修改 - 一律以共用模式開檔

- 新增 `Open-SharedRead`，以 `FileShare.ReadWrite | Delete` 開啟檔案。
- 回溯、取 cwd、`-Tail` 三段讀取全改走共用模式。
- 逐檔包 try／catch，鎖住的檔跳過而非中斷整個輸出。

---

## 2026.10.14 00:46 修正時區（UTC→本地）並顯示專案工作目錄

**類型**: 修復 · **檔案**: `Codex運行日誌.ps1`

### 問題 - 時間少 8 小時、專案欄位全空

rollout 顯示的時間比實際早 8 小時；標頭的專案名稱整欄空白。

### 根因 - 時區 Kind 遺失；新版 exec 不帶 workdir

- `[DateTimeOffset]::Parse` 把 UTC 值當成本地時間，少算時差。
- 新版 `custom_tool_call` 的 input 不含 `workdir` 欄位。

### 修改 - 正確轉時區並補上 cwd

- 改用 `([DateTimeOffset][datetime]$ts).ToLocalTime()`，保留 UTC→本地換算。
- 讀每個 rollout 第一行 `session_meta` 的 `cwd` 當預設工作目錄，標頭顯示專案名。

---

## 2026.10.14 00:40 改讀 rollout JSONL：取用完整未截斷的指令

**類型**: 改進 · **檔案**: `Codex運行日誌.ps1`

### 問題 - 長指令被截斷

SQLite 的 `feedback_log_body` 是 Codex 的預覽版，長指令（例如 Python heredoc）會被砍在中途。

### 根因 - 資料源本身就是截斷預覽

`feedback_log_body` 存的是 `<N bytes>` 截斷預覽，取不到完整指令，非腳本問題。

### 修改 - 改讀 rollout JSONL

- 來源改為 `%USERPROFILE%\.codex\sessions\<年>\<月>\<日>\rollout-*.jsonl`。
- 取 top-level `type=response_item`：新版 `custom_tool_call/exec`（input 為 JS）、舊版 `function_call/exec_command|shell_command`（arguments 為 JSON）。
- 連帶保有完整的 `justification`（Codex 的中文說明），不再被截斷。

---

## 2026.10.14 00:26 新增 -Tail 持續監看後續新紀錄

**類型**: 功能 · **檔案**: `Codex運行日誌.ps1`

### 問題 - 只能看歷史快照

印完起始內容後，無法持續追蹤 Codex 之後又做了什麼。

### 修改 - 新增 -Tail／-Interval

- 記錄每個 rollout 檔的位元組位移，輪詢時只讀新增部分，並保留未完成的尾行。
- 新出現的 session 檔自動納入監看；以 `Ctrl+C` 結束。

---

## 2026.10.14 00:18 重寫輸出與語法上色：修正分號與大括號誤斷行、還原雙層轉義

**類型**: 修復 · **檔案**: `Codex運行日誌.ps1`

### 問題 - 上色錯誤、程式碼被弄壞

顏色互相污染；字串內的 `;` `{` `}` 被硬斷行；`\"`、`\\n` 等轉義原樣顯示。

### 根因 - 取資料與著色做法不當

- 以 `|` 切 sqlite 輸出欄位，指令本身含管線就會被截斷。
- 未還原 `feedback_log_body` 的雙層轉義（JSON + Rust-debug），直接對原始字串做全域 `-replace`。

### 修改 - 重寫擷取與上色流程

- 改以 `sqlite3 -json` + `ConvertFrom-Json` 取數，並連續還原兩次轉義取得真正指令。
- 上色改為單次掃描 tokenizer，字串／註解優先匹配，避免色碼互染。
- 僅 PowerShell 展開語句：字串外用 `;{}` 斷行縮排，`for(;;)` 以括號深度保護。
- 依語言上色：PowerShell、Python、JavaScript、Shell(git)。

---
