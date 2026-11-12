import AppKit

enum ScrollAction: Equatable {
    case hold(Double, Double)   // unit direction, +y = down
    case page(Double)           // +1 half page down, -1 up
    case top, bottom, next, prev, exit, pending, none
    case select(Int)
}

enum ScrollKeys {
    static func action(char: Character?, code: Int64, shift: Bool, now: Double, lastG: inout Double, keys: String, arrows: Bool) -> ScrollAction {
        switch code {
        case Key.esc: return .exit
        case Key.tab: return shift ? .prev : .next
        case Key.left where arrows: return .hold(-1, 0)
        case Key.right where arrows: return .hold(1, 0)
        case Key.up where arrows: return .hold(0, -1)
        case Key.down where arrows: return .hold(0, 1)
        default: break
        }
        guard let c = char.map({ Character($0.lowercased()) }) else { return .none }
        let k = Array(keys.lowercased())
        if k.count >= 4 {
            if c == k[0] { return .hold(-1, 0) }
            if c == k[1] { return .hold(0, 1) }
            if c == k[2] { return .hold(0, -1) }
            if c == k[3] { return .hold(1, 0) }
        }
        switch c {
        case "d": return .page(1)
        case "u": return .page(-1)
        case "g":
            if shift { return .bottom }
            if now - lastG < 0.5 { lastG = 0; return .top }
            lastG = now
            return .pending
        case "1"..."9": return .select(Int(String(c))! - 1)
        default: return .none
        }
    }
}

// Pointer is warped into the chosen area (scroll events go to whatever is under it),
// then pixel scroll events are posted at ~120 Hz with eased velocity.
final class ScrollMode {
    private unowned let e: Engine
    private let overlay = Overlay()
    private var tap: KeyTap?
    private(set) var active = false
    private var areas: [(AXUIElement, CGRect)] = []
    private var current = 0
    private var held: [Int64: (Double, Double)] = [:]
    private var dash = false
    private var v = (x: 0.0, y: 0.0), carry = (x: 0.0, y: 0.0), jump = (x: 0.0, y: 0.0)
    private var timer: DispatchSourceTimer?
    private var lastTick = 0.0, lastG = 0.0
    private var saved: CGPoint?
    private var idle: DispatchWorkItem?
    private var monitor: Any?
    private var gen = 0

    init(_ e: Engine) { self.e = e }

    func toggle() { active ? exit() : enter() }

