param([Parameter(Mandatory=$true)][string]$FixturePath)
$ErrorActionPreference='Stop'
$fixture=Get-Content -LiteralPath $FixturePath -Raw | ConvertFrom-Json
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1')
$script:Checks=0;$script:Started=0
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:Checks++}
# Only endpoint identity and ownership evidence are substituted. Actual probe
# processes, curl deadlines, result classification and cleanup remain in use.
$testCa=Join-Path $PSScriptRoot 'test-fixtures/web-transport/localhost-cert.pem'
$script:RealStart=[scriptblock]::Create((${function:Start-HttpEndpointProbe}.ToString().Replace('--disable --silent',('--disable --cacert "'+$testCa+'" --silent'))))
function Start-HttpEndpointProbe($Profile,[string]$Url,[bool]$Fast=$false){
    $script:Started++
    $route='/204'
    switch($script:Case.Name){
        'late' {$route='/late'}
        'early' {if($Url -ne 'https://www.google.com/generate_204'){$route='/stall'}}
        'rejected' {$route='/403'}
        'unauthenticated' {$route=$(if($Url -eq 'https://api.openai.com/v1/models'){'/401'}else{'/403'})}
        'stallTotal' {$route='/stall'}
    }
    $probe=& $script:RealStart $Profile ('https://localhost:'+$fixture.OriginPort+$route) $Fast
    # Preserve the public endpoint's response policy (including the API's 401).
    $probe.Url=$Url
    return $probe
}
function Get-Listener($Profile){if($script:OwnerReady){[pscustomobject]@{PID=123;Name='fixture'}}}
$script:OwnerReady=$true
foreach($script:Case in $fixture.Cases){
    $script:Profiles=[pscustomobject]@{Profiles=@([pscustomobject]@{Id='fixture';Name='fixture';Protocol='http';Host='127.0.0.1';Port=$script:Case.Port})}
    $clock=[Diagnostics.Stopwatch]::StartNew()
    $result=Test-ProxyRoute 'fixture' -Fast
    $elapsed=$clock.Elapsed.TotalSeconds
    Check ($result.OwnerVerified -eq $true) ($script:Case.Name+': owner remains verified')
    switch($script:Case.Name){
        'slow' {
            Check ($result.Usable -and $elapsed -ge 4 -and $elapsed -lt 7) 'Fast accepts a 4.3 second CONNECT handshake and keeps probes concurrent'
            $clock.Restart();$full=Test-HttpEndpoint (Get-Profile 'fixture') 'https://www.google.com/generate_204'
            Check ($full.Accepted -and $clock.Elapsed.TotalSeconds -ge 4) 'Full and Fast both accept the same delayed TLS tunnel'
        }
        'late' {Check ($result.Usable -and $elapsed -ge 7.5 -and $elapsed -lt 11.5) 'Fast parent allows a response beyond its old seven second deadline'}
        'early' {Check ($result.Usable -and $elapsed -lt 3 -and @($result.Results).Count -lt 3) 'Fast returns on the first accepted endpoint and closes pending probes'}
        'rejected' {Check (-not $result.Usable -and @($result.Results|Where-Object {$_.Code -eq 403 -and $_.Reachable -and -not $_.Accepted}).Count -eq 3) 'HTTP 403 stays reachable but unusable'}
        'unauthenticated' {Check ($result.Usable -and @($result.Results|Where-Object {$_.Code -eq 401 -and $_.Accepted}).Count -eq 1) 'Only the known API permits unauthenticated HTTP 401'}
        'proxyAuth' {Check (-not $result.Usable) 'Proxy authentication refusal is not usable'}
        'tlsFailure' {Check (-not $result.Usable) 'Invalid target TLS after CONNECT is not usable'}
        'stallConnect' {Check (-not $result.Usable -and $elapsed -ge 5 -and $elapsed -lt 9) 'Silent CONNECT fails within the six second connection budget'}
        'stallTotal' {Check (-not $result.Usable -and $elapsed -ge 9 -and $elapsed -lt 13) 'Silent TLS origin fails within the ten second total budget'}
    }
    Write-Output ('PASS: PowerShell '+$script:Case.Name+' '+[Math]::Round($elapsed,2)+'s')
}
$script:OwnerReady=$false;$before=$script:Started;$rejected=$false
try{Test-ProxyRoute 'fixture' -Fast | Out-Null}catch{$rejected=$true}
Check ($rejected -and $script:Started -eq $before) 'Fast refuses unknown listener ownership before launching curl'
Write-Output ('PASS: '+$script:Checks+' PowerShell probe-budget assertions')
& (Join-Path $PSScriptRoot 'Test-ScopedNetworkDiagnosis.ps1') -FixturePath $FixturePath

& (Join-Path $PSScriptRoot 'Test-ObservedProxyDiagnosis.ps1') -FixturePath $FixturePath
& (Join-Path $PSScriptRoot 'Test-ForwardingStartup.ps1') -FixturePath $FixturePath
