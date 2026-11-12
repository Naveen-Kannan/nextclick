import AppKit

// shortcut -> scan (AX queue) -> labels -> typed letters -> click. Search mode filters by text instead.
final class ClickMode {
    enum Mode { case labels, system, search }
    private struct Pending { let letter: Character; let node: Node; let kind: ClickKind; let timer: DispatchWorkItem }

    private unowned let e: Engine
    private let overlay = Overlay()
    private var tap: KeyTap?
    private(set) var active = false
    private var mode = Mode.labels
    private var scan = Scan()
    private var ids: [String] = []
    private var labels: [String] = []
    private var typed = ""
    private var query = ""
    private var matches: [Int] = []
    private var focused = 0
    private var chosen: Int?
    private var gen = 0
    private var help = false
    private var pending: Pending?
    private var monitors: [Any] = []
    private var observers: [NSObjectProtocol] = []
    private var clickedAt = 0.0
    // click.prefetch (Caps down) scans while the key is still held; click.show (Caps up) reuses it.
    private var pre: (pid: pid_t, at: Double, scan: Scan?, ids: [String])?
    private var waiting: Int?
    private var requestedAt = 0.0  // click.show received, for the shown-in log
    private var retried = false

    var mission: Bool { active && scan.mission }

    init(_ e: Engine) { self.e = e }

    // Same mode again closes; the other mode switches.
    func toggle(_ m: Mode) {
        if active {
            let same = mode == m
            exit()
            if same { return }
        }
        enter(m)
    }

    func enter(_ m: Mode) {
        guard !active else { return }
        guard AXIsProcessTrusted() else { log.error("accessibility not granted"); return }
        guard let app = NSWorkspace.shared.frontmostApplication, !e.ignored(app) else { return }
        e.scroll.exit()
        let t = KeyTap { [unowned self] type, ev in self.key(type, ev) }
        requestedAt = ProcessInfo.processInfo.systemUptime
        retried = false
        guard t.start() else { return }
        tap = t
        active = true
        mode = m
        addMonitors()
        if e.cfg.hideCursor { Cursor.hide() }
        rescan()
    }

    func exit() {
        guard active else { return }
        active = false
        gen += 1
        pending?.timer.cancel()
        pending = nil
        help = false
        tap?.stop()
        tap = nil
        overlay.hide()
        monitors.forEach { NSEvent.removeMonitor($0) }
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        monitors = []
        observers = []
        Cursor.show()
    }

    func warm() { overlay.warm(theme: Theme.named(e.cfg.theme), size: CGFloat(e.cfg.labelSize)) }

    // click.repeat without showing labels.
    func repeatSilently() {
        guard !active, AXIsProcessTrusted(), let last = e.last, let app = NSWorkspace.shared.frontmostApplication else { return }
        let cfg = e.cfg, screens = Geo.screens, mc = e.missionOpen
        e.ax.async { [weak self] in
            let s = Discovery.scan(app, cfg, search: false, mission: mc, screens: screens)
            let ids = Labels.identity(s.nodes, origin: s.origin)
            DispatchQueue.main.async {
                guard let self, s.scope == last.scope, let i = ids.firstIndex(of: last.key) else { return }
                Clicker.click(s.nodes[i], last.kind, restore: self.e.cfg.restorePointer)
            }
        }
    }

    // MARK: scan

    func prefetch() {
        guard !active, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, !e.ignored(app) else { return }
        let pid = app.processIdentifier, now = ProcessInfo.processInfo.systemUptime
        pre = (pid, now, nil, [])
        let cfg = e.cfg, screens = Geo.screens, fresh = e.enabler.ensure(app), mc = e.missionOpen
        e.pre.async { [weak self] in
            if fresh { usleep(300_000) }
            let s = Discovery.scan(app, cfg, search: false, mission: mc, screens: screens)
            let ids = Labels.identity(s.nodes, origin: s.origin)
            log.notice("prefetch \(s.scope, privacy: .public): \(s.nodes.count) targets [\(s.timing, privacy: .public)]")
            DispatchQueue.main.async {
                guard let self, self.pre?.pid == pid, self.pre?.at == now else { return }
                self.pre = (pid, now, s, ids)
                if let g = self.waiting { self.waiting = nil; self.pre = nil; self.show(s, ids, gen: g) }
            }
        }
    }

