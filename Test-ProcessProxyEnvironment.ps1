$ErrorActionPreference='Stop'
. (Join-Path $PSScriptRoot 'ProcessProxyEnvironment.ps1')
. (Join-Path $PSScriptRoot 'ProcessInventory.ps1')
. (Join-Path $PSScriptRoot 'NetworkDiagnostics.ps1')
$script:checks=0
function Check($Condition,[string]$Message) {if(-not $Condition){throw $Message};$script:checks++}
# Invalid identity loads the isolated reader but does not open a process.
$invalid=Get-ProcessProxyEnvironmentObservation -ProcessId 0 -ExpectedPath '' -ExpectedCreationTicks 0
Check ($invalid.State -eq 'Unknown' -and $invalid.ReasonCode -eq 'InvalidIdentity') 'Invalid target remains unknown'
Check ([LocalProxySwitch.ProcessProxyEnvironment]::QueryAccess -eq 0x410) 'Only QUERY_INFORMATION and VM_READ requested'
Check ([LocalProxySwitch.ProcessProxyEnvironment]::MaximumEnvironmentBytes -eq 262144) 'Environment read is capped at 256 KiB'
$reader=[LocalProxySwitch.ProcessProxyEnvironment]
foreach($value in @('http://127.0.0.1:19451','socks5h://[::1]:19452','localhost:19453')) {
    $row=$reader::SummarizeValue('HTTP_PROXY',$value)
    Check ($row.State -eq 'Observed' -and $row.EndpointKind -eq 'Loopback' -and $row.Port -ge 19451) 'Canonical loopback parses safely'
}
$private=$reader::SummarizeValue('HTTPS_PROXY','http://FakeUser:FakePassword@private-secret.invalid:4555')
Check ($private.EndpointKind -eq 'External' -and $private.HasCredentials -and $private.Port -eq 0 -and -not $private.LoopbackHost) 'External endpoint is generalized'
Check (($private|ConvertTo-Json -Compress) -notmatch 'FakeUser|FakePassword|private-secret|4555') 'External credentials and endpoint never serialize'
$credential=$reader::SummarizeValue('HTTP_PROXY','http://FakeUser:FakePassword@localhost:19454')
Check ($credential.HasCredentials -and $credential.Port -eq 19454 -and ($credential|ConvertTo-Json -Compress) -notmatch 'FakeUser|FakePassword') 'Loopback authentication only returns presence'
foreach($value in @('http://localhost:0','http://localhost:65536','http://localhost:19451/token-secret','http://localhost:19451/?token=SECRET','http://localhost:19451/#SECRET','ftp://localhost:21','127.1:19451','2130706433:19451','http://127.0.0.1:19451;https=elsewhere','http://localhost:19451\secret')) {
    $row=$reader::SummarizeValue('HTTP_PROXY',$value)
    Check ($row.State -eq 'Unknown' -and -not $row.LoopbackHost -and $row.Port -eq 0) 'Malformed or noncanonical endpoint is never actionable'
}
Check ($reader::SummarizeValue('HTTP_PROXY',$null).State -eq 'Absent') 'Missing variable is explicitly absent'
Check ($reader::SummarizeValue('HTTP_PROXY','').State -eq 'Absent') 'Empty variable is explicitly absent'
Check ($reader::GetArchitectureSupport(8,0,0x8664) -eq 'X64') 'Native AMD64 uses x64 layout'
Check ($reader::GetArchitectureSupport(8,0x014c,0x8664) -eq 'X86') 'WOW64 uses x86 layout'
Check ($reader::GetArchitectureSupport(4,0,0x8664) -eq 'UnknownUnsupported') '32-bit host refuses cross-width reads'
Check ($reader::GetArchitectureSupport(8,0,0xaa64) -eq 'UnknownUnsupported') 'ARM64 layout is unsupported'
$addressMethod=$reader.GetMethod('Address',[Reflection.BindingFlags]'NonPublic,Static')
Check (-not $addressMethod.Invoke($null,[object[]]@([uint64]0x100000000,4))) 'WOW64 address cannot overflow 32-bit pointer width'
Check (-not $addressMethod.Invoke($null,[object[]]@([uint64]0x800000000000,8))) 'AMD64 kernel range is never read'
Check (-not $addressMethod.Invoke($null,[object[]]@([uint64]65537,8))) 'Unaligned UTF16 pointer is rejected'
$method=$reader.GetMethod('Summarize',[Reflection.BindingFlags]'NonPublic,Static')
function Summarize-Block([string]$Block) {
    $bytes=[Text.Encoding]::Unicode.GetBytes($Block)
    try {$method.Invoke($null,[object[]](,$bytes))}finally{[Array]::Clear($bytes,0,$bytes.Length)}
}
$empty=Summarize-Block "`0`0"
Check ($empty.State -eq 'Absent' -and $empty.NoProxyPresent -eq $false) 'Valid empty environment is absent'
$duplicate=Summarize-Block "HTTP_PROXY=http://localhost:19001`0http_proxy=http://localhost:19002`0NO_PROXY=*`0no_proxy=custom`0`0"
Check ($duplicate.Variables[0].ReasonCode -eq 'AmbiguousVariable' -and $null -eq $duplicate.NoProxyBroadBypass) 'Duplicate names cannot authorize diagnosis'
$bypass=Summarize-Block "SECRET=NeverExposeMe`0NO_PROXY=private-marker.invalid, *,localhost`0`0"
Check ($bypass.NoProxyPresent -and $bypass.NoProxyBroadBypass -and ($bypass|ConvertTo-Json -Depth 5) -notmatch 'NeverExposeMe|private-marker') 'Only bypass presence and broad flag survive'
$domain=Summarize-Block "NO_PROXY=*.private-marker.invalid,localhost`0`0"
Check (-not $domain.NoProxyBroadBypass) 'Domain wildcard does not imply global bypass'
function Get-Listener {throw 'No listener lookup is expected for an absent port'}
$local=Get-LocalEndpointObservation 'http://127.0.0.1:19451' ([pscustomobject]@{Available=$true;Rows=@()})
Check ($local.Ready -eq $false -and $local.Listening -eq $false) 'Existing tri-state endpoint classifier recognizes a dead local port'
$unknown=Get-LocalEndpointObservation 'http://127.0.0.1:19451' ([pscustomobject]@{Available=$false;Rows=@()})
Check ($null -eq $unknown.Ready -and $null -eq $unknown.Listening) 'Failed TCP observation stays unknown'
# Test only a transformed copy of our reader: deterministically deny its OpenProcess call.
# No real system or protected process is opened for this denial test.
$source=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ProcessProxyEnvironment.cs'))
$deniedSource=$source.Replace('namespace LocalProxySwitch {','namespace FlowSwitchDeniedFixture {').Replace('handle=OpenProcess(QueryAccess,false,(uint)id);','handle=IntPtr.Zero;')
Add-Type -TypeDefinition $deniedSource
$denied=[FlowSwitchDeniedFixture.ProcessProxyEnvironment]::Observe(123,'C:\Fixture.exe',1)
Check ($denied.State -eq 'Unknown' -and $denied.Variables.Count -eq 0 -and $denied.ReasonCode -in @('AccessDenied','ProcessUnavailable')) 'Unavailable handle never yields absence or proxy values'
$changedSource=$source.Replace('namespace LocalProxySwitch {','namespace FlowSwitchChangedFixture {').Replace('static string Identity(', 'public static int IdentityCalls; static string Identity(').Replace('if(GetProcessId(handle)!=(uint)id)', 'if(++IdentityCalls>1)return "IdentityChanged"; if(GetProcessId(handle)!=(uint)id)')
Add-Type -TypeDefinition $changedSource
# A copied reader with a private, fake remote-memory provider exercises hard bounds.
# It cannot open a real process: no production hook or memory provider is exposed.
$boundedSource=$source.Replace('namespace LocalProxySwitch {','namespace FlowSwitchBoundedFixture {')
$boundedSource=$boundedSource.Replace('[DllImport("kernel32.dll", SetLastError=true)] static extern bool ReadProcessMemory(IntPtr handle, IntPtr address, byte[] bytes, UIntPtr size, out UIntPtr read);',@'
static int Count; public static int Mode; public static int BytesRead;
static bool ReadProcessMemory(IntPtr handle, IntPtr address, byte[] bytes, UIntPtr size, out UIntPtr read) {
    int length=(int)size.ToUInt64();BytesRead+=length;Count++;
    for(int i=0;i<length;i++)bytes[i]=(byte)((i%2)==0?65:0);
    if(Mode==1){bytes[0]=0;bytes[1]=0;bytes[2]=0;bytes[3]=0;}
    read=Mode==2?(UIntPtr)(length-2):size;return Mode!=3;
}
'@)
$boundedSource=$boundedSource.Replace('[DllImport("kernel32.dll", SetLastError=true)] static extern UIntPtr VirtualQueryEx(IntPtr handle, IntPtr address, out MemoryInfo info, UIntPtr length);',@'
static UIntPtr VirtualQueryEx(IntPtr handle, IntPtr address, out MemoryInfo info, UIntPtr length) {
    info=new MemoryInfo();info.Base=new IntPtr(65536);info.Size=(UIntPtr)1048576;info.State=0x1000;info.Protect=4;return length;
}
'@)
Add-Type -TypeDefinition $boundedSource
$bounded=[FlowSwitchBoundedFixture.ProcessProxyEnvironment]
$readMethod=$bounded.GetMethod('EnvironmentBytes',[Reflection.BindingFlags]'NonPublic,Static')
$rejected=$false
try {$null=$readMethod.Invoke($null,[object[]]@([IntPtr]1,[uint64]65536,8))}catch{$rejected=$true}
Check ($rejected -and $bounded::BytesRead -eq 262144) 'Missing double terminator stops at exactly 256 KiB and cannot be absent'
$bounded::Mode=1
$emptyBytes=$readMethod.Invoke($null,[object[]]@([IntPtr]1,[uint64]65536,8))
Check ($emptyBytes.Length -eq 4) 'Valid empty block terminates at double NUL'
foreach($mode in @(2,3)) {
    $bounded::Mode=$mode;$rejected=$false
    try {$null=$readMethod.Invoke($null,[object[]]@([IntPtr]1,[uint64]65536,8))}catch{$rejected=$true}
    Check $rejected 'Short or failed memory reads cannot yield a complete block'
}
$root=Join-Path ([IO.Path]::GetTempPath()) ('FlowSwitch-ProxyEnvironment-'+[Guid]::NewGuid().ToString('N'))
$fixtures=New-Object 'Collections.Generic.List[Diagnostics.Process]'
try {
    [void][IO.Directory]::CreateDirectory($root)
    $fixtureSource=Join-Path $root 'Fixture.cs'
    [IO.File]::WriteAllText($fixtureSource,'using System; class Fixture { static void Main() { Console.WriteLine("ready"); Console.ReadLine(); } }')
    $csc=Join-Path $env:SystemRoot 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    foreach($arch in @('x64','x86')) {
        $exe=Join-Path $root ($arch+'.exe')
        & $csc /nologo /target:exe ('/platform:'+$arch) ('/out:'+$exe) $fixtureSource
        if($LASTEXITCODE -ne 0){throw 'Isolated fixture compilation failed'}
        $start=New-Object Diagnostics.ProcessStartInfo
        $start.FileName=$exe;$start.UseShellExecute=$false;$start.CreateNoWindow=$true;$start.RedirectStandardInput=$true;$start.RedirectStandardOutput=$true
        $start.EnvironmentVariables.Clear()
        $reservation=New-Object Net.Sockets.TcpListener([Net.IPAddress]::Loopback,0)
        $reservation.Start();$oldPort=([Net.IPEndPoint]$reservation.LocalEndpoint).Port;$reservation.Stop()
        $start.EnvironmentVariables['SystemRoot']=$env:SystemRoot
        $start.EnvironmentVariables['HTTP_PROXY']='http://FixtureUser:FixturePassword@127.0.0.1:'+$oldPort
        $start.EnvironmentVariables['HTTPS_PROXY']='http://ExternalUser:ExternalPassword@private-fixture.invalid:4555'
        $start.EnvironmentVariables['ALL_PROXY']='socks5h://[::1]:19452'
        $start.EnvironmentVariables['NO_PROXY']='private-bypass.invalid, *'
        $start.EnvironmentVariables['SECRET']='FakeSecretMustNeverLeaveFixture'
        $process=New-Object Diagnostics.Process;$process.StartInfo=$start
        if(-not $process.Start()){throw 'Isolated fixture did not start'};$fixtures.Add($process)
        Check ($process.StandardOutput.ReadLine() -eq 'ready') 'Fixture is ready'
        $entry=@(Get-ProcessInventory -Id $process.Id)[0]
        $ticks=$entry.StartTime.ToUniversalTime().Ticks
        $observed=Get-ProcessProxyEnvironmentObservation $process.Id $entry.Path $ticks
        Check ($observed.State -eq 'Observed' -and $observed.ReasonCode -eq 'Verified' -and $observed.Architecture -eq $arch.ToUpperInvariant().Replace('X86','X86')) 'Real isolated process environment is read with the correct layout'
        Check ($observed.Variables[0].Port -eq $oldPort -and $observed.Variables[0].HasCredentials -and $observed.Variables[2].LoopbackHost -eq '::1') 'Real inherited local stale endpoints are identified'
        $listeners=@([Net.NetworkInformation.IPGlobalProperties]::GetIPGlobalProperties().GetActiveTcpListeners()|Where-Object Port -eq $oldPort|ForEach-Object {[pscustomobject]@{State='Listen';LocalPort=$_.Port;LocalAddress=$_.Address.ToString()}})
        $realEndpoint=Get-LocalEndpointObservation ('http://127.0.0.1:'+$observed.Variables[0].Port) ([pscustomobject]@{Available=$true;Rows=$listeners})
        Check ($realEndpoint.Ready -eq $false -and $realEndpoint.Listening -eq $false) 'Real TCP snapshot identifies the inherited fixture port as stopped'
        Check ($observed.NoProxyPresent -and $observed.NoProxyBroadBypass) 'Real inherited bypass only yields booleans'
        $json=$observed|ConvertTo-Json -Depth 5 -Compress
        Check ($json -notmatch 'FixtureUser|FixturePassword|ExternalUser|ExternalPassword|private-fixture|private-bypass|FakeSecretMustNeverLeaveFixture|SECRET') 'Real environment output contains no credentials, external address or arbitrary secret'
        $wrongTicks=Get-ProcessProxyEnvironmentObservation $process.Id $entry.Path ($ticks+1)
        Check ($wrongTicks.State -eq 'Unknown' -and $wrongTicks.ReasonCode -eq 'IdentityChanged' -and $wrongTicks.Variables.Count -eq 0) 'PID reuse or stale creation identity yields no observations'
        $wrongPath=Get-ProcessProxyEnvironmentObservation $process.Id 'C:\DifferentFixture.exe' $ticks
        Check ($wrongPath.ReasonCode -eq 'IdentityChanged' -and $wrongPath.Variables.Count -eq 0) 'Path mismatch yields no observations'
        [FlowSwitchChangedFixture.ProcessProxyEnvironment]::IdentityCalls=0
        $changed=[FlowSwitchChangedFixture.ProcessProxyEnvironment]::Observe($process.Id,$entry.Path,$ticks)
        Check ($changed.ReasonCode -eq 'IdentityChanged' -and $changed.State -eq 'Unknown' -and $changed.Variables.Count -eq 0 -and [FlowSwitchChangedFixture.ProcessProxyEnvironment]::IdentityCalls -eq 2) 'Identity change after environment read discards all observations'
        $process.StandardInput.WriteLine('done');Check ($process.WaitForExit(5000)) 'Only own fixture exits normally'
        $ended=Get-ProcessProxyEnvironmentObservation $process.Id $entry.Path $ticks
        Check ($ended.State -eq 'Unknown' -and $ended.Variables.Count -eq 0) 'Ended process remains unknown'
    }
} finally {
    foreach($process in $fixtures) {
        try {if(-not $process.HasExited){$process.StandardInput.WriteLine('done');if(-not $process.WaitForExit(5000)){$process.Kill();$process.WaitForExit()}}}finally{$process.Dispose()}
    }
    $resolved=[IO.Path]::GetFullPath($root)
    if($resolved.StartsWith([IO.Path]::GetFullPath([IO.Path]::GetTempPath()),[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved).StartsWith('FlowSwitch-ProxyEnvironment-')){Remove-Item -LiteralPath $resolved -Recurse -Force}
}
$inventory=[IO.File]::ReadAllText((Join-Path $PSScriptRoot 'ProcessInventory.ps1'))
Check ($inventory -notmatch 'ReadProcessMemory|ProcessProxyEnvironment') 'General process inventory remains independent of memory diagnostics'
Write-Output ('PASS: '+$script:checks+' process proxy environment assertions; real AMD64 and WOW64 isolated fixtures; no user settings changed.')
