# App-native proxy adapters. They configure the launched app, never Windows or other processes.
function Get-ProgramProxyAdapter([string]$Executable) {
    if(-not $Executable -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)){return ''}
    $directory=[IO.Path]::GetDirectoryName($Executable)
    # Qt ships its own Chromium resources. A partial/mixed Qt deployment must not
    # fall through to Electron's command-line adapter merely because paks exist.
    $qtGenerations=@()
    foreach($generation in @(5,6)){
        foreach($part in @('Core','Network','WebEngineCore')){
            if(Test-Path -LiteralPath (Join-Path $directory ('Qt'+$generation+$part+'.dll')) -PathType Leaf){$qtGenerations+=@($generation);break}
        }
    }
    if($qtGenerations.Count){
        if($qtGenerations.Count -ne 1){return ''}
        $generation=$qtGenerations[0];$version=''
        $files=@('Core','Network','WebEngineCore'|ForEach-Object {Join-Path $directory ('Qt'+$generation+$_+'.dll')})
        $helpers=@((Join-Path $directory 'QtWebEngineProcess.exe'),(Join-Path $directory 'libexec\QtWebEngineProcess.exe')|Where-Object {Test-Path -LiteralPath $_ -PathType Leaf})
        if(-not $helpers.Count){return ''}
        try{
            foreach($file in @($files)+@($helpers)){
                if(-not (Test-Path -LiteralPath $file -PathType Leaf)){return ''}
                $info=[Diagnostics.FileVersionInfo]::GetVersionInfo($file)
                if($info.FileMajorPart -ne $generation -or $info.FileMinorPart -lt 0 -or $info.FileBuildPart -lt 0 -or $info.FilePrivatePart -lt 0){return ''}
                $current=(@($info.FileMajorPart,$info.FileMinorPart,$info.FileBuildPart,$info.FilePrivatePart) -join '.')
                if($version -and $current -cne $version){return ''};$version=$current
            }
        }catch{return ''}
        return 'qtwebengine'
    }
    if((Test-Path -LiteralPath (Join-Path $directory 'resources.pak') -PathType Leaf) -and (Test-Path -LiteralPath (Join-Path $directory 'chrome_100_percent.pak') -PathType Leaf)){return 'chromium'}
    # Environment-only adaptation is an explicit per-file opt-in, never inferred
    # from an EXE name. Do not pass Chromium switches to native CLI processes.
    if($script:DataRoot -and @((Get-ProgramLaunchEntries)|Where-Object {$_.path -ieq $Executable -and $_.adapter -ceq 'environment'}).Count){return 'environment'}
    return ''
}
function Test-ProgramConsoleExecutable([string]$Executable) {
    $stream=$null;$reader=$null
    try{
        $stream=[IO.File]::Open($Executable,[IO.FileMode]::Open,[IO.FileAccess]::Read,[IO.FileShare]::ReadWrite -bor [IO.FileShare]::Delete);$reader=New-Object IO.BinaryReader($stream)
        if($stream.Length -lt 64 -or $reader.ReadUInt16() -ne 0x5a4d){return $false}
        $stream.Position=0x3c;$offset=$reader.ReadUInt32()
        if($offset -gt $stream.Length-94){return $false};$stream.Position=$offset
        if($reader.ReadUInt32() -ne 0x00004550){return $false}
        $stream.Position=$offset+24;$magic=$reader.ReadUInt16();if($magic -notin @(0x10b,0x20b)){return $false}
        $stream.Position=$offset+24+68;return $reader.ReadUInt16() -eq 3
    }catch{return $false}finally{if($reader){$reader.Dispose()}elseif($stream){$stream.Dispose()}}
}
function Test-ProgramLaunchAdapterCompatibility([string]$Executable,[string]$ExpectedAdapter) {
    $adapter=Get-ProgramProxyAdapter $Executable
    if($ExpectedAdapter -ne 'environment'){return $adapter -ceq $ExpectedAdapter}
    if($adapter -notin @('','environment') -or -not (Test-Path -LiteralPath $Executable -PathType Leaf)){return $false}
    foreach($name in @('Qt5Core.dll','Qt5Network.dll','Qt5WebEngineCore.dll','Qt6Core.dll','Qt6Network.dll','Qt6WebEngineCore.dll')){if(Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($Executable)) $name)){return $false}}
    return $true
}
function Get-ProgramLaunchEntries {
    $path=Join-Path $script:DataRoot 'program-proxies.json'
    if(-not (Test-Path -LiteralPath $path)){return @()}
    $state=Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json
    if($state.version -ne 1){throw '程序启动代理配置版本不兼容。'}
    foreach($entry in @($state.entries)){
        if(-not [IO.Path]::IsPathRooted($entry.path) -or $entry.path -notmatch '(?i)\.exe$' -or $entry.path -match '["\r\n\x00]' -or $entry.adapter -notin @('chromium','qtwebengine','environment') -or $entry.route -notin (@('Direct','Follow')+(Get-ProfileKeys))){throw '程序启动代理配置无效，请从备份恢复。'}
    }
    @($state.entries)
}
function Set-ProgramLaunchEntries($Entries) {
    $before=@(Get-ProgramLaunchEntries)
    Write-LocalJson (Join-Path $script:DataRoot 'program-proxies.json') ([pscustomobject]@{version=1;entries=@($Entries)})
    try{foreach($entry in $before){if(-not @($Entries|Where-Object {$_.path -ieq $entry.path}).Count){Restore-ProgramProxyShortcuts $entry.path}}}
    catch{Write-LocalJson (Join-Path $script:DataRoot 'program-proxies.json') ([pscustomobject]@{version=1;entries=$before});throw}
}
function Get-ProgramFamily([string]$Executable,$Processes,$IdentityContext=$null) {
    . (Join-Path $PSScriptRoot 'ProgramFamilyTracking.ps1')
    @((Get-ProgramFamilyTrackingSnapshot $Executable $Processes $IdentityContext).Members)
}
function ConvertTo-ProgramArgument([string]$Value) {
    '"'+[regex]::Replace([regex]::Replace($Value,'(\\*)"','$1$1\"'),'(\\+)$','$1$1')+'"'
}
function Merge-QtWebEngineLaunchFlags([string]$ExistingFlags,[string[]]$ProxyArguments) {
    # Only flags owned by this launch are added. Never echo inherited values:
    # they may contain private destinations even when an error is reported.
    if($ExistingFlags -match '[\r\n\x00]' -or ([regex]::Matches($ExistingFlags,'"').Count % 2)){
        throw 'Qt 网页组件的已有启动参数无法安全解析，未覆盖参数或启动程序。'
    }
    if($ExistingFlags -match '(?i)--(?:proxy(?:[-=\s"]|$)|no-proxy|host-resolver|use-system-proxy|winhttp-proxy|auto-detect-proxy)'){
        throw 'Qt 网页组件已有代理、PAC 或域名解析参数，未覆盖它们。请先在原设置中处理冲突后重新检查。'
    }
    $ownedArguments=@($ProxyArguments)
    $direct=($ownedArguments.Count -eq 1 -and $ownedArguments[0] -ceq '--no-proxy-server')
    $proxied=($ownedArguments.Count -eq 2 -and $ownedArguments[0] -match '^--proxy-server=http://[^\s"\r\n\x00]+$' -and $ownedArguments[1] -ceq '--proxy-bypass-list=localhost;127.0.0.1;[::1]')
    if(-not ($direct -or $proxied)){throw 'Qt 网页组件的目标代理参数无效，未启动程序。'}
    if($ExistingFlags){return $ExistingFlags+' '+(@($ProxyArguments) -join ' ')}
    return (@($ProxyArguments) -join ' ')
}
function Set-ProgramLaunchEnvironment([Diagnostics.ProcessStartInfo]$StartInfo,$Plan) {
    if(-not $StartInfo -or $StartInfo.UseShellExecute){throw '启动环境必须属于独立的新进程，未改变调用者环境。'}
    $qtFlags=''
    if($Plan.Adapter -eq 'qtwebengine'){
        $existing='';$helperOverride=''
        foreach($key in @($StartInfo.EnvironmentVariables.Keys)){
            if([string]$key -ieq 'QTWEBENGINE_CHROMIUM_FLAGS'){$existing=[string]$StartInfo.EnvironmentVariables[$key]}
            if([string]$key -ieq 'QTWEBENGINEPROCESS_PATH'){$helperOverride=[string]$StartInfo.EnvironmentVariables[$key]}
        }
        if($helperOverride){throw 'Qt 网页组件已有独立辅助程序路径，当前适配无法核验。未覆盖路径或启动程序。'}
        # Validate before changing even this private environment block. Re-read
        # the real ProcessStartInfo rather than using a preview's inherited copy.
        $qtFlags=Merge-QtWebEngineLaunchFlags $existing @($Plan.QtWebEngineArguments)
    }
    $names=@('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY','NO_PROXY')
    if($Plan.Adapter -eq 'qtwebengine'){$names+=@('FTP_PROXY','QTWEBENGINE_CHROMIUM_FLAGS')}
    foreach($name in $names){
        foreach($key in @($StartInfo.EnvironmentVariables.Keys)){if([string]$key -ieq $name){$StartInfo.EnvironmentVariables.Remove([string]$key)}}
        if($name -eq 'QTWEBENGINE_CHROMIUM_FLAGS'){$StartInfo.EnvironmentVariables[$name]=$qtFlags}
        elseif($null -ne $Plan.Environment.$name){$StartInfo.EnvironmentVariables[$name]=[string]$Plan.Environment.$name}
    }
}
function Get-ProgramLaunchPlan([string]$Executable,[string]$Route) {
    $adapter=Get-ProgramProxyAdapter $Executable
    if($adapter -notin @('chromium','qtwebengine','environment')){throw '此程序尚未配置启动方式；可明确选择代理环境启动。仅保存引擎规则不能强制接管流量。'}
    foreach($p in $script:Profiles.Profiles){if($Executable -ieq $p.CorePath -or $Executable -ieq $p.AppPath){throw '不能给代理程序自身设置启动代理，以免形成回路。'}}
    $ingress=Get-ManagedProgramIngress $Executable
    if($ingress){
        $endpoint=Get-ManagedIngressEndpoint $ingress
        $environment=[pscustomobject]@{HTTP_PROXY=$endpoint;HTTPS_PROXY=$endpoint;ALL_PROXY=$endpoint;NO_PROXY='localhost,127.0.0.1,::1'}
        $plan=[pscustomobject]@{Path=$Executable;Route=$ingress.route;Adapter=$adapter;Arguments=@(('--proxy-server='+$endpoint),'--proxy-bypass-list=localhost;127.0.0.1;[::1]');Environment=$environment;Endpoint=$endpoint;IngressId=$ingress.id}
        if($adapter -eq 'environment'){$plan.Arguments=@()}
        if($adapter -eq 'qtwebengine'){
            $plan|Add-Member NoteProperty QtWebEngineArguments @($plan.Arguments);$plan.Arguments=@()
            $preview=New-Object Diagnostics.ProcessStartInfo;$preview.UseShellExecute=$false;Set-ProgramLaunchEnvironment $preview $plan
        }
        return $plan
    }
    $key=$Route
    if($key -eq 'Follow'){$key=Get-SystemKey (Get-SystemSnapshot)}
    if($key -notin (@('Direct')+(Get-ProfileKeys))){throw '当前系统代理无法解析为已配置入口，请先选择具体代理。'}
    $environment=[ordered]@{};$arguments=@();$endpoint=''
    if($key -eq 'Direct'){
        foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){$environment[$name]=$null}
        $environment.NO_PROXY='*';$arguments=@('--no-proxy-server')
    }else{
        $profile=Get-Profile $key
        if($profile.Protocol -ne 'http'){throw '界面与联网子进程共同使用的启动代理目前需要 HTTP 入口；请选择 HTTP 代理，或使用分流引擎。'}
        if(-not (Get-Listener $profile -ProbeRemote)){throw '所选代理入口未运行，未启动程序，也未切换到其他代理。'}
        $endpoint='http://'+(Get-EndpointAddress $profile)
        foreach($name in @('HTTP_PROXY','HTTPS_PROXY','ALL_PROXY')){$environment[$name]=$endpoint}
        $environment.NO_PROXY='localhost,127.0.0.1,::1'
        $arguments=@(("--proxy-server="+$endpoint),'--proxy-bypass-list=localhost;127.0.0.1;[::1]')
    }
    $plan=[pscustomobject]@{Path=$Executable;Route=$key;Adapter=$adapter;Arguments=$arguments;Environment=[pscustomobject]$environment;Endpoint=$endpoint}
    if($adapter -eq 'environment'){throw '代理环境启动缺少固定程序入口，请重新设置此程序线路。'}
    if($adapter -eq 'qtwebengine'){
        $plan|Add-Member NoteProperty QtWebEngineArguments @($plan.Arguments);$plan.Arguments=@()
        $preview=New-Object Diagnostics.ProcessStartInfo;$preview.UseShellExecute=$false;Set-ProgramLaunchEnvironment $preview $plan
    }
    return $plan
}
# Native command-line/background programs can opt into a private proxy environment.
# No binary-name allowlist and no claim that arbitrary sockets obey proxy variables.
function Get-EnvironmentProgramAccessPlan([string]$Path,[string]$Route) {
    $plan=[pscustomobject]@{Version=1;Kind='environment';Path=$Path;Route=$Route;CreatedAt=[DateTime]::UtcNow.ToString('o');Revision='';Identity='';CanApply=$false;BlockedReason='';Message=''}
    try{
        $script:Profiles=Read-ProfileSettings
        $path=Resolve-ProgramTarget $Path;$plan.Path=$path;Assert-ManagedRoute $Route -AllowFollow
        if($script:Profiles.Routing.Adapter -ne 'standalone'){throw '请先在代理入口中配置流向独立内核，保留已有设置。'}
        if((Get-ProgramProxyAdapter $path) -notin @('','environment')){throw '此程序已有网页组件适配，请使用现有启动方式。'}
        foreach($name in @('Qt5Core.dll','Qt5Network.dll','Qt5WebEngineCore.dll','Qt6Core.dll','Qt6Network.dll','Qt6WebEngineCore.dll')){if(Test-Path -LiteralPath (Join-Path ([IO.Path]::GetDirectoryName($path)) $name)){throw 'Qt 安装组件不完整或版本不一致，请修复原程序后使用网页组件适配。'}}
        $context=New-ProgramIdentityContext;$identity=Get-ProgramIdentityDescriptor $path $context
        if(-not $identity.FileId -or $identity.PathStatus -ne 'Available'){throw '程序文件身份无法核验。'}
        foreach($profile in $script:Profiles.Profiles){if((Test-ProgramPathEquivalent $path $profile.AppPath $context) -or (Test-ProgramPathEquivalent $path $profile.CorePath $context)){throw '不能给代理程序自身配置代理环境，以免形成回路。'}}
        $snapshot=Get-RoutingSnapshot
        if(@(@($snapshot.entries)+@($snapshot.programIngresses)+@($snapshot.launchEntries)|Where-Object {$_.path -ine $path -and (Test-ProgramPathEquivalent $_.path $path $context)}).Count){throw '同一程序存在不同路径记录，请先修复冲突。'}
        foreach($group in @('entries','programIngresses','launchEntries')){if(@($snapshot.$group|Where-Object {$_.path -ieq $path}).Count -gt 1){throw '此程序记录重复，请先处理冲突。'}}
        $plan.Revision=Get-NetworkRepairRevision (Get-SystemSnapshot) (Get-UserProxyEnv)
        $plan.Identity=Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes @($identity.FileId,$identity.CanonicalPath))
        $plan.CanApply=$true
        $plan.Message='为所选 EXE 建立固定代理入口，线路为「'+(Get-RouteName $Route)+'」。仅在流向启动的新进程中设置 HTTP_PROXY / HTTPS_PROXY / ALL_PROXY 和本地绕过；不会改系统或用户变量、桌面入口，也不会结束正在运行的程序。原来此 EXE 的引擎规则将替换为启动入口，其他程序、网站及备用线路保留。'+"`r`n`r`n"+'适用于会读取代理变量的命令行和后台程序。保存后先正常退出目标，再按此线路打开；已经运行的 Codex、其他终端启动的命令、忽略变量的 OAuth 或原生网络请求不会被强制改线。外部 VPN/TUN 仍控制系统路由，流向的“直连”表示不经过应用代理，不保证绕过 VPN。'
    }catch{$plan.BlockedReason=$_.Exception.Message;$plan.Message=$plan.BlockedReason}
    $plan
}
function Set-EnvironmentProgramAccess($Plan,[switch]$Confirmed,[switch]$ReuseExisting) {
    if(-not $Confirmed){throw '请先预览并确认代理环境启动的适用范围。'}
    Use-ChangeLock {
        if($ReuseExisting){
            $saved=@((Get-ProgramLaunchEntries)|Where-Object {$_.path -ieq $Plan.Path})
            if($saved.Count -ne 1 -or $saved[0].adapter -cne 'environment' -or -not (Get-ManagedProgramIngress $Plan.Path)){throw '原代理环境接入已撤销或改变，未重新建立入口；请重新预览并确认。'}
        }
        $age=([DateTime]::UtcNow-[DateTime]::Parse([string]$Plan.CreatedAt).ToUniversalTime()).TotalSeconds
        if($Plan.Version -ne 1 -or $Plan.Kind -cne 'environment' -or $age -lt 0 -or $age -gt 120){throw '代理环境预览无效或已过期，请重新预览。'}
        $fresh=Get-EnvironmentProgramAccessPlan $Plan.Path $Plan.Route
        if(-not $fresh.CanApply -or $fresh.Revision -cne $Plan.Revision -or $fresh.Identity -cne $Plan.Identity){throw '程序、网络或线路记录已变化，请重新预览；当前设置保留。'}
        $before=Get-RoutingSnapshot;$windows=Get-SystemSnapshot;$environment=Get-UserProxyEnv
        Ensure-ManagedGateway -PreserveWindowsSettings|Out-Null
        $current=Get-RoutingSnapshot;$compare=Copy-RoutingSnapshot $before;$compare.installed=$current.installed
        if(-not $before.installed -and -not $before.defaultRoute){$compare.defaultRoute=$current.defaultRoute}
        if(-not (Test-SameRouting $compare $current)){throw '服务启动期间程序或网站规则已变化，未覆盖新记录。'}
        $id=Get-ProgramIdentityDescriptor $fresh.Path (New-ProgramIdentityContext)
        if((Get-RuleMaintenanceHash (ConvertTo-RuleMaintenanceBytes @($id.FileId,$id.CanonicalPath))) -cne $fresh.Identity -or (Get-ProgramProxyAdapter $fresh.Path) -notin @('','environment')){throw '启动期间程序文件或适配已变化，未写入入口。'}
        $next=Copy-RoutingSnapshot $current
        $entry=$current.programIngresses|Where-Object {$_.path -ieq $fresh.Path}|Select-Object -First 1
        if($entry){$entry=Copy-RoutingSnapshot $entry;$entry.route=$fresh.Route}
        else{if(@($current.programIngresses).Count -ge 64){throw '程序入口已达上限。'};$entry=[pscustomobject]@{id=[Guid]::NewGuid().ToString('N');path=$fresh.Path;port=(New-ManagedIngressPort $current);route=$fresh.Route;identity=$id}}
        $next.entries=@($current.entries|Where-Object {$_.path -ine $fresh.Path})
        $next.programIngresses=@($current.programIngresses|Where-Object {$_.path -ine $fresh.Path})+@($entry)
        $next.launchEntries=@($current.launchEntries|Where-Object {$_.path -ine $fresh.Path})+@([pscustomobject]@{path=$fresh.Path;route='Follow';adapter='environment';identity=$id})
        $next|Add-Member NoteProperty resetIngressSelections @($entry.id) -Force
        $verify={
            $live=Invoke-AppRouter @{action='status'};$loaded=$live.programIngresses|Where-Object {$_.id -ceq $entry.id -and $_.path -ieq $entry.path -and [int]$_.port -eq [int]$entry.port}|Select-Object -First 1
            $wanted=$fresh.Route;if($wanted -eq 'Follow'){$wanted=$live.effectiveDefaultRoute}
            if(-not $live.available -or -not $loaded.ready -or -not $loaded.loaded -or $loaded.effectiveRoute -cne $wanted -or $wanted -in @('Blocked','Unknown','')){throw '固定入口或实际选路尚未就绪，不能确认完成。'}
            if(-not (Test-SameSnapshot $windows (Get-SystemSnapshot)) -or -not (Test-SameEnv $environment (Get-UserProxyEnv))){throw '外部网络设置已变化，未确认此次接入。'}
        }.GetNewClosure()
        $backup=Invoke-ManagedRoutingChange $current $next $verify
        [pscustomobject]@{Backup=$backup;Managed=$true;IngressId=$entry.id;Message='代理环境启动入口已保存并载入，系统代理和用户变量保留。请先正常退出所选程序，再点击“按此线路打开”。只对遵循代理变量的新进程及子进程生效；实际连接和登录仍需核验。'}
    }
}
function Get-ProgramShortcutRecords {
    $path=Join-Path $script:DataRoot 'program-shortcuts.json'
    if(Test-Path -LiteralPath $path){@((Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json).entries)}else{@()}
}
function Get-ProgramProxyShortcutHealth([string]$Executable) {
    foreach($record in @(Get-ProgramShortcutRecords|Where-Object {$_.program -ieq $Executable})){
        $state='missing-shortcut';$owned=$false;$backend='';$ready=$false
        if(Test-Path -LiteralPath $record.shortcut -PathType Leaf){
            Initialize-ProgramShortcutSupport
            $link=[FlowSwitchShellShortcut]::Read($record.shortcut)
            $owned=$link.TargetPath -ieq $record.managedTarget -and $link.Arguments -ceq $record.managedArguments
            if(-not $owned){$state='externally-modified'}else{
                $match=[regex]::Match($link.Arguments,'(?i)(?:^|\s)-File\s+(?:"([^"]+)"|(\S+))')
                if($match.Success){$backend=$match.Groups[1].Value;if(-not $backend){$backend=$match.Groups[2].Value}}
                if(-not $backend -or -not [IO.File]::Exists($backend) -or -not [IO.File]::Exists($link.TargetPath)){$state='missing-backend'}
                elseif($backend -ine (Join-Path $script:Root 'ProxySwitch.ps1')){$state='old-backend'}
                else{$state='ready';$ready=$true}
            }
        }
        [pscustomobject]@{Shortcut=$record.shortcut;Owned=$owned;State=$state;Ready=$ready;Backend=$backend;CanRefresh=($owned -and $state -in @('missing-backend','old-backend'))}
    }
}
function Get-VerifiedProgramShortcuts([string]$Executable) {
    @(Get-ProgramProxyShortcutHealth $Executable|Where-Object Ready|ForEach-Object Shortcut)
}
function Repair-ProgramProxyEntry([string]$Executable) {
    Use-ChangeLock {
        $snapshot=Get-RuleMaintenanceSnapshot $Executable
        if(-not @(@($snapshot.Launch.entries)+@($snapshot.Engine.programIngresses)|Where-Object {$_.path -ieq $Executable}).Count){throw '此程序没有启动代理记录，未修改入口。'}
        if(@($snapshot.Engine.entries|Where-Object {$_.path -ieq $Executable}).Count){throw '此程序同时有引擎规则，请先核对规则模式。'}
        if(-not [IO.File]::Exists($Executable)){throw '程序路径已失效，请先修复程序路径记录。'}
        if(-not @(Get-ProgramProxyShortcutHealth $Executable|Where-Object CanRefresh).Count){throw '没有仍归本工具且需要更新的旧入口；外部修改保持原样。'}
        $identity=Get-ProgramIdentityDescriptor -Path $Executable -Context (New-ProgramIdentityContext)
        $result=Invoke-RuleMaintenanceChange $snapshot $Executable $Executable $identity
        $result.Message='代理启动入口已更新到当前流向，原线路与原始入口备份保留。外部修改的入口保持原样；正在运行的程序未重启。'
        $result
    }
}
function Restore-ProgramProxyShortcuts([string]$Executable) {
    $records=@(Get-ProgramShortcutRecords);$keep=@()
    foreach($record in $records){
        if($record.program -ine $Executable){$keep+=@($record);continue}
        if(-not (Test-Path -LiteralPath $record.shortcut -PathType Leaf)){continue}
        Initialize-ProgramShortcutSupport
        $link=[FlowSwitchShellShortcut]::Read($record.shortcut)
        $owned=($link.TargetPath -ieq $record.managedTarget -and $link.Arguments -ceq $record.managedArguments)
        if(-not $owned){continue} # User edits win; never restore over an independently changed shortcut.
        if($record.originalBackup -and (Test-Path -LiteralPath $record.originalBackup -PathType Leaf)){Copy-Item -LiteralPath $record.originalBackup -Destination $record.shortcut -Force}
        elseif(-not $record.originalBackup){Remove-Item -LiteralPath $record.shortcut -Force}
        else{throw '原始快捷方式备份缺失，未覆盖当前入口。'}
    }
    if(@($records|Where-Object {$_.program -ieq $Executable}).Count){Write-LocalJson (Join-Path $script:DataRoot 'program-shortcuts.json') ([pscustomobject]@{version=1;entries=$keep})}
}
function Install-ProgramProxyShortcut([string]$Executable,[string]$DesktopDirectory='') {
    if(-not $DesktopDirectory){$DesktopDirectory=[Environment]::GetFolderPath('Desktop')}
    $records=@(Get-ProgramShortcutRecords);$existing=@($records|Where-Object {$_.program -ieq $Executable})
    Initialize-ProgramShortcutSupport
    $updates=@();$written=@()
    try{
        foreach($file in @(Get-ChildItem -LiteralPath $DesktopDirectory -Filter '*.lnk')){
            $link=[FlowSwitchShellShortcut]::Read($file.FullName)
            $record=$existing|Where-Object {$_.shortcut -ieq $file.FullName}|Select-Object -First 1
            if($link.TargetPath -ine $Executable -and -not ($record -and $link.TargetPath -ieq $record.managedTarget -and $link.Arguments -ceq $record.managedArguments)){continue}
            # Preserve arbitrary user launch arguments; they need explicit adapter support.
            if(-not $record -and $link.Arguments){continue}
            $updates+=@([pscustomobject]@{Path=$file.FullName;Existing=$record;Icon=$link.IconLocation;Description=$link.Description})
        }
        if(-not $updates.Count){
            $destination=Join-Path $DesktopDirectory ([IO.Path]::GetFileNameWithoutExtension($Executable)+'（指定代理）.lnk')
            if(Test-Path -LiteralPath $destination){throw '代理启动快捷方式名称已存在，未覆盖该文件。'}
            $updates=@([pscustomobject]@{Path=$destination;Existing=$null;Icon=($Executable+',0');Description=''})
        }
        $binary=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $arguments='-NoProfile -STA -ExecutionPolicy Bypass -WindowStyle Hidden -File '+(ConvertTo-ProgramArgument (Join-Path $script:Root 'ProxySwitch.ps1'))+' -DataDirectory '+(ConvertTo-ProgramArgument $script:DataRoot)+' -LaunchProgram '+(ConvertTo-ProgramArgument $Executable)
        foreach($update in $updates){
            $backup='';if(Test-Path -LiteralPath $update.Path){
                $directory=Join-Path $script:DataRoot 'backups\shortcuts';[void][IO.Directory]::CreateDirectory($directory)
                $backup=Join-Path $directory ([Guid]::NewGuid().ToString('N')+'.lnk');Copy-Item -LiteralPath $update.Path -Destination $backup
            }
            $written+=@([pscustomobject]@{Path=$update.Path;Backup=$backup})
            [FlowSwitchShellShortcut]::Write($update.Path,$binary,$arguments,[IO.Path]::GetDirectoryName($Executable),$update.Icon,'按 ProxySwitch 为该程序指定的线路启动（包含子进程）',7)
            $verify=[FlowSwitchShellShortcut]::Read($update.Path)
            if($verify.TargetPath -ine $binary -or $verify.Arguments -cne $arguments){throw '快捷方式写入核对失败。'}
            $original=$backup;if($update.Existing){$original=$update.Existing.originalBackup}
            $records=@($records|Where-Object {$_.shortcut -ine $update.Path})+@([pscustomobject]@{program=$Executable;shortcut=$update.Path;originalBackup=$original;managedTarget=$binary;managedArguments=$arguments})
        }
        Write-LocalJson (Join-Path $script:DataRoot 'program-shortcuts.json') ([pscustomobject]@{version=1;entries=$records})
        @($updates|ForEach-Object Path)
    }catch{
        foreach($item in $written){if($item.Backup){Copy-Item -LiteralPath $item.Backup -Destination $item.Path -Force}else{Remove-Item -LiteralPath $item.Path -Force -ErrorAction SilentlyContinue}}
        throw
    }
}
function Set-ProgramLaunchRoute([string]$Executable,[string]$Route) {
    Use-ChangeLock {
        if(@((Get-RoutingSnapshot).entries|Where-Object {$_.path -ieq $Executable}).Count){throw '此程序已有引擎规则。请先明确移除该规则，再改用主程序和子进程启动代理，避免两种方式冲突。'}
        $plan=Get-ProgramLaunchPlan $Executable $Route
        $before=@(Get-ProgramLaunchEntries);$next=@($before|Where-Object {$_.path -ine $Executable})+@([pscustomobject]@{path=$Executable;route=$Route;adapter=$plan.Adapter;identity=(Get-ProgramIdentityDescriptor -Path $Executable -Context (New-ProgramIdentityContext))})
        $backup=Save-Backup ([pscustomobject]@{Version=3;Time=(Get-Date).ToString('o');System=(Get-SystemSnapshot);Environment=(Get-UserProxyEnv);Selection=(Get-Selection);Routing=(Get-RoutingSnapshot)})
        try{Set-ProgramLaunchEntries $next;$shortcuts=@(Get-VerifiedProgramShortcuts $Executable)}catch{Set-ProgramLaunchEntries $before;throw}
        [pscustomobject]@{Backup=$backup;Message=('已保存「'+[IO.Path]::GetFileNameWithoutExtension($Executable)+'」的目标「'+(Get-RouteName $Route)+'」，尚未验证生效。请保存任务并完整退出，再右键选择「按指定线路打开」。保存线路不会改写桌面入口；可在「启动方式」中自行设置。已有代理入口：'+"`r`n"+($shortcuts -join "`r`n")+"`r`n"+'其他入口（开始菜单、任务栏、Listary 等）未接入此启动设置，重复从那些入口重开不会应用这里保存的代理。');Shortcuts=$shortcuts}
    }
}
function Start-ManagedProgram([string]$Executable,$Cancellation=$null) {
    Use-ChangeLock {
    $ingress=Get-ManagedProgramIngress $Executable
    $entry=$ingress;if(-not $entry){$entry=Get-ProgramLaunchEntries|Where-Object {$_.path -ieq $Executable}|Select-Object -First 1}
    if(-not $entry){throw '此程序尚未配置启动代理，请先在管理器中指定线路。'}
    $launchAdapter=Get-ProgramProxyAdapter $Executable
    if($launchAdapter -notin @('chromium','qtwebengine','environment') -or ($entry.adapter -and $entry.adapter -cne $launchAdapter)){throw '程序启动适配已改变，原设置保持不变。请重新检查程序路径和线路。'}
    if(@(Get-ProgramFamily $Executable @(Get-ProcessInventory)).Count){throw '该程序仍在运行。请先保存任务并完整退出，再从这个入口打开，才能让界面和联网子进程同时使用新线路。没有结束现有进程。'}
    if(Test-ManagedLaunchCancelled $Cancellation){throw '启动检查已取消，未启动程序。'}
    $limitedDirect=$false;$launchNotice=''
    if($ingress){
        Ensure-ManagedGateway -PreserveWindowsSettings|Out-Null
        $ready=Wait-ManagedProgramIngressReady $ingress -Cancellation $Cancellation
        if($ready.LimitedDirect){
            $limitedDirect=$true;$launchNotice=' 默认代理出口已暂停，仅匹配直连网站例外的请求可用；其他请求仍会失败，请切换到可用代理后重试。'
        }
    }else{
        $readyKey=$entry.route;if($readyKey -eq 'Follow'){$readyKey=Get-SystemKey (Get-SystemSnapshot)}
        Wait-ManagedProxyReady $readyKey
    }
    if(Test-ManagedLaunchCancelled $Cancellation){throw '启动检查已取消，未启动程序。'}
    if($ingress){
        $current=Get-ManagedProgramIngress $Executable
        if(-not $current -or $current.id -cne $ingress.id -or $current.port -ne $ingress.port -or $current.route -cne $ingress.route){throw '启动检查期间程序线路或固定入口已改变，未启动程序。请刷新后重试。'}
    }
    $plan=Get-ProgramLaunchPlan $Executable $entry.route
    if($launchAdapter -cne $plan.Adapter){throw '启动检查期间程序适配已改变，未启动程序。请重新检查程序路径和线路。'}
    if($plan.Adapter -eq 'qtwebengine'){$launchNotice+=' 已设置受支持的 Qt 网页组件；其他独立联网组件、系统隧道及登录结果仍需验证。'}
    if($plan.Adapter -eq 'environment'){$launchNotice+=' 仅本次启动及继承环境的子进程使用代理变量；忽略变量的请求、外部终端启动和 VPN/TUN 出口仍待核验。'}
    $psi=New-Object Diagnostics.ProcessStartInfo;$psi.FileName=$Executable;$psi.WorkingDirectory=[IO.Path]::GetDirectoryName($Executable)
    $psi.UseShellExecute=$false;$psi.CreateNoWindow=$false;$psi.Arguments=(@($plan.Arguments|ForEach-Object {ConvertTo-ProgramArgument $_}) -join ' ')
    Set-ProgramLaunchEnvironment $psi $plan
    try{$process=[Diagnostics.Process]::Start($psi)}
    catch{
        $native=$_.Exception;while($native.InnerException){$native=$native.InnerException}
        if($native -is [ComponentModel.Win32Exception] -and $native.NativeErrorCode -eq 740){throw '此程序要求管理员权限，未启动。请保存工作并通过托盘正常退出流向，再以管理员身份运行流向，随后从“按此线路打开”重试；已保存的程序线路仍保留，未写入成功启动记录。'}
        throw
    }
    try{
        $records=@();$path=Join-Path $script:DataRoot 'program-launches.json'
        if(Test-Path -LiteralPath $path){$records=@((Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json).entries|Where-Object {$_.path -ine $Executable})}
        # Process.Start owns this handle; inventory may already have lost a short-lived bootstrap.
        [void]$process.Handle;$started=$process.StartTime.ToUniversalTime().Ticks.ToString()
        $records+=@([pscustomobject]@{path=$Executable;pid=$process.Id;started=$started;route=$plan.Route;endpoint=$plan.Endpoint})
        Write-LocalJson $path ([pscustomobject]@{version=1;entries=$records})
        [pscustomobject]@{Message=('已按指定线路启动，等待观察实际连接。'+$launchNotice);PID=$process.Id;Route=$plan.Route;ObservationUnknown=$false;LimitedDirect=$limitedDirect}
    }catch{
        # A launch-record failure cannot turn a successfully started app into a failed launch.
        Write-LifecycleEvent 'program-launch' 'observation-unavailable'
        [pscustomobject]@{Message=('程序已启动，但启动记录或进程观察未完成，请刷新实际连接；没有重复启动程序。'+$launchNotice);PID=$process.Id;Route=$plan.Route;ObservationUnknown=$true;LimitedDirect=$limitedDirect}
    }finally{$process.Dispose()}
    }
}
function Test-ManagedProgramSession([string]$Executable,$Processes,[string]$Route) {
    $path=Join-Path $script:DataRoot 'program-launches.json';if(-not (Test-Path -LiteralPath $path)){return $false}
    try{$record=(Get-Content -LiteralPath $path -Raw -Encoding UTF8|ConvertFrom-Json).entries|Where-Object {$_.path -ieq $Executable}|Select-Object -First 1}catch{return $false}
    if(-not $record){return $false}
    $ingress=Get-ManagedProgramIngress $Executable
    if($ingress){
        if($record.endpoint -cne (Get-ManagedIngressEndpoint $ingress)){return $false}
        return @($Processes|Where-Object {$_.Id -eq $record.pid -and $_.Path -ieq $Executable -and $_.StartTime -and $_.StartTime.ToUniversalTime().Ticks.ToString() -eq $record.started}).Count -gt 0
    }
    $key=$Route;if($key -eq 'Follow'){$key=Get-SystemKey (Get-SystemSnapshot)}
    if($record.route -ne $key){return $false}
    if($key -ne 'Direct' -and $record.endpoint -cne ('http://'+(Get-EndpointAddress (Get-Profile $key)))){return $false}
    return @($Processes|Where-Object {$_.Id -eq $record.pid -and $_.Path -ieq $Executable -and $_.StartTime.ToUniversalTime().Ticks.ToString() -eq $record.started}).Count -gt 0
}


