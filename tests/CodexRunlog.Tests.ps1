#Requires -Modules @{ ModuleName = 'Pester'; ModuleVersion = '5.0.0' }

BeforeAll {
    $scriptPath = Join-Path (Split-Path -Parent $PSScriptRoot) 'Codex運行日誌.ps1'
    . $scriptPath          # 只載入函式（主流程會被 dot-source 守衛擋下）
}

Describe 'ConvertFrom-EscapedString' {
    It '還原換行 \n' {
        ConvertFrom-EscapedString '\n' | Should -Be "`n"
    }
    It '還原雙引號 \"' {
        ConvertFrom-EscapedString '\"' | Should -Be '"'
    }
    It '還原反斜線 \\' {
        ConvertFrom-EscapedString 'a\\b' | Should -Be 'a\b'
    }
    It '還原定位點 \t' {
        ConvertFrom-EscapedString '\t' | Should -Be "`t"
    }
    It '還原 Unicode \uXXXX' {
        ConvertFrom-EscapedString '\u0041' | Should -Be 'A'
    }
    It '未知轉義只取後一字元' {
        ConvertFrom-EscapedString '\x' | Should -Be 'x'
    }
    It '一般文字原樣保留' {
        ConvertFrom-EscapedString 'plain text' | Should -Be 'plain text'
    }
}

Describe 'Get-JsField' {
    It '取出被引號包住的 cmd' {
        Get-JsField 'cmd:"git status",max_output_tokens:5' 'cmd' | Should -Be 'git status'
    }
    It '取出含轉義的 justification' {
        Get-JsField 'justification:"第一行\n第二行"' 'justification' | Should -Be "第一行`n第二行"
    }
    It '欄位不存在時回傳空字串' {
        Get-JsField 'cmd:"x"' 'workdir' | Should -Be ''
    }
}

Describe 'Get-ExecFromJs' {
    It '抽出單一 exec_command' {
        $js = 'text(await tools.exec_command({cmd:"git status",sandbox_permissions:"require_escalated",justification:"檢查狀態"}));'
        $r = Get-ExecFromJs $js
        $r | Should -HaveCount 1
        $r[0].Cmd | Should -Be 'git status'
        $r[0].Sandbox | Should -Be 'require_escalated'
        $r[0].Justification | Should -Be '檢查狀態'
    }

    It '抽出多個 exec_command' {
        $js = 'Promise.allSettled([tools.exec_command({cmd:"a"}),tools.exec_command({cmd:"b"})])'
        $r = Get-ExecFromJs $js
        $r | Should -HaveCount 2
        $r[0].Cmd | Should -Be 'a'
        $r[1].Cmd | Should -Be 'b'
    }

    It '字串內的大括號不會破壞擷取' {
        $js = 'tools.exec_command({cmd:"if (x) { y }"})'
        $r = Get-ExecFromJs $js
        $r | Should -HaveCount 1
        $r[0].Cmd | Should -Be 'if (x) { y }'
    }

    It '沒有 exec_command 時回傳空' {
        $r = Get-ExecFromJs 'read_thread({threadId:"x"})'
        $r | Should -HaveCount 0
    }
}

