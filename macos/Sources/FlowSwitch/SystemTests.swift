import Foundation
import SystemConfiguration
import FlowModel

// Uses the actual SystemConfiguration API on a separate preferences file. Never opens
// default system preferences, obtains authorization, or changes the machine's network.
func systemSelfTest() throws {
    let dir = fm.temporaryDirectory.appendingPathComponent("FlowSwitch-preferences-" + UUID().uuidString)
    try prepare(dir); defer { try? fm.removeItem(at:dir) }
    let proxy = SystemProxy(dir,testPreferences:dir.appendingPathComponent("test.plist"))
    let dead = try freePort()
    let old: [String:Any] = ["HTTPEnable":1,"HTTPProxy":"127.0.0.1","HTTPPort":dead,"ProxyAutoConfigEnable":1,"ProxyAutoConfigURLString":"https://example.invalid/proxy.pac","ExceptionsList":["localhost","*.internal"]]
    func write(_ value: [String:Any]) throws {
        let prefs = try proxy.prefs()
        let row: [String:Any] = ["UserDefinedName":"Isolated fixture","Interface":["DeviceName":"en0","Hardware":"Ethernet","Type":"Ethernet"],"Proxies":value]
        guard SCPreferencesSetValue(prefs,"NetworkServices" as CFString,["fixture":row] as CFDictionary) else { throw FlowError("Fixture set failed: \(SCError())") }
        try proxy.commit(prefs)
    }
    func read() throws -> [String:Any] {
        let p = try proxy.prefs(); guard let proto = proxy.protocols(p).first?.1 else { throw FlowError("Fixture protocol missing") }; return proxy.config(proto)
    }
    func check(_ result: Bool, _ description: String) throws { if !result { throw FlowError("SystemPreferences test failed: " + description) } }
    try write(old); try proxy.activate(port:18790)
    try check(try proxy.isOwned(),"activation readback")
    try check((try read())["HTTPPort"] as? Int == 18790,"managed port")
    try proxy.restore()
    try check((try read())["HTTPEnable"] as? Int == 0,"dead backup disabled")
    try check((try read())["ProxyAutoConfigEnable"] as? Int == 1,"PAC restored")
    try check((try read())["ExceptionsList"] as? [String] == ["localhost","*.internal"],"bypass preserved")
    try check(!fm.fileExists(atPath:proxy.ledger.path),"ledger completed")
    try write(old); try proxy.activate(port:18790)
    let foreign: [String:Any] = ["HTTPEnable":1,"HTTPProxy":"external.example","HTTPPort":8888]
    try write(foreign); try proxy.restore()
    try check(ProxyPolicy.owns(try read(),expected:foreign),"foreign state untouched")
    try write(old); try proxy.activate(port:18790)
    var mixed = try read(); mixed["ExceptionsList"] = ["new.external"]
    try write(mixed)
    var blocked = false
    do { try proxy.restore() } catch { blocked = true }
    try check(blocked && fm.fileExists(atPath:proxy.ledger.path),"partial ownership retains recovery")
    try write(foreign); try proxy.restore()
    try write(old); let count = try proxy.repairDead()
    let repaired = try read()
    try check(count == 1 && (repaired["HTTPEnable"] as? Int) == 0,"explicit dead entry repair")
    print("PASS: isolated SystemConfiguration activation, readback, dead backup, PAC/bypass, external ownership, mixed conflict, repair")
}
