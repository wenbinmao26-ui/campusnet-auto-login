[CmdletBinding()]
param(
    [string]$CredentialPath = (Join-Path $env:LOCALAPPDATA 'CampusNetAutoLogin\credential.xml'),
    [string]$DataDirectory = '',
    [switch]$ForceReauth,
    [switch]$SkipLogout,
    [ValidateRange(1,168)][int]$ReauthIntervalHours = 12,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')][string]$RunId = ([guid]::NewGuid().ToString('N'))
)
# ASCII source is intentional for Windows PowerShell 5.1 compatibility.
Set-StrictMode -Version Latest
$ErrorActionPreference='Stop'
$Version='3.0.0'
if (-not $DataDirectory) { $DataDirectory=Split-Path -Parent $CredentialPath }
$StatePath=Join-Path $DataDirectory 'state.json'
$ReceiptPath=Join-Path $DataDirectory 'last-run.json'
$LogPath=Join-Path $DataDirectory 'campusnet.log'
$PortalPage='http://2.2.2.3/ac_portal/20210120210326/pc.html?template=20210120210326&tabs=pwd&vlanid=0'
$LoginEndpoint='http://2.2.2.3/ac_portal/login.php'

function Write-CampusLog {
    param([string]$Event,[string]$Detail='')
    if ((Test-Path -LiteralPath $LogPath) -and (Get-Item -LiteralPath $LogPath).Length -gt 2MB) {
        Move-Item -LiteralPath $LogPath -Destination "$LogPath.previous" -Force
    }
    $line='{0} [{1}] run={2} {3}' -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'),$Event,$RunId,($Detail -replace '[\r\n]+',' ')
    Add-Content -LiteralPath $LogPath -Value $line -Encoding UTF8
    Write-Host $line
}
function Write-AtomicJson {
    param([string]$Path,[object]$Value)
    $temp="$Path.$PID.tmp"
    try {
        [IO.File]::WriteAllText($temp,(ConvertTo-Json -InputObject $Value -Depth 6),(New-Object Text.UTF8Encoding($false)))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temp,$Path,[NullString]::Value) }
        else { [IO.File]::Move($temp,$Path) }
    }
    finally { if ([IO.File]::Exists($temp)) { [IO.File]::Delete($temp) } }
}
function Read-CampusState {
    $value=@{version=3;lastAuthUnix=0L;lastVerifiedUnix=0L;nextRetryUnix=0L;failures=0;blockedCredentialHash=''}
    if (-not (Test-Path -LiteralPath $StatePath)) { return $value }
    try {
        $loaded=Get-Content -LiteralPath $StatePath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($key in @('lastAuthUnix','lastVerifiedUnix','nextRetryUnix')) {
            if ($loaded.PSObject.Properties[$key]) {
                $number=[long]$loaded.$key
                if ($number -lt 0) { throw 'Invalid timestamp' }
                $value[$key]=$number
            }
        }
        if ($loaded.PSObject.Properties['failures']) { $value.failures=[math]::Max(0,[math]::Min(20,[int]$loaded.failures)) }
        if ($loaded.PSObject.Properties['blockedCredentialHash']) { $value.blockedCredentialHash=[string]$loaded.blockedCredentialHash }
        if ($value.lastAuthUnix -eq 0 -and $loaded.PSObject.Properties['lastSuccessfulAuthUtc']) {
            $raw=$loaded.lastSuccessfulAuthUtc
            $date=if ($raw -is [datetime]) { [DateTimeOffset]$raw } else { [DateTimeOffset]::Parse([string]$raw,[Globalization.CultureInfo]::InvariantCulture) }
            $value.lastAuthUnix=$date.ToUnixTimeSeconds()
        }
    }
    catch { Write-CampusLog 'STATE_INVALID' 'Rebuilding authentication state.' }
    return $value
}
function Get-AuthDecision {
    param([hashtable]$State,[long]$Now,[string]$CredentialHash,[bool]$Forced,[int]$IntervalHours)
    if ($Forced) { return 'manual' }
    if ($State.blockedCredentialHash -and $State.blockedCredentialHash -eq $CredentialHash) { return 'credential-blocked' }
    if ($State.nextRetryUnix -gt $Now -and $State.nextRetryUnix -le ($Now+900)) { return 'backoff' }
    if ($State.lastAuthUnix -le 0) { return 'first-run' }
    if ($State.lastAuthUnix -gt ($Now+300)) { return 'clock-reset' }
    if (($Now-$State.lastAuthUnix) -ge ($IntervalHours*3600)) { return 'interval' }
    return 'check'
}
function Get-CredentialFingerprint {
    $stream=$null;$sha=[Security.Cryptography.SHA256]::Create()
    try {
        $stream=[IO.File]::OpenRead($CredentialPath)
        return ([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','')
    }
    finally { if ($stream) { $stream.Dispose() }; $sha.Dispose() }
}
function New-DirectClient {
    Add-Type -AssemblyName System.Net.Http
    $handler=New-Object System.Net.Http.HttpClientHandler
    $handler.UseProxy=$false; $handler.AllowAutoRedirect=$false
    $client=New-Object System.Net.Http.HttpClient($handler)
    $client.Timeout=[TimeSpan]::FromSeconds(8)
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('User-Agent','CampusNetAutoLogin/3.0')
    [void]$client.DefaultRequestHeaders.TryAddWithoutValidation('Cache-Control','no-cache')
    return $client
}
function Invoke-CampusHttp {
    param([object]$Client,[string]$Uri,[hashtable]$Form)
    $response=$null; $body=$null
    try {
        if ($null -ne $Form) {
            $pairs=foreach ($key in $Form.Keys) { '{0}={1}' -f [uri]::EscapeDataString($key),[uri]::EscapeDataString([string]$Form[$key]) }
            $body=New-Object System.Net.Http.StringContent(($pairs -join '&'),[Text.Encoding]::UTF8,'application/x-www-form-urlencoded')
            $response=$Client.PostAsync($Uri,$body).GetAwaiter().GetResult()
        }
        else { $response=$Client.GetAsync($Uri).GetAwaiter().GetResult() }
        return [pscustomobject]@{Code=[int]$response.StatusCode;Text=$response.Content.ReadAsStringAsync().GetAwaiter().GetResult()}
    }
    finally { if ($response) { $response.Dispose() }; if ($body) { $body.Dispose() } }
}
function Test-ExpectedPortal {
    param([string]$Html)
    return ($Html -match 'id=["'']password_name["'']' -and $Html -match 'id=["'']password_pwd["'']' -and $Html -match 'onPwdLogin\(\)')
}
function Test-InternetConnectivity {
    param([object]$Client)
    # Online probes never suppress the periodic authentication deadline.
    $probes=@(
        @{Uri='http://www.msftconnecttest.com/connecttest.txt';Code=200;Pattern='^Microsoft Connect Test\s*$'},
        @{Uri='https://www.baidu.com/';Code=200;Pattern='<html'},
        @{Uri='http://connectivitycheck.gstatic.com/generate_204';Code=204;Pattern='^\s*$'}
    )
    $success=0
    foreach ($probe in $probes) {
        try {
            $reply=Invoke-CampusHttp $Client ($probe.Uri+'?t='+[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds())
            if ($reply.Code -eq $probe.Code -and $reply.Text -match $probe.Pattern) { $success++ }
            if ($success -ge 2) { return $true }
        }
        catch { }
    }
    return $false
}
function ConvertTo-PortalRc4Hex {
    param([string]$Text,[string]$KeyText)
    $source=$Text.Trim(); $box=New-Object 'System.Int32[]' 256
    for ($i=0;$i -lt 256;$i++) { $box[$i]=$i }
    $j=0
    for ($i=0;$i -lt 256;$i++) {
        $j=($j+$box[$i]+[int][char]$KeyText[$i % $KeyText.Length]) % 256
        $tmp=$box[$i];$box[$i]=$box[$j];$box[$j]=$tmp
    }
    $a=0;$b=0;$result=New-Object Text.StringBuilder
    foreach ($ch in $source.ToCharArray()) {
        $a=($a+1) % 256;$b=($b+$box[$a]) % 256
        $tmp=$box[$a];$box[$a]=$box[$b];$box[$b]=$tmp
        [void]$result.Append((([int]$ch) -bxor $box[($box[$a]+$box[$b]) % 256]).ToString('x2'))
    }
    return $result.ToString()
}
function Invoke-PortalLogin {
    param([object]$Client,[System.Management.Automation.PSCredential]$Credential)
    $pointer=[IntPtr]::Zero; $password=$null; $form=$null
    try {
        $pointer=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($Credential.Password)
        $password=[Runtime.InteropServices.Marshal]::PtrToStringBSTR($pointer)
        $tag=[DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds().ToString()
        $form=@{opr='pwdLogin';userName=$Credential.UserName;pwd=(ConvertTo-PortalRc4Hex $password $tag);auth_tag=$tag;rememberPwd='0'}
        $reply=Invoke-CampusHttp $Client $LoginEndpoint $form
        if ($reply.Code -ne 200) { throw 'Unexpected HTTP status' }
        $parsed=$reply.Text.Trim().TrimStart([char]0xFEFF) | ConvertFrom-Json
        $property=$parsed.PSObject.Properties['success']
        if ($null -eq $property -or $property.Value -isnot [bool]) { throw 'Invalid portal response' }
        return $property.Value
    }
    finally {
        $password=$null; $form=$null
        if ($pointer -ne [IntPtr]::Zero) { [Runtime.InteropServices.Marshal]::ZeroFreeBSTR($pointer) }
    }
}
function Invoke-CampusCycle {
    param([hashtable]$State,[object]$Client)
    if (-not (Test-Path -LiteralPath $CredentialPath)) { $script:Outcome='credential-missing';return 10 }
    $hash=Get-CredentialFingerprint
    $decision=Get-AuthDecision $State ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) $hash ([bool]$ForceReauth) $ReauthIntervalHours
    $script:Reason=$decision
    if ($decision -eq 'credential-blocked') { $script:Outcome=$decision;return 31 }
    if ($decision -eq 'backoff') { $script:Outcome=$decision;return 40 }
    if ($decision -eq 'check') {
        if (Test-InternetConnectivity $Client) {
            $State.lastVerifiedUnix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $State.failures=0;$State.nextRetryUnix=0L;$script:Outcome='online';return 0
        }
        Start-Sleep -Seconds 2
        if (Test-InternetConnectivity $Client) { $script:Outcome='online';return 0 }
        $script:Reason='offline'
    }
    try {
        $credential=Import-Clixml -LiteralPath $CredentialPath
        if ($credential -isnot [System.Management.Automation.PSCredential]) { throw 'Invalid credential type' }
    }
    catch { $script:Outcome='credential-unreadable';return 11 }
    Write-CampusLog 'AUTH_START' ('reason='+$script:Reason)
    $logoutAttempted=$false
    for ($attempt=1;$attempt -le 3;$attempt++) {
        try {
            $page=Invoke-CampusHttp $Client $PortalPage
            if ($page.Code -ne 200 -or -not (Test-ExpectedPortal $page.Text)) { $script:Outcome='portal-mismatch';return 21 }
            # Clear a session only once on a scheduled/manual renewal, never on offline retries.
            if ($script:Reason -ne 'offline' -and -not $SkipLogout -and -not $logoutAttempted) {
                $logoutAttempted=$true
                try { $null=Invoke-CampusHttp $Client $LoginEndpoint @{opr='logout'} }
                catch { Write-CampusLog 'LOGOUT_UNCONFIRMED' 'Continuing with login.' }
                Start-Sleep -Seconds 2
            }
            if (-not (Invoke-PortalLogin $Client $credential)) {
                $State.blockedCredentialHash=$hash;$script:Outcome='portal-rejected'
                Write-CampusLog 'AUTH_REJECTED' 'Automatic login paused until credentials change or a manual retry.'
                return 31
            }
            $State.lastAuthUnix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $State.blockedCredentialHash='';$State.failures=0;$State.nextRetryUnix=0L
            Write-AtomicJson $StatePath $State
            Write-CampusLog 'AUTH_ACCEPTED' ('nextDue='+[DateTimeOffset]::FromUnixTimeSeconds($State.lastAuthUnix).AddHours($ReauthIntervalHours).ToLocalTime().ToString('yyyy-MM-dd HH:mm:ss'))
            foreach ($delay in @(3,5)) {
                Start-Sleep -Seconds $delay
                if (Test-InternetConnectivity $Client) {
                    $State.lastVerifiedUnix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
                    $script:Outcome='authenticated';return 0
                }
            }
            $script:Outcome='auth-ok-network-unverified';return 32
        }
        catch {
            Write-CampusLog 'AUTH_RETRY' ('attempt='+$attempt+' errorType='+$_.Exception.GetType().Name)
            if ($attempt -lt 3) { Start-Sleep -Seconds (3*$attempt) }
        }
    }
    $script:Outcome='portal-unreachable';return 30
}

$lock=$null;$client=$null;$state=$null
$Outcome='starting';$Reason='';$exitCode=99;$started=[DateTimeOffset]::UtcNow
try {
    $null=New-Item -ItemType Directory -Path $DataDirectory -Force
    try { $lock=[IO.File]::Open((Join-Path $DataDirectory 'run.lock'),[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None) }
    catch [IO.IOException] { exit 75 }
    Write-AtomicJson $ReceiptPath @{runId=$RunId;version=$Version;startedUtc=$started.ToString('o');completed=$false}
    Write-CampusLog 'RUN_START' ('version='+$Version)
    $state=Read-CampusState;$client=New-DirectClient
    $exitCode=Invoke-CampusCycle $state $client
    if ($exitCode -ne 0 -and $exitCode -notin @(31,40)) {
        $state.failures=[math]::Min(20,$state.failures+1)
        $state.nextRetryUnix=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+[long][math]::Min(900,60*[math]::Pow(2,[math]::Min(4,$state.failures-1)))
    }
    Write-AtomicJson $StatePath $state
}
catch {
    $exitCode=99;$Outcome='internal-error'
    try { Write-CampusLog 'ERROR' ('type='+$_.Exception.GetType().Name+' line='+$_.InvocationInfo.ScriptLineNumber) } catch { }
}
finally {
    if ($client) { $client.Dispose() }
    if ($lock) {
        try {
            $lastAuth=if ($state -and $state.lastAuthUnix -gt 0) { [DateTimeOffset]::FromUnixTimeSeconds($state.lastAuthUnix).ToString('o') } else { $null }
            Write-AtomicJson $ReceiptPath @{
                runId=$RunId;version=$Version;startedUtc=$started.ToString('o');finishedUtc=[DateTimeOffset]::UtcNow.ToString('o')
                completed=$true;exitCode=$exitCode;outcome=$Outcome;reason=$Reason;lastSuccessfulAuthUtc=$lastAuth
            }
            Write-CampusLog 'RUN_END' ('code='+$exitCode+' outcome='+$Outcome)
        }
        catch { $exitCode=98 }
        finally { $lock.Dispose() }
    }
}
exit $exitCode