Describe 'Get-CommandEventsFromLine' {
    It '解析新版 custom_tool_call 並套用預設 workdir' {
        $line = '{"timestamp":"2026-10-13T14:24:59Z","type":"response_item","payload":{"type":"custom_tool_call","name":"exec","input":"text(await tools.exec_command({cmd:\"git status\"}));"}}'
        $e = Get-CommandEventsFromLine $line 'session.jsonl' 'C:\proj'
        $e | Should -HaveCount 1
        $e[0].Cmd | Should -Be 'git status'
        $e[0].Workdir | Should -Be 'C:\proj'
        $e[0].Time | Should -Not -BeNullOrEmpty
    }

    It '解析舊版 function_call exec_command 的 cmd 與 workdir' {
        $line = '{"timestamp":"2026-10-13T14:24:59Z","type":"response_item","payload":{"type":"function_call","name":"exec_command","arguments":"{\"cmd\":\"ls -la\",\"workdir\":\"C:\\\\proj\"}"}}'
        $e = Get-CommandEventsFromLine $line 'session.jsonl'
        $e | Should -HaveCount 1
        $e[0].Cmd | Should -Be 'ls -la'
        $e[0].Workdir | Should -Be 'C:\proj'
    }

    It '舊版 shell_command 取 command 欄位' {
        $line = '{"type":"response_item","payload":{"type":"function_call","name":"shell_command","arguments":"{\"command\":\"rg foo .\"}"}}'
        $e = Get-CommandEventsFromLine $line 'session.jsonl'
        $e | Should -HaveCount 1
        $e[0].Cmd | Should -Be 'rg foo .'
    }

    It '非 response_item 的行不產生事件' {
        $line = '{"type":"event_msg","payload":{"type":"message"}}'
        (Get-CommandEventsFromLine $line 's.jsonl') | Should -HaveCount 0
    }

    It '不是 shell 類工具的行不產生事件' {
        $line = '{"type":"response_item","payload":{"type":"function_call","name":"apply_patch","arguments":"{}"}}'
        (Get-CommandEventsFromLine $line 's.jsonl') | Should -HaveCount 0
    }

    It '壞掉的 JSON 不會拋錯，回傳空' {
        (Get-CommandEventsFromLine '{not json' 's.jsonl') | Should -HaveCount 0
    }
}

Describe 'Get-CodeLanguage' {
    It 'Python：import' { Get-CodeLanguage 'import os' | Should -Be 'python' }
    It 'Python：print(' { Get-CodeLanguage 'print(1)' | Should -Be 'python' }
    It 'Python：here-string 內含 import' {
        Get-CodeLanguage "@'`nimport json`n'@ | python -" | Should -Be 'python'
    }
    It 'JavaScript：const/require' {
        Get-CodeLanguage "const x = require('a')" | Should -Be 'javascript'
    }
    It 'JavaScript：here-string 內含 require' {
        Get-CodeLanguage "@'`nconst {test}=require('node:test')`n'@ | Set-Content a" | Should -Be 'javascript'
    }
    It 'Shell：git' { Get-CodeLanguage 'git status' | Should -Be 'shell' }
    It 'PowerShell：cmdlet' { Get-CodeLanguage 'Get-ChildItem -Force' | Should -Be 'powershell' }
    It 'PowerShell：變數' { Get-CodeLanguage '$env:PATH' | Should -Be 'powershell' }
    It 'PowerShell：註解開頭' { Get-CodeLanguage '# note' | Should -Be 'powershell' }
}

Describe 'Expand-PowerShellStatements' {
    It '分號與大括號斷行並縮排' {
        $lines = (Expand-PowerShellStatements 'if ($x) { a; b }') -split "`n"
        $lines | Should -HaveCount 4
        $lines[0] | Should -Be 'if ($x) {'
        $lines[1] | Should -Be '    a'
        $lines[2] | Should -Be '    b'
        $lines[3] | Should -Be '}'
    }

    It 'for(;;) 內的括號深度保護，不分號斷行' {
        $lines = (Expand-PowerShellStatements 'for($i=0;$i<3;$i++){ x }') -split "`n"
        $lines | Should -HaveCount 3
        $lines[0] | Should -Be 'for($i=0;$i<3;$i++){'
        $lines[1] | Should -Be '    x'
        $lines[2] | Should -Be '}'
    }

    It '單引號字串內的分號不拆' {
        Expand-PowerShellStatements "Write-Host 'a;b'" | Should -Be "Write-Host 'a;b'"
    }

    It '雙引號字串內以反引號轉義的分號不拆' {
        Expand-PowerShellStatements 'Write-Host "a`;b"' | Should -Be 'Write-Host "a`;b"'
    }

    It '註解內的分號不拆' {
        Expand-PowerShellStatements 'Get-Item x # note; here' | Should -Be 'Get-Item x # note; here'
    }

    It '單純多句以分號斷行' {
        $lines = (Expand-PowerShellStatements 'a; b') -split "`n"
        $lines | Should -HaveCount 2
        $lines[0] | Should -Be 'a'
        $lines[1] | Should -Be 'b'
    }
}

