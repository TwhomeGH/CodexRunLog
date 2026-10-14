#requires -Version 7.0
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
    相較 SQLite 的 feedback_log_body（會被 Codex 截斷），rollout 是完整指令。

.PARAMETER Limit
    起始顯示的指令筆數（由新到舊）。預設 50。

.PARAMETER Tail
    持續監看：印完起始內容後，輪詢各 rollout 檔新增的行並即時輸出。

.PARAMETER Interval
    -Tail 的輪詢間隔秒數。預設 2。

.PARAMETER SessionsDir
    rollout JSONL 根目錄。省略時依序嘗試：
    設定檔 CodexRunlog.ini → %USERPROFILE%\.codex\sessions。
    若都找不到，會提示手動輸入，並把結果寫回 CodexRunlog.ini。

.EXAMPLE
    .\Codex運行日誌.ps1
    .\Codex運行日誌.ps1 -Limit 100
    .\Codex運行日誌.ps1 -Tail -Interval 3
#>
[CmdletBinding()]
param(
    [int]$Limit = 50,
    [switch]$Tail,
    [int]$Interval = 2,
    [string]$SessionsDir = ''
)

$ErrorActionPreference = 'Stop'
[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$OutputEncoding = [System.Text.Encoding]::UTF8

$ESC = [char]27
$ConfigPath = Join-Path $PSScriptRoot 'CodexRunlog.ini'

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
                $e | Add-Member -NotePropertyName Time   -NotePropertyValue $time   -Force
                $e | Add-Member -NotePropertyName Source -NotePropertyValue $Source -Force
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
    return Get-ChildItem -LiteralPath $SessionsDir -Recurse -Filter 'rollout-*.jsonl' -File -ErrorAction SilentlyContinue |
        Sort-Object LastWriteTime -Descending
}

function Test-HasCommand {
    param([string]$Line)
    return ($Line.IndexOf('exec_command') -ge 0) -or ($Line.IndexOf('shell_command') -ge 0)
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

function Get-RecentEvents {
    param([int]$Need)
    $all = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-RolloutFiles)) {
        $cwd = Get-SessionCwd $f.FullName
        try {
            foreach ($line in (Read-SharedLines $f.FullName)) {
                if (-not (Test-HasCommand $line)) { continue }
                foreach ($ev in (Get-CommandEventsFromLine $line $f.FullName $cwd)) { $all.Add($ev) }
            }
        } catch { continue }
        if ($all.Count -ge $Need) { break }
    }
    return @($all | Sort-Object Time -Descending | Select-Object -First $Need)
}

# ── 輸出 ─────────────────────────────────────────────────────────────
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

# 被 dot-source 時（例如單元測試載入函式）不執行主流程
if ($MyInvocation.InvocationName -eq '.') { return }

$SessionsDir = Resolve-SessionsDir $SessionsDir

$events = @(Get-RecentEvents $Limit)

if (-not $Tail) {
    # 一般模式：最新在上，方便一眼看到最近的動作
    foreach ($e in $events) { Show-Event $e }
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

Write-Host (Color '90' "── 監看中（每 $Interval 秒輪詢；新事件接續於下方，Ctrl+C 結束）──")
while ($true) {
    Start-Sleep -Seconds $Interval

    $batch = [System.Collections.Generic.List[object]]::new()
    foreach ($f in (Get-RolloutFiles)) {
        $path = $f.FullName
        if (-not $offsets.ContainsKey($path)) {
            $offsets[$path] = 0L
            $carries[$path] = ''
        }
        if ([long]$f.Length -lt $offsets[$path]) {
            $offsets[$path] = 0L
            $carries[$path] = ''
        }
        if ([long]$f.Length -le $offsets[$path]) { continue }

        $r = try { Read-AppendedLines $path $offsets[$path] $carries[$path] } catch { $null }
        if ($null -eq $r) { continue }
        $offsets[$path] = $r.Offset
        $carries[$path] = $r.Carry

        $cwd = Get-SessionCwd $path
        foreach ($line in $r.Lines) {
            if (-not (Test-HasCommand $line)) { continue }
            $lineEvents = Get-CommandEventsFromLine $line $path $cwd
            foreach ($ev in (Select-NewEvents $lineEvents $floor)) { $batch.Add($ev) }
        }
    }

    if ($batch.Count -gt 0) {
        $sorted = @($batch | Sort-Object Time)
        foreach ($e in $sorted) { Show-Event $e }
        $floor = Get-MaxEventTime $sorted $floor
    }
}
