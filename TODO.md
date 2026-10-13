# TODO

本檔記錄**尚未正式開始 / 規劃中**的工作。已完成項目請看 [`Docs/ChangeHistory.md`](Docs/ChangeHistory.md)。

現況：目前只有 **Windows + PowerShell 7** 的實作（`Codex運行日誌.ps1`），尚未考慮 Linux／macOS 的對應產物，也還沒有 Web 頁面。

---

## 1. 跨平台（Linux / macOS）

> 目前 `Codex運行日誌.ps1` 綁定 Windows（`%USERPROFILE%`、`.ps1`、PowerShell 7）。Codex 本身與 rollout 格式是跨平台的，只有「讀取端」缺對應實作。

- [ ] 決定跨平台策略（二選一）
  - [ ] **(A) 單一跨平台 CLI**：用 Node/TypeScript 或 Python 改寫核心（讀 rollout、解析、上色、`--tail`），Windows 不再依賴 PowerShell。
  - [ ] **(B) 各自原生**：另寫 `bash`/`zsh` 版本（`codex-runlog.sh`），與 `.ps1` 共用同一份資料格式與輸出規格。
- [ ] sessions 目錄解析支援跨平台
  - [ ] macOS/Linux：`~/.codex/sessions`
  - [ ] 支援 `CODEX_HOME` 環境變數（若 Codex 有採用），優於寫死 `~/.codex`
  - [ ] 保留 ini 設定檔機制（或改為 `~/.config/codex-runlog/config` 之類）
- [ ] 終端機相容性
  - [ ] 確認 ANSI 16 色在 macOS Terminal / Linux TTY 的呈現
  - [ ] 偵測 `NO_COLOR` / 非 TTY（輸出到管線或檔案時自動關色）
  - [ ] 換行與寬字元（CJK）在非 Windows 終端的對齊
- [ ] 輸出行為一致：Windows 版與 Unix 版輸出格式需可比對（最好有共用測試向量）

---

## 2. Web 頁面

> 目標：不想只靠 CLI，能有本機網頁瀏覽／搜尋「Codex 做了什麼」。可參考 changelogkit 的 `serve` 模式（本機唯讀 GUI）。

- [ ] 架構選型
  - [ ] 本機唯讀 HTTP 服務（Node/Bun 或 Python）+ 靜態前端；或直接產生靜態 HTML
  - [ ] 資料來源沿用 rollout JSONL（避免另存一份）
- [ ] 核心功能
  - [ ] 時間軸列表（新→舊），支援無限捲動／分頁
  - [ ] 依專案（session cwd）、日期、語言、類型（PowerShell/Python/…）篩選
  - [ ] 全文搜尋（指令與 justification）
  - [ ] **即時 tail**：SSE 或 WebSocket 推送新指令（對應 CLI 的 `-Tail`）
  - [ ] 單筆展開：完整指令、語法上色、justification、所屬 session 連結
  - [ ] 一鍵複製原始指令
- [ ] 呈現
  - [ ] 沿用 CLI 的上色規則（伺服器端或前端 highlight 擇一）
  - [ ] 長指令收合／展開；安全跳脫（HTML 注入防護）
  - [ ] 深／淺色主題
- [ ] 部署
  - [ ] 預設只綁 `127.0.0.1`，不預設對外
  - [ ] 可選：`export` 成唯讀靜態站（供 GitHub Pages，比照 changelogkit）

---

## 3. 資料完整性（CLI 與 Web 共用）

- [ ] **顯示執行結果**：以 `call_id` 配對 `*_output`，呈現成功／失敗、exit code、耗時（Wall time）。
- [ ] 涵蓋更多工具：`apply_patch`、`write_stdin`、`wait`、`update_plan`、`web_search_call` 等（目前只顯示 `exec_command` / `shell_command` / `exec`）。
- [ ] 彙整同一指令的「呼叫 → 結果」為一筆（含 `session_id` 的 stdin 續傳）。
- [ ] 處理長指令的顯示上限（避免單筆洗版）與明確標示截斷（若有）。
- [ ] 支援 `compaction` / `session_meta` 標記，讓時間軸能標出「新 session / 已壓縮」事件。

---

## 4. 使用者體驗（CLI）

- [ ] 語言判斷目前為啟發式（例：`node -e "…"` 標成 JavaScript）；提供 `--lang` 覆寫或更準確的判斷。
- [ ] 篩選參數：`--project`、`--since`、`--grep`、`--lang`（目前只有 `-Limit`）。
- [ ] `--no-color` / `--plain`（供管線、存檔、CI）。
- [ ] 輸出格式：`--json`（給其他工具吃）、`--md`（貼文件用）。
- [ ] 效能：目前每次執行會掃描多個 rollout 檔；改為建立增量索引（只讀新位元組／快取已解析結果）。
- [ ] `-Tail` 顯示「本次新增 N 筆」的提示與安靜模式。

---

## 5. 工程品質

- [ ] 補足未覆蓋的測試：時間軸事件排序、設定檔讀寫（`Get-IniValue`／`Set-IniValue`）、`Read-AppendedLines` 位移讀取。
- [ ] 封裝／安裝：一鍵安裝到 PATH、版本號、`--version`。
- [ ] 文件：`TODO.md` 與 `Docs/Codex運行日誌.md`、`ChangeHistory.md` 交叉連結維護。

---

## 備註

- 本清單只放「未開始」的事；已完成者見 `Docs/ChangeHistory.md`。
- 跨平台與 Web 是本專案兩條主線，建議先定「跨平台策略」再談 Web（Web 之後可直接沿用核心）。
