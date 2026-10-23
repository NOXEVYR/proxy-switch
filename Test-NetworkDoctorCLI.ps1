$ErrorActionPreference='Stop'
# Real child shell and entry point, with an owned backend that fails before any
# settings load. Trap UI loading instead of displaying a modal on a regression.
$fixture=Join-Path ([IO.Path]::GetTempPath()) ('FlowSwitch-DoctorCLI-'+[Guid]::NewGuid().ToString('N'))
[void][IO.Directory]::CreateDirectory($fixture)
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'ProxySwitch.ps1') -Destination $fixture
$utf8=New-Object Text.UTF8Encoding($true)
[IO.File]::WriteAllText((Join-Path $fixture 'ProxyBackend.ps1'),"throw 'PRIVATE-initialization-fixture'",$utf8)
$shell=Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
$checks=0
foreach($mode in @('DiagnoseNetwork','ProbeNetwork','RecoveryDiagnostic','RecoveryProbe','ResetProxy')){
    $data=Join-Path $fixture $mode
    [void][IO.Directory]::CreateDirectory($data)
    $config=Join-Path $data 'config.json'
    [IO.File]::WriteAllText($config,'{"fixture":"preserve"}',$utf8)
    $marker=Join-Path $data 'ui-attempted.txt'
    $entry=(Join-Path $fixture 'ProxySwitch.ps1').Replace("'","''")
    $safeData=$data.Replace("'","''");$safeMarker=$marker.Replace("'","''")
    $command="function Add-Type { param([string]`$AssemblyName) [IO.File]::WriteAllText('$safeMarker','unexpected UI'); throw 'UI forbidden in diagnostic CLI' }; & '$entry' -$mode -DataDirectory '$safeData'"
    $info=New-Object Diagnostics.ProcessStartInfo
    $info.FileName=$shell
    $info.Arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -EncodedCommand '+[Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))
    $info.UseShellExecute=$false;$info.CreateNoWindow=$true
    $info.RedirectStandardOutput=$true;$info.RedirectStandardError=$true
    $child=[Diagnostics.Process]::Start($info)
    try{
        $outputTask=$child.StandardOutput.ReadToEndAsync()
        $errorTask=$child.StandardError.ReadToEndAsync()
        if(-not $child.WaitForExit(15000)){
            # This exact handle is the shell created above, never a user process.
            $child.Kill();$child.WaitForExit()
            throw ($mode+' failed to exit after initialization failure')
        }
        $checks++
        if($child.ExitCode -ne 1){throw ($mode+' must exit with failure code 1')};$checks++
        $null=$outputTask.Result;$null=$errorTask.Result
        if(Test-Path -LiteralPath $marker){throw ($mode+' attempted modal UI initialization')};$checks++
        $receiptPath=Join-Path $data 'last-startup-failure.json'
        $receipt=[IO.File]::ReadAllText($receiptPath)|ConvertFrom-Json
        if($receipt.ErrorCode -cne 'backend-initialization' -or $receipt.Stage -cne 'initialization' -or [IO.File]::ReadAllText($receiptPath).Contains('PRIVATE-initialization-fixture')){
            throw ($mode+' did not preserve a sanitized initialization report')
        };$checks++
        if([IO.File]::ReadAllText($config) -cne '{"fixture":"preserve"}'){throw 'Fixture config was modified'};$checks++
    }finally{$child.Dispose()}
}
Write-Host ('PASS: '+$checks+' diagnostic CLI failure checks; isolated child shells only, no real settings or UI.')
