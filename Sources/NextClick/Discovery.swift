import AppKit

enum Source: String { case window, menu, menubar, status, dock, mission }

struct Node {
    let el: AXUIElement
    let role: String
    let subrole: String
    var name: String          // title/description/placeholder/help: identity + search
    var text: String          // visible text gathered for search only (never persisted)
    let ident: String
    let frame: CGRect         // AX coords
    let visible: CGRect       // frame clipped by scroll areas/windows
    let source: Source
    var web = false           // came from the web-area search predicate
}

struct Scan {
    var nodes: [Node] = []
    var scope = "global"
    var origin = CGPoint.zero  // window origin, so identity survives window moves
    var mission = false
    var pid: pid_t = 0
    var timing = ""            // per-phase ms, for the scan log
}

enum Discovery {
    static let attrs = ["AXRole", "AXSubrole", "AXPosition", "AXSize", "AXTitle", "AXDescription",
                        "AXIdentifier", "AXEnabled", "AXPlaceholderValue", "AXHelp"]
    static let searchAttrs = attrs + ["AXValue"]

    static let pressRoles: Set = ["AXButton", "AXLink", "AXCheckBox", "AXRadioButton", "AXPopUpButton",
                                  "AXMenuButton", "AXMenuBarItem", "AXMenuItem", "AXComboBox", "AXTextField",
                                  "AXTextArea", "AXDisclosureTriangle", "AXColorWell", "AXDockItem", "AXRow"]
    static let maybePress: Set = ["AXImage", "AXGroup", "AXStaticText", "AXCell"]
    static let clipRoles: Set = ["AXWindow", "AXScrollArea", "AXList", "AXTable", "AXOutline", "AXBrowser"]
    static let leafRoles: Set = ["AXButton", "AXCheckBox", "AXRadioButton", "AXPopUpButton", "AXMenuButton",
                                 "AXTextField", "AXTextArea", "AXStaticText", "AXImage", "AXComboBox", "AXSlider",
                                 "AXDisclosureTriangle", "AXColorWell", "AXIncrementor", "AXScrollBar",
                                 "AXValueIndicator", "AXSplitter", "AXBusyIndicator", "AXProgressIndicator",
                                 "AXLevelIndicator", "AXMenuBar"]
    static let textRoles: Set = ["AXStaticText", "AXButton", "AXLink", "AXMenuItem", "AXCheckBox", "AXRadioButton",
                                 "AXPopUpButton", "AXHeading"]
    static let webKeys = ["AXLinkSearchKey", "AXButtonSearchKey", "AXControlSearchKey", "AXCheckBoxSearchKey",
                          "AXRadioGroupSearchKey", "AXTextFieldSearchKey", "AXListMarkerSearchKey"]

    // MARK: entry

