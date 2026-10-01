# 3.9.5 程序接入约定

- 首次未配置程序的worker在ChangeLock内重新读取保存快照和原生适配。已有engine或非Chromium统一返回ProgramAccessPlan，只读预览，经Confirmed才写；不得用陈旧UI模式转换已有专线。支持Chromium继续原managed路径；新增Test-ProgramRouteDispatch纳入Test-All。
- 恢复归属PreWindowsAction在规则实读/系统变量CAS后持久化，hook后再CAS；PostCommit只核验已认领记录和入口。看门狗初次/每轮读取独占或损坏session为Unknown，有界重试并保留保护，不依据旧session恢复。

- 引擎规则的新接入动作使用 ProgramRouteAccess 的只读Plan和120秒内显式Confirmed Apply；绑定系统/用户环境/完整配置规则/EXE和进程家族身份。普通SystemProxy可接入，TUN/Guard已知拒绝，第三方未知隧道不能宣称已关闭。
- 单事务接回系统入口并补齐Missing家族成员，保留Conflict/unknown、默认与当前备用、其他programIngress、siteRules及Selection；不能借统一切换清空专线。PostCommitAction需在共享事务try内、写后实读之后运行，失败进入现有归属回滚。
- 会话恢复归属随接回更新：保留仍归属字段的旧恢复baseline，外部已改字段按本次Before/语义重建，保留Bypass及自动模式。会话CAS失败或外部变化不能覆盖；回滚不完整时保留可恢复记录与核心。
- ApplicationObservation接入三态每轮实读，不跨轮缓存。Controller精确证据才确认engine线路；外部代理TCP登记不能证明接管，入口外或读取未知保持未知。UI区分普通engine的应用线路并检查和native的按此线路打开。

# UI 功能维护（2026-10-01）

- 四页各自拥有操作：网络切换、程序线路、代理入口、检查与维护；工具再分连接检查、维护与恢复、软件与记录。新增动作需注明对象、影响与撤回，更新 UiGuidance / USER_GUIDE / QuickStart 中的实际路径。
- Main PageHost 保留 program/proxy/tools 的 0/1/2 和 home=3；首次正常打开只读首页，测试用隔离 Demo。不得让后台刷新决定显式 PendingAction 是否执行。
- 单程序和单代理动作以选中对象为准；未知或未满足前提禁用并显示原因。只读检测选择不得改变待应用的全局线路。
- 嵌套布局使用 Dock/TableLayout，避免 Scale 中临时窄宽度永久压缩按钮；透明绘制寻找非透明祖先背景。Test-UsabilityUI / VisualTheme / RoutingWorkbenchUI 覆盖实际窗口、菜单、帮助、1/1.25/1.5模拟缩放和小尺寸。
- 代理编辑保存传入 Expected 配置，在写锁内核验；不覆盖另一实例的备用策略或入口。自有入口编辑不转换外部引擎，不丢失 Failover。
- 任务卡使用 TaskGrid 最小行高和纵向滚动，不依赖操作系统允许加大窗口；列布局宽使用实际 ClientSize，禁止横滚。缩放回归同时放大显式字体，按钮测量共享 TextBounds，逐项滚动后保留祖先可见边界断言。
- 主页使用 ScrollablePage，显式同步 DockFill 根控件 MinimumSize.Height 到 AutoScrollMinSize，不能依赖 WinForms 自动识别 DockFill 的滚动范围。New-Grid 高度 0 表示 AutoSize；操作栏可换行，标题按真实宽度增高。云端固定 1024×728 工作区也要运行两种字体/三档缩放。

# 3.9.4 更新维护

