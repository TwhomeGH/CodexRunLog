# CodexRunLog

**看清 Codex 到底跑了哪些指令。**

Codex 在對話中常只顯示指令的摘要或截斷片段，長指令（例如內嵌的 Python／Node 腳本）往往看不完整。CodexRunLog 直接讀取 Codex 的 **rollout 記錄**，把每一次 `exec_command` 的**完整指令**、**理由（justification）**與**工作目錄**取出來，依語言上色後輸出，並可持續監看。

> 一句話：**補上 Codex 每次都不把詳細指令內文顯示完整的問題。**

## 特色

- **完整未截斷**：來源是 rollout JSONL（`~/.codex/sessions/...`），不是會被 Codex 截斷的 feedback 預覽。
- **語法上色**：自動判斷 PowerShell / Python / JavaScript / Shell(git) 並上色。
- **可讀版面**：PowerShell 一行多句會自動斷行縮排；附上 Codex 的中文說明。
- **持續監看**：`-Tail` 即時追蹤後續新紀錄。
- **含執行結果**：以 `call_id` 配對輸出，顯示 exit code、耗時與輸出內容（`-NoOutput` 可關）。
- **不只指令**：同一份 rollout 的檔案變更、MCP 呼叫與 Web 搜尋也會顯示（`-NoActivity` 可關）。
- **可選細節**：`-Messages` 顯示 Codex 的文字回覆（commentary／final_answer）；Reasoning 在 rollout 裡沒有內容。
- **Hooks 補漏**：安裝 `hooks/Install-Hook.ps1` 後，沒有 rollout 的會話也能顯示（`~/.codex/runlog/events.jsonl`）。
- **跨機可攜**：sessions 目錄自動解析，找不到時提示輸入並記錄到 `CodexRunlog.ini`。
- **覆蓋率提示**：本機會話索引（`threads`）或非專案對話（`Documents\Codex`）比 rollout 新時，會在清單後提示。

## 需求

- Windows + **PowerShell 7**（`pwsh`）
- Codex 的本機記錄目錄（預設 `%USERPROFILE%\.codex\sessions`）

> Linux／macOS 對應產物與 Web 頁面仍在規劃，見 [TODO.md](TODO.md)。

## 快速開始

```powershell
# 最新 50 筆
.\CodexRunLog.ps1

# 最新 100 筆
.\CodexRunLog.ps1 -Limit 100

# 持續監看後續新紀錄（檔案變更即時顯示，Ctrl+C 結束）
.\CodexRunLog.ps1 -Tail

# 可選：安裝 hook 收集器，補齊沒有 rollout 的會話（需在 Codex 審查並信任）
pwsh -File .\hooks\Install-Hook.ps1
```

輸出範例：

```log
──────────────────────────────────────────────────────────────
2026/10/13 22:23:11  my_monitor_esp32
  [PowerShell]
  Get-Content tools/test-ntfy-ui.cjs
  Get-Content notify.cpp -TotalCount 65
  Get-Content ntfy_test.cpp -TotalCount 65
  ↳ 讀取測試與原始檔內容以核對修改結果。
```

## 參數

| 參數 | 預設 | 說明 |
| --- | --- | --- |
| `-Limit` | `50` | 取最新 N 筆事件（指令／檔案變更／MCP／Web 搜尋）；由舊到新顯示（最新在最下方） |
| `-Tail` | 關 | 印完起始內容後持續監看新紀錄 |
| `-Interval` | `60` | 監看的安全檢查間隔秒數（有變更時即時顯示；此為後援） |
| `-PollOnly` | 關 | 不用檔案變更通知，改固定輪詢 |
| `-SessionsDir` | 自動解析 | rollout JSONL 根目錄 |
| `-OutputLines` | `8` | 每筆結果顯示的行數（頭尾各 N 行；`0` 為全部） |
| `-NoOutput` | 關 | 不顯示執行結果 |
| `-NoActivity` | 關 | 只顯示指令；略過檔案變更、MCP 呼叫與 Web 搜尋 |
| `-Messages` | 關 | 額外顯示 AgentMessage（Codex 的文字回覆） |
| `-Diag` | 關 | 診斷各 rollout 檔的活動時間與指令數 |

> 上表僅為速查。參數與用法的權威來源是程式內的註解說明（單一來源），可直接執行 `Get-Help .\CodexRunLog.ps1 -Full`（另有 `-Examples`、`-Online`）。修改參數時請一併更新註解說明。

## 資料來源

讀取 `sessions/<年>/<月>/<日>/rollout-*.jsonl` 中 **top-level `type=response_item`** 的行：

- **新版**：`payload.type=custom_tool_call`、`payload.name=exec`，指令在 `input` 的 JS 內（`tools.exec_command({cmd:"…",justification:"…"})`）。
- **舊版**：`payload.type=function_call`、`payload.name=exec_command` / `shell_command`，指令在 `arguments`（JSON）。

sessions 目錄解析順序：`-SessionsDir` 參數 → `CodexRunlog.ini` → `%USERPROFILE%\.codex\sessions` → 提示手動輸入。

除了指令，也會讀取 `event_msg` 的 `item_completed`：

- `FileChange`：檔案新增／修改／刪除與 diff 行數。
- `McpToolCall`：MCP server / tool 與參數。
- `Extension` 的 `web.search`：查詢數與結果數。
- `AgentMessage`：用 `-Messages` 開啟；顯示 Codex 的文字回覆（commentary／final_answer）。`Reasoning` 的 `summary_text`／`raw_content` 在 rollout 裡都是空的，因此不提供。

這三類事件與指令共用同一個時間軸（`-Limit` 算的是事件數）；`-NoActivity` 可回到只看指令。

## 文件

- 完整使用說明：[Docs/CodexRunLog.md](Docs/CodexRunLog.md)
- 更新歷史（changelogkit 維護）：[Docs/ChangeHistory.md](Docs/ChangeHistory.md)
- 待辦與規劃：[TODO.md](TODO.md)

## 開發

```powershell
# 分析器 + 單元/整合測試 + 冒煙測試
pwsh -File .\scripts\check.ps1
```

測試為 **Pester 5**（`tests/`，含 rollout fixtures）；CI 於 Windows／Ubuntu／macOS 執行（`.github/workflows/ci.yml`），更新歷史以 changelogkit 匯出至 GitHub Pages（`.github/workflows/pages.yml`）。

## 授權

MIT，詳見 [LICENSE](LICENSE)。
