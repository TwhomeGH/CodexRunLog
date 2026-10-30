@{
    # 只把 Warning 以上當問題（Information 視為建議，例如位置參數用法）
    Severity = @('Error', 'Warning')

    # 逐條排除並附理由
    ExcludeRules = @(
        # 本工具就是主控台 UI，Write-Host 是刻意的輸出方式（PS7 已可重導）
        'PSAvoidUsingWriteHost'
        # 函式命名偏好（Get-ExecFromJs / Read-AppendedLines 等）刻意保留；重命名成本高、收益低
        'PSUseSingularNouns'
        # 本腳本 #requires PS 7，UTF-8 無 BOM 在 PS7 讀取正常
        'PSUseBOMForUnicodeEncodedFile'
        # Pester 的 BeforeAll 變數會在 It 內使用，分析器看不到跨 scope 使用（已知誤報）
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
