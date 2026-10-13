#requires -Version 7.0
<#
.SYNOPSIS
    CI / 本機檢查：PSScriptAnalyzer + Pester（＋ Windows 冒煙測試）。

.DESCRIPTION
    在專案根目錄執行：
        pwsh -File .\scripts\check.ps1
    任一項失敗會以非 0 結束碼結束，適合放進 CI。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$root = Split-Path -Parent $PSScriptRoot
$fail = 0

# ── 1. PSScriptAnalyzer ──────────────────────────────────────────────
Write-Host '== PSScriptAnalyzer ==' -ForegroundColor Cyan
Import-Module PSScriptAnalyzer -ErrorAction Stop
$settings = Join-Path $root 'PSScriptAnalyzerSettings.psd1'
$targets = @(
    (Join-Path $root 'Codex運行日誌.ps1'),
    (Join-Path $root 'tests/CodexRunlog.Tests.ps1')
)
$issues = @(foreach ($t in $targets) { Invoke-ScriptAnalyzer -Path $t -Settings $settings })
if ($issues.Count -gt 0) {
    $issues | Format-Table RuleName, Severity, Line, Message -AutoSize -Wrap | Out-String | Write-Host
    Write-Host "PSScriptAnalyzer: $($issues.Count) 個問題" -ForegroundColor Red
    $fail++
} else {
    Write-Host 'PSScriptAnalyzer: 通過' -ForegroundColor Green
}

# ── 2. Pester ───────────────────────────────────────────────────────
Write-Host '== Pester ==' -ForegroundColor Cyan
Import-Module Pester -MinimumVersion 5.0 -ErrorAction Stop
$cfg = New-PesterConfiguration
$cfg.Run.Path = Join-Path $root 'tests'
$cfg.Run.Exit = $false
$cfg.Output.Verbosity = 'Detailed'
$result = Invoke-Pester -Configuration $cfg
if ($result.FailedCount -gt 0) {
    Write-Host "Pester: $($result.FailedCount) 個失敗" -ForegroundColor Red
    $fail++
}

# ── 3. 冒煙測試（僅 Windows：主腳本目前只支援 Windows）──────────────
Write-Host '== 冒煙測試 ==' -ForegroundColor Cyan
if ($IsWindows) {
    $fixture = Join-Path $root 'tests/fixtures/sessions'
    $script = Join-Path $root 'Codex運行日誌.ps1'
    $out = & $script -SessionsDir $fixture -Limit 10 6>&1 2>&1 | Out-String
    if ($out -match 'git status') {
        Write-Host '冒煙測試: 通過' -ForegroundColor Green
    } else {
        Write-Host '冒煙測試: 失敗（輸出沒有 git status）' -ForegroundColor Red
        Write-Host $out
        $fail++
    }
} else {
    Write-Host '冒煙測試: 略過（主腳本目前僅支援 Windows）' -ForegroundColor Yellow
}

# ── 結果 ────────────────────────────────────────────────────────────
if ($fail -gt 0) {
    Write-Host "檢查失敗（$fail 項）" -ForegroundColor Red
    exit 1
}
Write-Host '全部通過' -ForegroundColor Green
exit 0
