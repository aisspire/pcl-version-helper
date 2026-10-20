#requires -Version 5.1
[CmdletBinding(SupportsShouldProcess = $true, DefaultParameterSetName = 'Protect')]
param(
    [Parameter(ParameterSetName = 'Protect', Position = 0)]
    [string] $Path,
    [Parameter(ParameterSetName = 'Protect')]
    [string] $RollbackArchive,
    [Parameter(ParameterSetName = 'Restore', Mandatory = $true)]
    [string] $RestoreBackup
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$script:ArchiveHash = '0835d346cd0f95c1472a3c0655d66e6ca8b7e4494ca0083768e3316f2cd4e7b1'
$script:LauncherHash = '5582952ded3b443503f66c23b810802bd20f1a3e847b54d9e09653a825859a36'
$script:ArchiveUrl = 'https://raw.githubusercontent.com/Meloong-Git/PCL/5ef81e490ae46b1100d61e33d0183094c7a80ca8/%E6%9C%80%E6%96%B0%E6%AD%A3%E5%BC%8F%E7%89%88.zip'

function Get-PclHash([string] $File) {
    if (-not [IO.File]::Exists($File)) { return $null }
    return (Get-FileHash -LiteralPath $File -Algorithm SHA256).Hash.ToLowerInvariant()
}

function Assert-PclPlainPath([string] $File) {
    # 拒绝符号链接、目录联接和网络路径，避免写入意外位置。
    if ($File.StartsWith('\\')) { throw '请将启动器放在本机磁盘后再操作。' }
    $item = $File
    while ($item) {
        if (Test-Path -LiteralPath $item) {
            if ((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "路径包含符号链接或目录联接，已停止：$item"
            }
        }
        $item = [IO.Path]::GetDirectoryName($item)
    }
}

function Get-PclVersion([string] $File) {
    if ([IO.Path]::GetExtension($File) -ine '.exe') { throw '请选择 PCL 的 EXE 文件。' }
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($File)
    if ($info.ProductName -ne 'Plain Craft Launcher') {
        throw "无法确认这是 PCL，未做修改：$File"
    }
    $version = [version]::new($info.FileMajorPart, $info.FileMinorPart, $info.FileBuildPart, $info.FilePrivatePart)
    if ($version.Major -ne 2) { throw "尚未验证此版本，已停止：$version" }
    return $version
}

function Resolve-PclLauncher([string] $InputPath) {
    if (-not $InputPath) {
        Add-Type -AssemblyName System.Windows.Forms
        $dialog = New-Object Windows.Forms.OpenFileDialog
        try {
            $dialog.Title = '请选择正在使用的 PCL 启动器 EXE'
            $dialog.Filter = 'PCL 启动器 (*.exe)|*.exe'
            if ($dialog.ShowDialog() -ne [Windows.Forms.DialogResult]::OK) { throw '已取消，未做修改。' }
            $InputPath = $dialog.FileName
        } finally { $dialog.Dispose() }
    }
    $resolved = (Resolve-Path -LiteralPath $InputPath).ProviderPath
    if ([IO.Directory]::Exists($resolved)) {
        $candidates = @(Get-ChildItem -LiteralPath $resolved -Filter '*.exe' -File | Where-Object {
            [Diagnostics.FileVersionInfo]::GetVersionInfo($_.FullName).ProductName -eq 'Plain Craft Launcher'
        })
        if ($candidates.Count -ne 1) { throw '该目录没有唯一的 PCL 启动器，请直接指定 EXE 文件。' }
        $resolved = $candidates[0].FullName
    }
    Assert-PclPlainPath $resolved
    $null = Get-PclVersion $resolved
    return $resolved
}

function Assert-PclStopped([string] $Launcher, [switch] $SkipFileProbe) {
    $root = [IO.Path]::GetDirectoryName($Launcher).TrimEnd('\') + '\'
    $name = [IO.Path]::GetFileName($Launcher)
    foreach ($process in Get-CimInstance Win32_Process) {
        if ($process.ProcessId -eq $PID) { continue }
        $executable = [string] $process.ExecutablePath
        $command = [string] $process.CommandLine
        $inside = $executable -and $executable.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
        $updater = $command.Contains('--update') -and $command.IndexOf($Launcher, [StringComparison]::OrdinalIgnoreCase) -ge 0
        $unreadable = -not $executable -and ($process.Name -ieq $name -or $process.Name -ieq 'Plain Craft Launcher 2.exe')
        if ($inside -or $updater -or $unreadable) {
            throw "请先关闭 PCL 及其更新程序，然后重试。进程：$($process.Name)，PID：$($process.ProcessId)"
        }
    }
    # 正在运行的 EXE、只读文件和缺少写权限都会在这里提前失败。
    if (-not $SkipFileProbe) {
        $stream = [IO.File]::Open($Launcher, 'Open', 'ReadWrite', 'None')
        $stream.Dispose()
    }
}

function Get-PclConfigBytes([byte[]] $Bytes) {
    $offset = 0
    $encoding = [Text.UTF8Encoding]::new($false, $true)
    if ($Bytes.Length -ge 4 -and [BitConverter]::ToString($Bytes, 0, 4) -in @('FF-FE-00-00', '00-00-FE-FF')) {
        throw '暂不处理 UTF-32 配置文件，原文件未修改。'
    } elseif ($Bytes.Length -ge 3 -and [BitConverter]::ToString($Bytes, 0, 3) -eq 'EF-BB-BF') {
        $offset = 3
    } elseif ($Bytes.Length -ge 2 -and [BitConverter]::ToString($Bytes, 0, 2) -eq 'FF-FE') {
        $offset = 2; $encoding = [Text.UnicodeEncoding]::new($false, $false, $true)
    } elseif ($Bytes.Length -ge 2 -and [BitConverter]::ToString($Bytes, 0, 2) -eq 'FE-FF') {
        $offset = 2; $encoding = [Text.UnicodeEncoding]::new($true, $false, $true)
    }
    try {
        $text = $encoding.GetString($Bytes, $offset, $Bytes.Length - $offset)
    } catch {
        if ($offset -ne 0) { throw }
        $encoding = [Text.Encoding]::GetEncoding([Text.Encoding]::Default.CodePage,
            [Text.EncoderExceptionFallback]::new(), [Text.DecoderExceptionFallback]::new())
        $text = $encoding.GetString($Bytes)
    }
    if ($text.Contains([string][char]0)) { throw '配置文件含有无法识别的空字符，原文件未修改。' }
    $pattern = '(?m)(?:^|(?<=\r))SystemSystemUpdate:[^\r\n]*'
    if ([regex]::IsMatch($text, $pattern)) {
        $updated = [regex]::Replace($text, $pattern, 'SystemSystemUpdate:3')
    } else {
        $newline = "`r`n"
        $match = [regex]::Match($text, '\r\n|\n|\r')
        if ($match.Success) { $newline = $match.Value }
        $separator = ''
        if ($text.Length -gt 0 -and -not $text.EndsWith("`n") -and -not $text.EndsWith("`r")) { $separator = $newline }
        $updated = $text + $separator + 'SystemSystemUpdate:3' + $newline
    }
    $body = $encoding.GetBytes($updated)
    $result = [byte[]]::new($offset + $body.Length)
    if ($offset) { [Array]::Copy($Bytes, 0, $result, 0, $offset) }
    [Array]::Copy($body, 0, $result, $offset, $body.Length)
    return ,$result
}

function Get-PclRollback([string] $Archive, [string] $WorkFolder) {
    if ($Archive) {
        $Archive = (Resolve-Path -LiteralPath $Archive).ProviderPath
    } else {
        $Archive = Join-Path $WorkFolder 'PCL-2.14.0.0.zip'
        Write-Host '正在下载固定的官方历史版本 2.14.0.0……'
        $previousTls = [Net.ServicePointManager]::SecurityProtocol
        try {
            [Net.ServicePointManager]::SecurityProtocol = $previousTls -bor [Net.SecurityProtocolType]::Tls12
            Invoke-WebRequest -Uri $script:ArchiveUrl -OutFile $Archive -UseBasicParsing -TimeoutSec 120
        } finally { [Net.ServicePointManager]::SecurityProtocol = $previousTls }
    }
    if ((Get-PclHash $Archive) -ne $script:ArchiveHash) { throw '旧版压缩包 SHA-256 不符，未替换启动器。' }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $zip = [IO.Compression.ZipFile]::OpenRead($Archive)
    $destination = Join-Path $WorkFolder 'PCL-2.14.0.0.exe'
    try {
        if ($zip.Entries.Count -ne 1 -or $zip.Entries[0].FullName -cne 'Plain Craft Launcher 2.exe') {
            throw '压缩包内容不符合预期。'
        }
        [IO.Compression.ZipFileExtensions]::ExtractToFile($zip.Entries[0], $destination, $false)
    } finally { $zip.Dispose() }
    if ((Get-PclHash $destination) -ne $script:LauncherHash -or (Get-PclVersion $destination) -ne [version]'2.14.0.0') {
        throw '旧版 EXE 校验失败，未替换启动器。'
    }
    return $destination
}

function Invoke-PclTransaction([string] $Launcher, [object[]] $Changes, [string] $Operation) {
    Assert-PclStopped $Launcher
    $root = [IO.Path]::GetDirectoryName($Launcher)
    $backupRoot = Join-Path $root 'PCL-Backups'
    Assert-PclPlainPath $backupRoot
    $backup = Join-Path $backupRoot ((Get-Date -Format 'yyyyMMdd-HHmmss') + '-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($backup)
    Write-Host "备份目录：$backup"
    $records = @()
    $applied = @()
    $locks = @()
    try {
        foreach ($change in $Changes) {
            Assert-PclPlainPath $change.Target
            if ([IO.File]::Exists($change.Target)) {
                # 允许读取和原子替换，阻止其他程序在备份与替换之间写入原文件。
                $locks += [IO.File]::Open($change.Target, 'Open', 'Read', ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
            }
        }
        foreach ($change in $Changes) {
            Assert-PclPlainPath $change.Target
            if ((Get-PclHash $change.Target) -ne $change.BeforeHash) { throw "文件已被其他程序改变，已停止：$($change.Target)" }
            $original = Join-Path $backup $change.BackupName
            if ($null -ne $change.BeforeHash) {
                [IO.File]::Copy($change.Target, $original, $false)
                if ((Get-PclHash $original) -ne $change.BeforeHash) { throw '原文件备份校验失败。' }
            }
            $records += [ordered]@{
                Target = $change.Target; BackupName = $change.BackupName
                BeforeHash = $change.BeforeHash; AfterHash = Get-PclHash $change.Stage
            }
        }
        $manifest = [ordered]@{ Schema = 1; Launcher = $Launcher; Operation = $Operation; Files = $records }
        [IO.File]::WriteAllText((Join-Path $backup 'manifest.json'), ($manifest | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($true))
        Assert-PclStopped $Launcher -SkipFileProbe
        for ($i = 0; $i -lt $Changes.Count; $i++) {
            $change = $Changes[$i]
            if ((Get-PclHash $change.Target) -ne $change.BeforeHash) { throw "文件在替换前发生变化：$($change.Target)" }
            if ((Get-PclHash $change.Stage) -ne $records[$i].AfterHash) { throw '暂存文件发生变化，已停止。' }
            if ($null -ne $change.BeforeHash) {
                [IO.File]::Replace($change.Stage, $change.Target, [NullString]::Value)
            } else {
                [IO.File]::Move($change.Stage, $change.Target)
            }
            $applied += $i
            if ((Get-PclHash $change.Target) -ne $records[$i].AfterHash) { throw '写入后的校验失败。' }
        }
        Write-Host '操作完成。原文件已完整备份，游戏文件未修改。' -ForegroundColor Green
        if ($env:PCL_MAINTENANCE_ENTRY) {
            Write-Host ('恢复命令（PowerShell）：& "{0}" -RestoreBackup "{1}"' -f $env:PCL_MAINTENANCE_ENTRY, $backup)
        } else {
            Write-Host ('恢复命令：powershell -NoProfile -ExecutionPolicy Bypass -File "{0}" -RestoreBackup "{1}"' -f $PSCommandPath, $backup)
        }
        return $backup
    } catch {
        $failure = $_
        foreach ($i in @($applied | Sort-Object -Descending)) {
            $change = $Changes[$i]
            try {
                if ((Get-PclHash $change.Target) -ne $records[$i].AfterHash) { throw '目标再次发生变化，请从备份手动恢复。' }
                if ($null -ne $change.BeforeHash) {
                    $recovery = $change.Target + '.' + [guid]::NewGuid().ToString('N') + '.recovery'
                    [IO.File]::Copy((Join-Path $backup $change.BackupName), $recovery, $false)
                    [IO.File]::Replace($recovery, $change.Target, [NullString]::Value)
                } else {
                    # 仅删除本次创建且校验未变的新文件，不删除任何原有文件。
                    [IO.File]::Delete($change.Target)
                }
            } catch { Write-Warning "自动恢复未完成：$_；完整原文件保留在 $backup" }
        }
        throw $failure
    } finally {
        foreach ($lock in $locks) { $lock.Dispose() }
    }
}

function Invoke-PclMaintenance {
    if ($env:OS -ne 'Windows_NT') { throw '此脚本需要在 Windows PowerShell 中运行。' }
    $restore = $null
    if ($RestoreBackup) {
        $folder = (Resolve-Path -LiteralPath $RestoreBackup).ProviderPath
        $restore = [IO.File]::ReadAllText((Join-Path $folder 'manifest.json')) | ConvertFrom-Json
        if ($restore.Schema -ne 1) { throw '无法识别此备份。' }
        $launcher = Resolve-PclLauncher $restore.Launcher
    } else { $launcher = Resolve-PclLauncher $Path }
    $version = Get-PclVersion $launcher
    $root = [IO.Path]::GetDirectoryName($launcher)
    $config = Join-Path $root 'PCL\Setup.ini'
    Assert-PclPlainPath $config
    Assert-PclStopped $launcher
    Write-Host "启动器：$launcher"
    Write-Host "检测版本：$version"
    if (-not $restore -and $version -gt [version]'2.99.0.0') { throw '高于已核对的 2.99.0.0，停止自动回退，请先确认版本。' }
    $rollback = -not $restore -and $version -eq [version]'2.99.0.0'
    $action = '关闭启动器更新'
    if ($rollback) { $action = '备份并回退到 2.14.0.0，同时关闭更新' }
    if ($restore) { $action = '保留当前文件的备份，再恢复所选备份（可能重新开启更新）' }
    Write-Host "处理方案：$action"
    if (-not $PSCmdlet.ShouldProcess($launcher, $action)) { return }

    $work = Join-Path $root ('.pcl-maintenance-' + [guid]::NewGuid().ToString('N'))
    $null = [IO.Directory]::CreateDirectory($work)
    $changes = @()
    try {
        if ($restore) {
            foreach ($record in $restore.Files) {
                if ($record.Target -cne $launcher -and $record.Target -cne $config) { throw '备份包含非预期的目标路径。' }
                $expectedName = 'Setup.ini.original'
                if ($record.Target -ceq $launcher) { $expectedName = 'Launcher.exe.original' }
                if ($record.BackupName -cne $expectedName) { throw '备份文件名不符合预期。' }
                if ($null -eq $record.BeforeHash) {
                    Write-Host '原先不存在的配置文件将保留，避免删除当前内容。'
                    continue
                }
                $original = Join-Path $folder $record.BackupName
                if ((Get-PclHash $original) -ne $record.BeforeHash) { throw '备份文件校验失败。' }
                $stage = Join-Path $work $record.BackupName
                [IO.File]::Copy($original, $stage, $false)
                $changes += [pscustomobject]@{ Target = $record.Target; Stage = $stage; BackupName = $expectedName; BeforeHash = Get-PclHash $record.Target }
            }
        } else {
            $configHash = Get-PclHash $config
            $bytes = [byte[]]::new(0)
            if ($null -ne $configHash) { $bytes = [IO.File]::ReadAllBytes($config) }
            $newBytes = Get-PclConfigBytes $bytes
            $configStage = Join-Path $work 'Setup.ini'
            [IO.File]::WriteAllBytes($configStage, $newBytes)
            if ((Get-PclHash $configStage) -ne $configHash) {
                $changes += [pscustomobject]@{ Target = $config; Stage = $configStage; BackupName = 'Setup.ini.original'; BeforeHash = $configHash }
            }
            if ($rollback) {
                $launcherHash = Get-PclHash $launcher
                $oldLauncher = Get-PclRollback $RollbackArchive $work
                $changes += [pscustomobject]@{ Target = $launcher; Stage = $oldLauncher; BackupName = 'Launcher.exe.original'; BeforeHash = $launcherHash }
            }
        }
        if ($changes.Count -eq 0) { Write-Host '无需修改：更新已关闭，或所选备份没有需要恢复的原文件。'; return }
        # 下载、校验、备份均完成后才替换；新配置总是先于 EXE 写入。
        $null = [IO.Directory]::CreateDirectory((Join-Path $root 'PCL'))
        $sha = [Security.Cryptography.SHA256]::Create()
        try { $key = [BitConverter]::ToString($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($launcher.ToLowerInvariant()))).Replace('-', '') }
        finally { $sha.Dispose() }
        $mutex = [Threading.Mutex]::new($false, ('Local\PCLMaintenance-' + $key))
        $acquired = $false
        try {
            try { $acquired = $mutex.WaitOne(0) }
            catch [Threading.AbandonedMutexException] { $acquired = $true }
            if (-not $acquired) { throw '另一个脚本正在处理此启动器，请稍后重试。' }
            $null = Invoke-PclTransaction $launcher $changes $action
        } finally {
            if ($acquired) { $mutex.ReleaseMutex() }
            $mutex.Dispose()
        }
    } finally {
        # work 为本次新建的唯一目录，从不清理用户目录或用户提供的压缩包。
        if ([IO.Directory]::Exists($work)) { Remove-Item -LiteralPath $work -Recurse -Force }
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    try { Invoke-PclMaintenance } catch { Write-Error -ErrorRecord $_ -ErrorAction Continue; exit 1 }
}
