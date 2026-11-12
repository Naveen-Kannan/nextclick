import Foundation
import os

let log = Logger(subsystem: "com.nkannan.nextclick", category: "nextclick")

// ~/.config/nextclick/config.json (or $NEXTCLICK_CONFIG). Every key is optional; snake_case in JSON.
public struct Config: Codable, Equatable {
    var theme = "codex"                  // codex (Solarized/Gruvbox by appearance) | claude | sunset | classic | midnight | frost
    var labelKeys = "ASDFJKLEWRUIO"
    var labelSize: Double = 12
    var smartLabels = true               // frequent targets get short, stable labels; off = no history writes
    var autoClick = true                 // click as soon as a label is complete
    var chainClicks = false              // re-show labels after each click until Esc
    var doubleClickMs: Double = 280      // retype the last letter within this window = double-click
    var restorePointer = false           // move the pointer back after a click
    var hideCursor = true
    var sounds = false
    var volume: Double = 0.35
    var menubar = true
    var statusItems = true
    var dock = true
    var missionControl = true            // auto-label Mission Control
    var enableAx = true                  // turn on AX trees in Chromium/Electron apps (restored on exit)
    var experimentalAx = false           // also Firefox / Spotify
    var webFastPath = true               // AXUIElementsForSearchPredicate in web areas
    var hitTest = true                   // drop targets covered by something else or not drawn
    var ignoredApps: [String] = []       // bundle ids
    var scroll = Scroll()

    struct Scroll: Codable, Equatable {
        var keys = "hjkl"                // left, down, up, right
        var speed: Double = 1400         // px/s
        var dash: Double = 3             // shift multiplier
        var arrows = true
        var numbers = true
        var idleExit: Double = 0         // seconds, 0 = never
        var restorePointer = true
    }

    public init() {}
}

extension Config {
    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = Config()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
        theme = try v(.theme, z.theme)
        labelKeys = try v(.labelKeys, z.labelKeys)
        labelSize = try v(.labelSize, z.labelSize)
        smartLabels = try v(.smartLabels, z.smartLabels)
        autoClick = try v(.autoClick, z.autoClick)
        chainClicks = try v(.chainClicks, z.chainClicks)
        doubleClickMs = try v(.doubleClickMs, z.doubleClickMs)
        restorePointer = try v(.restorePointer, z.restorePointer)
        hideCursor = try v(.hideCursor, z.hideCursor)
        sounds = try v(.sounds, z.sounds)
        volume = try v(.volume, z.volume)
        menubar = try v(.menubar, z.menubar)
        statusItems = try v(.statusItems, z.statusItems)
        dock = try v(.dock, z.dock)
        missionControl = try v(.missionControl, z.missionControl)
        enableAx = try v(.enableAx, z.enableAx)
        experimentalAx = try v(.experimentalAx, z.experimentalAx)
        webFastPath = try v(.webFastPath, z.webFastPath)
        hitTest = try v(.hitTest, z.hitTest)
        ignoredApps = try v(.ignoredApps, z.ignoredApps)
        scroll = try v(.scroll, z.scroll)
    }
}

extension Config.Scroll {
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self), z = Config.Scroll()
        func v<T: Decodable>(_ k: CodingKeys, _ def: T) throws -> T { try c.decodeIfPresent(T.self, forKey: k) ?? def }
        keys = try v(.keys, z.keys)
        speed = try v(.speed, z.speed)
        dash = try v(.dash, z.dash)
        arrows = try v(.arrows, z.arrows)
        numbers = try v(.numbers, z.numbers)
        idleExit = try v(.idleExit, z.idleExit)
        restorePointer = try v(.restorePointer, z.restorePointer)
    }
}

extension Config {
    static var path: String {
        ProcessInfo.processInfo.environment["NEXTCLICK_CONFIG"]
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/nextclick/config.json").path
    }

    static func decode(_ data: Data) throws -> Config {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return try d.decode(Config.self, from: data)
    }

    // Missing file = defaults. Bad file = nil (caller keeps the previous config).
    static func load(_ path: String = Config.path) -> Config? {
        guard let data = FileManager.default.contents(atPath: path) else { return Config() }
        do { return try decode(data) } catch {
            log.error("config \(path, privacy: .private): \(error.localizedDescription, privacy: .private)")
            return nil
        }
    }
}

// Same watch pattern as hkd's ConfigLoader: re-arm after atomic replace.
final class ConfigWatcher {
    private let path: String
    private var source: DispatchSourceFileSystemObject?
    var onChange: (() -> Void)?

    init(path: String) { self.path = path }
    deinit { stop() }

    func start() {
        stop()
        let fd = open(path, O_EVTONLY)
        guard fd >= 0 else { return }
        let s = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete], queue: .main)
        s.setEventHandler { [weak self] in
            guard let self else { return }
            self.onChange?()
            if !s.data.intersection([.rename, .delete]).isEmpty { self.start() }
        }
        s.setCancelHandler { close(fd) }
        source = s
        s.resume()
    }

    func stop() {
        source?.cancel()
        source = nil
    }
}
