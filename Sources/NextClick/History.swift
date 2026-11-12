import Foundation

enum ClickKind: String, Codable { case left, right, command, hover }

// ~/Library/Application Support/nextclick/history.json — per-app click counts by hashed identity.
final class History {
    struct Entry: Codable, Equatable { var c: Double; var t: Double; var l: String }
    struct Last: Codable, Equatable { var scope: String; var key: String; var kind: ClickKind }
    struct File: Codable, Equatable {
        var version = 1
        var scopes: [String: [String: Entry]] = [:]
        var last: Last?
    }

    static let halfLife = 14.0 * 86400, maxPerScope = 300, saveDelay = 2.0
    private(set) var file = File()
    private let url: URL?
    private let io = DispatchQueue(label: "com.nkannan.nextclick.history", qos: .utility)
    private var pending: DispatchWorkItem?
    private var dirty = false

    static var defaultURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("nextclick/history.json")
    }

    init(url: URL?) {
        self.url = url
        guard let url, let data = try? Data(contentsOf: url) else { return }
        file = (try? JSONDecoder().decode(File.self, from: data)) ?? File()
    }

    static func decayed(_ e: Entry, now: Double) -> Double {
        e.c * pow(0.5, max(0, now - e.t) / halfLife)
    }

    func memory(_ scope: String, now: Double = Date().timeIntervalSince1970) -> [String: (score: Double, label: String)] {
        (file.scopes[scope] ?? [:]).mapValues { (History.decayed($0, now: now), $0.l) }
    }

    func record(scope: String, key: String, label: String, kind: ClickKind, now: Double = Date().timeIntervalSince1970) {
        var m = file.scopes[scope] ?? [:]
        let c = m[key].map { History.decayed($0, now: now) } ?? 0
        m[key] = Entry(c: c + 1, t: now, l: label)
        if m.count > History.maxPerScope {
            let keep = m.sorted { History.decayed($0.value, now: now) > History.decayed($1.value, now: now) }.prefix(History.maxPerScope)
            m = Dictionary(uniqueKeysWithValues: keep.map { ($0.key, $0.value) })
        }
        file.scopes[scope] = m
        file.last = Last(scope: scope, key: key, kind: kind)
        schedule()
    }

    func clear() {
        file = File()
        dirty = false
        pending?.cancel()
        guard let url else { return }
        io.async { try? FileManager.default.removeItem(at: url) }
        log.notice("history cleared")
    }

    func flush() {
        pending?.cancel()
        save()
        io.sync {}
    }

    private func schedule() {
        dirty = true
        pending?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.save() }
        pending = w
        DispatchQueue.main.asyncAfter(deadline: .now() + History.saveDelay, execute: w)
    }

    private func save() {
        guard dirty, let url else { return }
        dirty = false
        let snapshot = file
        io.async {
            guard let data = try? JSONEncoder().encode(snapshot) else { return }
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? data.write(to: url, options: .atomic)
        }
    }
}
