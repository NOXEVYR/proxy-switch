import Foundation
import FlowModel
import Network
import Darwin

let appVersion = "0.1.0-preview.3"
let healthURL = "https://www.gstatic.com/generate_204"
let healthURLs = [healthURL,"https://www.msftconnecttest.com/connecttest.txt"]
let fm = FileManager.default
func dataDirectory() -> URL {
    fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("FlowSwitch", isDirectory: true)
}
func prepare(_ directory: URL) throws {
    try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions:0o700])
    try fm.setAttributes([.posixPermissions:0o700], ofItemAtPath: directory.path)
}
func save(_ data: Data, _ path: URL) throws { try data.write(to: path, options: .atomic); try fm.setAttributes([.posixPermissions:0o600], ofItemAtPath: path.path) }
func saveJSON<T: Encodable>(_ value: T, _ path: URL) throws { try save(JSONEncoder().encode(value), path) }
func loadJSON<T: Decodable>(_ type: T.Type, _ path: URL) throws -> T { try JSONDecoder().decode(type, from: Data(contentsOf: path)) }
func corePath() -> String { Bundle.main.bundleURL.appendingPathComponent("Contents/Resources/mihomo").path }
func jsonData(_ object: Any) throws -> Data { try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) }

enum SocketState { case open, closed, unknown }
func socketState(_ host: String, _ port: Int) -> SocketState {
    guard let p = NWEndpoint.Port(rawValue: UInt16(clamping: port)) else { return .unknown }
    let done = DispatchSemaphore(value: 0)
    let connection = NWConnection(host: NWEndpoint.Host(host), port: p, using: .tcp)
    var result: SocketState = .unknown
    let lock = NSLock(); var finished = false
    connection.stateUpdateHandler = { state in
        lock.lock(); defer { lock.unlock() }
        if finished { return }
        switch state {
        case .ready: result = .open
        case .failed(let e), .waiting(let e):
            if case .posix(let code) = e, code == .ECONNREFUSED { result = .closed } else { result = .unknown }
        default: return
        }
        finished = true; done.signal()
    }
    connection.start(queue: DispatchQueue.global(qos: .utility))
    _ = done.wait(timeout: .now() + 1)
    lock.lock(); finished = true; let answer = result; lock.unlock(); connection.cancel()
    return answer
}
func confirmedClosed(_ host: String, _ port: Int) -> Bool {
    // localhost can resolve to more than one address; never infer that both are closed from one.
    let hosts = host.lowercased() == "localhost" ? ["127.0.0.1", "::1"] : [host]
    return hosts.allSatisfy { socketState($0,port) == .closed && socketState($0,port) == .closed }
}
func freePort() throws -> Int {
    let fd = socket(AF_INET, SOCK_STREAM, 0); guard fd >= 0 else { throw FlowError("无法申请控制端口。") }
    defer { close(fd) }
    var addr = sockaddr_in(); addr.sin_family = sa_family_t(AF_INET); addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size); addr.sin_addr.s_addr = inet_addr("127.0.0.1")
    let result = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd,$0,socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    guard result == 0 else { throw FlowError("无法绑定控制端口。") }
    var length = socklen_t(MemoryLayout<sockaddr_in>.size)
    _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd,$0,&length) } }
    return Int(UInt16(bigEndian: addr.sin_port))
}
struct Controller: Codable {
    let port: Int
    let secret: String
    func call(_ method: String, _ path: String, _ body: [String:Any]? = nil, timeout: Double = 6) throws -> [String:Any] {
        let config = URLSessionConfiguration.ephemeral
        config.connectionProxyDictionary = [:]; config.timeoutIntervalForRequest = timeout; config.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: config); defer { session.invalidateAndCancel() }
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)" + path)!)
        request.httpMethod = method; request.setValue("Bearer " + secret, forHTTPHeaderField: "Authorization")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        if let body { request.httpBody = try jsonData(body) }
        let done = DispatchSemaphore(value: 0); let lock = NSLock()
        var answer: [String:Any]?; var failure: Error?
        session.dataTask(with: request) { data, response, error in
            lock.lock(); defer { lock.unlock(); done.signal() }
            if let error { failure = error; return }
            guard let response = response as? HTTPURLResponse, (200..<300).contains(response.statusCode) else { failure = FlowError("内核接口未完成请求。"); return }
            guard let data, data.count <= 8_000_000 else { failure = FlowError("内核返回异常。"); return }
            if data.isEmpty { answer = [:] } else { answer = (try? JSONSerialization.jsonObject(with: data)) as? [String:Any] }
        }.resume()
        _ = done.wait(timeout: .now() + timeout + 1)
        lock.lock(); defer { lock.unlock() }
        if let failure { throw failure }
        guard let answer else { throw FlowError("内核响应超时或格式错误。") }; return answer
    }
    func select(_ group: String, _ value: String) throws {
        _ = try call("PUT", "/proxies/" + group, ["name":value])
        guard (try call("GET", "/proxies/" + group))["now"] as? String == value else { throw FlowError("出口切换核验失败。") }
    }
    func health(_ routes: [Route], urls: [String] = healthURLs) -> [String:Bool] {
        let jobs = DispatchGroup(), lock = NSLock(); var results = [String:Bool]()
        for route in routes {
            jobs.enter()
            DispatchQueue.global(qos: .utility).async {
                defer { jobs.leave() }
                var result: Bool? = false
                for url in urls {
                    let encoded = url.addingPercentEncoding(withAllowedCharacters: .alphanumerics)!
                    do {
                        if try self.call("GET", "/proxies/UP-\(route.id)/delay?timeout=3000&url=\(encoded)", timeout: 4)["delay"] != nil { result = true; break }
                    } catch {
                        if (try? self.call("GET", "/version", timeout: 1)) == nil { result = nil; break }
                    }
                }
                lock.lock(); results["UP-" + route.id] = result; lock.unlock()
            }
        }
        jobs.wait(); return results
    }
}
struct WorkerStatus: Codable {
    var phase: String
    var message: String
    var updated = Date().timeIntervalSince1970
    var observed: [String:String] = [:]
    var connections: Int? = nil
}
struct Command: Codable { var id = UUID().uuidString; var action: String; var route: String? = nil }
func proxyProbe(port: Int) -> Bool { healthURLs.contains { proxyProbeOnce(port:port,url:$0) } }
func proxyProbeOnce(port: Int, url: String) -> Bool {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
    p.arguments = ["--silent", "--output", "/dev/null", "--write-out", "%{http_code}", "--connect-timeout", "3", "--max-time", "6", "--noproxy", "", "--proxy", "http://127.0.0.1:\(port)", url]
    let output = Pipe(); p.standardOutput = output; p.standardError = FileHandle.nullDevice
    do { try p.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        return p.terminationStatus == 0 && ["200","204"].contains(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "")
    } catch { return false }
}
