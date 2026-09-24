$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-clean-start-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($qa)
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory (Join-Path $qa 'data')
$script:Checks=0;$script:Writes=0;$script:LockDepth=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
function Throws([scriptblock]$Action,[string]$Pattern){$message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message};Check ($message -match $Pattern) ('Expected refusal: '+$Pattern)}
$script:AutoFingerprint='fixture-auto'
$script:Before=[pscustomobject]@{Flags=3;Server='127.0.0.1:19001';Bypass='fixture.local';AutomaticConfigFingerprint=$script:AutoFingerprint}
$script:Current=$script:Before.PSObject.Copy()
function Get-SystemSnapshot {$script:Current.PSObject.Copy()}
function Get-CleanStartSystemSnapshot {$value=Get-SystemSnapshot;$value|Add-Member AutomaticConfigFingerprint $script:AutoFingerprint -Force;return $value}
function Set-SystemSnapshot($Value){$script:Writes++;$script:Current=$Value.PSObject.Copy()}
function Set-UserProxyEnv {throw 'Tests must never change persistent environment variables'}
function Use-ChangeLock([scriptblock]$Action){$script:LockDepth++;try{& $Action}finally{$script:LockDepth--}}
function Invoke-AppRouter {throw 'Clean start tests must not contact a real routing engine'}
$fixtureDirectory=Join-Path $qa 'fixture';[void][IO.Directory]::CreateDirectory($fixtureDirectory)
$fixture=Join-Path $fixtureDirectory 'CleanFixture.exe'
$code=@'
using System;using System.IO;using System.Diagnostics;using System.Threading;
public static class CleanFixture {
 public static void Main(string[] args){
  string folder=AppDomain.CurrentDomain.BaseDirectory;
  bool child=args.Length>0 && args[0]=="--child";
  if(!child)File.AppendAllText(Path.Combine(folder,"root-starts.txt"),Process.GetCurrentProcess().Id+Environment.NewLine);
  string[] names={"HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","FTP_PROXY","NO_PROXY","FLOWSWITCH_TEST_KEEP"};
  using(var output=new StreamWriter(Path.Combine(folder,child?"child-env.txt":"parent-env.txt"))){foreach(string name in names)output.WriteLine(name+"="+(Environment.GetEnvironmentVariable(name)??"<null>"));}
  if(!child){var info=new ProcessStartInfo(Path.Combine(folder,"CleanFixture.exe"),"--child");info.UseShellExecute=false;info.CreateNoWindow=true;using(var process=Process.Start(info))process.WaitForExit(5000);}
  var until=DateTime.UtcNow.AddSeconds(20);while(File.Exists(Path.Combine(folder,"hold"))&&!File.Exists(Path.Combine(folder,"stop"))&&DateTime.UtcNow<until)Thread.Sleep(25);
 }
}
'@
Add-Type -TypeDefinition $code -OutputAssembly $fixture -OutputType WindowsApplication
$savedEnvironment=@{};foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','FTP_PROXY','NO_PROXY','FLOWSWITCH_TEST_KEEP','QTWEBENGINE_CHROMIUM_FLAGS')){$savedEnvironment[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
try{
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','FTP_PROXY')){[Environment]::SetEnvironmentVariable($name,'http://127.0.0.1:19999','Process')}
    [Environment]::SetEnvironmentVariable('NO_PROXY','old.local','Process');[Environment]::SetEnvironmentVariable('FLOWSWITCH_TEST_KEEP','preserved','Process');[Environment]::SetEnvironmentVariable('QTWEBENGINE_CHROMIUM_FLAGS',$null,'Process')
    $info=New-CleanProgramStartInfo $fixture
    Check (-not $info.UseShellExecute -and $info.WorkingDirectory -eq $fixtureDirectory -and $info.EnvironmentVariables['NO_PROXY'] -eq '*') 'Clean launch creates a separate inherited environment and correct working directory'
    foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','FTP_PROXY')){Check (-not $info.EnvironmentVariables.ContainsKey($name)) ('Only child launch environment removes '+$name)}
    $process=[Diagnostics.Process]::Start($info)
    try{Check ($process.WaitForExit(8000)) 'Real clean-environment parent and child fixture exit successfully'}finally{$process.Dispose()}
    foreach($name in @('parent-env.txt','child-env.txt')){
        $lines=[IO.File]::ReadAllLines((Join-Path $fixtureDirectory $name))
        Check (@($lines|Where-Object {$_ -match '^(HTTP_PROXY|HTTPS_PROXY|ALL_PROXY|FTP_PROXY)=<null>$'}).Count -eq 4 -and $lines -contains 'NO_PROXY=*' -and $lines -contains 'FLOWSWITCH_TEST_KEEP=preserved') ('Real '+$name+' inherits cleared proxies and unrelated environment intact')
    }
    Check ([Environment]::GetEnvironmentVariable('HTTP_PROXY','Process') -eq 'http://127.0.0.1:19999' -and $script:Writes -eq 0) 'Actual parent-child launch does not change the host environment or Windows proxy'
    [Environment]::SetEnvironmentVariable('QTWEBENGINE_CHROMIUM_FLAGS','--proxy-server=http://127.0.0.1:19999','Process')
    Throws {New-CleanProgramStartInfo $fixture} '额外.*网络'
    [Environment]::SetEnvironmentVariable('QTWEBENGINE_CHROMIUM_FLAGS',$null,'Process')
    $plan=Get-ProgramCleanStartPlan $fixture
    Check ($plan.Path -eq $fixture -and -not $plan.DirectTest -and $plan.FileId -and $plan.Revision -and $script:Writes -eq 0) 'Preparing a clean launch is read-only and binds executable identity and configuration revision'
    $stale=$plan.PSObject.Copy();$stale.CreatedAt-=91;Throws {Assert-CleanStartPlan $stale} '过期'
    $future=$plan.PSObject.Copy();$future.CreatedAt+=20;Throws {Assert-CleanStartPlan $future} '过期'
    $changed=$plan.PSObject.Copy();$changed.FileId='not-the-file';Throws {Assert-CleanStartPlan $changed} '文件.*改变'
    $changed=$plan.PSObject.Copy();$changed.Revision='not-the-rules';Throws {Assert-CleanStartPlan $changed} '线路.*改变'
    $invalid=$plan.PSObject.Copy();$invalid.DirectTest='true';Throws {Assert-CleanStartPlan $invalid} '计划无效'
    Throws {Start-ProgramCleanSession $plan} '先确认'
    $script:Current=[pscustomobject]@{Flags=3;Server='127.0.0.1:19998';Bypass='external'};Throws {Assert-CleanStartPlan $plan} '系统代理.*改变';$script:Current=$script:Before.PSObject.Copy()
    $script:AutoFingerprint='changed-auto';Throws {Assert-CleanStartPlan $plan} '系统代理.*改变';$script:AutoFingerprint='fixture-auto'
    [IO.File]::WriteAllText((Join-Path $fixtureDirectory 'hold'),'hold')
    $process=[Diagnostics.Process]::Start((New-CleanProgramStartInfo $fixture))
    try{Start-Sleep -Milliseconds 250;Throws {Assert-CleanProgramStopped $fixture} '仍在运行'}finally{[IO.File]::WriteAllText((Join-Path $fixtureDirectory 'stop'),'stop');[void]$process.WaitForExit(8000);$process.Dispose()}
    $inventoryReader=${function:Get-ProcessInventory}
    function Get-ProcessInventory { @([pscustomobject]@{Id=49100;ParentId=0;ProcessName='CleanFixture';Path='';StartTime=$null}) }
    Throws {Assert-CleanProgramStopped $fixture} '同名.*身份不可读取'
    Set-Item Function:Get-ProcessInventory $inventoryReader
    $sessionId=[Guid]::NewGuid().ToString('N');$sessionFolder=Join-Path $script:DataRoot ('clean-start\'+$sessionId)
    Write-LocalJson (Join-Path $script:DataRoot 'clean-start-current.json') @{Id=$sessionId}
    Write-LocalJson (Join-Path $sessionFolder 'status.json') @{Phase='preparing';Message='fixture pending session'}
    Throws {Start-ProgramCleanSession (Get-ProgramCleanStartPlan $fixture) -Confirmed} '尚未结束'
    Write-LocalJson (Join-Path $sessionFolder 'status.json') @{Phase='complete';Message='fixture finished session'}
    $writerBeforeMonitor=${function:Write-LocalJson};$script:MonitorStarts=0
    function Write-LocalJson($Path,$Value){if([IO.Path]::GetFileName($Path) -eq 'monitor-launch.json'){throw 'fixture monitor evidence write failure'};& $writerBeforeMonitor $Path $Value}
    function Start-Process {param($FilePath,$WindowStyle,$ArgumentList,[switch]$PassThru);$script:MonitorStarts++;$stub=[pscustomobject]@{Id=49010;StartTime=[DateTime]::UtcNow};$stub|Add-Member ScriptMethod Dispose {};return $stub}
    try{
        $submitted=Start-ProgramCleanSession (Get-ProgramCleanStartPlan $fixture) -Confirmed
        Check ($submitted.SessionId -and $script:MonitorStarts -eq 1 -and (Get-CleanStartSession).Status.Phase -ne 'failed') 'Monitor process submission followed by metadata failure is not mislabeled as an unstarted worker'
    }finally{Set-Item Function:Write-LocalJson $writerBeforeMonitor;Remove-Item Function:Start-Process}
    $target=[pscustomobject]@{Flags=1;Server=$script:Before.Server;Bypass=$script:Before.Bypass;AutomaticConfigFingerprint=$script:AutoFingerprint};$script:Current=$target.PSObject.Copy();$script:Writes=0
    Check ((Restore-CleanStartSnapshot $script:Before $target) -eq 'restored' -and (Test-SameSnapshot $script:Current $script:Before) -and $script:Writes -eq 1) 'Owned temporary direct settings restore to the exact previous proxy'
    $script:Current=[pscustomobject]@{Flags=3;Server='127.0.0.1:19998';Bypass='external'};$script:Writes=0
    Check ((Restore-CleanStartSnapshot $script:Before $target) -eq 'external-change' -and $script:Writes -eq 0 -and $script:Current.Server -eq '127.0.0.1:19998') 'External system proxy changes are preserved during restoration'
    $script:Current=$target.PSObject.Copy();$script:AutoFingerprint='external-pac'
    Check ((Restore-CleanStartSnapshot $script:Before $target) -eq 'external-change' -and $script:Writes -eq 0) 'A changed automatic proxy configuration is preserved even when manual proxy fields match'
    $script:AutoFingerprint='fixture-auto'
    $script:Current=$script:Before.PSObject.Copy();Check ((Restore-CleanStartSnapshot $script:Before $target) -eq 'restored' -and $script:Writes -eq 0) 'Restoration is idempotent when settings already match the original'
}finally{foreach($name in $savedEnvironment.Keys){[Environment]::SetEnvironmentVariable($name,$savedEnvironment[$name],'Process')}}

# Exercise the actual worker in child PowerShell processes. Its backend is a test
# adapter over the real functions; every Windows/RunOnce writer is replaced below.
# The copied worker only changes its mutex namespace so it cannot block a live session.
$harness=Join-Path $qa 'worker';[void][IO.Directory]::CreateDirectory($harness)
$workerSource=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'CleanStartWorker.ps1')).Replace('Local\FlowSwitch-CleanStart-','Local\FlowSwitch-Test-CleanStart-'+[Guid]::NewGuid().ToString('N')+'-')
[IO.File]::WriteAllText((Join-Path $harness 'CleanStartWorker.ps1'),$workerSource,(New-Object Text.UTF8Encoding($true)))
$backendPath=(Join-Path $PSScriptRoot 'ProxyBackend.ps1').Replace("'","''")
$backend=@'
param([string]$DataDirectory)
. '__BACKEND__' -DataDirectory $DataDirectory
$script:Scenario=[IO.File]::ReadAllText((Join-Path $DataDirectory 'scenario'))
$script:MockSystem=[pscustomobject]@{Flags=3;Server='127.0.0.1:19001';Bypass='fixture.local';AutomaticConfigFingerprint='fixture-auto'}
$script:MockLock=0
function Log-Mock([string]$Text){[IO.File]::AppendAllText((Join-Path $script:DataRoot 'events'),$Text+"`r`n")}
function Use-ChangeLock([scriptblock]$Action){$script:MockLock++;try{& $Action}finally{$script:MockLock--}}
function Get-SystemSnapshot {return $script:MockSystem.PSObject.Copy()}
function Get-CleanStartSystemSnapshot {return Get-SystemSnapshot}
function Get-CleanStartRecoveryRoot {Join-Path $script:DataRoot 'r'}
function Start-CleanStartRecoveryGuard([string]$WorkerPath,[string]$SessionId,[string]$Directory){Log-Mock 'guard:ready';return [pscustomobject]@{PID=49002;StartTicks='1';Path='fixture-guard'}}
function Get-CleanStartProcessState($Identity){if($Identity){return 'alive'};return 'unknown'}
function Set-SystemSnapshot($Value){
    Log-Mock ('system:'+ $Value.Flags +':lock='+$script:MockLock)
    if($script:Scenario -eq 'restore-failure' -and $Value.Flags -eq 3){throw 'fixture restoration failure'}
    $script:MockSystem=$Value.PSObject.Copy()
    if($script:Scenario -eq 'external-change' -and $Value.Flags -eq 1){$script:MockSystem=[pscustomobject]@{Flags=3;Server='127.0.0.1:19998';Bypass='external'}}
    Write-LocalJson (Join-Path $script:DataRoot 'mock-system.json') $script:MockSystem
}
function Set-UserProxyEnv {throw 'Persistent environment writes forbidden'}
function Get-ProcessInventory {return @()}
function Invoke-AppRouter {throw 'Real engine invocation forbidden'}
function Test-Path {param($Path,$LiteralPath,$PathType,$ErrorAction);if($Path -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\RunOnce'){return $true};if($LiteralPath){Microsoft.PowerShell.Management\Test-Path -LiteralPath $LiteralPath}else{Microsoft.PowerShell.Management\Test-Path $Path}}
function New-ItemProperty {param($LiteralPath,$Name,$Value,$PropertyType,[switch]$Force);Log-Mock 'runonce:add';if($script:Scenario -eq 'runonce-failure'){throw 'fixture RunOnce failure'};[IO.File]::WriteAllText((Join-Path $script:DataRoot 'runonce'),$Value)}
function Get-ItemPropertyValue {param($LiteralPath,$Name,$ErrorAction);$path=Join-Path $script:DataRoot 'runonce';if([IO.File]::Exists($path)){[IO.File]::ReadAllText($path)}}
function Remove-ItemProperty {param($LiteralPath,$Name);Log-Mock 'runonce:remove';[IO.File]::Delete((Join-Path $script:DataRoot 'runonce'))}
function Start-Process {param($FilePath,$WindowStyle,$ArgumentList,$Verb,[switch]$PassThru);Log-Mock ('worker:'+ $WindowStyle);$session=(Get-Content (Join-Path $script:DataRoot 'clean-start-current.json') -Raw|ConvertFrom-Json).Id;$folder=Join-Path $script:DataRoot ('clean-start\'+$session);Write-LocalJson (Join-Path $folder 'ready.json') @{Ready=$true};$stub=[pscustomobject]@{Id=49001;StartTime=[DateTime]::UtcNow};$stub|Add-Member ScriptMethod Dispose {};return $stub}
function Start-Sleep {param($Milliseconds,$Seconds);$session=(Get-Content (Join-Path $script:DataRoot 'clean-start-current.json') -Raw|ConvertFrom-Json).Id;$folder=Join-Path $script:DataRoot ('clean-start\'+$session);if([IO.File]::Exists((Join-Path $folder 'go'))){if($script:Scenario -eq 'launch-failure'){Write-LocalJson (Join-Path $folder 'child-error.json') @{Message='fixture launch failure'}}else{Write-LocalJson (Join-Path $folder 'launched.json') @{PID=49001}};[IO.File]::WriteAllText((Join-Path $folder 'stop'),'stop')}else{Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 1}}
$realWriter=${function:Write-LocalJson}
function Write-LocalJson($Path,$Value){if($script:Scenario -eq 'record-failure' -and [IO.Path]::GetFileName($Path) -eq 'launched.json'){throw 'fixture evidence write failure'};& $realWriter $Path $Value}
'@
[IO.File]::WriteAllText((Join-Path $harness 'ProxyBackend.ps1'),$backend.Replace('__BACKEND__',$backendPath),(New-Object Text.UTF8Encoding($true)))
function Run-WorkerScenario([string]$Scenario,[string]$Mode='Monitor'){
    $data=Join-Path $qa $Scenario;[void][IO.Directory]::CreateDirectory($data)
    [IO.File]::WriteAllText((Join-Path $data 'scenario'),$Scenario)
    $oldRoot=$script:DataRoot;$script:DataRoot=$data
    try{$script:Current=$script:Before.PSObject.Copy();$plan=Get-ProgramCleanStartPlan $fixture ($Mode -eq 'Monitor')}finally{$script:DataRoot=$oldRoot}
    $id=[Guid]::NewGuid().ToString('N');$folder=Join-Path $data ('clean-start\'+$id);[void][IO.Directory]::CreateDirectory($folder)
    Write-LocalJson (Join-Path $data 'clean-start-current.json') @{Id=$id}
    Write-LocalJson (Join-Path $folder 'request.json') @{Version=1;Id=$id;UserSid=[Security.Principal.WindowsIdentity]::GetCurrent().User.Value;Plan=$plan;DataDirectory=$data;CreatedAt=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()}
    if($Mode -eq 'Child'){
        [IO.File]::WriteAllText((Join-Path $folder 'go'),'go')
        if($Scenario -eq 'cancel-before-launch'){[IO.File]::WriteAllText((Join-Path $folder 'cancel'),'cancel')}
        foreach($name in @('parent-env.txt','child-env.txt','root-starts.txt')){[IO.File]::Delete((Join-Path $fixtureDirectory $name))}
    }
    $shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    & $shell -NoProfile -ExecutionPolicy Bypass -File (Join-Path $harness 'CleanStartWorker.ps1') -DataDirectory $data -SessionId $id -Mode $Mode
    $status=$null;$childError=$null;$events=@()
    if([IO.File]::Exists((Join-Path $folder 'status.json'))){$status=Get-Content (Join-Path $folder 'status.json') -Raw|ConvertFrom-Json}
    if([IO.File]::Exists((Join-Path $folder 'child-error.json'))){$childError=Get-Content (Join-Path $folder 'child-error.json') -Raw|ConvertFrom-Json}
    if([IO.File]::Exists((Join-Path $data 'events'))){$events=[IO.File]::ReadAllLines((Join-Path $data 'events'))}
    [pscustomobject]@{Data=$data;Folder=$folder;Status=$status;ChildError=$childError;Events=$events;ExitCode=$LASTEXITCODE}
}
$result=Run-WorkerScenario 'restore-success'
Check ($result.Status.Phase -eq 'complete' -and $result.Events -contains 'runonce:add' -and $result.Events -contains 'runonce:remove') 'Actual monitor worker arms and removes mocked RunOnce recovery around a successful direct comparison'
Check (@($result.Events|Where-Object {$_ -match '^system:'}).Count -eq 2 -and @($result.Events|Where-Object {$_ -match '^system:.*lock=0$'}).Count -eq 0) 'Temporary proxy write and restoration occur under the shared change lock'
Check (($result.Events -join ',') -match 'runonce:add,.*system:1:') 'Recovery is armed before any simulated Windows proxy change'
$result=Run-WorkerScenario 'external-change'
Check ($result.Status.Phase -eq 'external-change' -and @($result.Events|Where-Object {$_ -match '^system:'}).Count -eq 1) 'Monitor restoration preserves external changes after a raced write'
$result=Run-WorkerScenario 'runonce-failure'
Check ($result.Status.Phase -eq 'failed' -and @($result.Events|Where-Object {$_ -match '^system:'}).Count -eq 0) 'Failed recovery registration prevents any temporary Windows proxy write'
$result=Run-WorkerScenario 'restore-failure'
Check ($result.Status.Phase -eq 'recovery-failed' -and [IO.File]::Exists((Join-Path $result.Data 'runonce')) -and [IO.File]::Exists((Join-Path $result.Folder 'recovery.json'))) 'Failed restoration retains both recovery snapshot and RunOnce fallback'
$result=Run-WorkerScenario 'launch-failure'
Check ($result.Status.Phase -eq 'launch-failed' -or ($result.Status.PSObject.Properties['LaunchPhase'] -and $result.Status.LaunchPhase -eq 'failed') -or ($result.Status.Message -match 'fixture launch failure')) 'Successful proxy restoration does not conceal a failed target launch'
$result=Run-WorkerScenario 'cancel-before-launch' 'Child'
Check (-not [IO.File]::Exists((Join-Path $fixtureDirectory 'parent-env.txt')) -and -not [IO.File]::Exists((Join-Path $result.Folder 'launched.json'))) 'A canceled monitor cannot cause a late child to launch after a go marker exists'
$result=Run-WorkerScenario 'record-failure' 'Child'
$deadline=[DateTime]::UtcNow.AddSeconds(5);while(-not [IO.File]::Exists((Join-Path $fixtureDirectory 'parent-env.txt')) -and [DateTime]::UtcNow -lt $deadline){Start-Sleep -Milliseconds 30}
Check ([IO.File]::Exists((Join-Path $fixtureDirectory 'parent-env.txt')) -and ($null -eq $result.ChildError -or $result.ChildError.Message -notmatch '程序未启动')) 'A Process.Start success followed by evidence write failure is never reported as a failed launch'
Check ([IO.File]::ReadAllLines((Join-Path $fixtureDirectory 'root-starts.txt')).Count -eq 1) 'Post-start evidence failure never retries or launches the target twice'
Write-Output ('PASS: '+$script:Checks+' clean-start checks; real temporary parent/child environment, actual worker with simulated Windows/RunOnce, identity/expiry and recovery boundaries.')
