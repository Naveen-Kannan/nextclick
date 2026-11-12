import AppKit
import QuartzCore

struct Theme {
    let top: CGColor, bottom: CGColor, text: CGColor, typed: CGColor, border: CGColor, ring: CGColor
    var radius: CGFloat = 5
    var accent: CGColor? = nil
    var hi: CGColor { accent ?? top }  // scroll-area outline, card border

    static var dark: Bool {
        if let app = NSApp { return app.effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }
        return UserDefaults.standard.string(forKey: "AppleInterfaceStyle") == "Dark"
    }

    private static func flat(_ bg: UInt32, text: UInt32, accent: UInt32, ring: UInt32, radius: CGFloat) -> Theme {
        Theme(top: rgb(bg), bottom: rgb(bg), text: rgb(text), typed: rgb(accent), border: rgb(accent), ring: rgb(ring), radius: radius, accent: rgb(accent))
    }

    // codex = the user's Codex palette: Solarized (light) / Gruvbox (dark), following the system.
    static func named(_ n: String, dark: Bool = Theme.dark) -> Theme {
        switch n {
        case "codex", "solarized", "gruvbox":
            return (n == "gruvbox" || (n == "codex" && dark))
                ? flat(0x282828, text: 0xEBDBB2, accent: 0x458588, ring: 0xFABD2F, radius: 4)
                : flat(0xFDF6E3, text: 0x073642, accent: 0xB58900, ring: 0x268BD2, radius: 4)
        case "claude":
            return dark ? flat(0x262624, text: 0xF5F4EE, accent: 0xD97757, ring: 0xF5F4EE, radius: 6)
                        : flat(0xFAF9F5, text: 0x141413, accent: 0xD97757, ring: 0x141413, radius: 6)
        case "classic":
            return Theme(top: rgb(0xFFE066), bottom: rgb(0xFCC419), text: rgb(0x1A1A1A), typed: rgb(0x1A1A1A, 0.4),
                         border: rgb(0xB08900, 0.7), ring: rgb(0x1A1A1A), radius: 3)
        case "midnight":
            return Theme(top: rgb(0x2E3038), bottom: rgb(0x1C1D22), text: rgb(0x63E6BE), typed: rgb(0x63E6BE, 0.35),
                         border: rgb(0x63E6BE, 0.25), ring: rgb(0x63E6BE))
        case "frost":
            return Theme(top: rgb(0xFFFFFF, 0.92), bottom: rgb(0xF1F3F5, 0.86), text: rgb(0x212529), typed: rgb(0x212529, 0.35),
                         border: rgb(0x000000, 0.12), ring: rgb(0x339AF0), radius: 6)
        default:  // sunset
            return Theme(top: rgb(0xFF8A5B), bottom: rgb(0xFF4F6D), text: rgb(0xFFFFFF), typed: rgb(0xFFFFFF, 0.45),
                         border: rgb(0xFFFFFF, 0.35), ring: rgb(0xFFF3BF))
        }
    }
}

private func rgb(_ hex: UInt32, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat(hex >> 16 & 0xFF) / 255, green: CGFloat(hex >> 8 & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: a)
}

// Transparent click-through panels, one per screen. Math stays in AX space (top-left, y down);
// toLayer() converts at placement because AppKit resets geometryFlipped on window layers.
final class Overlay {
    struct Item { let label: String; let rect: CGRect }

    private final class Badge {
        let root = CALayer(), bg = CAGradientLayer(), text = CATextLayer()
        let label: String
        var frame = CGRect.zero
        var screen = 0
        init(_ label: String) { self.label = label }
    }

    private var panels: [NSPanel] = []
    private var screenRects: [CGRect] = []
    private var badges: [Badge] = []
    private var clusters: [[Int]] = []
    private var rotation = 0
    private var theme = Theme.named("sunset")
    private var size: CGFloat = 12
    private var extra: [CALayer] = []
    private var cardLayer: CALayer?