- 托管启动使用 Wait-ManagedProgramIngressReady 的共享绝对期限；读取新鲜监督器健康结果、核验所选程序的有效出口和固定入口实际请求，再末次复核。默认出口故障不阻止正常专线；Direct 与明确直连网站例外分开提示，不能把有限可达称为整体恢复。
- 环境变量读取/端口诊断保留三态。系统直连时仅清理已确认死亡的简单本地用户变量；NO_PROXY 广泛绕过只提示不删除。事务、恢复与回滚调用 Set-UserProxyEnv 时传 ExpectedBefore，每个字段写入前核验，外部修改保留。不能声称 Windows 跨第三方读写完全原子化。
- 停止自有内核前按语义核验主入口及程序入口引用，支持 localhost/IPv4/IPv6 回环和协议列表分隔；仍被外部设置引用时保留后台并拒绝停止。对照完成与更新安装共同使用 Test-CleanStartSessionFinished 验证恢复记录，而非仅凭 phase 字符串。
- Test-ManagedLaunchReadiness 纳入 Test-All 与源码包；Test-ManagedSwitchChain 覆盖冷启动离线拒绝、默认故障专线正常、备用、明确直连及关闭自动备用，均使用真实隔离固定入口请求。

- 更新仅从 NOXEVYR/proxy-switch 稳定 Release 获取绑定清单；保持运行时和安装布局不变，Range 失败不得下载整包兜底。后台最多 50 MiB 差异；安装总须明确操作。
- 安装器通过独立 ShellExecute 启动，避免继承启动器管道而互等退出。进程核验复用 ProcessInventory 的有限查询，未知阻止替换，不强杀。
- 更新前用 Restore-IndependentSession -GracefulOnly 正常恢复设置；恢复/停止失败保留可见界面。替换只涉及已登记程序文件，事务和备份存数据目录 updates。
- Test-UpdateEngine/Transport/Install/Lifecycle 纳入 Test-All；Test-UpdateIntegration <已构建包目录> 使用真实隔离窗口/启动器/安装器，不能代替真实代理会话或账号验收。

# 3.9.3 整体维护约定

- 恢复与失效入口修复共用 NetworkDiagnostics 的 Get-LocalEndpointObservation / Get-RecoveryEndpointState；未知归属或 IPv6 双栈未知不能等同入口停止。撤销手动标志须保留 PAC/自动检测模式。
- 提交后的桌面入口观察不得抛出操作失败；返回独立未知标记与安全提示，保留线路结果和备份。只读就绪查询可在同一绝对期限内重试，不重复写入或启动。
- UI 操作/观察失败后，列表与汇总卡一起标记过期；筛选/右键菜单延迟刷新不得把旧快照当成新状态。
- Test-WebTransport.cjs <CorePath> 验证真实 TLS POST、分段返回与目标错误；仅使用显式公开测试证书和回环源站，不改信任库，不读账号。测试证书只随源码白名单分发，不进入 Windows 程序包。
- Test-RecoveryConsistency、Test-ManagedReadiness 纳入 Test-All 和源码打包。每轮维护按 ACCEPTANCE / TEST_REPORT 验证跨模块链路；不得以首页 HTTP 200 代替网页发送或真实认证成功。

# 3.9.2 列表刷新约定

- 程序与代理列表先构建完整快照，再调用 DataList.ApplyRows。身份/顺序不变时原位更新；成员变化后按身份恢复滚动、选择与焦点。BeginUpdate/EndUpdate 必须用 finally 配对，渲染失败不得先清空旧表。
- Test-ListRefreshUI 使用隔离演示数据验证反复刷新、隐藏/显示、切页、缩放、列表成员变化及失败恢复；不能把加速循环说成实测多小时在线。

# 3.9.1 启动入口维护

- 程序选线不改写桌面快捷方式；仅显式启动方式设置可创建、绑定或恢复入口，线路与入口状态独立。写入使用快照和 CAS，失败只回退仍归本次修改的内容，保留外部编辑。
- 自动发现所有入口（扫描、系统配置、缓存保存）排除自有网关/程序入口及数据目录内自有内核，端口从当前配置读取，不硬编码忽略端口。

# 3.9.0 游戏诊断约定

