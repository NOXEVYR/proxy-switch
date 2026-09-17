import Foundation
import SystemConfiguration
import Security
import FlowModel

final class SystemProxy {
    let directory: URL
    private let testPreferences: URL?
    var authorization: AuthorizationRef?
    init(_ directory: URL, testPreferences: URL? = nil) { self.directory = directory; self.testPreferences = testPreferences }
    deinit { if let authorization { AuthorizationFree(authorization, []) } }
    var ledger: URL { directory.appendingPathComponent("recovery.plist") }
    func authorize() throws {
        if testPreferences != nil { return }
        if authorization != nil { return }
        guard AuthorizationCreate(nil, nil, [], &authorization) == errAuthorizationSuccess, let authorization else { throw FlowError("无法创建系统授权。") }
        let status = "system.preferences.network".withCString { name -> OSStatus in
            var item = AuthorizationItem(name: name, valueLength: 0, value: nil, flags: 0)
            return withUnsafeMutablePointer(to: &item) { pointer in
                var rights = AuthorizationRights(count: 1, items: pointer)
                return AuthorizationCopyRights(authorization, &rights, nil, [.interactionAllowed, .extendRights, .preAuthorize], nil)
            }
        }
        guard status == errAuthorizationSuccess else { throw FlowError("未获得修改网络设置的授权；系统代理未接管。") }
    }
    func prefs() throws -> SCPreferences {
        guard let value = SCPreferencesCreateWithAuthorization(nil, "FlowSwitch" as CFString, testPreferences.map { $0.path as CFString }, authorization) else { throw FlowError("无法读取系统网络设置。") }; return value
    }
    func protocols(_ prefs: SCPreferences) -> [(String, SCNetworkProtocol)] {
        let services = SCNetworkServiceCopyAll(prefs) as? [SCNetworkService] ?? []
        return services.compactMap { service in
            guard SCNetworkServiceGetEnabled(service), let id = SCNetworkServiceGetServiceID(service), let proto = SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies), SCNetworkProtocolGetEnabled(proto) else { return nil }
            return (id as String,proto)
        }
    }
    func config(_ proto: SCNetworkProtocol) -> [String:Any] { SCNetworkProtocolGetConfiguration(proto) as? [String:Any] ?? [:] }
    func commit(_ prefs: SCPreferences) throws {
        guard SCPreferencesCommitChanges(prefs), SCPreferencesApplyChanges(prefs) else { throw FlowError("系统代理写入或应用失败；已保留恢复记录。") }
    }
    func activate(port: Int) throws {
        guard !fm.fileExists(atPath: ledger.path) else { throw FlowError("存在待恢复会话，请先恢复残留设置。") }
        try authorize()
        let prefs = try prefs()
        guard SCPreferencesLock(prefs,false) else { throw FlowError("网络设置正在被修改，请稍后再试。") }; defer { SCPreferencesUnlock(prefs) }
        let targets = protocols(prefs)
        guard !targets.isEmpty else { throw FlowError("未发现可管理的网络服务。") }
        var record: [String:Any] = [:]
        for (id,proto) in targets { let old = config(proto); record[id] = ["before":old, "owned":ProxyPolicy.managed(old,port:port)] }
        // Durable before the first write, including partial commit / process death.
        try save(PropertyListSerialization.data(fromPropertyList: record, format: .binary, options: 0), ledger)
        for (id,proto) in targets {
            let owned = (record[id] as! [String:Any])["owned"] as! [String:Any]
            guard SCNetworkProtocolSetConfiguration(proto,owned as CFDictionary) else { throw FlowError("系统拒绝写入代理；请恢复残留设置。") }
        }
        try commit(prefs)
        let fresh = try self.prefs()
        for (id,proto) in protocols(fresh) {
            if let row = record[id] as? [String:Any], let owned = row["owned"] as? [String:Any], !ProxyPolicy.owns(config(proto),expected:owned) { throw FlowError("系统入口核验失败，可能被其他代理改写。") }
        }
    }
    func restore() throws {
        guard fm.fileExists(atPath: ledger.path) else { return }
        let bytes = try Data(contentsOf: ledger)
        guard let records = try PropertyListSerialization.propertyList(from: bytes, format: nil) as? [String:[String:Any]] else { throw FlowError("恢复记录损坏，请在系统设置检查代理。") }
        try authorize(); let prefs = try prefs()
        guard SCPreferencesLock(prefs,false) else { throw FlowError("网络设置被占用；保留代理运行并等待恢复。") }; defer { SCPreferencesUnlock(prefs) }
        var expected: [String:[String:Any]] = [:]
        for (id,row) in records {
            guard let service = SCNetworkServiceCopy(prefs,id as CFString), let proto = SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies),
                  let before = row["before"] as? [String:Any], let owned = row["owned"] as? [String:Any] else { continue }
            let current = config(proto)
            guard ProxyPolicy.owns(current,expected:owned) else {
                let stillUsesUs = ["HTTP","HTTPS","SOCKS"].contains { prefix in
                    let enabled = (current[prefix + "Enable"] as? NSNumber)?.boolValue == true
                    let hostMatches = (current[prefix + "Proxy"] as? String) == "127.0.0.1"
                    let portMatches = (current[prefix + "Port"] as? Int) == (owned[prefix + "Port"] as? Int)
                    return enabled && hostMatches && portMatches
                }
                if stillUsesUs { throw FlowError("外部修改与流向入口混合，保留内核运行。请在系统代理设置移除流向入口后重试。") }
                continue
            }
            let safe = ProxyPolicy.removeDeadLoopback(before,isClosed:confirmedClosed)
            guard SCNetworkProtocolSetConfiguration(proto,safe as CFDictionary) else { throw FlowError("恢复写入失败。") }; expected[id] = safe
        }
        try commit(prefs)
        let fresh = try self.prefs()
        for (id,wanted) in expected {
            if let service = SCNetworkServiceCopy(fresh,id as CFString), let proto = SCNetworkServiceCopyProtocol(service,kSCNetworkProtocolTypeProxies), !ProxyPolicy.owns(config(proto),expected:wanted) { throw FlowError("恢复核验失败，已保留记录。") }
        }
        try fm.removeItem(at:ledger)
    }
    func isOwned() throws -> Bool {
        let records = try PropertyListSerialization.propertyList(from: Data(contentsOf: ledger), format: nil) as? [String:[String:Any]] ?? [:]
        let fresh = try prefs()
        return protocols(fresh).allSatisfy { id,proto in
            guard let owned = records[id]?["owned"] as? [String:Any] else { return false }
            return ProxyPolicy.owns(config(proto),expected:owned)
        }
    }
    func repairDead() throws -> Int {
        try restore()
        let first = try prefs(); var plans: [String:([String:Any],[String:Any])] = [:]
        for (id,proto) in protocols(first) {
            let old = config(proto), fixed = ProxyPolicy.removeDeadLoopback(config(proto),isClosed:confirmedClosed)
            if !ProxyPolicy.owns(old,expected:fixed) { plans[id] = (old,fixed) }
        }
        if plans.isEmpty { return 0 }
        try authorize(); let latest = try prefs()
        guard SCPreferencesLock(latest,false) else { throw FlowError("系统代理正在变化，请重新诊断。") }; defer { SCPreferencesUnlock(latest) }
        var count = 0
        for (id,proto) in protocols(latest) {
            guard let (old,_) = plans[id] else { continue }
            guard ProxyPolicy.owns(config(proto),expected:old) else { throw FlowError("诊断后系统代理已经改变，未覆盖新设置。") }
            let checked = ProxyPolicy.removeDeadLoopback(old,isClosed:confirmedClosed)
            if !ProxyPolicy.owns(old,expected:checked) {
                guard SCNetworkProtocolSetConfiguration(proto,checked as CFDictionary) else { throw FlowError("修复写入失败。") }; count += 1
            }
        }
        try commit(latest); return count
    }
    func summary() throws -> String {
        let prefs = try prefs(); var lines = [String]()
        for (id,proto) in protocols(prefs) {
            let service = SCNetworkServiceCopy(prefs,id as CFString)
            let name = service.flatMap { SCNetworkServiceGetName($0) as String? } ?? "网络服务"
            let value = config(proto)
            let proxies = ["HTTP","HTTPS","SOCKS"].map { prefix -> String in
                if (value[prefix + "Enable"] as? NSNumber)?.boolValue != true { return prefix + " 关闭" }
                let host = value[prefix + "Proxy"] as? String ?? "未知", port = value[prefix + "Port"] as? Int ?? 0
                let local = ["127.0.0.1","localhost","::1"].contains(host.lowercased())
                let state = local ? socketState(host,port) : .unknown
                return "\(prefix) \(host):\(port)（\(state == .closed ? "入口拒绝连接" : state == .open ? "端口有监听，未证明目标可用" : "未探测/未知")）"
            }
            lines.append(name + "\n" + proxies.joined(separator:" · "))
        }
        return lines.joined(separator:"\n\n") + "\n\n诊断不更改设置。PAC、远程代理、TUN 和应用缓存需要分别检查。"
    }
}
