param([string]$FixturePath='')
$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-Recovery-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
. (Join-Path $PSScriptRoot 'NetworkRecovery.ps1')
$script:checks=0;$script:realFileWriter=${function:Set-RuleMaintenanceFile};$script:realProbe=${function:Start-HttpEndpointProbe};$script:realTargets=${function:Test-NetworkTargets};$script:realDirectProbe=${function:Start-NetworkRecoveryDirectProbe}
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:checks++}
function Use-ChangeLock([scriptblock]$Action){$script:locks++;$script:locked=$true;try{if($script:lockRace){$script:lockRace=$false;$script:en.NO_PROXY='outside-lock'};& $Action}finally{$script:locked=$false}}
function Reset-Fixture {
    $script:DataRoot=Join-Path $qa ([Guid]::NewGuid().ToString('N'));[void][IO.Directory]::CreateDirectory($script:DataRoot)
    $script:StatePath=Join-Path $script:DataRoot 'selection.json';$script:ConfigPath=Join-Path $script:DataRoot 'config.json';$script:BackupDir=Join-Path $script:DataRoot 'backups'
    $script:Profiles=[pscustomobject]@{Profiles=@([pscustomobject]@{Id='relay_a';Name='Relay A';Protocol='http';Host='127.0.0.1';Port=19341;CorePath='';AppPath=''},[pscustomobject]@{Id='relay_b';Name='Relay B';Protocol='http';Host='127.0.0.1';Port=19342;CorePath='';AppPath=''});Routing=[pscustomobject]@{Adapter='none'}}
    $script:sys=[pscustomobject]@{Flags=3;Server='127.0.0.1:19341';Bypass='<local>;example.invalid';AutoConfigUrl=''}
    $script:en=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:19341';HTTPS_PROXY='http://127.0.0.1:19341';ALL_PROXY=$null;NO_PROXY='example.invalid'}
    $script:selection=[pscustomobject]@{Key='relay_a';Private='keep'};$script:rules=[pscustomobject]@{entries=@([pscustomobject]@{path='fixture-app.exe';route='relay_b'});programIngresses=@();siteRules=@()}
    $script:endpoints=@{relay_a='Ready';relay_b='Ready'};$script:generation=1;$script:writes=0;$script:probes=0;$script:backups=0;$script:locks=0;$script:locked=$false
    $script:failBackup=$false;$script:failReceipt=$false;$script:failFinalReceipt=$false;$script:externalOnFinalReceipt=$false;$script:externalViewOnFinalReceipt=$false;$script:failAfterWrite=$false;$script:outsideWrite=$false;$script:lockRace=$false;$script:probeRace=$false;$script:failProbe=$false;$script:viewsOverride=$null;$script:tun=$false;$script:guard=$false;$script:topology='NoEvidence';$script:machine='Direct';$script:cleanFinished=$true
    [IO.File]::WriteAllText($script:ConfigPath,'{ intentionally malformed fixture config')
}
function Get-SystemSnapshot {Copy-NetworkRecoveryValue $script:sys}
function Get-UserProxyEnv {Copy-NetworkRecoveryValue $script:en}
function Get-Selection {Copy-NetworkRecoveryValue $script:selection}
function Get-RoutingSnapshot {Copy-NetworkRecoveryValue $script:rules}
function Read-ProfileSettings {$script:Profiles}
function Get-NetworkRecoveryMachineStatus {[pscustomobject]@{State='Available';NeedsRepair=($script:machine -ne 'Direct');WinHttpState=$script:machine;Revision=$script:machine;Message='匿名机器层夹具。'}}
function Get-ClientInterference {[pscustomobject]@{Running=$false;Tun=$script:tun;Guard=$script:guard;SystemProxy=$false;Topology=[pscustomobject]@{State=$script:topology;IPv4=$script:topology;IPv6=$script:topology;Available=$true}}}
function Get-CleanStartSession {[pscustomobject]@{Fixture=$true}}
function Test-CleanStartSessionFinished($Session){$script:cleanFinished}
function Get-WindowsApplicationProxyViews {
    if($script:viewsOverride){return $script:viewsOverride}
    $enabled=[bool]($script:sys.Flags -band 2)
    [pscustomobject]@{Registry=[pscustomobject]@{Available=$true;Enabled=$enabled;Server=$script:sys.Server};WinHttpIE=[pscustomobject]@{Available=$true;Server=$(if($enabled){$script:sys.Server}else{''});AutoDetect=[bool]($script:sys.Flags -band 8);HasPac=[bool]($script:sys.Flags -band 4)}}
}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$true;Rows=@($script:Profiles.Profiles|Where-Object {$script:endpoints[$_.Id] -eq 'Ready'}|ForEach-Object {[pscustomobject]@{State='Listen';LocalAddress='127.0.0.1';LocalPort=$_.Port;OwningProcess=$PID}})}}
function Get-Listener($Profile){if(@($script:Profiles.Profiles|Where-Object {$_.Port -eq $Profile.Port -and $script:endpoints[$_.Id] -eq 'Ready'}).Count){[pscustomobject]@{PID=$PID}}}
function Get-DailyProxyEndpoint([string]$Key){[pscustomobject]@{Key=$Key;State=$(if($Key -eq 'Direct'){'Ready'}elseif($script:endpoints.ContainsKey($Key)){$script:endpoints[$Key]}else{'Unsupported'});Identity=($Key+':'+$script:generation)}}
function Set-SystemSnapshot($Value){Check $script:locked 'System mutation must hold change lock';$script:writes++;$pac=$script:sys.AutoConfigUrl;$script:sys=Copy-NetworkRecoveryValue $Value;if($null -eq $script:sys.PSObject.Properties['AutoConfigUrl']){$script:sys|Add-Member NoteProperty AutoConfigUrl $pac};$script:viewsOverride=$null;if($script:outsideWrite){$script:outsideWrite=$false;$script:sys.Server='outside.invalid:9';$script:sys.Flags=3;$script:en.HTTP_PROXY='http://outside.invalid:9';throw 'PRIVATE-outside-write'};if($script:failAfterWrite){$script:failAfterWrite=$false;throw 'PRIVATE-native-failure'}}
function Set-UserProxyEnv($Value,$ExpectedBefore){Check $script:locked 'Env mutation must hold lock';Check (Test-SameEnv $ExpectedBefore $script:en) 'Environment CAS';$script:writes++;$script:en=Copy-NetworkRecoveryValue $Value}
function Save-Selection($Value){Check $script:locked 'Selection mutation must hold lock';$script:writes++;$script:selection=Copy-NetworkRecoveryValue $Value}
function Save-Backup($Value){$script:backups++;if($script:failBackup){throw 'PRIVATE-backup-path'};[void][IO.Directory]::CreateDirectory($script:BackupDir);$path=Join-Path $script:BackupDir ('fixture-'+$script:backups+'.json');[IO.File]::WriteAllText($path,($Value|ConvertTo-Json -Depth 32));$path}
function Set-RuleMaintenanceFile($Before,[byte[]]$Bytes,[bool]$Remove=$false){if($Before.Path -eq (Get-NetworkRecoveryReceiptPath)){if($script:failReceipt){throw 'PRIVATE-receipt-credential'};if($script:failFinalReceipt -and -not $Remove -and ([Text.Encoding]::UTF8.GetString($Bytes)|ConvertFrom-Json).Phase -eq 'Applied'){$script:failFinalReceipt=$false;if($script:externalOnFinalReceipt){$script:sys.Flags=15;$script:sys.Server='outside.invalid:9';$script:sys.AutoConfigUrl='https://outside.invalid/changed.pac';$script:en.HTTP_PROXY='http://outside.invalid:9'};if($script:externalViewOnFinalReceipt){$script:viewsOverride=Get-WindowsApplicationProxyViews;$script:viewsOverride.Registry.Server='outside-latent.invalid:9'};throw 'PRIVATE-final-receipt-failure'}};& $script:realFileWriter $Before $Bytes $Remove}
function Test-ProxyRoute([string]$Key,[switch]$Fast){Check $Fast 'Formal preflight must use bounded Fast';$script:probes++;if($script:probeRace){$script:probeRace=$false;$script:generation++};[pscustomobject]@{Usable=(-not $script:failProbe)}}
function Test-NetworkTargets($Profile){$script:probes++;@([pscustomobject]@{Stage=$(if($script:failProbe){'probe-timeout'}else{'https-response'});HttpCode=$(if($script:failProbe){0}else{204});AuthenticationVerified=$false})}
function Test-NetworkRecoveryDirectTargets {$script:probes++;@([pscustomobject]@{Stage='https-response';HttpCode=204})}
function Get-ProcessProxyEnvironment {throw 'FORBIDDEN process environment read'}
function Set-RoutingSnapshot {throw 'FORBIDDEN program rule write'}
function Start-Service {throw 'FORBIDDEN service start'}
function Stop-Service {throw 'FORBIDDEN service stop'}
function Stop-Process {throw 'FORBIDDEN process stop'}
function Start-Process {throw 'FORBIDDEN client start'}
try{
    Reset-Fixture
    $report=Get-NetworkRecoveryReport;Check ($report.Verification.Request -eq 'NotTested' -and $script:probes -eq 0 -and $script:writes -eq 0) 'Passive report never probes or mutates'
    Check ((Get-NetworkRecoveryPlan -Goal Proxy).Code -eq 'TargetRequired') 'Proxy requires explicit target'
    $r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct);Check ($r.Code -eq 'ConfirmationRequired' -and $script:writes -eq 0) 'Explicit confirmation required'
    $plan=Get-NetworkRecoveryPlan -Goal Direct;$plan.CreatedAt=[DateTimeOffset]::UtcNow.AddSeconds(-121).ToString('o');$r=Invoke-NetworkRecoveryPlan $plan -Confirmed;Check ($r.Code -eq 'PlanExpired' -and $script:writes -eq 0) 'Expired plan rejected before changes'
    $plan=Get-NetworkRecoveryPlan -Goal Direct;$script:lockRace=$true;$r=Invoke-NetworkRecoveryPlan $plan -Confirmed;Check ($r.Code -eq 'StateChanged' -and $script:writes -eq 0 -and $script:en.NO_PROXY -eq 'outside-lock') 'Lock-time CAS preserves concurrent edit'
    Reset-Fixture;$initialRules=Get-DailyProxyHash $script:rules;$initialSelection=Get-DailyProxyHash $script:selection;$initialConfig=(Read-RuleMaintenanceFile $script:ConfigPath).Hash
    $script:Profiles.Profiles=@();$script:sys.Flags=15;$script:sys.AutoConfigUrl='https://pac.example.invalid/PRIVATE-PAC?credential=fixture';$script:sys.Server='http=127.0.0.1:19349;https=127.0.0.1:19350';$script:en.HTTP_PROXY='http://fixture:PRIVATE-credential@retired.example.invalid:9'
    $plan=Get-NetworkRecoveryPlan -Goal Direct;Check $plan.CanApply 'Uninstalled, unregistered, malformed config and PAC residue still allow explicit Direct'
    $r=Invoke-NetworkRecoveryPlan $plan -Confirmed
    Check ($r.State -eq 'Applied' -and $script:sys.Flags -eq 1 -and $script:sys.Server -eq '' -and $script:sys.AutoConfigUrl -eq '' -and $null -eq $script:en.HTTP_PROXY -and $null -eq $script:en.HTTPS_PROXY) ('Direct fully clears application proxy fields: '+($r|ConvertTo-Json -Compress))
    Check ($script:en.NO_PROXY -eq 'example.invalid' -and $script:sys.Bypass -eq '<local>;example.invalid' -and (Get-DailyProxyHash $script:rules) -eq $initialRules -and (Get-DailyProxyHash $script:selection) -eq $initialSelection -and (Read-RuleMaintenanceFile $script:ConfigPath).Hash -eq $initialConfig) 'Direct preserves bypass, routes, selection and malformed original config'
    Check ((Test-Path -LiteralPath $r.Backup) -and (Test-Path -LiteralPath $r.Receipt)) 'Backup and durable receipt exist'
    Check ((Get-NetworkRecoveryUndoPlan).Code -eq 'UndoAutomaticUnsupported') 'Undo never restores unknown PAC'
    $beforeWrites=$script:writes;$beforeBackups=$script:backups;$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed;Check ($r.State -eq 'NoChange' -and $script:writes -eq $beforeWrites -and $script:backups -eq $beforeBackups) 'Direct is idempotent with zero extra setting writes or backups'
    $events=[IO.File]::ReadAllText((Get-NetworkRecoveryEventPath));Check ($events -notmatch 'PRIVATE|credential|pac\.example|retired\.example|19349|fixture-app|example\.invalid') 'Events contain no addresses, credentials, ports, configuration or paths'
    Reset-Fixture;$script:sys.Flags=1;$report=Get-NetworkRecoveryReport
    Check ($report.Findings.Code -contains 'UserProxyWhileSystemOff' -and @($report.Checks|Where-Object {$_.Name -eq '用户 HTTP_PROXY' -and $_.State -eq 'Listening'}).Count -eq 1) 'System off plus live user proxy is explicitly mixed, not healthy Direct'
    $report=Get-NetworkRecoveryReport -Probe;Check ($report.Verification.Request -eq 'TargetRequired' -and $script:probes -eq 0) 'Mixed state never guesses probe target'
    $report=Get-NetworkRecoveryReport -Probe -Key relay_a;Check ($report.Verification.Request -eq 'RequestSucceeded' -and $script:probes -eq 1) 'Explicit successful request distinguished from listening'
    $script:failProbe=$true;$report=Get-NetworkRecoveryReport -Probe -Key relay_a;Check ($report.Verification.Request -eq 'RequestFailed') 'Silent request distinguished from listening'
    Reset-Fixture;$report=Get-NetworkRecoveryReport -Probe;Check ($report.Verification.Request -eq 'RequestSucceeded' -and $script:probes -eq 1) 'Unique aligned current system proxy is probed without guessing restoration selection'
    $script:Profiles.Profiles[1].Port=$script:Profiles.Profiles[0].Port;$beforeProbes=$script:probes;$report=Get-NetworkRecoveryReport -Probe;Check ($report.Verification.Request -eq 'TargetRequired' -and $script:probes -eq $beforeProbes) 'Duplicate registered endpoint does not authorize guessed current route'
    $script:Profiles.Profiles[1].Port=19342
    Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed|Out-Null;$beforeProbes=$script:probes;$report=Get-NetworkRecoveryReport -Probe;Check ($report.Verification.Request -eq 'RequestSucceeded' -and $script:probes -eq ($beforeProbes+1)) 'Direct post-reset report performs explicit direct request check'
    Reset-Fixture;$script:tun=$true;$script:guard=$true;$script:topology='Evidence';$script:machine='Proxy';$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed
    Check ($r.State -eq 'Partial' -and $script:sys.Flags -eq 1 -and $r.Message -match '隧道') 'Tunnel/guard/machine residue allows application reset but only Partial result'
    Reset-Fixture;Write-LocalJson (Get-IndependentSessionPath) ([pscustomobject]@{Generation='old'});$plan=Get-NetworkRecoveryPlan -Goal Direct;Check (-not $plan.CanApply -and $plan.Code -eq 'SessionOwnsSettings') 'Owned session has explicit safe next step'
    $r=Invoke-NetworkRecoveryPlan $plan -Confirmed;Check ($r.Code -eq 'SessionOwnsSettings' -and $script:writes -eq 0) 'Old session cannot overwrite a newly recovered state'
    Reset-Fixture;[IO.File]::WriteAllText((Join-Path $script:DataRoot 'clean-start-current.json'),'{}');$script:cleanFinished=$false;Check ((Get-NetworkRecoveryPlan -Goal Direct).Code -eq 'CleanStartOwnsSettings') 'Active clean-start recovery ownership blocks new reset'
    Reset-Fixture;$script:failBackup=$true;$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed;Check ($r.Code -eq 'BackupFailed' -and $script:writes -eq 0) 'Backup failure prevents all setting writes'
    Reset-Fixture;$script:failReceipt=$true;$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed;Check ($r.Code -eq 'ReceiptFailed' -and $script:writes -eq 0) ('Receipt failure prevents writes: '+$r.Code)
    Reset-Fixture;$before=Get-DailyProxyHash @($script:sys,$script:en);$script:failAfterWrite=$true;$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed;Check ($r.State -eq 'Failed' -and (Get-DailyProxyHash @($script:sys,$script:en)) -eq $before) ('Native failure rolls back owned system and env: '+$r.Code)
    Reset-Fixture;$script:sys.Flags=15;$script:sys.AutoConfigUrl='https://automatic.example.invalid/original.pac';$before=Get-DailyProxyHash @($script:sys,$script:en,(Get-DailyProxyWindowsViews $script:sys));$script:failFinalReceipt=$true
    $r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed
    Check ($r.State -eq 'Failed' -and $r.Code -eq 'ApplyFailed' -and (Get-DailyProxyHash @($script:sys,$script:en,(Get-DailyProxyWindowsViews $script:sys))) -eq $before -and -not (Test-Path -LiteralPath (Get-NetworkRecoveryReceiptPath))) 'Final receipt failure restores coherent manual+PAC+auto-detect baseline and original user environment'
    Reset-Fixture;$script:sys.Flags=15;$script:sys.AutoConfigUrl='https://automatic.example.invalid/original.pac';$oldHttps=$script:en.HTTPS_PROXY;$script:failFinalReceipt=$true;$script:externalOnFinalReceipt=$true
    $r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed
    Check ($r.Code -eq 'RollbackIncomplete' -and $script:sys.Flags -eq 15 -and $script:sys.AutoConfigUrl -eq 'https://outside.invalid/changed.pac' -and $script:sys.Server -eq 'outside.invalid:9' -and $script:en.HTTP_PROXY -eq 'http://outside.invalid:9' -and $script:en.HTTPS_PROXY -eq $oldHttps) 'PAC rollback preserves later outside PAC/server/HTTP edits and restores only remaining owned environment fields'
    Reset-Fixture;$script:sys.Flags=15;$script:sys.AutoConfigUrl='https://automatic.example.invalid/original.pac';$script:failFinalReceipt=$true;$script:externalViewOnFinalReceipt=$true
    $r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed
    Check ($r.Code -eq 'RollbackIncomplete' -and $script:sys.Flags -eq 1 -and $script:sys.AutoConfigUrl -eq '' -and $script:viewsOverride.Registry.Server -eq 'outside-latent.invalid:9') 'PAC rollback requires full target-view ownership and preserves disabled registry-server outside edit'
    Reset-Fixture;$script:sys.Flags=15;$script:sys.AutoConfigUrl='https://automatic.example.invalid/original.pac';$script:viewsOverride=Get-WindowsApplicationProxyViews;$script:viewsOverride.Registry.Enabled=$false;$script:failFinalReceipt=$true
    $r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed
    Check ($r.Code -eq 'RollbackIncomplete' -and $script:sys.Flags -eq 1 -and $script:sys.AutoConfigUrl -eq '') 'Divergent original automatic views are not reconstructed as a single falsely restored baseline'
    Reset-Fixture;$oldHttps=$script:en.HTTPS_PROXY;$script:outsideWrite=$true;$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed;Check ($r.Code -eq 'RollbackIncomplete' -and $script:sys.Server -eq 'outside.invalid:9' -and $script:en.HTTP_PROXY -eq 'http://outside.invalid:9' -and $script:en.HTTPS_PROXY -eq $oldHttps) 'Rollback preserves external system and changed env while restoring remaining owned env fields'
    Reset-Fixture;$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed;Check ((Get-NetworkRecoveryUndoPlan).CanApply) 'Live registered original endpoint allows undo preview'
    $script:endpoints.relay_a='Stopped';$plan=Get-NetworkRecoveryUndoPlan;Check ($plan.Code -eq 'UndoTargetUnavailable') 'Dead/uninstalled endpoint cannot be restored'
    $script:endpoints.relay_a='Ready';$plan=Get-NetworkRecoveryUndoPlan;$script:failProbe=$true;$r=Restore-NetworkRecovery $plan -Confirmed;Check ($r.Code -eq 'UndoTargetUnavailable' -and $script:sys.Flags -eq 1) 'Listening original endpoint must also pass request before undo'
    $script:failProbe=$false;$r=Restore-NetworkRecovery (Get-NetworkRecoveryUndoPlan) -Confirmed;Check ($r.State -eq 'Applied' -and $script:sys.Flags -eq 3 -and $script:en.HTTP_PROXY -eq 'http://127.0.0.1:19341') ('Undo restores identity-verified healthy endpoint: '+$r.Code)
    Check (-not (Get-NetworkRecoveryUndoPlan).CanApply) 'Undo is single use'
    Reset-Fixture;$script:sys.Flags=1;Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed|Out-Null;$script:failProbe=$true;$r=Restore-NetworkRecovery (Get-NetworkRecoveryUndoPlan) -Confirmed;Check ($r.Code -eq 'UndoTargetUnavailable' -and $null -eq $script:en.HTTP_PROXY) 'Undo to system Direct still probes original user proxy endpoints before restoring variables'
    Reset-Fixture;$plan=Get-NetworkRecoveryPlan -Goal Proxy -Key relay_b;Check $plan.CanApply 'Explicit Proxy goal uses formal DailyProxy plan';$script:failProbe=$true;$r=Invoke-NetworkRecoveryPlan $plan -Confirmed;Check ($r.State -eq 'Failed' -and $script:writes -eq 0 -and $script:probes -eq 1) 'Proxy goal refuses failed formal route preflight'
    Reset-Fixture;$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Proxy -Key relay_b) -Confirmed;Check ($r.State -eq 'Applied' -and $script:sys.Server -eq '127.0.0.1:19342' -and $script:probes -eq 1) ('Proxy goal applies explicit selected route: '+$r.Code)
    $undo=Get-NetworkRecoveryUndoPlan;Check $undo.CanApply 'Proxy undo delegates formal DailyProxy ownership';$r=Restore-NetworkRecovery $undo -Confirmed;Check ($r.State -eq 'Applied' -and $script:sys.Server -eq '127.0.0.1:19341') 'Proxy undo restores healthy original route'
    Reset-Fixture;$script:failFinalReceipt=$true;$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Proxy -Key relay_b) -Confirmed
    Check ($r.State -eq 'Partial' -and $script:sys.Server -eq '127.0.0.1:19342') 'Interrupted wrapper finalization retains successful formal switch and durable Prepared receipt'
    Check ((Get-NetworkRecoveryReport).Findings.Code -contains 'RecoveryInterrupted') 'Interrupted durable receipt is diagnosed without replaying it'
    $plan=Get-NetworkRecoveryUndoPlan;Check $plan.CanApply 'Prepared receipt binds only the new formal receipt, original baseline, target and time window'
    $r=Restore-NetworkRecovery $plan -Confirmed;Check ($r.State -eq 'Applied' -and $script:sys.Server -eq '127.0.0.1:19341') 'Prepared committed switch can be safely undone'
    $path=Get-NetworkRecoveryEventPath;$injected=[pscustomobject]@{Version=1;Events=@([pscustomobject]@{At=[DateTimeOffset]::UtcNow.ToString('o');State='Applied';Code='Applied';Private='PRIVATE-credential-address-path'})};[IO.File]::WriteAllText($path,($injected|ConvertTo-Json));Write-NetworkRecoveryEvent 'Rejected' 'http://PRIVATE:credential@address.invalid/path'
    Check ([IO.File]::ReadAllText($path) -notmatch 'PRIVATE|credential|address|path') 'Event rewrite strips unknown old fields and rejects arbitrary new codes'
    for($i=0;$i -lt 80;$i++){Write-NetworkRecoveryEvent 'Rejected' 'StateChanged'}
    $event=Get-Content -LiteralPath (Get-NetworkRecoveryEventPath) -Raw|ConvertFrom-Json;Check (@($event.Events).Count -eq 64 -and (Get-Item -LiteralPath (Get-NetworkRecoveryEventPath)).Length -lt 65536) 'Event history bounded to 64 redacted entries'
    if($FixturePath){
        $fixture=Get-Content -LiteralPath $FixturePath -Raw|ConvertFrom-Json
        $ca=Join-Path $PSScriptRoot 'test-fixtures/web-transport/localhost-cert.pem'
        $script:localProbe=[scriptblock]::Create(($script:realProbe.ToString().Replace('--disable --silent',('--disable --cacert "'+$ca+'" --silent'))))
        function Start-HttpEndpointProbe($Profile,[string]$Url,[bool]$Fast=$false){& $script:localProbe $Profile ('https://localhost:'+$fixture.OriginPort+'/204') $Fast}
        Set-Item Function:Test-NetworkTargets $script:realTargets
        foreach($case in $fixture.Cases){
            Reset-Fixture;$script:Profiles.Profiles[0].Port=[int]$case.Port;$script:sys.Server='127.0.0.1:'+$case.Port;$script:en.HTTP_PROXY='http://127.0.0.1:'+$case.Port
            if($case.Name -eq 'terminated'){$script:endpoints.relay_a='Stopped'}
            $clock=[Diagnostics.Stopwatch]::StartNew();$report=Get-NetworkRecoveryReport -Probe -Key relay_a
            if($case.Name -eq 'healthy'){Check ($report.Verification.Request -eq 'RequestSucceeded') 'Real loopback CONNECT+TLS forwarding succeeds'}
            elseif($case.Name -eq 'silent'){Check ($report.Verification.Request -eq 'RequestFailed' -and $clock.Elapsed.TotalSeconds -lt 14) 'Real accept-without-forwarding fixture fails within bounded request deadline'}
            else{Check ($report.Verification.Request -eq 'TargetUnavailable') 'Force-ended own fixture cannot be probed as available';$r=Invoke-NetworkRecoveryPlan (Get-NetworkRecoveryPlan -Goal Direct) -Confirmed;Check ($r.State -eq 'Applied') 'Force-ended own proxy still allows Direct reset'}
        }
        $directSource=$script:realDirectProbe.ToString().Replace('--disable --silent',('--disable --cacert "'+$ca+'" --silent')).Replace('+$Url',('+''https://localhost:'+$fixture.OriginPort+'/204'''))
        Set-Item Function:Start-NetworkRecoveryDirectProbe ([scriptblock]::Create($directSource))
        $moduleDirect=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'NetworkRecovery.ps1'),[ref]$null,[ref]$null).Find({param($ast)$ast -is [Management.Automation.Language.FunctionDefinitionAst] -and $ast.Name -eq 'Test-NetworkRecoveryDirectTargets'},$false)
        Set-Item Function:Test-NetworkRecoveryDirectTargets $moduleDirect.Body.GetScriptBlock()
        $report=Get-NetworkRecoveryReport -Probe;Check ($report.Verification.Request -eq 'RequestSucceeded') 'Actual direct curl after proxy termination bypasses inherited proxies and reaches only loopback TLS origin'
    }
    Write-Output ('PASS: '+$script:checks+' network recovery assertions (Windows writes stubbed; no external requests).')
}finally{
    $resolved=[IO.Path]::GetFullPath($qa);$temp=[IO.Path]::GetFullPath([IO.Path]::GetTempPath())
    if($resolved.StartsWith($temp,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('FlowSwitch-Recovery-')){Remove-Item -LiteralPath $resolved -Recurse -Force -ErrorAction SilentlyContinue}
}
