# Codex 運行日誌（CodexRunlog）

把 Codex 每次實際執行的指令，從 rollout 記錄中撈出來、依語言上色後輸出，讓你**明確知道 Codex 在幹嘛**。

- 主程式：`CodexRunLog.ps1`
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
- **結果**：`payload.call_id` 可對應 `function_call_output` / `custom_tool_call_output`，顯示 exit code、耗時與輸出內容（`-NoOutput` 可關）。

### 非指令事件（檔案變更／MCP／Web 搜尋）

同一個 rollout 除 `response_item` 外還有 `event_msg` 的 `item_completed`；工具會把它變成時間軸上的事件，和指令一起排序：

| `item.type` | 顯示 |
| --- | --- |
| `FileChange` | `[檔案變更]`：新增／修改／刪除＋diff 的 `+N -M` 行數 |
| `McpToolCall` | `[MCP]`：server.tool 與參數（截斷至 160 字） |
| `Extension`（`web.search`） | `[Web 搜尋]`：查詢數、結果數與第一個查詢 |
| `AgentMessage` | `[Agent]`：Codex 的文字回覆（需 `-Messages`），標註 `commentary`／`final_answer` |

`CommandExecution` 的 `item_completed` 不重複顯示（指令本來就從 `response_item` 來）。`-NoActivity` 可回到只看指令，`-Messages` 再加上文字回覆。

`Reasoning` 的 `summary_text` 與 `raw_content` 在 rollout 裡實測全為空，因此不提供顯示。

### 本機會話索引（rollout 以外）

工具的資料來源是 rollout JSONL；`~/.codex` 另外還有會話索引，用來確認「有沒有比 rollout 更新的本機會話」。

| 訊號 | 來源 | 說明 |
| --- | --- | --- |
| 會話索引 | `session_index.jsonl` | 不需 `sqlite3`；Guardian review 略過 |
| 非專案對話 | `Documents\Codex\<日期>\<對話>` | 只有 `work`／`outputs`，沒有逐字稿 |
| 會話清單 | `state_*.sqlite` 的 `threads` | 需 `sqlite3`；排除 subagent／guardian |
| 逐字稿 | `thread_history_*.sqlite` 的 `thread_items` | 同上過濾 |
| 背景活動 | `logs_*.sqlite` 的 `thread_id` | 只列在 `-Diag`；含 ambient／背景執行，**不算會話** |
| 專案活動 | `state_*.sqlite` 的 `projects` | 只列在 `-Diag` |

- 比對基準是**所有 rollout 檔的最新事件**（含 `session_meta`／`compaction` 等不顯示的行），不是清單最後一筆。
- 只有會話類訊號（索引／`threads`／逐字稿／非專案對話）晚於基準 60 秒以上時才提示。
- 例：本機最後使用為 11/12–11/13；rollout 最新事件 11/12 10:17，但 `Documents\Codex\2026-11-13\new-chat` 為 11/13 23:38 → 提示非專案對話不在清單內。

> 非專案對話資料夾只存 `work/`、`outputs/`（對話產生的檔案），**不含逐字稿**；因此工具只能提示「有這個對話」，無法顯示內容。

### Hooks（補齊沒有 rollout 的會話）

rollout 只覆蓋部分會話（例如非專案對話可能不寫 rollout）。Codex 的 hooks 是官方穩定介面，可在工具呼叫後把**結構化事件**寫成本機 JSONL：

| 項目 | 內容 |
| --- | --- |
| 收集器 | `hooks/codex-runlog-hook.py` → `~/.codex/runlog/events.jsonl` |
| 安裝 | `pwsh -File .\hooks\Install-Hook.ps1` |
| 信任 | 桌面版 **Settings > Hooks** 或 CLI `/hooks`（未信任不會執行） |
| 移除 | `pwsh -File .\hooks\Install-Hook.ps1 -Uninstall` |

涵蓋事件：`PostToolUse` 的 `Bash`（含 `exec_command`）、`apply_patch`、MCP、其他本地函式工具，以及 `SessionStart`／`SessionEnd` 兩個會話邊界。`WebSearch` 等 hosted tool 不經本地 hook，仍由 rollout 提供。

會話邊界會顯示成 `[Session 開始]`（含 `source`，例如 `startup`）與 `[Session 結束]`，用來分辨「清單停住」是沒有新事件，還是會話已結束。

