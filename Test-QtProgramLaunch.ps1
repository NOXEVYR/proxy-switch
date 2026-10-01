[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-qt-launch-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory (Join-Path $qa 'data')
$script:Checks=0;$script:WindowsWrites=0;$script:Ingress=$null;$script:ReadyCalls=0;$script:PreservingStarts=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
function Throws([scriptblock]$Action,[string]$Pattern){
    $message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message}
    Check ($message -match $Pattern) ('Expected fixed rejection: '+$Pattern)
    return $message
}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Set-SystemSnapshot {$script:WindowsWrites++;throw 'Real Windows writes forbidden'}
function Set-UserProxyEnv {$script:WindowsWrites++;throw 'Real user environment writes forbidden'}
function Get-SystemSnapshot {[pscustomobject]@{Flags=3;Server='127.0.0.1:19990';Bypass='fixture-only'}}
function Get-UserProxyEnv {[pscustomobject]@{HTTP_PROXY=$null;HTTPS_PROXY=$null;ALL_PROXY=$null;NO_PROXY='localhost'}}
function Get-Listener {[pscustomobject]@{PID=1;Name='Fixture-only listener observation'}}
function Get-ProcessInventory {@()}
function Get-ProgramFamily {@()}
function Get-ManagedProgramIngress($Executable){$script:Ingress}
function Ensure-ManagedGateway([switch]$PreserveWindowsSettings){$script:ReadyCalls++;if($PreserveWindowsSettings){$script:PreservingStarts++}}
function Wait-ManagedProgramIngressReady($Ingress,$Cancellation){$script:ReadyCalls++;[pscustomobject]@{LimitedDirect=$false}}
function Wait-ManagedProxyReady($Key){$script:ReadyCalls++}
function Invoke-AppRouter {throw 'The launch test must not contact an actual engine'}
function Get-VerifiedProgramShortcuts {@()}
$script:Profiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
    @{Id='a';Name='Fixture A';Protocol='http';Host='127.0.0.1';Port=19990;CorePath='';AppPath=''},
    @{Id='b';Name='Fixture B';Protocol='http';Host='127.0.0.1';Port=19991;CorePath='';AppPath=''}
);Routing=@{Adapter='none';ProfileId=''}})
$names=@('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','FTP_PROXY','NO_PROXY','QTWEBENGINE_CHROMIUM_FLAGS','QTWEBENGINEPROCESS_PATH')
$caller=[ordered]@{};$user=[ordered]@{}
foreach($name in $names){$caller[$name]=[Environment]::GetEnvironmentVariable($name,'Process');$user[$name]=[Environment]::GetEnvironmentVariable($name,'User')}
$callerHash=Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes $caller)
$userHash=Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes $user)
$systemHash=Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes ([LocalProxySwitch.Native]::Read()))
[void][IO.Directory]::CreateDirectory($qa)