- 连接证据必须区分入口与出口；经流向直连不是绕过入口，已建立 TCP 不等于登录成功。内部通信只接受精确反向四元组及已验证同进程/家族身份，不能猜测未知回环端口。
- ProgramFamilyRouting 仅向已验证的当前家族成员补缺规则；预览有效期、规则 revision、进程创建时间和文件身份均须复核，保留冲突和网站例外。
- ProgramCleanStart/CleanStartWorker 只启动用户确认的原 EXE，不结束用户进程。临时直连是显式操作，最多五分钟；WinINet 写入/恢复须短事务锁和所有权检查，保持外部修改。监视器异常退出须有恢复兜底，恢复失败保留记录。
- 对照恢复只被动核验原简单本地入口；已停止时撤销失效手动代理并保留原自动模式，未知状态不得当作已停止。入口检查之后须再做快照 CAS，重复恢复须幂等。
- 清理仅限子进程环境块。启动成功后的记录失败不得报告为未启动；启动结果与恢复结果分开。新界面动作与拒绝路径须由真实控件测试覆盖。
- 品牌标识集中于 DesktopBranding.cs，EXE、窗口、快捷方式必须一致。仅刷新本工具快捷方式，不清空系统缓存或重启 Explorer。
- 快捷方式文件通过 ShellShortcut.cs 的 IShellLinkW/IPersistFile 读写，避免依赖系统旧代码页；只在快捷方式操作时加载独立类型，不调用 Resolve 或执行目标。编辑既有入口保留额外 Shell 属性；程序代理入口不自动写入流向品牌 AppID。
- 新验证：Test-ProgramFamilyRouting、Test-ProgramCleanStart、Test-CleanStartWorker、Test-DesktopBranding 纳入 Test-All；新模块同步加入测试夹具及两个打包白名单。不得发布 clean-start 会话、真实用户进程或网络记录。

# 3.8.2 网络修复约定

- 失效入口修复只接受明确确认、全量配置 revision 与新鲜 TCP 观察。简单回环代理在没有监听时才可清理；远程/复杂/未知不能按失效处理。
- 备用接管保留程序专用选择和网站例外，迁移前后均验证实际请求；无可用备用只撤销坏的手动系统入口及已确认失效的本地代理变量，保留有效变量、自动配置及原选择记录。
- 外部守护/TUN 和活动会话入口偏离必须诊断提示；不自动关闭第三方开关，不后台争抢代理。Test-DeadEntryRepair 纳入 Test-All，Test-DeadEntryIntegration 使用真实隔离内核，Windows 写入模拟。

# 3.8.0 核心重构约定（优先于下方历史模式约定）

- 明确切换不因第三方仅开启普通系统代理而一律阻止；实读/CAS写入流向入口，并提示第三方随后启动/退出可能改写。TUN或持续代理守卫仍需先关闭；不代用户改第三方开关，不后台抢回入口。外部分流引擎已退出时，先经detach-offline证明并移除本工具旧规则，再转入自有网关；不能被已退出引擎的reload要求永久卡死。

- 普通统一切换使用 Set-UniversalProxy，明确选线时接入自有固定入口；普通程序选线使用 Set-ManagedApplicationRoute。支持的 Chromium/Electron 使用稳定的独立 mixed listener，主程序参数和子进程环境均不再绑定上游端口；不要求用户选择 launch/engine 模式。被动打开、刷新仍不接管网络。
- app-rules.json version 3 在同一 CAS 事务中保存 entries、defaultRoute、programIngresses、siteRules。旧请求缺失新增字段时保留现值，显式空数组才清除。每个程序入口使用独立 selector；只有显式改该程序线路才重置它，无关规则同步保留备用。Follow 保留 id/port 并跟随默认；统一切换撤销程序专用选择，保留网站规则。
- 网站优先级：指定程序范围优先于全局范围；同范围内更具体的域名优先，同域精确匹配优先于子域规则。配置生成与观察/重连的规则解释必须一致。不采集完整登录 URL、授权码或令牌。
- 启动请求必须交给持有托盘生命周期的主 UI。IPC 仅同用户、路径参数、30 秒有效期、最多 4 条；执行前复核已保存程序，未就绪不启动。Process.Start 成功后的观察/记录失败不得报告为启动失败。
- 当前宿主会话内可以缓存已验证父子关系，但每轮必须重新核验 PID、创建 ticks、规范路径和文件身份，不缓存存活结论，不持久化私人进程关系；未知不猜测。宿主重启丢失孤儿关系不影响其固定入口转发，观察仍需明确未知。
- 移除入口前核验 family、控制器和当前 TCP；活跃或未知拒绝，先用 Follow 取消专用线路。引擎写锁内复核活跃入口。端口所有权使用 GatewayPortOwnership.ps1 的 GetExtendedTcpTable 与精确自有核心 startTicks，禁止读目标进程内存。
- 新验证：Test-ManagedRouting、Test-ProgramFamilyTracking、Test-ManagedObservation、Test-ManagedRemoval、Test-ManagedLaunchEvidence、Test-RoutePolicy 纳入 Test-All；Test-ManagedSwitchChain.ps1 -RuntimeDirectory 和 Test-ProgramIngressIntegration.cjs <CorePath> 使用真实隔离内核/父子程序/HTTP。UI 使用 Test-RoutingWorkbenchUI、Test-LaunchDispatch。不得用本地夹具通过代替真实 OAuth 登录验收。

