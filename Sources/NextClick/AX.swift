import AppKit
import ApplicationServices

// Thin AXUIElement wrappers. Every call is an IPC round trip to the target app.
enum AX {
    static func value(_ e: AXUIElement, _ a: String) -> CFTypeRef? {
        var r: CFTypeRef?
        return AXUIElementCopyAttributeValue(e, a as CFString, &r) == .success ? r : nil
    }

    static func string(_ e: AXUIElement, _ a: String) -> String? { value(e, a) as? String }
    static func bool(_ e: AXUIElement, _ a: String) -> Bool? { value(e, a) as? Bool }

    static func element(_ e: AXUIElement, _ a: String) -> AXUIElement? { asElement(value(e, a)) }

    static func asElement(_ v: CFTypeRef?) -> AXUIElement? {
        guard let v, CFGetTypeID(v) == AXUIElementGetTypeID() else { return nil }
        return (v as! AXUIElement)
    }

    static func elements(_ e: AXUIElement, _ a: String, max: Int = 4000) -> [AXUIElement] {
        var r: CFArray?
        guard AXUIElementCopyAttributeValues(e, a as CFString, 0, max, &r) == .success else { return [] }
        return (r as? [AXUIElement]) ?? []
    }

    // Batched fetch; missing attributes come back as nil.
    static func multiple(_ e: AXUIElement, _ attrs: [String]) -> [CFTypeRef?] {
        var r: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(e, attrs as CFArray, [], &r) == .success,
              let arr = r as [AnyObject]?, arr.count == attrs.count else { return Array(repeating: nil, count: attrs.count) }
        return arr.map { v in
            if CFGetTypeID(v) == AXValueGetTypeID(), AXValueGetType(v as! AXValue) == .axError { return nil }
            return v as CFTypeRef
        }
    }

    static func point(_ v: CFTypeRef?) -> CGPoint? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero
        return AXValueGetValue(v as! AXValue, .cgPoint, &p) ? p : nil
    }

    static func size(_ v: CFTypeRef?) -> CGSize? {
        guard let v, CFGetTypeID(v) == AXValueGetTypeID() else { return nil }
        var s = CGSize.zero
        return AXValueGetValue(v as! AXValue, .cgSize, &s) ? s : nil
    }

    static func frame(_ e: AXUIElement) -> CGRect? {
        let v = multiple(e, ["AXPosition", "AXSize"])
        guard let p = point(v[0]), let s = size(v[1]) else { return nil }
        return CGRect(origin: p, size: s)
    }

    static func actions(_ e: AXUIElement) -> [String] {
        var r: CFArray?
        guard AXUIElementCopyActionNames(e, &r) == .success else { return [] }
        return (r as? [String]) ?? []
    }

    @discardableResult
    static func perform(_ e: AXUIElement, _ action: String) -> Bool {
        AXUIElementPerformAction(e, action as CFString) == .success
    }

    @discardableResult
    static func set(_ e: AXUIElement, _ a: String, _ v: CFTypeRef) -> AXError {
        AXUIElementSetAttributeValue(e, a as CFString, v)
    }

    static func parameterized(_ e: AXUIElement, _ a: String, _ p: CFTypeRef) -> CFTypeRef? {
        var r: CFTypeRef?
        return AXUIElementCopyParameterizedAttributeValue(e, a as CFString, p, &r) == .success ? r : nil
    }

    static func app(_ pid: pid_t, timeout: Float = 0.3) -> AXUIElement {
        let e = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(e, timeout)
        return e
    }

    private static let system: AXUIElement = {
        let s = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(s, 0.1)
        return s
    }()

    static func hit(_ p: CGPoint) -> AXUIElement? {
        var r: AXUIElement?
        return AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &r) == .success ? r : nil
    }

    static func same(_ a: AXUIElement, _ b: AXUIElement) -> Bool { CFEqual(a, b) }
}

// AX space: origin at the primary screen's top-left, y down. Cocoa: bottom-left, y up.
enum Geo {
    static var primaryHeight: CGFloat { NSScreen.screens.first?.frame.height ?? 0 }

    static func ax(_ cocoa: CGRect, ph: CGFloat = primaryHeight) -> CGRect {
        CGRect(x: cocoa.minX, y: ph - cocoa.maxY, width: cocoa.width, height: cocoa.height)
    }

    static var screens: [CGRect] { NSScreen.screens.map { ax($0.frame) } }

    static func onScreen(_ r: CGRect, _ screens: [CGRect]) -> Bool {
        screens.contains { $0.intersects(r) }
    }
}
