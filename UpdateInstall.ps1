[CmdletBinding()]
param([Parameter(Mandatory=$true)][string]$Ticket,[switch]$Recover)
$ErrorActionPreference='Stop'
# Private helper environment only; do not inherit a PowerShell 7 module search path.
$env:PSModulePath=Join-Path $PSHOME 'Modules'
function Write-UpdateJournal($Path,$Value){
    $tmp=$Path+'.'+[Guid]::NewGuid().ToString('N')+'.tmp'
    $bytes=(New-Object Text.UTF8Encoding($false)).GetBytes(($Value|ConvertTo-Json -Depth 20))
    $stream=New-Object IO.FileStream($tmp,[IO.FileMode]::CreateNew,[IO.FileAccess]::Write,[IO.FileShare]::None)
    try{$stream.Write($bytes,0,$bytes.Length);$stream.Flush($true)}finally{$stream.Dispose()}
    if(Test-Path -LiteralPath $Path){[IO.File]::Replace($tmp,$Path,[NullString]::Value)}else{[IO.File]::Move($tmp,$Path)}
}
function Read-UpdateJson($Path){Get-Content -LiteralPath $Path -Raw -Encoding UTF8|ConvertFrom-Json}
function Assert-UpdatePath([string]$Root,[string]$Relative){
    if(-not $Relative -or $Relative.Contains('\') -or $Relative.Contains(':') -or $Relative -match '(^|/)(\.|\.\.|)(/|$)' -or $Relative -match '[. ](/|$)' -or $Relative -match '(?i)(^|/)(con|prn|aux|nul|com\d|lpt\d)(\.|/|$)'){throw 'Unsafe update path'}
    $base=[IO.Path]::GetFullPath($Root).TrimEnd('\');$full=[IO.Path]::GetFullPath((Join-Path $base $Relative))
    if(-not $full.StartsWith($base+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Update path escapes installation'}
    $item=$full
    while($item -and $item.Length -ge $base.Length){if(Test-Path -LiteralPath $item){if((Get-Item -LiteralPath $item -Force).Attributes -band [IO.FileAttributes]::ReparsePoint){throw 'Reparse paths cannot be updated'}};$item=[IO.Path]::GetDirectoryName($item)}
    return $full
}
function Get-UpdateHash($Path){$stream=[IO.File]::OpenRead($Path);$sha=[Security.Cryptography.SHA256]::Create();try{([BitConverter]::ToString($sha.ComputeHash($stream))).Replace('-','').ToLowerInvariant()}finally{$sha.Dispose();$stream.Dispose()}}
function Test-UpdateProcessExited($Identity){
    if(-not $Identity -or [int]$Identity.id -le 0 -or -not $Identity.ticks -or -not $Identity.path){throw 'Missing process identity'}
    $rows=@(Get-ProcessInventory -Id ([int]$Identity.id))
    if(-not $rows.Count){return $true}
    $row=$rows[0]
    # A snapshot can still contain a naturally exiting host whose limited query
    # no longer supplies its identity. Unknown is never proof of exit.
    if(-not $row.Path -or -not $row.StartTime -or $row.StartTime -eq [DateTime]::MinValue){return $false}
    if($row.StartTime.ToUniversalTime().Ticks.ToString() -cne [string]$Identity.ticks){return $true}
    if($row.Path -ine [string]$Identity.path){throw 'Process identity changed'}
    return $false
}
function Wait-UpdateProcessesExited($Identities,[DateTime]$Deadline){
    # All hosts share the original handoff deadline; retries cannot extend it.
    if([DateTime]::UtcNow -ge $Deadline){throw 'Owned process exit was not confirmed before update handoff expired'}
    foreach($identity in @($Identities)){
        while($true){
            if([DateTime]::UtcNow -ge $Deadline){throw 'Owned process exit was not confirmed before update handoff expired'}
            $exited=Test-UpdateProcessExited $identity
            if([DateTime]::UtcNow -ge $Deadline){throw 'Owned process exit was not confirmed before update handoff expired'}
            if($exited){break}
            Start-Sleep -Milliseconds 100
        }
    }
}
function Assert-UpdatePortsReleased($Ports){
    if(-not @($Ports).Count){return}
    $rows=@(Get-NetTCPConnection -State Listen -ErrorAction Stop)
    foreach($port in $Ports){if(@($rows|Where-Object LocalPort -eq ([int]$port)).Count){throw 'Gateway port is still occupied'}}
}
function Assert-NoUpdateHost([string]$Root){
    foreach($row in @(Get-ProcessInventory | Where-Object ProcessName -eq 'FlowSwitch')){
        if(-not $row.Path){throw 'Installation process identity is unavailable'}
        if($row.Path -ieq (Join-Path $Root 'FlowSwitch.exe')){throw 'Installation is still in use'}
    }
}
function Restore-UpdateFiles($Root,$Stage,$Journal){
    $blocked=$false
    foreach($f in @($Journal.files|Where-Object writing)){
        try{$dest=Assert-UpdatePath $Root $f.path;$current=Get-UpdateHash $dest
            if($current -ceq $f.before){continue};if($current -cne $f.after){throw 'External edit preserved'}
            $backup=Assert-UpdatePath (Join-Path $Stage 'backup') $f.path;if((Get-UpdateHash $backup) -cne $f.before){throw 'Backup changed'}
            $tmp=$dest+'.rollback-'+[Guid]::NewGuid().ToString('N');Copy-Item -LiteralPath $backup -Destination $tmp;[IO.File]::Replace($tmp,$dest,[NullString]::Value)
        }catch{$blocked=$true}
    }
    return (-not $blocked)
}
function Invoke-UpdateInstall([string]$TicketPath){
    $handoff=Read-UpdateJson $TicketPath
    $candidatePath=[IO.Path]::GetFullPath([string]$handoff.candidate)
    $candidate=Read-UpdateJson $candidatePath
    $root=[IO.Path]::GetFullPath([string]$candidate.root);$stage=[IO.Path]::GetFullPath([string]$candidate.stage)
    $data=[IO.Path]::GetFullPath([string]$candidate.data)
    if($candidate.schema -ne 1 -or -not $stage.StartsWith((Join-Path $data 'updates\stage-'),[StringComparison]::OrdinalIgnoreCase) -or [IO.Path]::GetDirectoryName($candidatePath) -ine $stage -or [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($TicketPath)) -ine $stage -or $stage.StartsWith($root+'\',[StringComparison]::OrdinalIgnoreCase)){throw 'Invalid update handoff'}
    if($handoff.nonce -notmatch '^[a-f0-9]{32}$'){throw 'Invalid update nonce'}
    $statePath=Join-Path $stage 'install-state.json';$lockPath=Join-Path $root '.flowswitch-update.lock'
    $lock=$null;$journal=$null
    try{
        $lock=New-Object IO.FileStream($lockPath,[IO.FileMode]::OpenOrCreate,[IO.FileAccess]::ReadWrite,[IO.FileShare]::None)
        if($Recover){
            $recovery=Read-UpdateJson $statePath
            if($recovery.phase -notin @('installing','rollback-blocked')){throw 'No interrupted replacement to recover'}
            foreach($identity in @($handoff.processes)){if(-not (Test-UpdateProcessExited $identity)){throw 'Host must exit normally before recovery'}}
            Assert-NoUpdateHost $root
            if(Test-Path -LiteralPath (Join-Path $data 'gateway-session.json')){throw 'Proxy recovery must complete before update recovery'}
            Assert-UpdatePortsReleased @($handoff.ports)
            $recovery.phase=$(if(Restore-UpdateFiles $root $stage $recovery){'rolled-back'}else{'rollback-blocked'})
            Write-UpdateJournal $statePath $recovery
            if($recovery.phase -ne 'rolled-back'){throw 'External changes preserved; manual recovery required'}
            return
        }
        if(Test-Path -LiteralPath $statePath){$old=Read-UpdateJson $statePath;if($old.phase -in @('installing','rollback-blocked','restarting')){throw 'Previous update requires recovery before another install'}}
        $reg=Read-UpdateJson (Join-Path $root 'update-install.json')
        if($reg.product -cne 'FlowSwitch' -or $reg.platform -cne 'windows' -or $reg.arch -cne 'x64' -or $reg.channel -cne 'stable' -or $reg.build -cne $candidate.from.build -or $reg.version -cne $candidate.from.version -or (Get-UpdateHash (Join-Path $root 'manifest.json')) -cne $reg.manifestSha256){throw 'Installation identity changed'}
        if($candidate.target.schema -ne 1 -or $candidate.target.product -cne 'FlowSwitch' -or $candidate.target.platform -cne 'windows' -or $candidate.target.arch -cne 'x64' -or $candidate.target.channel -cne 'stable'){throw 'Invalid target identity'}
        if([version]$candidate.target.version -le [version]$reg.version -or $candidate.target.build -cne $candidate.target.manifestSha256){throw 'Update version must increase'}
        $registered=Read-UpdateJson (Join-Path $root 'manifest.json')
        $known=@{};foreach($f in $registered){$known[[string]$f.path]=[string]$f.sha256}
        $known['manifest.json']=Get-UpdateHash (Join-Path $root 'manifest.json');$known['update-install.json']=Get-UpdateHash (Join-Path $root 'update-install.json')
        if(@($candidate.targetFiles).Count -ne $registered.Count){throw 'File layout changed'}
        foreach($f in $candidate.targetFiles){if(-not $known.ContainsKey([string]$f.path)){throw 'Unregistered target file'};if($f.path -like 'app/runtime/*' -and $known[[string]$f.path] -cne $f.sha256){throw 'Runtime update requires full package'}}
        $seen=@{}
        foreach($f in $candidate.changes){
            $dest=Assert-UpdatePath $root $f.path;$source=Assert-UpdatePath $stage $f.path
            if($seen.ContainsKey([string]$f.path) -or -not $known.ContainsKey([string]$f.path) -or $f.path -like 'app/runtime/*' -or $known[[string]$f.path] -cne $f.beforeSha256 -or (Get-UpdateHash $dest) -cne $f.beforeSha256 -or (Get-UpdateHash $source) -cne $f.sha256){throw 'Staged file or registered installation changed'}
            $seen[[string]$f.path]=$true
        }
        if((Get-UpdateHash (Join-Path $stage 'manifest.json')) -cne $candidate.target.manifestSha256){throw 'Staged manifest binding mismatch'}
        $journal=[pscustomobject]@{phase='waiting';nonce=$handoff.nonce;version=$candidate.target.version;files=@();reason=''}
        Write-UpdateJournal $statePath $journal
        [IO.File]::WriteAllText((Join-Path $stage ('ready-'+$handoff.nonce)), $handoff.nonce)
        $deadline=[DateTime]::UtcNow.AddSeconds(90);$commit=Join-Path $stage ('commit-'+$handoff.nonce)
        while(-not (Test-Path -LiteralPath $commit)){if([DateTime]::UtcNow -gt $deadline){throw 'Update handoff expired'};Start-Sleep -Milliseconds 100}
        if([IO.File]::ReadAllText($commit) -cne $handoff.nonce){throw 'Invalid handoff confirmation'}
        Wait-UpdateProcessesExited @($handoff.processes) $deadline
        if(Test-Path -LiteralPath (Join-Path $data 'gateway-session.json')){throw 'Gateway session still exists'}
        Assert-UpdatePortsReleased @($handoff.ports)
        Assert-NoUpdateHost $root
        # Revalidate every program file after the host exits; user files are outside this list.
        foreach($f in $registered){if((Get-UpdateHash (Assert-UpdatePath $root $f.path)) -cne $f.sha256){throw 'Program changed while waiting'}}
        foreach($f in $candidate.changes){
            $backup=Assert-UpdatePath (Join-Path $stage 'backup') $f.path
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($backup))
            Copy-Item -LiteralPath (Assert-UpdatePath $root $f.path) -Destination $backup
            if((Get-UpdateHash $backup) -cne $f.beforeSha256){throw 'Backup mismatch'}
            $journal.files+=@([pscustomobject]@{path=$f.path;before=$f.beforeSha256;after=$f.sha256;writing=$false})
        }
        $journal.phase='installing';Write-UpdateJournal $statePath $journal
        foreach($f in $journal.files){
            $dest=Assert-UpdatePath $root $f.path
            if((Get-UpdateHash $dest) -cne $f.before){throw 'External program change during install'}
            $source=Assert-UpdatePath $stage $f.path
            if((Get-UpdateHash $source) -cne $f.after){throw 'Staged program changed during install'}
            $f.writing=$true;Write-UpdateJournal $statePath $journal
            $temporary=$dest+'.flowswitch-'+[Guid]::NewGuid().ToString('N')+'.tmp'
            [IO.File]::Copy($source,$temporary,$false)
            [IO.File]::Replace($temporary,$dest,[NullString]::Value)
        }
        foreach($f in $candidate.targetFiles){if((Get-UpdateHash (Assert-UpdatePath $root $f.path)) -cne $f.sha256){throw 'Installed file verification failed'}}
        if((Get-UpdateHash (Join-Path $root 'manifest.json')) -cne $candidate.target.manifestSha256){throw 'Installed manifest mismatch'}
        $journal.phase='installed';Write-UpdateJournal $statePath $journal
        Assert-UpdatePortsReleased @($handoff.ports)
        $journal.phase='restarting';Write-UpdateJournal $statePath $journal
        $exe=Join-Path $root 'FlowSwitch.exe'
        $args='--data-directory "'+[regex]::Replace($data,'(\\+)$','$1$1')+'"'
        # No arbitrary command or application name from remote metadata is executed.
        $lock.Dispose();$lock=$null
        $launched=Start-Process -FilePath $exe -ArgumentList $args -WorkingDirectory $root -WindowStyle Hidden -PassThru
        $journal|Add-Member NoteProperty restartPID $launched.Id -Force;Write-UpdateJournal $statePath $journal
        # The new UI writes its receipt only after the first successful state refresh.
        $ack=Join-Path $stage 'restart-ack.json';$deadline=[DateTime]::UtcNow.AddSeconds(45)
        while(-not (Test-Path -LiteralPath $ack)){if([DateTime]::UtcNow -gt $deadline){$journal.phase='installed-restart-unconfirmed';Write-UpdateJournal $statePath $journal;return};Start-Sleep -Milliseconds 200}
        $reply=Read-UpdateJson $ack
        if($reply.version -cne $candidate.target.version -or $reply.build -cne $candidate.target.build -or $reply.nonce -cne $handoff.nonce -or $reply.launcherPID -ne $launched.Id){throw 'Restart receipt mismatch'}
        $journal.phase='completed';Write-UpdateJournal $statePath $journal
    }catch{
        if(-not $journal -and -not $Recover){Write-UpdateJournal $statePath ([pscustomobject]@{phase='preflight-failed';reason=$_.Exception.GetType().Name;line=$_.InvocationInfo.ScriptLineNumber})}
        if($journal){
            # Never roll back a newly started host underneath it. Keep a truthful separate restart result.
            if($journal.phase -in @('installed','restarting','installed-restart-unconfirmed')){$journal.phase='installed-restart-unconfirmed';$journal.reason='restart-not-confirmed'}
            else{
                $blocked=-not (Restore-UpdateFiles $root $stage $journal)
                $journal.phase=$(if($blocked){'rollback-blocked'}elseif(@($journal.files|Where-Object writing).Count){'rolled-back'}else{'cancelled'});$journal.reason='installation-not-completed'
            }
            $journal|Add-Member NoteProperty failureLine $_.InvocationInfo.ScriptLineNumber -Force
            Write-UpdateJournal $statePath $journal
        }
        throw 'Update did not complete. Preserve the staging journal and backups.'
    }finally{if($lock){$lock.Dispose()}}
}
$handoffIdentity=Read-UpdateJson $Ticket
$candidateIdentity=Read-UpdateJson $handoffIdentity.candidate
. (Join-Path $candidateIdentity.root 'app\ProcessInventory.ps1')
Invoke-UpdateInstall $Ticket