    // A prefetch for this app from the last 1.5 s: use it, or wait for it if still running.
    private func usePrefetch(_ app: NSRunningApplication) -> Bool {
        guard mode == .labels, let p = pre, p.pid == app.processIdentifier,
              ProcessInfo.processInfo.systemUptime - p.at < 1.5 else { return false }
        if let s = p.scan { pre = nil; show(s, p.ids, gen: gen) } else { waiting = gen }
        return true
    }

    private func rescan() {
        guard let app = NSWorkspace.shared.frontmostApplication else { return exit() }
        gen += 1
        if usePrefetch(app) { return }
        let g = gen, cfg = e.cfg, search = mode == .search, system = mode == .system, screens = Geo.screens, mc = e.missionOpen
        let fresh = system ? false : e.enabler.ensure(app)
        e.ax.async { [weak self] in
            if fresh { usleep(300_000) }  // Chromium builds its tree after the flag flips
            let t0 = ProcessInfo.processInfo.systemUptime
            let s = Discovery.scan(app, cfg, search: search, system: system, mission: mc, screens: screens)
            let ids = Labels.identity(s.nodes, origin: s.origin)
            let ms = Int((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            log.notice("scan \(s.scope, privacy: .public): \(s.nodes.count) targets in \(ms) ms [\(s.timing, privacy: .public)]")
            DispatchQueue.main.async { self?.show(s, ids, gen: g) }
        }
    }

    private func show(_ s: Scan, _ ids: [String], gen g: Int) {
        guard active, g == gen else { return }
        scan = s
        self.ids = ids
        typed = ""
        query = ""
        matches = []
        chosen = nil
        if s.nodes.count < 8, !retried, e.enabler.warming(s.pid) {  // tree still being built: one quick retry
            retried = true
            let g = gen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in if self?.gen == g, self?.active == true { self?.rescan() } }
            return
        }
        guard !s.nodes.isEmpty else { return flash("Nothing to click") }
        if mode == .search { overlay.card("type to search"); return }
        let pool = Labels.generate(s.nodes.count, Labels.keys(e.cfg.labelKeys))
        labels = e.cfg.smartLabels ? Labels.assign(keys: ids, pool: pool, memory: e.history.memory(s.scope)) : spatial(pool)
        let t0 = ProcessInfo.processInfo.systemUptime
        overlay.show(zip(labels, s.nodes).map { .init(label: $0, rect: $1.visible) }, theme: Theme.named(e.cfg.theme),
                     size: CGFloat(e.cfg.labelSize), high: s.mission)
        let now = ProcessInfo.processInfo.systemUptime
        log.notice("shown \(s.nodes.count) labels \(Int((now - self.requestedAt) * 1000)) ms after click.show (overlay \(Int((now - t0) * 1000)) ms)")
        if e.cfg.sounds { e.sound.play(.open, volume: e.cfg.volume) }
    }

    private func spatial(_ pool: [String]) -> [String] {
        var out = [String](repeating: "", count: pool.count)
        for (k, i) in Labels.spatial(scan.nodes.map(\.visible)).enumerated() { out[i] = pool[k] }
        return out
    }

    private func flash(_ msg: String) {
        overlay.card(msg)
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in if self?.gen == g { self?.exit() } }
    }

    // MARK: keys (tap callback, main thread)

    private func key(_ type: CGEventType, _ ev: CGEvent) -> Bool {
        guard active else { return false }
        if let p = pending { return pendingKey(type, ev, p) }
        guard type == .keyDown else { return type == .keyUp }
        let code = Key.code(ev), f = ev.flags, rep = Key.isRepeat(ev)
        if help { help = false; overlay.card(nil); return true }
        switch code {
        case Key.esc: exit()
        case Key.del: backspace()
        case Key.ret, Key.enter: confirm(ClickMode.kind(f))
        case Key.tab: move(f.contains(.maskShift) ? -1 : 1)
        case Key.down where mode == .search: move(1)
        case Key.up where mode == .search: move(-1)
        case Key.space: mode == .search ? append(" ") : (rep ? () : overlay.rotate())
        default: if !rep { char(code, f) }
        }
        return true
    }

    private func char(_ code: Int64, _ f: CGEventFlags) {
        guard let c = Key.char(code, shift: f.contains(.maskShift)) else { return }
        if c == "?" { help = true; return overlay.card(Help.text, center: true) }
        if mode == .search { return append(String(c)) }
        if c == ".", typed.isEmpty { return repeatHere() }
        guard let plain = Key.char(code, shift: false).map({ Character($0.lowercased()) }),
              Labels.keys(e.cfg.labelKeys).contains(plain) else { return }
        letter(plain, f)
    }

