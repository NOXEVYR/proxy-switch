import AppKit
import FlowModel

// Command modes never instantiate the GUI or modify system settings unless explicitly requested.
let args = CommandLine.arguments
if args.count == 2 && args[1] == "--system-selftest" {
    do { try systemSelfTest(); exit(0) } catch { fputs((error.localizedDescription + "\n"),stderr); exit(1) }
}
if args.count >= 3 && ["--worker","--repair"].contains(args[1]) {
    exit(Worker(URL(fileURLWithPath:args[2])).run(repair:args[1] == "--repair"))
}
if args.count == 6 && args[1] == "--export-config" {
    do {
        let settings = try loadJSON(Settings.self,URL(fileURLWithPath:args[2]))
        guard let port = Int(args[4]) else { throw FlowError("Invalid controller port") }
        let config = try settings.coreConfig(controllerPort:port,secret:args[5])
        try save(try jsonData(config),URL(fileURLWithPath:args[3])); exit(0)
    } catch { fputs("Configuration validation failed\n",stderr); exit(1) }
}
if args.count == 2 && args[1] == "--version" { print("FlowSwitch macOS \(appVersion)"); exit(0) }
if let identifier = Bundle.main.bundleIdentifier,
   let existing = NSRunningApplication.runningApplications(withBundleIdentifier:identifier).first(where: { $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }) {
    existing.activate(options:[.activateAllWindows,.activateIgnoringOtherApps]); exit(0)
}
let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
