import AppKit
import AVFoundation

// Chromium/Electron only build an AX tree when asked. We flip the flag on activation and
// flip it back on exit.
final class Enabler {
    private var touched: [pid_t: [String]] = [:]
    private var enabledAt: [pid_t: Double] = [:]
    private var cache: [String: [String]] = [:]   // bundle path -> attributes to try, in order
    private var observers: [NSObjectProtocol] = []
    private let queue: DispatchQueue
    private let cfg: () -> Config

    static let experimental: Set = ["org.mozilla.firefox", "org.mozilla.nightly", "org.mozilla.firefoxdeveloperedition",
                                    "app.zen-browser.zen", "com.spotify.client"]
    static let chromiumIDs = ["com.google.Chrome", "com.microsoft.edgemac", "com.brave.Browser", "company.thebrowser.",
                              "com.vivaldi.", "com.operasoftware.", "org.chromium.", "ai.perplexity.comet"]

    init(queue: DispatchQueue, cfg: @escaping () -> Config) {
        self.queue = queue
        self.cfg = cfg
    }

    func start() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.ensure(app) }
        })
        observers.append(nc.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
            if let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication { self?.touched[app.processIdentifier] = nil }
        })
        if let app = NSWorkspace.shared.frontmostApplication { ensure(app) }
    }

    func stop() {
        observers.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        observers = []
        restoreAll()
    }

    // true if the flag was just turned on (the app needs a moment to build its tree).
    @discardableResult
    func ensure(_ app: NSRunningApplication) -> Bool {
        let c = cfg(), pid = app.processIdentifier
        let attrs = attributes(app, experimental: c.experimentalAx)
        guard c.enableAx, touched[pid] == nil, !attrs.isEmpty,
              !(app.bundleIdentifier.map(c.ignoredApps.contains) ?? false) else { return false }
        touched[pid] = attrs
        enabledAt[pid] = ProcessInfo.processInfo.systemUptime
        let id = app.bundleIdentifier ?? "?"
        // Result codes lie here (apps apply the write and still report NotImplemented), so read back.
        queue.async {
            let el = AX.app(pid)
            var done: String?
            for a in attrs {
                AX.set(el, a, kCFBooleanTrue)
                if AX.bool(el, a) == true { done = a; break }
            }
            log.notice("\(done == nil ? "set (unverified)" : "enabled", privacy: .public) \(done ?? attrs.joined(separator: "+"), privacy: .public) for \(id, privacy: .public)")
            // Chromium builds its tree lazily; touch the window (off the serial scan queue) so the
            // first real scan finds it ready.
            DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 0.15) {
                if let w = AX.element(el, "AXFocusedWindow") { AX.elements(w, "AXChildren").forEach { _ = AX.elements($0, "AXChildren") } }
            }
        }
        return true
    }

    // Chromium/Electron fill in their tree for a second or two after the flag flips.
    func warming(_ pid: pid_t) -> Bool {
        enabledAt[pid].map { ProcessInfo.processInfo.systemUptime - $0 < 3 } ?? false
    }

    func restoreAll() {
        for (pid, attrs) in touched { attrs.forEach { AX.set(AX.app(pid, timeout: 0.2), $0, kCFBooleanFalse) } }
        touched = [:]
    }

    private func attributes(_ app: NSRunningApplication, experimental: Bool) -> [String] {
        let id = app.bundleIdentifier ?? ""
        if experimental, Enabler.experimental.contains(id) { return [Enabler.enhanced] }
        guard let url = app.bundleURL else { return [] }
        if let hit = cache[url.path] { return hit }
        let a = Enabler.classify(bundleID: id, frameworks: (try? FileManager.default.contentsOfDirectory(atPath: url.appendingPathComponent("Contents/Frameworks").path)) ?? [])
        cache[url.path] = a
        return a
    }

    static let manual = "AXManualAccessibility", enhanced = "AXEnhancedUserInterface"

    // Attributes to try in order. Electron and renamed Chromium shells (e.g. "Codex Framework")
    // take the side-effect-free AXManualAccessibility; Chrome-family browsers need enhanced UI.
    static func classify(bundleID: String, frameworks: [String]) -> [String] {
        if frameworks.contains("Electron Framework.framework") { return [manual] }
        if chromiumIDs.contains(where: { bundleID.hasPrefix($0) }) { return [enhanced] }
        if frameworks.contains(where: { $0.contains("Chromium") || $0.hasSuffix(" Framework.framework") }) { return [manual, enhanced] }
        return []
    }
}

