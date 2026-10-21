[CmdletBinding()]
param(
    [string]$TaskName = 'CampusNet Auto Login',
    [switch]$KeepCredential
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$installDirectory = Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin'
$existingTask = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if ($null -ne $existingTask) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    Write-Host "已删除计划任务：$TaskName"
}
else {
    Write-Host "未找到计划任务：$TaskName"
}

if ($KeepCredential) {
    Write-Host "已保留本机配置：$installDirectory"
}
elseif (Test-Path -LiteralPath $installDirectory) {
    $confirmedPath = [IO.Path]::GetFullPath($installDirectory)
    $expectedPath = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin'))
    if ($confirmedPath -ne $expectedPath) {
        throw "拒绝删除意外路径：$confirmedPath"
    }
    Remove-Item -LiteralPath $confirmedPath -Recurse -Force
    Write-Host '已删除加密凭据、运行脚本和日志。'
}

Write-Host '卸载完成。' -ForegroundColor Green
