import AppKit
import FlowModel

extension AppDelegate {
    // Runs only with --ui-smoke, against a newly created temporary data directory.
    // Real UI selectors exercise persistence; network-changing selectors are never called.
    func verifyWorkspace() throws {
        func check(_ ok: Bool, _ message: String) throws { if !ok { throw FlowError(message) } }
        try check(window.isVisible && pages.count == 3,"Missing workspace")
        try check(root.path.hasPrefix(fm.temporaryDirectory.path) && root.lastPathComponent.hasPrefix("FlowSwitch-UI-"),"UI test is not isolated")
        defer { try? fm.removeItem(at:root) }
        fputs("UI: route and rule actions\n",stderr)
        name.stringValue = "日常线路"; host.stringValue = "127.0.0.1"; port.stringValue = "17891"; addRoute()
        name.stringValue = "备用线路"; host.stringValue = "127.0.0.1"; port.stringValue = "17892"; addRoute()
        try check(settings.routes.count == 2,"Add route did not persist")
        ruleValue.stringValue = "example.com"; ruleKind.selectItem(at:0); ruleRoute.selectItem(at:1); addRule()
        try check(settings.rules.count == 1,"Add rule failed")
        ruleValue.stringValue = "未保存的输入"
        for index in [1,2,0] { navigationButtons[index].performClick(nil); try check(currentPage == index && !pages[index].isHidden,"Navigation failed") }
        try check(ruleValue.stringValue == "未保存的输入","Navigation discarded a draft")
        let saved = try Data(contentsOf:root.appendingPathComponent("settings.json"))
        fputs("UI: resize and navigation\n",stderr)
        for size in [NSSize(width:1040,height:860),NSSize(width:1140,height:900),NSSize(width:1440,height:980)] {
            window.setContentSize(size)
            for index in 0..<3 {
                selectPage(index); window.contentView!.layoutSubtreeIfNeeded()
                let page = pages[index]; let parent = page.superview!
                try check(page.frame.minY >= -1 && page.frame.maxY <= parent.bounds.height+1,"Page clipped vertically")
                func verify(_ view: NSView) throws {
                    guard !view.isHidden else { return }
                    // Scroll document contents are intentionally larger than their viewport.
                    if view is NSScrollView { return }
                    for child in view.subviews {
                        let rect = child.convert(child.bounds,to:window.contentView)
                        try check(rect.minX >= -1 && rect.maxX <= window.contentView!.bounds.width+1 && rect.minY >= -1 && rect.maxY <= window.contentView!.bounds.height+1,"Control escaped window: \(type(of:child)), rect=\(rect), window=\(window.contentView!.bounds), page=\(index)")
                        try verify(child)
                    }
                }
                try verify(page)
                for control in index == 0 ? [name,host,port] : index == 1 ? [ruleValue] : [] {
                    try check(!control.isHiddenOrHasHiddenAncestor && control.visibleRect.width >= control.bounds.width-1,"Input hidden or clipped after resize")
                }
            }
        }
        try check(try Data(contentsOf:root.appendingPathComponent("settings.json")) == saved,"Layout changed saved settings")
        fputs("UI: persistence and captures\n",stderr)
        removeRule.selectItem(at:0); deleteRule(); removeRoute.selectItem(at:1); deleteRoute()
        try check(settings.rules.isEmpty && settings.routes.count == 1,"Delete actions failed")
        let reloaded = try loadJSON(Settings.self,root.appendingPathComponent("settings.json"))
        try check(reloaded.routes.count == 1 && reloaded.rules.isEmpty,"Persistence disagrees with UI")
        // Restore synthetic examples for the screenshots, without activating a proxy.
        name.stringValue = "备用线路"; port.stringValue = "17892"; addRoute()
        ruleValue.stringValue = "example.com"; ruleRoute.selectItem(at:1); addRule()
        ruleValue.stringValue = ""; window.setContentSize(NSSize(width:1140,height:900)); selectPage(0)
        if let index = CommandLine.arguments.firstIndex(of:"--screenshot"), index+1 < CommandLine.arguments.count {
            let target = URL(fileURLWithPath:CommandLine.arguments[index+1])
            for page in 0..<3 {
                selectPage(page); window.contentView!.layoutSubtreeIfNeeded(); window.displayIfNeeded()
                guard let view = window.contentView, let rep = view.bitmapImageRepForCachingDisplay(in:view.bounds) else { throw FlowError("Screenshot unavailable") }
                view.cacheDisplay(in:view.bounds,to:rep)
                let file = page == 0 ? target : target.deletingLastPathComponent().appendingPathComponent("ui-page-\(page).png")
                guard let bytes = rep.representation(using:.png,properties:[:]) else { throw FlowError("Screenshot encoding failed") }
                try bytes.write(to:file)
            }
        }
        print("PASS: native UI navigation, draft preservation, route/rule add/delete persistence, three window sizes, isolated settings")
    }
}