    // Window scope: open menus, else the focused window (+ windows in front of it).
    // System scope: the app's menu bar, status items and Dock. screens: read on main by the caller.
    // mission: Mission Control state from the Dock observer; nil = unknown, ask the Dock.
    static func scan(_ app: NSRunningApplication, _ cfg: Config, search: Bool, system: Bool = false, mission: Bool? = nil,
                     screens: [CGRect]) -> Scan {
        var t = ProcessInfo.processInfo.systemUptime, timing: [String] = []
        func lap(_ name: String) {
            let now = ProcessInfo.processInfo.systemUptime
            timing.append("\(name) \(Int((now - t) * 1000))")
            t = now
        }
        if mission != false, let mc = missionNodes(screens) { return mc }
        lap("mc")
        let el = AX.app(app.processIdentifier)
        var s = Scan(scope: app.bundleIdentifier ?? "global")
        s.pid = app.processIdentifier
        var w = Walk(search: search, screens: screens, webFast: cfg.webFastPath && !search)
        var winFrame = CGRect.null
        if system {
            var status: [Node] = []
            let group = DispatchGroup()
            if cfg.statusItems {
                DispatchQueue.global(qos: .userInteractive).async(group: group) {
                    var sw = Walk(search: search, screens: screens, webFast: false)
                    statusItems().forEach { sw.visit($0, clip: .infinite, source: .status, owner: nil, depth: 0, descend: false) }
                    status = sw.out
                }
            }
            if cfg.menubar, let bar = AX.element(el, "AXMenuBar") {
                AX.elements(bar, "AXChildren").forEach { w.visit($0, clip: .infinite, source: .menubar, owner: nil, depth: 0, descend: false) }
            }
            lap("menubar")
            group.wait()
            w.out += status
            lap("status")
            if cfg.dock, let items = dockItems(screens) { items.forEach { w.visit($0, clip: .infinite, source: .dock, owner: nil, depth: 0, descend: false) } }
            lap("dock")
        } else {
            // One batched read: focus, window list, children (context menus), menu bar.
            let a = AX.multiple(el, ["AXFocusedWindow", "AXMainWindow", "AXWindows", "AXChildren", "AXMenuBar"])
            let menus = openMenus(children: a[3] as? [AXUIElement] ?? [], bar: AX.asElement(a[4]))
            if !menus.isEmpty {
                menus.forEach { w.visit($0, clip: .infinite, source: .menu, owner: nil, depth: 0) }
            } else if let win = AX.asElement(a[0]) ?? AX.asElement(a[1]) {
                if let f = AX.frame(win) { s.origin = f.origin; winFrame = f }
                for front in frontWindows(a[2] as? [AXUIElement] ?? [], focused: win) { w.visit(front, clip: .infinite, source: .window, owner: nil, depth: 0) }
                w.visit(win, clip: .infinite, source: .window, owner: nil, depth: 0)
            }
            lap("window(\(w.visited))")
            timing.append(String(format: "attr %.0f probe %d(+%d cached)/%.0f kids %d/%.0f lv %d", w.cost.attr, w.actionProbes, w.cached,
                                 w.cost.probe, w.cost.nKids, w.cost.kids, w.cost.levels))
            if cfg.hitTest {
                let n = w.out.count, front = occluders(pid: app.processIdentifier, window: winFrame)
                w.out = unoccluded(w.out, front)
                lap("hit(-\(n - w.out.count) of \(w.out.filter { n in front.contains { $0.intersects(n.visible) } }.count + n - w.out.count))")
            }
        }
        s.nodes = dedupe(w.out)
        let bySource = Dictionary(grouping: s.nodes, by: \.source.rawValue).mapValues(\.count)
        timing.append(bySource.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
        s.timing = timing.joined(separator: ", ")
        return s
    }

    // Windows listed in front of the focused one (popovers, palettes, sheets-as-windows).
    static func frontWindows(_ windows: [AXUIElement], focused: AXUIElement) -> [AXUIElement] {
        var out: [AXUIElement] = []
        for w in windows.prefix(8) {
            if AX.same(w, focused) { break }
            if AX.bool(w, "AXMinimized") != true { out.append(w) }
        }
        return Array(out.prefix(3))
    }

    // Context menus show up as AXMenu children of the app; menu bar menus hang off the selected item.
    // Selected items are probed in parallel, level by level (menu bar -> menu -> submenu).
    static func openMenus(children: [AXUIElement], bar: AXUIElement?) -> [AXUIElement] {
        func menus(_ els: [AXUIElement]) -> [AXUIElement] {
            let roles = Walk.parallel(els.count) { AX.string(els[$0], "AXRole") }
            return zip(els, roles).filter { $0.1 == "AXMenu" }.map(\.0)
        }
        var out = menus(Array(children.prefix(32)))
        var items = (bar.map { AX.elements($0, "AXChildren") } ?? []) + out.flatMap { AX.elements($0, "AXChildren") }
        while !items.isEmpty, out.count < 8 {
            let sel = Walk.parallel(items.count) { AX.bool(items[$0], "AXSelected") == true }
            let opened = menus(zip(items, sel).filter(\.1).flatMap { AX.elements($0.0, "AXChildren") })
            out += opened
            items = opened.flatMap { AX.elements($0, "AXChildren") }
        }
        return out
    }

    // Only targets under a window in front of the focused one (popover, sheet, another app) are
    // hit-tested: the element on screen at the label's spot must be the target, inside it, or a container
    // of it. Everything else is visible by construction, so the common case costs no app round trips.
    // Web results skip this: Chromium answers every point with one page-sized group.
    static func unoccluded(_ nodes: [Node], _ front: [CGRect]) -> [Node] {
        let keep = Walk.parallel(nodes.count) { i -> Bool in
            let n = nodes[i], r = n.visible
            guard !n.web, front.contains(where: { $0.intersects(r) }) else { return true }
            for p in [CGPoint(x: r.midX, y: r.midY), CGPoint(x: r.minX + min(6, r.width / 2), y: r.midY)] {
                if visibleAt(p, n) { return true }
            }
            return false
        }
        return zip(nodes, keep).filter(\.1).map(\.0)
    }

    static func visibleAt(_ p: CGPoint, _ n: Node) -> Bool {
        guard let h = AX.hit(p), !AX.same(h, n.el), let f = AX.frame(h) else { return true }
        return covers(hit: f, target: n.frame)
    }

    // Pure geometry, so it can be tested: hit inside the target, or a container of it.
    static func covers(hit f: CGRect, target t: CGRect) -> Bool {
        t.insetBy(dx: -3, dy: -3).contains(f) || f.insetBy(dx: -3, dy: -3).contains(t)
    }

    // On-screen windows in front of the app's focused window (AX space; CG window bounds share it).
    // Our own panels, the Dock, menu bar and other system layers are left out.
    static func occluders(pid: pid_t, window: CGRect) -> [CGRect] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]]
        else { return [] }
        let me = getpid()
        var out: [CGRect] = []
        for w in list {
            guard let b = w[kCGWindowBounds as String] as? NSDictionary, let r = CGRect(dictionaryRepresentation: b) else { continue }
            let owner = w[kCGWindowOwnerPID as String] as? pid_t ?? 0, layer = w[kCGWindowLayer as String] as? Int ?? 0
            if owner == pid, window.isNull || abs(r.minX - window.minX) + abs(r.minY - window.minY) + abs(r.width - window.width) < 4 { break }
            // Normal windows and popups; the app's own windows at any level (popovers, sheets). Other apps'
            // floating layers are skipped: they're usually transparent overlays (e.g. ChatGPT's companion).
            let counts = layer == 0 || layer == 101 || (owner == pid && (0..<20).contains(layer))
            if owner == me || !counts || (w[kCGWindowAlpha as String] as? Double ?? 1) < 0.05 { continue }
            out.append(r)
        }
        return out
    }

    static func dedupe(_ nodes: [Node]) -> [Node] {
        var seen = Set<String>()
        return nodes.filter { n in
            let r = n.visible
            return seen.insert("\(Int(r.minX)),\(Int(r.minY)),\(Int(r.width)),\(Int(r.height))").inserted
        }
    }

    // MARK: system UI

    static func dockApp() -> NSRunningApplication? {
        NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.dock").first
    }

    static func dockItems(_ screens: [CGRect]) -> [AXUIElement]? {
        guard let dock = dockApp() else { return nil }
        let el = AX.app(dock.processIdentifier, timeout: 0.2)
        guard let list = AX.elements(el, "AXChildren").first(where: { AX.string($0, "AXRole") == "AXList" }) else { return nil }
        let items = AX.elements(list, "AXChildren")
        // autohidden dock parks items off-screen
        return items.filter { i in AX.frame(i).map { f in screens.contains { $0.contains(f) } } ?? false }
    }

    // Most apps own no status item; remember that for a minute instead of asking every scan.
    private static var noExtras: [pid_t: Double] = [:]
    private static let extrasLock = NSLock()

    static func statusItems() -> [AXUIElement] {
        let now = ProcessInfo.processInfo.systemUptime
        extrasLock.lock()
        let apps = NSWorkspace.shared.runningApplications.filter {
            ($0.activationPolicy != .prohibited || $0.bundleIdentifier == "com.apple.controlcenter")
                && noExtras[$0.processIdentifier].map { now - $0 > 60 } ?? true
        }
        extrasLock.unlock()
        var found = [[AXUIElement]](repeating: [], count: apps.count)
        let lock = NSLock()
        DispatchQueue.concurrentPerform(iterations: apps.count) { i in
            let pid = apps[i].processIdentifier
            guard let bar = AX.element(AX.app(pid, timeout: 0.05), "AXExtrasMenuBar") else {
                extrasLock.lock(); noExtras[pid] = now; extrasLock.unlock()
                return
            }
            let items = AX.elements(bar, "AXChildren", max: 64)
            lock.lock(); found[i] = items; lock.unlock()
        }
        return found.flatMap { $0 }
    }

    // Mission Control lives in the Dock's AX tree under identifier "mc" while open.
    static func missionRoot() -> AXUIElement? {
        guard let dock = dockApp() else { return nil }
        let el = AX.app(dock.processIdentifier, timeout: 0.2)
        return AX.elements(el, "AXChildren").first { AX.string($0, "AXIdentifier") == "mc" }
    }

    static func missionNodes(_ screens: [CGRect]) -> Scan? {
        guard let root = missionRoot() else { return nil }
        var w = Walk(search: false, screens: screens, webFast: false)
        w.mission = true
        w.visit(root, clip: .infinite, source: .mission, owner: nil, depth: 0)
        return Scan(nodes: dedupe(w.out), scope: "mission-control", mission: true)
    }

    // MARK: scroll areas

    static func scrollAreas(_ app: NSRunningApplication, screens: [CGRect]) -> [(AXUIElement, CGRect)] {
        let el = AX.app(app.processIdentifier)
        guard let win = AX.element(el, "AXFocusedWindow") ?? AX.element(el, "AXMainWindow"),
              let wf = AX.frame(win) else { return [] }
        var w = Walk(search: false, screens: screens, webFast: false)
        w.areasOnly = true
        w.visit(win, clip: .infinite, source: .window, owner: nil, depth: 0)
        let areas = w.areas.filter { $0.1.width >= 60 && $0.1.height >= 60 }
        let sorted = areas.sorted { $0.1.width * $0.1.height > $1.1.width * $1.1.height }
        return sorted.isEmpty ? [(win, wf)] : Array(sorted.prefix(9))
    }
}

