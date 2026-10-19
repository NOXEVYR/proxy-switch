param([Parameter(Mandatory=$true)][string]$FixturePath)
$ErrorActionPreference='Stop'
# Only the loopback fixture created by Test-ProxyProbeBudget.cjs is contacted.
$qa=Join-Path $env:TEMP ('FlowSwitch-ForwardingStartup-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$fixture=Get-Content -LiteralPath $FixturePath -Raw -Encoding UTF8|ConvertFrom-Json
$script:checks=0;$script:started=@();$script:closed=0;$script:healthFresh=$true
$script:FixtureCa=Join-Path $PSScriptRoot 'test-fixtures\web-transport\localhost-cert.pem'
$startText=${function:Start-HttpEndpointProbe}.ToString()
$script:actualStart=[scriptblock]::Create($startText.Replace('$psi.UseShellExecute=$false;','$psi.Arguments += '' --cacert "''+$script:FixtureCa+''"''; $psi.UseShellExecute=$false;'))
$script:actualClose=${function:Close-HttpEndpointProbe}
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Set-SystemSnapshot {throw 'Startup check must not write Windows settings'}
function Set-UserProxyEnv {throw 'Startup check must not write user variables'}
function Ensure-ManagedGateway {throw 'Test must not start a core'}
function Start-ManagedProgram {throw 'Test must not start a user application'}
function Get-FixtureListener([int]$Port){
    $client=New-Object Net.Sockets.TcpClient
    try{$pending=$client.BeginConnect('127.0.0.1',$Port,$null,$null);try{if(-not $pending.AsyncWaitHandle.WaitOne(1000)){return $false};$client.EndConnect($pending);return $client.Connected}finally{$pending.AsyncWaitHandle.Dispose()}}finally{$client.Close()}
}
function Start-HttpEndpointProbe($Profile,[string]$Url,[bool]$Fast=$false){
    if($Profile.Host -ne '127.0.0.1' -or $Profile.Port -ne $script:case.Port){throw 'Startup attempted an unexpected proxy'}
    $suffix=if($script:case.Name -eq 'stallTotal'){'/stall'}else{'/204'}
    $probe=& $script:actualStart $Profile ('https://localhost:'+ $fixture.OriginPort+$suffix) $Fast
    # Keep each production target's label distinct while contacting only the fixture.
    $probe.Url=$Url;$script:started+=@($probe.Process.Id);$probe
}
function Close-HttpEndpointProbe($Probe){$script:closed++;& $script:actualClose $Probe}
function Invoke-AppRouter {
    param($Request,$TimeoutMilliseconds)
    if($Request.action -ne 'status'){throw 'Only a status query is permitted'}
    $stamp=[DateTime]::UtcNow;if(-not $script:healthFresh){$stamp=$stamp.AddMinutes(-5)}
    [pscustomobject]@{available=$true;rulesAvailable=$true;programIngresses=@([pscustomobject]@{id='fixture';loaded=$true;ready=$true;effectiveRoute='upstream'});failover=[pscustomobject]@{updated=$stamp.ToString('o');health=[pscustomobject]@{upstream=$true}}}
}
foreach($name in @('stallConnect','stallTotal')){
    $script:case=@($fixture.Cases|Where-Object Name -eq $name)[0]
    if(-not $script:case){throw 'Missing fixture case'}
    Check (Get-FixtureListener $script:case.Port) ($name+': local TCP still accepts a fresh connection')
    $ingress=[pscustomobject]@{id='fixture';port=[int]$script:case.Port};$script:started=@();$script:closed=0;$launched=$false;$errorText=''
    $timer=[Diagnostics.Stopwatch]::StartNew()
    try{Wait-ManagedProgramIngressReady $ingress 1800|Out-Null;$launched=$true}catch{$errorText=$_.Exception.Message}
    Check (-not $launched -and $errorText -match '未启动程序') ($name+': listening plus fresh healthy metadata must not allow a stalled launch')
    Check ($script:started.Count -gt 0 -and $script:closed -eq $script:started.Count) ($name+': real curl probes ran and all handles were cleaned')
    Check ($timer.Elapsed.TotalSeconds -lt 6) ($name+': all stalled probes share a bounded launch deadline')
    Check (@($script:started|Where-Object {Get-Process -Id $_ -ErrorAction SilentlyContinue}).Count -eq 0) ($name+': no owned curl helper remains')
    Check (Get-FixtureListener $script:case.Port) ($name+': refusal to launch does not close the listening proxy')
}
$script:healthFresh=$false;$script:started=@();$launched=$false
try{Wait-ManagedProgramIngressReady $ingress 350|Out-Null;$launched=$true}catch{}
Check (-not $launched -and $script:started.Count -eq 0) 'A stale healthy snapshot does not authorize a request or launch'
Write-Output ('PASS: '+$script:checks+' real loopback stalled-forwarding startup checks; no application starts or Windows writes.')
