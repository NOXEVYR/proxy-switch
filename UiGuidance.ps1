# Read-only guidance. This module owns only its dialog and never changes routing or launch settings.
Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing

function Get-FlowGuideTopics {
    @(
        [pscustomobject]@{
            Key='start'; Title='开始使用'
            Tip='管理已有代理，按需为程序和网站选线路。打开、刷新与自动发现不会切换网络。'
            Purpose='流向管理你已有的 HTTP / SOCKS5 代理，为默认请求、指定程序和网站分别选择出口。它不提供代理节点或 VPN 服务。'
            Steps=@('1. 完整解压程序包，双击 FlowSwitch.exe，保留旁边的 app 文件夹。','2. 启动自己的代理客户端；到「代理入口」点击「发现后台代理」或「添加代理入口…」。','3. 关闭上游客户端的 TUN 和持续代理守卫，保留代理服务运行。普通系统代理开关可能在客户端启动或退出时改写入口，建议也将其关闭。','4. 在「网络切换」选线路，点击「统一切换」，等待入口就绪。需要程序专用线路时，到「程序线路」设置；连接不通时到「检查与维护」检查。')
            Impact='普通打开、刷新、自动发现只读取状态或补充入口列表，不会重新应用历史线路。明确切换后才改变网络设置；关闭主窗口默认收至托盘，服务继续运行。需要停止时使用托盘「停止代理服务并退出」。'
            State='先看入口是否就绪，再看实际出口。随后在目标应用发起一次真实请求。规则已保存、端口可连接或网页首页打开，都不能证明账号登录和对话发送成功。'
        }
        [pscustomobject]@{
            Key='switch'; Title='统一切换与撤回'
            Tip='设置默认线路，并将程序专用线路改为跟随；网站例外保留。主要影响接入流向的新请求。'
            Purpose='为遵循系统代理、代理环境变量或已接入流向的请求设置默认出口。选择「直连」时，请求仍可能经过流向本地入口后再直连。'
            Steps=@('1. 打开「网络切换」，选择「直连」或已添加的代理。选择下拉项本身不会应用。','2. 点击「统一切换」，等待操作结果和入口状态。','3. 如需恢复本次切换前的设置，在同页点击「撤回线路更改」，查看恢复结果。')
            Impact='统一切换会取消程序专用线路，将其改为「跟随统一线路」，保留程序固定入口和网站例外。因此统一直连后，显式指定代理的网站仍可走代理。撤回使用切换前备份，并保留其他软件后来修改的设置。已有长连接、应用缓存的旧地址及独立隧道不会被强行改写。'
            State='区分「已选择待应用」和操作完成后的实际出口；入口未就绪、状态未知或刷新失败时，先查诊断。目标应用仍指向旧端口时，保存工作后完整正常退出应用及相关启动器，再重新打开。'
        }
        [pscustomobject]@{
            Key='programs'; Title='程序专用线路'
            Tip='为选中程序设直连、代理或跟随。首次接入可能需完整重开；选线不会自动绑定桌面图标。'
            Purpose='让已接入流向的程序使用自己的线路，例如浏览器跟随默认线路，而 IDE 使用另一条代理。'
            Steps=@('1. 在「程序线路」搜索并选中程序；也可点击「添加程序…」选择 EXE / 快捷方式，或拖入一个文件。','2. 点击底部「设置此程序线路 ▾」，指定「直连」、某个代理或「跟随统一线路」。右键菜单的「更改此程序线路」也可设置。','3. 若提示等待重开，先保存工作并完整正常退出程序、启动器及相关托盘进程，再点击「按此线路打开」。','4. 程序升级后提示路径变更时，在「更多设置 ▾」用「修复程序路径记录…」核对旧、新路径；候选不明确时重新添加。')
            Impact='支持的 Chromium / Electron 程序通过稳定本地入口启动，继承此入口的联网子进程可一起改出口。其他程序的按 EXE 规则仅控制经过流向的流量；自带隧道、独立服务或忽略代理的程序不保证覆盖。选线不修改桌面入口；改回「跟随统一线路」取消专用选择。移除设置若遇到活跃或未知入口，应先正常退出相关程序。'
            State='「已保存」「已加载」「等待重开」和「已观察到实际线路」代表不同阶段。双击程序，或到「更多设置 ▾ → 记录与详情 → 程序与连接详情…」查看证据。未观察到连接不等于断网；父程序一条成功连接也不能证明全部子进程都使用目标线路。'
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
            Key='diagnostics'; Title='网络诊断与旧连接'
            Tip='先只读排查，再确认具体修复。未观察到连接不等于断网，TCP / HTTPS 成功不等于登录成功。'
            Purpose='区分入口未就绪、默认出口暂停、系统设置冲突、程序仍用旧地址和目标站点响应等问题。'
            Steps=@('1. 到「检查与维护 → 连接检查」，点击「开始网络检查」，先阅读结果。','2. 仅在存在可处理项目时点击同组「查看并修复…」，核对影响后确认。修复前会重新核验状态。','3. 同组可在下拉框选择入口后「检测此入口」，或运行「Google 登录诊断」。再回目标应用验证登录及实际请求。','4. 旧连接需要更新时，在「程序线路」选中程序，打开「更多设置 ▾ → 连接检查与恢复 → 重连此程序的旧线路连接…」，核对预览数量后确认。','5. 「检查与维护 → 维护与恢复」提供「重新载入规则」「查看恢复步骤」；「软件与记录」提供「导出诊断报告…」。')
            Impact='排查会读取入口和设置，并可能发送无账号凭据的固定站点请求；不会自动执行修复。修复可能启用检测通过的备用或撤销已确认失效的手动入口，影响系统代理和相关变量，保留程序专线、网站例外及外部后续修改。重连仅关闭仍满足预览归属条件的旧线路连接，由应用自行重连；可能中断当前请求，请先保存工作。不会结束应用。'
            State='观察到的入口、实际出口、TCP 建立、HTTPS 响应与账号登录要分别判断。「未运行」「运行中未观察到 TCP」「正在建立」「读取失败」各有含义；短时请求、UDP / QUIC 和独立隧道可能不在快照中。修复后观察失败应刷新，不能据此把已提交的更改当作未发生。'
        }
        [pscustomobject]@{
            Key='launch'; Title='启动方式与桌面绑定'
            Tip='在流向内选中程序即可设置或解除桌面绑定。绑定完全自愿；解除保留线路，不撤回系统代理。'
            Purpose='选择以后如何打开已配置程序：仅在流向中打开、另建代理图标，或绑定原桌面入口。'
            Steps=@('1. 在「程序线路」选中程序，打开「更多设置 ▾ → 启动与桌面入口 → 启动方式与桌面绑定…」。无需先找到桌面图标。','2. 推荐选择「不绑定桌面」，以后在流向内点击「按此线路打开」。也可另建独立代理入口，保留原图标。','3. 只有希望原图标经过流向时，才选择「绑定原桌面入口」并保存。','4. 解除绑定：仍在流向中选中该程序，回同一「启动方式与桌面绑定…」选择「不绑定桌面」并保存。')
            Impact='桌面绑定完全自愿，线路选择和绑定分别设置。「不绑定桌面」会恢复仍归本工具的原入口，并移除本工具创建且未被修改的独立入口；保留外部修改、保存的线路和正在运行的程序。解除绑定应走「启动方式与桌面绑定…」，不是「撤回线路更改」，也不会撤回系统代理。普通入口的实际联网仍取决于应用和系统配置。'
            State='代理启动会先检查必要服务，入口未就绪不启动。正在运行时先正常退出整组程序，避免旧地址缓存或重复启动。启动成功只表示打开了程序，实际线路和登录仍需观察。旧代理图标指向缺失或旧版工具时，在「更多设置 ▾ → 启动与桌面入口」选「修复旧代理启动入口…」。'
        }
        [pscustomobject]@{
            Key='recovery'; Title='停止、恢复与直连对照'
            Tip='关窗口默认留托盘；停止服务会恢复会话设置。直连对照需确认，会临时影响用户系统代理，最多五分钟。'
            Purpose='安全结束流向服务、处理入口异常，或在游戏登录排查中进行一次有时限的直连对照。'
            Steps=@('1. 日常只想隐藏窗口：点击 X，默认留在系统托盘；双击托盘图标恢复窗口。','2. 真正结束：托盘右键「停止代理服务并退出」。也可取消「关闭窗口后驻留托盘」，使关闭按钮执行停止退出。','3. 先正常退出启动器和全部相关进程，再到「程序线路」选中程序，在「更多设置 ▾ → 连接检查与恢复」选择「干净环境启动（请先退出整组程序）…」。它只清理新程序环境中的代理变量。','4. 仍需直连登录对照时，在同一菜单明确选择并确认「直连登录对照（限时恢复）…」。最多五分钟；完成后到「检查与维护 → 维护与恢复」点击「结束对照并恢复」，也可等待到期恢复。')
            Impact='停止服务先恢复仍归当前会话的代理设置，再停止自有内核；其他软件后来改动会保留。失败时窗口及恢复记录保留，不能当作已退出。内核意外停止会有限重试，耗尽后尝试恢复设置。直连对照会临时关闭当前用户系统代理，影响其他遵循它的新连接，内核继续运行；须先确认范围。到期或结束时按归属核对恢复，未知或恢复失败会保留记录并提示处理。'
            State='「窗口已隐藏」与「服务已停止」不同。入口恢复后，已运行应用仍可能缓存旧地址，需保存工作后完整正常退出并重开。对照以真实进入大厅或仍报错判断，不能用端口连通代替登录；一次对照成功也不能确定唯一故障原因。'
        }
        [pscustomobject]@{
            Key='updates'; Title='检查更新与安装'
            Tip='官方文件差异不超过 50 MiB 可自动暂存；超过先确认。安装须明确操作，恢复或停止失败保留界面。'
            Purpose='检查官方稳定版并校验更新文件，下载暂存与安装分为两步。具备更新功能的完整程序包才能使用应用内更新。'
            Steps=@('1. 到「检查与维护 → 软件与记录」，点击「检查更新」；可设置「后台检查更新」开关。','2. 官方文件差异不超过 50 MiB 时可自动校验暂存。超过 50 MiB 会先显示传输大小，明确同意后才下载。检查或暂存期间可点击取消。','3. 显示「安装更新…」后，先保存任务，再点击并确认安装；暂存本身不会替换当前程序。','4. 旧版没有更新登记或更新入口时，先下载官方完整包，正常停止旧版后完整解压到新目录并打开；这是启用后续应用内更新的首次升级。运行组件或文件布局变化时也需要完整包。')
            Impact='安装前会正常恢复代理设置并停止流向服务，当前连接可能中断。恢复、停止或进程核验失败会保留界面，不强行结束进程；失败备份和事务记录保留在本机数据目录的 updates 中。安装后重新打开默认只读，需要时再明确统一切换。关闭后台检查停止自动检查，可继续手动检查；不会把已经暂存的文件自动安装。'
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