    var visible: Bool { panels.contains { $0.isVisible } }

    // First show pays ~90 ms for panel creation and CoreAnimation/CoreText setup; do it at startup.
    func warm(theme: Theme, size: CGFloat) {
        prepare(high: false)
        self.theme = theme
        self.size = size
        let b = Badge("as")
        build(b, font: Overlay.font(size), typed: 0)
        layer(0).addSublayer(b.root)
        panels.forEach { $0.alphaValue = 0; $0.orderFrontRegardless() }
        CATransaction.flush()
        DispatchQueue.main.async { [weak self] in
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            b.root.removeFromSuperlayer()
            CATransaction.commit()
            self?.panels.forEach { $0.orderOut(nil); $0.alphaValue = 1 }
        }
    }

    // MARK: labels

    func show(_ items: [Item], theme: Theme, size: CGFloat, high: Bool = false) {
        prepare(high: high)
        self.theme = theme
        self.size = size
        clearLabels()
        let font = Overlay.font(size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for it in items {
            let b = Badge(it.label)
            b.screen = screenIndex(it.rect)
            build(b, font: font, typed: 0)
            place(b, near: it.rect.offsetBy(dx: -screenRects[b.screen].minX, dy: -screenRects[b.screen].minY))
            layer(b.screen).addSublayer(b.root)
            badges.append(b)
        }
        CATransaction.commit()
        clusters = Overlay.clusters(badges.map(\.frame), badges.map(\.screen))
        rotation = 0
        applyRotation()
        order(true)
    }

    func update(typed: String) {
        let font = Overlay.font(size)
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for b in badges {
            let hit = b.label.hasPrefix(typed)
            b.root.isHidden = !hit
            if hit { b.text.string = attributed(b.label, typed: typed.count, font: font) }
        }
        CATransaction.commit()
    }

    func only(_ visible: Set<Int>) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (i, b) in badges.enumerated() { b.root.isHidden = !visible.contains(i) }
        CATransaction.commit()
    }