    func enter() {
        guard !active, AXIsProcessTrusted(), let app = NSWorkspace.shared.frontmostApplication, !e.ignored(app) else { return }
        e.click.exit()
        let t = KeyTap { [unowned self] type, ev in self.key(type, ev) }
        guard t.start() else { return }
        tap = t
        active = true
        saved = CGEvent(source: nil)?.location
        monitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in self?.exit() }
        gen += 1
        let g = gen, screens = Geo.screens
        e.ax.async { [weak self] in
            let a = Discovery.scrollAreas(app, screens: screens)
            DispatchQueue.main.async {
                guard let self, self.active, self.gen == g else { return }
                self.areas = a
                self.select(0)
            }
        }
        bumpIdle()
    }

    func exit() {
        guard active else { return }
        active = false
        gen += 1
        tap?.stop()
        tap = nil
        timer?.cancel()
        timer = nil
        held = [:]
        v = (0, 0); jump = (0, 0); carry = (0, 0)
        idle?.cancel()
        monitor.map { NSEvent.removeMonitor($0) }
        monitor = nil
        overlay.hide()
        if e.cfg.scroll.restorePointer, let p = saved { CGWarpMouseCursorPosition(p); CGAssociateMouseAndMouseCursorPosition(1) }
        Cursor.show()
    }

    private func select(_ i: Int) {
        guard !areas.isEmpty else {
            overlay.card("Nothing to scroll")
            let g = gen
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.7) { [weak self] in if self?.gen == g { self?.exit() } }
            return
        }
        current = (i + areas.count) % areas.count
        let r = areas[current].1
        CGWarpMouseCursorPosition(CGPoint(x: r.midX, y: r.midY))
        CGAssociateMouseAndMouseCursorPosition(1)
        if e.cfg.hideCursor { Cursor.hide() }
        overlay.areas(areas.map(\.1), active: current, numbers: e.cfg.scroll.numbers, theme: Theme.named(e.cfg.theme))
    }

    private func key(_ type: CGEventType, _ ev: CGEvent) -> Bool {
        guard active else { return false }
        let code = Key.code(ev)
        dash = ev.flags.contains(.maskShift)
        if type == .flagsChanged { return false }
        if type == .keyUp { return held.removeValue(forKey: code) != nil || true }
        guard type == .keyDown else { return false }
        bumpIdle()
        let s = e.cfg.scroll
        let a = ScrollKeys.action(char: Key.char(code, shift: false), code: code, shift: dash, now: ProcessInfo.processInfo.systemUptime,
                                  lastG: &lastG, keys: s.keys, arrows: s.arrows)
        let h = areas.isEmpty ? 600 : areas[current].1.height
        switch a {
        case .exit: exit()
        case .hold(let x, let y): if !Key.isRepeat(ev) { held[code] = (x, y); run() }
        case .page(let d): jump.y += d * h * 0.5; run()
        case .top: edge(0)
        case .bottom: edge(1)
        case .next: select(current + 1)
        case .prev: select(current - 1)
        case .select(let n): if n < areas.count { select(n) }
        case .pending: break
        case .none: exit(); return false  // unknown key: leave scroll mode and let it through
        }
        return true
    }

    // Jump via the scroll bar when it is settable, else a long eased scroll.
    private func edge(_ value: Double) {
        if !areas.isEmpty, let bar = AX.element(areas[current].0, "AXVerticalScrollBar"),
           AX.set(bar, "AXValue", value as CFNumber) == .success { return }
        jump.y += value == 0 ? -200_000 : 200_000
        run()
    }

    private func run() {
        guard timer == nil else { return }
        lastTick = ProcessInfo.processInfo.systemUptime
        let t = DispatchSource.makeTimerSource(queue: .main)
        t.schedule(deadline: .now(), repeating: 1.0 / 120, leeway: .milliseconds(1))
        t.setEventHandler { [weak self] in self?.tick() }
        timer = t
        t.resume()
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime, dt = min(0.05, now - lastTick)
        lastTick = now
        let target = held.values.reduce((0.0, 0.0)) { ($0.0 + $1.0, $0.1 + $1.1) }
        let speed = e.cfg.scroll.speed * (dash ? e.cfg.scroll.dash : 1), k = min(1, dt * 16)
        v.x += (target.0 * speed - v.x) * k
        v.y += (target.1 * speed - v.y) * k
        let ease = 1 - pow(0.78, dt * 120)
        var jx = jump.x * ease, jy = jump.y * ease
        if abs(jump.x - jx) < 1 { jx = jump.x }
        if abs(jump.y - jy) < 1 { jy = jump.y }
        jump.x -= jx
        jump.y -= jy
        post(v.x * dt + jx, v.y * dt + jy)
        if held.isEmpty, abs(v.x) < 3, abs(v.y) < 3, jump == (0, 0) {
            v = (0, 0)
            timer?.cancel()
            timer = nil
        }
    }

    private func post(_ dx: Double, _ dy: Double) {
        carry.x += dx
        carry.y += dy
        let ix = Int32(carry.x.rounded(.towardZero)), iy = Int32(carry.y.rounded(.towardZero))
        guard ix != 0 || iy != 0 else { return }
        carry.x -= Double(ix)
        carry.y -= Double(iy)
        CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -iy, wheel2: -ix, wheel3: 0)?.post(tap: .cghidEventTap)
    }

    private func bumpIdle() {
        idle?.cancel()
        let s = e.cfg.scroll.idleExit
        guard s > 0 else { return }
        let w = DispatchWorkItem { [weak self] in self?.exit() }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + s, execute: w)
    }
}
