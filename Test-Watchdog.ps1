$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-Watchdog-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
$utf8=New-Object Text.UTF8Encoding($true)
$source='using System.Threading;class Fixture{static void Main(){Thread.Sleep(60000);}}'
$cs=Join-Path $qa 'Owner.cs';$exe=Join-Path $qa 'Owner.exe';[IO.File]::WriteAllText($cs,$source)
& (Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe') /nologo /target:winexe ('/out:'+$exe) $cs
if($LASTEXITCODE -ne 0){throw 'Fixture compile failed'}
$body=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'GatewayWatchdog.ps1'))
$body=$body.Substring($body.IndexOf('$path=Get-IndependentSessionPath'))
$mock=@'
$fixtureOwnerState=${function:Get-RecoveryOwnerState}
$fixtureSessionProcess=${function:Test-SessionProcess}
function Get-RecoveryOwnerState($Session){if(Test-Path (Join-Path $script:DataRoot 'owner-unknown')){return 'unknown'};& $fixtureOwnerState $Session}
function Test-SessionProcess($ProcessId,$Ticks){if(Test-Path (Join-Path $script:DataRoot 'owner-unknown')){return $false};& $fixtureSessionProcess $ProcessId $Ticks}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Get-SystemSnapshot {Get-Content (Join-Path $script:DataRoot 'fake-system.json') -Raw|ConvertFrom-Json}
function Get-UserProxyEnv {Get-Content (Join-Path $script:DataRoot 'fake-env.json') -Raw|ConvertFrom-Json}
function Set-SystemSnapshot($v){[IO.File]::AppendAllText((Join-Path $script:DataRoot 'setting-writes.txt'),"system`r`n");if(Test-Path (Join-Path $script:DataRoot 'fail-restore')){throw 'isolated write failure'};Write-LocalJson (Join-Path $script:DataRoot 'fake-system.json') $v}
function Set-UserProxyEnv($v){[IO.File]::AppendAllText((Join-Path $script:DataRoot 'setting-writes.txt'),"environment`r`n");Write-LocalJson (Join-Path $script:DataRoot 'fake-env.json') $v}
function Remove-ItemProperty {param($LiteralPath,$Name,$ErrorAction)}
function Get-ItemPropertyValue {param($LiteralPath,$Name,$ErrorAction);throw 'No registration in isolated fixture'}
function Test-RecoveryEndpoint([string]$value){[IO.File]::AppendAllText((Join-Path $script:DataRoot 'endpoint-probes.txt'),($value+"`r`n"));if($value -eq '127.0.0.1:18790'){return (Test-Path (Join-Path $script:DataRoot 'listener-ready'))};if($value -eq 'external.example:8080'){return $true};return $false}
'@
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$parseTokens=$null;$parseErrors=$null
$gatewayAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'IndependentGateway.ps1'),[ref]$parseTokens,[ref]$parseErrors)
if($parseErrors.Count){throw 'Independent gateway source did not parse'}
$resolver=$gatewayAst.Find({param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-GatewayWatchdogEndpoint'},$true)
if(-not $resolver){throw 'Owned watchdog endpoint resolver is missing'}
. ([scriptblock]::Create($resolver.Extent.Text))
$resolverChecks=0
foreach($inputValue in @('<missing>','','127.0.0.1:0','127.0.0.1:65536','external.example:18790','http://127.0.0.1:18790','localhost:18790','127.0.0.1:18790/path','user:pass@127.0.0.1:18790','[::1]:18790','127.0.0.1:+1',' 127.0.0.1:18790','127.0.0.1:18790 ',"127.0.0.1:18790`n","127.0.0.1:18790`r`n")){
    $record=[pscustomobject]@{PreserveWindowsSettings=$true;TargetSystem=[pscustomobject]@{Server='external.example:8080'}}
    if($inputValue -ne '<missing>'){$record|Add-Member NoteProperty OwnGatewayEndpoint $inputValue}
    $resolved=Get-GatewayWatchdogEndpoint $record
    if($resolved.State -ne 'Unknown' -or $resolved.Endpoint -cne ''){throw 'Malformed or missing ownership was accepted as a watchdog endpoint'}
    $resolverChecks++
}
foreach($inputValue in @('127.0.0.1:1','127.0.0.1:18790','127.0.0.1:65535')){
    $resolved=Get-GatewayWatchdogEndpoint ([pscustomobject]@{PreserveWindowsSettings=$true;OwnGatewayEndpoint=$inputValue;TargetSystem=[pscustomobject]@{Server='external.example:8080'}})
    if($resolved.State -ne 'Ready' -or $resolved.Endpoint -cne $inputValue){throw 'Valid owned loopback endpoint was rejected'}
    $resolverChecks++
}
foreach($inputValue in @('','127.0.0.1:20000','external.example:8080')){
    $resolved=Get-GatewayWatchdogEndpoint ([pscustomobject]@{TargetSystem=[pscustomobject]@{Server=$inputValue};OwnGatewayEndpoint='127.0.0.1:18790'})
    if($resolved.State -ne 'Ready' -or $resolved.Endpoint -cne $inputValue){throw 'Ordinary session endpoint compatibility changed'}
    $resolverChecks++
}
Write-Output ('PASS: '+$resolverChecks+' watchdog endpoint ownership and compatibility checks.')
$checks=0
foreach($case in @('owner-unknown','owner-crash','core-crash','external-change','restore-failure','session-lock','session-corrupt','session-update','preserve-direct','preserve-dead-external','preserve-remote-owned-dead','preserve-missing-owned','preserve-invalid-owned')){
    $data=Join-Path $qa $case;[void][IO.Directory]::CreateDirectory((Join-Path $data 'gateway'))
    $owner=Start-Process -FilePath $exe -WindowStyle Hidden -PassThru
    $watch=$null
    try{
        $proxy=@{Flags=3;Server='127.0.0.1:18790';Bypass='localhost'};$direct=@{Flags=1;Server='';Bypass='localhost'}
        $targetEnv=@{HTTP_PROXY='http://127.0.0.1:18790';HTTPS_PROXY='http://127.0.0.1:18790';ALL_PROXY='http://127.0.0.1:18790';NO_PROXY='localhost'}
        $oldEnv=@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='localhost'}
        $session=@{OwnerPID=$owner.Id;OwnerStart=$owner.StartTime.ToUniversalTime().Ticks.ToString();Started=[Guid]::NewGuid().ToString();BeforeSystem=$direct;TargetSystem=$proxy;BeforeEnv=$oldEnv;TargetEnv=$targetEnv}
        $preserve=$case.StartsWith('preserve-')
        if($preserve){
            $baseline=if($case -eq 'preserve-direct'){$direct}elseif($case -eq 'preserve-remote-owned-dead'){@{Flags=3;Server='external.example:8080';Bypass='external-before'}}else{@{Flags=3;Server='127.0.0.1:20000';Bypass='external-before'}}
            $baselineEnv=@{HTTP_PROXY='http://127.0.0.1:20000';HTTPS_PROXY='http://external.example:8080';ALL_PROXY='socks5://127.0.0.1:20000';NO_PROXY='localhost,.external.example'}
            $session.PreserveWindowsSettings=$true;$session.OwnGatewayEndpoint='127.0.0.1:18790'
            $session.BeforeSystem=$baseline;$session.TargetSystem=$baseline;$session.BeforeEnv=$baselineEnv;$session.TargetEnv=$baselineEnv
            if($case -eq 'preserve-missing-owned'){$session.Remove('OwnGatewayEndpoint')}
            if($case -eq 'preserve-invalid-owned'){$session.OwnGatewayEndpoint='127.0.0.1:65536'}
            $targetEnv=$baselineEnv
        }
        [IO.File]::WriteAllText((Join-Path $data 'gateway-session.json'),($session|ConvertTo-Json -Depth 5),$utf8)
        $system=$proxy;if($preserve){$system=$baseline};if($case -eq 'external-change'){$system=@{Flags=3;Server='127.0.0.1:20000';Bypass='external'}}
        [IO.File]::WriteAllText((Join-Path $data 'fake-system.json'),($system|ConvertTo-Json),$utf8)
        [IO.File]::WriteAllText((Join-Path $data 'fake-env.json'),($targetEnv|ConvertTo-Json),$utf8)
        [IO.File]::WriteAllText((Join-Path $data 'listener-ready'),'ready')
        if($case -eq 'preserve-remote-owned-dead'){[IO.File]::Delete((Join-Path $data 'listener-ready'))}
        if($case -eq 'restore-failure'){[IO.File]::WriteAllText((Join-Path $data 'fail-restore'),'yes')}
        if($case -eq 'owner-unknown'){[IO.File]::WriteAllText((Join-Path $data 'owner-unknown'),'unknown')}
        $fixture=Join-Path $data 'Watch.ps1'
        $prefix='$ErrorActionPreference=''Stop'''+"`r`n"+('. '''+(Join-Path $PSScriptRoot 'ProxyBackend.ps1').Replace("'","''")+''' -DataDirectory '''+$data.Replace("'","''")+'''')+"`r`n"
        [IO.File]::WriteAllText($fixture,($prefix+$mock+"`r`n"+$body),$utf8)
        $watch=Start-Process -FilePath $shell -ArgumentList ('-NoProfile -ExecutionPolicy Bypass -File "'+$fixture+'"') -WindowStyle Hidden -PassThru
        $deadline=[DateTime]::Now.AddSeconds(10);while(-not (Test-Path (Join-Path $data 'gateway\watchdog-ready.json')) -and [DateTime]::Now -lt $deadline){Start-Sleep -Milliseconds 100}
        if(-not (Test-Path (Join-Path $data 'gateway\watchdog-ready.json'))){throw 'Watchdog did not become ready'}
        if($preserve){
            $systemBefore=[IO.File]::ReadAllText((Join-Path $data 'fake-system.json'))
            $envBefore=[IO.File]::ReadAllText((Join-Path $data 'fake-env.json'))
            if($case -ne 'preserve-remote-owned-dead'){
                Start-Sleep -Milliseconds 2400
                if($watch.HasExited -or -not (Test-Path (Join-Path $data 'gateway-session.json')) -or (Test-Path (Join-Path $data 'gateway/stop'))){throw ('Coexistence watchdog falsely stopped healthy or unknown service: '+$case)}
                if($case -in @('preserve-missing-owned','preserve-invalid-owned')){
                    if(Test-Path (Join-Path $data 'endpoint-probes.txt')){throw 'Unknown owned endpoint fell back to probing third-party Windows settings'}
                    $events=@(Get-Content (Join-Path $data 'gateway/lifecycle-session.jsonl')|ForEach-Object {$_|ConvertFrom-Json})
                    if(-not @($events|Where-Object {$_.event -eq 'watchdog-entry-pending' -and $_.reason -eq 'owned-entry-unknown'}).Count){throw 'Unknown owned endpoint did not record its fixed diagnostic reason'}
                    $session.OwnGatewayEndpoint='127.0.0.1:18790'
                    [IO.File]::WriteAllText((Join-Path $data 'gateway-session.json'),($session|ConvertTo-Json -Depth 5),$utf8)
                    Start-Sleep -Milliseconds 1200
                    if($watch.HasExited){throw 'Repairing unknown owned endpoint stopped protection'}
                }
                # Third-party changes after session creation also remain unclaimed.
                $externalSystem=@{Flags=3;Server='127.0.0.1:21000';Bypass='external-after';AutoConfigUrl='http://external.example/proxy.pac'}
                $externalEnv=@{HTTP_PROXY='http://127.0.0.1:21000';HTTPS_PROXY='http://external.example:8081';ALL_PROXY='socks5://127.0.0.1:21000';NO_PROXY='localhost,.changed.example'}
                [IO.File]::WriteAllText((Join-Path $data 'fake-system.json'),($externalSystem|ConvertTo-Json),$utf8)
                [IO.File]::WriteAllText((Join-Path $data 'fake-env.json'),($externalEnv|ConvertTo-Json),$utf8)
                $systemBefore=[IO.File]::ReadAllText((Join-Path $data 'fake-system.json'));$envBefore=[IO.File]::ReadAllText((Join-Path $data 'fake-env.json'))
                $owner.Kill()
            }
            if(-not $watch.WaitForExit(10000)){throw ('Coexistence watchdog did not recover '+$case)}
            $probes=@(Get-Content (Join-Path $data 'endpoint-probes.txt'))
            if(-not $probes.Count -or @($probes|Where-Object {$_ -cne '127.0.0.1:18790'}).Count){throw 'Coexistence watchdog probed an external endpoint instead of its owned entrance'}
            if([IO.File]::ReadAllText((Join-Path $data 'fake-system.json')) -cne $systemBefore -or [IO.File]::ReadAllText((Join-Path $data 'fake-env.json')) -cne $envBefore -or (Test-Path (Join-Path $data 'setting-writes.txt'))){throw 'Coexistence recovery wrote or changed third-party system/environment settings'}
            if((Test-Path (Join-Path $data 'gateway-session.json')) -or -not (Test-Path (Join-Path $data 'gateway/stop'))){throw 'Coexistence recovery did not stop the owned service and finish its journal'}
            $events=@(Get-Content (Join-Path $data 'gateway/lifecycle-session.jsonl')|ForEach-Object {$_|ConvertFrom-Json})
            $reason=if($case -eq 'preserve-remote-owned-dead'){'entry-unavailable'}else{'owner-exited'}
            if(-not @($events|Where-Object {$_.event -eq 'watchdog-recovery' -and $_.reason -eq $reason}).Count){throw 'Coexistence watchdog recovered for the wrong lifecycle reason'}
            $checks++;Write-Output ('PASS: watchdog '+$case+' checks owned entrance and preserves external settings');continue
        }
        if($case -eq 'owner-unknown'){
            Start-Sleep -Milliseconds 2200
            if($watch.HasExited -or -not (Test-Path (Join-Path $data 'gateway-session.json')) -or (Test-Path (Join-Path $data 'gateway/stop'))){throw 'Unknown owner identity was misclassified as an exited UI'}
            [IO.File]::Delete((Join-Path $data 'owner-unknown'))
        }
        if($case -eq 'session-lock'){
            $held=[IO.File]::Open((Join-Path $data 'gateway-session.json'),[IO.FileMode]::Open,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
            try{Start-Sleep -Milliseconds 2400;if($watch.HasExited -or (Test-Path (Join-Path $data 'gateway/stop'))){throw 'Locked journal stopped recovery protection'}}finally{$held.Dispose()}
        }
        if($case -eq 'session-corrupt'){
            [IO.File]::WriteAllText((Join-Path $data 'gateway-session.json'),'{incomplete',$utf8)
            Start-Sleep -Milliseconds 2400
            if($watch.HasExited -or (Test-Path (Join-Path $data 'gateway/stop'))){throw 'Unavailable journal was treated as a stopped owner'}
            [IO.File]::WriteAllText((Join-Path $data 'gateway-session.json'),($session|ConvertTo-Json -Depth 5),$utf8)
        }
        if($case -eq 'session-update'){
            $proxy.Bypass='new-owned-bypass'
            [IO.File]::WriteAllText((Join-Path $data 'fake-system.json'),($proxy|ConvertTo-Json),$utf8)
            [IO.File]::WriteAllText((Join-Path $data 'gateway-session.json'),($session|ConvertTo-Json -Depth 5),$utf8)
            Start-Sleep -Milliseconds 1200
            if($watch.HasExited){throw 'Same-session ownership refresh stopped watchdog'}
        }
        if($case -eq 'core-crash'){[IO.File]::Delete((Join-Path $data 'listener-ready'))}else{$owner.Kill()}
        if(-not $watch.WaitForExit(10000)){throw ('Watchdog did not recover '+$case)}
        $after=Get-Content (Join-Path $data 'fake-system.json') -Raw|ConvertFrom-Json
        if($case -eq 'restore-failure'){
            if($after.Server -ne '127.0.0.1:18790' -or -not (Test-Path (Join-Path $data 'gateway-session.json')) -or (Test-Path (Join-Path $data 'gateway\stop'))){throw 'Failed restoration lost journal or falsely stopped service'}
            $events=Get-Content (Join-Path $data 'gateway\lifecycle-session.jsonl')|ForEach-Object {$_|ConvertFrom-Json}
            if(@($events|Where-Object event -eq 'watchdog-restore-failed').Count -ne 3){throw 'Restoration retry limit failed'}
            $checks++;Write-Output 'PASS: watchdog finite restore failure preserves session';continue
        }
        if($case -eq 'external-change'){if($after.Server -ne '127.0.0.1:20000'){throw 'Overwrote external choice'}}elseif($after.Flags -ne 1 -or $after.Server){throw 'Dead proxy was left behind'}
        if((Test-Path (Join-Path $data 'gateway-session.json')) -or -not (Test-Path (Join-Path $data 'gateway\stop'))){throw 'Recovery order/journal failure'}
        $checks++;Write-Output ('PASS: watchdog '+$case)
    }finally{if($watch){if(-not $watch.HasExited){$watch.Kill()};$watch.Dispose()};if(-not $owner.HasExited){$owner.Kill()};$owner.Dispose()}
}
Write-Output ('PASS: '+$checks+' real watchdog process lifecycle checks with isolated Windows-setting stubs.')
Write-Output ('PASS: '+($checks+$resolverChecks)+' total watchdog checks.')