    func focus(_ i: Int?) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for (k, b) in badges.enumerated() {
            let on = k == i
            b.bg.borderWidth = on ? 2 : 1
            b.bg.borderColor = on ? theme.ring : theme.border
            b.root.zPosition = on ? 10 : b.root.zPosition
            b.root.transform = on ? CATransform3DMakeScale(1.15, 1.15, 1) : CATransform3DIdentity
        }
        CATransaction.commit()
    }

    // Space: bring the next badge of each overlapping cluster to the front.
    func rotate() {
        rotation += 1
        applyRotation()
    }

    func hide() {
        order(false)
        clearLabels()
        clearExtra()
        card(nil)
    }

    // MARK: cards and areas

    func card(_ text: String?, center: Bool = false) {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        cardLayer?.removeFromSuperlayer()
        cardLayer = nil
        guard let text, !text.isEmpty else { return }
        prepare(high: false)
        let i = mainIndex(), bounds = CGRect(origin: .zero, size: screenRects[i].size)
        let t = CATextLayer()
        t.string = NSAttributedString(string: text, attributes: [
            .font: center ? NSFont.monospacedSystemFont(ofSize: 13, weight: .medium) : Overlay.font(15),
            .foregroundColor: NSColor.white])
        t.contentsScale = scale(i)
        let sz = (t.string as! NSAttributedString).size()
        let pad: CGFloat = 14, w = ceil(sz.width) + pad * 2, h = ceil(sz.height) + pad * 1.4
        let box = CALayer()
        box.backgroundColor = rgb(0x111214, 0.88)
        box.cornerRadius = 10
        box.borderColor = theme.hi
        box.borderWidth = 1.5
        box.frame = toLayer(CGRect(x: bounds.midX - w / 2, y: center ? bounds.midY - h / 2 : bounds.maxY * 0.8 - h / 2, width: w, height: h), i)
        t.frame = CGRect(x: pad, y: pad * 0.7, width: ceil(sz.width), height: ceil(sz.height))
        box.addSublayer(t)
        box.zPosition = 100
        layer(i).addSublayer(box)
        cardLayer = box
        order(true)
    }

    func areas(_ rects: [CGRect], active: Int, numbers: Bool, theme: Theme) {
        prepare(high: false)
        self.theme = theme
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        defer { CATransaction.commit() }
        clearExtra()
        let font = Overlay.font(13)
        for (k, r) in rects.enumerated() {
            let s = screenIndex(r), local = r.offsetBy(dx: -screenRects[s].minX, dy: -screenRects[s].minY)
            let box = CALayer()
            box.frame = toLayer(local.insetBy(dx: 2, dy: 2), s)
            box.borderColor = k == active ? theme.hi : theme.hi.copy(alpha: 0.35)
            box.borderWidth = k == active ? 3 : 1.5
            box.cornerRadius = 8
            box.backgroundColor = k == active ? theme.hi.copy(alpha: 0.05) : nil
            layer(s).addSublayer(box)
            extra.append(box)
            guard numbers, rects.count > 1 else { continue }
            let b = Badge("\(k + 1)")
            b.screen = s
            build(b, font: font, typed: 0)
            b.root.frame = toLayer(CGRect(origin: CGPoint(x: local.minX + 8, y: local.minY + 8), size: b.root.frame.size), s)
            layer(s).addSublayer(b.root)
            extra.append(b.root)
        }
        order(true)
    }

    // MARK: internals

    private func build(_ b: Badge, font: NSFont, typed: Int) {
        let s = attributed(b.label, typed: typed, font: font), sz = s.size()
        let px = ceil(size * 0.42), py = ceil(size * 0.14)
        let h = ceil(sz.height) + py * 2, w = max(h, ceil(sz.width) + px * 2)
        b.root.frame = CGRect(x: 0, y: 0, width: w, height: h)
        b.root.shadowColor = CGColor(gray: 0, alpha: 1)
        b.root.shadowOpacity = 0.35
        b.root.shadowRadius = 2
        b.root.shadowOffset = CGSize(width: 0, height: 1)
        b.root.shadowPath = CGPath(roundedRect: b.root.bounds, cornerWidth: theme.radius, cornerHeight: theme.radius, transform: nil)
        b.bg.frame = b.root.bounds
        b.bg.colors = [theme.top, theme.bottom]
        b.bg.cornerRadius = theme.radius
        b.bg.borderWidth = 1
        b.bg.borderColor = theme.border
        b.text.string = s
        b.text.alignmentMode = .center
        b.text.contentsScale = scale(b.screen)
        b.text.frame = CGRect(x: 0, y: py, width: w, height: ceil(sz.height))
        b.root.addSublayer(b.bg)
        b.root.addSublayer(b.text)
    }

    private func place(_ b: Badge, near r: CGRect) {
        let w = b.root.frame.width, h = b.root.frame.height, bounds = CGRect(origin: .zero, size: screenRects[b.screen].size)
        var x = r.width > w * 2.2 ? r.minX + 2 : r.midX - w / 2
        var y = r.midY - h / 2
        x = min(max(x, bounds.minX + 1), bounds.maxX - w - 1)
        y = min(max(y, bounds.minY + 1), bounds.maxY - h - 1)
        b.frame = CGRect(x: round(x), y: round(y), width: w, height: h)
        b.root.frame = toLayer(b.frame, b.screen)
    }

    private func attributed(_ label: String, typed: Int, font: NSFont) -> NSAttributedString {
        let s = NSMutableAttributedString(string: label.uppercased(), attributes: [.font: font, .kern: 0.4, .foregroundColor: NSColor(cgColor: theme.text)!])
        if typed > 0 { s.addAttribute(.foregroundColor, value: NSColor(cgColor: theme.typed)!, range: NSRange(location: 0, length: min(typed, label.count))) }
        return s
    }

    private func applyRotation() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        for c in clusters {
            for (k, i) in c.enumerated() { badges[i].root.zPosition = k == rotation % c.count ? 2 : 1 }
        }
        CATransaction.commit()
    }

    private func clearLabels() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        badges.forEach { $0.root.removeFromSuperlayer() }
        CATransaction.commit()
        badges = []
        clusters = []
    }

    private func clearExtra() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        extra.forEach { $0.removeFromSuperlayer() }
        CATransaction.commit()
        extra = []
    }

    private func prepare(high: Bool) {
        let rects = Geo.screens
        let level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(high ? .cursorWindow : .assistiveTechHighWindow)) - (high ? 1 : 0))
        if rects == screenRects, panels.count == rects.count {
            panels.forEach { $0.level = level }
            return
        }
        panels.forEach { $0.orderOut(nil) }
        panels = NSScreen.screens.map { s in
            let p = NSPanel(contentRect: s.frame, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            p.level = level
            p.backgroundColor = .clear
            p.isOpaque = false
            p.hasShadow = false
            p.ignoresMouseEvents = true
            p.isReleasedWhenClosed = false
            p.animationBehavior = .none  // labels appear in the same frame, no window-appear animation
            p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
            let v = NSView(frame: CGRect(origin: .zero, size: s.frame.size))
            v.wantsLayer = true
            p.contentView = v
            p.setFrame(s.frame, display: false)
            return p
        }
        screenRects = rects
    }

    private func order(_ on: Bool) {
        panels.forEach { on ? $0.orderFrontRegardless() : $0.orderOut(nil) }
    }

    private func layer(_ i: Int) -> CALayer { panels[i].contentView!.layer! }
    private func toLayer(_ r: CGRect, _ i: Int) -> CGRect { Overlay.toLayer(r, height: screenRects[i].height) }

    // AX-local (top-left origin) -> layer (bottom-left origin).
    static func toLayer(_ r: CGRect, height: CGFloat) -> CGRect {
        CGRect(x: r.minX, y: height - r.maxY, width: r.width, height: r.height)
    }
    private func scale(_ i: Int) -> CGFloat { NSScreen.screens.indices.contains(i) ? NSScreen.screens[i].backingScaleFactor : 2 }

    private func screenIndex(_ r: CGRect) -> Int {
        let c = CGPoint(x: r.midX, y: r.midY)
        return screenRects.firstIndex { $0.contains(c) } ?? screenRects.indices.max {
            screenRects[$0].intersection(r).width * screenRects[$0].intersection(r).height
                < screenRects[$1].intersection(r).width * screenRects[$1].intersection(r).height
        } ?? 0
    }

    private func mainIndex() -> Int {
        guard let m = NSScreen.main, let i = NSScreen.screens.firstIndex(of: m), i < panels.count else { return 0 }
        return i
    }

    static func font(_ size: CGFloat) -> NSFont {
        let base = NSFont.systemFont(ofSize: size, weight: .bold)
        guard let d = base.fontDescriptor.withDesign(.rounded) else { return base }
        return NSFont(descriptor: d, size: size) ?? base
    }

    // Union-find over overlapping badge frames on the same screen.
    static func clusters(_ frames: [CGRect], _ screens: [Int]) -> [[Int]] {
        var parent = Array(frames.indices)
        func find(_ x: Int) -> Int { var x = x; while parent[x] != x { parent[x] = parent[parent[x]]; x = parent[x] }; return x }
        let order = frames.indices.sorted { frames[$0].minX < frames[$1].minX }
        for (a, i) in order.enumerated() {
            for j in order[(a + 1)...] {
                if frames[j].minX > frames[i].maxX { break }
                if screens[i] == screens[j], frames[i].intersects(frames[j]) { parent[find(i)] = find(j) }
            }
        }
        var groups: [Int: [Int]] = [:]
        for i in frames.indices { groups[find(i), default: []].append(i) }
        return groups.values.filter { $0.count > 1 }.map { $0.sorted() }
    }
}
