import XCTest
@testable import FlowModel

final class PolicyTests: XCTestCase {
    func fixture() -> Settings {
        var s = Settings(); s.routes = [Route(name:"A",host:"127.0.0.1",port:28970,kind:"http",id:"a"),Route(name:"B",host:"127.0.0.1",port:28971,kind:"socks5",id:"b")]; s.selected = "a"; return s
    }
    func testConfigAndRulePrecedence() throws {
        var s = fixture(); s.rules = [Rule(kind:"PROCESS-PATH",value:"/Applications/Test.app/Contents/MacOS/Test",route:"b"),Rule(kind:"DOMAIN-SUFFIX",value:"example.com",route:"a"),Rule(kind:"DOMAIN",value:"example.com",route:"DIRECT"),Rule(kind:"DOMAIN-SUFFIX",value:"api.example.com",route:"b")]
        let c = try s.coreConfig(controllerPort:28972,secret:"test")
        XCTAssertEqual(c["rules"] as? [String],["DOMAIN-SUFFIX,api.example.com,FS-b","DOMAIN,example.com,DIRECT","DOMAIN-SUFFIX,example.com,FS-a","PROCESS-PATH,/Applications/Test.app/Contents/MacOS/Test,FS-b","MATCH,FS-Default"])
        XCTAssertEqual((c["tun"] as? [String:Bool])?["enable"],false)
        XCTAssertEqual(c["bind-address"] as? String,"127.0.0.1")
    }
    func testNoImplicitDirect() {
        let s = fixture(); XCTAssertEqual(s.candidates("a"),["UP-a","UP-b","REJECT"])
        var f = Failover("UP-a")
        for _ in 0..<3 { _ = f.observe(candidates:s.candidates("a"),health:["UP-a":false,"UP-b":false]) }
        XCTAssertEqual(f.current,"REJECT")
        XCTAssertEqual(f.observe(candidates:s.candidates("a"),health:["UP-a":false,"UP-b":true]),"UP-b")
    }
    func testStickToHealthyBackupAndUnknown() {
        let s = fixture(); var f = Failover("UP-a")
        for _ in 0..<2 { XCTAssertEqual(f.observe(candidates:s.candidates("a"),health:["UP-a":false,"UP-b":true]),"UP-a") }
        XCTAssertEqual(f.observe(candidates:s.candidates("a"),health:["UP-a":false,"UP-b":true]),"UP-b")
        for _ in 0..<8 { XCTAssertEqual(f.observe(candidates:s.candidates("a"),health:["UP-a":true,"UP-b":true]),"UP-b") }
        for _ in 0..<8 { XCTAssertEqual(f.observe(candidates:s.candidates("a"),health:[:]),"UP-b") }
    }
    func testExplicitDirectFallback() {
        var s = fixture(); s.allowDirect = true; var f = Failover("UP-a")
        for _ in 0..<3 { _ = f.observe(candidates:s.candidates("a"),health:["UP-a":false,"UP-b":false]) }
        XCTAssertEqual(f.current,"DIRECT")
    }
    func testPreserveActualSelectionWhenBuilding() throws {
        let c = try fixture().coreConfig(controllerPort:28972,secret:"test",selections:["a":"UP-b"])
        let groups = c["proxy-groups"] as! [[String:Any]]
        XCTAssertEqual((groups[0]["proxies"] as? [String])?.first,"UP-b")
    }
    func testRejectSelfLoopAndRuleInjection() {
        var s = fixture(); s.routes[0].port = s.port; XCTAssertThrowsError(try s.validate())
        s = fixture(); s.rules = [Rule(kind:"DOMAIN",value:"a.com,DIRECT",route:"a")]; XCTAssertThrowsError(try s.validate())
        s = fixture(); s.routes[0].host = "http://host/path"; XCTAssertThrowsError(try s.validate())
        s = fixture(); s.rules = [Rule(kind:"PROCESS-PATH",value:"relative",route:"a")]; XCTAssertThrowsError(try s.validate())
        s = fixture(); s.rules = [Rule(kind:"DOMAIN",value:"a..com",route:"a")]; XCTAssertThrowsError(try s.validate())
    }
    func testUnknownAndRemoteProxyNeverRemoved() {
        let old: [String:Any] = ["HTTPEnable":1,"HTTPProxy":"remote.example","HTTPPort":7897,"HTTPSEnable":1,"HTTPSProxy":"127.0.0.1","HTTPSPort":29758,"ProxyAutoConfigEnable":1,"ProxyAutoConfigURLString":"https://example.com/pac","ExceptionsList":["local"]]
        let result = ProxyPolicy.removeDeadLoopback(old,isClosed:{ _,_ in false })
        XCTAssertTrue(ProxyPolicy.owns(old,expected:result))
        let fixed = ProxyPolicy.removeDeadLoopback(old,isClosed:{ _,_ in true })
        XCTAssertEqual(fixed["HTTPEnable"] as? Int,1); XCTAssertEqual(fixed["HTTPSEnable"] as? Int,0)
        XCTAssertEqual(fixed["ProxyAutoConfigEnable"] as? Int,1); XCTAssertEqual(fixed["ExceptionsList"] as? [String],["local"])
    }
    func testRestorationOwnershipAndBypassPreservation() {
        let old: [String:Any] = ["ExceptionsList":["localhost","*.internal"],"ProxyAutoConfigEnable":1,"ProxyAutoConfigURLString":"https://example.com/pac"]
        let owned = ProxyPolicy.managed(old,port:18790)
        XCTAssertEqual(owned["ExceptionsList"] as? [String],["localhost","*.internal"])
        XCTAssertEqual(owned["ProxyAutoConfigEnable"] as? Int,0)
        var foreign = owned; foreign["HTTPPort"] = 29758
        XCTAssertFalse(ProxyPolicy.owns(foreign,expected:owned)); XCTAssertTrue(ProxyPolicy.owns(owned,expected:owned))
    }
}
