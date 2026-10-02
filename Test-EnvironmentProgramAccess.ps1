$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-env-access-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++}
function Throws([scriptblock]$Action,$Pattern){$message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message};Check ($message -match $Pattern) ('Expected '+$Pattern+', got '+$message)}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Get-SystemSnapshot {Copy-RoutingSnapshot $script:Windows}
function Get-UserProxyEnv {Copy-RoutingSnapshot $script:UserEnv}
function Set-SystemSnapshot {throw 'Real Windows write forbidden'}
function Set-UserProxyEnv {throw 'Real user environment write forbidden'}
function Get-VerifiedProgramShortcuts {throw 'Environment setup must not inspect/change desktop shortcuts'}
function Ensure-ManagedGateway([switch]$PreserveWindowsSettings){Check $PreserveWindowsSettings 'Startup preserves external settings';if($script:StartupChange){$script:Windows.Server='127.0.0.1:19999'}}
function Invoke-AppRouter($Request,[int]$TimeoutMilliseconds=55000){
    $state=Get-Content (Join-Path $qa 'app-rules.json') -Raw|ConvertFrom-Json
    if($Request.action -eq 'replace'){
        Check ($Request.expectedStateHash -ceq (Read-RuleMaintenanceFile (Join-Path $qa 'app-rules.json')).TextHash) 'Rule update binds expected file hash'
        $state.entries=@($Request.entries);$state.defaultRoute=$Request.defaultRoute;$state.programIngresses=@($Request.programIngresses);$state.siteRules=@($Request.siteRules)
        Write-LocalJson (Join-Path $qa 'app-rules.json') $state
        return @{ok=$true;stateHash=(Read-RuleMaintenanceFile (Join-Path $qa 'app-rules.json')).TextHash}
    }
    $ingresses=@($state.programIngresses|ForEach-Object {$entry=Copy-RoutingSnapshot $_;$entry|Add-Member ready (-not $script:RejectStatus);$entry|Add-Member loaded $true;$entry|Add-Member effectiveRoute $(if($_.route -eq 'Follow'){'b'}else{$_.route});$entry})
    [pscustomobject]@{available=$true;rulesAvailable=$true;defaultLoaded=$true;effectiveDefaultRoute='b';programIngresses=$ingresses}
}
$app=Join-Path $qa 'native.exe';$other=Join-Path $qa 'other.exe'
Copy-Item (Join-Path $env:WINDIR 'System32/whoami.exe') $app
Copy-Item (Join-Path $env:WINDIR 'System32/whoami.exe') $other
$profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(@{Id='gateway';Name='Own';Protocol='http';Host='127.0.0.1';Port=18790;CorePath=(Join-Path $qa 'core.exe')},@{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=18791},@{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=18792});Routing=@{Adapter='standalone';ProfileId='gateway';UnifiedMode='gateway'}})
function Reset-Fixture {
    $script:Profiles=Copy-RoutingSnapshot $profiles;Write-LocalJson $script:ConfigPath $script:Profiles
    $script:Windows=[pscustomobject]@{Flags=3;Server='127.0.0.1:57777';Bypass='external.local'}
    $script:UserEnv=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:57777';HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='outside.example'}
    Write-LocalJson (Join-Path $qa 'app-rules.json') @{version=3;installed=$true;defaultRoute='a';entries=@(@{path=$app;route='a'},@{path=$other;route='Direct'});programIngresses=@();siteRules=@(@{id=('2'*32);domain='example.com';type='domain';scope='global';route='b'})}
    Write-LocalJson (Join-Path $qa 'program-proxies.json') @{version=1;entries=@()}
    $script:StartupChange=$false;$script:RejectStatus=$false
}
Reset-Fixture
Check (Test-ProgramConsoleExecutable $app) 'PE console subsystem detected without filename guess'
Check (-not (Test-ProgramConsoleExecutable (Join-Path $env:WINDIR 'explorer.exe'))) 'GUI executable is not inferred to support proxy environment'
Check ((Get-ProgramProxyAdapter $app) -eq '') 'Native adapter has no implicit opt-in before confirmation'
$plan=Get-EnvironmentProgramAccessPlan $app 'b'
Check ($plan.CanApply -and $plan.Message -match 'TUN' -and $plan.Message -match '已经运行') 'Preview states existing-process and tunnel limits'
Throws {Set-EnvironmentProgramAccess $plan} '确认'
$before=Get-RoutingSnapshot
$result=Set-EnvironmentProgramAccess $plan -Confirmed
$after=Get-RoutingSnapshot;$entry=$after.programIngresses[0]
Check ($result.Managed -and $entry.route -eq 'b') 'Explicit opt-in creates selected program ingress'
Check ($after.defaultRoute -eq 'a' -and $after.entries.Count -eq 1 -and $after.entries[0].path -eq $other -and $after.siteRules.Count -eq 1) 'Only selected EXE rule converts; default, other and website policies remain'
Check ($after.launchEntries.Count -eq 1 -and $after.launchEntries[0].adapter -eq 'environment') 'Launch opt-in and ingress committed together'
Check ((Get-ProgramProxyAdapter $app) -eq 'environment') 'Only configured native EXE obtains environment adapter'
$launch=Get-ProgramLaunchPlan $app 'b'
Check ($launch.Arguments.Count -eq 0 -and $launch.Environment.HTTP_PROXY -eq (Get-ManagedIngressEndpoint $entry)) 'Native launch uses stable endpoint without Chromium arguments'
$psi=New-Object Diagnostics.ProcessStartInfo;$psi.UseShellExecute=$false;$psi.EnvironmentVariables['https_proxy']='http://127.0.0.1:19999';$psi.EnvironmentVariables['NO_PROXY']='*';$psi.EnvironmentVariables['UNRELATED_FIXTURE']='keep'
Set-ProgramLaunchEnvironment $psi $launch
Check ($psi.EnvironmentVariables['HTTPS_PROXY'] -eq $launch.Endpoint -and $psi.EnvironmentVariables['NO_PROXY'] -eq 'localhost,127.0.0.1,::1' -and $psi.EnvironmentVariables['UNRELATED_FIXTURE'] -eq 'keep') 'Private launch overrides stale proxy/broad bypass and preserves unrelated environment'
$port=$entry.port;$id=$entry.id
Set-EnvironmentProgramAccess (Get-EnvironmentProgramAccessPlan $app 'a') -Confirmed|Out-Null
$next=(Get-RoutingSnapshot).programIngresses[0]
Check ($next.port -eq $port -and $next.id -eq $id -and $next.route -eq 'a') 'Changing upstream retains program endpoint and identity'
Set-ApplicationRoute $app 'Direct'|Out-Null
$next=(Get-RoutingSnapshot).programIngresses[0]
Check ($next.port -eq $port -and $next.id -eq $id -and $next.route -eq 'Direct') 'Existing CLI route API reuses a confirmed native adapter without changing its endpoint'
Reset-Fixture;$plan=Get-EnvironmentProgramAccessPlan $app 'b';Throws {Set-EnvironmentProgramAccess $plan -Confirmed -ReuseExisting} '接入已撤销'
Reset-Fixture;$plan=Get-EnvironmentProgramAccessPlan $app 'b';$plan.CreatedAt=[DateTime]::UtcNow.AddSeconds(-121).ToString('o');Throws {Set-EnvironmentProgramAccess $plan -Confirmed} '过期'
Reset-Fixture;$plan=Get-EnvironmentProgramAccessPlan $app 'b';[IO.File]::AppendAllText((Join-Path $qa 'program-proxies.json'),' ');Throws {Set-EnvironmentProgramAccess $plan -Confirmed} '变化'
Reset-Fixture;$plan=Get-EnvironmentProgramAccessPlan $app 'b';$plan.Identity='wrong';Throws {Set-EnvironmentProgramAccess $plan -Confirmed} '变化'
Reset-Fixture;$before=Get-RoutingSnapshot;$script:RejectStatus=$true;Throws {Set-EnvironmentProgramAccess (Get-EnvironmentProgramAccessPlan $app 'b') -Confirmed} '未就绪';Check (Test-SameRouting $before (Get-RoutingSnapshot)) 'Failed readiness rolls back ingress and native opt-in together'
Reset-Fixture;$before=Get-RoutingSnapshot;$script:StartupChange=$true;Throws {Set-EnvironmentProgramAccess (Get-EnvironmentProgramAccessPlan $app 'b') -Confirmed} '外部网络';Check (Test-SameRouting $before (Get-RoutingSnapshot)) 'External Windows change during startup preserves old rules'
Write-Output ('PASS: '+$checks+' environment opt-in, stable port, CAS, rollback and private launch assertions; Windows setters are forbidden.')