    private func letter(_ c: Character, _ f: CGEventFlags) {
        let next = typed + String(c)
        let hits = labels.indices.filter { labels[$0].hasPrefix(next) }
        guard !hits.isEmpty else { return }
        typed = next
        overlay.update(typed: typed)
        guard let i = hits.first(where: { labels[$0] == typed }) else { return }
        if e.cfg.autoClick { fire(i, ClickMode.kind(f), letter: c) } else { chosen = i; overlay.focus(i) }
    }

    private func backspace() {
        if mode == .search {
            guard !query.isEmpty else { return }
            query.removeLast()
            return refilter()
        }
        guard !typed.isEmpty else { return }
        typed.removeLast()
        chosen = nil
        overlay.focus(nil)
        overlay.update(typed: typed)
    }

    private func confirm(_ kind: ClickKind) {
        if mode == .search, !matches.isEmpty { return fire(matches[focused], kind, letter: nil) }
        if let i = chosen { fire(i, kind, letter: nil) }
    }

    private func move(_ d: Int) {
        guard mode == .search, !matches.isEmpty else { return }
        focused = (focused + d + matches.count) % matches.count
        overlay.focus(focused)
    }

    private func append(_ s: String) {
        query += s
        refilter()
    }

    private func refilter() {
        matches = Array(Labels.search(scan.nodes.map { "\($0.name) \($0.text)" }, query).prefix(40))
        focused = 0
        let items = matches.enumerated().map { Overlay.Item(label: "\($0.offset + 1)", rect: scan.nodes[$0.element].visible) }
        overlay.show(items, theme: Theme.named(e.cfg.theme), size: CGFloat(e.cfg.labelSize), high: scan.mission)
        overlay.focus(matches.isEmpty ? nil : 0)
        overlay.card(query.isEmpty ? "type to search" : "⌕ \(query)   \(matches.count)")
    }

    private func repeatHere() {
        guard let last = e.last, last.scope == scan.scope, let i = ids.firstIndex(of: last.key) else { return flash("No previous click here") }
        fire(i, last.kind, letter: nil)
    }

    // MARK: click

    private func fire(_ i: Int, _ kind: ClickKind, letter: Character?) {
        let n = scan.nodes[i]
        e.recordClick(scope: scan.scope, key: ids[i], label: mode == .search ? "" : labels[i], kind: kind)
        overlay.hide()
        clickedAt = ProcessInfo.processInfo.systemUptime
        Clicker.click(n, kind, restore: e.cfg.restorePointer)
        if e.cfg.sounds { e.sound.play(.click, volume: e.cfg.volume) }
        guard let letter, kind == .left || kind == .right, !scan.mission else { return afterClick() }
        let t = DispatchWorkItem { [weak self] in self?.afterClick() }
        pending = Pending(letter: letter, node: n, kind: kind, timer: t)
        DispatchQueue.main.asyncAfter(deadline: .now() + e.cfg.doubleClickMs / 1000, execute: t)
    }

    // Inside the double-click window: same letter = double-click, anything else ends the mode and passes through.
    private func pendingKey(_ type: CGEventType, _ ev: CGEvent, _ p: Pending) -> Bool {
        guard type == .keyDown else { return type == .keyUp }
        p.timer.cancel()
        pending = nil
        let same = !Key.isRepeat(ev) && Key.char(Key.code(ev), shift: false).map { Character($0.lowercased()) } == p.letter
        if same {
            clickedAt = ProcessInfo.processInfo.systemUptime
            Clicker.click(p.node, p.kind, count: 2, restore: e.cfg.restorePointer)
        }
        afterClick()
        return same
    }

    private func afterClick() {
        pending = nil
        guard e.cfg.chainClicks, !scan.mission else { return exit() }
        typed = ""
        let g = gen
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            guard let self, self.active, self.gen == g else { return }
            self.rescan()
        }
    }

    // A real mouse click or app switch ends the mode; our own synthetic clicks are ignored.
    private func addMonitors() {
        let quiet = { [weak self] in (ProcessInfo.processInfo.systemUptime - (self?.clickedAt ?? 0)) < 0.6 }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { [weak self] _ in
            if !quiet() { self?.exit() }
        }) { monitors.append(m) }
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            if !quiet(), self?.scan.mission == false { self?.exit() }
        })
    }

    static func kind(_ f: CGEventFlags) -> ClickKind {
        if f.contains(.maskShift) { return .right }
        if f.contains(.maskCommand) { return .command }
        if f.contains(.maskAlternate) { return .hover }
        return .left
    }
}