# 3.7.2 维护约定

- 手动 Set-SelectedProxy 通过一次性 resetDefaultSelection 区分用户重选和普通同步；不持久化该标记。普通规则变更、路径修复、后台刷新必须保留有效备用。
- 已配置 standalone 且没有活动会话时，用户点击统一切换可启动并核验其固定入口；打开／刷新仍为只读，不自动迁移第三方引擎。冷启动切换快照须包含原程序规则。
- 旧启动代理记录在 UI 改线时保持 launch 模式。主程序及子进程适配需明确选择；已有 engine 规则必须先明确移除，禁止静默混用。
- Test-EntryMaintenance.ps1 纳入 Test-All；Test-SwitchChain.ps1 -RuntimeDirectory <现有锁定组件目录> 使用真实隔离内核与本地 HTTP A/B/D 应答，覆盖冷启动、来回切换、手动返回首选、实际出口不一致时回滚及状态显示；Windows 和 RunOnce 写入使用桩。
- Test-ObservationUI.ps1 验证实际右键菜单与诊断按钮；Test-ProgramLaunch.ps1 用实际临时父子程序验证下一次启动的 A→B 环境继承。以上不能代替真实 IDE OAuth 验收。

# 网络代理切换器

- Windows PowerShell 5.1 / WinForms。Windows 程序包自带锁定版本 Node.js 与 mihomo；源码开发也可使用已安装的组件。本目录 vendor/js-yaml 5.4.1 保留 MIT 许可证。不自动更新依赖。
- `ProxySwitch.ps1` 是脚本入口；`ProxyBackend.ps1` 提供状态、诊断、事务切换和恢复。Windows 程序包由编译后的 `FlowSwitch.exe` 启动 `app/ProxySwitch.ps1`。
- `Preferences.ps1` 提供本机设置、快捷方式解析、汇总诊断；`Storage.ps1` 解析共享目录，数据默认保存到 `%USERPROFILE%\.proxyswitch`，避免 MSIX AppData 重定向产生不同文件视图。代码目录仅保留 `config.defaults.json` 默认模板。测试可用 `PROXY_SWITCH_DATA_DIR` 指定隔离目录。
- `Build-Release.ps1 -Destination <新目录>` 通过显式文件清单打包；不得把本机 config.json、selection.json、app-rules.json、备份或实机截图加入清单。
- `assets` 中的截图使用 `-Demo` 演示数据生成；不要用用户真实进程列表作为公开截图。
- PowerShell 中文源文件保存为 UTF-8 BOM，兼容 Windows PowerShell 5.1。
- 全局切换管理当前用户 WinINet 系统代理及 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY；NO_PROXY 仅追加本地绕过，直连时保留。
- 引擎规则分流使用 Clash PROCESS-PATH 规则；仅管理 PSW-App-* 命名的代理和规则及带标记的全局脚本扩展，保留其他设置。
- 修改 Clash 前验证候选配置、备份，并通过已有本地命名管道重载和核对规则；失败回滚。含节点凭据的备份只存在 Clash 用户配置目录中，不写入 outputs。
- 不输出 API 密钥、订阅地址、节点凭据或账户认证；不改账号切换器、DNS、路由、WinHTTP。不自动开启 TUN 或网络控制端口。
- 不自动结束 Codex、浏览器或其他客户端进程；显示当前连接和重启提示。
- 不后台抢回代理。切换带跨进程互斥、持久化备份、失败回滚、实读校验。
- 验证：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ProxySwitch.ps1`（内存模拟写入，不改真实网络）。
- 只读实机检查：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\ProxySwitch.ps1 -Status` 和 `-Check <代理标识>`。
- 界面预览：`powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\ProxySwitch.ps1 -PreviewPath <绝对PNG路径>`。
- 分流单元测试：`node .\Test-AppRouter.cjs`。实机分流只使用工作目录中专门编译的校验程序，完成后移除测试规则。
- 完整静态与单元验证：`powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-All.ps1`。界面检查：`powershell.exe -NoProfile -STA -File .\ProxySwitch.ps1 -SmokeTest`。
- Windows PowerShell 5.1 调用 .NET 需要空字符串指针时使用 `[NullString]::Value`；不要将 `$null` 传入 `File.Replace` 的 backupFileName 参数。