// Breadth-first walk with clipping, a node budget and a deadline. Each tree level is fetched
// concurrently: the target app still answers serially, but the IPC round trips overlap.
struct Walk {
    let search: Bool
    let screens: [CGRect]
    let webFast: Bool
    var mission = false
    var areasOnly = false
    var out: [Node] = []
    var areas: [(AXUIElement, CGRect)] = []
    var visited = 0
    var actionProbes = 0
    var cost = (attr: 0.0, probe: 0.0, kids: 0.0, nKids: 0, levels: 0)  // wall ms per phase, for the scan log
    var probeHits: [String: Int] = [:]
    var cached = 0
    let deadline = ProcessInfo.processInfo.systemUptime + 1.2
    static let maxNodes = 9000, maxDepth = 64, maxProbes = 300

    // kids: AXChildren comes in the same batched read unless the parent is a scroll area (where a table
    // would materialize every row; tables use AXVisibleRows instead).
    private struct Item { let el: AXUIElement; let clip: CGRect; let owner: Int?; let depth: Int; let descend: Bool; var kids = false }
    private struct Expand { let el: AXUIElement; let role: String; let clip: CGRect; let owner: Int?; let depth: Int; var kids: [AXUIElement]? = nil }
    static let tableRoles: Set = ["AXTable", "AXOutline"]