去重規則：若事件的 `transcript_path` 存在（有 rollout），工具事件交給 rollout（exit code／耗時較完整）；**會話邊界例外**，因為 rollout 沒有開始／結束標記，仍由 hook 提供。`-NoActivity` 只保留指令，會一併隱藏會話邊界。

限制：

- Windows 上 hook command 以空白切分，**路徑不能含空白**（安裝器會先檢查）。
- `SessionEnd` 逾時上限 3 秒；hook 失敗不影響 Codex 執行。
- 安裝後仍需在 Codex 審查並信任；hook 檔案變更會重新要求審查。

### 雲端環境（exec-server --remote）

Codex 可在遠端環境執行，例如：

```text
codex.exe … exec-server --concurrent-requests 32 \
  --remote https://codex-cloud-environments.chatgpt.com/api \
  --environment-id ccarenv_b64_…
```

這類會話的逐字稿與工具呼叫都在雲端，**不會寫入本機 rollout，也不經本機 hooks**，所以清單看不到任何內容。

工具會掃描執行中的 `codex.exe` 命令列，發現雲端 exec-server 時在輸出末尾提示：

```text
ℹ 雲端環境執行中：ccarenv_6abcf53396e08191affed674754b178b，自 2026/11/17 02:57:47；
  這類對話不會寫入本機 rollout／hook。
```

`-Diag` 會列出 PID、遠端 URL 與環境 ID。若要在本機留下逐字稿與指令，請在 Codex 新開對話時選擇 **Local** 環境。

找不到 `sqlite3.exe` 時只比對 `session_index.jsonl`，不影響主流程；`-Tail` 只在啟動時檢查一次。

---

## 用法

```powershell
# 最新 50 筆指令
.\CodexRunLog.ps1

# 最新 100 筆
.\CodexRunLog.ps1 -Limit 100

# 持續監看後續新紀錄（檔案變更即時顯示）
.\CodexRunLog.ps1 -Tail

# 不用檔案變更通知，改固定輪詢（每 2 秒）
.\CodexRunLog.ps1 -Tail -PollOnly -Interval 2

# 指定其他 sessions 目錄（會覆蓋設定檔）
.\CodexRunLog.ps1 -SessionsDir 'D:\codex\sessions'
```

### 參數

| 參數 | 型別 | 預設 | 說明 |
| --- | --- | --- | --- |
| `-Limit` | int | `50` | 取最新的 N 筆事件（指令、檔案變更、MCP 呼叫、Web 搜尋）；輸出由舊到新（最新在最下方），與 `-Tail` 一致 |
| `-Tail` | switch | 關 | 印完起始內容後持續監看；檔案變更即時輸出（由舊到新，最新在最底部） |
| `-Interval` | int | `60` | 監看的安全檢查間隔秒數（有變更時即時輸出；此為後援） |
| `-PollOnly` | switch | 關 | 不用檔案變更通知，改固定輪詢（網路磁碟等環境） |
| `-SessionsDir` | string | 自動解析 | rollout JSONL 根目錄；省略時依「設定檔 → `%USERPROFILE%\.codex\sessions` → 手動輸入」解析 |
| `-OutputLines` | int | `8` | 每筆結果最多顯示頭尾各 N 行；`0` 表示全部 |
| `-NoOutput` | switch | 關 | 不顯示執行結果 |
| `-NoActivity` | switch | 關 | 只顯示指令；略過檔案變更、MCP 呼叫與 Web 搜尋 |
| `-Messages` | switch | 關 | 額外顯示 AgentMessage（Codex 的文字回覆） |
| `-Diag` | switch | 關 | 診斷：列出各 rollout 檔的活動時間、mtime、大小、指令／結果數，以及 本機會話訊號 |

> 本表為速查。參數與用法的**權威來源是程式內的註解說明**，執行 `Get-Help .\CodexRunLog.ps1 -Full`（另有 `-Examples`、`-Online`）即可取得；修改參數時請一併更新註解。

`-Tail` 用 `Ctrl+C` 結束。

監看模式的排序與除重：

- 起始內容**由舊到新**排列（最新在最底部），後續新事件自然往下接續，維持單一時間軸、不會亂序。
- 以 `FileSystemWatcher` 即時偵測檔案變更，閒置時不做掃描；每 `-Interval` 秒僅做一次安全檢查。
- 以「時間下限」過濾：只有比目前最新事件更新者才輸出，避免新出現的 rollout 檔**重播舊內容**。

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