function Build-Fixture([string]$Version,[string]$Name,[bool]$Library=$false){
    $output=Join-Path $qa ($Name+$(if($Library){'.dll'}else{'.exe'}))
    $type='QtFixture'+[Guid]::NewGuid().ToString('N')
    if($Library){$code='using System.Reflection;[assembly:AssemblyFileVersion("'+$Version+'")]public class '+$type+' {}'}
    else{
        $code=@'
using System;using System.IO;using System.Diagnostics;using System.Reflection;using System.Threading;
[assembly:AssemblyFileVersion("VERSION")]
public static class CLASSNAME {
 public static void Main(string[] args) {
  bool child=args.Length>0 && args[0]=="--fixture-child";
  var keys=new string[]{"HTTP_PROXY","HTTPS_PROXY","ALL_PROXY","FTP_PROXY","NO_PROXY","QTWEBENGINE_CHROMIUM_FLAGS"};
  var lines=new string[keys.Length+1];
  for(int i=0;i<keys.Length;i++)lines[i]=Environment.GetEnvironmentVariable(keys[i])??"";
  lines[keys.Length]=String.Join(" ",args);
  File.WriteAllLines(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,child?"child.txt":"parent.txt"),lines);
  if(child)return;
  var info=new ProcessStartInfo(Path.Combine(AppDomain.CurrentDomain.BaseDirectory,"QtWebEngineProcess.exe"),"--fixture-child");
  info.UseShellExecute=false;info.CreateNoWindow=true;
  using(var ownChild=Process.Start(info)){if(!ownChild.WaitForExit(5000))Environment.ExitCode=2;}
  Thread.Sleep(600);
 }
}
'@
        $code=$code.Replace('VERSION',$Version).Replace('CLASSNAME',$type)
    }
    Add-Type -TypeDefinition $code -OutputAssembly $output -OutputType $(if($Library){'Library'}else{'WindowsApplication'})
    return $output
}
$v5=Build-Fixture '5.15.2.0' 'template5'
$d5=Build-Fixture '5.15.2.0' 'library5' $true
$v6=Build-Fixture '6.5.0.0' 'template6'
$d6=Build-Fixture '6.5.0.0' 'library6' $true
$wrong=Build-Fixture '5.15.3.0' 'wrong-version' $true
function New-Fixture([string]$Name,[int]$Generation=5,[switch]$Libexec){
    $dir=Join-Path $qa $Name;[void][IO.Directory]::CreateDirectory($dir)
    $exe=Join-Path $dir 'Launcher.exe'
    $template=$(if($Generation -eq 5){$v5}else{$v6});$dll=$(if($Generation -eq 5){$d5}else{$d6})
    Copy-Item -LiteralPath $template -Destination $exe
    foreach($part in @('Core','Network','WebEngineCore')){Copy-Item -LiteralPath $dll -Destination (Join-Path $dir ('Qt'+$Generation+$part+'.dll'))}
    $helper=$dir;if($Libexec){$helper=Join-Path $dir 'libexec';[void][IO.Directory]::CreateDirectory($helper)}
    Copy-Item -LiteralPath $template -Destination (Join-Path $helper 'QtWebEngineProcess.exe')
    return $exe
}
function New-TestStartInfo([string]$Path,[string]$Flags=''){
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$Path;$psi.WorkingDirectory=[IO.Path]::GetDirectoryName($Path)
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$true
    foreach($name in $names){foreach($key in @($psi.EnvironmentVariables.Keys)){if([string]$key -ieq $name){$psi.EnvironmentVariables.Remove([string]$key)}}}
    $psi.EnvironmentVariables['http_proxy']='http://127.0.0.1:19998'
    $psi.EnvironmentVariables['https_proxy']='http://127.0.0.1:19998'
    $psi.EnvironmentVariables['all_proxy']='http://127.0.0.1:19998'
    $psi.EnvironmentVariables['ftp_proxy']='http://127.0.0.1:19998'
    $psi.EnvironmentVariables['no_proxy']='*'
    $psi.EnvironmentVariables['qtwebengine_chromium_flags']=$Flags
    return $psi
}
function Test-Inheritance([string]$Path,$Plan,[string]$OldFlags,[string]$ExpectedProxy,[string]$ExpectedFlags){
    $psi=New-TestStartInfo $Path $OldFlags
    Set-ProgramLaunchEnvironment $psi $Plan
    $psi.Arguments=(@($Plan.Arguments|ForEach-Object {ConvertTo-ProgramArgument $_}) -join ' ')
    $owned=[Diagnostics.Process]::Start($psi)
    try{
        Check ($owned.WaitForExit(10000)) 'Only the own fixture process completes normally'
        Check ($owned.ExitCode -eq 0) 'Own fixture parent observes its child complete normally'
        foreach($file in @('parent.txt','child.txt')){
            $actual=@(Get-Content -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($Path)) $file))
            Check ($actual.Count -eq 7) 'Parent and child write only the fixture-selected environment fields'
            foreach($i in 0..2){Check ($actual[$i] -ceq $ExpectedProxy) 'Actual parent and child use the selected proxy rather than inherited stale address'}
            Check ($actual[3] -ceq '') 'Qt launch clears the private FTP proxy value'
            Check ($actual[4] -ceq $(if($ExpectedProxy){'localhost,127.0.0.1,::1'}else{'*'})) 'Actual parent and child receive the selected bypass'
            Check ($actual[5] -ceq $ExpectedFlags) 'Actual Qt flags preserve old non-network flags and contain the chosen route'
            if($file -eq 'parent.txt'){Check ($actual[6] -ceq '') 'Qt launch does not pass Chromium flags to the original EXE'}
            else{Check ($actual[6] -ceq '--fixture-child') 'Child launch retains its own arguments'}
        }
    }finally{$owned.Dispose()}
}

