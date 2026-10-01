$ErrorActionPreference='Stop'
$t=$null;$errors=$null;$ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'UpdateInstall.ps1'),[ref]$t,[ref]$errors)
foreach($fn in $ast.FindAll({param($a)$a -is [Management.Automation.Language.FunctionDefinitionAst]},$true)){Invoke-Expression $fn.Extent.Text}
$script:Checks=0
function Check($Value,$Message){if(-not $Value){throw $Message};$script:Checks++}
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
$Recover=$true;Invoke-UpdateInstall $f.Ticket;$Recover=$false
Check ((Read-UpdateJson $f.State).phase -eq 'rolled-back' -and (Get-UpdateHash $before) -ceq $changed.beforeSha256) 'persisted interrupted transaction can be recovered'
Copy-Item -LiteralPath (Join-Path $f.Candidate.stage $changed.path) -Destination $before
[IO.File]::WriteAllText($before,'external edit')
$journal=Read-UpdateJson $f.State;$journal.phase='rollback-blocked';Write-UpdateJournal $f.State $journal
$Recover=$true;try{Invoke-UpdateInstall $f.Ticket}catch{};$Recover=$false
Check ((Read-UpdateJson $f.State).phase -eq 'rollback-blocked' -and [IO.File]::ReadAllText($before) -ceq 'external edit') 'recovery preserves later external edits and backup'
foreach($name in @('../secret','app/../../data','app/CON.txt','app/x:ads','app/file.','app//file')){$blocked=$false;try{Assert-UpdatePath $f.Candidate.root $name|Out-Null}catch{$blocked=$true};Check $blocked 'unsafe update path rejected'}
Write-Output ('PASS: '+$script:Checks+' installer rollback/recovery/path/port checks; isolated files only.')