Describe 'Format-Line' {
    It 'PowerShell cmdlet 上黃色 (33)' {
        (Format-Line 'Get-ChildItem' 'powershell').Contains("$([char]27)[33m") | Should -BeTrue
    }
    It 'PowerShell 關鍵字上洋紅 (35)' {
        (Format-Line 'if ($x) { }' 'powershell').Contains("$([char]27)[35m") | Should -BeTrue
    }
    It 'PowerShell 變數上亮青 (96)' {
        (Format-Line '$env:PATH' 'powershell').Contains("$([char]27)[96m") | Should -BeTrue
    }
    It '字串上綠色 (32)' {
        (Format-Line 'Write-Host "hi"' 'powershell').Contains("$([char]27)[32m") | Should -BeTrue
    }
    It '關鍵字不會污染到字串內容' {
        # 'if' 在字串內不應被上成關鍵字色：整個字串只會有一段綠色
        $out = Format-Line "Write-Host 'if'" 'powershell'
        $out.Contains("$([char]27)[35m") | Should -BeFalse
    }
    It '結束碼不會外洩：輸出尾端有 reset' {
        (Format-Line 'git status' 'shell').Contains("$([char]27)[0m") | Should -BeTrue
    }
}

Describe '整合：fixture 檔端到端解析' {
    BeforeAll {
        $script:fixture = Join-Path $PSScriptRoot 'fixtures/sessions/2026/10/14/rollout-2026-10-14T10-00-00-fixture.jsonl'
        $script:fixtureCwd = 'C:\fixtures\demo'
        $script:fixtureEvents = foreach ($line in (Read-SharedLines $script:fixture)) {
            if (Test-HasCommand $line) { Get-CommandEventsFromLine $line $script:fixture $script:fixtureCwd }
        }
    }

    It 'fixture 檔存在' {
        Test-Path -LiteralPath $script:fixture | Should -BeTrue
    }

    It '抽出預期的 5 個指令且順序正確' {
        $script:fixtureEvents | Should -HaveCount 5
        ($script:fixtureEvents.Cmd -join '|') | Should -Be 'git status|echo a|echo b|ls -la|rg foo .'
    }

    It '新版指令帶入 justification' {
        $script:fixtureEvents[0].Justification | Should -Be '檢查狀態'
    }

    It '未帶 workdir 的指令套用 session cwd' {
        $script:fixtureEvents[0].Workdir | Should -Be 'C:\fixtures\demo'
        $script:fixtureEvents[1].Workdir | Should -Be 'C:\fixtures\demo'
    }

    It '舊版指令的 workdir 取自身參數' {
        $script:fixtureEvents[3].Cmd | Should -Be 'ls -la'
        $script:fixtureEvents[3].Workdir | Should -Be 'C:\proj'
    }

    It '非指令行（session_meta / message / apply_patch）不產生事件' {
        # 7 行中只有 4 行含 exec_command / shell_command，共 5 筆事件
        $script:fixtureEvents | Should -HaveCount 5
    }
}