    var exhausted: Bool { visited >= Walk.maxNodes || ProcessInfo.processInfo.systemUptime > deadline }

    mutating func visit(_ el: AXUIElement, clip: CGRect, source: Source, owner: Int?, depth: Int, descend: Bool = true) {
        let names = search ? Discovery.searchAttrs : Discovery.attrs
        var level = [Item(el: el, clip: clip, owner: owner, depth: depth, descend: descend)]
        while !level.isEmpty, !exhausted {
            let batch = Array(level.prefix(Walk.maxNodes - visited))
            visited += batch.count
            var t = ProcessInfo.processInfo.systemUptime
            func tick() -> Double { let n = ProcessInfo.processInfo.systemUptime, d = (n - t) * 1000; t = n; return d }
            let withKids = names + ["AXChildren"]
            let vals = Walk.parallel(batch.count) { AX.multiple(batch[$0].el, batch[$0].kids ? withKids : names) }
            cost.attr += tick()
            let press = probe(batch.map(\.el), vals)
            cost.probe += tick()
            var expand: [Expand] = []
            for i in batch.indices {
                guard var x = consider(batch[i], vals[i], pressable: press[i], source: source) else { continue }
                if batch[i].kids, !Walk.tableRoles.contains(x.role) { x.kids = Array(((vals[i].last ?? nil) as? [AXUIElement] ?? []).prefix(2000)) }
                expand.append(x)
            }
            _ = tick()
            let need = expand.indices.filter { expand[$0].kids == nil }
            let fetched = Walk.parallel(need.count) { Walk.children(expand[need[$0]].el, role: expand[need[$0]].role) }
            for (k, i) in need.enumerated() { expand[i].kids = fetched[k] }
            cost.kids += tick()
            cost.nKids += need.count
            cost.levels += 1
            level = expand.flatMap { p in
                (p.kids ?? []).map { Item(el: $0, clip: p.clip, owner: p.owner, depth: p.depth + 1, descend: true, kids: p.role != "AXScrollArea") }
            }.filter { $0.depth < Walk.maxDepth }
        }
    }

