# Read-only guidance. This module owns only its dialog and never changes routing or launch settings.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-FlowProgramStatusSummary($App) {
    if($App.RequiresRepair){return '需修复程序路径'}
    if($App.Status -match '读取失败|未知|失败'){return '状态未知 · 查看下方说明'}
    if($App.NeedsRelaunch){return '需正常退出后从流向重开'}
    if($App.ProgramEntryState -eq 'Partial' -or $App.Status -match '未确认接管|绕过|旧线路|未接入'){return '部分连接未接入 · 查看下方'}
    if($App.Loaded -and $App.Status -match '已观察到'){return '已观察到规则线路'}
    if(-not $App.HasSavedRule -and $App.Mode -notin @('engine','managed','launch')){return '未单独设置'}
    if($App.Running -or @($App.PIDs|Where-Object {$_}).Count){return '运行中 · 等待连接核验'}
    return '已保存 · 等待程序启动'
}
function Get-FlowGuideTopics {
    @(
        [pscustomobject]@{
            Key='doctor'; Title='断网排查与恢复'
            Tip='先只读检查；旧代理卸载、卡死或退出后，可预览恢复普通上网。'
            Purpose='把用户系统代理、机器代理、代理变量、实际请求和隧道证据分开判断。'
            Steps=@('1. 首页点击「开始断网排查」，读取结果。此步不切换、不清理、不重启。','2. 明确放弃旧入口时，点击「重置代理…」。阅读预览，确认后先备份再重置用户代理。旧客户端已卸载也能处理。','3. 结果提示机器级残留时，点击「管理员恢复…」预览并确认，才申请 Windows 权限。取消只取消此步骤。','4. 点击「检测当前通路」，再回实际应用验证。需要代理时先在原客户端连接，再选择已登记代理并点「恢复到所选代理…」。','5. VPN/TUN 或断网保护需在原客户端处理。旧程序环境需保存工作后正常重开；只有一个软件失败时回程序线路单独排查。','6. 首页「恢复记录与撤回」可预览撤回用户级恢复；原入口不可用时拒绝恢复到坏线路。机器级备份独立保留。')
            Impact='用户级重置清除手动代理、PAC、自动检测和三项用户代理变量，保留 NO_PROXY 与专线。机器级步骤只清除三项机器变量和 WinHTTP 默认代理；不结束进程、不改网卡/DNS/路由、不后台争抢。'
            State='设置已重置、通路有响应和账号可用是不同结果。未知单独显示；自动备份失败、状态变化或仍有托管会话时给出原因与下一步，不能强行覆盖。'
        }
        [pscustomobject]@{
            Key='residue'; Title='后台旧代理残留'
            Tip='系统已切到 Clash，某个程序仍报错时，显式检查它的启动环境。'
            Purpose='按程序和后台 PID 显示代理变量中的本机端口、当前监听状态与已观察到的连接。只提取代理摘要，不展示完整环境、命令行或账号。'
            Steps=@('1. 首页点击「检查旧代理残留」，或在程序线路选中软件后点击同名按钮。只在你点击时检查，已识别游戏/反作弊目录、系统目录及已登记代理客户端不读取进程环境。','2. 「环境指向已停止入口」表示变量中的本机端口没有监听；入口不同但仍监听可能是专线。未知项保留未知，不自动清除。','3. 当前能用的程序继续使用。确需处理时，先保存工作并正常完整退出目标程序及后台，再点击「退出后按当前代理启动…」查看并确认。仍运行、入口变化或预览过期时拒绝启动。','4. 已有专线时点击「查看已有程序线路」，核对原入口并使用原线路；不会覆盖专线。新启动后用头像、登录或消息验证，再重新检查。')
            Impact='扫描不写网络设置、不结束程序。确认后仅对该程序本次新启动设置当前代理环境，保留账号、快捷方式、专线和其他程序；不重启 Explorer，也不修改持久环境。'
            State='代理变量不等于程序一定采用，TCP 连接也不等于请求成功。不读取或不支持的程序仍需在自身设置和普通网络排查中核对；检查结果只代表标注时间。'
        }
        [pscustomobject]@{
            Key='start'; Title='开始使用'
            Tip='管理已有代理，按需为程序和网站选线路。打开、刷新与自动发现不会切换网络。'
            Purpose='流向管理你已有的 HTTP / SOCKS5 代理，为默认请求、指定程序和网站分别选择出口。它不提供代理节点或 VPN 服务。'
            Steps=@('1. 打开流向先看「网络切换」顶部的当前系统代理管理方。当前入口与目标程序均正常时，无需重新应用，也无需启动独立入口。','2. 需要备用入口时，先在目标代理客户端连接。到「代理入口」选中它，点击「检测此入口」。未监听、归属未知或检测失败时，继续保留当前线路。','3. 入口可用后，在「网络切换」选择目标，点击「预览切换…」，核对影响后确认。返回原入口使用相同步骤。目标客户端只提供 VPN 隧道而没有本地 HTTP 入口时，先在原客户端核对模式；不要凭端口登记判断已兼容。','4. 只有某个程序出问题时，选中程序点击「排查此程序网络」；多个程序一起失败时，点击首页「开始断网排查」。根据结果处理入口、变量或程序旧连接。')
            Impact='普通打开、刷新、自动发现只读取状态或补充入口列表，不会重新应用历史线路。明确切换后才改变网络设置；关闭主窗口默认收至托盘，服务继续运行。需要停止时使用托盘「停止代理服务并退出」。'
            State='先看入口是否就绪，再看实际出口。随后在目标应用发起一次真实请求。规则已保存、端口可连接或网页首页打开，都不能证明账号登录和对话发送成功。'
        }
        [pscustomobject]@{
            Key='vpn'; Title='多代理与 VPN 共存'
            Tip='先选择故障程序排查，再按实际入口处理。程序直连不等于绕过 VPN 的系统路由。'
            Purpose='把程序自己的代理、Windows 系统代理和 VPN 隧道路由分开检查。不同层可以同时存在；改一层不保证另一层跟随。'
            Steps=@('1. 在「程序线路」选中打不开的程序，点击「排查此程序网络」。程序专线从自身入口代测；当前可核验的外部代理另作独立对照；家族观察不完整时只代表已核验成员。整机入口问题单独保留。','2. 在结果的「处理办法」选择路径修复、程序线路设置、重连预览或启动步骤。每个步骤显示对象、影响和前提；先处理身份未知或路径失效。','3. 入口仍监听但 HTTPS 请求超时时，先在原代理/VPN 客户端核对连接和节点，再检测同一入口。链路正常后，才根据程序实际错误决定是否保存工作并正常重开。浏览器与程序可能走不同线路或接口，不能只凭浏览器能用就认定重启程序能修复。','4. 若希望游戏等程序绕过 VPN，先核对 VPN 客户端自身是否提供程序或网站绕过规则；流向的「直连」只是不使用指定上游代理，不保证避开 VPN 隧道路由。流向不代改第三方 TUN、DNS、hosts 或路由。')
            Impact='诊断只读；进入处理步骤不会自动执行整机修复。确认的程序修复继续使用原有身份核验、备份和恢复机制。机器级设置和第三方接管需在原设置中核对，流向不会反复抢写。'
            State='隧道路由的 Evidence / Unknown / NoEvidence 分别表示见到证据、读取或覆盖未知、未见证据；未见不代表关闭。已见 TCP、代测 HTTPS 成功或端口监听，不代表真实登录、游戏或持续对话已通过。'
        }
        [pscustomobject]@{
            Key='switch'; Title='日常切换与撤回'
            Tip='日常模式先预览，再检测并切换系统代理；保留程序专线，不启动独立入口。'
            Purpose='让遵循系统代理的新请求使用选定客户端。已运行程序可能记住旧变量；保存的目标、当前系统入口和程序实际连接分别显示。'
            Steps=@('1. 在原代理客户端连接，到「代理入口」检测目标。下拉框选择本身不会应用。','2. 点击「预览切换…」，查看当前目标、切换范围与下一步，确认后重新核验并检测。选择当前有效入口时无需重复写入。','3. 「撤回上次切换…」只撤销仍归流向最近一次日常切换的设置；入口停用或外部设置已改变时拒绝恢复，并保留当前状态。','4. 已明确配置高级独立分流时，按钮显示「统一切换」；该模式另有程序专线重置范围，请核对页面说明。')
            Impact='日常模式只修改当前用户 Windows 系统代理和 HTTP_PROXY、HTTPS_PROXY、ALL_PROXY，保留 NO_PROXY、程序规则和绑定。不会关闭程序、切第三方节点、开 TUN 或后台抢回代理。高级统一切换会把程序专用选择改为跟随，保留固定入口和网站例外。切换和撤回前均有备份；不恢复任意历史网关配置。'
            State='当前管理方按实读的系统入口显示，不能证明所有程序均使用它。目标客户端未提供可核验 HTTP 入口时不能切换；VPN/TUN 路由仍由原客户端管理。已有长连接不会自动迁移，短暂断网先检查入口和代理通路，再决定是否正常重开单个程序。'
        }
        [pscustomobject]@{
            Key='programs'; Title='程序专用线路'
            Tip='为选中程序设直连、代理或跟随。首次接入可能需完整重开；选线不会自动绑定桌面图标。'
            Purpose='让已接入流向的程序使用自己的线路，例如浏览器跟随默认线路，而 IDE 使用另一条代理。'
            Steps=@('1. 在「程序线路」搜索并选中程序；也可点击「添加程序…」选择 EXE / 快捷方式，或拖入一个文件。','2. 点击底部「设置此程序线路 ▾」，指定「直连」、某个代理或「跟随统一线路」。右键菜单也可设置。普通游戏等没有启动适配的程序，选目标后直接弹出接入预览；首次不需要先找「按此线路打开」。','3. 核对预览中的系统入口接入和已核验子进程后确认；保留其他专线、当前备用和网站规则。已有引擎规则需重新接入时，点击「应用线路并检查」。支持启动适配的程序使用「按此线路打开」。服务未启动时，先到「代理入口 → 备用与服务 → 使用流向独立入口」明确启动已配置服务。','4. 程序升级后点击「修复路径后改线…」核对旧、新路径。服务明确停止时只修保存记录，不必先启动代理；候选不唯一时拒绝。想使用 Windows 当前系统代理，在「更多设置 → 记录与详情」选择「使用系统代理（取消已停用专线）…」，预览并确认；它与跟随流向默认出口的「跟随统一线路」不同。')
            Impact='支持的 Chromium / Electron 与已核验 Qt 网页组件通过稳定本地入口启动，继承此入口的联网子进程可一起改出口。命令行和后台程序可在「更多设置 → 启动与桌面入口 → 命令行 / 后台代理环境…」明确配置；它只影响从流向新启动、会读取代理变量的请求。Qt 只控制遵循参数的网页组件；首次接入后需正常退出整组程序并从流向打开。已有 Codex、其他终端启动、独立服务或忽略代理设置的请求不保证覆盖。选线不自动绑定桌面；改回「跟随统一线路」取消专用选择。'
            State='「已保存」「已加载」「等待重开」和「已观察到实际线路」代表不同阶段。双击程序，或到「更多设置 ▾ → 记录与详情 → 程序与连接详情…」查看证据。系统入口绕过流向时，只保存规则不会接管；请点击「应用线路并检查」。需要接入、等待连接和未知分开显示，代理端口已连接不能冒充引擎接管证据；父程序一条成功连接也不能证明全部子进程都使用目标线路。'
        }
        [pscustomobject]@{
            Key='websites'; Title='网站分流'
            Tip='只填域名，为网站设直连或代理。网站例外优先于程序线路，统一切换会保留。'
            Purpose='同一个浏览器中，让不同网站分别直连或使用代理，例如程序默认代理，某个网站单独直连。'
            Steps=@('1. 在「网络切换」点击「设置网站例外…」。仅为某程序设置时，到「程序线路」选中它，再打开「更多设置 ▾ → 连接检查与恢复 → 此程序的网站分流…」。','2. 选择所有程序或指定程序范围，只输入域名，例如 example.com，选择仅此域名或包含子域名，再选择线路。','3. 点击「添加 / 更新」，核对列表后保存。不要粘贴登录链接、完整网址、查询参数、授权码或令牌。','4. 保存后在目标程序重新发起请求；原网页仍使用长连接时需重新打开页面，必要时完整重开程序。')
            Impact='网站例外优先于程序线路。指定程序范围优先于全局范围；同一范围更具体域名优先；同域「仅此域名」优先于包含子域名。统一切换会保留例外。删除对应条目并保存即可取消；在编辑窗口点击取消不会应用修改。规则仅控制进入流向的新连接。'
            State='「网站规则已加载」说明规则已交给入口，不等于网站所有功能都可用。页面可能访问多个域名，应分别核对实际请求；不要为排查而提供登录链接或账号凭据。'
        }
        [pscustomobject]@{
            Key='proxies'; Title='代理入口与自动发现'
            Tip='添加、检测已有 HTTP / SOCKS5 入口。自动发现只补充列表，不切换网络，也不提供节点。'
            Purpose='整理自己的代理服务地址、协议和端口，便于统一切换、程序分流和备用选择。'
            Steps=@('1. 打开自己的代理客户端并等待服务就绪。','2. 在「代理入口」点击「发现后台代理」，或用「添加代理入口…」填写已知地址、端口和协议。','3. 选中条目，使用底部「检测此入口」「编辑入口…」或「打开关联代理软件」。移除登记用「更多 ▾ → 从列表移除此入口…」。','4. 若代理列表仍为空，请核对客户端的实际监听地址及协议，不要把游戏通信端口当作代理入口。')
            Impact='自动发现可识别已知代理程序，并缓存发现结果；不会对无关游戏端口发送代理握手，也不会自动切换系统入口。添加和编辑后，仍需明确选线才应用。删除有规则引用的代理需先处理引用；删除本地入口后会记录忽略，避免反复发现。取消自动发现不会停止已有代理服务。'
            State='列表中出现代理只说明入口已登记；本地监听、代理握手和外网请求是不同检查。代理客户端退出后，端口可能失效。不要仅凭「已发现」判断当前网络可用。'
        }
        [pscustomobject]@{
            Key='failover'; Title='自动接替与备用'
            Tip='首选线路连续失败时尝试已配置备用；全部失效默认暂停，允许直连须明确勾选。'
            Purpose='已接入流向的请求遇到首选代理故障时，按顺序尝试可用备用线路，减少手动切换。'
            Steps=@('1. 在「代理入口」打开「备用与服务 ▾ → 备用线路顺序…」。','2. 启用自动接替，选择备用代理并调整顺序。每个程序先尝试自己指定的线路。','3. 如确实接受全部代理失效后直连，明确勾选「全部代理失效时允许直连」；默认关闭。','4. 保存后观察首选线路、当前出口与接替提示。需要返回首选时，重新明确选择对应线路。服务入口设置在同一菜单的「使用流向独立入口…」；已有外部引擎适配才使用「配置外部 Clash 引擎（高级）…」。')
            Impact='软故障连续多轮才接替，已确认本地入口停止时可提前接替。首选恢复后保留仍可用的备用，避免反复跳转。关闭自动接替取消后续自动选择，不代表现有连接已经回到首选；明确重新选线后核对出口。全部代理失效且未允许直连时暂停相应出口，其他程序专线或直连网站例外可能仍可用。'
            State='「首选」是保存的目标，「当前出口」是入口实际使用的线路。检测过期、检测工具出错或出口未知不能当作健康。备用可达不保证所有网站和账号正常，旧长连接可能仍需应用自行重连。'
        }
        [pscustomobject]@{
            Key='diagnostics'; Title='自助网络排查'
            Tip='先只读排查，再确认具体修复。未观察到连接不等于断网，TCP / HTTPS 成功不等于登录成功。'
            Purpose='区分入口未就绪、默认出口暂停、系统设置冲突、程序仍用旧地址和目标站点响应等问题。'
            Steps=@('1. 一个软件打不开时，在「程序线路」选中它，点击「排查此程序网络」。不确定影响范围时，到「检查与维护 → 连接检查」点击「开始网络检查」。','2. 结果窗口直接给出结论、设置/入口/通路/程序连接四层证据和下一步。先处理明确发现的问题；需要更多证据时，按提示在软件中重试，再点「重新检查」。','3. 当前存在可处理项时，「整机修复预览…」才可用；核对整机影响后确认。站点限制、凭据问题或证据不足不会假装已经修好。','4. 「检查详情」可查看底层证据；同页的「检测此入口」用于复核单一代理。旧连接需要更新时，在程序的「更多设置 → 连接检查与恢复」预览重连范围后确认。','5. 「检查与维护 → 维护与恢复」提供「重新载入规则」「查看恢复步骤」；「软件与记录」保留操作记录与脱敏报告导出。')
            Impact='排查会读取入口和设置，并可能发送无账号凭据的固定站点请求；不会自动执行修复。修复可能启用检测通过的备用或撤销已确认失效的手动入口。系统已直连但用户代理变量仍指向停止的本地入口时，可仅清理已确认失效的变量，保留有效、未知变量和 NO_PROXY，不改系统入口、保存线路或规则。每次写入前重新核验，发现外部改动即停止并按归属回退。重连仅关闭仍满足预览归属条件的旧线路连接，由应用自行重连；可能中断当前请求，请先保存工作。不会结束应用。'
            State='观察到的入口、实际出口、TCP 建立、HTTPS 响应与账号登录要分别判断。「未运行」「运行中未观察到 TCP」「正在建立」「读取失败」各有含义；未知监听不能按已停止清理。NO_PROXY 的广泛绕过可能让部分客户端直连，不同客户端解释也可能不同；本工具只提示，不自动删除。已运行应用的环境不会随用户变量写入刷新，需保存工作后完整正常退出再从「按此线路打开」重开。短时请求、UDP / QUIC 和独立隧道可能不在快照中。修复后观察失败应刷新，不能据此把已提交的更改当作未发生。'
        }
        [pscustomobject]@{
            Key='launch'; Title='启动方式与桌面绑定'
            Tip='在流向内选中程序即可设置或解除桌面绑定。绑定完全自愿；解除保留线路，不撤回系统代理。'
            Purpose='选择以后如何打开已配置程序：仅在流向中打开、另建代理图标，或绑定原桌面入口。'
            Steps=@('1. 在「程序线路」选中程序，打开「更多设置 ▾ → 启动与桌面入口 → 启动方式与桌面绑定…」。无需先找到桌面图标。','2. 推荐选择「不绑定桌面」，以后在流向内点击「按此线路打开」。也可另建独立代理入口，保留原图标。','3. 只有希望原图标经过流向时，才选择「绑定原桌面入口」并保存。','4. 解除绑定：仍在流向中选中该程序，回同一「启动方式与桌面绑定…」选择「不绑定桌面」并保存。')
            Impact='桌面绑定完全自愿，线路选择和绑定分别设置。「不绑定桌面」会恢复仍归本工具的原入口，并移除本工具创建且未被修改的独立入口；保留外部修改、保存的线路和正在运行的程序。解除绑定应走「启动方式与桌面绑定…」，不是「撤回线路更改」，也不会撤回系统代理。普通入口的实际联网仍取决于应用和系统配置。'
            State='代理启动会先检查该程序入口与实际出口，新鲜健康检查和固定入口请求未通过时保留服务与配置并拒绝打开；其他程序的默认线路失败不应阻止可用专线。全部代理失效但存在明确直连网站例外时，提示仅这些例外可用，不能视为整体恢复。正在运行时先正常退出整组程序，避免旧地址缓存或重复启动。启动成功只表示打开了程序，实际线路和登录仍需观察。旧代理图标指向缺失或旧版工具时，在「更多设置 ▾ → 启动与桌面入口」选「修复旧代理启动入口…」。'
        }
        [pscustomobject]@{
            Key='recovery'; Title='停止、恢复与直连对照'
            Tip='日常切换用首页撤回；没有流向服务时，关闭流向不会停止第三方代理客户端。高级服务与直连对照另有恢复范围。'
            Purpose='日常模式在首页预览撤回刚才的切换。高级独立服务需按会话归属停止；直连对照需单独确认。不要把恢复历史备份当成通用修网。'
            Steps=@('1. 日常只想隐藏窗口：点击 X，默认留在系统托盘；双击托盘图标恢复窗口。','2. 真正结束：托盘右键「停止代理服务并退出」。也可取消「关闭窗口后驻留托盘」，使关闭按钮执行停止退出。','3. 先正常退出启动器和全部相关进程，再到「程序线路」选中程序，在「更多设置 ▾ → 连接检查与恢复」选择「干净环境启动（请先退出整组程序）…」。它只清理新程序环境中的代理变量。','4. 仍需直连登录对照时，在同一菜单明确选择并确认「直连登录对照（限时恢复）…」。最多五分钟；完成后到「检查与维护 → 维护与恢复」点击「结束对照并恢复」，也可等待到期恢复。')
            Impact='停止服务先恢复仍归当前会话的代理设置，再停止自有内核；其他软件后来改动会保留。如果外部设置仍指向流向主入口或程序入口，即使地址改成 localhost 或 IPv6 回环，也会拒绝停止并保留后台；先按提示在写入设置的软件中换线，再重试。失败时窗口及恢复记录保留，不能当作已退出。内核意外停止会有限重试，耗尽后尝试恢复设置。直连对照会临时关闭当前用户系统代理，影响其他遵循它的新连接，内核继续运行；须先确认范围。到期或结束时按归属核对恢复，未知或恢复失败会保留记录并提示处理。'
            State='「窗口已隐藏」与「服务已停止」不同。入口恢复后，已运行应用仍可能缓存旧地址，需保存工作后完整正常退出并重开。对照以真实进入大厅或仍报错判断，不能用端口连通代替登录；一次对照成功也不能确定唯一故障原因。'
        }
        [pscustomobject]@{
            Key='updates'; Title='检查更新与安装'
            Tip='官方文件差异不超过 50 MiB 可自动暂存；超过先确认。安装须明确操作，恢复或停止失败保留界面。'
            Purpose='检查官方稳定版并校验更新文件，下载暂存与安装分为两步。具备更新功能的完整程序包才能使用应用内更新。'
            Steps=@('1. 到「检查与维护 → 软件与记录」，点击「检查更新」；可设置「后台检查更新」开关。','2. 官方文件差异不超过 50 MiB 时可自动校验暂存。超过 50 MiB 会先显示传输大小，明确同意后才下载。检查或暂存期间可点击取消。','3. 显示「安装更新…」后，先保存任务，再点击并确认安装；暂存本身不会替换当前程序。','4. 旧版没有更新登记或更新入口时，先下载官方完整包，正常停止旧版后完整解压到新目录并打开；这是启用后续应用内更新的首次升级。运行组件或文件布局变化时也需要完整包。')
            Impact='安装前会正常恢复代理设置并停止流向服务，当前连接可能中断。恢复、停止或进程核验失败会保留界面，不强行结束进程；失败备份和事务记录保留在本机数据目录的 updates 中。安装后重新打开默认只读；已有专线时，到「代理入口 → 备用与服务 → 使用流向独立入口」启动并保留专线，所有程序跟随同一路线时才统一切换。关闭后台检查停止自动检查，可继续手动检查；不会把已经暂存的文件自动安装。'
            State='「已暂存」代表文件已准备，不代表安装完成。「窗口已就绪」也不代表代理服务或目标应用已恢复。出现安装未确认、恢复受阻或读取失败时保留 updates 目录和原包，按提示处理后再试；不要通过删除备份来消除提示。'
        }
    )
}