- 3.0 的代理模型是 Version=3 / Profiles[] / Routing；全新默认 Profiles 为空，品牌名称只允许出现在旧配置迁移、候选端口识别或特定引擎适配中，不能作为固定 UI 选项。
- 「统一切换」必须一起处理系统代理、用户变量和程序例外，保存可恢复快照。启用引擎时使用托管默认 MATCH 规则；不要将“只改系统入口”声称为统一出口。
- 原生设置尚未开始写入时，失败不能覆盖其他程序的并发系统设置更改。应用路由后需验证实际线路。
- HTTP 与直连的基础统一切换、Chromium/Electron 启动代理不依赖 Node.js 或任何 VPN 品牌；SOCKS5 统一切换和引擎规则分流需要可选引擎。
- 独立集成测试可设置 PROXY_SWITCH_TEST_ENGINE_DIR 和 PROXY_SWITCH_TEST_PIPE；后者必须以 \\.\pipe\ProxySwitch-Test- 开头。使用专门的回环端口、独立状态目录和测试进程，退出时结束自己启动的引擎，不修改用户实例。

- 3.0.3 保留启动与定时自动发现，提供独立的自动发现开关。启动、刷新、退出不写系统代理、环境变量或程序规则，不重新应用历史选择。自动发现可以补充本机代理列表；主动握手仅针对已识别的代理内核或用户配置的内核完整路径，发送前复核 PID、启动时间、路径与监听归属。不扫描游戏或无关程序端口。未知客户端可以从当前系统代理/用户代理变量被动识别，或由用户明确添加入口后手动检测。
- 保留用户已有标识、名称、Routing 和 DiscoveryIgnored。探测后须在互斥锁内重新读取配置，去重后再保存；删除本地入口时记入忽略列表。
- 后台状态响应需携带同一配置目录的 Settings，UI 同步下拉框与列表；SmokeTest 不运行自动发现，断言配置数量与列表数量一致。
- 新增验证：powershell.exe -NoProfile -ExecutionPolicy Bypass -File .\Test-ProxyDiscovery.ps1（真实回环应答与隔离配置，不写真实网络）。

