import AppKit
import FlowModel

final class MainPanel: NSView {
    override func draw(_ dirtyRect: NSRect) {
        FlowStyle.canvas.setFill()
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
    let root = CommandLine.arguments.contains("--ui-smoke") ? FileManager.default.temporaryDirectory.appendingPathComponent("FlowSwitch-UI-" + UUID().uuidString) : dataDirectory()
    var pages = [NSView](), navigationButtons = [NSButton](), currentPage = 0
    let pageTitle = NSTextField(labelWithString:""), pageSubtitle = NSTextField(labelWithString:"")
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
        if CommandLine.arguments.contains("--ui-smoke") { fputs("UI: building workspace\n",stderr) }
        build(); refresh(); showWindow()
        if CommandLine.arguments.contains("--ui-smoke") { fputs("UI: window shown\n",stderr) }
        if !CommandLine.arguments.contains("--ui-smoke") { timer = Timer.scheduledTimer(withTimeInterval:1.5,repeats:true) { [weak self] _ in self?.poll() } }
        if CommandLine.arguments.contains("--ui-smoke") {
            DispatchQueue.main.asyncAfter(deadline:.now()+2) {
                do { try self.verifyWorkspace() } catch { fputs("UI verification failed: \(error.localizedDescription)\n",stderr); exit(1) }
                NSApp.terminate(nil)
            }
        }
    }
    func label(_ text: String, size: CGFloat = 13) -> NSTextField { let view = NSTextField(labelWithString:text); view.font = .systemFont(ofSize:size); return view }
    func button(_ text: String, _ action: Selector, edit: Bool = false) -> NSButton {
        let b = FlowActionButton(title:text,target:self,action:action); b.bezelStyle = .rounded; b.isBordered = false; if edit { editing.append(b) }; return b
    }
    func row(_ views: [NSView]) -> NSStackView {
        let stack = NSStackView(views:views); stack.orientation = .horizontal; stack.distribution = .fill; stack.spacing = 8; stack.alignment = .centerY
        for view in views { stack.setVisibilityPriority(.mustHold,for:view) }
        if views.contains(where: { $0 is NSButton }) {
            let spacer = NSView()
            spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1),for:.horizontal)
            spacer.setContentCompressionResistancePriority(NSLayoutConstraint.Priority(1),for:.horizontal)
            stack.addArrangedSubview(spacer)
            spacer.widthAnchor.constraint(greaterThanOrEqualToConstant:0).isActive = true
        }
        return stack
    }
    func scroll(_ text: NSTextView, height: CGFloat) -> NSScrollView {
        text.isEditable = false; text.isSelectable = true; text.font = .monospacedSystemFont(ofSize:12,weight:.regular)
        text.textContainerInset = NSSize(width:12,height:10); text.autoresizingMask = [.width]; text.backgroundColor = FlowStyle.canvas; text.textColor = .labelColor
        let view = NSScrollView(); view.documentView = text; view.hasVerticalScroller = true; view.borderType = .noBorder
        view.heightAnchor.constraint(equalToConstant:height).isActive = true
        return view
    }
    func build() {
        window = NSWindow(contentRect:NSRect(x:0,y:0,width:1140,height:900),styleMask:[.titled,.closable,.miniaturizable,.resizable],backing:.buffered,defer:false)
        window.contentView = MainPanel(frame:NSRect(x:0,y:0,width:1140,height:900))
        window.title = "流向 FlowSwitch · macOS \(appVersion)"; window.delegate = self; window.minSize = NSSize(width:1040,height:860); window.center()
        let menu = NSMenu(); let top = NSMenuItem(); menu.addItem(top)
        top.submenu = NSMenu(title:"FlowSwitch"); top.submenu?.addItem(withTitle:"停止服务并退出",action:#selector(quit),keyEquivalent:"q").target = self
        let editTop = NSMenuItem(); menu.addItem(editTop); editTop.submenu = NSMenu(title:"编辑")
        for (t,s,k) in [("复制",#selector(NSText.copy(_:)),"c"),("粘贴",#selector(NSText.paste(_:)),"v"),("全选",#selector(NSText.selectAll(_:)),"a")] { editTop.submenu?.addItem(withTitle:t,action:s,keyEquivalent:k) }
        NSApp.mainMenu = menu
        tray = NSStatusBar.system.statusItem(withLength:NSStatusItem.variableLength); tray.button?.title = "流向"; tray.button?.image = FlowStyle.menuIcon
        let tm = NSMenu(); tm.addItem(withTitle:"打开流向",action:#selector(showWindow),keyEquivalent:"").target = self
        tm.addItem(withTitle:"停止服务并退出",action:#selector(quit),keyEquivalent:"").target = self; tray.menu = tm
        buildWorkspace()
    }

    @objc func showWindow() { window.makeKeyAndOrderFront(nil); NSApp.activate(ignoringOtherApps:true) }
    func applicationShouldHandleReopen(_ sender: NSApplication,hasVisibleWindows flag: Bool) -> Bool { showWindow(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
    @objc func quit() { NSApp.terminate(nil) }
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if worker?.isRunning == true { quitting = true; stop(); showWindow(); return .terminateLater }
        return .terminateNow
    }
    func error(_ e: Error) {
        if CommandLine.arguments.contains("--ui-smoke") { fputs("UI action failed: \(e.localizedDescription)\n",stderr); exit(1) }
        let alert = NSAlert(); alert.messageText = "操作未完成"; alert.informativeText = e.localizedDescription; alert.runModal()
    }
    func routeName(_ id: String) -> String { id == "DIRECT" ? "直连" : settings.routes.first(where:{$0.id == id})?.name ?? "未知线路" }
    func routeID(_ popup: NSPopUpButton) -> String { popup.indexOfSelectedItem <= 0 ? "DIRECT" : settings.routes[popup.indexOfSelectedItem-1].id }
    func refresh() {
        for popup in [selected,ruleRoute] { popup.removeAllItems(); popup.addItems(withTitles:["直连"] + settings.routes.map(\.name)) }
        selected.selectItem(at:(["DIRECT"] + settings.routes.map(\.id)).firstIndex(of:settings.selected) ?? 0)
        removeRoute.removeAllItems(); removeRoute.addItems(withTitles:settings.routes.map(\.name))
        removeRule.removeAllItems(); removeRule.addItems(withTitles:settings.rules.map { $0.value })
        routeText.string = settings.routes.enumerated().map { "\($0.offset+1). \($0.element.name)    \($0.element.kind.uppercased())  \($0.element.host):\($0.element.port)" }.joined(separator:"\n")
        if settings.routes.isEmpty { routeText.string = "还没有线路。\n在下方添加已有代理，即可选择默认线路或设置备用。" }
        ruleText.string = settings.rules.map { "\($0.kind)  \($0.value)  →  \(routeName($0.route))" }.joined(separator:"\n")
        if settings.rules.isEmpty { ruleText.string = "暂未设置专用规则。\n进入流向的连接将按默认线路处理。" }
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
