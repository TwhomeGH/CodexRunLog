# Codex 運行日誌（CodexRunlog）

把 Codex 每次實際執行的指令，從 rollout 記錄中撈出來、依語言上色後輸出，讓你**明確知道 Codex 在幹嘛**。

- 主程式：`Codex運行日誌.ps1`
- 環境：**Windows + PowerShell 7**（腳本有 `#requires -Version 7.0`）

---

## 緣起

一開始是讀 Codex 的 SQLite 記錄（`logs_2.sqlite` 的 `feedback_log_body`），但那個欄位存的是 **Codex 自己的預覽截斷版**，長指令會被砍在中途（例如 Python heredoc 只到 `p=Path('Do`）。所以現在改讀 **rollout JSONL**——那裡是**完整未截斷**的指令，也連帶保有 `justification`（Codex 對「為什麼要跑這條」的中文說明）。

---

## 資料來源

根目錄（預設，會依目前使用者自動展開）：

```bash
%USERPROFILE%\.codex\sessions\<年>\<月>\<日>\rollout-*.jsonl
```

解析順序：**`-SessionsDir` 參數 → 設定檔 `CodexRunlog.ini` → `%USERPROFILE%\.codex\sessions`**；三者都找不到時，會**提示手動輸入**，並把結果寫回 `CodexRunlog.ini`（見下方〈設定檔〉）。

每個 session 一個檔案，一行一個 JSON。本工具只挑 **top-level `type == "response_item"`** 的行，再依 `payload.type` 分兩代格式：

| 版本 | `payload.type` | `payload.name` | 指令位置 |
| --- | --- | --- | --- |
| 新版（0.162 起） | `custom_tool_call` | `exec` | `payload.input`（JS）內含 `tools.exec_command({cmd:"…",justification:"…",sandbox_permissions:"…"})` |
| 舊版 | `function_call` | `exec_command` / `shell_command` | `payload.arguments`（JSON：`cmd` / `command` / `workdir` / `shell`） |

其他補充：

- **時間**：rollout 的 `timestamp` 是 **UTC（帶 `Z`）**，程式會轉成本地時間顯示。
- **工作目錄**：新版 `exec` input 不帶 workdir，改讀每檔第一行 `session_meta` 的 `cwd`，在標頭顯示專案名。
- **結果**：`payload.call_id` 可對應 `function_call_output` / `custom_tool_call_output`（目前尚未顯示，見「待辦」）。

---

## 用法

```powershell
# 最新 50 筆指令
.\Codex運行日誌.ps1

# 最新 100 筆
.\Codex運行日誌.ps1 -Limit 100

# 持續監看後續新紀錄（每 2 秒輪詢）
.\Codex運行日誌.ps1 -Tail

# 自訂輪詢間隔（秒）
.\Codex運行日誌.ps1 -Tail -Interval 3

# 指定其他 sessions 目錄（會覆蓋設定檔）
.\Codex運行日誌.ps1 -SessionsDir 'D:\codex\sessions'
```

### 參數

| 參數 | 型別 | 預設 | 說明 |
| --- | --- | --- | --- |
| `-Limit` | int | `50` | 起始顯示筆數（由新到舊） |
| `-Tail` | switch | 關 | 印完起始內容後，輪詢並即時輸出後續新紀錄 |
| `-Interval` | int | `2` | `-Tail` 的輪詢間隔秒數 |
| `-SessionsDir` | string | 自動解析 | rollout JSONL 根目錄；省略時依「設定檔 → `%USERPROFILE%\.codex\sessions` → 手動輸入」解析 |

`-Tail` 用 `Ctrl+C` 結束。

### 設定檔 `CodexRunlog.ini`

放在**腳本同一資料夾**，首次找不到目錄而手動輸入時自動產生（UTF-8，無 BOM）：

```ini
[paths]
sessions = C:\Users\someone\.codex\sessions
```

- 換到別台電腦時，若 ini 指到的路徑不存在，會自動忽略並改找該機的 `%USERPROFILE%\.codex\sessions`，仍找不到才提示重新輸入。
- 想改路徑：直接編輯 ini，或用 `-SessionsDir` 暫時覆蓋。

---

## 輸出範例

```bash
──────────────────────────────────────────────────────────────────────────────
2026/10/13 22:23:11  my_monitor_esp32
  [PowerShell]
  Get-Content tools/test-ntfy-ui.cjs
  Get-Content notify.cpp -TotalCount 65
  Get-Content ntfy_test.cpp -TotalCount 65
  ↳ 讀取測試與原始檔內容以核對修改結果。
```

每筆顯示：

1. **標頭**：本地時間 + 專案目錄（取自 session cwd）
2. **`[語言]  sandbox=…`**：判斷出的語言，以及沙箱權限（若有）
3. **指令本體**：依語言上色，PowerShell 一行多句會展開縮排
4. **`↳ 理由`**：Codex 的 `justification`（若有）

### 上色圖例

| 顏色 | 代表 |
| --- | --- |
| 洋紅 magenta | 關鍵字（`if` / `for` / `import` / `const` …） |
| 綠 green | 字串 |
| 灰 gray | 註解 |
| 黃 yellow | Cmdlet（`Get-ChildItem`）、Python 內建函式、JS 全域物件 |
| 亮青 bright cyan | 變數（`$env:PATH`） |
| 亮藍 bright blue | 參數 / 旗標（`-ErrorAction`、`--check`） |
| 亮洋紅 bright magenta | 數字 |
| 青 cyan | `git` 與子命令、`[語言]` 標籤 |
| 亮黃 bright yellow | `↳` 之後的 justification |

