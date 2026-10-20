#requires -Version 5.1
param([string] $FixtureDirectory, [switch] $Online)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$scriptFile = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Protect-PCL.ps1'))
$testRoot = Join-Path $PSScriptRoot ('.test-run-' + [guid]::NewGuid().ToString('N'))
$null = [IO.Directory]::CreateDirectory($testRoot)
$script:checks = 0

function Assert-True([bool] $Condition, [string] $Message) {
    if (-not $Condition) { throw "FAIL: $Message" }
    $script:checks++
    Write-Host "PASS: $Message"
}
function Hash([string] $File) { return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash }
function Run-Tool([string[]] $Arguments, [int] $ExpectedExit = 0) {
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        $output = & "$PSHOME\powershell.exe" -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $scriptFile @Arguments 2>&1
        $code = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($code -ne $ExpectedExit) { throw "Unexpected exit $code (expected $ExpectedExit): $output" }
    return ($output | Out-String)
}
function New-Case([string] $Name, [string] $Fixture = 'old.exe') {
    $directory = Join-Path $testRoot $Name
    $null = [IO.Directory]::CreateDirectory((Join-Path $directory 'PCL'))
    # 同时验证带空格、中文和方括号的路径以及重命名的启动器。
    $exe = Join-Path $directory '我的启动器 [personal].exe'
    [IO.File]::Copy((Join-Path $FixtureDirectory $Fixture), $exe)
    return [pscustomobject]@{ Root = $directory; Exe = $exe; Ini = Join-Path $directory 'PCL\Setup.ini' }
}
function Get-Backup([object] $Case) {
    return @(Get-ChildItem -LiteralPath (Join-Path $Case.Root 'PCL-Backups') -Directory)[0].FullName
}
function Get-UpstreamArchive([string] $Revision, [string] $ExpectedHash, [string] $Destination) {
    $url = 'https://raw.githubusercontent.com/Meloong-Git/PCL/' + $Revision + '/%E6%9C%80%E6%96%B0%E6%AD%A3%E5%BC%8F%E7%89%88.zip'
    $previousTls = [Net.ServicePointManager]::SecurityProtocol
    try {
        [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
        Invoke-WebRequest -Uri $url -OutFile $Destination -UseBasicParsing -TimeoutSec 120
    } finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
    if ((Hash $Destination) -ine $ExpectedHash) { throw 'Upstream test archive SHA-256 mismatch.' }
}
function Run-Standalone([string] $Entry, [string] $Launcher, [string] $Archive, [string] $Backup, [int] $ExpectedExit = 0) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = $env:ComSpec
    $arguments = ' -Path "' + $Launcher + '" -RollbackArchive "' + $Archive + '"'
    if ($Backup) { $arguments = ' -RestoreBackup "' + $Backup + '"' }
    $start.Arguments = '/d /s /c ""' + $Entry + '"' + $arguments + '"'
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.EnvironmentVariables['PCL_MAINTENANCE_NO_PAUSE'] = '1'
    # 临时脚本也限定在测试目录中，不写入实际用户的临时目录。
    $start.EnvironmentVariables['TEMP'] = [IO.Path]::GetDirectoryName($Entry)
    $process = [Diagnostics.Process]::Start($start)
    try {
        $output = $process.StandardOutput.ReadToEnd()
        $errors = $process.StandardError.ReadToEnd()
        $process.WaitForExit()
        if ($process.ExitCode -ne $ExpectedExit) { throw "CMD exit $($process.ExitCode): $output $errors" }
        return $output
    } finally { $process.Dispose() }
}

