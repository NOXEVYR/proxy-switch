$ErrorActionPreference='Stop'
$qa=[IO.Path]::GetFullPath((Join-Path $env:TEMP ('FlowSwitch-ProfileSave-'+[Guid]::NewGuid().ToString('N'))))
[void][IO.Directory]::CreateDirectory($qa)
$script:checks=0
function Check($Condition,[string]$Message){if(-not $Condition){throw $Message};$script:checks++}
function Copy-Settings($Value){$Value|ConvertTo-Json -Depth 12|ConvertFrom-Json}
function Settings-Text($Value){$Value|ConvertTo-Json -Depth 12 -Compress}
function File-Bytes([string]$Path){[Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))}

try{
    # Load only real preference/storage functions; never initialize the network backend.
    . (Join-Path $PSScriptRoot 'Preferences.ps1') -DataDirectory $qa
    $script:RealWriteLocalJson=${function:Write-LocalJson}
    function Write-LocalJson([string]$Path,$Value){$script:writeCalls++;& $script:RealWriteLocalJson $Path $Value}
    function Get-RoutingSnapshot {[pscustomobject]@{entries=@();programIngresses=@();siteRules=@();launchEntries=@();defaultRoute=$null;installed=$false}}
    function Get-Selection {[pscustomobject]@{Key='Direct';NetworkKey='Direct'}}
    function Get-SystemSnapshot {[pscustomobject]@{Flags=0;Server='';Bypass=''}}
    function Get-SystemKey($Snapshot){'Direct'}
    function Use-ChangeLock([scriptblock]$Action){
        $script:lockCalls++
        # Deterministic interleaving: an independent writer finishes after Save starts,
        # immediately before its protected action. Reading before this boundary is stale.
        if($script:BeforeLock){$hook=$script:BeforeLock;$script:BeforeLock=$null;& $hook}
        & $Action
    }
    $seed=[pscustomobject]@{
        Version=3
        Profiles=@(
            [pscustomobject]@{Id='owned';Name='Local gateway';Protocol='http';Host='127.0.0.1';Port=18790;AutoPort=$false;AppPath='';CorePath='C:\Fixture\core.exe'},
            [pscustomobject]@{Id='a';Name='Alpha';Protocol='http';Host='127.0.0.1';Port=19001;AutoPort=$false;AppPath='';CorePath=''},
            [pscustomobject]@{Id='b';Name='Beta';Protocol='socks5';Host='127.0.0.1';Port=19002;AutoPort=$false;AppPath='';CorePath=''}
        )
        Routing=[pscustomobject]@{Adapter='standalone';ProfileId='owned';UnifiedMode='gateway';Failover=[pscustomobject]@{Enabled=$true;Order=@('b','a');AllowDirect=$false}}
        DiscoveryIgnored=@('loopback:19003')
    }
    function Start-Case([string]$Name){
        $script:DataRoot=Join-Path $qa $Name
        $script:ConfigPath=Join-Path $script:DataRoot 'config.json'
        $script:BackupDir=Join-Path $script:DataRoot 'backups'
        $script:Profiles=ConvertTo-ValidProfileSettings (Copy-Settings $seed)
        & $script:RealWriteLocalJson $script:ConfigPath $script:Profiles
        $script:BeforeLock=$null;$script:writeCalls=0;$script:lockCalls=0
    }
    function Check-Conflict([string]$Change,[string]$Timing){
        Start-Case ($Change+'-'+$Timing)
        $expected=Read-ProfileSettings
        $edit=Copy-Settings $expected;$edit.Profiles[1].Name='UI rename'
        $script:external=Copy-Settings $expected
        switch($Change){
            'failover-enabled'{$script:external.Routing.Failover.Enabled=$false}
            'failover-order'{$script:external.Routing.Failover.Order=@('a','b')}
            'failover-direct'{$script:external.Routing.Failover.AllowDirect=$true}
            'added-profile'{$script:external.Profiles+=@([pscustomobject]@{Id='c';Name='External C';Protocol='http';Host='127.0.0.1';Port=19004;AutoPort=$false;AppPath='';CorePath=''})}
            'edited-endpoint'{$script:external.Profiles[2].Port=19005}
            'ignored-entry'{$script:external.DiscoveryIgnored+=@('loopback:19006')}
            'case-only-name'{$script:external.Profiles[2].Name='BETA'}
        }
        $script:external=ConvertTo-ValidProfileSettings $script:external
        # A pre-existing backup is also protected from replacement or deletion.
        [void][IO.Directory]::CreateDirectory($script:BackupDir)
        $sentinel=Join-Path $script:BackupDir 'settings-existing.json'
        [IO.File]::WriteAllText($sentinel,'existing backup')
        $backupBefore=File-Bytes $sentinel
        $memoryBefore=Settings-Text $script:Profiles
        $callerBefore=Settings-Text $edit
        $expectedBefore=Settings-Text $expected
        $script:externalBytes=$null
        $externalWriter={
            & $script:RealWriteLocalJson $script:ConfigPath $script:external
            $script:externalBytes=File-Bytes $script:ConfigPath
        }
        if($Timing -eq 'before-call'){& $externalWriter}else{$script:BeforeLock=$externalWriter}
        $failure=$null
        try{Save-ProfileSettings $edit -Expected $expected}catch{$failure=$_.Exception.Message}
        $label=$Change+' / '+$Timing
        Check ($null -ne $failure -and $failure -match '其他操作修改') ($label+': stale editor receives a configuration conflict')
        Check ($script:lockCalls -eq 1 -and $null -eq $script:BeforeLock) ($label+': protected action reached after the scheduled external writer')
        Check ((File-Bytes $script:ConfigPath) -ceq $script:externalBytes) ($label+': external config is preserved byte for byte')
        Check ((Settings-Text (Read-ProfileSettings)) -ceq (Settings-Text $script:external)) ($label+': external fields survive, without the stale UI rename')
        Check ($script:writeCalls -eq 0) ($label+': no clean config write is attempted')
        Check (@(Get-ChildItem -LiteralPath $script:BackupDir -File).Count -eq 1 -and (File-Bytes $sentinel) -ceq $backupBefore) ($label+': conflict neither adds nor changes backups')
        Check ((Settings-Text $script:Profiles) -ceq $memoryBefore) ($label+': current in-memory settings are not replaced')
        Check ((Settings-Text $edit) -ceq $callerBefore -and (Settings-Text $expected) -ceq $expectedBefore) ($label+': caller edit and expected snapshot are unchanged')
        Check (@(Get-ChildItem -LiteralPath $script:DataRoot -Filter '*.tmp' -File).Count -eq 0) ($label+': no abandoned atomic-write files')
    }

    foreach($timing in @('before-call','before-lock')){
        foreach($change in @('failover-enabled','failover-order','failover-direct','added-profile','edited-endpoint','ignored-entry','case-only-name')){
            Check-Conflict $change $timing
        }
    }

    Start-Case 'matching-snapshot'
    $expected=Read-ProfileSettings;$beforeBytes=File-Bytes $script:ConfigPath
    $edit=Copy-Settings $expected;$edit.Profiles[1].Name='Saved rename'
    Save-ProfileSettings $edit -Expected $expected
    $saved=Read-ProfileSettings
    Check ($saved.Profiles[1].Name -ceq 'Saved rename') 'Matching snapshot saves the requested UI rename'
    Check ($saved.Routing.Failover.Enabled -and -not $saved.Routing.Failover.AllowDirect -and ($saved.Routing.Failover.Order -join ',') -ceq 'b,a') 'Successful rename retains failover policy and order'
    Check ($saved.Profiles.Count -eq 3 -and $saved.Profiles[2].Port -eq 19002 -and ($saved.DiscoveryIgnored -join ',') -ceq 'loopback:19003') 'Successful rename retains other profiles and discovery exclusions'
    Check ($script:writeCalls -eq 1 -and $script:lockCalls -eq 1) 'Matching snapshot performs one protected write'
    Check ((Settings-Text $script:Profiles) -ceq (Settings-Text $saved)) 'Successful save publishes the saved in-memory settings'
    $backups=@(Get-ChildItem -LiteralPath $script:BackupDir -File)
    Check ($backups.Count -eq 1 -and (File-Bytes $backups[0].FullName) -ceq $beforeBytes) 'Successful save creates an exact previous-config backup'
    Check ($expected.Profiles[1].Name -ceq 'Alpha') 'Successful save leaves the expected snapshot unchanged'

    Start-Case 'legacy-caller'
    $edit=Read-ProfileSettings;$edit.Profiles[1].Name='Legacy rename'
    # Compatibility callers deliberately retain unconditional-save behavior.
    $external=Read-ProfileSettings;$external.Routing.Failover.Enabled=$false
    & $script:RealWriteLocalJson $script:ConfigPath $external
    $beforeBytes=File-Bytes $script:ConfigPath
    Save-ProfileSettings $edit
    $saved=Read-ProfileSettings
    Check ($saved.Profiles[1].Name -ceq 'Legacy rename' -and $saved.Routing.Failover.Enabled) 'Omitting Expected preserves the established unconditional-save API'
    Check ($script:writeCalls -eq 1 -and $script:lockCalls -eq 1) 'Legacy caller still performs one protected write'
    $backups=@(Get-ChildItem -LiteralPath $script:BackupDir -File)
    Check ($backups.Count -eq 1 -and (File-Bytes $backups[0].FullName) -ceq $beforeBytes) 'Legacy caller backs up the actual latest disk config'

    Start-Case 'equivalent-snapshot'
    $expected=Read-ProfileSettings
    # Property order, whitespace and omitted default fields differ but represent the same settings.
    $expected=[pscustomobject]@{DiscoveryIgnored=$expected.DiscoveryIgnored;Routing=$expected.Routing;Profiles=$expected.Profiles;Version=3}
    $expected.Profiles[1].PSObject.Properties.Remove('AutoPort')
    $expected.Profiles[1].Host='[127.0.0.1]'
    $edit=Read-ProfileSettings;$edit.Profiles[1].Name='Equivalent snapshot rename'
    Save-ProfileSettings $edit -Expected $expected
    Check ((Read-ProfileSettings).Profiles[1].Name -ceq 'Equivalent snapshot rename' -and $script:writeCalls -eq 1) 'Equivalent validated settings do not cause a false concurrency conflict'

    Write-Output ('PASS: '+$script:checks+' profile-save assertions; real isolated config files, deterministic interleavings, no real network or user settings writes.')
}finally{
    # Delete only the exact unique temporary root allocated by this test.
    $resolved=[IO.Path]::GetFullPath($qa)
    $tempPrefix=[IO.Path]::GetFullPath($env:TEMP).TrimEnd('\')+'\'
    if($resolved.StartsWith($tempPrefix,[StringComparison]::OrdinalIgnoreCase) -and [IO.Path]::GetFileName($resolved) -match '^FlowSwitch-ProfileSave-[0-9a-f]{32}$' -and (Test-Path -LiteralPath $resolved)){
        Remove-Item -LiteralPath $resolved -Recurse -Force
    }
}
