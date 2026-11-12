import CoreGraphics
import CryptoKit
import Foundation

enum Labels {
    static func keys(_ s: String) -> [Character] {
        var seen = Set<Character>()
        let k = s.lowercased().filter { $0.isLetter || $0.isNumber }.filter { seen.insert($0).inserted }
        return k.count >= 2 ? Array(k) : Array("asdfjklewruio")
    }

    // Balanced prefix-free labels, shortest first (Vimium's scheme).
    static func generate(_ n: Int, _ keys: [Character]) -> [String] {
        guard n > 0 else { return [] }
        var all = [""], offset = 0
        while all.count - offset < n || all.count == 1 {
            let h = all[offset]
            offset += 1
            all += keys.map { h + String($0) }
        }
        return Array(all[offset..<offset + n])
    }

    // Smart assignment: remembered labels stay put if still short enough for their rank;
    // other favourites get the shortest free labels; the rest hash into stable slots.
    static func assign(keys ids: [String], pool: [String], memory: [String: (score: Double, label: String)]) -> [String] {
        let n = ids.count
        guard pool.count >= n else { return pool + Array(repeating: "", count: n - pool.count) }
        var out = [String?](repeating: nil, count: n), used = Set<String>()
        let poolSet = Set(pool)
        let fav = (0..<n).filter { memory[ids[$0]] != nil }.sorted { memory[ids[$0]]!.score > memory[ids[$1]]!.score }
        for (rank, i) in fav.enumerated() {
            let l = memory[ids[i]]!.label
            if poolSet.contains(l), !used.contains(l), l.count <= pool[rank].count { out[i] = l; used.insert(l) }
        }
        var free = pool.filter { !used.contains($0) }, next = 0
        for i in fav where out[i] == nil { out[i] = free[next]; used.insert(free[next]); next += 1 }
        free = Array(free[next...])
        var taken = [Bool](repeating: false, count: free.count)
        for i in 0..<n where out[i] == nil {
            var j = Int(fnv1a(ids[i]) % UInt64(free.count))
            while taken[j] { j = (j + 1) % free.count }
            taken[j] = true
            out[i] = free[j]
        }
        return out.map { $0! }
    }

    // Reading order: rows of ~10px, then x.
    static func spatial(_ rects: [CGRect]) -> [Int] {
        rects.indices.sorted { (i: Int, j: Int) -> Bool in
            let a = rects[i], b = rects[j], ay = Int(a.minY / 10), by = Int(b.minY / 10)
            return ay != by ? ay < by : a.minX < b.minX
        }
    }

    static func fnv1a(_ s: String) -> UInt64 {
        var h: UInt64 = 0xcbf29ce484222325
        for b in s.utf8 { h = (h ^ UInt64(b)) &* 0x100000001b3 }
        return h
    }

    // Hashed so no on-screen text reaches disk. Position is window-relative and coarse.
    static func identity(_ nodes: [Node], origin: CGPoint) -> [String] {
        var count: [String: Int] = [:]
        return nodes.map { n in
            let rel = n.source == .window || n.source == .mission
                ? "\(Int((n.frame.minX - origin.x) / 48)),\(Int((n.frame.minY - origin.y) / 48))" : ""
            let raw = "\(n.source.rawValue)|\(n.role)|\(n.subrole)|\(n.name)|\(n.ident)|\(rel)"
            let k = count[raw, default: 0]
            count[raw] = k + 1
            let digest = SHA256.hash(data: Data((k == 0 ? raw : "\(raw)#\(k)").utf8))
            return digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        }
    }

    // Search: word-start matches rank above substring matches; ties keep reading order.
    static func search(_ texts: [String], _ q: String) -> [Int] {
        let q = q.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return [] }
        var scored: [(Int, Int)] = []
        for (i, t) in texts.enumerated() {
            let t = t.lowercased()
            guard let r = t.range(of: q) else { continue }
            let start = r.lowerBound == t.startIndex || !t[t.index(before: r.lowerBound)].isLetter
            scored.append((i, start ? 0 : 1))
        }
        return scored.sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0 < $1.0 }.map(\.0)
    }
}
