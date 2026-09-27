$ErrorActionPreference='Stop'
$qa=Join-Path $env:TEMP ('FlowSwitch-desktop-mode-'+[Guid]::NewGuid().ToString('N'))
$env:PROXY_SWITCH_DATA_DIR=Join-Path $qa 'data'
. (Join-Path $PSScriptRoot 'ProxyBackend.ps1')
function Invoke-AppRouter {throw 'Desktop preferences must not change the routing engine.'}
$desktop=Join-Path $qa 'Desktop';$app=Join-Path $qa 'App'
[void][IO.Directory]::CreateDirectory($desktop);[void][IO.Directory]::CreateDirectory($app)
$exe=Join-Path $app 'Fixture.exe';Copy-Item -LiteralPath (Join-Path $env:SystemRoot 'System32\notepad.exe') -Destination $exe
foreach($name in @('resources.pak','chrome_100_percent.pak')){[IO.File]::WriteAllText((Join-Path $app $name),'fixture')}
Initialize-ProgramShortcutSupport
$normal=Join-Path $desktop 'Fixture.lnk';$custom=Join-Path $desktop 'Custom.lnk'
[FlowSwitchShellShortcut]::Write($normal,$exe,'',$app,($exe+',0'),'Original',1)
[FlowSwitchShellShortcut]::Write($custom,$exe,'--custom-profile test',$app,($exe+',0'),'Custom',1)
$normalHash=(Get-FileHash -LiteralPath $normal).Hash;$customHash=(Get-FileHash -LiteralPath $custom).Hash
Write-LocalJson (Join-Path $script:DataRoot 'program-proxies.json') @{version=1;entries=@(@{path=$exe;route='Direct';adapter='chromium'})}
Write-LocalJson (Join-Path $script:DataRoot 'app-rules.json') @{version=3;entries=@();programIngresses=@();siteRules=@(@{domain='fixture.example';route='Direct'})}
$routesBefore=(Get-FileHash -LiteralPath (Join-Path $script:DataRoot 'app-rules.json')).Hash
$launchBefore=(Get-FileHash -LiteralPath (Join-Path $script:DataRoot 'program-proxies.json')).Hash
$script:Pass=0
function Check($Condition,$Message){if(-not $Condition){throw $Message};$script:Pass++}
function Mode([string]$Value){Set-ProgramDesktopMode $exe $Value (Get-ProgramDesktopState $exe).Revision $desktop}
function Throws([scriptblock]$Block){$threw=$false;try{& $Block|Out-Null}catch{$threw=$true};Check $threw 'Expected a guarded rejection'}
Check ((Get-ProgramDesktopState $exe).Mode -eq 'InApp') 'Ordinary launcher defaults to in-app use'
$bound=Mode 'Bound'
Check ((Get-ProgramDesktopState $exe).Mode -eq 'Bound' -and ([FlowSwitchShellShortcut]::Read($normal)).Arguments -match '-LaunchProgram') 'Explicit binding creates a managed launcher'
Check ((Get-FileHash -LiteralPath $custom).Hash -eq $customHash) 'Custom arguments remain untouched'
Mode 'InApp'|Out-Null
Check ((Get-FileHash -LiteralPath $normal).Hash -eq $normalHash) 'Unbinding restores original bytes'
Check ((Get-FileHash -LiteralPath (Join-Path $script:DataRoot 'app-rules.json')).Hash -eq $routesBefore -and (Get-FileHash -LiteralPath (Join-Path $script:DataRoot 'program-proxies.json')).Hash -eq $launchBefore) 'Desktop preference preserves all routing and site rules'
$separate=Mode 'Separate';$separatePath=$separate.Shortcuts[0]
Check ([IO.File]::Exists($separatePath) -and (Get-FileHash -LiteralPath $normal).Hash -eq $normalHash -and (Get-ProgramDesktopState $exe).Mode -eq 'Separate') 'Separate entry leaves normal shortcut intact'
Mode 'Separate'|Out-Null
Check (@(Get-ProgramShortcutRecords).Count -eq 1) 'Repeated separate selection is idempotent'
Mode 'Bound'|Out-Null
Check (-not [IO.File]::Exists($separatePath) -and (Get-ProgramDesktopState $exe).Mode -eq 'Bound') 'Explicit bound mode replaces only the owned separate entry'
$link=[FlowSwitchShellShortcut]::Read($normal);$link.Arguments='--user-edit';[FlowSwitchShellShortcut]::Write($normal,$link)
$externalHash=(Get-FileHash -LiteralPath $normal).Hash
Mode 'InApp'|Out-Null
Check ((Get-FileHash -LiteralPath $normal).Hash -eq $externalHash) 'Unbinding preserves externally modified shortcuts'
[FlowSwitchShellShortcut]::Write($normal,$exe,'',$app,($exe+',0'),'Original',1)
$baseline=(Get-FileHash -LiteralPath $normal).Hash
$oldRevision=(Get-ProgramDesktopState $exe).Revision
Write-LocalJson (Join-Path $script:DataRoot 'program-proxies.json') @{version=1;entries=@(@{path=$exe;route='Follow';adapter='chromium'})}
Throws {Set-ProgramDesktopMode $exe 'Bound' $oldRevision $desktop}
Check ((Get-FileHash -LiteralPath $normal).Hash -eq $baseline) 'Stale preview writes nothing'
$realWriter=${function:Set-RuleMaintenanceFile}
function Set-RuleMaintenanceFile($Before,[byte[]]$Bytes,[bool]$Remove=$false){if([IO.Path]::GetFileName($Before.Path) -eq 'program-shortcuts.json'){throw 'fixture record failure'};& $realWriter $Before $Bytes $Remove}
Throws {Mode 'Bound'}
Check ((Get-FileHash -LiteralPath $normal).Hash -eq $baseline) 'Record failure rolls back owned shortcut bytes'
${function:Set-RuleMaintenanceFile}=$realWriter
Mode 'Bound'|Out-Null
$record=Get-ProgramShortcutRecords|Select-Object -First 1
$backupPath=$record.originalBackup
$record.originalBackup=Join-Path $qa 'missing.lnk'
Write-LocalJson (Join-Path $script:DataRoot 'program-shortcuts.json') @{version=1;entries=@($record)}
$beforeFailure=(Get-FileHash -LiteralPath $normal).Hash
Throws {Mode 'InApp'}
Check ((Get-FileHash -LiteralPath $normal).Hash -eq $beforeFailure) 'Missing original backup refuses destructive restore'
Write-Output ('PASS: '+$script:Pass+' explicit desktop preference checks; isolated files only.')
