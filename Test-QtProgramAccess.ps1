[CmdletBinding()]
param()
$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-qt-access-'+[Guid]::NewGuid().ToString('N'))
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1') -DataDirectory $qa
$script:Checks=0
function Check($Value,[string]$Message){if(-not $Value){throw $Message};$script:Checks++}
function Throws([scriptblock]$Action,[string]$Pattern){
    $message='';try{& $Action|Out-Null}catch{$message=$_.Exception.Message}
    Check ($message -match $Pattern) ('Expected '+$Pattern+', got '+$message)
    return $message
}
function Hash($Value){Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes $Value)}
function Use-ChangeLock([scriptblock]$Action){& $Action}
function Get-SystemSnapshot {Copy-RoutingSnapshot $script:Windows}
function Get-UserProxyEnv {Copy-RoutingSnapshot $script:UserEnv}
function Set-SystemSnapshot {$script:WindowsWrites++;throw 'Real Windows writes forbidden'}
function Set-UserProxyEnv {$script:WindowsWrites++;throw 'Real persistent environment writes forbidden'}
function Install-ProgramProxyShortcut {throw 'Qt access must not bind desktop entries'}
function Get-ProgramProxyAdapter([string]$Executable){if($script:AdapterUnknown){return ''};'qtwebengine'}
$originalIdentity=${function:Get-ProgramIdentityDescriptor}
function Get-ProgramIdentityDescriptor([string]$Path,$Context){
    $identity=& $originalIdentity $Path $Context
    if($script:IdentityUnknown -and $Path -ieq $app){$identity.FileId='';$identity.PathStatus='Unknown'}
    $identity
}
function Get-Listener {throw 'Qt preview/apply must not probe third-party processes'}
$script:StateFile=Join-Path $qa 'app-rules.json'
$realEnsure=${function:Ensure-ManagedGateway}
function Ensure-ManagedGateway([switch]$PreserveWindowsSettings){
    $script:EnsureCalls++
    Check $PreserveWindowsSettings 'Every Qt service-start request preserves Windows settings'
    $state=Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json
    if($script:ColdStart){$state.installed=$true;if(-not $state.defaultRoute){$state.defaultRoute='b'}}
    switch($script:StartupChange){
        'default' {$state.defaultRoute='b'}
        'sites' {$state.siteRules[0].route='Direct'}
        'entry' {$state.entries[1].route='a'}
        'system' {$script:Windows.Server='127.0.0.1:19999'}
        'environment' {$script:UserEnv.HTTP_PROXY='http://127.0.0.1:19999'}
        'flags' {[Environment]::SetEnvironmentVariable('QTWEBENGINE_CHROMIUM_FLAGS','--disable-gpu --lang=zh','Process')}
        'adapter' {$script:AdapterUnknown=$true}
    }
    Write-LocalJson $script:StateFile $state
}
function Invoke-AppRouter($Request,[int]$TimeoutMilliseconds=55000){
    $state=Get-Content -LiteralPath $script:StateFile -Raw -Encoding UTF8|ConvertFrom-Json
    if($Request.action -eq 'replace'){
        Check ($Request.expectedStateHash -ceq (Read-RuleMaintenanceFile $script:StateFile).TextHash) 'Rules replacement binds the exact previous file image'
        Check ($Request.expectedSettingsHash -ceq (Read-RuleMaintenanceFile $script:ConfigPath).TextHash) 'Rules replacement binds the profile file image'
        $script:Replaces++;$script:LastRequest=$Request
        $state.entries=@($Request.entries);$state.defaultRoute=$Request.defaultRoute
        foreach($field in @('programIngresses','siteRules')){if($Request.ContainsKey($field)){$state.$field=@($Request[$field])}}
        foreach($id in @($Request.resetIngressSelections|Where-Object {$_})){$script:Selectors[$id]=$null}
        Write-LocalJson $script:StateFile $state
        return [pscustomobject]@{ok=$true;stateHash=(Read-RuleMaintenanceFile $script:StateFile).TextHash}
    }
    $ingresses=@($state.programIngresses|ForEach-Object {
        $entry=Copy-RoutingSnapshot $_
        $entry|Add-Member NoteProperty ready ($script:RejectStatus -ne 'ready')
        $entry|Add-Member NoteProperty loaded ($script:RejectStatus -ne 'loaded')
        $effective=$(if($entry.route -eq 'Follow'){$script:EffectiveDefault}else{$entry.route})
        if($entry.path -ieq $app){
            switch($script:RejectStatus){
                'id' {$entry.id='wrong-identity'}
                'path' {$entry.path=$other}
                'port' {$entry.port++}
                'route' {$effective='a'}
                'blocked' {$effective='Blocked'}
                'unknown' {$effective='Unknown'}
                'empty' {$effective=''}
            }
        }
        $entry|Add-Member NoteProperty effectiveRoute $effective
        $entry
    })
    if($script:Replaces -gt 0 -and $script:ExternalDuringVerify){$script:ExternalDuringVerify=$false;$script:Windows.Server='127.0.0.1:19999'}
    [pscustomobject]@{available=($script:RejectStatus -ne 'available');rulesAvailable=$true;defaultLoaded=$true;effectiveDefaultRoute=$script:EffectiveDefault;programIngresses=$ingresses;siteRulesLoaded=$true}
}
$dir=Join-Path $qa 'fixture';[void][IO.Directory]::CreateDirectory($dir)
$app=Join-Path $dir 'Launcher.exe';$child=Join-Path $dir 'QtWebEngineProcess.exe';$other=Join-Path $dir 'Other.exe'
foreach($file in @($app,$child,$other)){Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\whoami.exe') -Destination $file}
$app,$child,$other=@(@($app,$child,$other)|ForEach-Object {(& $originalIdentity $_ (New-ProgramIdentityContext -Packages @())).CanonicalPath})
$script:BaseProfiles=ConvertTo-ValidProfileSettings ([pscustomobject]@{Version=3;Profiles=@(
    @{Id='gateway';Name='Gateway';Protocol='http';Host='127.0.0.1';Port=18790;CorePath=(Join-Path $qa 'core.exe')},
    @{Id='a';Name='A';Protocol='http';Host='127.0.0.1';Port=18791},
    @{Id='b';Name='B';Protocol='http';Host='127.0.0.1';Port=18792}
);Routing=@{Adapter='standalone';ProfileId='gateway';UnifiedMode='gateway'}})
$qtNames=@('QTWEBENGINE_CHROMIUM_FLAGS','QTWEBENGINEPROCESS_PATH')
$savedQt=@{};foreach($name in $qtNames){$savedQt[$name]=[Environment]::GetEnvironmentVariable($name,'Process')}
$realSystemHash=Hash ([LocalProxySwitch.Native]::Read())
$realUser=@{};foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')+$qtNames){$realUser[$name]=[Environment]::GetEnvironmentVariable($name,'User')}
$realUserHash=Hash $realUser
function Reset-Fixture {
    foreach($name in $qtNames){[Environment]::SetEnvironmentVariable($name,$null,'Process')}
    $script:Profiles=Copy-RoutingSnapshot $script:BaseProfiles
    Write-LocalJson $script:ConfigPath $script:Profiles
    $script:Windows=[pscustomobject]@{Flags=3;Server='127.0.0.1:57777';Bypass='outside-bypass'}
    $script:UserEnv=[pscustomobject]@{HTTP_PROXY='http://127.0.0.1:57777';HTTPS_PROXY='http://127.0.0.1:57777';ALL_PROXY='http://127.0.0.1:57777';NO_PROXY='outside-bypass'}
    Write-LocalJson $script:StateFile @{version=3;installed=$true;defaultRoute='a';entries=@(@{path=$app;route='b'},@{path=$child;route='b'},@{path=$other;route='Direct'});programIngresses=@(@{id=('1'*32);path=$other;port=19080;route='a'});siteRules=@(@{id=('2'*32);scope='global';type='domain';domain='example.com';route='b'},@{id=('3'*32);scope='program';type='domain';domain='game.example.com';route='Direct';path=$app})}
    Write-LocalJson (Join-Path $qa 'program-proxies.json') @{version=1;entries=@(@{path=$other;route='b';adapter='chromium'})}
    Save-Selection ([pscustomobject]@{Key='gateway';NetworkKey='b';Note='preserve bytes'})
    $script:Selectors=@{('1'*32)='b';default='b'}
    $script:EnsureCalls=0;$script:Replaces=0;$script:WindowsWrites=0;$script:StartupChange='';$script:RejectStatus='';$script:EffectiveDefault='b'
    $script:AdapterUnknown=$false;$script:IdentityUnknown=$false;$script:ColdStart=$false;$script:ExternalDuringVerify=$false
    if(Test-Path -LiteralPath (Get-IndependentSessionPath)){[IO.File]::Delete((Get-IndependentSessionPath))}
}
try {
    Reset-Fixture
    $plan=Get-QtProgramAccessPlan $app 'Direct';$before=Get-RoutingSnapshot
    Check ($plan.CanApply -and $plan.Kind -ceq 'qtwebengine') 'Qt preview accepts the verified selected executable'
    Check ($plan.Message -match '游戏 UDP' -and $plan.Message -match '不代表登录恢复') 'Preview states limited component coverage and the login boundary'
    Check ($script:EnsureCalls -eq 0 -and $script:Replaces -eq 0 -and $script:WindowsWrites -eq 0) 'Preview has no writes or service starts'
    [void](Throws {Set-QtProgramAccess $plan} '确认')
    $selectionHash=(Read-RuleMaintenanceFile $script:StatePath).Hash
    $profileHash=(Read-RuleMaintenanceFile $script:ConfigPath).Hash
    $result=Set-QtProgramAccess $plan -Confirmed;$after=Get-RoutingSnapshot
    $root=@($after.programIngresses|Where-Object path -ieq $app)
    Check ($result.Managed -and $root.Count -eq 1 -and $root[0].route -ceq 'Direct') 'Confirmed root migration installs one Direct fixed entrance'
    Check ($root[0].id -cmatch '^[a-f0-9]{32}$' -and $root[0].port -ne 19080) 'New entrance has its own identity and does not reuse the other program port'
    Check (@($after.entries|Where-Object path -ieq $app).Count -eq 0 -and @($after.entries).Count -eq 2) 'Only the root executable engine rule is removed'
    Check (($after.entries|Where-Object path -ieq $child).route -ceq 'b') 'Explicit Qt helper child rule remains unchanged'
    Check ($after.defaultRoute -ceq 'a' -and (Hash $after.siteRules) -ceq (Hash $before.siteRules) -and (Hash $after.launchEntries) -ceq (Hash $before.launchEntries)) 'Default, websites and unrelated launch records remain unchanged'
    Check (($after.programIngresses|Where-Object path -ieq $other).route -ceq 'a' -and $script:Selectors[('1'*32)] -ceq 'b' -and $script:Selectors.default -ceq 'b') 'Other entrance and active program/default backup selections remain unchanged'
    Check (@($script:LastRequest.resetIngressSelections).Count -eq 1 -and $script:LastRequest.resetIngressSelections[0] -ceq $root[0].id -and -not $script:LastRequest.resetDefaultSelection) 'Only the explicitly changed root selector is reset'
    Check ((Read-RuleMaintenanceFile $script:StatePath).Hash -ceq $selectionHash -and (Read-RuleMaintenanceFile $script:ConfigPath).Hash -ceq $profileHash) 'Persistent selection and profile byte images remain unchanged'
    Check ($result.Backup -and (Test-Path -LiteralPath $result.Backup) -and $result.Message -match '真实登录仍待验证' -and $result.Message -match '未绑定桌面') 'Result contains a private backup without claiming authentication or desktop binding'
    $id=$root[0].id;$port=$root[0].port
    $plan=Get-QtProgramAccessPlan $app 'Follow';Set-QtProgramAccess $plan -Confirmed|Out-Null
    $root=Get-ManagedProgramIngress $app
    Check ($root.id -ceq $id -and $root.port -eq $port -and $root.route -ceq 'Follow') 'Explicit Follow uses effective backup and retains stable identity/port'

    foreach($age in @(-1,121)){
        Reset-Fixture;$plan=Get-QtProgramAccessPlan $app 'Direct';$plan.CreatedAt=[DateTime]::UtcNow.AddSeconds(-$age).ToString('o')
        [void](Throws {Set-QtProgramAccess $plan -Confirmed} '过期');Check ($script:EnsureCalls -eq 0 -and $script:Replaces -eq 0) 'Invalid/future preview is refused before service startup'
    }
    foreach($change in @('system','environment','selection','profiles','rules')){
        Reset-Fixture;$plan=Get-QtProgramAccessPlan $app 'Direct'
        switch($change){
            'system' {$script:Windows.Bypass='changed'}
            'environment' {$script:UserEnv.NO_PROXY='changed'}
            'selection' {Save-Selection ([pscustomobject]@{Key='gateway';NetworkKey='a'})}
            'profiles' {$profiles=Read-ProfileSettings;$profiles.Profiles[1].Name='changed';Write-LocalJson $script:ConfigPath $profiles}
            'rules' {$state=Get-Content $script:StateFile -Raw|ConvertFrom-Json;$state.entries[1].route='a';Write-LocalJson $script:StateFile $state}
        }
        [void](Throws {Set-QtProgramAccess $plan -Confirmed} '旧预览');Check ($script:EnsureCalls -eq 0 -and $script:Replaces -eq 0) ('Changed '+$change+' refuses stale preview before service startup')
    }
    Reset-Fixture;$plan=Get-QtProgramAccessPlan $app 'Direct';[Environment]::SetEnvironmentVariable('QTWEBENGINE_CHROMIUM_FLAGS','--disable-gpu','Process')
    [void](Throws {Set-QtProgramAccess $plan -Confirmed} '旧预览');Check ($script:EnsureCalls -eq 0) 'Fresh non-network flag identity change invalidates the preview'
    Reset-Fixture;$plan=Get-QtProgramAccessPlan $app 'Direct'
    $savedExe=$app+'.old';[IO.File]::Move($app,$savedExe)
    try{Copy-Item -LiteralPath (Join-Path $env:WINDIR 'System32\whoami.exe') -Destination $app;[void](Throws {Set-QtProgramAccess $plan -Confirmed} '旧预览');Check ($script:EnsureCalls -eq 0) 'Replacing the executable invalidates its real file identity'}
    finally{[IO.File]::Delete($app);[IO.File]::Move($savedExe,$app)}

    foreach($change in @('default','sites','entry','system','environment','flags','adapter')){
        Reset-Fixture;$plan=Get-QtProgramAccessPlan $app 'Direct';$script:StartupChange=$change
        [void](Throws {Set-QtProgramAccess $plan -Confirmed} '启动期间|全局入口|启动环境')
        Check ($script:Replaces -eq 0 -and @((Get-RoutingSnapshot).entries|Where-Object path -ieq $app).Count -eq 1) ('Startup '+$change+' race is retained without writing a Qt entrance')
        if($change -eq 'default'){Check ((Get-RoutingSnapshot).defaultRoute -ceq 'b') 'An existing default changed externally during startup is preserved and refused, not normalized away'}
    }
    Reset-Fixture;$state=Get-Content $script:StateFile -Raw|ConvertFrom-Json;$state.installed=$false;$state.defaultRoute='';$state.entries=@();$state.programIngresses=@();$state.siteRules=@();Write-LocalJson $script:StateFile $state
    $script:ColdStart=$true;$plan=Get-QtProgramAccessPlan $app 'Direct';Set-QtProgramAccess $plan -Confirmed|Out-Null
    Check ((Get-RoutingSnapshot).defaultRoute -ceq 'b' -and $script:EnsureCalls -eq 1 -and $script:WindowsWrites -eq 0) 'First service initialization can normalize an empty default while preserving Windows'

    foreach($rejection in @('ready','loaded','available','id','path','port','route','blocked','unknown','empty')){
        Reset-Fixture;$before=Get-RoutingSnapshot;$selectionHash=(Read-RuleMaintenanceFile $script:StatePath).Hash
        $plan=Get-QtProgramAccessPlan $app 'Direct';$script:RejectStatus=$rejection
        [void](Throws {Set-QtProgramAccess $plan -Confirmed} '未就绪')
        Check ($script:Replaces -eq 2 -and (Test-SameRouting $before (Get-RoutingSnapshot))) ('Rejected precise status '+$rejection+' rolls back the entire owned rule snapshot')
        Check ((Read-RuleMaintenanceFile $script:StatePath).Hash -ceq $selectionHash -and $script:WindowsWrites -eq 0) 'Failed verification retains selection bytes and never writes Windows'
    }
    foreach($effective in @('Blocked','Unknown','')){
        Reset-Fixture;$before=Get-RoutingSnapshot;$plan=Get-QtProgramAccessPlan $app 'Follow';$script:EffectiveDefault=$effective
        [void](Throws {Set-QtProgramAccess $plan -Confirmed} '未就绪');Check (Test-SameRouting $before (Get-RoutingSnapshot)) 'Follow refuses blocked/unknown/empty effective default and restores rules'
    }
    Reset-Fixture;$before=Get-RoutingSnapshot;$plan=Get-QtProgramAccessPlan $app 'Direct';$script:ExternalDuringVerify=$true
    [void](Throws {Set-QtProgramAccess $plan -Confirmed} '外部全局入口')
    Check ((Test-SameRouting $before (Get-RoutingSnapshot)) -and $script:Windows.Server -ceq '127.0.0.1:19999') 'Post-write external Windows change is retained while owned rules roll back'

    Reset-Fixture;$profiles=Read-ProfileSettings;$profiles.Profiles[1].AppPath=$app;Write-LocalJson $script:ConfigPath $profiles
    Check (-not (Get-QtProgramAccessPlan $app 'Direct').CanApply) 'Proxy application itself is rejected'
    Reset-Fixture;$profiles=Read-ProfileSettings;$profiles.Profiles[1].CorePath=$app;Write-LocalJson $script:ConfigPath $profiles
    Check (-not (Get-QtProgramAccessPlan $app 'Direct').CanApply) 'Proxy core itself is rejected'
    Reset-Fixture;$alias=Join-Path $dir 'Alias.exe';New-Item -ItemType HardLink -Path $alias -Target $app|Out-Null
    $state=Get-Content $script:StateFile -Raw|ConvertFrom-Json;$state.entries+=@([pscustomobject]@{path=$alias;route='a'});Write-LocalJson $script:StateFile $state
    $plan=Get-QtProgramAccessPlan $app 'Direct';Check (-not $plan.CanApply -and $plan.Message -match '不同路径') 'Hard-link alias of the same actual file refuses conflicting records'
    Reset-Fixture;$state=Get-Content $script:StateFile -Raw|ConvertFrom-Json;$state.entries+=@([pscustomobject]@{path=$app;route='a'});Write-LocalJson $script:StateFile $state
    Check (-not (Get-QtProgramAccessPlan $app 'Direct').CanApply) 'Duplicate exact root engine rules refuse ambiguous migration'
    Reset-Fixture;$script:IdentityUnknown=$true;Check (-not (Get-QtProgramAccessPlan $app 'Direct').CanApply) 'Unknown file identity refuses preview'
    Reset-Fixture;$script:AdapterUnknown=$true;Check (-not (Get-QtProgramAccessPlan $app 'Direct').CanApply) 'Unknown or partial Qt layout refuses preview'
    foreach($name in $qtNames){
        Reset-Fixture;[Environment]::SetEnvironmentVariable($name,$(if($name -eq 'QTWEBENGINEPROCESS_PATH'){'C:\fixture-private\helper.exe'}else{'--proxy-pac-url=https://fixture-private.invalid/secret'}),'Process')
        $plan=Get-QtProgramAccessPlan $app 'Direct'
        Check (-not $plan.CanApply -and $plan.Message -notmatch 'fixture-private|secret') 'Unknown helper and existing network flags refuse preview without exposing values'
    }

    # Exercise the actual Ensure wrapper separately: only the product core start is stubbed.
    Reset-Fixture
    function Enable-IndependentGateway([int]$OwnerPID,[string]$InitialRoute,[switch]$PreserveWindowsSettings){
        $script:ColdStarts++;Check $PreserveWindowsSettings 'Actual Ensure forwards Windows-preserving mode to the cold core start'
        Check ($OwnerPID -eq $PID -and -not $InitialRoute) 'Qt cold-start wrapper supplies its lifecycle owner without overriding the default'
    }
    $script:ColdStarts=0
    & $realEnsure -PreserveWindowsSettings|Out-Null
    Check ($script:ColdStarts -eq 1 -and $script:WindowsWrites -eq 0) 'Actual Ensure wrapper requests only one cold start and performs no Windows writes'
}finally{
    foreach($name in $qtNames){[Environment]::SetEnvironmentVariable($name,$savedQt[$name],'Process')}
}
$latestUser=@{};foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')+$qtNames){$latestUser[$name]=[Environment]::GetEnvironmentVariable($name,'User')}
Check ((Hash $latestUser) -ceq $realUserHash) 'Actual persistent user environment is unchanged'
Check ((Hash ([LocalProxySwitch.Native]::Read())) -ceq $realSystemHash) 'Actual Windows proxy snapshot is unchanged'
foreach($name in $qtNames){Check ([Environment]::GetEnvironmentVariable($name,'Process') -ceq $savedQt[$name]) 'Caller Qt environment restored after isolated CAS tests'}
Write-Output ('PASS: '+$script:Checks+' Qt access preview, identity/CAS, preserved policy, precise readiness and rollback assertions; Windows/core/API writes are isolated fixtures, no user application started.')
