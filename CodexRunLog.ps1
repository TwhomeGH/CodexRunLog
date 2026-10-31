<#
.SYNOPSIS
    讀取 Codex 的 rollout JSONL（sessions 目錄），抽出每一次 exec_command
    的完整指令與理由，依語言上色後輸出。

.DESCRIPTION
    資料來源：%USERPROFILE%\.codex\sessions\<年>\<月>\<日>\rollout-*.jsonl
    （找不到時依 CodexRunlog.ini，再提示手動輸入並寫回設定檔）
    每行是一個 JSON 物件（top-level type=response_item）。
      - 新版：payload.type=custom_tool_call, payload.name=exec,
              payload.input 內含 tools.exec_command({cmd:"…",justification:"…"})
      - 舊版：payload.type=function_call, payload.name=exec_command / shell_command,
              payload.arguments 為 JSON（cmd / command / workdir / shell）
    cmd 可能以雙引號、單引號或反引號樣板字串（可跨行）包住，皆會解析。
    相較 SQLite 的 feedback_log_body（會被 Codex 截斷），rollout 是完整指令。
    每筆指令會以 call_id 配對其執行結果（custom_tool_call_output / function_call_output）。

    注意：本工具目前僅支援 Windows + PowerShell 7。

.PARAMETER Limit
    取最新的 N 筆指令。輸出由舊到新（最新在最下方）。預設 50。

.PARAMETER Tail
    持續監看：印完起始內容後，輪詢各 rollout 檔新增的行並即時輸出。
    監看模式由舊到新排列（最新在最下方），並略過重播的舊內容。

.PARAMETER Interval
    監看模式的安全檢查間隔秒數（有檔案變更時會即時輸出，此值只是後援）。預設 60。

.PARAMETER PollOnly
    不使用檔案變更通知，改為固定輪詢（適合網路磁碟或不支援 watcher 的環境）。

.PARAMETER SessionsDir
    rollout JSONL 根目錄。省略時依序嘗試：
    設定檔 CodexRunlog.ini → %USERPROFILE%\.codex\sessions。
    若都找不到，會提示手動輸入，並把結果寫回 CodexRunlog.ini。

.PARAMETER OutputLines
    每筆指令結果最多顯示的行數（開頭與結尾各 N 行）。預設 8；設 0 表示全部顯示。

.PARAMETER NoOutput
    不顯示指令的執行結果，只列指令本身。

.PARAMETER Diag
    診斷模式：列出各 rollout 檔的最後事件時間、mtime、大小與指令／結果數量，
    用來確認「資料在哪、為何沒抓到最新指令」，不輸出一般清單。

.EXAMPLE
    顯示最新 50 筆指令。
    PS C:\> .\CodexRunLog.ps1

.EXAMPLE
    顯示最新 100 筆。
    PS C:\> .\CodexRunLog.ps1 -Limit 100

.EXAMPLE
    持續監看，每 3 秒輪詢一次（Ctrl+C 結束）。
    PS C:\> .\CodexRunLog.ps1 -Tail -Interval 3

.EXAMPLE
    指定 rollout 根目錄。
    PS C:\> .\CodexRunLog.ps1 -SessionsDir 'D:\codex\sessions'

.EXAMPLE
    診斷：檢查各 rollout 檔的活動時間與指令數量。
    PS C:\> .\CodexRunLog.ps1 -Diag

.NOTES
    相關文件：Docs/CodexRunLog.md（完整說明）、Docs/ChangeHistory.md（更新歷史）、TODO.md（待辦）。
    參數與用法以 Get-Help .\CodexRunLog.ps1 -Full 為準。

.LINK
    https://github.com/TwhomeGH/CodexRunLog

.LINK
    https://github.com/TwhomeGH/CodexRunLog/blob/main/Docs/CodexRunLog.md
#>
[CmdletBinding()]
param(
    [int]$Limit = 50,
    [switch]$Tail,
    [int]$Interval = 60,
    [string]$SessionsDir = '',
    [int]$OutputLines = 8,
    [switch]$NoOutput,
    [switch]$Diag,
    [switch]$PollOnly
)
#Requires -Version 7.0

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ESC = [char]27
$ConfigPath = Join-Path $PSScriptRoot 'CodexRunlog.ini'

# 顯示選項集中一處（供 Show-Output 使用），也讓參數在頂層被明確引用
$script:Options = [pscustomobject]@{
    OutputLines = [int]$OutputLines
    ShowOutput  = -not $NoOutput
}

function Color {
    param([string]$Code, [string]$Text)
    "$ESC[${Code}m${Text}$ESC[0m"
}

# ── 設定檔（簡易 INI）────────────────────────────────────────────────
function Get-IniValue {
    param([string]$Section, [string]$Key)
    if (-not (Test-Path -LiteralPath $ConfigPath)) { return '' }
    $cur = ''
    foreach ($line in [System.IO.File]::ReadAllLines($ConfigPath)) {
        $t = $line.Trim()
        if ($t -eq '' -or $t.StartsWith(';') -or $t.StartsWith('#')) { continue }
        if ($t -match '^\[(.+)\]$') { $cur = $Matches[1].Trim(); continue }
        if ($cur -eq $Section -and $t -match "^$([regex]::Escape($Key))\s*=\s*(.*)$") {
            return $Matches[1].Trim()
        }
    }
    return ''
}