- HTTP 统一选择直接使用所选入口；只有引擎自身或 SOCKS5 需要托管默认 MATCH。回滚前检查设置仍属于本次操作，保留外部更改。撤回必须检查本地代理环境变量端口。
- `Test-Compatibility.ps1` 验证被动状态、游戏端口排除、并发回滚、失效备份和 SynSent；不得读取游戏进程内存或自动重启游戏来测试。
- 界面回归：`Test-PassiveLifecycle.ps1`（关闭自动发现后的 72 秒观察模式）、`Test-DiscoveryUI.ps1`（手动发现、外部配置刷新、删除与重扫）、`Test-AutomaticDiscoveryUI.ps1`（自动发现、缓存、新端口与程序监控）和 `Test-SwitchInteraction.ps1`（用户切换优先、进度与设置实读）。均使用隔离配置和模拟 Windows 写入。
- 进程路径通过 `ProcessInventory.ps1` 的 QueryFullProcessImageNameW 和 PROCESS_QUERY_LIMITED_INFORMATION 获取。不得回退到 Windows PowerShell 5.1 的 Get-Process.Path / MainModule；它们可能请求 VM_READ 并枚举目标模块。拒绝访问时仅显示可取得的 PID/名称，不提权。
- 切换使用 Test-ProxyRoute -Fast，并行预检、任一可用即继续；完整逐站诊断保留独立入口。后台发现须响应用户操作的取消请求，不能强行中断网络事务或回滚。
- 单元/隔离验证不能代替真实游戏登录，不能把偶发成功或有限查询接口变更表述为已确认游戏错误的根因。


- 3.1 为有 Chromium/Electron 运行资源的程序提供启动代理适配，界面使用受支持的代理启动参数，子进程使用独立 HTTP_PROXY/HTTPS_PROXY/ALL_PROXY/NO_PROXY 环境块。不修改第三方 app.asar、账号或登录凭据，不覆盖用户/系统环境变量。
- 程序启动代理保存在 program-proxies.json，入口备份与记录保存在本机 backups/shortcuts 与 program-shortcuts.json；启动证据保存在 program-launches.json。全部不得发布。按程序保存目标不能宣称已经生效，需识别实际启动会话并观察父子进程连接。
- 原桌面入口无额外参数时可备份后接入；有自定义参数则保留它并创建单独的代理入口。入口每次启动读取最新选择和端口。正在运行时拒绝重复启动，不自动结束软件；恢复不得覆盖用户后来更改的目标/参数。
- 统一切换要将启动代理专用目标改为 Follow，与引擎规则一起备份和回滚。删除代理时检查两类规则的引用。旧版本备份只恢复其包含的数据。
- Get-ProgramFamily 汇总同一程序目录内由其创建的子进程，显示入口外 SynSent。未单独指定、等待重开、已启动待验证、实际观察到目标连接必须分开，不能仅靠主界面连接就声称联网子进程也已成功。
- 新增 Test-ProgramLaunch.ps1：真实临时父子程序验证环境继承、原桌面入口备份/恢复、引擎离线时的程序代理、统一回滚与子进程绕过状态。只写临时目录。
- 3.1.1 默认共享目录只在首次创建时复制当前环境可见的旧 AppData 数据，完整复制后原子发布，保留原文件；已有共享数据不得被旧版本覆盖。仅在存在匹配的迁移记录时将显式旧默认目录作为兼容别名；其他显式目录及测试环境变量保持隔离。迁移不得应用历史线路或写 Windows 网络设置。
- `Test-Storage.ps1` 验证共享目录解析、迁移完整性、备份索引重定位、旧入口兼容和失败保留。`last-program-launch.json`、`storage-layout.json` 及程序配置和记录只存本机，不能加入发布清单。实机桌面入口验收必须由桌面实际启动，打包父进程下的成功运行不能代替。
- 3.1.2 同时发布 Windows x64 程序包与源码包。`Build-WindowsPackage.ps1 -Destination <新目录>` 使用 Windows 自带 .NET Framework csc 编译 `Launcher.cs` 为 WinExe，按运行文件白名单打包，不下载依赖；保留 `app` 目录，不将 EXE 宣称为无依赖的单文件程序。
- `Test-WindowsPackage.ps1 -PackageDirectory <包目录>` 校验文件哈希、移动后的 Unicode/空格路径、EXE SmokeTest、显式数据目录和缺失文件处理。测试安装脚本只在临时副本中替换桌面目录，不能创建或覆盖真实桌面图标。