Describe '監看時間下限（Get-MaxEventTime / Select-NewEvents）' {
    It 'Get-MaxEventTime 取集合中最大時間' {
        $ev1 = [pscustomobject]@{ Time = [DateTimeOffset]::Parse('2026-10-14T10:00:01Z'); Cmd = 'a' }
        $ev2 = [pscustomobject]@{ Time = [DateTimeOffset]::Parse('2026-10-14T10:00:02Z'); Cmd = 'b' }
        Get-MaxEventTime @($ev1, $ev2) | Should -Be ([DateTimeOffset]::Parse('2026-10-14T10:00:02Z'))
    }

    It 'Get-MaxEventTime 空集合時回傳 Start' {
        $start = [DateTimeOffset]::Parse('2026-10-01T00:00:00Z')
        Get-MaxEventTime @() $start | Should -Be $start
    }

    It 'Select-NewEvents 只保留比 Floor 新的事件' {
        $t1 = [DateTimeOffset]::Parse('2026-10-14T10:00:01Z')
        $ev1 = [pscustomobject]@{ Time = $t1; Cmd = 'a' }
        $ev2 = [pscustomobject]@{ Time = [DateTimeOffset]::Parse('2026-10-14T10:00:02Z'); Cmd = 'b' }
        $new = @(Select-NewEvents @($ev1, $ev2) $t1)
        $new | Should -HaveCount 1
        $new[0].Cmd | Should -Be 'b'
    }

    It 'Select-NewEvents 保留時間未知（null）的事件' {
        $evNull = [pscustomobject]@{ Time = $null; Cmd = 'x' }
        $floor = [DateTimeOffset]::Parse('2026-10-14T10:00:02Z')
        @(Select-NewEvents @($evNull) $floor)[0].Cmd | Should -Be 'x'
    }
}

Describe '單引號 cmd（Codex 另一種寫法）' {
    It 'Get-JsField 支援單引號字串' {
        Get-JsField "cmd:'git status'" 'cmd' | Should -Be 'git status'
    }

    It 'Get-JsField 還原單引號內的反斜線轉義' {
        Get-JsField "cmd:'rg -n \'foo\' .'" 'cmd' | Should -Be "rg -n 'foo' ."
    }

    It 'Get-ExecFromJs 抽出單引號 cmd' {
        $js = "text(await tools.exec_command({cmd:'git status',max_output_tokens:4000}));"
        $e = @(Get-ExecFromJs $js)
        $e | Should -HaveCount 1
        $e[0].Cmd | Should -Be 'git status'
    }

    It 'Get-ExecFromJs 單引號 cmd 內的大括號不會破壞擷取' {
        $js = "tools.exec_command({cmd:'echo {a} }',max_output_tokens:10})"
        $e = @(Get-ExecFromJs $js)
        $e | Should -HaveCount 1
        $e[0].Cmd | Should -Be 'echo {a} }'
    }

    It 'Get-ExecFromJs 混合雙引號與單引號欄位' {
        $js = "tools.exec_command({cmd:'git diff --check',sandbox_permissions:`"require_escalated`",justification:`"檢查`"})"
        $e = @(Get-ExecFromJs $js)
        $e[0].Cmd | Should -Be 'git diff --check'
        $e[0].Sandbox | Should -Be 'require_escalated'
        $e[0].Justification | Should -Be '檢查'
    }
}

Describe '反引號（樣板字串）cmd' {
    It 'Get-JsField 支援反引號字串' {
        $bt = [char]96
        Get-JsField ('cmd:' + $bt + 'hello world' + $bt) 'cmd' | Should -Be 'hello world'
    }

    It 'Get-ExecFromJs 抽出跨行反引號 cmd' {
        $js = @'
tools.exec_command({cmd:`line1
line2`,max_output_tokens:10})
'@
        $e = @(Get-ExecFromJs $js)
        $e | Should -HaveCount 1
        $e[0].Cmd | Should -Be "line1`nline2"
    }

    It '跨行反引號 cmd 內的括號不影響擷取' {
        $js = @'
tools.exec_command({cmd:`if (x) { y }
done`,max_output_tokens:1})
'@
        $e = @(Get-ExecFromJs $js)
        $e[0].Cmd | Should -Be "if (x) { y }`ndone"
    }
}