// Dock posts private AXExpose* notifications when Mission Control opens/closes.
final class MissionObserver {
    var onOpen: (() -> Void)?
    var onClose: (() -> Void)?
    private(set) var open = false
    var attached: Bool { observer != nil }
    private var observer: AXObserver?
    private var launch: NSObjectProtocol?
    static let opens = ["AXExposeShowAllWindows", "AXExposeShowFrontWindows", "AXExposeShowDesktop"]
    static let exit = "AXExposeExit"

    func start() {
        attach()
        launch = NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didLaunchApplicationNotification, object: nil, queue: .main) { [weak self] n in
            let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            if app?.bundleIdentifier == "com.apple.dock" { self?.attach() }
        }
    }

    func stop() {
        detach()
        launch.map { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        launch = nil
    }

    private func attach() {
        detach()
        guard let dock = Discovery.dockApp() else { return }
        var obs: AXObserver?
        let cb: AXObserverCallback = { _, _, name, refcon in
            guard let refcon else { return }
            let me = Unmanaged<MissionObserver>.fromOpaque(refcon).takeUnretainedValue()
            me.open = (name as String) != MissionObserver.exit
            me.open ? me.onOpen?() : me.onClose?()
        }
        guard AXObserverCreate(dock.processIdentifier, cb, &obs) == .success, let obs else { return }
        let el = AXUIElementCreateApplication(dock.processIdentifier)
        let me = Unmanaged.passUnretained(self).toOpaque()
        for n in MissionObserver.opens + [MissionObserver.exit] { AXObserverAddNotification(obs, el, n as CFString, me) }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        observer = obs
    }

    private func detach() {
        guard let o = observer else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(o), .defaultMode)
        observer = nil
        open = false
    }
}

// Two tiny synthesized sounds; the engine runs only while playing.
final class Sound {
    enum Effect: CaseIterable { case open, click }
    private let engine = AVAudioEngine(), player = AVAudioPlayerNode()
    private let format = AVAudioFormat(standardFormatWithSampleRate: 44100, channels: 1)!
    private var buffers: [Effect: AVAudioPCMBuffer] = [:]
    private var idle: DispatchWorkItem?

    init() {
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        for e in Effect.allCases { buffers[e] = buffer(Sound.samples(e, rate: format.sampleRate)) }
    }

    func play(_ e: Effect, volume: Double) {
        guard let b = buffers[e] else { return }
        if !engine.isRunning { try? engine.start() }
        guard engine.isRunning else { return }
        player.volume = Float(max(0, min(1, volume)))
        player.scheduleBuffer(b, at: nil, options: .interrupts)
        if !player.isPlaying { player.play() }
        idle?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.player.stop(); self?.engine.stop() }
        idle = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: w)
    }

    private func buffer(_ s: [Float]) -> AVAudioPCMBuffer? {
        guard let b = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(s.count)) else { return nil }
        b.frameLength = AVAudioFrameCount(s.count)
        s.withUnsafeBufferPointer { b.floatChannelData![0].update(from: $0.baseAddress!, count: s.count) }
        return b
    }

    static func samples(_ e: Effect, rate: Double) -> [Float] {
        var rng = SystemRandomNumberGenerator()
        switch e {
        case .open:  // rising chirp
            let n = Int(rate * 0.055)
            var phase = 0.0
            return (0..<n).map { (i: Int) -> Float in
                let t = Double(i) / rate
                let f: Double = 740 + 440 * t / 0.055
                phase += 2 * Double.pi * f / rate
                let tone: Double = sin(phase) + 0.25 * sin(2 * phase)
                let env: Double = min(1, t / 0.003) * exp(-t / 0.016)
                return Float(tone * env * 0.45)
            }
        case .click:  // short tick
            let n = Int(rate * 0.025)
            return (0..<n).map { (i: Int) -> Float in
                let t = Double(i) / rate
                let noise: Double = Double.random(in: -1...1, using: &rng) * exp(-t / 0.0025) * 0.5
                let tone: Double = sin(2 * Double.pi * 2400 * t) * exp(-t / 0.005) * 0.3
                return Float(noise + tone)
            }
        }
    }
}

enum Help {
    static let text = """
    nextclick
    ─────────────────────────────────────
    letters        click the label
    ⇧ last letter  right-click
    ⌘ last letter  ⌘-click (new tab)
    ⌥ last letter  move pointer (hover)
    letter again   double-click
    .              repeat last click here
    space          cycle overlapping labels
    ⌫              undo a letter
    esc            close
    scroll mode    hjkl · ⇧ fast · d/u · gg/G · tab · 1-9
    """
}
