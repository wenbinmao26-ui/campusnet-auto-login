[CmdletBinding()]
param([string]$TaskName='CampusNet Auto Login',[switch]$ReuseCredential,[switch]$NoTest)
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$install=Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin'
$credentialPath=Join-Path $install 'credential.xml'
$runner=Join-Path $install 'CampusNet-AutoLogin.ps1'
$wrapper=Join-Path $install 'Run-CampusNet-Hidden.vbs'
$statePath=Join-Path $install 'state.json'
$files=@('CampusNet-AutoLogin.ps1','Run-CampusNet-Hidden.vbs')
foreach ($name in $files) {
    $source=Join-Path $PSScriptRoot $name
    if (-not (Test-Path -LiteralPath $source)) { throw "Missing package file: $name" }
    if ([IO.File]::ReadAllText($source) -match '[^\x00-\x7f]') { throw "Runtime source must be ASCII: $name" }
}
$null=[scriptblock]::Create([IO.File]::ReadAllText((Join-Path $PSScriptRoot $files[0])))
$null=New-Item -ItemType Directory -Path $install -Force
if ($ReuseCredential -and -not (Test-Path -LiteralPath $credentialPath)) { throw 'No saved credential. Run the installer interactively.' }
if (-not $ReuseCredential -and (Test-Path -LiteralPath $credentialPath)) {
    $ReuseCredential=(Read-Host 'Reuse saved campus credentials? (Y/n)') -notmatch '^[Nn]$'
}
if ($ReuseCredential) {
    $saved=Import-Clixml -LiteralPath $credentialPath
    if ($saved -isnot [System.Management.Automation.PSCredential]) { throw 'Invalid saved credential.' }
    $saved=$null
}
else {
    $username=Read-Host 'Campus username'
    $password=Read-Host 'Campus password' -AsSecureString
    if (-not $username.Trim() -or $password.Length -eq 0) { throw 'Username and password are required.' }
    $credential=New-Object System.Management.Automation.PSCredential($username.Trim(),$password)
    $credential | Export-Clixml -LiteralPath $credentialPath -Force
    if (Test-Path -LiteralPath $statePath) { Move-Item -LiteralPath $statePath -Destination (Join-Path $install ('state-before-credential-change-'+(Get-Date -Format 'yyyyMMddHHmmss')+'.json')) }
}
$credentialHash=(Get-FileHash -LiteralPath $credentialPath).Hash
$backup=Join-Path $install ('backups\'+(Get-Date -Format 'yyyyMMdd-HHmmss'))
$null=New-Item -ItemType Directory -Path $backup -Force
$oldTask=Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
$oldXml=$null
if ($oldTask) {
    $oldXml=Export-ScheduledTask -TaskName $TaskName
    [IO.File]::WriteAllText((Join-Path $backup 'task.xml'),$oldXml,[Text.Encoding]::Unicode)
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    if ($oldTask.State -eq 'Running') {
        $deadline=(Get-Date).AddSeconds(90)
        do { Start-Sleep -Seconds 1; $running=(Get-ScheduledTask -TaskName $TaskName).State -eq 'Running' } while ($running -and (Get-Date) -lt $deadline)
        if ($running) { Enable-ScheduledTask -TaskName $TaskName | Out-Null; throw 'Existing authentication is still running; no files replaced.' }
    }
}
foreach ($name in @('CampusNet-AutoLogin.ps1','Run-CampusNet-Hidden.vbs','state.json')) {
    $path=Join-Path $install $name
    if (Test-Path -LiteralPath $path) { Copy-Item -LiteralPath $path -Destination (Join-Path $backup $name) }
}
try {
    foreach ($name in $files) {
        $source=Join-Path $PSScriptRoot $name
        $dest=Join-Path $install $name
        Copy-Item -LiteralPath $source -Destination $dest -Force
        if ((Get-FileHash -LiteralPath $source).Hash -ne (Get-FileHash -LiteralPath $dest).Hash) { throw 'Installed file hash mismatch.' }
    }
    $identity=[Security.Principal.WindowsIdentity]::GetCurrent().Name
    $action=New-ScheduledTaskAction -Execute (Join-Path $env:WINDIR 'System32\wscript.exe') -Argument ('//B //Nologo "'+$wrapper+'"') -WorkingDirectory $install
    $triggers=@(
        (New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(1) -RepetitionInterval (New-TimeSpan -Minutes 1)),
        (New-ScheduledTaskTrigger -AtLogOn -User $identity)
    )
    $settings=New-ScheduledTaskSettingsSet -StartWhenAvailable -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -Hidden -ExecutionTimeLimit (New-TimeSpan -Minutes 4) -MultipleInstances IgnoreNew
    $principal=New-ScheduledTaskPrincipal -UserId $identity -LogonType Interactive -RunLevel Limited
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $triggers -Settings $settings -Principal $principal -Description 'CampusNet v3: check every minute, reauthenticate every 12 hours, validate execution receipts.' -Force | Out-Null
    if ((Get-FileHash -LiteralPath $credentialPath).Hash -ne $credentialHash) { throw 'Credential unexpectedly changed.' }
}
catch {
    foreach ($name in $files) { if (Test-Path -LiteralPath (Join-Path $backup $name)) { Copy-Item -LiteralPath (Join-Path $backup $name) -Destination (Join-Path $install $name) -Force } }
    if ($oldXml) { Register-ScheduledTask -TaskName $TaskName -Xml $oldXml -Force | Out-Null }
    throw
}
Write-Host "Installed v3. Backup: $backup"
Write-Host 'Checks run every minute while this Windows user is logged in (including the lock screen).'
if (-not $NoTest) {
    $before=Get-Date
    Start-ScheduledTask -TaskName $TaskName
    $deadline=$before.AddSeconds(180)
    do { Start-Sleep -Seconds 1; $task=Get-ScheduledTask -TaskName $TaskName; $info=Get-ScheduledTaskInfo -TaskName $TaskName } while (($info.LastRunTime -lt $before.AddSeconds(-1) -or $task.State -eq 'Running') -and (Get-Date) -lt $deadline)
    $receiptPath=Join-Path $install 'last-run.json'
    if (-not (Test-Path -LiteralPath $receiptPath)) { throw 'No execution receipt. Check launcher.log.' }
    $receipt=Get-Content -LiteralPath $receiptPath -Raw | ConvertFrom-Json
    if (-not $receipt.completed -or ([DateTimeOffset]::Parse($receipt.startedUtc).LocalDateTime -lt $before.AddSeconds(-1))) { throw 'No fresh completed receipt.' }
    if ($info.LastTaskResult -ne 0 -or $receipt.exitCode -ne 0) { throw "Background validation failed: $($receipt.outcome). Check campusnet.log." }
    Write-Host "Background task verified: $($receipt.outcome), run=$($receipt.runId)"
}
