<#
.SYNOPSIS
    安裝／移除 CodexRunLog 的 Codex hook 收集器。

.DESCRIPTION
    把 hooks\codex-runlog-hook.py 複製到 $CodexHome\runlog\，並在
    $CodexHome\hooks.json 加入 SessionStart／PostToolUse／SessionEnd 三個 hook。

    Codex 對非託管 hook 會要求先審查並信任；安裝後請在桌面版
    Settings > Hooks（或 CLI 的 /hooks）核准，hook 才會執行。

    既有 hooks.json 會先備份為 hooks.json.bak.<時間>；-Uninstall 只移除
    本工具的項目，不動其他 hook。

.PARAMETER CodexHome
    Codex 設定目錄，預設 %USERPROFILE%\.codex。

.PARAMETER Python
    python.exe 路徑；省略時自動從 PATH 尋找。

.PARAMETER Uninstall
    移除 hooks.json 內本工具的項目（不會刪除已收集的 events.jsonl）。

.EXAMPLE
    pwsh -File .\hooks\Install-Hook.ps1

.EXAMPLE
    pwsh -File .\hooks\Install-Hook.ps1 -Uninstall
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [string]$CodexHome = (Join-Path $HOME '.codex'),
    [string]$Python = '',
    [switch]$Uninstall
)

$ErrorActionPreference = 'Stop'

$marker = 'codex-runlog-hook.py'
$source = Join-Path $PSScriptRoot 'codex-runlog-hook.py'
$hooksPath = Join-Path $CodexHome 'hooks.json'
$installDir = Join-Path $CodexHome 'runlog'
$target = Join-Path $installDir $marker

if (-not (Test-Path -LiteralPath $CodexHome)) {
    throw "找不到 Codex 設定目錄：$CodexHome"
}

# ── 讀取既有 hooks.json（壞檔不覆寫）──────────────────────────────────
$cfg = $null
if (Test-Path -LiteralPath $hooksPath) {
    try {
        $cfg = Get-Content -LiteralPath $hooksPath -Raw | ConvertFrom-Json
    } catch {
        throw "hooks.json 不是有效 JSON，未做任何修改：$($_.Exception.Message)"
    }
} else {
    $cfg = [pscustomobject]@{}
}
if (-not $cfg.PSObject.Properties['hooks']) {
    $cfg | Add-Member -NotePropertyName hooks -NotePropertyValue ([pscustomobject]@{})
}
$hooks = $cfg.hooks

# ── 建立／移除項目 ────────────────────────────────────────────────────
# ── 解析 python（必須在建立 handler 前）────────────────────────────────
if (-not $Uninstall) {
    if (-not $Python) {
        $cmd = Get-Command python -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        if (-not $cmd) { throw '找不到 python.exe；請用 -Python 指定路徑。' }
        $Python = $cmd.Source
    }
    # Codex 在 Windows 上直接以空白切分 hook command（不經 shell），含空白的路徑會失敗
    foreach ($p in @($Python, $target)) {
        if ($p -match '\s') { throw "hook 路徑含空白，Codex 無法直接執行：$p（請改用無空白的路徑）" }
    }
}

function Test-OurHandler {
    param($Handler)
    foreach ($field in @('command', 'commandWindows')) {
        $value = $Handler.$field
        if ($value -and ([string]$value).Contains($marker)) { return $true }
    }
    return $false
}

$events = @('SessionStart', 'PostToolUse', 'SessionEnd')
foreach ($ev in $events) {
    $groups = @()
    if ($hooks.PSObject.Properties[$ev]) { $groups = @($hooks.$ev) }

    $kept = @()
    foreach ($group in $groups) {
        $handlers = @($group.hooks | Where-Object { -not (Test-OurHandler $_) })
        if ($handlers.Count -gt 0) {
            $group.hooks = $handlers
            $kept += $group
        }
    }

    if ($Uninstall) {
        if ($kept.Count -gt 0) {
            $hooks | Add-Member -NotePropertyName $ev -NotePropertyValue $kept -Force
        } else {
            $hooks.PSObject.Properties.Remove($ev)
        }
        continue
    }

    $handler = [pscustomobject]@{
        type           = 'command'
        command        = $Python + ' ' + $target
        commandWindows = $Python + ' ' + $target
        timeout        = if ($ev -eq 'SessionEnd') { 3 } else { 10 }
        statusMessage  = 'CodexRunLog: 記錄事件'
    }
    $group = [pscustomobject]@{ hooks = @($handler) }
    if ($ev -eq 'PostToolUse') { $group | Add-Member -NotePropertyName matcher -NotePropertyValue '*' }
    $kept += $group
    $hooks | Add-Member -NotePropertyName $ev -NotePropertyValue $kept -Force
}

# ── 寫檔 ──────────────────────────────────────────────────────────────
if (-not $Uninstall) {
    if ($PSCmdlet.ShouldProcess($target, '複製 hook 收集器')) {
        New-Item -ItemType Directory -Force -Path $installDir | Out-Null
        Copy-Item -LiteralPath $source -Destination $target -Force
    }
}

if ($PSCmdlet.ShouldProcess($hooksPath, $(if ($Uninstall) { '移除 CodexRunLog hooks' } else { '寫入 CodexRunLog hooks' }))) {
    if (Test-Path -LiteralPath $hooksPath) {
        $backup = "$hooksPath.bak." + (Get-Date -Format 'yyyyMMdd-HHmmss')
        Copy-Item -LiteralPath $hooksPath -Destination $backup -Force
        Write-Host "已備份：$backup"
    }
    $json = $cfg | ConvertTo-Json -Depth 20
    [System.IO.File]::WriteAllText($hooksPath, $json + "`n", [System.Text.UTF8Encoding]::new($false))
}

if ($Uninstall) {
    Write-Host '已移除 CodexRunLog hooks（events.jsonl 保留）。'
} else {
    Write-Host "已寫入：$hooksPath"
    Write-Host "收集器：$target"
    Write-Host ''
    Write-Host '下一步（必要）：在 Codex 桌面版 Settings > Hooks，或 CLI 輸入 /hooks，'
    Write-Host '審查並信任這幾個 hook；未信任前 Codex 不會執行它們。'
}
