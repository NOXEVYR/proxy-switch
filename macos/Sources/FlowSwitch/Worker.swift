import Foundation
import Darwin
import FlowModel

private var interrupted = false
final class Worker {
    let root: URL
    let parent: pid_t
    let proxy: SystemProxy
    var core: Process?
    var lockFD: Int32 = -1
    var controller: Controller!
    var states: [String:Failover] = [:]
    var settings = Settings()
    init(_ root: URL) { self.root = root; parent = getppid(); proxy = SystemProxy(root) }
    func report(_ phase: String, _ message: String) {
        var count: Int? = nil
        if let controller, let response = try? controller.call("GET", "/connections", timeout: 1) { count = (response["connections"] as? [Any])?.count }
        try? saveJSON(WorkerStatus(phase:phase,message:message,observed:states.mapValues(\.current),connections:count),root.appendingPathComponent("status.json"))
    }
    func launchCore() throws {
        guard confirmedClosed("127.0.0.1",settings.port), confirmedClosed("127.0.0.1",controller.port) else { throw FlowError("流向入口或控制端口已被占用 / 状态未知，未接管系统。") }
        let config = try settings.coreConfig(controllerPort:controller.port, secret:controller.secret, selections:states.mapValues(\.current))
        try save(try jsonData(config),root.appendingPathComponent("runtime.json"))
        let child = Process(); child.executableURL = URL(fileURLWithPath:corePath())
        child.arguments = ["-d",root.appendingPathComponent("core").path,"-f",root.appendingPathComponent("runtime.json").path]
        child.standardOutput = FileHandle.nullDevice; child.standardError = FileHandle.nullDevice
        try child.run(); core = child
        for _ in 0..<40 {
            guard child.isRunning else { throw FlowError("内核未能启动；请检查系统版本和内核权限。") }
            if (try? controller.call("GET","/version",timeout:1)) != nil && socketState("127.0.0.1",settings.port) == .open { return }
            Thread.sleep(forTimeInterval:0.1)
        }
        throw FlowError("内核启动核验超时。")
    }
    func stopCore() {
        if let core, core.isRunning { core.terminate(); core.waitUntilExit() }
    }
    func selectInitial() throws {
        let health = controller.health(settings.routes)
        for route in settings.routes {
            let candidate = settings.candidates(route.id).first { $0 == "DIRECT" || health[$0] == true } ?? "REJECT"
            try controller.select("FS-" + route.id,candidate); states[route.id] = Failover(candidate)
        }
        try controller.select("FS-Default",settings.target(settings.selected))
        guard proxyProbe(port:settings.port) else { throw FlowError("入口已启动，但实际 HTTPS 检测失败，系统代理尚未接入。请检查线路。") }
    }
    func tickHealth() throws {
        let health = controller.health(settings.routes)
        for route in settings.routes {
            var candidate = states[route.id] ?? Failover(settings.candidates(route.id)[0])
            let old = candidate.current
            let next = candidate.observe(candidates:settings.candidates(route.id),health:health)
            if old != next { try controller.select("FS-" + route.id,next) }
            states[route.id] = candidate
        }
    }
    func restoreAndStop() {
        // Keep the working core alive if restoring preferences is denied or contested.
        while true {
            do { try proxy.restore(); stopCore(); report("stopped","系统设置已恢复；外部改动保留。流向服务已停止。"); return }
            catch { report("restore-failed","恢复未完成，保留内核运行。请检查系统代理冲突 / 授权；将自动重试。") }
            Thread.sleep(forTimeInterval:5)
        }
    }
    func run(repair: Bool) -> Int32 {
        defer { if lockFD >= 0 { flock(lockFD,LOCK_UN); close(lockFD) } }
        do {
            try prepare(root)
            lockFD = open(root.appendingPathComponent("worker.lock").path,O_CREAT|O_RDWR,0o600)
            guard lockFD >= 0, flock(lockFD,LOCK_EX|LOCK_NB) == 0 else { return 2 }
            _ = fcntl(lockFD,F_SETFD,FD_CLOEXEC)
            signal(SIGTERM) { _ in interrupted = true }; signal(SIGINT) { _ in interrupted = true }; signal(SIGHUP) { _ in interrupted = true }
            if repair {
                report("repairing","正在检查残留会话和失效本地入口；需要时会请求系统授权。")
                let count = try proxy.repairDead()
                report("stopped","检查完成：恢复了残留会话（如有），处理 \(count) 个网络服务的失效本地入口。远程/PAC/未知设置保留。")
                return 0
            }
            settings = try loadJSON(Settings.self,root.appendingPathComponent("settings.json")); try settings.validate()
            guard !fm.fileExists(atPath:proxy.ledger.path) else { throw FlowError("检测到残留会话。请先点击“修复失效入口 / 恢复残留”。") }
            try prepare(root.appendingPathComponent("core"))
            controller = Controller(port:try freePort(),secret:UUID().uuidString + UUID().uuidString)
            try saveJSON(controller,root.appendingPathComponent("controller.json"))
            try? fm.removeItem(at:root.appendingPathComponent("command.json"))
            report("starting","正在验证内核、候选线路和实际 HTTPS 请求…")
            try launchCore(); try selectInitial()
            guard getppid() == parent, !interrupted else { throw FlowError("窗口已退出，取消接入。") }
            report("authorizing","线路检测通过。请允许 macOS 修改网络设置；取消则不接管。")
            try proxy.activate(port:settings.port)
            var lastCommand = "", lastHealth = Date.distantPast, restarts: [Date] = []
            var message = "已接入系统代理。新连接按规则分流；探测成功不代表账号登录成功。"
            while getppid() == parent && !interrupted {
                if let command = try? loadJSON(Command.self,root.appendingPathComponent("command.json")), command.id != lastCommand {
                    lastCommand = command.id
                    if command.action == "stop" { break }
                    if command.action == "switch", let route = command.route, route == "DIRECT" || settings.routes.contains(where: { $0.id == route }) {
                        let old = settings.selected, oldState = states[route]
                        do {
                            if route != "DIRECT" {
                                let health = controller.health(settings.routes)
                                guard health["UP-" + route] == true else { throw FlowError("所选线路检测失败，已保留当前出口。") }
                                try controller.select("FS-" + route,"UP-" + route); states[route] = Failover("UP-" + route)
                            }
                            try controller.select("FS-Default",settings.target(route))
                            guard proxyProbe(port:settings.port) else { throw FlowError("切换后的实际请求检测失败，已尝试回滚。") }
                            settings.selected = route; try saveJSON(settings,root.appendingPathComponent("settings.json"))
                            message = "已切换并通过 HTTPS 探测。既有连接可能仍使用旧线路；网站/程序例外保留。"
                        } catch {
                            settings.selected = old
                            do {
                                try controller.select("FS-Default",settings.target(old))
                                if let oldState { try controller.select("FS-" + route,oldState.current); states[route] = oldState }
                                message = error.localizedDescription
                            } catch { throw FlowError("切换回滚失败，将恢复系统设置并停止。") }
                        }
                    }
                }
                if core?.isRunning != true {
                    restarts = restarts.filter { Date().timeIntervalSince($0) < 300 }
                    guard restarts.count < 3 else { throw FlowError("内核恢复次数已耗尽，将恢复系统设置。") }
                    Thread.sleep(forTimeInterval:pow(2,Double(restarts.count))); restarts.append(Date())
                    try launchCore(); message = "自有内核已恢复；保留有效备用出口。"
                }
                if Date().timeIntervalSince(lastHealth) >= 8 {
                    try tickHealth(); lastHealth = Date()
                    if (try? proxy.isOwned()) != true { message = "系统入口发生变化 / 无法核验，未自动抢回。请停止后处理其他代理的守护或 TUN。" }
                }
                report("running",message); Thread.sleep(forTimeInterval:1)
            }
            report("stopping","先恢复系统设置，再停止自有内核…"); restoreAndStop(); return 0
        } catch {
            let message = error.localizedDescription
            if fm.fileExists(atPath:proxy.ledger.path) { restoreAndStop() } else { stopCore() }
            report("error",message); return 1
        }
    }
}