$qt=New-Fixture 'qt5'
Check ((Get-ProgramProxyAdapter $qt) -ceq 'qtwebengine') 'Complete Qt5 layout is recognized without Electron paks'
$qt6=New-Fixture 'qt6' 6
Check ((Get-ProgramProxyAdapter $qt6) -ceq 'qtwebengine') 'Matching Qt6 layout is recognized'
$nested=New-Fixture 'nested-helper' 5 -Libexec
Check ((Get-ProgramProxyAdapter $nested) -ceq 'qtwebengine') 'Adjacent libexec helper has an independently checked matching version'
foreach($part in @('Core','Network','WebEngineCore')){
    $incomplete=New-Fixture ('missing-'+$part);$dir=[IO.Path]::GetDirectoryName($incomplete)
    $original=Join-Path $dir ('Qt5'+$part+'.dll');Move-Item -LiteralPath $original -Destination ($original+'.disabled')
    foreach($name in @('resources.pak','chrome_100_percent.pak')){[IO.File]::WriteAllText((Join-Path $dir $name),'inert')}
    Check ((Get-ProgramProxyAdapter $incomplete) -ceq '') 'Incomplete Qt module layout is refused'
}
$missing=New-Fixture 'missing-helper';$dir=[IO.Path]::GetDirectoryName($missing)
Move-Item -LiteralPath (Join-Path $dir 'QtWebEngineProcess.exe') -Destination (Join-Path $dir 'helper.disabled')
foreach($name in @('resources.pak','chrome_100_percent.pak')){[IO.File]::WriteAllText((Join-Path $dir $name),'inert')}
Check ((Get-ProgramProxyAdapter $missing) -ceq '') 'Partial Qt cannot become Chromium merely because generic paks exist'
$bad=New-Fixture 'wrong-dll';Copy-Item -LiteralPath $wrong -Destination (Join-Path ([IO.Path]::GetDirectoryName($bad)) 'Qt5Network.dll') -Force
Check ((Get-ProgramProxyAdapter $bad) -ceq '') 'Mismatched Qt patch versions are refused'
$bad=New-Fixture 'wrong-helper';Copy-Item -LiteralPath $v6 -Destination (Join-Path ([IO.Path]::GetDirectoryName($bad)) 'QtWebEngineProcess.exe') -Force
Check ((Get-ProgramProxyAdapter $bad) -ceq '') 'Qt5 with Qt6 helper is refused'
$bad=New-Fixture 'missing-version';[IO.File]::WriteAllText((Join-Path ([IO.Path]::GetDirectoryName($bad)) 'Qt5Core.dll'),'inert unversioned module')
Check ((Get-ProgramProxyAdapter $bad) -ceq '') 'Unversioned module is not treated as a known Qt runtime'
$mixed=New-Fixture 'mixed-generation';Copy-Item -LiteralPath $d6 -Destination (Join-Path ([IO.Path]::GetDirectoryName($mixed)) 'Qt6Core.dll')
Check ((Get-ProgramProxyAdapter $mixed) -ceq '') 'Two Qt generations are ambiguous and refused'
$case=New-Fixture 'case-folded';$dir=[IO.Path]::GetDirectoryName($case)
Move-Item -LiteralPath (Join-Path $dir 'Qt5Network.dll') -Destination (Join-Path $dir 'qt5network.case')
Move-Item -LiteralPath (Join-Path $dir 'qt5network.case') -Destination (Join-Path $dir 'QT5NETWORK.DLL')
Check ((Get-ProgramProxyAdapter $case) -ceq 'qtwebengine') 'Windows filename matching tolerates module casing'

