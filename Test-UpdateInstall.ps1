$ErrorActionPreference='Stop'
$t=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'UpdateInstall.ps1'),[ref]$t,[ref]$errors)
foreach($fn in $ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $fn.Extent.Text}
$script:Checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:Checks++}
Check (-not $errors.Count) 'installer parses in Windows PowerShell'
# Exercise the production identity check/wait with only synthetic inventory rows.
$script:InventoryQueries=0;$script:InventoryMode='unknown-path'
$identity=[pscustomobject]@{id=10001;ticks='639264000000000000';path='C:\FlowSwitch-fixture\FlowSwitch.exe'}
function Get-ProcessInventory([int]$Id){
    $script:InventoryQueries++
    if($script:InventoryMode -eq 'absent' -or ($script:InventoryMode -eq 'transient' -and $script:InventoryQueries -ge 3)){return}
    $start=New-Object DateTime([long]$identity.ticks,[DateTimeKind]::Utc)
    $path=$identity.path
    if($script:InventoryMode -in @('unknown-path','transient','persistent')){$path=''}
    if($script:InventoryMode -eq 'unknown-time'){$start=[DateTime]::MinValue}
    if($script:InventoryMode -eq 'reused'){$start=$start.AddTicks(1)}
    if($script:InventoryMode -eq 'changed-path'){$path='C:\Other-fixture\FlowSwitch.exe'}
    if($script:InventoryMode -eq 'late-absence'){Microsoft.PowerShell.Utility\Start-Sleep -Milliseconds 150;return}
    if($script:InventoryMode -eq 'shared-deadline' -and $Id -eq 10001 -and $script:InventoryQueries -ge 3){return}
    if($script:InventoryMode -eq 'persistent' -and $script:GuardFixture){
        Check (@((Read-UpdateJson $script:GuardFixture.State).files).Count -eq 0) 'unknown identity cannot authorize backup or replacement'
        foreach($entry in $script:GuardFixture.Candidate.changes){Check ((Get-UpdateHash (Join-Path $script:GuardFixture.Candidate.root $entry.path)) -ceq $entry.beforeSha256) 'unknown identity preserves each installed file'}
    }
    [pscustomobject]@{Id=$Id;Path=$path;StartTime=$start}
}
Check (-not (Test-UpdateProcessExited $identity)) 'unavailable path is unconfirmed exit'
$script:InventoryMode='unknown-time'
Check (-not (Test-UpdateProcessExited $identity)) 'unavailable start time is unconfirmed exit'
$script:InventoryMode='absent'
Check (Test-UpdateProcessExited $identity) 'absent PID confirms old host exit'
$script:InventoryMode='reused'
Check (Test-UpdateProcessExited $identity) 'fully observed reused PID confirms original host exit'
$script:InventoryMode='changed-path';$failed=$false
try{Test-UpdateProcessExited $identity|Out-Null}catch{$failed=$true}
Check $failed 'same creation time with a changed path remains rejected'
$failed=$false;try{Test-UpdateProcessExited ([pscustomobject]@{id=10001;ticks='';path=$identity.path})|Out-Null}catch{$failed=$true}
Check $failed 'missing handoff identity remains rejected'
$script:InventoryMode='transient';$script:InventoryQueries=0
Wait-UpdateProcessesExited @($identity) ([DateTime]::UtcNow.AddSeconds(2))
Check ($script:InventoryQueries -eq 3) 'transient unknown retries until PID disappears'
$script:InventoryMode='persistent';$script:InventoryQueries=0;$failed=$false;$watch=[Diagnostics.Stopwatch]::StartNew()
try{Wait-UpdateProcessesExited @($identity) ([DateTime]::UtcNow.AddMilliseconds(250))}catch{$failed=$true}
$watch.Stop()
Check ($failed -and $script:InventoryQueries -ge 2 -and $watch.ElapsedMilliseconds -lt 1500) 'persistent unknown expires without an unbounded wait'
$script:InventoryMode='late-absence';$failed=$false
try{Wait-UpdateProcessesExited @($identity) ([DateTime]::UtcNow.AddMilliseconds(75))}catch{$failed=$true}
Check $failed 'exit observed after the deadline cannot authorize replacement'
$script:InventoryMode='shared-deadline';$script:InventoryQueries=0;$failed=$false;$watch.Restart()
try{Wait-UpdateProcessesExited @($identity,([pscustomobject]@{id=10002;ticks=$identity.ticks;path=$identity.path})) ([DateTime]::UtcNow.AddMilliseconds(350))}catch{$failed=$true}
$watch.Stop()
Check ($failed -and $script:InventoryQueries -ge 4 -and $watch.ElapsedMilliseconds -lt 1500) 'multiple hosts consume one absolute deadline'
$script:InventoryQueries=0;$failed=$false
try{Wait-UpdateProcessesExited @($identity) ([DateTime]::UtcNow.AddSeconds(-1))}catch{$failed=$true}
Check ($failed -and $script:InventoryQueries -eq 0) 'already expired handoff is rejected before querying'
function New-Fixture {
    $file=& node (Join-Path $PSScriptRoot 'Test-UpdateEngine.cjs') --fixture
    if($LASTEXITCODE -ne 0){throw 'Fixture failed'}
    $candidate=Read-UpdateJson $file
    $nonce=[Guid]::NewGuid().ToString('N');$ticket=Join-Path $candidate.stage 'handoff.json'
    Write-UpdateJournal $ticket ([pscustomobject]@{candidate=$file;nonce=$nonce;processes=@();ports=@()})
    [IO.File]::WriteAllText((Join-Path $candidate.stage ('commit-'+$nonce)),$nonce)
    [pscustomobject]@{Candidate=$candidate;Ticket=$ticket;State=(Join-Path $candidate.stage 'install-state.json')}
}
# Filesystem tests use only isolated fixture installations; no real process/network mutation.
function Assert-NoUpdateHost {}
function Assert-UpdatePortsReleased($Ports){if($script:Occupied){throw 'Isolated occupied-port fixture'}}
$Recover=$false
# Run the installer through its real waiting gate with a shorter test-only deadline.
# The original gate remains intact; only its caller supplies the fixture time limit.
$script:ProductionWait=${function:Wait-UpdateProcessesExited}
function Wait-UpdateProcessesExited($Identities,[DateTime]$Deadline){& $script:ProductionWait $Identities ([DateTime]::UtcNow.AddMilliseconds(250))}
$f=New-Fixture;$script:GuardFixture=$f
$handoff=Read-UpdateJson $f.Ticket;$handoff.processes=@($identity);Write-UpdateJournal $f.Ticket $handoff
$script:InventoryMode='persistent';$script:InventoryQueries=0;$failed=$false
try{Invoke-UpdateInstall $f.Ticket}catch{$failed=$true}
$state=Read-UpdateJson $f.State
Check ($failed -and $script:InventoryQueries -ge 2 -and $state.phase -eq 'cancelled' -and @($state.files).Count -eq 0) 'installer cancels before replacement when unknown persists through its deadline'
$script:GuardFixture=$null
Set-Item -LiteralPath function:Wait-UpdateProcessesExited -Value $script:ProductionWait
$f=New-Fixture;$handoff=Read-UpdateJson $f.Ticket;$handoff.processes=@($identity);Write-UpdateJournal $f.Ticket $handoff
$script:InventoryMode='transient';$script:InventoryQueries=0;$script:Occupied=$true
try{Invoke-UpdateInstall $f.Ticket}catch{}finally{$script:Occupied=$false}
Check ($script:InventoryQueries -eq 3 -and (Read-UpdateJson $f.State).phase -eq 'cancelled') 'installer retries transient unknown before continuing to the port safety gate'
$f=New-Fixture
$canary=Join-Path $f.Candidate.root 'private-config-canary.txt';[IO.File]::WriteAllText($canary,'untouched')
$locked=Join-Path $f.Candidate.root 'app\Preferences.ps1'
$handle=New-Object IO.FileStream($locked,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::Read)
try{$failed=$false;try{Invoke-UpdateInstall $f.Ticket}catch{$failed=$true};Check $failed 'replacement failure is reported'}finally{$handle.Dispose()}
$state=Read-UpdateJson $f.State
Check ($state.phase -eq 'rolled-back') 'partial replacement rolls back on locked file'
foreach($entry in $f.Candidate.changes){Check ((Get-UpdateHash (Join-Path $f.Candidate.root $entry.path)) -ceq $entry.beforeSha256) ('rollback preserves '+$entry.path)}
Check ([IO.File]::ReadAllText($canary) -ceq 'untouched') 'unregistered user file preserved'
$f=New-Fixture;$script:Occupied=$true;try{Invoke-UpdateInstall $f.Ticket}catch{};$script:Occupied=$false
Check ((Read-UpdateJson $f.State).phase -eq 'cancelled') 'occupied port blocks before replacement'
$f=New-Fixture
$changed=$f.Candidate.changes[0];$before=Join-Path $f.Candidate.root $changed.path;$backup=Join-Path (Join-Path $f.Candidate.stage 'backup') $changed.path
[void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup));Copy-Item -LiteralPath $before -Destination $backup
Copy-Item -LiteralPath (Join-Path $f.Candidate.stage $changed.path) -Destination $before
Write-UpdateJournal $f.State ([pscustomobject]@{phase='installing';files=@([pscustomobject]@{path=$changed.path;before=$changed.beforeSha256;after=$changed.sha256;writing=$true})})
$handoff=Read-UpdateJson $f.Ticket;$handoff.processes=@($identity);Write-UpdateJournal $f.Ticket $handoff
$script:InventoryMode='unknown-time';$Recover=$true;$failed=$false
try{Invoke-UpdateInstall $f.Ticket}catch{$failed=$true}finally{$Recover=$false}
Check ($failed -and (Read-UpdateJson $f.State).phase -eq 'installing' -and (Get-UpdateHash $before) -ceq $changed.sha256) 'unknown host identity cannot authorize recovery replacement'
$handoff.processes=@();Write-UpdateJournal $f.Ticket $handoff
$Recover=$true;Invoke-UpdateInstall $f.Ticket;$Recover=$false
Check ((Read-UpdateJson $f.State).phase -eq 'rolled-back' -and (Get-UpdateHash $before) -ceq $changed.beforeSha256) 'persisted interrupted transaction can be recovered'
Copy-Item -LiteralPath (Join-Path $f.Candidate.stage $changed.path) -Destination $before
[IO.File]::WriteAllText($before,'external edit')
$journal=Read-UpdateJson $f.State;$journal.phase='rollback-blocked';Write-UpdateJournal $f.State $journal
$Recover=$true;try{Invoke-UpdateInstall $f.Ticket}catch{};$Recover=$false
Check ((Read-UpdateJson $f.State).phase -eq 'rollback-blocked' -and [IO.File]::ReadAllText($before) -ceq 'external edit') 'recovery preserves later external edits and backup'
foreach($name in @('../secret','app/../../data','app/CON.txt','app/x:ads','app/file.','app//file')){$blocked=$false;try{Assert-UpdatePath $f.Candidate.root $name|Out-Null}catch{$blocked=$true};Check $blocked 'unsafe update path rejected'}
Write-Output ('PASS: '+$script:Checks+' installer identity/deadline/rollback/recovery/path/port checks; isolated files only.')
