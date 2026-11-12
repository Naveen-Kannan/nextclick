import AppKit

// AXPress for menus, the Dock, status items and Mission Control; real mouse events elsewhere.
// Native targets get a geometric hit test first (covered -> AXPress); web targets click directly,
// since Chromium hit-tests every point to one page-sized group.
enum Clicker {
    static let queue = DispatchQueue(label: "com.nkannan.nextclick.click", qos: .userInteractive)
    static let pressSources: Set<Source> = [.menu, .menubar, .status, .dock, .mission]

    // Native targets wait a frame so the hit test can't see the just-hidden overlay; others go now.
    static func click(_ n: Node, _ kind: ClickKind, count: Int = 1, restore: Bool) {
        let wait = n.web || pressSources.contains(n.source) ? 0 : 0.012
        queue.asyncAfter(deadline: .now() + wait) { run(n, kind, count: count, restore: restore) }
    }

    private static func run(_ n: Node, _ kind: ClickKind, count: Int, restore: Bool) {
        if pressSources.contains(n.source), count == 1, kind != .hover {
            let action = kind == .right && n.source == .dock ? "AXShowMenu" : "AXPress"
            if AX.perform(n.el, action) { return }
        }
        let p = point(n)
        if kind == .left, count == 1, !n.web, !Discovery.visibleAt(p, n), AX.actions(n.el).contains("AXPress"),
           AX.perform(n.el, "AXPress") { return }
        let back = CGEvent(source: nil)?.location
        mouse(.mouseMoved, p, .left, 0, [])
        guard kind != .hover else { return }
        let (down, up, button): (CGEventType, CGEventType, CGMouseButton) =
            kind == .right ? (.rightMouseDown, .rightMouseUp, .right) : (.leftMouseDown, .leftMouseUp, .left)
        let flags: CGEventFlags = kind == .command ? .maskCommand : []
        // count = click state: a double-click is the earlier click plus one with state 2
        mouse(down, p, button, Int64(max(1, count)), flags)
        usleep(8000)
        mouse(up, p, button, Int64(max(1, count)), flags)
        if restore, let back {
            usleep(30000)
            CGWarpMouseCursorPosition(back)
            CGAssociateMouseAndMouseCursorPosition(1)
        }
    }

    static func point(_ n: Node) -> CGPoint {
        if let p = AX.point(AX.value(n.el, "AXActivationPoint")), n.visible.contains(p) { return p }
        let r = n.visible
        return CGPoint(x: r.midX, y: r.midY)
    }

    private static func mouse(_ t: CGEventType, _ p: CGPoint, _ b: CGMouseButton, _ state: Int64, _ flags: CGEventFlags) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: t, mouseCursorPosition: p, mouseButton: b) else { return }
        if state > 0 { e.setIntegerValueField(.mouseEventClickState, value: state) }
        e.flags = flags
        e.post(tap: .cghidEventTap)
    }
}