$plan=Get-ProgramLaunchPlan $qt 'a'
Check ($plan.Adapter -ceq 'qtwebengine' -and @($plan.Arguments).Count -eq 0) 'Qt plans identify their adapter without original-EXE flags'
Check ($plan.QtWebEngineArguments -contains '--proxy-server=http://127.0.0.1:19990') 'Legacy Qt proxy selects the requested HTTP route'
$flags='--disable-gpu --lang="zh CN" --enable-features=FixtureFeature'
Test-Inheritance $qt $plan $flags 'http://127.0.0.1:19990' ($flags+' --proxy-server=http://127.0.0.1:19990 --proxy-bypass-list=localhost;127.0.0.1;[::1]')
$direct=Get-ProgramLaunchPlan $qt 'Direct'
Check ($direct.QtWebEngineArguments -contains '--no-proxy-server' -and @($direct.Arguments).Count -eq 0) 'Legacy Qt Direct disables only the new Qt web component proxy'
Test-Inheritance $qt $direct $flags '' ($flags+' --no-proxy-server')
$follow=Get-ProgramLaunchPlan $qt 'Follow'
Check ($follow.Route -ceq 'a' -and $follow.Endpoint -ceq $plan.Endpoint) 'Legacy Follow resolves to the current system profile'
$second=Get-ProgramLaunchPlan $qt6 'b'
Test-Inheritance $qt6 $second '--disable-gpu' 'http://127.0.0.1:19991' '--disable-gpu --proxy-server=http://127.0.0.1:19991 --proxy-bypass-list=localhost;127.0.0.1;[::1]'

foreach($flag in @('--proxy-server=http://private.invalid','--PROXY-PAC-URL=https://private.invalid/secret','--no-proxy-server','--proxy-bypass-list=*','--host-resolver-rules="MAP secret *"','--use-system-proxy-resolver','--winhttp-proxy-resolver','--auto-detect-proxy')){
    $psi=New-TestStartInfo $qt $flag;$before=@($psi.EnvironmentVariables.Keys|Sort-Object|ForEach-Object {$_+'='+$psi.EnvironmentVariables[$_]}) -join "`n"
    $message=Throws {Set-ProgramLaunchEnvironment $psi $plan} '已有代理、PAC 或域名解析参数'
    Check ($message -notmatch 'private|secret|proxy-server=') 'Conflict rejection does not expose inherited network values'
    $after=@($psi.EnvironmentVariables.Keys|Sort-Object|ForEach-Object {$_+'='+$psi.EnvironmentVariables[$_]}) -join "`n"
    Check ($before -ceq $after) 'Rejected merge leaves even the private StartInfo block unchanged'
}
foreach($badFlags in @('--lang="unfinished',"--disable-gpu`n--lang=zh")){
    [void](Throws {Merge-QtWebEngineLaunchFlags $badFlags @('--no-proxy-server')} '无法安全解析')
}
$psi=New-TestStartInfo $qt;$psi.EnvironmentVariables['QTWEBENGINEPROCESS_PATH']='C:\fixture-secret\helper.exe'
$message=Throws {Set-ProgramLaunchEnvironment $psi $plan} '辅助程序路径'
Check ($message -notmatch 'fixture-secret') 'Unknown helper overrides are rejected without disclosure'
$psi=New-TestStartInfo $qt;$psi.UseShellExecute=$true
[void](Throws {Set-ProgramLaunchEnvironment $psi $plan} '独立的新进程')
[void](Throws {Merge-QtWebEngineLaunchFlags '' @('--proxy-server=http://bad.invalid private')} '目标代理参数无效')
[void](Throws {Merge-QtWebEngineLaunchFlags '' @('--no-proxy-server','--proxy-server=http://127.0.0.1:19990')} '目标代理参数无效')