──────────────────────────────────────────────────────────────────────────────
2026/10/31 08:52:44  my_monitor_esp32
  [檔案變更]
  修改  C:\Users\me\proj\Test-Scripts.ps1  +3 -1
  修改  C:\Users\me\proj\Docs\ChangeHistory.md  +1 -1

──────────────────────────────────────────────────────────────────────────────
2026/11/11 00:21:59  ProcessFix
  [Web 搜尋]  2 個查詢，26 筆結果
  site.learn.microsoft.com NotifyIcon ShowBalloonTip …
```

每筆顯示：

1. **標頭**：本地時間 + 專案目錄（取自 session cwd）
2. **`[語言]  sandbox=…`**：判斷出的語言，以及沙箱權限（若有）
3. **指令本體**：依語言上色，PowerShell 一行多句會展開縮排
4. **`↳ 理由`**：Codex 的 `justification`（若有）

非指令事件也會用同樣的標頭：檔案變更列出路徑與 `+N -M`，MCP 列出 `server.tool` 與參數，Web 搜尋列出查詢數／結果數。

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

1. **掃檔**：列出所有 `rollout-*.jsonl`，依「最後事件時間」由新到舊處理（避免 mtime 過期），累積到 `-Limit` 筆就停。
2. **取指令事件**：只解析含 `exec_command` / `shell_command` 關鍵字的行（先做便宜的字串預篩，省去大量 JSON 解析），還原轉義後取出 `cmd` / `justification` / `sandbox_permissions` / `workdir`。`cmd` 可能是雙引號、單引號或反引號樣板字串（多行），三種都會解析。
3. **語言判斷**：
   - here-string（`@'…'@` / `@"…"@`）先看內容是 Python（`import` / `def` / `print(`）還是 JavaScript（`require(` / `=>` / `const`）。
   - 其他依 PowerShell cmdlet / `$var` / `#`、`git`、或預設 shell 判定。
4. **上色**：單次掃描 tokenizer，**字串/註解優先**匹配，避免關鍵字跑進字串、色碼互相污染。
5. **展開**：僅 PowerShell 會把 `;` `{` `}` 在**字串外**斷行並 4 空格縮排；`for(;;)` 之類用**括號深度**保護不誤斷。
6. **監看**：`-Tail` 以 `FileSystemWatcher`（`ReadDirectoryChangesW`）即時偵測寫入，閒置時不掃描，另有每 `-Interval` 秒的安全檢查（`-PollOnly` 可改固定輪詢）。記錄每個檔的**位元組位移**，只讀新增部分並保留未完成的尾行；新 session 檔自動納入。新事件依時間排序接續在下方，並以「時間下限」略過較舊內容（避免重播）。

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

**清單看起來不是最新（最新事件停在好幾天前）。**

先跑 `-Diag` 看「本機訊號」：若時間比 rollout 新，表示那些會話沒有落地成 `rollout-*.jsonl`（App／雲端會話），本工具不會顯示，輸出末尾也會有黃色提示。若連 本機訊號都沒有，再確認 `-SessionsDir` 是否指到正確的 `.codex\sessions`。

---

## 限制與待辦

- **結果配對以 `call_id` 為準**：`write_stdin` 等續傳尚未彙整成同一筆（見 [`TODO.md`](../TODO.md)）。
- **本機會話不在來源內**：工具只讀 rollout JSONL 與 hooks；非專案對話若沒安裝 hooks，只會被偵測到「存在且較新」，內容不會顯示。
- **語言判斷為啟發式**：`node -e "…"` 這類「PowerShell 跑 JS」會標成 JavaScript，屬合理但非完美。
- **僅涵蓋指令與少數事件**：`exec_command` / `shell_command` / `exec`，加上 `FileChange` / `McpToolCall` / `web.search`；`AgentMessage` 需 `-Messages`，`Reasoning` 在 rollout 裡沒有內容。

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
changelogkit add "一句話標題" --type 修復 --file CodexRunLog.ps1

# 檢索 / 顯示 / 網頁 / 匯出
changelogkit list
changelogkit show 1
changelogkit serve        # 本機網頁 GUI
changelogkit export _site # 唯讀靜態站
```

> 註：在 Windows 上以 `changelogkit` 的 CLI 時若中文顯示亂碼，先設 `$env:PYTHONIOENCODING='utf-8'`。
