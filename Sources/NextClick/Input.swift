import AppKit
import Carbon.HIToolbox

// Session-level key tap, installed only while a mode is active. Placed at the head,
// so it sees keys before hkd's own tap and can swallow them.
final class KeyTap {
    typealias Handler = (CGEventType, CGEvent) -> Bool  // true = swallow
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private let handler: Handler

    init(_ handler: @escaping Handler) { self.handler = handler }

    func start() -> Bool {
        let mask = CGEventMask((1 << CGEventType.keyDown.rawValue) | (1 << CGEventType.keyUp.rawValue) | (1 << CGEventType.flagsChanged.rawValue))
        tap = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap, eventsOfInterest: mask,
                                callback: { _, type, event, refcon in
                                    let me = Unmanaged<KeyTap>.fromOpaque(refcon!).takeUnretainedValue()
                                    return me.handle(type, event)
                                }, userInfo: Unmanaged.passUnretained(self).toOpaque())
        guard let tap else { log.error("key tap creation failed"); return false }
        source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        return true
    }

    func stop() {
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes) }
        tap = nil
        source = nil
    }

    private func handle(_ type: CGEventType, _ e: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            return Unmanaged.passUnretained(e)
        }
        return handler(type, e) ? nil : Unmanaged.passUnretained(e)
    }
}

enum Key {
    static let esc: Int64 = 53, ret: Int64 = 36, enter: Int64 = 76, tab: Int64 = 48, space: Int64 = 49
    static let del: Int64 = 51, fwdDel: Int64 = 117, left: Int64 = 123, right: Int64 = 124, down: Int64 = 125, up: Int64 = 126

    static func code(_ e: CGEvent) -> Int64 { e.getIntegerValueField(.keyboardEventKeycode) }
    static func isRepeat(_ e: CGEvent) -> Bool { e.getIntegerValueField(.keyboardEventAutorepeat) != 0 }

    private static var plain: [Int64: Character] = [:]
    private static var shifted: [Int64: Character] = [:]
    private static var layoutID = ""

    // Characters from the current ASCII-capable layout, so labels follow QWERTY/Dvorak/Colemak and ignore IMEs.
    static func char(_ code: Int64, shift: Bool) -> Character? {
        refreshIfNeeded()
        return shift ? shifted[code] : plain[code]
    }

    private static func refreshIfNeeded() {
        guard let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource()?.takeRetainedValue() else { return }
        let id = prop(src, kTISPropertyInputSourceID).map { Unmanaged<CFString>.fromOpaque($0).takeUnretainedValue() as String } ?? ""
        guard id != layoutID || plain.isEmpty, let raw = prop(src, kTISPropertyUnicodeKeyLayoutData) else { return }
        let data = Unmanaged<CFData>.fromOpaque(raw).takeUnretainedValue() as Data
        layoutID = id
        plain = [:]
        shifted = [:]
        data.withUnsafeBytes { buf in
            guard let layout = buf.baseAddress?.assumingMemoryBound(to: UCKeyboardLayout.self) else { return }
            for code in 0..<128 {
                if let c = translate(layout, UInt16(code), 0) { plain[Int64(code)] = c }
                if let c = translate(layout, UInt16(code), UInt32(shiftKey >> 8) & 0xFF) { shifted[Int64(code)] = c }
            }
        }
    }

    private static func prop(_ src: TISInputSource, _ key: CFString) -> UnsafeMutableRawPointer? {
        TISGetInputSourceProperty(src, key)
    }

    private static func translate(_ layout: UnsafePointer<UCKeyboardLayout>, _ code: UInt16, _ mods: UInt32) -> Character? {
        var dead: UInt32 = 0, len = 0
        var chars = [UniChar](repeating: 0, count: 4)
        let st = UCKeyTranslate(layout, code, UInt16(kUCKeyActionDown), mods, UInt32(LMGetKbdType()),
                                OptionBits(kUCKeyTranslateNoDeadKeysBit), &dead, chars.count, &len, &chars)
        guard st == noErr, len == 1, let s = String(utf16CodeUnits: chars, count: len).first, !s.isWhitespace, s.isASCII else { return nil }
        return s
    }
}

// Hide the pointer while labels are up. hkd is a background process, so this needs the
// SetsCursorInBackground connection property (private, looked up at runtime; no-op if missing).
enum Cursor {
    private static var hidden = false
    private typealias ConnFn = @convention(c) () -> Int32
    private typealias SetFn = @convention(c) (Int32, Int32, CFString, CFTypeRef) -> Int32
    private static let enabled: Bool = {
        let all = UnsafeMutableRawPointer(bitPattern: -2)  // RTLD_DEFAULT
        guard let c = dlsym(all, "CGSMainConnectionID") ?? dlsym(all, "CGSDefaultConnectionForThread"),
              let s = dlsym(all, "CGSSetConnectionProperty") else { return false }
        let cid = unsafeBitCast(c, to: ConnFn.self)()
        return unsafeBitCast(s, to: SetFn.self)(cid, cid, "SetsCursorInBackground" as CFString, kCFBooleanTrue) == 0
    }()

    static func hide() {
        guard !hidden, enabled else { return }
        CGDisplayHideCursor(CGMainDisplayID())
        hidden = true
    }

    static func show() {
        guard hidden else { return }
        CGDisplayShowCursor(CGMainDisplayID())
        hidden = false
    }
}