function Get-FlowHelpText([string]$Topic='start') {
    $entry=Get-FlowGuideTopics | Where-Object { $_.Key -eq $Topic } | Select-Object -First 1
    if(-not $entry){$entry=Get-FlowGuideTopics | Select-Object -First 1}
    return [string]$entry.Tip
}

function Show-FlowGuide([Windows.Forms.Form]$Owner,[string]$Topic='start') {
    $topics=@(Get-FlowGuideTopics)
    $dialog=New-Object Windows.Forms.Form
    $bodyFont=$null;$headingFont=$null;$titleFont=$null
    try {
        $dialog.Name='FlowGuide';$dialog.Text='流向 · 使用指南'
        $dialog.ClientSize=New-Object Drawing.Size(980,690)
        $dialog.MinimumSize=New-Object Drawing.Size(760,550)
        $dialog.AutoScaleMode='Dpi';$dialog.StartPosition='CenterParent'
        $dialog.FormBorderStyle='Sizable';$dialog.MinimizeBox=$false;$dialog.ShowInTaskbar=$false
        $dialog.BackColor=[Drawing.ColorTranslator]::FromHtml('#121C2B')
        $baseFont=New-Object Drawing.Font('Microsoft YaHei UI',10)
        try {
            if($Owner){$dialog.BackColor=$Owner.BackColor;$fontFamily=$Owner.Font.FontFamily;$fontSize=$Owner.Font.SizeInPoints;if($Owner.Icon){$dialog.Icon=$Owner.Icon}}
            else{$fontFamily=$baseFont.FontFamily;$fontSize=$baseFont.SizeInPoints;$dialog.StartPosition='CenterScreen'}
            $bodyFont=New-Object Drawing.Font($fontFamily,[single][Math]::Max(10,$fontSize),[Drawing.FontStyle]::Regular)
            $headingFont=New-Object Drawing.Font($fontFamily,$bodyFont.SizeInPoints,[Drawing.FontStyle]::Bold)
            $titleFont=New-Object Drawing.Font($fontFamily,[single]($bodyFont.SizeInPoints+4),[Drawing.FontStyle]::Bold)
        } finally {$baseFont.Dispose()}
        $dialog.Font=$bodyFont
        $dark=$dialog.BackColor.GetBrightness() -lt 0.5
        $textColor=$(if($dark){[Drawing.ColorTranslator]::FromHtml('#EBF3FC')}else{[Drawing.ColorTranslator]::FromHtml('#15283D')})
        if($Owner -and [Math]::Abs($Owner.ForeColor.GetBrightness()-$dialog.BackColor.GetBrightness()) -gt 0.35){$textColor=$Owner.ForeColor}
        $surface=$(if($dark){[Drawing.ColorTranslator]::FromHtml('#1B2A3D')}else{[Drawing.Color]::White})
        $accent=$(if($dark){[Drawing.ColorTranslator]::FromHtml('#9EDBFA')}else{[Drawing.ColorTranslator]::FromHtml('#155782')})
        $dialog.ForeColor=$textColor

        $layout=New-Object Windows.Forms.TableLayoutPanel
        $layout.Dock='Fill';$layout.Padding=New-Object Windows.Forms.Padding(18)
        $layout.ColumnCount=2;$layout.RowCount=2
        [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Absolute,195)))
        [void]$layout.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
        [void]$layout.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,52)))
        $dialog.Controls.Add($layout)

        $navigation=New-Object Windows.Forms.ListBox
        $navigation.Name='FlowGuideTopics';$navigation.Dock='Fill';$navigation.IntegralHeight=$false
        $navigation.BorderStyle='None';$navigation.BackColor=$surface;$navigation.ForeColor=$textColor
        $navigation.DisplayMember='Title';$navigation.AccessibleName='使用指南主题';$navigation.TabIndex=0
        $navigation.Margin=New-Object Windows.Forms.Padding(0,0,16,0)
        foreach($entry in $topics){[void]$navigation.Items.Add($entry)}
        $layout.Controls.Add($navigation,0,0)

        $reading=New-Object Windows.Forms.TableLayoutPanel
        $reading.Dock='Fill';$reading.ColumnCount=1;$reading.RowCount=2;$reading.Margin=New-Object Windows.Forms.Padding(0)
        [void]$reading.ColumnStyles.Add((New-Object Windows.Forms.ColumnStyle([Windows.Forms.SizeType]::Percent,100)))
        [void]$reading.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Absolute,50)))
        [void]$reading.RowStyles.Add((New-Object Windows.Forms.RowStyle([Windows.Forms.SizeType]::Percent,100)))
        $layout.Controls.Add($reading,1,0)
        $title=New-Object Windows.Forms.Label
        $title.Name='FlowGuideTitle';$title.Dock='Fill';$title.Font=$titleFont;$title.ForeColor=$accent;$title.TextAlign='MiddleLeft'
        $reading.Controls.Add($title,0,0)
        $reader=New-Object Windows.Forms.RichTextBox
        $reader.Name='FlowGuideReading';$reader.Dock='Fill';$reader.ReadOnly=$true;$reader.DetectUrls=$false
        $reader.BorderStyle='None';$reader.BackColor=$surface;$reader.ForeColor=$textColor;$reader.Font=$bodyFont
        $reader.WordWrap=$true;$reader.ScrollBars='Vertical';$reader.TabIndex=1;$reader.AccessibleName='用途、设置步骤、影响与撤回、状态如何判断'
        $reading.Controls.Add($reader,0,1)

        $footer=New-Object Windows.Forms.FlowLayoutPanel
        $footer.Dock='Fill';$footer.FlowDirection='RightToLeft';$footer.WrapContents=$false
        # Explicit margins keep button height + top padding inside the footer at every DPI.
        $footer.Margin=New-Object Windows.Forms.Padding(0)
        $footer.Padding=New-Object Windows.Forms.Padding(0,8,0,0)
        $layout.Controls.Add($footer,0,1);$layout.SetColumnSpan($footer,2)
        $close=New-Object Windows.Forms.Button
        $close.Name='FlowGuideClose';$close.Text='关闭指南';$close.Size=New-Object Drawing.Size(120,34)
        $close.Margin=New-Object Windows.Forms.Padding(0)
        $close.FlatStyle='Flat';$close.BackColor=$surface;$close.ForeColor=$textColor;$close.Cursor=[Windows.Forms.Cursors]::Hand
        $close.DialogResult='Cancel';$close.TabIndex=2;$footer.Controls.Add($close);$dialog.CancelButton=$close

        $render={
            $entry=$navigation.SelectedItem
            if(-not $entry){return}
            $title.Text=$entry.Title
            $sections=@(
                [pscustomobject]@{Heading='用途';Text=$entry.Purpose},
                [pscustomobject]@{Heading='设置步骤';Text=($entry.Steps -join "`n`n")},
                [pscustomobject]@{Heading='影响与撤回';Text=$entry.Impact},
                [pscustomobject]@{Heading='状态如何判断';Text=$entry.State}
            )
            $reader.Clear();$reader.SelectionFont=$bodyFont;$reader.SelectionColor=$textColor
            foreach($section in $sections){
                $reader.SelectionFont=$headingFont;$reader.SelectionColor=$accent
                $reader.AppendText($section.Heading+"`n")
                $reader.SelectionFont=$bodyFont;$reader.SelectionColor=$textColor
                $reader.AppendText($section.Text+"`n`n")
            }
            $reader.Select(0,0);$reader.ScrollToCaret()
        }.GetNewClosure()
        $navigation.Add_SelectedIndexChanged($render)
        $selected=0
        for($i=0;$i -lt $topics.Count;$i++){if($topics[$i].Key -eq $Topic){$selected=$i;break}}
        $navigation.SelectedIndex=$selected
        if($Owner){[void]$dialog.ShowDialog($Owner)}else{[void]$dialog.ShowDialog()}
    } finally {
        $dialog.Dispose()
        if($titleFont){$titleFont.Dispose()};if($headingFont){$headingFont.Dispose()};if($bodyFont){$bodyFont.Dispose()}
    }
}
