$ErrorActionPreference='Stop'
$dir=Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin'
$receipt=Join-Path $dir 'last-run.json'
if (-not (Test-Path -LiteralPath $receipt)) { Write-Host 'No v3 execution receipt exists.'; exit 1 }
$r=Get-Content -LiteralPath $receipt -Raw | ConvertFrom-Json
if (-not $r.completed) { Write-Host "Check is running: $($r.runId), started $($r.startedUtc)"; exit 0 }
$finished=[DateTimeOffset]::Parse($r.finishedUtc)
[pscustomobject]@{Version=$r.version;LastCheck=$finished.LocalDateTime;MinutesSinceCheck=[math]::Round(([DateTimeOffset]::UtcNow-$finished).TotalMinutes,1);Completed=$r.completed;Result=$r.outcome;ExitCode=$r.exitCode;RunId=$r.runId} | Format-List
if ($r.lastSuccessfulAuthUtc) {
    $auth=[DateTimeOffset]::Parse($r.lastSuccessfulAuthUtc)
    [pscustomobject]@{LastAuthentication=$auth.LocalDateTime;NextAuthentication=$auth.AddHours(12).LocalDateTime} | Format-List
}
if (([DateTimeOffset]::UtcNow-$finished).TotalMinutes -gt 3) { Write-Warning 'No fresh check in the last 3 minutes. The PC may have been asleep, logged out, or the task may have failed.' }
Get-Content -LiteralPath (Join-Path $dir 'campusnet.log') -Tail 8 -Encoding UTF8
