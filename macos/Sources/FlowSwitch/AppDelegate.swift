import AppKit
import FlowModel

final class MainPanel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        NSBezierPath(rect:bounds).fill()
        super.draw(dirtyRect)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate {
    var window: NSWindow!
    var tray: NSStatusItem!
    var settings = Settings()
    var worker: Process?
    var timer: Timer?
    var quitting = false
    var busy = false
    let root = dataDirectory()
    let title = NSTextField(labelWithString:"未接入 · 打开流向不会修改网络")
    let detail = NSTextField(wrappingLabelWithString:"添加已有 HTTP / SOCKS5 入口，然后点击接入。流向不提供线路或订阅。")
    let name = NSTextField(), host = NSTextField(), port = NSTextField(), ingress = NSTextField()
    let kind = NSPopUpButton(), selected = NSPopUpButton(), ruleKind = NSPopUpButton(), ruleRoute = NSPopUpButton()
    let ruleValue = NSTextField(), removeRoute = NSPopUpButton(), removeRule = NSPopUpButton()
    let allowDirect = NSButton(checkboxWithTitle:"全部代理失效时允许直连（默认关闭）",target:nil,action:nil)
    let routeText = NSTextView(), ruleText = NSTextView(), diagnostics = NSTextView()
    var editing = [NSControl]()
    var startButton: NSButton!, stopButton: NSButton!, switchButton: NSButton!, repairButton: NSButton!

    func applicationDidFinishLaunching(_ notification: Notification) {
        do {
            try prepare(root)
            let path = root.appendingPathComponent("settings.json")
            if fm.fileExists(atPath:path.path) { settings = try loadJSON(Settings.self,path); try settings.validate() }
        } catch { detail.stringValue = "配置读取失败，未覆盖原文件：" + error.localizedDescription; busy = true }
        build(); refresh(); showWindow()
        timer = Timer.scheduledTimer(withTimeInterval:1.5,repeats:true) { [weak self] _ in self?.poll() }
        if CommandLine.arguments.contains("--ui-smoke") {
            DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                assert(self.window.isVisible && self.startButton != nil && self.selected.numberOfItems >= 1)
                if let index = CommandLine.arguments.firstIndex(of:"--screenshot"), index+1 < CommandLine.arguments.count,
                   let view = self.window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) {
                    view.cacheDisplay(in:view.bounds,to:rep)
                    try? rep.representation(using:.png,properties:[:])?.write(to:URL(fileURLWithPath:CommandLine.arguments[index+1]))
                }
                NSApp.terminate(nil)
            }
        }
    }
    func label(_ text: String, size: CGFloat = 13) -> NSTextField { let view = NSTextField(labelWithString:text); view.font = .systemFont(ofSize:size); return view }
    func button(_ text: String, _ action: Selector, edit: Bool = false) -> NSButton {
        let b = NSButton(title:text,target:self,action:action); b.bezelStyle = .rounded; if edit { editing.append(b) }; return b
    }
    func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views:views); stack.orientation = .horizontal; stack.spacing = 8; stack.alignment = .centerY; return stack
    }
    func scroll(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        text.isEditable = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        text.textContainerInset = NSSize(width:10,height:8); text.autoresizingMask = [.width]
        let view = NSScrollView(); view.documentView = text; view.hasVerticalScroller = true; view.borderType = .bezelBorder
        view.heightAnchor.constraint(equalToConstant:height).isActive = true
        return view
    }
    func build() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:980,height:810),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.contentView = MainPanel(frame:NSRect(x:0,y:0,width:980,height:810))
        window.title = "流向 FlowSwitch · macOS \(appVersion)"; window.delegate = self; window.minSize = NSSize(width:900,height:810); window.center()
        let menu = NSMenu(); let top = NSMenuItem(); menu.addItem(top)
        top.submenu = NSMenu(title:"FlowSwitch"); top.submenu?.addItem(withTitle:"停止服务并退出",action:#selector(quit),keyEquivalent:"q").target = self
        let editTop = NSMenuItem(); menu.addItem(editTop); editTop.submenu = NSMenu(title:"编辑")
        for (t,s,k) in [("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { editTop.submenu?.addItem(withTitle:t,action:s,keyEquivalent:k) }
        NSApp.mainMenu = menu
        tray = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength); tray.button?.title = "流向"
        let tm = NSMenu(); tm.addItem(withTitle:"打开流向",action:#selector(showWindow),keyEquivalent:"").target = self
        tm.addItem(withTitle:"停止服务并退出",action:#selector(quit),keyEquivalent:"").target = self; tray.menu = tm
        let stack = NSStackView(); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12; stack.translatesAutoresizingMaskIntoConstraints = false
        let container = window.contentView!; container.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo:container.leadingAnchor,constant:24),stack.trailingAnchor.constraint(equalTo:container.trailingAnchor,constant:-24),stack.topAnchor.constraint(equalTo:container.topAnchor,constant:20)])
        let brand = label("流向  /  FlowSwitch",size:26); brand.font = .systemFont(ofSize:26,weight:.semibold)
        stack.addArrangedSubview(brand); title.font = .systemFont(ofSize:15,weight:.semibold); stack.addArrangedSubview(title)
        detail.maximumNumberOfLines = 3; stack.addArrangedSubview(detail); detail.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        startButton = button("接入系统代理",#selector(start)); stopButton = button("停止并恢复",#selector(stop)); switchButton = button("切换新连接",#selector(switchRoute))
        stack.addArrangedSubview(row([label("默认线路"),selected,switchButton,startButton,stopButton]))
        stack.addArrangedSubview(label("线路 · 自动备用按列表顺序选择；有效备用不会自动跳回首选",size:14))
        for (field,placeholder,width) in [(name,"线路名称",140.0),(host,"127.0.0.1 或服务器地址",220.0),(port,"端口",70.0),(ingress,"18790",70.0)] {
            field.placeholderString = placeholder; field.widthAnchor.constraint(equalToConstant:width).isActive = true; editing.append(field)
        }
        kind.addItems(withTitles:["HTTP","SOCKS5"]); editing.append(kind)
        stack.addArrangedSubview(row([name,kind,host,port,button("添加线路",#selector(addRoute),edit:true)]))
        let rs = scroll(routeText,height:72); stack.addArrangedSubview(rs); rs.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        editing.append(removeRoute); editing.append(allowDirect); editing.append(ingress)
        stack.addArrangedSubview(row([removeRoute,button("删除线路",#selector(deleteRoute),edit:true),label("固定入口"),ingress,allowDirect]))
        stack.addArrangedSubview(label("分流规则 · 网站优先于程序；仅影响进入流向的流量",size:14))
        ruleKind.addItems(withTitles:["域名及子域","精确域名","程序路径"]); editing.append(ruleKind); editing.append(ruleRoute); editing.append(ruleValue); editing.append(removeRule)
        ruleValue.placeholderString = "example.com 或 /Applications/…/Contents/MacOS/…"; ruleValue.widthAnchor.constraint(equalToConstant:330).isActive = true
        stack.addArrangedSubview(row([ruleKind,ruleValue,button("选择程序",#selector(chooseApp),edit:true),ruleRoute,button("添加规则",#selector(addRule),edit:true)]))
        let rules = scroll(ruleText,height:83); stack.addArrangedSubview(rules); rules.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        stack.addArrangedSubview(row([removeRule,button("删除规则",#selector(deleteRule),edit:true),button("保存设置",#selector(saveSettings),edit:true)]))
        repairButton = button("修复失效入口 / 恢复残留",#selector(repair))
        stack.addArrangedSubview(row([button("排查网络",#selector(diagnose)),repairButton,button("打开使用说明",#selector(help))]))
        let ds = scroll(diagnostics,height:112); stack.addArrangedSubview(ds); ds.widthAnchor.constraint(equalTo:stack.widthAnchor).isActive = true
        stack.addArrangedSubview(label("关闭窗口继续在菜单栏运行；退出会先恢复代理。修改线路和规则前请停止服务。",size:12))
        selected.widthAnchor.constraint(equalToConstant:180).isActive = true
        removeRoute.widthAnchor.constraint(equalToConstant:150).isActive = true; removeRule.widthAnchor.constraint(equalToConstant:220).isActive = true
        ruleRoute.widthAnchor.constraint(equalToConstant:130).isActive = true
        ingress.stringValue = String(settings.port); allowDirect.state = settings.allowDirect ? .on : .off
        diagnostics.string = "测试版：未使用 Developer ID 公证。没有 TUN，不接管忽略系统代理的程序。\n程序路径匹配依赖内核在当前权限下识别进程；未识别时按默认线路处理。\n配置保存在 ~/Library/Application Support/FlowSwitch；不自动导入第三方订阅或账号。"
    }
    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if worker?.isRunning == true { quitting = true; stop(); showWindow(); return .terminateLater }
        return .terminateNow
    }
    func error(_ e: Error) { let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = e.localizedDescription; alert.runModal() }
    func routeName(_ id: String) -> String { id == "DIRECT" ? "直连" : settings.routes.first(where:{$0.id == id})?.name ?? "未知线路" }
    func routeID(_ popup: NSPopUpButton) -> String { popup.indexOfSelectedItem <= 0 ? "DIRECT" : settings.routes[popup.indexOfSelectedItem-1].id }
    func refresh() {
        for popup in [selected,ruleRoute] { popup.removeAllItems(); popup.addItems(withTitles:["直连"] + settings.routes.map(\.name)) }
        selected.selectItem(at:(["DIRECT"] + settings.routes.map(\.id)).firstIndex(of:settings.selected) ?? 0)
        removeRoute.removeAllItems(); removeRoute.addItems(withTitles:settings.routes.map(\.name))
        removeRule.removeAllItems(); removeRule.addItems(withTitles:settings.rules.map { $0.value })
        routeText.string = settings.routes.enumerated().map { "\($0.offset+1). \($0.element.name)    \($0.element.kind.uppercased())  \($0.element.host):\($0.element.port)" }.joined(separator:"\n")
        ruleText.string = settings.rules.map { "\($0.kind)  \($0.value)  →  \(routeName($0.route))" }.joined(separator:"\n")
    }
    func persist() throws {
        guard !busy else { throw FlowError("原配置无法读取；请先备份并检查配置文件。") }
        guard let value = Int(ingress.stringValue) else { throw FlowError("固定入口须为数字端口。") }
        settings.port = value; settings.allowDirect = allowDirect.state == .on; settings.selected = routeID(selected)
        try settings.validate(); try saveJSON(settings,root.appendingPathComponent("settings.json"))
    }
    @objc func saveSettings() { do { try persist(); detail.stringValue = "设置已保存在本机；尚未改变系统代理。" } catch { self.error(error) } }
    @objc func addRoute() {
        let previous = settings
        do {
            guard let number = Int(port.stringValue) else { throw FlowError("请填写有效的上游端口。") }
            settings.routes.append(Route(name:name.stringValue,host:host.stringValue.trimmingCharacters(in:.whitespaces),port:number,kind:kind.indexOfSelectedItem == 0 ? "http":"socks5"))
            try settings.validate(); try saveJSON(settings,root.appendingPathComponent("settings.json")); refresh()
            name.stringValue = ""; port.stringValue = ""
        } catch { settings = previous; self.error(error) }
    }
    @objc func deleteRoute() {
        guard removeRoute.indexOfSelectedItem >= 0 else { return }; let index = removeRoute.indexOfSelectedItem; let id = settings.routes[index].id
        guard !settings.rules.contains(where:{$0.route == id}), settings.selected != id else { error(FlowError("请先更改默认线路，并移除引用该线路的规则。")); return }
        let previous = settings
        do { settings.routes.remove(at:index); try saveJSON(settings,root.appendingPathComponent("settings.json")); refresh() } catch { settings = previous; self.error(error) }
    }
    @objc func chooseApp() {
        let panel = NSOpenPanel(); panel.canChooseFiles = true; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            ruleValue.stringValue = Bundle(url:url)?.executableURL?.path ?? url.path; ruleKind.selectItem(at:2)
        }
    }
    @objc func addRule() {
        let previous = settings
        do {
            let kind = ["DOMAIN-SUFFIX","DOMAIN","PROCESS-PATH"][ruleKind.indexOfSelectedItem]
            var value = ruleValue.stringValue.trimmingCharacters(in:.whitespaces); if kind != "PROCESS-PATH" { value = value.lowercased() }
            settings.rules.append(Rule(kind:kind,value:value,route:routeID(ruleRoute)))
            try settings.validate(); try saveJSON(settings,root.appendingPathComponent("settings.json")); refresh(); ruleValue.stringValue = ""
        } catch { settings = previous; self.error(error) }
    }
    @objc func deleteRule() {
        guard removeRule.indexOfSelectedItem >= 0 else { return }; let previous = settings
        do { settings.rules.remove(at:removeRule.indexOfSelectedItem); try saveJSON(settings,root.appendingPathComponent("settings.json")); refresh() } catch { settings = previous; self.error(error) }
    }
    func launch(_ mode: String) throws {
        guard worker?.isRunning != true else { throw FlowError("已有操作正在执行。") }
        try? fm.removeItem(at:root.appendingPathComponent("status.json"))
        try? fm.removeItem(at:root.appendingPathComponent("command.json"))
        let process = Process(); process.executableURL = Bundle.main.executableURL; process.arguments = [mode,root.path]
        process.standardOutput = FileHandle.nullDevice; process.standardError = FileHandle.nullDevice
        try process.run(); worker = process; poll()
    }
    @objc func start() {
        do { try persist(); try launch("--worker") } catch { self.error(error) }
    }
    @objc func stop() {
        do { try saveJSON(Command(action:"stop"),root.appendingPathComponent("command.json")); detail.stringValue = "正在请求恢复并停止，最迟需等待本轮健康检测结束。" } catch { self.error(error) }
    }
    @objc func switchRoute() {
        do { try saveJSON(Command(action:"switch",route:routeID(selected)),root.appendingPathComponent("command.json")); detail.stringValue = "正在核验新线路；失败会保留原出口。" } catch { self.error(error) }
    }
    @objc func repair() {
        let alert = NSAlert(); alert.messageText = "修复失效本地入口"; alert.informativeText = "将恢复仍属于流向的残留设置，并关闭确认拒绝连接的本机手动代理。远程代理、PAC 和未知状态保持不变；需要时 macOS 会请求授权。"; alert.addButton(withTitle:"检查并修复"); alert.addButton(withTitle:"取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        do { try launch("--repair") } catch { self.error(error) }
    }
    @objc func diagnose() {
        diagnostics.string = "正在只读检查系统入口…"
        DispatchQueue.global(qos:.utility).async {
            let result = (try? SystemProxy(self.root).summary()) ?? "系统设置读取失败，状态未知。"
            DispatchQueue.main.async { self.diagnostics.string = result }
        }
    }
    @objc func help() { NSWorkspace.shared.open(Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/README.md")) }
    func poll() {
        let active = worker?.isRunning == true
        for control in editing { control.isEnabled = !active && !busy }
        startButton.isEnabled = !active && !busy; repairButton.isEnabled = !active; stopButton.isEnabled = active
        switchButton.isEnabled = false
        if let status = try? loadJSON(WorkerStatus.self,root.appendingPathComponent("status.json")) {
            let fresh = Date().timeIntervalSince1970-status.updated < 30
            title.stringValue = active ? "\(status.phase == "running" ? "已接入" : "处理中") · 127.0.0.1:\(settings.port)" : "未接入"
            if active && status.phase == "conflict" { title.stringValue = "系统入口不一致 · 不代表应用仍经过流向" }
            if !fresh && active { title.stringValue = "后台状态暂未更新 · 不能确认网络是否正常" }
            detail.stringValue = status.message
            switchButton.isEnabled = active && fresh && status.phase == "running"
            if active && status.phase == "running" {
                routeText.string = settings.routes.enumerated().map { index,route in
                    let observed = status.observed[route.id] ?? "未知"
                    let target = observed.hasPrefix("UP-") ? routeName(String(observed.dropFirst(3))) : observed == "REJECT" ? "暂停（没有可用备用）" : observed == "DIRECT" ? "直连" : observed
                    return "\(index+1). \(route.name)  \(route.host):\(route.port)    当前出口：\(target)"
                }.joined(separator:"\n")
                title.stringValue += " · 当前 \(status.connections.map(String.init) ?? "未知") 条内核连接"
            }
            if status.phase == "restore-failed" && quitting { quitting = false; NSApp.reply(toApplicationShouldTerminate:false) }
        }
        if !active && worker != nil {
            worker = nil
            if let updated = try? loadJSON(Settings.self,root.appendingPathComponent("settings.json")) { settings = updated; refresh() }
            if quitting { quitting = false; NSApp.reply(toApplicationShouldTerminate:true) }
        }
    }
}
