import ApplicationServices
import Foundation
import Testing
@testable import NextClick

private let keys = Labels.keys("ASDFJKLEWRUIO")
private func tmp(_ name: String) -> URL {
    URL(fileURLWithPath: "/private/tmp/nextclick-tests-\(UUID().uuidString)").appendingPathComponent(name)
}
private func node(_ name: String, _ x: CGFloat, _ y: CGFloat, source: Source = .window) -> Node {
    let r = CGRect(x: x, y: y, width: 40, height: 20)
    return Node(el: AXUIElementCreateApplication(getpid()), role: "AXButton", subrole: "", name: name, text: "",
                ident: "", frame: r, visible: r, source: source)
}

// MARK: labels

@Test func labelsArePrefixFreeAndShortestFirst() {
    for n in [1, 5, 13, 14, 60, 169, 170, 900] {
        let l = Labels.generate(n, keys)
        #expect(l.count == n)
        #expect(Set(l).count == n)
        #expect(l.map(\.count) == l.map(\.count).sorted())
        for a in l { for b in l where a != b { #expect(!b.hasPrefix(a)) } }
    }
}

@Test func labelCountsStayShort() {
    #expect(Labels.generate(13, keys).allSatisfy { $0.count == 1 })
    #expect(Labels.generate(169, keys).allSatisfy { $0.count == 2 })
    #expect(Labels.generate(14, keys).filter { $0.count == 1 }.count == 12)
}

@Test func keysDedupeAndFallBack() {
    #expect(Labels.keys("aAsS d") == ["a", "s", "d"])
    #expect(Labels.keys("x") == Array("asdfjklewruio"))
}

@Test func assignmentIsStableAndUnique() {
    let ids = (0..<40).map { "id\($0)" }, pool = Labels.generate(40, keys)
    let a = Labels.assign(keys: ids, pool: pool, memory: [:]), b = Labels.assign(keys: ids, pool: pool, memory: [:])
    #expect(a == b)
    #expect(Set(a).count == 40)
    #expect(Set(a).isSubset(of: Set(pool)))
}

@Test func favouritesGetShortLabelsAndKeepThem() {
    let ids = (0..<40).map { "id\($0)" }, pool = Labels.generate(40, keys)
    let short = pool.first { $0.count == 1 }!
    let mem: [String: (score: Double, label: String)] = ["id7": (9, short), "id9": (5, "zz")]
    let l = Labels.assign(keys: ids, pool: pool, memory: mem)
    #expect(l[7] == short)
    #expect(l[9].count == 1)  // remembered label not in pool -> shortest free
    #expect(Set(l).count == 40)
}

@Test func spatialOrderReadsRowsThenColumns() {
    let r = [CGRect(x: 100, y: 50, width: 5, height: 5), CGRect(x: 10, y: 52, width: 5, height: 5), CGRect(x: 0, y: 0, width: 5, height: 5)]
    #expect(Labels.spatial(r) == [2, 1, 0])
}

@Test func identityIsHashedStableAndWindowRelative() {
    let a = [node("Send", 10, 10), node("Send", 10, 10), node("Reply", 60, 10)]
    let ids = Labels.identity(a, origin: .zero)
    #expect(Set(ids).count == 3)
    #expect(ids.allSatisfy { $0.count == 16 && !$0.contains("Send") })
    let moved = [node("Send", 510, 310), node("Send", 510, 310), node("Reply", 560, 310)]
    #expect(Labels.identity(moved, origin: CGPoint(x: 500, y: 300)) == ids)
}

@Test func searchRanksWordStarts() {
    #expect(Labels.search(["Unsubscribe", "Subscribe", "Sub menu", "Other"], "sub") == [1, 2, 0])
    #expect(Labels.search(["a"], "  ").isEmpty)
}

// MARK: history

@Test func historyDecaysWithHalfLife() {
    let e = History.Entry(c: 8, t: 0, l: "a")
    #expect(abs(History.decayed(e, now: History.halfLife) - 4) < 1e-9)
    #expect(History.decayed(e, now: -5) == 8)
}

@Test func historyRecordsPrunesAndPersists() throws {
    let url = tmp("history.json"), h = History(url: url)
    for i in 0..<(History.maxPerScope + 20) { h.record(scope: "app", key: "k\(i)", label: "a", kind: .left, now: Double(i)) }
    h.record(scope: "app", key: "k0", label: "s", kind: .right, now: 1000)
    #expect(h.file.scopes["app"]!.count == History.maxPerScope)
    #expect(h.file.last == History.Last(scope: "app", key: "k0", kind: .right))
    h.flush()
    let back = History(url: url)
    #expect(back.file == h.file)
    #expect(back.memory("app", now: 1000)["k0"]!.label == "s")
    back.clear()
    back.flush()
    #expect(!FileManager.default.fileExists(atPath: url.path))
}

@Test func smartLabelsOffWritesNothing() throws {
    let cfg = tmp("config.json"), hist = tmp("history.json")
    try FileManager.default.createDirectory(at: cfg.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"smart_labels": false}"#.utf8).write(to: cfg)
    let e = Engine(configPath: cfg.path, historyURL: hist)
    e.reload()
    e.recordClick(scope: "app", key: "k", label: "a", kind: .left)
    e.history.flush()
    #expect(e.last?.key == "k")
    #expect(e.history.file.scopes.isEmpty)
    #expect(!FileManager.default.fileExists(atPath: hist.path))
}

// MARK: config

@Test func configDecodesPartialSnakeCase() throws {
    let c = try Config.decode(Data(#"{"theme":"midnight","label_keys":"hjkl","enable_ax":false,"scroll":{"speed":900}}"#.utf8))
    #expect(c.theme == "midnight")
    #expect(c.labelKeys == "hjkl")
    #expect(c.enableAx == false)
    #expect(c.scroll.speed == 900)
    #expect(c.scroll.keys == "hjkl")
    #expect(c.smartLabels)
}

@Test func configMissingIsDefaultBadIsNil() throws {
    #expect(Config.load("/private/tmp/nextclick-missing-\(UUID().uuidString).json") == Config())
    let bad = tmp("bad.json")
    try FileManager.default.createDirectory(at: bad.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(#"{"theme": 3}"#.utf8).write(to: bad)
    #expect(Config.load(bad.path) == nil)
}

@Test func defaultsMatchPersonalization() {
    let c = Config()
    #expect(c.theme == "codex")
    #expect(c.hitTest)
    #expect(c.labelKeys == "ASDFJKLEWRUIO")
}

// MARK: scroll keys

@Test func scrollKeysMapDirectionsAndJumps() {
    var g = 0.0
    func a(_ c: Character?, _ code: Int64 = 0, shift: Bool = false, now: Double = 10, keys: String = "hjkl", arrows: Bool = true) -> ScrollAction {
        ScrollKeys.action(char: c, code: code, shift: shift, now: now, lastG: &g, keys: keys, arrows: arrows)
    }
    #expect(a("h") == .hold(-1, 0))
    #expect(a("j") == .hold(0, 1))
    #expect(a("k") == .hold(0, -1))
    #expect(a("L") == .hold(1, 0))
    #expect(a("d") == .page(1))
    #expect(a("u") == .page(-1))
    #expect(a("g", shift: true) == .bottom)
    #expect(a("g", now: 20) == .pending)
    #expect(a("g", now: 20.3) == .top)
    #expect(a("g", now: 30) == .pending)
    #expect(a("g", now: 31) == .pending)
    #expect(a("3") == .select(2))
    #expect(a("x") == .none)
    #expect(a(nil, Key.esc) == .exit)
    #expect(a(nil, Key.tab, shift: true) == .prev)
    #expect(a(nil, Key.down) == .hold(0, 1))
    #expect(a(nil, Key.down, arrows: false) == .none)
    #expect(a("n", keys: "bnpf") == .hold(0, 1))
}

// MARK: misc

@Test func classifyChromiumAndElectron() {
    #expect(Enabler.classify(bundleID: "com.tinyspeck.slackmacgap", frameworks: ["Electron Framework.framework", "Squirrel.framework"]) == [Enabler.manual])
    #expect(Enabler.classify(bundleID: "com.google.Chrome", frameworks: []) == [Enabler.enhanced])
    #expect(Enabler.classify(bundleID: "com.openai.codex", frameworks: ["Codex Framework.framework", "Sparkle.framework"]) == [Enabler.manual, Enabler.enhanced])
    #expect(Enabler.classify(bundleID: "com.apple.Safari", frameworks: ["Sparkle.framework"]).isEmpty)
}

@Test func overlappingBadgesCluster() {
    let f = [CGRect(x: 0, y: 0, width: 10, height: 10), CGRect(x: 5, y: 5, width: 10, height: 10),
             CGRect(x: 100, y: 0, width: 10, height: 10), CGRect(x: 8, y: 0, width: 10, height: 10)]
    #expect(Overlay.clusters(f, [0, 0, 0, 1]) == [[0, 1]])
}

@Test func soundsAreShortAndBounded() {
    for e in Sound.Effect.allCases {
        let s = Sound.samples(e, rate: 44100)
        #expect(s.count > 500 && s.count < 4000)
        #expect(s.allSatisfy { abs($0) <= 1 })
    }
}

@Test func commandTableMatchesReadme() {
    let names = Set(NextClickCommands().commands.keys)
    #expect(names == ["click.show", "click.prefetch", "click.system", "click.search", "click.repeat", "scroll.show", "nextclick.reload", "nextclick.clear_history"])
}

@Test func overlayConvertsTopLeftToLayerSpace() {
    #expect(Overlay.toLayer(CGRect(x: 10, y: 20, width: 30, height: 40), height: 1080) == CGRect(x: 10, y: 1020, width: 30, height: 40))
    #expect(Overlay.toLayer(CGRect(x: 0, y: 1060, width: 5, height: 20), height: 1080).minY == 0)
}

@Test func codexThemeFollowsAppearance() {
    let light = Theme.named("codex", dark: false), dark = Theme.named("codex", dark: true)
    #expect(light.top == CGColor(srgbRed: 0xFD / 255, green: 0xF6 / 255, blue: 0xE3 / 255, alpha: 1))
    #expect(dark.top == CGColor(srgbRed: 0x28 / 255, green: 0x28 / 255, blue: 0x28 / 255, alpha: 1))
    #expect(Theme.named("nope", dark: false).text == Theme.named("sunset", dark: false).text)
}

@Test func hitGeometryKeepsPartsAndContainersDropsOverlaps() {
    let t = CGRect(x: 100, y: 100, width: 80, height: 24)
    #expect(Discovery.covers(hit: CGRect(x: 104, y: 104, width: 20, height: 16), target: t))   // icon inside button
    #expect(Discovery.covers(hit: CGRect(x: 0, y: 30, width: 1920, height: 1050), target: t))  // Chromium page group
    #expect(!Discovery.covers(hit: CGRect(x: 90, y: 110, width: 300, height: 200), target: t)) // popover over half of it
    #expect(!Discovery.covers(hit: CGRect(x: 120, y: 90, width: 40, height: 40), target: t))   // overlapping sibling
}