try {
    $parseErrors = $null; $tokens = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($scriptFile, [ref] $tokens, [ref] $parseErrors)
    Assert-True ($parseErrors.Count -eq 0) 'PowerShell 5.1 syntax'
    $standalone = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\Protect-PCL.cmd'))
    $cmdText = [IO.File]::ReadAllText($standalone)
    $marker = ':PCL_POWERSHELL_PAYLOAD'
    $embedded = [Convert]::FromBase64String($cmdText.Substring($cmdText.LastIndexOf($marker) + $marker.Length))
    Assert-True ([Convert]::ToBase64String($embedded) -ceq [Convert]::ToBase64String([IO.File]::ReadAllBytes($scriptFile))) 'standalone CMD embeds exact current source'
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (-not $FixtureDirectory) {
        $FixtureDirectory = Join-Path $testRoot 'fixtures'
        $null = [IO.Directory]::CreateDirectory($FixtureDirectory)
        foreach ($item in @(@('5ef81e490ae46b1100d61e33d0183094c7a80ca8', 'old', '0835d346cd0f95c1472a3c0655d66e6ca8b7e4494ca0083768e3316f2cd4e7b1'), @('6b9a50df911c9d68b69b24c979efba477fb14b67', 'new', '01877f06df84cbab376c286a633e76ef7fca0bb469e26df97f3b09b5abd503bc'))) {
            $archive = Join-Path $FixtureDirectory ($item[1] + '.zip')
            Get-UpstreamArchive $item[0] $item[2] $archive
            $zip = [IO.Compression.ZipFile]::OpenRead($archive)
            try { [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.Entries[0], (Join-Path $FixtureDirectory ($item[1] + '.exe'))) }
            finally { $zip.Dispose() }
        }
    }
    $oldHash = Hash (Join-Path $FixtureDirectory 'old.exe')
    $newHash = Hash (Join-Path $FixtureDirectory 'new.exe')

    $case = New-Case 'CMD & 单文件 [运行]' 'new.exe'
    $entry = Join-Path $case.Root 'Protect-PCL.cmd'
    [IO.File]::Copy($standalone, $entry)
    $output = Run-Standalone $entry $case.Exe (Join-Path $FixtureDirectory 'old.zip') ''
    Assert-True ((Hash $case.Exe) -eq $oldHash -and [IO.File]::ReadAllText($case.Ini).Contains('SystemSystemUpdate:3')) 'standalone CMD rollback without adjacent PS1'
    Assert-True ($output.Contains('Protect-PCL.cmd') -and -not $output.Contains('PCL-Maintenance-')) 'standalone restore command points to durable CMD'
    Assert-True (@(Get-ChildItem -LiteralPath $case.Root -Filter '*.ps1' -File).Count -eq 0) 'standalone removes its temporary source'
    $null = Run-Standalone $entry $case.Exe '' (Get-Backup $case)
    Assert-True ((Hash $case.Exe) -eq $newHash) 'standalone CMD forwards restore arguments'
    $null = Run-Standalone $entry $case.Exe (Join-Path $FixtureDirectory 'new.zip') '' 1
    Assert-True ((Hash $case.Exe) -eq $newHash -and @(Get-ChildItem -LiteralPath $case.Root -Filter '*.ps1' -File).Count -eq 0) 'standalone propagates failure and cleans temporary source'

    foreach ($item in @(
        @('utf8', [Text.UTF8Encoding]::new($false), "`r`n"),
        @('utf8-bom', [Text.UTF8Encoding]::new($true), "`n"),
        @('utf16le', [Text.UnicodeEncoding]::new($false, $true), "`r`n"),
        @('utf16be', [Text.UnicodeEncoding]::new($true, $true), "`r"),
        @('ansi', [Text.Encoding]::Default, "`r`n")
    )) {
        $case = New-Case ('配置 [保留] ' + $item[0])
        $encoding = $item[1]; $nl = $item[2]
        $before = '标题:保留中文、空格和冒号:值' + $nl + 'SystemSystemUpdate:0' + $nl + 'Other:keep' + $nl + 'SystemSystemUpdate:1'
        $expected = '标题:保留中文、空格和冒号:值' + $nl + 'SystemSystemUpdate:3' + $nl + 'Other:keep' + $nl + 'SystemSystemUpdate:3'
        [IO.File]::WriteAllText($case.Ini, $before, $encoding)
        $originalHash = Hash $case.Ini
        $null = Run-Tool @('-Path', $case.Exe)
        $expectedPath = Join-Path $case.Root 'expected.ini'
        [IO.File]::WriteAllText($expectedPath, $expected, $encoding)
        Assert-True ((Hash $case.Ini) -eq (Hash $expectedPath)) ($item[0] + ': preserve other bytes and replace duplicate keys')
        Assert-True ((Hash $case.Exe) -eq $oldHash) ($item[0] + ': keep old EXE')
        $backup = Get-Backup $case
        Assert-True ((Hash (Join-Path $backup 'Setup.ini.original')) -eq $originalHash) ($item[0] + ': exact original backup')
        $null = Run-Tool @('-Path', $case.Exe)
        Assert-True (@(Get-ChildItem -LiteralPath (Join-Path $case.Root 'PCL-Backups') -Directory).Count -eq 1) ($item[0] + ': idempotent second run')
        $null = Run-Tool @('-RestoreBackup', $backup)
        Assert-True ((Hash $case.Ini) -eq $originalHash) ($item[0] + ': restore original bytes')
    }

    $case = New-Case '缺少配置'
    $null = Run-Tool @('-Path', $case.Root)
    Assert-True ([IO.File]::ReadAllText($case.Ini) -eq "SystemSystemUpdate:3`r`n") 'create missing config'
    $null = Run-Tool @('-RestoreBackup', (Get-Backup $case))
    Assert-True ([IO.File]::Exists($case.Ini)) 'restore keeps config that did not previously exist'

    $case = New-Case '缺少配置项'
    [IO.File]::WriteAllText($case.Ini, 'Other:保留', [Text.UTF8Encoding]::new($false))
    $null = Run-Tool @('-Path', $case.Exe)
    Assert-True ([IO.File]::ReadAllText($case.Ini) -eq "Other:保留`r`nSystemSystemUpdate:3`r`n") 'append key without dropping final line'

    $case = New-Case '预览' 'new.exe'
    $null = Run-Tool @('-Path', $case.Exe, '-WhatIf')
    Assert-True ((Hash $case.Exe) -eq $newHash -and -not (Test-Path -LiteralPath $case.Ini) -and @(Get-ChildItem -LiteralPath $case.Root -Force).Count -eq 2) 'WhatIf writes nothing'

    $case = New-Case '安全回退' 'new.exe'
    [IO.File]::WriteAllText($case.Ini, "Other:保留`nSystemSystemUpdate:0`n", [Text.UTF8Encoding]::new($true))
    $configHash = Hash $case.Ini
    $game = Join-Path $case.Root '.minecraft\saves\世界'
    $null = [IO.Directory]::CreateDirectory($game)
    $save = Join-Path $game 'level.dat'
    [IO.File]::WriteAllBytes($save, [byte[]](0, 1, 2, 255))
    $saveHash = Hash $save
    $null = Run-Tool @('-Path', $case.Exe, '-RollbackArchive', (Join-Path $FixtureDirectory 'old.zip'))
    Assert-True ((Hash $case.Exe) -eq $oldHash) 'replace with verified official old EXE'
    Assert-True ([IO.File]::ReadAllText($case.Ini) -eq "Other:保留`nSystemSystemUpdate:3`n") 'rollback disables updates and preserves config'
    Assert-True ((Hash $save) -eq $saveHash) 'game save untouched'
    $backup = Get-Backup $case
    Assert-True ((Hash (Join-Path $backup 'Launcher.exe.original')) -eq $newHash) 'new EXE fully backed up'
    $null = Run-Tool @('-RestoreBackup', $backup)
    Assert-True ((Hash $case.Exe) -eq $newHash -and (Hash $case.Ini) -eq $configHash) 'restore EXE and config'
    $backups = @(Get-ChildItem -LiteralPath (Join-Path $case.Root 'PCL-Backups') -Directory)
    Assert-True ($backups.Count -eq 2) 'restoration also backs up current content'

    $case = New-Case '错误压缩包' 'new.exe'
    [IO.File]::WriteAllText($case.Ini, 'Other:untouched')
    $configHash = Hash $case.Ini
    $null = Run-Tool @('-Path', $case.Exe, '-RollbackArchive', (Join-Path $FixtureDirectory 'new.zip')) 1
    Assert-True ((Hash $case.Exe) -eq $newHash -and (Hash $case.Ini) -eq $configHash) 'bad archive changes no original files'
    Assert-True (-not (Test-Path -LiteralPath (Join-Path $case.Root 'PCL-Backups'))) 'bad archive creates no misleading backup'

    $case = New-Case '独占占用' 'new.exe'
    $lock = [IO.File]::Open($case.Exe, 'Open', 'Read', 'None')
    try { $null = Run-Tool @('-Path', $case.Exe) 1 } finally { $lock.Dispose() }
    Assert-True ((Hash $case.Exe) -eq $newHash -and -not (Test-Path -LiteralPath $case.Ini)) 'locked launcher refused'

    $case = New-Case '非启动器'
    [IO.File]::Copy("$PSHOME\powershell.exe", $case.Exe, $true)
    $exeHash = Hash $case.Exe
    $null = Run-Tool @('-Path', $case.Exe) 1
    Assert-True ((Hash $case.Exe) -eq $exeHash -and -not (Test-Path -LiteralPath $case.Ini)) 'unrelated EXE refused'

    $case = New-Case '只读配置' 'new.exe'
    [IO.File]::WriteAllText($case.Ini, 'SystemSystemUpdate:0')
    $configHash = Hash $case.Ini
    [IO.File]::SetAttributes($case.Ini, [IO.FileAttributes]::ReadOnly)
    try { $null = Run-Tool @('-Path', $case.Exe, '-RollbackArchive', (Join-Path $FixtureDirectory 'old.zip')) 1 }
    finally { [IO.File]::SetAttributes($case.Ini, [IO.FileAttributes]::Normal) }
    Assert-True ((Hash $case.Exe) -eq $newHash -and (Hash $case.Ini) -eq $configHash) 'read-only config does not downgrade EXE'

    $case = New-Case '运行中的更新程序' 'new.exe'
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = "$PSHOME\powershell.exe"
    $start.Arguments = '-NoProfile -NonInteractive -Command "Start-Sleep -Seconds 60 # --update ' + $case.Exe + '"'
    $start.UseShellExecute = $false
    $worker = [Diagnostics.Process]::Start($start)
    try { $null = Run-Tool @('-Path', $case.Exe) 1 }
    finally { if (-not $worker.HasExited) { $worker.Kill(); $worker.WaitForExit() }; $worker.Dispose() }
    Assert-True ((Hash $case.Exe) -eq $newHash -and -not (Test-Path -LiteralPath $case.Ini)) 'running updater refused without killing it'

    $case = New-Case '损坏的备份'
    $null = Run-Tool @('-Path', $case.Exe)
    $backup = Get-Backup $case
    # 该备份的原配置不存在；用一个有配置的回退场景验证损坏备份。
    [IO.File]::WriteAllText($case.Ini, 'SystemSystemUpdate:0')
    $null = Run-Tool @('-Path', $case.Exe)
    $backup = @(Get-ChildItem -LiteralPath (Join-Path $case.Root 'PCL-Backups') -Directory | Where-Object { [IO.File]::Exists((Join-Path $_.FullName 'Setup.ini.original')) })[0].FullName
    [IO.File]::AppendAllText((Join-Path $backup 'Setup.ini.original'), 'tamper')
    $configHash = Hash $case.Ini
    $null = Run-Tool @('-RestoreBackup', $backup) 1
    Assert-True ((Hash $case.Ini) -eq $configHash -and (Hash $case.Exe) -eq $oldHash) 'corrupted backup refused'

    if ($Online) {
        $case = New-Case '联网下载回退' 'new.exe'
        $null = Run-Tool @('-Path', $case.Exe)
        Assert-True ((Hash $case.Exe) -eq $oldHash -and [IO.File]::ReadAllText($case.Ini).Contains('SystemSystemUpdate:3')) 'HTTPS download and verified rollback'
    }

    # 注入第二个替换失败，验证第一步配置写入会恢复，且原始备份保留。
    . $scriptFile
    $case = New-Case '中途失败'
    [IO.File]::WriteAllText($case.Ini, 'SystemSystemUpdate:0')
    $configHash = Hash $case.Ini
    $stage = Join-Path $case.Root 'staged.ini'
    [IO.File]::WriteAllText($stage, 'SystemSystemUpdate:3')
    $missingStage = Join-Path $case.Root 'will-disappear.exe'
    [IO.File]::Copy((Join-Path $FixtureDirectory 'new.exe'), $missingStage)
    $script:stopChecks = 0
    function Assert-PclStopped([string] $Launcher, [switch] $SkipFileProbe) {
        $script:stopChecks++
        if ($script:stopChecks -eq 2) { [IO.File]::Delete($missingStage) }
    }
    $failed = $false
    try {
        $null = Invoke-PclTransaction $case.Exe @(
            [pscustomobject]@{ Target = $case.Ini; Stage = $stage; BackupName = 'Setup.ini.original'; BeforeHash = $configHash.ToLowerInvariant() },
            [pscustomobject]@{ Target = $case.Exe; Stage = $missingStage; BackupName = 'Launcher.exe.original'; BeforeHash = $oldHash.ToLowerInvariant() }
        ) 'test injected failure'
    } catch { $failed = $true }
    Assert-True ($failed -and (Hash $case.Ini) -eq $configHash -and (Hash $case.Exe) -eq $oldHash) 'mid-transaction failure restores already changed config'
    Assert-True ((Hash (Join-Path (Get-Backup $case) 'Setup.ini.original')) -eq $configHash) 'failure preserves original backup'

    Write-Host "All $script:checks checks passed." -ForegroundColor Green
} finally {
    # 测试只清理本次创建的唯一目录。
    Remove-Item -LiteralPath $testRoot -Recurse -Force
}
