$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-patrol-'+[Guid]::NewGuid().ToString('N'))
$script:DataRoot=Join-Path $qa 'isolated data';$script:ProductVersion='3.9.9'
$script:checks=0;$script:writes=0;$script:machineReads=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:checks++;Write-Output ('PASS: '+$Message)}
function Fails([scriptblock]$Action){try{& $Action|Out-Null;return $false}catch{return $true}}
. (Join-Path $PSScriptRoot 'NetworkDiagnostics.ps1')
$sharedRepair=${function:Repair-NetworkDiagnosis}
. (Join-Path $PSScriptRoot 'SmartPatrol.ps1') -Library
Check ($script:machineReads -eq 0 -and -not (Test-Path $qa)) 'Library loading performs no host scan or file write'
function Get-Listener {param($Profile,$TcpRows);if(@($TcpRows).Count){[pscustomobject]@{PID=1}}}
$script:tcp=[pscustomobject]@{Available=$true;Rows=@()}
Check ((Get-SmartPatrolValueState 'http://127.0.0.1:19100' $script:tcp) -eq 'Dead') 'Successful empty snapshot proves absent simple local listener without collection crash'
Check ((Get-SmartPatrolValueState '' $script:tcp) -eq 'Unset') 'Unset remains distinct from unknown or dead'
$script:tcp.Available=$false
Check ((Get-SmartPatrolValueState 'http://127.0.0.1:19100' $script:tcp) -eq 'Unknown') 'Unavailable collection never authorizes cleanup'
$script:tcp.Available=$true;$script:tcp.Rows=@([pscustomobject]@{State='Listen';LocalPort=19100;LocalAddress='127.0.0.1'})
Check ((Get-SmartPatrolValueState 'http://127.0.0.1:19100' $script:tcp) -eq 'Listening') 'Single listener works and is not called target health'
$script:tcp.Rows=@([pscustomobject]@{State='Listen';LocalPort=19100;LocalAddress='::1'})
Check ((Get-SmartPatrolValueState 'socks5://[::1]:19100' $script:tcp) -eq 'Listening') 'IPv6 loopback supported'
Check ((Get-SmartPatrolValueState '127.0.0.1:19100' $script:tcp) -eq 'Dead') 'IPv6-only listener does not cover IPv4 address'
$script:tcp.Rows=@([pscustomobject]@{State='Listen';LocalPort=19100;LocalAddress='::'})
Check ((Get-SmartPatrolValueState '127.0.0.1:19100' $script:tcp) -eq 'Unknown') 'Ambiguous dual-stack wildcard preserved'
foreach($value in @('http://proxy.example:8080','http://u:synthetic-secret@127.0.0.1:19100','http://127.0.0.1:19100/path','http=127.0.0.1:19100;https=127.0.0.1:19101','invalid')){
    Check ((Get-SmartPatrolValueState $value $script:tcp) -eq 'Unknown') 'Remote, credential-bearing or complex values retained'
}
$script:tcp.Rows=@();$script:revision='fixture-one';$script:action='clear-dead-environment';$script:machineFailure=$false
function Get-NetworkDiagnosis {[pscustomobject]@{Revision=$script:revision;RepairAction=$script:action;RepairText='Fixture repair';Issues=@([pscustomobject]@{Code='fixture';Message='synthetic-secret'});Endpoints=@();Message='synthetic-private-diagnostic'}}
function Get-TcpObservationSnapshot {$script:tcp}
function Get-UserProxyEnv {[pscustomobject]@{HTTP_PROXY='http://u:synthetic-secret@proxy.example:8080';HTTPS_PROXY='http://127.0.0.1:19100';ALL_PROXY=''}}
function Get-SmartPatrolMachineValue($Name){$script:machineReads++;if($script:machineFailure){throw 'synthetic-private-error'};'http://u:synthetic-secret@proxy.example:8080'}
function Get-SystemSnapshot {[pscustomobject]@{Flags=1;Server='';Bypass='custom-private.example;<local>'}}
function Get-SmartPatrolHostsState {[pscustomobject]@{State='Observed';Mappings=2}}
function Get-NetworkTopologyObservation {[pscustomobject]@{State='NoEvidence';IPv4='NoEvidence';IPv6='NoEvidence'}}
function Write-LocalJson($Path,$Value){[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 8),(New-Object Text.UTF8Encoding($false)))}
function Repair-NetworkDiagnosis($Revision,$ExpectedAction){$script:writes++;$script:applied=$Revision;$script:appliedAction=$ExpectedAction;[pscustomobject]@{Message='Fixture repair committed';Backup='synthetic-private-backup'}}
$report=Get-SmartPatrolReport
Check ($script:writes -eq 0 -and $report.Environment.Count -eq 6) 'Six environment rows collected without settings mutation'
Check ($report.EndpointCount -eq 0 -and $report.Topology.State -eq 'NoEvidence') 'No hardcoded gateway port and missing topology evidence not healthy'
$summary=Get-SmartPatrolSummary $report;$json=ConvertTo-Json -InputObject $summary -Depth 8;$display=Format-SmartPatrolReport $report
Check ($json -notmatch 'synthetic-secret|synthetic-private|proxy.example|custom-private' -and $display -notmatch 'synthetic-secret|synthetic-private|proxy.example|custom-private') 'Summary and console do not expose values, credentials, IPs or private diagnostics'
Check (-not $summary.authenticationVerified -and $display -match '未见证据不等于 TUN 已关闭') 'No route absence, IP consistency or login success claims'
$log=Save-SmartPatrolReport $report
Check ($log.StartsWith($script:DataRoot) -and [IO.File]::ReadAllText($log) -notmatch 'synthetic-secret|synthetic-private|proxy.example') 'One bounded redacted report uses actual isolated data root'
$script:machineFailure=$true;$unknown=Get-SmartPatrolReport
Check (-not $unknown.MachineAvailable -and @($unknown.Environment|Where-Object { $_.Scope -eq 'Machine' -and $_.State -eq 'Unknown'}).Count -eq 3) 'Machine read errors remain unknown with no clearing'
$script:machineFailure=$false
Check (Fails {Invoke-SmartPatrolRepair $report}) 'Unconfirmed repair refused'
$expired=$report|ConvertTo-Json -Depth 8|ConvertFrom-Json;$expired.CapturedAt=[DateTimeOffset]::UtcNow.AddSeconds(-121).ToString('o')
Check (Fails {Invoke-SmartPatrolRepair $expired -Confirmed}) 'Expired preview refused'
$expired.CapturedAt=[DateTimeOffset]::UtcNow.AddSeconds(10).ToString('o')
Check (Fails {Invoke-SmartPatrolRepair $expired -Confirmed}) 'Future timestamp refused'
$script:revision='external-change'
Check (Fails {Invoke-SmartPatrolRepair $report -Confirmed}) 'Concurrent configuration change invalidates preview'
$script:revision='fixture-one';$script:action='repair-dead-entry'
Check (Fails {Invoke-SmartPatrolRepair $report -Confirmed}) 'Changed repair action invalidates preview even with same revision'
$script:action='clear-dead-environment'
Check ($script:writes -eq 0) 'All invalid previews performed zero repair writes'
$null=Invoke-SmartPatrolRepair $report -Confirmed
Check ($script:writes -eq 1 -and $script:applied -ceq 'fixture-one' -and $script:appliedAction -ceq 'clear-dead-environment') 'Confirmed current plan delegates revision and action to shared transactional repair'
function Repair-NetworkDiagnosis($Revision){throw 'synthetic concurrent transaction failure'}
Check (Fails {Invoke-SmartPatrolRepair $report -Confirmed}) 'Shared transaction failure surfaces without false repair success'
${function:Repair-NetworkDiagnosis}=$sharedRepair
function Use-ChangeLock($Action){$script:action='repair-dead-entry';& $Action}
function Repair-DeadSystemEntry($Revision){$script:writes++;throw 'Wrong action must never execute'}
$script:writes=0
Check (Fails {Invoke-SmartPatrolRepair $report -Confirmed}) 'Real shared repair rejects same-revision action change inside lock'
Check ($script:writes -eq 0) 'Lock-time listener/guard change cannot substitute a different repair'
$script:action='clear-dead-environment';$script:saveCalls=0;$script:failSave=$false;$script:messages=@()
function Write-Host {param($Object);$script:messages+=[string]$Object}
function Save-SmartPatrolReport($Report,[bool]$Repaired=$false){$script:saveCalls++;if($script:failSave -and $script:saveCalls -gt 1){throw 'fixture post-save failure'};'isolated-report'}
function Read-Host($Prompt){'N'}
function Repair-NetworkDiagnosis($Revision,$ExpectedAction){$script:writes++;[pscustomobject]@{Message='committed';Backup='fixture'}}
$code=Invoke-SmartPatrolCommand
Check ($code -eq 0 -and $script:writes -eq 0) 'Default command only checks and stores redacted summary'
$code=Invoke-SmartPatrolCommand -Fix
Check ($code -eq 0 -and $script:writes -eq 0) 'Interactive cancellation performs no repair'
$script:saveCalls=0;$script:failSave=$true;$script:messages=@()
$code=Invoke-SmartPatrolCommand -Fix -Yes
Check ($code -eq 0 -and $script:writes -eq 1 -and ($script:messages -join ' ') -match '已提交') 'Committed repair preserved when later summary save fails'
$script:failSave=$false
function Repair-NetworkDiagnosis($Revision,$ExpectedAction){throw 'fixture failed transaction'}
$code=Invoke-SmartPatrolCommand -Fix -Yes
Check ($code -eq 1 -and $script:writes -eq 1) 'Uncommitted transaction failure has nonzero command result'
$plan=Get-SmartPatrolLaunchPlan -DataDirectory (Join-Path $qa 'custom settings') -ScriptPath (Join-Path $qa 'app folder\SmartPatrol.ps1')
Check ($plan.FilePath -ceq (Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe') -and $plan.Arguments -match '-NoExit' -and $plan.Arguments -match '-KeepOpen' -and $plan.Arguments.Contains('"'+(Join-Path $qa 'custom settings')+'"') -and $plan.Arguments -notmatch '-Fix') 'Launch uses absolute shell, readable console, quoted data directory and read-only mode'
$null=New-Item -ItemType Directory -Path (Join-Path $qa 'app folder') -Force
[IO.File]::WriteAllText((Join-Path $qa 'app folder\SmartPatrol.ps1'),'# isolated launch fixture')
function Start-Process {param($FilePath,$ArgumentList,$WorkingDirectory);$script:launchArgs=$ArgumentList;$script:launchPath=$FilePath}
Start-SmartPatrolConsole -DataDirectory (Join-Path $qa 'custom settings') -ScriptPath (Join-Path $qa 'app folder\SmartPatrol.ps1')
Check ($script:launchArgs -ceq $plan.Arguments -and $script:launchPath -ceq $plan.FilePath) 'Console dispatch forwards safe plan; fixture does not start process'
$tokens=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'SmartPatrol.ps1'),[ref]$tokens,[ref]$errors)
$commands=@($ast.FindAll({param($node)$node -is [Management.Automation.Language.CommandAst]},$true)|ForEach-Object GetCommandName)
Check ($commands -notcontains 'Invoke-WebRequest' -and $commands -notcontains 'Set-ItemProperty' -and $commands -notcontains 'Broadcast-EnvChange') 'Patrol has no independent HTTP, registry or broadcast write pipeline'
$cli=Join-Path $qa 'cli fixture';[void][IO.Directory]::CreateDirectory($cli)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'SmartPatrol.ps1') -Destination (Join-Path $cli 'SmartPatrol.ps1')
$backend=@'
param([string]$DataDirectory='')
$script:DataRoot=Join-Path $PSScriptRoot 'isolated';$script:ProductVersion='3.9.9'
[IO.File]::WriteAllText((Join-Path $PSScriptRoot 'input.txt'),$DataDirectory)
function Get-NetworkDiagnosis {[pscustomobject]@{RepairAction='';Issues=@();Endpoints=@()}}
function Get-TcpObservationSnapshot {[pscustomobject]@{Available=$false;Rows=@()}}
function Get-UserProxyEnv {[pscustomobject]@{HTTP_PROXY='';HTTPS_PROXY='';ALL_PROXY=''}}
function Get-SmartPatrolMachineValue($Name){''}
function Get-SmartPatrolHostsState {[pscustomobject]@{State='Unknown';Mappings=0}}
function Get-SystemSnapshot {[pscustomobject]@{Flags=1;Bypass=''}}
function Get-NetworkTopologyObservation {[pscustomobject]@{State='Unknown';IPv4='Unknown';IPv6='Unknown'}}
function Write-LocalJson($Path,$Value){[IO.File]::WriteAllText($Path,(ConvertTo-Json -InputObject $Value -Depth 8))}
'@
[IO.File]::WriteAllText((Join-Path $cli 'ProxyBackend.ps1'),$backend,(New-Object Text.UTF8Encoding($true)))
function Run-CliFixture([string]$File,[string]$Arguments=''){
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "'+$File+'" '+$Arguments;$psi.UseShellExecute=$false;$psi.CreateNoWindow=$true;$psi.RedirectStandardOutput=$true;$psi.RedirectStandardError=$true
    $p=New-Object Diagnostics.Process;$p.StartInfo=$psi;[void]$p.Start();$out=$p.StandardOutput.ReadToEndAsync();$err=$p.StandardError.ReadToEndAsync();$p.WaitForExit();$code=$p.ExitCode;$p.Dispose();$code
}
$cliScript=Join-Path $cli 'SmartPatrol.ps1'
Check ((Run-CliFixture $cliScript) -eq 0 -and [IO.File]::ReadAllText((Join-Path $cli 'input.txt')) -ceq '') 'Actual CLI forwards empty default selection so legacy migration remains available'
Check ((Run-CliFixture $cliScript ('-DataDirectory "'+$script:DataRoot+'"')) -eq 0 -and [IO.File]::ReadAllText((Join-Path $cli 'input.txt')) -ceq $script:DataRoot) 'Actual CLI forwards explicit custom directory unchanged'
Check ((Run-CliFixture $cliScript '-MachineOnly -Yes') -eq 2) 'Actual machine cleanup entry is refused before any backend load'
$harness='& (Join-Path $PSScriptRoot ''SmartPatrol.ps1'') -KeepOpen'+[Environment]::NewLine+'[IO.File]::WriteAllText((Join-Path $PSScriptRoot ''returned.txt''),''returned'')'
[IO.File]::WriteAllText((Join-Path $cli 'KeepOpen.ps1'),$harness,(New-Object Text.UTF8Encoding($true)))
Check ((Run-CliFixture (Join-Path $cli 'KeepOpen.ps1')) -eq 0 -and (Test-Path -LiteralPath (Join-Path $cli 'returned.txt'))) 'KeepOpen returns to shell instead of terminating the console'
Write-Output ('PASS: '+$script:checks+' smart patrol assertions; all host/network writes and reads isolated or stubbed. Retained '+$qa)