# Desktop integration is an explicit preference, independent of route selection.
function Get-ProgramDesktopState([string]$Executable) {
    $records=@(Get-ProgramShortcutRecords|Where-Object {$_.program -ieq $Executable})
    $health=@(Get-ProgramProxyShortcutHealth $Executable)
    $owned=@($records|Where-Object {$path=$_.shortcut;@($health|Where-Object {$_.Shortcut -ieq $path -and $_.Owned}).Count})
    $bound=@($owned|Where-Object originalBackup).Count
    $separate=@($owned|Where-Object {-not $_.originalBackup}).Count
    [pscustomobject]@{Mode=$(if($bound){'Bound'}elseif($separate){'Separate'}else{'InApp'});Bound=$bound;Separate=$separate;External=@($health|Where-Object {$_.State -eq 'externally-modified'}).Count;Revision=(Get-RuleMaintenanceSnapshot $Executable).Fingerprint}
}
function Set-ProgramDesktopMode([string]$Executable,[ValidateSet('InApp','Separate','Bound')][string]$Mode,[string]$ExpectedRevision,[string]$DesktopDirectory='') {
    Use-ChangeLock {
        $executable=ConvertTo-ProgramIdentityPath $Executable
        if(-not $executable -or $executable -notmatch '(?i)\.exe$'){throw '请选择有效程序。'}
        if(-not $DesktopDirectory){$DesktopDirectory=[Environment]::GetFolderPath('Desktop')}
        $snapshot=Get-RuleMaintenanceSnapshot $executable
        if(-not $ExpectedRevision -or $snapshot.Fingerprint -cne $ExpectedRevision){throw '程序设置已变化，请重新打开启动方式。'}
        if($Mode -ne 'InApp'){
            if((Get-ProgramProxyAdapter $executable) -notin @('chromium','qtwebengine','environment') -or -not @(@($snapshot.Launch.entries)+@($snapshot.Engine.programIngresses)|Where-Object {$_.path -ieq $executable}).Count){throw '请先为受支持的程序指定线路，再设置代理启动入口。'}
        }
        Initialize-ProgramShortcutSupport
        $backup=New-RuleMaintenanceBackup $snapshot 'desktop-mode' $executable $executable
        $restore=New-RuleMaintenanceShortcutChanges $snapshot $executable '' $backup -Remove
        $changes=@{};foreach($change in $restore.Changes){$changes[$change.Before.Path]=$change}
        $records=@($restore.Records);$targets=@()
        if($Mode -eq 'Separate'){
            $path=Join-Path $DesktopDirectory ([IO.Path]::GetFileNameWithoutExtension($executable)+'（指定代理）.lnk')
            $before=Read-RuleMaintenanceFile $path
            if($before.Exists -and (-not $changes.ContainsKey($path) -or -not $changes[$path].Remove)){throw '独立代理入口名称已被其他文件占用，未覆盖。'}
            $targets+=@([pscustomobject]@{Path=$path;Before=$before;Original='';Bytes=[byte[]]@();Icon=($executable+',0')})
        }elseif($Mode -eq 'Bound'){
            foreach($file in @(Get-ChildItem -LiteralPath $DesktopDirectory -Filter '*.lnk')){
                $path=$file.FullName;$before=Read-RuleMaintenanceFile $path
                $bytes=$before.Bytes
                if($changes.ContainsKey($path)){if($changes[$path].Remove){continue};$bytes=$changes[$path].Bytes}
                $stage=Join-Path $backup.Directory ([Guid]::NewGuid().ToString('N')+'.lnk')
                [IO.File]::WriteAllBytes($stage,$bytes);$link=[FlowSwitchShellShortcut]::Read($stage)
                if($link.TargetPath -ine $executable -or $link.Arguments){continue}
                $existing=$snapshot.Shortcuts.entries|Where-Object {$_.shortcut -ieq $path -and $_.program -ieq $executable}|Select-Object -First 1
                $original=$stage;if($existing -and $existing.originalBackup){$original=$existing.originalBackup}
                $targets+=@([pscustomobject]@{Path=$path;Before=$before;Original=$original;Bytes=$bytes;Icon=$link.IconLocation})
            }
            if(-not $targets.Count){throw '未找到可绑定的原桌面入口。带自定义参数或外部修改的入口保持原样；可选择创建独立代理入口。'}
        }
        foreach($target in $targets){
            $stage=Join-Path $backup.Directory ([Guid]::NewGuid().ToString('N')+'.lnk')
            if($target.Bytes.Length){[IO.File]::WriteAllBytes($stage,$target.Bytes)}
            $binary=Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe';$arguments=Get-RuleMaintenanceArguments $executable
            [FlowSwitchShellShortcut]::Write($stage,$binary,$arguments,[IO.Path]::GetDirectoryName($executable),$target.Icon,'由流向按已保存线路打开；可在流向的启动方式中解除',7)
            $verify=[FlowSwitchShellShortcut]::Read($stage)
            if($verify.TargetPath -ine $binary -or $verify.Arguments -cne $arguments){throw '代理入口生成失败，未修改桌面。'}
            $changes[$target.Path]=[pscustomobject]@{Before=$target.Before;Bytes=[IO.File]::ReadAllBytes($stage);Remove=$false}
            $records+=@([pscustomobject]@{program=$executable;shortcut=$target.Path;originalBackup=$target.Original;managedTarget=$binary;managedArguments=$arguments})
        }
        $next=$snapshot.Shortcuts|ConvertTo-Json -Depth 16|ConvertFrom-Json;$next.entries=$records
        $ordered=@($changes.Values)+@([pscustomobject]@{Before=$snapshot.Files['program-shortcuts.json'];Bytes=(ConvertTo-RuleMaintenanceBytes $next);Remove=$false})
        if((Get-RuleMaintenanceSnapshot $executable).Fingerprint -cne $snapshot.Fingerprint){throw '准备期间程序记录或入口已变化，未修改。'}
        $written=@()
        try{
            foreach($change in $ordered){
                Set-RuleMaintenanceFile $change.Before $change.Bytes $change.Remove
                $written+=@([pscustomobject]@{Before=$change.Before;AfterHash=$(if($change.Remove){'<missing>'}else{Get-RuleMaintenanceHash $change.Bytes})})
            }
            foreach($item in $written){if((Read-RuleMaintenanceFile $item.Before.Path).Hash -cne $item.AfterHash){throw '入口写入后发生外部更改。'}}
        }catch{
            $problems=0
            for($i=$written.Count-1;$i -ge 0;$i--){$item=$written[$i];try{$current=Read-RuleMaintenanceFile $item.Before.Path;if($current.Hash -ceq $item.AfterHash){Set-RuleMaintenanceFile $current $item.Before.Bytes (-not $item.Before.Exists)}}catch{$problems++}}
            throw ('启动方式未保存成功；已尽力恢复仍归本次修改的文件，外部修改保留。回退失败项：'+$problems+'。备份：'+$backup.Path)
        }
        $message=switch($Mode){'InApp'{'已解除桌面绑定，原入口恢复正常启动；需要代理时在流向中选择“按指定线路打开”。'}'Separate'{'已创建独立代理入口，原桌面入口保持正常启动。'}'Bound'{'已按你的选择绑定原桌面入口；以后双击会先由流向检查代理服务，可随时在启动方式中解除。'}}
        [pscustomobject]@{Mode=$Mode;Backup=$backup.Path;Shortcuts=@($targets|ForEach-Object Path);Message=($message+' 保存的线路和网站规则未改变，正在运行的程序未重启。'+$(if($restore.Preserved){' 外部改动的入口保持原样。'}else{''}))}
    }
}
