#requires -Version 5.1
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$source = Join-Path $root 'Protect-PCL.ps1'
$destination = Join-Path $root 'Protect-PCL.cmd'
# CMD 只负责提取嵌入源码并启动本次 PowerShell 进程，不修改系统执行策略。
# 使用环境变量传递路径，避免把文件名插入 PowerShell 代码；CreateNew 防止覆盖临时文件。
$header = @'
@echo off
setlocal
set "PCL_MAINTENANCE_ENTRY=%~f0"
set "PCL_MAINTENANCE_PAYLOAD=%TEMP%\PCL-Maintenance-%RANDOM%-%RANDOM%.ps1"
powershell.exe -NoProfile -ExecutionPolicy Bypass -Command "$text=[IO.File]::ReadAllText($env:PCL_MAINTENANCE_ENTRY); $mark=':PCL_POWERSHELL_PAYLOAD'; $index=$text.LastIndexOf($mark); if($index -lt 0){exit 1}; $bytes=[Convert]::FromBase64String($text.Substring($index+$mark.Length)); $file=[IO.File]::Open($env:PCL_MAINTENANCE_PAYLOAD,'CreateNew','Write','None'); try{$file.Write($bytes,0,$bytes.Length)}finally{$file.Dispose()}"
if errorlevel 1 goto pcl_extract_failed
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%PCL_MAINTENANCE_PAYLOAD%" %*
set "pcl_exit_code=%errorlevel%"
del /q "%PCL_MAINTENANCE_PAYLOAD%" >nul 2>&1
goto pcl_finish
:pcl_extract_failed
echo Could not prepare the embedded script. No launcher files were changed.
set "pcl_exit_code=1"
:pcl_finish
echo.
if not defined PCL_MAINTENANCE_NO_PAUSE pause
exit /b %pcl_exit_code%
:PCL_POWERSHELL_PAYLOAD
'@
$base64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($source), [Base64FormattingOptions]::InsertLineBreaks)
$content = $header.Replace("`r`n", "`n").Replace("`n", "`r`n") + "`r`n" + $base64 + "`r`n"
[IO.File]::WriteAllText($destination, $content, [Text.Encoding]::ASCII)
Write-Host "已生成独立入口：$destination"
