import Foundation

public struct FlowError: LocalizedError {
    public let message: String
    public init(_ message: String) { self.message = message }
    public var errorDescription: String? { message }
}
public struct Route: Codable, Equatable {
    public var id: String
    public var name: String
    public var host: String
    public var port: Int
    public var kind: String
    public init(name: String, host: String, port: Int, kind: String, id: String = UUID().uuidString.lowercased()) {
        self.id = id; self.name = name; self.host = host; self.port = port; self.kind = kind
    }
}
public struct Rule: Codable, Equatable {
    public var kind: String
    public var value: String
    public var route: String
    public init(kind: String, value: String, route: String) { self.kind = kind; self.value = value; self.route = route }
}
public struct Settings: Codable, Equatable {
    public var routes: [Route] = []
    public var rules: [Rule] = []
    public var selected = "DIRECT"
    public var allowDirect = false
    public var port = 18790
    public init() {}
    public func validate() throws {
        guard (1024...65535).contains(port), routes.count <= 8, rules.count <= 128 else { throw FlowError("入口端口须为 1024–65535；最多 8 条线路、128 条规则。") }
        let ids = Set(routes.map(\.id))
        guard ids.count == routes.count, selected == "DIRECT" || ids.contains(selected) else { throw FlowError("线路标识重复或默认线路不存在。") }
        for r in routes {
            guard r.id.range(of: "^[a-zA-Z0-9-]{1,64}$", options: .regularExpression) != nil,
                  r.id != "DIRECT", !r.name.trimmingCharacters(in: .whitespaces).isEmpty, r.name.count <= 80,
                  ["http", "socks5"].contains(r.kind), (1...65535).contains(r.port),
                  r.host.range(of: "^[a-zA-Z0-9.:_-]{1,253}$", options: .regularExpression) != nil else { throw FlowError("线路格式无效。地址只填写主机名或 IP，不包含协议、路径或账号。") }
            if ["localhost", "127.0.0.1", "::1"].contains(r.host.lowercased()) && r.port == port { throw FlowError("上游不能指向流向自己的入口。") }
        }
        var seen = Set<String>()
        for r in rules {
            guard r.route == "DIRECT" || ids.contains(r.route), ["DOMAIN", "DOMAIN-SUFFIX", "PROCESS-PATH"].contains(r.kind),
                  !r.value.isEmpty, !r.value.contains(","), !r.value.contains("\n"), !r.value.contains("\r"),
                  seen.insert(r.kind + ":" + r.value).inserted else { throw FlowError("规则无效、重复或引用了已删除的线路。") }
            if r.kind == "PROCESS-PATH" {
                guard r.value.hasPrefix("/"), !r.value.contains("*"), !r.value.contains("?") else { throw FlowError("程序规则须为完整可执行文件路径。") }
            } else {
                guard r.value == r.value.lowercased(), r.value.count <= 253,
                      r.value.split(separator: ".", omittingEmptySubsequences: false).allSatisfy({ label in
                          label.range(of: "^[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$", options: .regularExpression) != nil
                      }) else { throw FlowError("网站规则填写小写域名，不包含 https://、端口或路径。") }
            }
        }
    }
    public func candidates(_ preferred: String) -> [String] {
        if preferred == "DIRECT" { return ["DIRECT"] }
        return ["UP-" + preferred] + routes.filter { $0.id != preferred }.map { "UP-" + $0.id } + (allowDirect ? ["DIRECT"] : []) + ["REJECT"]
    }
    public func coreConfig(controllerPort: Int, secret: String, selections: [String:String] = [:]) throws -> [String:Any] {
        try validate()
        let groups: [[String:Any]] = routes.map { route in
            let candidates = candidates(route.id)
            let current = selections[route.id] ?? candidates[0]
            return ["name":"FS-" + route.id, "type":"select", "proxies":candidates.contains(current) ? [current] + candidates.filter { $0 != current } : candidates]
        } + [["name":"FS-Default", "type":"select", "proxies":[target(selected)] + (["DIRECT"] + routes.map { "FS-" + $0.id }).filter { $0 != target(selected) }]]
        let ordered = rules.sorted { a, b in
            if (a.kind == "PROCESS-PATH") != (b.kind == "PROCESS-PATH") { return b.kind == "PROCESS-PATH" }
            if a.value.count != b.value.count { return a.value.count > b.value.count }
            if a.kind != b.kind { return a.kind == "DOMAIN" }
            return a.value < b.value
        }
        return ["mixed-port":port, "bind-address":"127.0.0.1", "allow-lan":false,
                "external-controller":"127.0.0.1:\(controllerPort)", "secret":secret,
                "mode":"rule", "ipv6":true, "log-level":"silent", "find-process-mode":"always",
                "profile":["store-selected":false], "dns":["enable":false], "tun":["enable":false],
                "proxies":routes.map { ["name":"UP-" + $0.id, "type":$0.kind, "server":$0.host, "port":$0.port] as [String:Any] },
                "proxy-groups":groups, "rules":ordered.map { "\($0.kind),\($0.value),\(target($0.route))" } + ["MATCH,FS-Default"]]
    }
    public func target(_ route: String) -> String { route == "DIRECT" ? "DIRECT" : "FS-" + route }
}

public struct Failover {
    public var current: String
    public var failures = 0
    public init(_ current: String) { self.current = current }
    public mutating func observe(candidates: [String], health: [String:Bool]) -> String {
        if current == "DIRECT" || health[current] == true { failures = 0; return current }
        if current != "REJECT" && health[current] == nil { failures = 0; return current }
        failures += 1
        if current != "REJECT" && failures < 3 { return current }
        // Unknown probes must not turn an existing usable route into a false outage.
        let next = candidates.first { $0 == "DIRECT" || health[$0] == true }
        if let next { current = next; failures = 0 }
        else if candidates.filter({ $0 != "REJECT" }).allSatisfy({ health[$0] == false }) { current = "REJECT"; failures = 0 }
        return current
    }
}

public enum ProxyPolicy {
    public static func managed(_ original: [String:Any], port: Int) -> [String:Any] {
        var result = original
        for prefix in ["HTTP", "HTTPS", "SOCKS"] { result[prefix + "Enable"] = 1; result[prefix + "Proxy"] = "127.0.0.1"; result[prefix + "Port"] = port }
        result["ProxyAutoConfigEnable"] = 0; result["ProxyAutoDiscoveryEnable"] = 0
        return result
    }
    public static func owns(_ current: [String:Any], expected: [String:Any]) -> Bool { NSDictionary(dictionary: current).isEqual(to: expected) }
    public static func removeDeadLoopback(_ original: [String:Any], isClosed: (String,Int)->Bool) -> [String:Any] {
        var result = original
        for prefix in ["HTTP", "HTTPS", "SOCKS"] {
            guard (original[prefix + "Enable"] as? NSNumber)?.boolValue == true,
                  let host = original[prefix + "Proxy"] as? String,
                  ["localhost", "127.0.0.1", "::1"].contains(host.lowercased()),
                  let port = original[prefix + "Port"] as? Int, (1...65535).contains(port), isClosed(host,port) else { continue }
            result[prefix + "Enable"] = 0
        }
        return result
    }
}