function Set-IniValue {
    [CmdletBinding(SupportsShouldProcess)]
    param([string]$Section, [string]$Key, [string]$Value)
    $lines = @()
    if (Test-Path -LiteralPath $ConfigPath) { $lines = @([System.IO.File]::ReadAllLines($ConfigPath)) }

    $out = [System.Collections.Generic.List[string]]::new()
    $cur = ''
    $done = $false
    $sectionSeen = $false
    foreach ($line in $lines) {
        $t = $line.Trim()
        if ($t -match '^\[(.+)\]$') {
            if ($cur -eq $Section -and -not $done) { $out.Add("$Key = $Value"); $done = $true }
            $cur = $Matches[1].Trim()
            if ($cur -eq $Section) { $sectionSeen = $true }
            $out.Add($line)
            continue
        }
        if ($cur -eq $Section -and -not $done -and $t -match "^$([regex]::Escape($Key))\s*=") {
            $out.Add("$Key = $Value"); $done = $true
            continue
        }
        $out.Add($line)
    }
    if (-not $done) {
        if (-not $sectionSeen) {
            if ($out.Count -gt 0) { $out.Add('') }
            $out.Add("[$Section]")
        }
        $out.Add("$Key = $Value")
    }
    if ($PSCmdlet.ShouldProcess($ConfigPath, "寫入 [$Section] $Key")) {
        [System.IO.File]::WriteAllText($ConfigPath, (($out -join "`r`n") + "`r`n"), [System.Text.UTF8Encoding]::new($false))
    }
}

# ── 解除轉義（JS / JSON 字串）──────────────────────────────────────────
function ConvertFrom-EscapedString {
    param([string]$Text)
    $sb = [System.Text.StringBuilder]::new($Text.Length)
    $i = 0
    while ($i -lt $Text.Length) {
        $ch = $Text[$i]
        if ($ch -eq '\' -and ($i + 1) -lt $Text.Length) {
            $nx = $Text[$i + 1]
            switch ($nx) {
                'n' { [void]$sb.Append("`n") }
                'r' { [void]$sb.Append("`r") }
                't' { [void]$sb.Append("`t") }
                'b' { [void]$sb.Append("`b") }
                'f' { [void]$sb.Append("`f") }
                'u' {
                    if (($i + 5) -lt $Text.Length) {
                        try { [void]$sb.Append([char][Convert]::ToInt32($Text.Substring($i + 2, 4), 16)) }
                        catch { [void]$sb.Append($nx) }
                        $i += 6
                        continue
                    }
                    [void]$sb.Append($nx)
                }
                default { [void]$sb.Append($nx) }
            }
            $i += 2
        } else {
            [void]$sb.Append($ch)
            $i++
        }
    }
    return $sb.ToString()
}

# 從 JS 物件 body 取一個字串欄位（cmd / justification / sandbox_permissions / workdir / shell）
# Codex 依內容選用雙引號、單引號或反引號樣板字串，三種都要支援。
function Get-JsField {
    param([string]$Body, [string]$Key)
    $k = [regex]::Escape($Key)
    $bt = [char]96
    $patterns = @(
        ($k + ':\s*"((?:\\.|[^"\\])*)"'),
        ($k + ":\s*'((?:\\.|[^'\\])*)'"),
        ($k + ':\s*' + $bt + '((?:\\.|[^' + $bt + '\\])*)' + $bt)
    )
    foreach ($p in $patterns) {
        $m = [regex]::Match($Body, $p)
        if ($m.Success) { return (ConvertFrom-EscapedString $m.Groups[1].Value) }
    }
    return ''
}