- 3.2.0 的 Routing.UnifiedMode 为 system（旧默认）或 gateway（用户选择固定入口）；gateway 要求引擎就绪，HTTP/SOCKS5/Direct 均保持同一本地入口，不能离线时偷偷回退到其他端口。
- 普通 Set-ApplicationRoute 始终设置引擎规则，不再默认调用启动适配或创建快捷方式。旧启动适配只保留兼容记录，迁移某条引擎规则时相应启动目标设为 Follow。
- 按程序重连必须先预览并由用户点击确认，只 DELETE 已预览且仍匹配 EXE、连接 ID、开始时间、旧线路的连接。不得调用全局 DELETE /connections，不自动重连/退出对话、浏览器或游戏。
- Test-GatewayControl.ps1 检查固定入口计划与无快捷方式副作用；Test-GatewayIntegration.cjs <已安装内核绝对路径> 使用独立配置、命名管道、两个测试 EXE 和本地 HTTP/SOCKS5 上游验证真实连接，不下载依赖。

- 3.2.1 品牌为流向 FlowSwitch；DesktopBranding.cs 提供运行窗口任务栏标识和重开属性。发布图标为 assets/FlowSwitch.ico，PNG 只随源码发布。保留 ProxySwitch.ps1、.proxyswitch 与 PSW-App-* 内部兼容标识。

- 3.3.0 的 FlowTheme.cs 提供 WinForms 深色控件；加载时引用 System.Windows.Forms、System.Drawing。不要重写代理后端来调整外观。列表列宽仅响应外部宽度变化，预留滚动条空间，避免 SizeChanged 递归。视觉验证：Test-VisualTheme.ps1（120 行演示数据、三页导航和三种窗口尺寸），配合 Test-SwitchInteraction.ps1 与 Test-WindowsPackage.ps1。

- 3.3.1 的 ListHost / LogHost 使用裁切视口与独立滚动轨道。不得以删除滚动功能解决白色滚动条；列宽只由 DataList.SetColumnWeights 管理。所有主工作区须显式指定百分比行/列，测试需断言整个工作区及底栏不被裁切。Test-VisualTheme.ps1 -Scale 1.25 / 1.5 为布局模拟，不宣称已改变或逐个实测操作系统 DPI。

- 3.3.2 列宽需在原生缩放完成和绘制前按实际客户区收敛；滚动回归必须检查 WS_HSCROLL，而不能只比较列宽总和或一张静态预览。

- 3.4 独立模式由用户显式启用：standalone 内核和恢复进程只管理自己的本地端口，不复制订阅、不自动开启 TUN。自动接替只改独立内核出口，不反复覆盖 Windows 代理。正常退出与崩溃恢复必须先恢复仍归属本会话的系统代理和环境变量，再停止自有内核；原入口失效时恢复直连。RunOnce 只用于异常断电后的下次登录恢复，不自动接管网络。验证 Test-IndependentRouter.cjs、Test-IndependentIntegration.cjs、Test-ExitRecovery.ps1、Test-Watchdog.ps1。

- 3.5 Windows 包自带锁定版本 Node 与 mihomo；运行时不下载或安装组件、不修改 PATH。Prepare-Runtime.ps1 只在明确构建时按 runtime.lock.json 从官方来源准备并校验组件。Build-WindowsPackage.ps1 必须使用已验证 RuntimeDirectory。包内保留许可证和对应内核源码。源码开发仍可使用已安装组件。
- RuntimeSupport.ps1 统一解析运行组件。现有独立内核副本优先保留，新电脑先检查随包标准内核是否受处理器支持，不支持时使用兼容内核；健康检测从 Windows 绝对路径启动 curl。Test-RuntimeBundle.ps1 使用隔离目录、空 PATH、真实内核和 Windows 写入桩；不得修改真实用户配置或 RunOnce。
- 3.5.1 重载规则与回滚保留仍有效的内核当前备用选择，不能使无关程序回跳首选。检测进程不可用是未知状态，不能据此宣告全部失败。HTTP 健康检查验证 CONNECT 隧道。接替事件仅存本机 gateway/failover-events.json，限制 100 条，不记录目标网址、进程路径或凭据。检测成功不能等同于用户目标网站可用。
- 界面可在同一轮显示刷新中传递 TcpRows 快照，包含 Listen/Established/SynSent；不保存为跨轮缓存。切换、健康检查和退出恢复的网络就绪判断必须实时读取。Test-StatusSnapshot.ps1 验证空快照、状态过滤和实时校验不复用旧快照。