    // AXPress lookups for roles that are only sometimes clickable, capped, in parallel. Answers are
    // cached per element (stable across scans of the same window), so repeat scans skip most probes.
    private mutating func probe(_ els: [AXUIElement], _ vals: [[CFTypeRef?]]) -> [Bool?] {
        var out = [Bool?](repeating: nil, count: els.count), idx: [Int] = []
        for (i, v) in vals.enumerated() where actionProbes < Walk.maxProbes && (v[7] as? Bool) != false && !areasOnly {
            let role = v[0] as? String ?? ""
            guard mission ? role != "AXButton" && role != "AXDockItem" : Discovery.maybePress.contains(role) else { continue }
            if let hit = PressCache.get(els[i]) { out[i] = hit } else { idx.append(i); actionProbes += 1 }
        }
        let hits = Walk.parallel(idx.count) { AX.actions(els[idx[$0]]).contains("AXPress") }
        for (k, i) in idx.enumerated() {
            out[i] = hits[k]
            PressCache.set(els[i], hits[k])
        }
        for (i, h) in out.enumerated() where h == true { probeHits[vals[i][0] as? String ?? "?", default: 0] += 1 }
        cached += out.compactMap { $0 }.count - idx.count
        return out
    }

    private mutating func consider(_ it: Item, _ v: [CFTypeRef?], pressable: Bool?, source: Source, web: Bool = false) -> Expand? {
        let role = v[0] as? String ?? "", sub = v[1] as? String ?? ""
        var frame = CGRect.null
        if let p = AX.point(v[2]), let s = AX.size(v[3]) { frame = CGRect(origin: p, size: s) }
        var clip = it.clip
        if Discovery.clipRoles.contains(role), !frame.isNull {
            clip = clip.intersection(frame)
            if clip.isNull || clip.isEmpty { return nil }
        }
        let visible = frame.isNull ? .null : frame.intersection(clip)
        if areasOnly {
            if role == "AXScrollArea", !visible.isNull { areas.append((it.el, visible)) }
        } else if (v[7] as? Bool) != false, usable(visible), isTarget(role, pressable) {
            let name = [v[4], v[5], v[8], v[9]].lazy.compactMap { $0 as? String }.first { !$0.isEmpty } ?? ""
            out.append(Node(el: it.el, role: role, subrole: sub, name: String(name.prefix(80)), text: "",
                            ident: v[6] as? String ?? "", frame: frame, visible: visible, source: source, web: web))
            if search { addText(owner: out.count - 1, v: v, role: role) }
            guard it.descend, search || role == "AXRow" || mission else { return nil }  // rows can hold buttons
            return Expand(el: it.el, role: role, clip: clip, owner: out.count - 1, depth: it.depth)
        } else if search, let o = it.owner {
            addText(owner: o, v: v, role: role)
        }
        guard it.descend, !Discovery.leafRoles.contains(role) || mission else { return nil }
        if role == "AXWebArea", webFast, webSearch(it.el, clip: clip, source: source) { return nil }
        return Expand(el: it.el, role: role, clip: clip, owner: it.owner, depth: it.depth)
    }