# 新版 exec 的 input：抽出所有 tools.exec_command({...})
function Get-ExecFromJs {
    param([string]$Js)
    $out = [System.Collections.Generic.List[object]]::new()
    $needle = 'exec_command('
    $idx = 0
    while (($idx = $Js.IndexOf($needle, $idx)) -ge 0) {
        $b = $Js.IndexOf('{', $idx + $needle.Length - 1)
        if ($b -lt 0) { break }

        # 由 { 起掃到配對的 }；字串（雙引號、單引號、反引號樣板）內的括號不算
        $bt = [char]96
        $depth = 0; $i = $b; $inStr = $false; $quote = ''; $esc = $false; $end = -1
        while ($i -lt $Js.Length) {
            $ch = $Js[$i]
            if ($inStr) {
                if ($esc) { $esc = $false }
                elseif ($ch -eq '\') { $esc = $true }
                elseif ($ch -eq $quote) { $inStr = $false }
            } else {
                if ($ch -eq '"' -or $ch -eq "'" -or $ch -eq $bt) { $inStr = $true; $quote = $ch }
                elseif ($ch -eq '{') { $depth++ }
                elseif ($ch -eq '}') { $depth--; if ($depth -eq 0) { $end = $i; break } }
            }
            $i++
        }
        if ($end -gt $b) {
            $body = $Js.Substring($b + 1, $end - $b - 1)
            $cmd = Get-JsField $body 'cmd'
            if ($cmd) {
                $out.Add([pscustomobject]@{
                    Cmd           = $cmd
                    Justification = Get-JsField $body 'justification'
                    Sandbox       = Get-JsField $body 'sandbox_permissions'
                    Workdir       = Get-JsField $body 'workdir'
                })
            }
        }
        $idx = $b + 1
    }
    return $out
}

# ── 從一行 rollout JSON 取出指令事件 ─────────────────────────────────
function Get-CommandEventsFromLine {
    param([string]$Line, [string]$Source, [string]$DefaultWorkdir = '')
    $out = [System.Collections.Generic.List[object]]::new()

    $o = $null
    try { $o = $Line | ConvertFrom-Json } catch { return $out }
    if ($o.type -ne 'response_item') { return $out }
    $p = $o.payload
    if ($null -eq $p) { return $out }

    # rollout 的 timestamp 是 UTC（帶 Z），ConvertFrom-Json 會轉成 Kind=Utc 的 DateTime；
    # 直接用 DateTimeOffset 承接才不會丟掉時區而少算本地時差。
    $time = $null
    if ($o.timestamp) {
        try {
            $dt = [datetime]$o.timestamp
            $time = ([DateTimeOffset]$dt).ToLocalTime()
        } catch { Write-Verbose "無法解析 timestamp：$($_.Exception.Message)" }
    }
    if ($null -eq $time) {
        $ct = $p.internal_chat_message_metadata_passthrough.create_time
        if ($ct) { $time = [DateTimeOffset]::FromUnixTimeSeconds([long]$ct).ToLocalTime() }
    }

    switch ($p.type) {
        'custom_tool_call' {
            if ($p.name -ne 'exec') { break }
            foreach ($e in (Get-ExecFromJs $p.input)) {
                if (-not $e.Workdir) { $e.Workdir = $DefaultWorkdir }
                $e | Add-Member -NotePropertyName Time   -NotePropertyValue $time       -Force
                $e | Add-Member -NotePropertyName Source -NotePropertyValue $Source     -Force
                $e | Add-Member -NotePropertyName CallId -NotePropertyValue $p.call_id  -Force
                $out.Add($e)
            }
        }
        'function_call' {
            if ($p.name -ne 'exec_command' -and $p.name -ne 'shell_command') { break }
            $a = $null
            try { $a = $p.arguments | ConvertFrom-Json } catch { Write-Verbose "無法解析 function_call arguments：$($_.Exception.Message)" }
            if ($null -eq $a) { break }
            $cmd = if ($p.name -eq 'shell_command') { $a.command } else { $a.cmd }
            $wd  = if ($a.workdir) { $a.workdir } else { $DefaultWorkdir }
            if ($cmd) {
                $out.Add([pscustomobject]@{
                    Time          = $time
                    Cmd           = $cmd
                    Justification = $a.justification
                    Sandbox       = $a.sandbox_permissions
                    Workdir       = $wd
                    Source        = $Source
                    CallId        = $p.call_id
                })
            }
        }
    }
    return $out
}

# ── 語言判斷 ─────────────────────────────────────────────────────────
function Get-CodeLanguage {
    param([string]$Cmd)
    $t = $Cmd
    # 內嵌 here-string（@'…'@ / @"…"@）依內容再細分：Python 或 JavaScript
    if ($t -match "@['`"][\s\S]*?\b(?:import|def|print)\b" -or
        $t -match "(?m)^\s*(?:import\s|from\s+\S+\s+import\s|def\s+\w+\(|class\s+\w+|print\()") { return 'python' }
    if ($t -match "@['`"][\s\S]*?(?:require\(|module\.exports|=>|\bconst\s|\blet\s|function\s*\()" -or
        $t -match "(?m)^\s*(?:const\s|let\s|var\s|function\s|import\s+\{|export\s)") { return 'javascript' }
    if ($t -match '(?m)^\s*git\b') { return 'shell' }
    if ($t -match '\b[A-Z][a-zA-Z]+-[A-Z][A-Za-z]*\b' -or
        $t -match '\$[A-Za-z_{]' -or
        $t -match '(?m)^\s*#') { return 'powershell' }
    return 'shell'
}

# ── 語法上色（一次掃描，字串優先，避免關鍵字誤入字串/色碼互相污染）────
$PAT_PS = @'
(?<comment>#[^\r\n]*)|(?<string>'(?:''|[^'])*'|"(?:`[\s\S]|[^"`])*")|(?<kw>\b(?:if|elseif|else|foreach|for|while|until|do|switch|function|filter|return|param|begin|process|end|try|catch|finally|throw|break|continue|in|not|and|or|is)\b)|(?<git>\bgit\b)|(?<cmdlet>\b[A-Z][a-zA-Z]*-[A-Z][A-Za-z]*\b)|(?<var>\$[\w:{}]+)|(?<param>(?<![\w-])--?[A-Za-z][\w-]*)|(?<num>\b\d+(?:\.\d+)?\b)
'@

$PAT_PY = @'
(?<comment>#[^\r\n]*)|(?<string>"""(?:\\.|[\s\S])*?"""|'''(?:\\.|[\s\S])*?'''|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?<kw>\b(?:import|from|def|class|return|for|while|if|elif|else|try|except|finally|with|as|in|is|not|and|or|lambda|yield|pass|break|continue|raise|global|nonlocal|assert|del|async|await|True|False|None)\b)|(?<bi>\b(?:print|len|range|str|int|float|bool|list|dict|set|tuple|open|enumerate|zip|sorted|next|iter|sum|min|max|abs|any|all|isinstance)\b)|(?<num>\b\d+(?:\.\d+)?\b)
'@

$PAT_SH = @'
(?<comment>#[^\r\n]*)|(?<string>'(?:[^']*)'|"(?:\\.|[^"\\])*")|(?<git>\bgit\b)|(?<sub>\b(?:status|diff|add|commit|log|checkout|branch|merge|rebase|push|pull|fetch|clone|stash|restore|reset|show|tag|remote|config|init|rm|mv|clean|switch|cherry-pick|rev-parse|apply|blame|ls-files|grep)\b)|(?<param>(?<![\w-])--?[A-Za-z][\w-]*)|(?<num>\b\d+(?:\.\d+)?\b)
'@

$PAT_JS = @'
(?<comment>//[^\r\n]*|/\*[\s\S]*?\*/)|(?<string>`(?:\\.|[^`\\])*`|"(?:\\.|[^"\\])*"|'(?:\\.|[^'\\])*')|(?<kw>\b(?:const|let|var|function|return|if|else|for|while|do|switch|case|default|break|continue|new|class|extends|import|export|from|async|await|yield|throw|try|catch|finally|typeof|instanceof|in|of|delete|void|this|super|null|undefined|true|false)\b)|(?<bi>\b(?:require|module|exports|process|console|Promise|JSON|Object|Array|String|Number|Boolean|Math|Date|Error|RegExp|Map|Set|structuredClone|assert)\b)|(?<num>\b\d+(?:\.\d+)?\b)
'@

$HIGHLIGHT = {
    param($m)
    if ($m.Groups['comment'].Success) { return "$ESC[90m$($m.Value)$ESC[0m" }
    if ($m.Groups['string'].Success)  { return "$ESC[32m$($m.Value)$ESC[0m" }
    if ($m.Groups['kw'].Success)      { return "$ESC[35m$($m.Value)$ESC[0m" }
    if ($m.Groups['git'].Success)     { return "$ESC[36m$($m.Value)$ESC[0m" }
    if ($m.Groups['sub'].Success)     { return "$ESC[36m$($m.Value)$ESC[0m" }
    if ($m.Groups['cmdlet'].Success)  { return "$ESC[33m$($m.Value)$ESC[0m" }
    if ($m.Groups['bi'].Success)      { return "$ESC[33m$($m.Value)$ESC[0m" }
    if ($m.Groups['var'].Success)     { return "$ESC[96m$($m.Value)$ESC[0m" }
    if ($m.Groups['param'].Success)   { return "$ESC[94m$($m.Value)$ESC[0m" }
    if ($m.Groups['num'].Success)     { return "$ESC[95m$($m.Value)$ESC[0m" }
    return $m.Value
}

function Format-Line {
    param([string]$Line, [string]$Lang)
    $pat = switch ($Lang) {
        'python'     { $PAT_PY }
        'javascript' { $PAT_JS }
        'powershell' { $PAT_PS }
        default      { $PAT_SH }
    }
    return [regex]::Replace($Line, $pat, $HIGHLIGHT)
}

# ── 把 PowerShell 一行多句展開成縮排後的多行（字串/括號內不處理）──────
function Expand-PowerShellStatements {
    param([string]$Code)
    $out    = [System.Collections.Generic.List[string]]::new()
    $indent = 0
    $depth  = 0
    $inS    = $false
    $inD    = $false
    $cur    = [System.Text.StringBuilder]::new()

    $flush = {
        $text = $cur.ToString().Trim()
        if ($text.Length -gt 0) { $out.Add(('    ' * $indent) + $text) }
        [void]$cur.Clear()
    }

    foreach ($raw in ($Code -split "`r?`n")) {
        $line = $raw
        $i = 0
        while ($i -lt $line.Length) {
            $c = $line[$i]
            if ($inS) {
                [void]$cur.Append($c)
                if ($c -eq "'") {
                    if (($i + 1) -lt $line.Length -and $line[$i + 1] -eq "'") { [void]$cur.Append("'"); $i++ }
                    else { $inS = $false }
                }
                $i++; continue
            }
            if ($inD) {
                [void]$cur.Append($c)
                if ($c -eq '`' -and ($i + 1) -lt $line.Length) { [void]$cur.Append($line[$i + 1]); $i += 2; continue }
                if ($c -eq '"') { $inD = $false }
                $i++; continue
            }
            if ($c -eq '#' -and $depth -eq 0) {
                [void]$cur.Append($line.Substring($i)); $i = $line.Length; break
            }
            switch ($c) {
                "'" { $inS = $true;  [void]$cur.Append($c) }
                '"' { $inD = $true;  [void]$cur.Append($c) }
                '(' { $depth++; [void]$cur.Append($c) }
                ')' { if ($depth -gt 0) { $depth-- }; [void]$cur.Append($c) }
                ';' { if ($depth -eq 0) { & $flush } else { [void]$cur.Append($c) } }
                '{' { [void]$cur.Append($c); & $flush; $indent++ }
                '}' {
                    & $flush
                    if ($indent -gt 0) { $indent-- }
                    [void]$cur.Append('}')
                    & $flush
                }
                default { [void]$cur.Append($c) }
            }
            $i++
        }
        & $flush
    }
    return ($out -join "`n")
}

# ── 掃描 rollout 檔，取得最近 N 筆指令 ───────────────────────────────
function Get-RolloutFiles {
    param([string]$Root = $SessionsDir)
    return Get-ChildItem -LiteralPath $Root -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

# 依「檔案最後事件時間」排序（活動中檔案 mtime 可能過期，不能只信 mtime）
function Get-RolloutFilesByActivity {
    param([string]$Root = $SessionsDir)
    $items = foreach ($f in (Get-RolloutFiles -Root $Root)) {
        $t = Get-FileLastEventTime $f.FullName
        $key = if ($null -ne $t) { $t } else { [DateTimeOffset]$f.LastWriteTime }
        [pscustomobject]@{ File = $f; Key = $key }
    }
    return @($items | Sort-Object Key -Descending | ForEach-Object { $_.File })
}

function Test-HasCommand {
    param([string]$Line)
    return ($Line.IndexOf('exec_command') -ge 0) -or ($Line.IndexOf('shell_command') -ge 0)
}

function Test-HasOutput {
    param([string]$Line)
    return ($Line.IndexOf('call_id') -ge 0) -and
           (($Line.IndexOf('custom_tool_call_output') -ge 0) -or ($Line.IndexOf('function_call_output') -ge 0))
}

function Test-HasRelevant {
    param([string]$Line)
    return (Test-HasCommand $Line) -or ($Line.IndexOf('FileChange') -ge 0)
}

# 讀檔尾一小段取最後一個 timestamp；活動中的檔案 mtime 可能不會即時更新
function Get-FileLastEventTime {
    param([string]$Path)
    $fs = $null; $buf = $null; $read = 0
    try {
        $fs = Open-SharedRead $Path
        $len = $fs.Length
        if ($len -le 0) { return $null }
        $start = [Math]::Max(0L, $len - 65536)
        $fs.Seek($start, [System.IO.SeekOrigin]::Begin) | Out-Null
        $buf = New-Object byte[] ([int]($len - $start))
        while ($read -lt $buf.Length) {
            $n = $fs.Read($buf, $read, $buf.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
    } catch { return $null } finally { if ($fs) { $fs.Dispose() } }
    $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    $lines = $text -split "`n"
    for ($i = $lines.Count - 1; $i -ge 0; $i--) {
        $m = [regex]::Match($lines[$i], '"timestamp"\s*:\s*"([^"]+)"')
        if ($m.Success) {
            try { return [DateTimeOffset]::Parse($m.Groups[1].Value).ToLocalTime() } catch { return $null }
        }
    }
    return $null
}

# 把 output 欄位（字串或內容區塊陣列）攤平成純文字
function Get-OutputText {
    param($Output)
    if ($null -eq $Output) { return $null }
    if ($Output -is [string]) { return $Output }
    $parts = [System.Collections.Generic.List[string]]::new()
    if ($Output -is [System.Collections.IEnumerable]) {
        foreach ($item in $Output) {
            if ($null -eq $item) { continue }
            if ($item -is [string]) { [void]$parts.Add($item) }
            elseif ($item.PSObject.Properties['text']) { [void]$parts.Add([string]$item.text) }
            else { [void]$parts.Add(($item | ConvertTo-Json -Depth 5 -Compress)) }
        }
    } elseif ($Output.PSObject.Properties['text']) {
        [void]$parts.Add([string]$Output.text)
    } else {
        [void]$parts.Add(($Output | ConvertTo-Json -Depth 5 -Compress))
    }
    return ($parts -join "`n")
}

# 從 exec 的輸出 JSON 取出 exit code／耗時與真正的 output 文字
function Format-ExecOutput {
    param($Output)
    $raw = Get-OutputText $Output
    $result = [pscustomobject]@{ Text = $raw; ExitCode = $null; WallTime = $null }
    if (-not $raw) { return $result }
    $me = [regex]::Match($raw, '"exit_code"\s*:\s*(-?\d+)')
    if ($me.Success) { $result.ExitCode = [int]$me.Groups[1].Value }
    $mw = [regex]::Match($raw, '"wall_time_seconds"\s*:\s*([0-9.]+)')
    if ($mw.Success) { $result.WallTime = [double]$mw.Groups[1].Value }
    $mo = [regex]::Match($raw, '"output"\s*:\s*"((?:\\.|[^"\\])*)"')
    if ($mo.Success) { $result.Text = ConvertFrom-EscapedString $mo.Groups[1].Value }
    return $result
}

function Get-ToolOutputsFromLine {
    param([string]$Line)
    $o = $null
    try { $o = $Line | ConvertFrom-Json } catch { return $null }
    if ($o.type -ne 'response_item') { return $null }
    $p = $o.payload
    if ($null -eq $p -or -not $p.call_id) { return $null }
    if ($p.type -ne 'custom_tool_call_output' -and $p.type -ne 'function_call_output') { return $null }
    $fmt = Format-ExecOutput $p.output
    $time = $null
    if ($o.timestamp) { try { $time = ([DateTimeOffset]([datetime]$o.timestamp)).ToLocalTime() } catch { Write-Verbose 'timestamp 解析失敗' } }
    return [pscustomobject]@{
        CallId   = $p.call_id
        Time     = $time
        Output   = $fmt.Text
        ExitCode = $fmt.ExitCode
        WallTime = $fmt.WallTime
    }
}

# 依 call_id 把輸出掛回對應的指令事件
function Join-EventsWithOutputs {
    param($Calls, $Outputs)
    if ($null -eq $Outputs -or $Outputs.Count -eq 0) { return $Calls }
    foreach ($c in $Calls) {
        if ($c.CallId -and $Outputs.ContainsKey($c.CallId)) {
            $o = $Outputs[$c.CallId]
            $c | Add-Member -NotePropertyName Output   -NotePropertyValue $o.Output   -Force
            $c | Add-Member -NotePropertyName ExitCode -NotePropertyValue $o.ExitCode -Force
            $c | Add-Member -NotePropertyName WallTime -NotePropertyValue $o.WallTime -Force
        }
    }
    return $Calls
}

$script:WorkdirCache = @{}

# 以共用模式開檔（ReadWrite/Delete），避免與 Codex 正在寫入的 rollout 檔互鎖
function Open-SharedRead {
    param([string]$Path)
    $share = [System.IO.FileShare]::ReadWrite -bor [System.IO.FileShare]::Delete
    return [System.IO.FileStream]::new($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, $share)
}

function Read-SharedFirstLine {
    param([string]$Path)
    $fs = $null; $sr = $null
    try {
        $fs = Open-SharedRead $Path
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
        return $sr.ReadLine()
    } finally {
        if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() }
    }
}

function Read-SharedLines {
    param([string]$Path)
    $fs = $null; $sr = $null
    $lines = [System.Collections.Generic.List[string]]::new()
    try {
        $fs = Open-SharedRead $Path
        $sr = [System.IO.StreamReader]::new($fs, [System.Text.Encoding]::UTF8)
        while ($null -ne ($l = $sr.ReadLine())) { $lines.Add($l) }
    } finally {
        if ($sr) { $sr.Dispose() } elseif ($fs) { $fs.Dispose() }
    }
    return $lines
}

# 讀 rollout 第一行的 session_meta，取該 session 的 cwd 當作預設工作目錄
function Get-SessionCwd {
    param([string]$Path)
    if ($script:WorkdirCache.ContainsKey($Path)) { return $script:WorkdirCache[$Path] }
    $cwd = ''
    try {
        $head = Read-SharedFirstLine $Path
        if ($head) {
            $h = $head | ConvertFrom-Json
            if ($h.payload.cwd) { $cwd = $h.payload.cwd }
        }
    } catch { Write-Verbose "無法取得 session cwd（$Path）：$($_.Exception.Message)" }
    $script:WorkdirCache[$Path] = $cwd
    return $cwd
}

# 讀檔重試：Codex 寫入中可能短暫鎖檔，重試幾次再放棄
function Read-SharedLinesWithRetry {
    param([string]$Path, [int]$Attempts = 4)
    for ($i = 0; $i -lt $Attempts; $i++) {
        try {
            $lines = @(Read-SharedLines $Path)
            return ,$lines
        } catch {
            Write-Verbose "讀取失敗（第 $($i + 1)/$Attempts 次）：$Path：$($_.Exception.Message)"
            if ($i -lt $Attempts - 1) { Start-Sleep -Milliseconds 150 }
        }
    }
    return $null
}

function Get-RecentEvents {
    param([int]$Need, [string]$Root = $SessionsDir)
    $calls = [System.Collections.Generic.List[object]]::new()
    $outputs = @{}
    foreach ($f in (Get-RolloutFilesByActivity -Root $Root)) {
        $cwd = Get-SessionCwd $f.FullName
        $lines = Read-SharedLinesWithRetry $f.FullName
        if ($null -eq $lines) {
            # 不再靜默跳過：讓使用者知道有一整個檔讀不到
            Write-Host (Color '93' "⚠ 無法讀取，已跳過：$($f.Name)（可能被 Codex 鎖住，稍後重試）")
            continue
        }
        # 逐行容錯：單行壞掉不影響整個檔
        foreach ($line in $lines) {
            try {
                if (Test-HasCommand $line) {
                    foreach ($ev in (Get-CommandEventsFromLine $line $f.FullName $cwd)) { $calls.Add($ev) }
                } elseif (Test-HasOutput $line) {
                    $rec = Get-ToolOutputsFromLine $line
                    if ($rec) { $outputs[$rec.CallId] = $rec }
                }
            } catch { Write-Verbose "略過一行（解析失敗）：$($_.Exception.Message)" }
        }
        if ($calls.Count -ge $Need) { break }
    }
    [void](Join-EventsWithOutputs $calls $outputs)
    return @($calls | Sort-Object Time -Descending | Select-Object -First $Need)
}

# ── 輸出 ─────────────────────────────────────────────────────────────
function Show-Output {
    param($e)
    if (-not $script:Options.ShowOutput) { return }
    if (-not $e.Output) { return }
    $MaxLines = $script:Options.OutputLines

    $meta = @()
    if ($null -ne $e.ExitCode) { $meta += "exit=$($e.ExitCode)" }
    if ($null -ne $e.WallTime) { $meta += ('{0:N1}s' -f [double]$e.WallTime) }
    $label = '結果'
    if ($meta.Count -gt 0) { $label += '（' + ($meta -join ' · ') + '）' }
    Write-Host ('  ' + (Color '90' '↳ ') + (Color '36' $label))

    $arr = @($e.Output -split "`r?`n")
    while ($arr.Count -gt 0 -and $arr[-1] -eq '') {
        if ($arr.Count -eq 1) { $arr = @(); break }
        $arr = @($arr[0..($arr.Count - 2)])
    }
    $total = $arr.Count
    if ($MaxLines -le 0 -or $total -le 2 * $MaxLines) {
        foreach ($line in $arr) { Write-Host ('  ' + (Color '90' $line)) }
    } else {
        foreach ($line in $arr[0..($MaxLines - 1)]) { Write-Host ('  ' + (Color '90' $line)) }
        Write-Host ('  ' + (Color '90' "…（省略 $($total - 2 * $MaxLines) 行）"))
        foreach ($line in $arr[($total - $MaxLines)..($total - 1)]) { Write-Host ('  ' + (Color '90' $line)) }
    }
}

function Show-Event {
    param($e)
    $lang  = Get-CodeLanguage $e.Cmd
    $label = switch ($lang) {
        'python'     { 'Python' }
        'javascript' { 'JavaScript' }
        'powershell' { 'PowerShell' }
        'shell'      { 'Shell' }
        default      { 'Code' }
    }
    $ts = if ($e.Time) { $e.Time.ToString('yyyy/MM/dd HH:mm:ss') } else { '----/--/-- --:--:--' }
    $place = ''
    if ($e.Workdir) { $place = Split-Path $e.Workdir -Leaf }

    Write-Host (Color '90' ('─' * 78))
    Write-Host ((Color '97' $ts) + '  ' + (Color '90' $place))

    $meta = "[$label]"
    if ($e.Sandbox) { $meta += "  sandbox=$($e.Sandbox)" }
    Write-Host ('  ' + (Color '36' $meta))

    $code = if ($lang -eq 'powershell') { Expand-PowerShellStatements $e.Cmd } else { $e.Cmd }
    foreach ($line in ($code -split "`r?`n")) {
        Write-Host ('  ' + (Format-Line $line $lang))
    }
    if ($e.Justification) {
        Write-Host ('  ' + (Color '90' '↳ ') + (Color '93' $e.Justification))
    }
    if ($e.Output) { Show-Output $e }
    Write-Host ''
}

# ── 讀取檔案自 Offset 之後新增的行（保留未完成尾行）────────────────────
function Read-AppendedLines {
    param([string]$Path, [long]$Offset, [string]$Carry)
    $fs = $null
    $read = 0
    try {
        $fs = Open-SharedRead $Path
        $fs.Seek($Offset, [System.IO.SeekOrigin]::Begin) | Out-Null
        $remaining = $fs.Length - $Offset
        if ($remaining -le 0) { return [pscustomobject]@{ Lines = @(); Carry = $Carry; Offset = $Offset } }
        $buf = New-Object byte[] ([int]$remaining)
        while ($read -lt $buf.Length) {
            $n = $fs.Read($buf, $read, $buf.Length - $read)
            if ($n -le 0) { break }
            $read += $n
        }
        $text = $Carry + [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
    } finally {
        if ($fs) { $fs.Dispose() }
    }

    $parts  = $text -split "`n"
    $carryOut = $parts[-1]
    $lines = @()
    if ($parts.Count -gt 1) {
        $lines = $parts[0..($parts.Count - 2)] | ForEach-Object { $_.TrimEnd("`r") }
    }
    return [pscustomobject]@{ Lines = $lines; Carry = $carryOut; Offset = ($Offset + $read) }
}

# ── 主流程 ───────────────────────────────────────────────────────────
# 解析 sessions 目錄：明確參數 > 設定檔 > %USERPROFILE%\.codex\sessions > 手動輸入
function Resolve-SessionsDir {
    param([string]$Explicit)
    if ($Explicit) {
        if (-not (Test-Path -LiteralPath $Explicit)) { throw "指定的 sessions 目錄不存在：$Explicit" }
        return $Explicit
    }

    $cfg = Get-IniValue 'paths' 'sessions'
    if ($cfg -and (Test-Path -LiteralPath $cfg)) { return $cfg }

    $profileRoot = if ($env:USERPROFILE) { $env:USERPROFILE } else { $HOME }
    $def = Join-Path $profileRoot '.codex/sessions'
    if (Test-Path -LiteralPath $def) { return $def }

    Write-Host (Color '93' "找不到 Codex sessions 目錄（預設：$def）。")
    Write-Host (Color '90' "請輸入 rollout JSONL 所在目錄，輸入後會記錄到 $ConfigPath")
    while ($true) {
        $ans = Read-Host 'sessions 目錄'
        if (-not $ans) { continue }
        $ans = $ans.Trim().Trim('"').Trim("'")
        if (Test-Path -LiteralPath $ans) {
            Set-IniValue 'paths' 'sessions' $ans
            Write-Host (Color '90' "已記錄到 $ConfigPath")
            return $ans
        }
        Write-Host (Color '91' "路徑不存在，請重新輸入。")
    }
}

# 回傳事件集合中最大的時間，作為監看模式的「時間下限」。
function Get-MaxEventTime {
    param($Events, [DateTimeOffset]$Start = [DateTimeOffset]::MinValue)
    $max = $Start
    foreach ($e in $Events) {
        if ($e.Time -and $e.Time -gt $max) { $max = $e.Time }
    }
    return $max
}

# 只保留比 Floor 新（或時間未知）的事件，避免新的 rollout 檔重播舊內容。
function Select-NewEvents {
    param($Events, [DateTimeOffset]$Floor)
    foreach ($e in $Events) {
        if ($null -eq $e.Time -or $e.Time -gt $Floor) { $e }
    }
}

# 掃描一次：讀取各檔自 offset 之後的新行，回傳新事件（已依 call_id 配對輸出）
function Read-TailBatch {
    param([hashtable]$Offsets, [hashtable]$Carries, [string]$Root = $SessionsDir)
    $calls = [System.Collections.Generic.List[object]]::new()
    $outs = @{}
    foreach ($f in (Get-RolloutFiles -Root $Root)) {
        $path = $f.FullName
        if (-not $Offsets.ContainsKey($path)) { $Offsets[$path] = 0L; $Carries[$path] = '' }
        if ([long]$f.Length -lt $Offsets[$path]) { $Offsets[$path] = 0L; $Carries[$path] = '' }
        if ([long]$f.Length -le $Offsets[$path]) { continue }

        $r = try { Read-AppendedLines $path $Offsets[$path] $Carries[$path] } catch { $null }
        if ($null -eq $r) { continue }
        $Offsets[$path] = $r.Offset
        $Carries[$path] = $r.Carry

        $cwd = Get-SessionCwd $path
        foreach ($line in $r.Lines) {
            try {
                if (Test-HasCommand $line) {
                    foreach ($ev in (Get-CommandEventsFromLine $line $path $cwd)) { $calls.Add($ev) }
                } elseif (Test-HasOutput $line) {
                    $rec = Get-ToolOutputsFromLine $line
                    if ($rec) { $outs[$rec.CallId] = $rec }
                }
            } catch { Write-Verbose "略過一行（解析失敗）：$($_.Exception.Message)" }
        }
    }
    [void](Join-EventsWithOutputs $calls $outs)
    return [pscustomobject]@{ Calls = $calls; Outputs = $outs }
}

# 建立檔案變更監看器（FileSystemWatcher 即 ReadDirectoryChangesW）；失敗回傳 $null
function Get-SessionWatcher {
    param([string]$Root)
    try {
        $w = [System.IO.FileSystemWatcher]::new($Root, '*.jsonl')
        $w.IncludeSubdirectories = $true
        $w.NotifyFilter = [System.IO.NotifyFilters]::LastWrite -bor [System.IO.NotifyFilters]::Size -bor
                          [System.IO.NotifyFilters]::CreationTime -bor [System.IO.NotifyFilters]::FileName
        $w.InternalBufferSize = 65536
        return $w
    } catch {
        Write-Verbose "無法建立 FileSystemWatcher：$($_.Exception.Message)"
        return $null
    }
}

# 被 dot-source 時（例如單元測試載入函式）不執行主流程
# 診斷：列出各 rollout 檔的活動時間與指令／結果數量
function Show-Diagnostics {
    param([string]$Root)
    Write-Host (Color '97' "sessions 根目錄：$Root")
    $files = Get-RolloutFilesByActivity -Root $Root
    Write-Host (Color '90' "共 $($files.Count) 個 rollout 檔，依「最後事件時間」排序（前 12 個）：")
    $i = 0
    foreach ($f in ($files | Select-Object -First 12)) {
        $i++
        $last = Get-FileLastEventTime $f.FullName
        $lastText = if ($last) { $last.ToString('yyyy-MM-dd HH:mm:ss') } else { '(無 timestamp)' }
        if ($f.Length -le 20MB) {
            $calls = 0; $outs = 0
            try {
                foreach ($line in (Read-SharedLines $f.FullName)) {
                    if ($line -match '"type"\s*:\s*"(custom_tool_call|function_call)"') { $calls++ }
                    elseif ($line -match '"type"\s*:\s*"(custom_tool_call_output|function_call_output)"') { $outs++ }
                }
            } catch { Write-Verbose "診斷讀取失敗：$($_.Exception.Message)" }
            $stat = "calls=$calls outputs=$outs"
            if ($calls -eq 0) { $stat += '  ← 無指令（可能是審查執行緒）' }
        } else {
            $stat = '（檔案過大，略過統計）'
        }
        Write-Host ("  {0,2}. {1}  mtime={2}  size={3,8}  last={4}  {5}" -f $i, $f.Name, $f.LastWriteTime.ToString('MM-dd HH:mm'), $f.Length, $lastText, $stat)
    }
}

if ($MyInvocation.InvocationName -eq '.') { return }

$SessionsDir = Resolve-SessionsDir $SessionsDir

if ($Diag) {
    Show-Diagnostics $SessionsDir
    return
}

$events = @(Get-RecentEvents $Limit)

if (-not $Tail) {
    # 由舊到新輸出：最新永遠在最下方，與 -Tail 一致
    foreach ($e in ($events | Sort-Object Time)) { Show-Event $e }
    return
}

# 監看模式：由舊到新排列（最新在最底部），後續新事件自然往下接續，不會亂序
foreach ($e in ($events | Sort-Object Time)) { Show-Event $e }

# 時間下限：晚於此時間者才算「新事件」，可避免新出現的 rollout 檔重播舊內容
$floor = Get-MaxEventTime $events

# 記下各檔目前的結尾位移，之後只讀新增位元組，不會重播舊內容
$offsets = @{}
$carries = @{}
foreach ($f in (Get-RolloutFiles)) {
    $offsets[$f.FullName] = [long]$f.Length
    $carries[$f.FullName] = ''
}

$pending = @{}
$safetySeconds = [Math]::Max(5, $Interval)
$pollCap = [Math]::Max(1, $Interval)
$watcher = if ($PollOnly) { $null } else { Get-SessionWatcher $SessionsDir }

if ($null -ne $watcher) {
    Write-Host (Color '90' "── 監看中（檔案變更即時通知；每 $safetySeconds 秒安全檢查；Ctrl+C 結束）──")
} else {
    if (-not $PollOnly) { Write-Host (Color '93' '（無法使用檔案變更通知，改用輪詢）') }
    Write-Host (Color '90' '── 監看中（輪詢；Ctrl+C 結束）──')
}

$idleShown = $false
$ticks = 0
$pollSeconds = [Math]::Min(2, $pollCap)

try {
    while ($true) {
        if ($null -ne $watcher) {
            # 1 秒 timeout 只為了讓 Ctrl+C 能及時中斷；真正的喚醒來自檔案變更事件
            $res = $watcher.WaitForChanged([System.IO.WatcherChangeTypes]::All, 1000)
            $timedOut = $res.TimedOut
            if ($timedOut) {
                $ticks++
                if ($ticks -lt $safetySeconds) { continue }   # 閒置：完全不掃描
                $ticks = 0
            } else {
                $ticks = 0
                Start-Sleep -Milliseconds 250                 # 防抖：等同一批寫入落定
            }
        } else {
            Start-Sleep -Seconds $pollSeconds
            $timedOut = $true
        }

        $batch = Read-TailBatch $offsets $carries
        $newCalls = @(Select-NewEvents $batch.Calls $floor | Sort-Object Time)
        $hasNew = ($newCalls.Count -gt 0) -or ($batch.Outputs.Count -gt 0)

        if ($hasNew) {
            $idleShown = $false
            if ($null -eq $watcher) { $pollSeconds = [Math]::Min(2, $pollCap) }

            foreach ($e in $newCalls) {
                if (-not $e.Output -and $e.CallId) { $pending[$e.CallId] = $e }
                Show-Event $e
            }

            # 先前已輸出、結果晚到的指令：補印結果
            foreach ($id in @($batch.Outputs.Keys)) {
                if (-not $pending.ContainsKey($id)) { continue }
                $ev = $pending[$id]
                if ($ev.Output) { $pending.Remove($id); continue }
                $o = $batch.Outputs[$id]
                $ev | Add-Member -NotePropertyName Output   -NotePropertyValue $o.Output   -Force
                $ev | Add-Member -NotePropertyName ExitCode -NotePropertyValue $o.ExitCode -Force
                $ev | Add-Member -NotePropertyName WallTime -NotePropertyValue $o.WallTime -Force
                Write-Host (Color '90' ('─' * 78))
                Write-Host ((Color '90' '結果（較早指令）') + '  ' + (Color '90' $ev.Time.ToString('yyyy/MM/dd HH:mm:ss')))
                Show-Output $ev
                Write-Host ''
                $pending.Remove($id)
            }

            $floor = Get-MaxEventTime @($newCalls) $floor
            foreach ($o in @($batch.Outputs.Values)) { if ($o.Time -and $o.Time -gt $floor) { $floor = $o.Time } }
        } elseif ($timedOut -and -not $idleShown) {
            Write-Host (Color '90' '… 閒置，等待變更（Ctrl+C 結束）')
            $idleShown = $true
            if ($null -eq $watcher) { $pollSeconds = [Math]::Min($pollCap, [Math]::Max(2, $pollSeconds * 2)) }
        }
    }
} finally {
    if ($null -ne $watcher) { $watcher.Dispose() }
}
