import AppKit
import FlowModel

enum FlowStyle {
    static let canvas = NSColor(srgbRed:16/255,green:25/255,blue:31/255,alpha:1)
    static let surface = NSColor(srgbRed:24/255,green:37/255,blue:44/255,alpha:1)
    static let accent = NSColor(srgbRed:112/255,green:221/255,blue:189/255,alpha:1)
    static let muted = NSColor(srgbRed:165/255,green:187/255,blue:185/255,alpha:1)
}

final class WorkspaceSurface: NSView {
    let color: NSColor
    init(_ color: NSColor = FlowStyle.surface) {
        self.color = color; super.init(frame:.zero)
        wantsLayer = true; layer?.cornerRadius = 14
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func draw(_ dirtyRect: NSRect) { color.setFill(); NSBezierPath(roundedRect:bounds,xRadius:14,yRadius:14).fill() }
}

extension AppDelegate {
    func vertical(_ views: [NSView], spacing: CGFloat = 12) -> NSStackView {
        let stack = NSStackView(views:views); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = spacing
        return stack
    }
    func pin(_ view: NSView, to parent: NSView, inset: CGFloat = 0) {
        view.translatesAutoresizingMaskIntoConstraints = false; parent.addSubview(view)
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo:parent.leadingAnchor,constant:inset),view.trailingAnchor.constraint(equalTo:parent.trailingAnchor,constant:-inset),view.topAnchor.constraint(equalTo:parent.topAnchor,constant:inset),view.bottomAnchor.constraint(equalTo:parent.bottomAnchor,constant:-inset)])
    }
    func note(_ text: String) -> NSTextField {
        let field = NSTextField(wrappingLabelWithString:text); field.font = .systemFont(ofSize:12); field.textColor = FlowStyle.muted
        return field
    }
    func card(_ heading: String, _ views: [NSView]) -> NSView {
        let title = label(heading,size:14); title.font = .systemFont(ofSize:14,weight:.semibold)
        let stack = vertical([title] + views); let surface = WorkspaceSurface(); pin(stack,to:surface,inset:16)
        for view in views { view.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        return surface
    }
    func field(_ title: String, _ control: NSControl, width: CGFloat? = nil) -> NSView {
        let stack = vertical([note(title),control],spacing:6)
        control.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        if let width = width { stack.widthAnchor.constraint(equalToConstant:width).isActive = true }
        control.setContentCompressionResistancePriority(.defaultLow,for:.horizontal)
        return stack
    }
    func page(_ cards: [NSView]) -> NSView {
        let spacer = NSView(); spacer.setContentHuggingPriority(.defaultLow,for:.vertical)
        let stack = vertical(cards + [spacer]); stack.translatesAutoresizingMaskIntoConstraints = false
        for card in cards { card.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true }
        return stack
    }
    func buildWorkspace() {
        func stage(_ text: String) { if CommandLine.arguments.contains("--ui-smoke") { fputs("UI build: \(text)\n",stderr) } }
        stage("sidebar")
        window.appearance = NSAppearance(named:.darkAqua)
        let container = window.contentView!
        let sidebar = WorkspaceSurface(NSColor(srgbRed:19/255,green:33/255,blue:40/255,alpha:1))
        sidebar.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(sidebar)
        NSLayoutConstraint.activate([sidebar.leadingAnchor.constraint(equalTo:container.leadingAnchor),sidebar.topAnchor.constraint(equalTo:container.topAnchor),sidebar.bottomAnchor.constraint(equalTo:container.bottomAnchor),sidebar.widthAnchor.constraint(equalToConstant:184)])
        let icon = NSImageView(image:NSImage(contentsOf:Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/FlowSwitch.icns")) ?? NSImage()); icon.imageScaling = .scaleProportionallyUpOrDown
        icon.widthAnchor.constraint(equalToConstant:68).isActive = true; icon.heightAnchor.constraint(equalToConstant:68).isActive = true
        let brand = label("流向",size:28); brand.font = .systemFont(ofSize:28,weight:.semibold)
        let wordmark = note("F L O W S W I T C H")
        let space = NSView(); space.heightAnchor.constraint(equalToConstant:30).isActive = true
        let navigation = vertical([icon,brand,wordmark,space,note("网络工作台")],spacing:12)
        for (index,entry) in [("线路管理","point.3.connected.trianglepath.dotted"),("分流规则","arrow.triangle.branch"),("网络诊断","waveform.path.ecg")].enumerated() {
            let b = button(entry.0,#selector(navigate)); b.tag = index; b.image = NSImage(systemSymbolName:entry.1,accessibilityDescription:nil)
            b.imagePosition = .imageLeading; b.alignment = .left; b.heightAnchor.constraint(equalToConstant:42).isActive = true
            navigation.addArrangedSubview(b); navigationButtons.append(b)
            b.widthAnchor.constraint(equalTo: navigation.widthAnchor).isActive = true
        }
        navigation.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(navigation)
        NSLayoutConstraint.activate([navigation.leadingAnchor.constraint(equalTo:sidebar.leadingAnchor,constant:18),navigation.trailingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:-18),navigation.topAnchor.constraint(equalTo:sidebar.topAnchor,constant:24)])
        let sideFooter = vertical([note("让每条连接各得其所。"),note("macOS · \(appVersion)"),button("使用说明",#selector(help))],spacing:8)
        sideFooter.translatesAutoresizingMaskIntoConstraints = false; sidebar.addSubview(sideFooter)
        NSLayoutConstraint.activate([sideFooter.leadingAnchor.constraint(equalTo:navigation.leadingAnchor),sideFooter.trailingAnchor.constraint(equalTo:navigation.trailingAnchor),sideFooter.bottomAnchor.constraint(equalTo:sidebar.bottomAnchor,constant:-24)])

        stage("connection control")
        pageTitle.font = .systemFont(ofSize:26,weight:.semibold)
        pageSubtitle.textColor = FlowStyle.muted; pageSubtitle.font = .systemFont(ofSize:12)
        title.font = .systemFont(ofSize:14,weight:.semibold); detail.font = .systemFont(ofSize:12); detail.textColor = FlowStyle.muted
        detail.maximumNumberOfLines = 3
        startButton = button("接入系统代理",#selector(start)); startButton.bezelColor = FlowStyle.accent; startButton.contentTintColor = FlowStyle.canvas
        stopButton = button("停止并恢复",#selector(stop)); switchButton = button("切换新连接",#selector(switchRoute))
        selected.widthAnchor.constraint(equalToConstant:185).isActive = true
        let controls = row([label("默认线路"),selected,switchButton,startButton,stopButton])
        let status = card("连接控制",[title,detail,controls])
        let hostView = NSView()
        let footer = note("关闭窗口后继续在菜单栏运行；停止服务会先恢复代理。")
        let content = vertical([vertical([pageTitle,pageSubtitle],spacing:6),status,hostView,footer],spacing:16)
        content.translatesAutoresizingMaskIntoConstraints = false; container.addSubview(content)
        NSLayoutConstraint.activate([content.leadingAnchor.constraint(equalTo:sidebar.trailingAnchor,constant:24),content.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-24),content.topAnchor.constraint(equalTo:container.topAnchor,constant:24),content.bottomAnchor.constraint(equalTo:container.bottomAnchor,constant:-18)])
        for view in content.arrangedSubviews { view.widthAnchor.constraint(equalTo:content.widthAnchor).isActive = true }
        hostView.setContentHuggingPriority(.defaultLow,for:.vertical)

        stage("pages")
        kind.addItems(withTitles:["HTTP","SOCKS5"]); ruleKind.addItems(withTitles:["域名及子域","精确域名","程序路径"])
        name.placeholderString = "如：日常线路"; host.placeholderString = "127.0.0.1"; port.placeholderString = "7897"
        ruleValue.placeholderString = "example.com 或程序可执行文件路径"
        editing += [name,host,port,ingress,kind,removeRoute,allowDirect,ruleKind,ruleRoute,ruleValue,removeRule]
        let routeFields = row([field("名称",name,width:150),field("协议",kind,width:90),field("服务器地址",host),field("端口",port,width:75)])
        let routeEditor = card("添加线路",[routeFields,row([note("使用已有的 HTTP / SOCKS5 代理入口。"),button("添加线路",#selector(addRoute),edit:true)])])
        removeRoute.widthAnchor.constraint(equalToConstant:220).isActive = true
        let routeList = card("已配置线路",[scroll(routeText,height:88),row([removeRoute,button("删除线路",#selector(deleteRoute),edit:true)]),note("自动备用按列表顺序选择，当前备用可用时不会自动跳回。")])
        ingress.widthAnchor.constraint(equalToConstant:80).isActive = true
        let prefs = card("接管偏好",[row([label("固定入口"),ingress,allowDirect]),row([note("修改线路或规则前，请先停止服务。"),button("保存设置",#selector(saveSettings),edit:true)])])
        let routePage = page([routeList,routeEditor,prefs])

        removeRule.widthAnchor.constraint(equalToConstant:280).isActive = true
        let ruleList = card("已保存规则",[scroll(ruleText,height:136),row([removeRule,button("删除规则",#selector(deleteRule),edit:true)])])
        let ruleFields = row([field("匹配方式",ruleKind,width:140),field("域名或程序路径",ruleValue),field("指定线路",ruleRoute,width:150)])
        let ruleEditor = card("添加分流规则",[ruleFields,row([button("选择程序…",#selector(chooseApp),edit:true),button("添加规则",#selector(addRule),edit:true)]),note("网站规则优先于程序规则。程序路径匹配依赖内核识别，仅影响进入流向的连接。")])
        let rulePage = page([ruleList,ruleEditor])
        repairButton = button("修复失效入口 / 恢复残留",#selector(repair))
        let diagnosticPage = page([card("排查与恢复",[note("先查看系统入口，再按提示修复。修复前会重新核验，并由你确认。"),row([button("排查网络",#selector(diagnose)),repairButton])]),card("检查结果",[scroll(diagnostics,height:240)])])
        pages = [routePage,rulePage,diagnosticPage]
        for p in pages { pin(p,to:hostView) }
        ingress.stringValue = String(settings.port); allowDirect.state = settings.allowDirect ? .on : .off
        diagnostics.string = "尚未开始检查。点击「排查网络」只读检查系统代理。\n\n当前为 macOS 试用版：未公证，没有 TUN。\n忽略系统代理的程序不会被自动接管。\n配置仅保存在本机，不导入第三方订阅或账号。"
        stage("initial selection")
        selectPage(0); poll()
        stage("ready")
    }
    @objc func navigate(_ sender: NSButton) { selectPage(sender.tag) }
    func selectPage(_ index: Int) {
        currentPage = index
        for (i,p) in pages.enumerated() { p.isHidden = i != index }
        for (i,b) in navigationButtons.enumerated() { b.bezelColor = i == index ? FlowStyle.accent.withAlphaComponent(0.22) : .clear; b.contentTintColor = i == index ? FlowStyle.accent : FlowStyle.muted; b.state = i == index ? .on : .off }
        pageTitle.stringValue = ["线路管理","分流规则","网络诊断"][index]
        pageSubtitle.stringValue = ["连接已有代理，为日常网络选择一个可靠入口。","让网站和程序，各自走合适的线路。","查看入口状态，找出断连原因，再进行修复。"][index]
        window.contentView?.needsLayout = true
    }
}