- 3.6 窗口默认关闭到 NotifyIcon 托盘，必须使用 Application.Run 保持隐藏窗口消息循环；托盘明确提供打开和停止服务并退出。ui-settings.json 属于本机私有设置，不能发布。同一数据目录再次启动只唤醒现有窗口；Windows 注销/关机不拦截为隐藏。
- 独立内核恢复使用同一 supervisor，五分钟内最多三次，退避 1/2/4 秒；同时校验监听和控制接口。上游全失效只暂停出口，不因健康站点失败重启内核。恢复守护必须验证 supervisor 身份与新鲜心跳，最多给予 45 秒入口恢复时间；恢复 Windows 失败最多尝试三次，保留会话和提示。
- 退出先实读验证仍归属本会话的 Windows 设置恢复，再请求 supervisor 停止当前 child。Supervisor 崩溃后的 child 必须同时核对 PID、父 PID、启动时间与 EXE 路径，不得只按文件名杀进程。生命周期日志只接受固定事件/原因码及数字，不记录原始 stdout/stderr、URL、程序路径或凭据；限制大小。
- Google 登录诊断仅对固定 oauth2.googleapis.com/token 发出无凭据 HEAD 请求。区分本地入口、代理握手和 HTTPS 响应，任何 HTTP 响应不能等同登录成功。托管启动等待独立入口及已加载出口；普通启动只能诊断与提示，不声称刷新了应用环境或缓存。
- 新验证：Test-LifecycleProtection.ps1（已纳入 Test-All）、node Test-Lifecycle.cjs <现有内核EXE>、Test-TrayLifecycle.ps1 -CorePath <现有内核EXE>、Test-SupervisorRecovery.ps1 -CorePath <现有内核EXE>。后三者使用真实隔离内核；Windows 设置使用桩。UI 旧回归通过 ui-settings.json 关闭驻留以正常清理测试窗口；托盘测试单独覆盖默认行为。

- 3.7 ProgramIdentity.ps1 使用注册包身份 / 包内相对 EXE 或真实文件身份关联；不按相同文件名猜测迁移，不提权。注册包元数据可跨 runspace 缓存，进程和文件证据不跨轮缓存。ProgramIdentity 与 ApplicationObservation 供只读刷新使用；RuleMaintenance 的修复必须由用户明确触发。
- 区分进程读取、TCP 采集、规则、连接及 selector API 的可用性；失败用 unknown / null，不等同空列表或未监听。程序表是 TCP 快照，不能代表 UDP / QUIC 全量网络或认证结果。引擎托管规则需核验完整顺序，不能只因列表中存在就认为有效。
- RuleMaintenance 计划必须在应用前复核身份、记录快照和快捷方式归属；引擎 replace 的 expectedStateHash 在内部锁中比较 UTF8 无 BOM 文件文本 SHA256，缺失使用 <missing>；成功返回自己写入的 stateHash。身份元数据不参与线路指纹，不能使备用出口回跳。
- 生命周期停止 / 重启使用绝对就绪期限；旧 supervisor 停止中不复用旧 child。孤儿内核清理核对精确 OS 创建 ticks 并持有进程句柄。watchdog 用 ExpectedSession 在锁内校验会话，恢复环境变量前重新实读归属。
- 新单元测试：Test-ProgramIdentity.ps1、Test-ApplicationObservation.ps1、Test-RuleMaintenance.ps1，均纳入 Test-All；真实控件测试：powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -File .\Test-ObservationUI.ps1。完整功能范围见 ACCEPTANCE.md，已执行验证见 TEST_REPORT.md。

- 3.7.1 损坏锁只在 GatewayLock.ps1 持有禁止写入和删除的文件句柄期间核对并接管；不得按时间戳直接删除，也不得终止锁持有进程。锁释放需等待竞争恢复句柄。Test-GatewayLock.cjs 纳入 Test-All，覆盖活跃空锁及八进程恢复竞争；Test-Lifecycle 验证空锁下真实自动接替。