---

## 運作原理

1. **掃檔**：列出所有 `rollout-*.jsonl`，依 `LastWriteTime` 由新到舊處理，累積到 `-Limit` 筆就停。
2. **取指令事件**：只解析含 `exec_command` / `shell_command` 關鍵字的行（先做便宜的字串預篩，省去大量 JSON 解析），還原轉義後取出 `cmd` / `justification` / `sandbox_permissions` / `workdir`。
3. **語言判斷**：
   - here-string（`@'…'@` / `@"…"@`）先看內容是 Python（`import` / `def` / `print(`）還是 JavaScript（`require(` / `=>` / `const`）。
   - 其他依 PowerShell cmdlet / `$var` / `#`、`git`、或預設 shell 判定。
4. **上色**：單次掃描 tokenizer，**字串/註解優先**匹配，避免關鍵字跑進字串、色碼互相污染。
5. **展開**：僅 PowerShell 會把 `;` `{` `}` 在**字串外**斷行並 4 空格縮排；`for(;;)` 之類用**括號深度**保護不誤斷。
6. **監看**：`-Tail` 記錄每個檔的**位元組位移**，輪詢時只讀新增部分，保留未完成的尾行；新 session 檔自動納入。

---

## 疑難排解

**`The process cannot access the file ... because it is being used by another process`**

Codex 正在寫入該 rollout 檔。程式已用 `FileShare.ReadWrite | Delete` 共用模式開檔，理論上不會再撞；若仍遇到，請更新到本版（讀取全走共用模式，且逐檔包 try/catch，鎖住的檔會跳過）。

**時間看起來少 8 小時。**

rollout 的 `timestamp` 是 UTC。程式已用 `([DateTimeOffset][datetime]$ts).ToLocalTime()` 轉本地時間；若你的時區不是 UTC+8，顯示會自動跟著系統時區走。

**畫面提示要輸入 sessions 目錄。**

表示 `-SessionsDir`、`CodexRunlog.ini`、`%USERPROFILE%\.codex\sessions` 都不存在。照提示輸入正確目錄即可，會自動記錄到 `CodexRunlog.ini`，下次不用再輸。

**指定了 `-SessionsDir` 卻直接報錯**

`-SessionsDir` 是明確指定，路徑不存在時會直接拋錯（不會退回自動解析），請確認路徑拼寫。

**輸出是 `←[32m…` 這種亂碼**

你的終端不支援 ANSI。請用 Windows Terminal，或 PowerShell 7（`$PSStyle.OutputRendering` 維持預設即可）。

---

## 限制與待辦

- **尚未顯示執行結果**：`tool_output`（成功/失敗、exit code、耗時）已可由 `call_id` 配對，尚未納入顯示。
- **語言判斷為啟發式**：`node -e "…"` 這類「PowerShell 跑 JS」會標成 JavaScript，屬合理但非完美。
- **僅涵蓋 shell 類工具**：`exec_command` / `shell_command` / `exec`；`apply_patch` 等編輯工具未顯示。

> 完整的待辦（含跨平台 Linux/macOS 與 Web 頁面規劃）見專案根目錄 [`TODO.md`](../TODO.md)。

---

## 開發者：測試與 CI

單元測試使用 **Pester 5**（首次需安裝）：

```powershell
Install-Module Pester -Scope CurrentUser -MinimumVersion 5.0

# 只跑測試
Invoke-Pester .\tests\CodexRunlog.Tests.ps1 -Output Detailed

# 分析器 + 測試 + 冒煙（CI 用）
pwsh -File .\scripts\check.ps1
```

- 測資 fixtures：`tests/fixtures/sessions/…`，涵蓋新版 `custom_tool_call/exec` 與舊版 `function_call/exec_command|shell_command`。
- 分析器設定：`PSScriptAnalyzerSettings.psd1`（只排除 `Write-Host`、`PSUseSingularNouns`、`PSUseBOMForUnicodeEncodedFile` 三條，並在檔案內註明理由）。
- GitHub Actions：`.github/workflows/ci.yml` 於 Windows／Ubuntu／macOS 執行（非 Windows 只跑分析器與測試，冒煙測試略過）。

涵蓋範圍：

- `ConvertFrom-EscapedString`：轉義還原
- `Get-JsField` / `Get-ExecFromJs` / `Get-CommandEventsFromLine`：指令擷取（新舊格式）
- `Get-CodeLanguage`：語言判斷
- `Expand-PowerShellStatements`：語句展開（字串／括號／註解保護）
- `Format-Line`：語法上色（色碼與不互染）

> 腳本被 **dot-source** 時會跳過主流程，測試才能只載入函式：`if ($MyInvocation.InvocationName -eq '.') { return }`。

---

## 相關記憶（給未來的自己）

- rollout 路徑、格式、UTC 時間等事實。
- Windows 讀取被寫入中的檔案需 `FileShare.ReadWrite | Delete`。

---

## 更新歷史

本專案的改動紀錄由 **changelogkit** 維護，存放於 [`ChangeHistory.md`](ChangeHistory.md)。

```powershell
# 新增一筆（會插到最前面）
changelogkit add "一句話標題" --type 修復 --file Codex運行日誌.ps1

# 檢索 / 顯示 / 網頁 / 匯出
changelogkit list
changelogkit show 1
changelogkit serve        # 本機網頁 GUI
changelogkit export _site # 唯讀靜態站
```

> 註：在 Windows 上以 `changelogkit` 的 CLI 時若中文顯示亂碼，先設 `$env:PYTHONIOENCODING='utf-8'`。