    // Tables/outlines: only on-screen rows (AXChildren would materialize every row).
    private static func children(_ el: AXUIElement, role: String) -> [AXUIElement] {
        role == "AXTable" || role == "AXOutline" ? AX.elements(el, "AXVisibleRows", max: 400) : AX.elements(el, "AXChildren", max: 2000)
    }

    static func parallel<T>(_ n: Int, _ f: (Int) -> T) -> [T] {
        guard n > 1 else { return (0..<n).map(f) }
        var out = [T?](repeating: nil, count: n)
        out.withUnsafeMutableBufferPointer { buf in DispatchQueue.concurrentPerform(iterations: n) { buf[$0] = f($0) } }
        return out.map { $0! }
    }

    private func usable(_ r: CGRect) -> Bool {
        !r.isNull && r.width >= 2 && r.height >= 2 && Geo.onScreen(r, screens)
    }

    private func isTarget(_ role: String, _ pressable: Bool?) -> Bool {
        if mission { return role == "AXButton" || role == "AXDockItem" || pressable == true }
        return Discovery.pressRoles.contains(role) || pressable == true
    }

    private mutating func addText(owner: Int, v: [CFTypeRef?], role: String) {
        guard Discovery.textRoles.contains(role) else { return }
        let parts = [v[4], v[5], v.count > 10 ? v[10] : nil].compactMap { $0 as? String }.filter { !$0.isEmpty }
        guard !parts.isEmpty, out[owner].text.count < 240 else { return }
        out[owner].text += " " + parts.joined(separator: " ")
    }

    // One parameterized call returns every link/button/control in a web area.
    private mutating func webSearch(_ area: AXUIElement, clip: CGRect, source: Source) -> Bool {
        let params: [String: Any] = ["AXSearchKey": Discovery.webKeys, "AXResultsLimit": 3000,
                                     "AXDirection": "AXDirectionNext", "AXVisibleOnly": true,
                                     "AXImmediateDescendantsOnly": false]
        guard let r = AX.parameterized(area, "AXUIElementsForSearchPredicate", params as CFDictionary),
              let found = r as? [AXUIElement], !found.isEmpty else { return false }
        let lite = Array(Discovery.attrs.prefix(8)), list = Array(found.prefix(Walk.maxNodes - visited))
        let vals = Walk.parallel(list.count) { AX.multiple(list[$0], lite) + [nil, nil] }
        visited += list.count
        for (el, v) in zip(list, vals) {
            _ = consider(Item(el: el, clip: clip, owner: nil, depth: Walk.maxDepth - 1, descend: false), v, pressable: nil, source: source, web: true)
        }
        return true
    }
}

// Element -> has AXPress. AXUIElement refs compare/hash by the underlying object (CFEqual/CFHash).
enum PressCache {
    private struct K: Hashable {
        let el: AXUIElement
        static func == (a: K, b: K) -> Bool { CFEqual(a.el, b.el) }
        func hash(into h: inout Hasher) { h.combine(CFHash(el)) }
    }
    private static var map: [K: Bool] = [:]
    private static let lock = NSLock()

    static func get(_ el: AXUIElement) -> Bool? {
        lock.lock(); defer { lock.unlock() }
        return map[K(el: el)]
    }

    static func set(_ el: AXUIElement, _ v: Bool) {
        lock.lock(); defer { lock.unlock() }
        if map.count > 20000 { map = [:] }  // crude bound; stale entries are harmless
        map[K(el: el)] = v
    }
}