$chromeDir=Join-Path $qa 'chrome';[void][IO.Directory]::CreateDirectory($chromeDir)
$chrome=Join-Path $chromeDir 'ChromeFixture.exe';Copy-Item -LiteralPath $v5 -Destination $chrome
foreach($name in @('resources.pak','chrome_100_percent.pak')){[IO.File]::WriteAllText((Join-Path $chromeDir $name),'inert')}
Check ((Get-ProgramProxyAdapter $chrome) -ceq 'chromium') 'Existing Chromium resource layout retains its adapter'
$chromePlan=Get-ProgramLaunchPlan $chrome 'a';$psi=New-TestStartInfo $chrome $flags
Set-ProgramLaunchEnvironment $psi $chromePlan
Check ($chromePlan.Arguments -contains '--proxy-server=http://127.0.0.1:19990' -and $psi.EnvironmentVariables['QTWEBENGINE_CHROMIUM_FLAGS'] -ceq $flags) 'Chromium still uses original-EXE flags and does not rewrite unrelated Qt flags'
$chromeDirect=Get-ProgramLaunchPlan $chrome 'Direct'
Check ($chromeDirect.Arguments -contains '--no-proxy-server' -and $chromeDirect.Environment.NO_PROXY -ceq '*') 'Chromium legacy Direct remains unchanged'
Set-ProgramLaunchRoute $qt 'a'|Out-Null
Check ((Get-ProgramLaunchEntries).adapter -ceq 'qtwebengine') 'Saved Qt route carries the discovered adapter'
Set-ProgramLaunchRoute $chrome 'a'|Out-Null
Check (@(Get-ProgramLaunchEntries).Count -eq 2) 'Legacy Chromium and Qt records coexist in the same schema'
$savedEntries=@(Get-ProgramLaunchEntries)
Write-LocalJson (Join-Path $script:DataRoot 'program-proxies.json') @{version=1;entries=@(@{path=$qt;route='a';adapter='unknown-adapter'})}
[void](Throws {Get-ProgramLaunchEntries} '配置无效')
Write-LocalJson (Join-Path $script:DataRoot 'program-proxies.json') @{version=1;entries=$savedEntries}

# Real Start-ManagedProgram uses the existing stable entrance rather than an upstream port.
$managed=New-Fixture 'managed'
$script:Ingress=[pscustomobject]@{id=('a'*32);path=$managed;port=19992;route='Direct'}
$managedPlan=Get-ProgramLaunchPlan $managed 'Direct'
Check ($managedPlan.Endpoint -ceq 'http://127.0.0.1:19992' -and $managedPlan.QtWebEngineArguments -contains '--proxy-server=http://127.0.0.1:19992') 'Managed Direct still targets its stable entrance; the engine decides Direct'
Check ($managedPlan.QtWebEngineArguments -notcontains '--no-proxy-server') 'Managed Direct does not bypass per-program site rules'
$result=Start-ManagedProgram $managed
$owned=[Diagnostics.Process]::GetProcessById($result.PID)
try{
    Check ($owned.WaitForExit(10000)) 'The managed own fixture exits normally without a forced stop'
    $actual=@(Get-Content -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($managed)) 'child.txt'))
    Check ($actual[0] -ceq 'http://127.0.0.1:19992' -and $actual[5] -match '--proxy-server=http://127\.0\.0\.1:19992') 'Managed Qt parent and child inherit the stable entrance'
    Check ($result.Route -ceq 'Direct' -and $result.Message -match 'Qt 网页组件' -and $result.Message -match '独立联网组件' -and $result.Message -match '登录结果仍需验证') 'Managed result states component coverage rather than overall login success'
    Check ($script:ReadyCalls -ge 2) 'Managed Qt launch retains gateway and entrance readiness checks'
    Check ($script:PreservingStarts -eq 1) 'Managed Qt entrance readiness requests a Windows-preserving service start'
}finally{$owned.Dispose()}
$script:Ingress=$null

$latestCaller=[ordered]@{};$latestUser=[ordered]@{}
foreach($name in $names){$latestCaller[$name]=[Environment]::GetEnvironmentVariable($name,'Process');$latestUser[$name]=[Environment]::GetEnvironmentVariable($name,'User')}
Check ((Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes $latestCaller)) -ceq $callerHash) 'No tested plan or launch changes the caller proxy/Qt environment'
Check ((Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes $latestUser)) -ceq $userHash) 'No tested plan or launch changes persistent user proxy/Qt environment'
Check ((Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes ([LocalProxySwitch.Native]::Read()))) -ceq $systemHash) 'Real system proxy snapshot remains unchanged'
Check ($script:WindowsWrites -eq 0) 'No launch path invokes Windows or user proxy writes'
Write-Output ('PASS: '+$script:Checks+' Qt/Chromium adapter, environment and real fixture parent-child assertions; no user application, account or network configuration changes.')
