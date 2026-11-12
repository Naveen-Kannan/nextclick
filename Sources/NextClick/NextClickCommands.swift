import AppKit

// NextClickCommands — plug into hkd:
//   let nextclick = NextClickCommands()
//   daemon.add(name: nextclick.name, commands: nextclick.commands)
//   nextclick.start()   // config watch, AX enabler, Mission Control observer
//   nextclick.stop()    // on shutdown: restores AX flags, flushes history
public final class NextClickCommands {
    public let name = "nextclick"
    private let engine = Engine()

    public init() {}

    public var commands: [String: () -> Void] {
        let e = engine
        return [
            "click.show": { e.click.toggle(.labels) },
            "click.prefetch": { e.click.prefetch() },
            "click.system": { e.click.toggle(.system) },
            "click.search": { e.click.toggle(.search) },
            "click.repeat": { e.click.repeatSilently() },
            "scroll.show": { e.scroll.toggle() },
            "nextclick.reload": { e.reload() },
            "nextclick.clear_history": { e.history.clear(); e.last = nil },
        ]
    }

    public func start() { engine.start() }
    public func stop() { engine.stop() }
}

final class Engine {
    private(set) var cfg = Config()
    let ax = DispatchQueue(label: "com.nkannan.nextclick.ax", qos: .userInteractive)
    // Caps-down prefetch gets its own queue: when Caps turns out to be Hyper (Caps+J scroll,
    // Caps+/ search), those scans must not wait behind a window scan nobody will use.
    let pre = DispatchQueue(label: "com.nkannan.nextclick.prefetch", qos: .userInteractive)
    let history: History
    var last: History.Last?
    lazy var enabler = Enabler(queue: ax) { [unowned self] in self.cfg }
    lazy var sound = Sound()
    lazy var click = ClickMode(self)
    lazy var scroll = ScrollMode(self)
    private let mission = MissionObserver()
    private let configPath: String
    private let watcher: ConfigWatcher

    init(configPath: String = Config.path, historyURL: URL? = History.defaultURL) {
        self.configPath = configPath
        watcher = ConfigWatcher(path: configPath)
        history = History(url: historyURL)
        last = history.file.last
    }

    func start() {
        reload()
        watcher.onChange = { [weak self] in self?.reload() }
        watcher.start()
        enabler.start()
        mission.onOpen = { [weak self] in self?.missionOpened() }
        mission.onClose = { [weak self] in if self?.click.mission == true { self?.click.exit() } }
        mission.start()
        ax.async { _ = Discovery.statusItems() }  // warm the no-status-item cache so the first scan is fast
        click.warm()
        log.notice("nextclick started (config \(self.configPath, privacy: .private))")
    }

    func stop() {
        click.exit()
        scroll.exit()
        mission.stop()
        enabler.stop()
        watcher.stop()
        history.flush()
    }

    func reload() {
        guard let c = Config.load(configPath) else { return }
        if c != cfg { log.notice("config loaded") }
        cfg = c
    }

    // Known Mission Control state, so scans skip the Dock round trip; nil when not observing.
    var missionOpen: Bool? { mission.attached ? mission.open : nil }

    func ignored(_ app: NSRunningApplication) -> Bool {
        app.bundleIdentifier.map(cfg.ignoredApps.contains) ?? false
    }

    // Smart labels off = nothing written to disk; '.' still repeats within this session.
    func recordClick(scope: String, key: String, label: String, kind: ClickKind) {
        last = History.Last(scope: scope, key: key, kind: kind)
        if cfg.smartLabels { history.record(scope: scope, key: key, label: label, kind: kind) }
    }

    private func missionOpened() {
        guard cfg.missionControl, !click.active, !scroll.active else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35) { [weak self] in
            guard let self, !self.click.active else { return }
            self.ax.async {
                guard Discovery.missionRoot() != nil else { return }
                DispatchQueue.main.async { self.click.enter(.labels) }
            }
        }
    }
}
