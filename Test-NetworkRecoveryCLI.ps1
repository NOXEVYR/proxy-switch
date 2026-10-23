$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-recovery-cli-'+[Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($qa)
$build=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'Build-WindowsPackage.ps1'))
$match=[regex]::Match($build,'(?s)\$runtime=@\((.*?)\r?\n\)')
foreach($name in @([regex]::Matches($match.Groups[1].Value,"'([^']+)'")|ForEach-Object {$_.Groups[1].Value})){
    $dest=Join-Path $qa $name;[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($dest));Copy-Item -LiteralPath (Join-Path $PSScriptRoot $name) -Destination $dest
}
$data=Join-Path $qa 'data';[void][IO.Directory]::CreateDirectory($data);$config=Join-Path $data 'config.json';[IO.File]::WriteAllText($config,'{PRIVATE-corrupt-fixture')
$before=(Get-FileHash -LiteralPath $config).Hash
$guard=@'

function Get-SystemSnapshot {[pscustomobject]@{Flags=3;Server='127.0.0.1:19341';Bypass='';AutoConfigUrl=''}}
function Get-UserProxyEnv {[pscustomobject]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='fixture.invalid'}}
function Get-WindowsApplicationProxyViews {[pscustomobject]@{Registry=[pscustomobject]@{Available=$true;Enabled=$true;Server='127.0.0.1:19341'};WinHttpIE=[pscustomobject]@{Available=$true;Server='127.0.0.1:19341';AutoDetect=$false;HasPac=$false}}}
function Get-ClientInterference {[pscustomobject]@{Tun=$false;Guard=$false;Topology=[pscustomobject]@{State='NoEvidence'}}}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$true;Rows=@()}}
function Set-SystemSnapshot {throw 'FORBIDDEN Windows write'}
function Set-UserProxyEnv {throw 'FORBIDDEN environment write'}
function Write-ProfileSettings {throw 'FORBIDDEN registration write'}
function Use-ChangeLock {throw 'FORBIDDEN mutation lock in preview'}
'@
[IO.File]::AppendAllText((Join-Path $qa 'ProxyBackend.ps1'),$guard,(New-Object Text.UTF8Encoding($true)))
$failed=$false;try{. (Join-Path $qa 'ProxyBackend.ps1') -DataDirectory $data}catch{$failed=$true}
if(-not $failed){throw 'Ordinary bootstrap must not substitute empty registration'}
$report=& (Join-Path $qa 'ProxySwitch.ps1') -DataDirectory $data -RecoveryDiagnostic|ConvertFrom-Json
if($report.Code -eq 'ObservationUnavailable' -or $report.Verification.Request -ne 'NotTested'){throw 'Explicit recovery diagnostic must work without parsing registration or probing'}
$plan=& (Join-Path $qa 'ProxySwitch.ps1') -DataDirectory $data -ResetProxy|ConvertFrom-Json
if(-not $plan.CanApply -or $plan.Goal -ne 'Direct' -or $plan.PSObject.Properties['Context']){throw 'Reset CLI must return a redacted preview without private context'}
if((Get-FileHash -LiteralPath $config).Hash -cne $before -or (Test-Path (Join-Path $data 'backups')) -or (Test-Path (Join-Path $data 'recovery'))){throw 'Read-only recovery bootstrap changed registration or wrote recovery records'}
if(($report|ConvertTo-Json -Depth 10) -match 'PRIVATE-corrupt-fixture'){throw 'Report leaked corrupt content'}
Write-Output 'PASS: 5 recovery CLI bootstrap checks; isolated corrupt registration, preview only, mutation guards.'
