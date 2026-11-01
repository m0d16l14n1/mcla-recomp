// The game's files: checked against the one supported release (game-files.json, the 13 files of Midnight
// Club: Los Angeles Complete Edition, sizes and SHA-256), and taken out of a disc image (an Xbox 360 ISO,
// XDVDFS) the way scripts/extract_game.py does, unmodified.

import CryptoKit
import Foundation

struct GameManifest: Decodable {
    struct File: Decodable {
        let path: String
        let size: Int64
        let sha256: String
    }
    let title: String
    let titleId: String
    let xexVersion: String
    let files: [File]

    var totalSize: Int64 { files.reduce(0) { $0 + $1.size } }

    static let shared: GameManifest? = {
        let candidates = [
            Bundle.main.url(forResource: "game-files", withExtension: "json"),
            ProcessInfo.processInfo.environment["MCLA_GAME_FILES_JSON"].map { URL(fileURLWithPath: $0) },
        ]
        for case let url? in candidates {
            if let data = try? Data(contentsOf: url), let m = try? JSONDecoder().decode(GameManifest.self, from: data) {
                return m
            }
        }
        return nil
    }()
}

enum FileState: Equatable {
    case unknown, checking, ok, missing, wrongSize(Int64), wrongHash, unreadable
    var label: String {
        switch self {
        case .unknown: return "—"
        case .checking: return "checking…"
        case .ok: return "OK"
        case .missing: return "missing"
        case .wrongSize(let s): return "wrong size (\(ByteCountFormatter.string(fromByteCount: s, countStyle: .file)))"
        case .wrongHash: return "different contents"
        case .unreadable: return "can't be read"
        }
    }
    var good: Bool { self == .ok }
}

/// The result of a check, the whole folder at once.
struct GameCheck {
    var states: [String: FileState] = [:]
    var titleId: String?
    var full = false   // contents compared, not only sizes
    var finished = false

    var allGood: Bool { finished && !states.isEmpty && states.values.allSatisfy(\.good) }
    var problems: [String] { states.filter { !$0.value.good }.map(\.key).sorted() }
}

enum GameFiles {
    /// The XEX's title id (XEX2 optional header 0x00040006, the execution info), as 8 hex digits.
    static func titleId(of xex: URL) -> String? {
        guard let h = try? FileHandle(forReadingFrom: xex) else { return nil }
        defer { try? h.close() }
        guard let head = try? h.read(upToCount: 0x4000), head.count >= 0x18, head.prefix(4) == Data("XEX2".utf8) else { return nil }
        func be32(_ o: Int) -> UInt32? {
            guard o >= 0, o + 4 <= head.count else { return nil }
            return head[head.startIndex + o..<head.startIndex + o + 4].reduce(0) { $0 << 8 | UInt32($1) }
        }
        guard let count = be32(0x14) else { return nil }
        for i in 0..<Int(min(count, 64)) {
            guard let key = be32(0x18 + i * 8), let value = be32(0x1C + i * 8) else { return nil }
            if key == 0x00040006, let id = be32(Int(value) + 12) { return String(format: "%08X", id) }
        }
        return nil
    }

    /// Checks the folder: sizes always, contents (SHA-256) when `full`. `progress` gets bytes read so far.
    static func check(folder: URL, manifest: GameManifest, full: Bool,
                      cancelled: @escaping () -> Bool,
                      progress: @escaping (Int64, String) -> Void) -> GameCheck {
        var result = GameCheck(full: full)
        let fm = FileManager.default
        var done: Int64 = 0
        for file in manifest.files {
            if cancelled() { return result }
            let url = folder.appendingPathComponent(file.path)
            guard let attrs = try? fm.attributesOfItem(atPath: url.path), let size = attrs[.size] as? Int64 else {
                result.states[file.path] = .missing
                done += file.size
                continue
            }
            if size != file.size {
                result.states[file.path] = .wrongSize(size)
                done += file.size
                continue
            }
            if !full {
                result.states[file.path] = .ok
                continue
            }
            guard let h = try? FileHandle(forReadingFrom: url) else {
                result.states[file.path] = .unreadable
                done += file.size
                continue
            }
            var hasher = SHA256()
            var readOK = true
            while true {
                if cancelled() { try? h.close(); return result }
                let chunk: Data
                do {
                    guard let c = try h.read(upToCount: 8 << 20), !c.isEmpty else { break }
                    chunk = c
                } catch {
                    readOK = false
                    break
                }
                hasher.update(data: chunk)
                done += Int64(chunk.count)
                progress(done, file.path)
            }
            try? h.close()
            let hex = hasher.finalize().map { String(format: "%02x", $0) }.joined()
            result.states[file.path] = !readOK ? .unreadable : hex == file.sha256.lowercased() ? .ok : .wrongHash
        }
        result.titleId = titleId(of: folder.appendingPathComponent("default.xex"))
        result.finished = true
        return result
    }
}

/// An Xbox 360 disc image, read as XDVDFS.
struct XboxDiscImage {
    static let sector: UInt64 = 0x800
    static let magic = Data("MICROSOFT*XBOX*MEDIA".utf8)
    /// Where the game partition starts: raw XDVDFS, XGD2, XGD1, XGD3, and redump images.
    static let partitionOffsets: [UInt64] = [0x0, 0xFD90000, 0x2080000, 0x18300000, 0x89D80000]

    struct Entry {
        let path: String
        let sector: UInt32
        let size: UInt32
    }

    enum Failure: LocalizedError {
        case notXbox, truncated(String), io(String)
        var errorDescription: String? {
            switch self {
            case .notXbox: return "This is not an Xbox 360 disc image (no XDVDFS volume was found in it)."
            case .truncated(let p): return "The image ends early, in \(p): it may be incomplete."
            case .io(let m): return m
            }
        }
    }

    let url: URL
    let base: UInt64
    let entries: [Entry]

    init(url: URL) throws {
        self.url = url
        guard let h = try? FileHandle(forReadingFrom: url) else { throw Failure.io("Can't open \(url.path).") }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        var found: (UInt64, UInt32, UInt32)?
        for b in XboxDiscImage.partitionOffsets where b + 32 * XboxDiscImage.sector + 28 <= size {
            try? h.seek(toOffset: b + 32 * XboxDiscImage.sector)
            guard let head = try? h.read(upToCount: 28), head.count == 28 else { continue }
            if head.prefix(20) == XboxDiscImage.magic {
                found = (b, XboxDiscImage.le32(head, 20), XboxDiscImage.le32(head, 24))
                break
            }
        }
        guard let (b, rootSector, rootSize) = found else { throw Failure.notXbox }
        base = b
        var out: [Entry] = []
        var visited = Set<UInt32>()
        try XboxDiscImage.walk(h, base: b, sector: rootSector, size: rootSize, path: "", into: &out, visited: &visited)
        entries = out.filter { !$0.path.hasPrefix("/$SystemUpdate") }.sorted { $0.path < $1.path }
    }

    static func le32(_ d: Data, _ o: Int) -> UInt32 {
        d[d.startIndex + o..<d.startIndex + o + 4].reversed().reduce(0) { $0 << 8 | UInt32($1) }
    }
    static func le16(_ d: Data, _ o: Int) -> UInt16 {
        UInt16(d[d.startIndex + o]) | UInt16(d[d.startIndex + o + 1]) << 8
    }

    private static func walk(_ h: FileHandle, base: UInt64, sector: UInt32, size: UInt32, path: String,
                             into out: inout [Entry], visited: inout Set<UInt32>) throws {
        guard visited.insert(sector).inserted, size > 0, size < 64 << 20 else { return }
        try h.seek(toOffset: base + UInt64(sector) * XboxDiscImage.sector)
        guard let data = try h.read(upToCount: Int(size)) else { return }
        var stack = [0]
        var seen = Set<Int>()
        while let node = stack.popLast() {
            let off = node * 4
            guard seen.insert(off).inserted, off + 14 <= data.count else { continue }
            let left = le16(data, off), right = le16(data, off + 2)
            if left == 0xFFFF { continue }
            let sec = le32(data, off + 4), fileSize = le32(data, off + 8)
            let attr = data[data.startIndex + off + 12], nameLength = Int(data[data.startIndex + off + 13])
            guard off + 14 + nameLength <= data.count else { continue }
            let nameData = data[data.startIndex + off + 14..<data.startIndex + off + 14 + nameLength]
            let name = String(decoding: nameData, as: UTF8.self)
            let full = path + "/" + name
            if attr & 0x10 != 0 {
                if fileSize > 0 { try walk(h, base: base, sector: sec, size: fileSize, path: full, into: &out, visited: &visited) }
            } else {
                out.append(Entry(path: full, sector: sec, size: fileSize))
            }
            if left != 0 { stack.append(Int(left)) }
            if right != 0 { stack.append(Int(right)) }
        }
    }

    var totalSize: Int64 { entries.reduce(0) { $0 + Int64($1.size) } }

    /// Copies every file into `folder` (a file already there with the right size is kept).
    func extract(to folder: URL, cancelled: () -> Bool, progress: (Int64, String) -> Void) throws {
        let fm = FileManager.default
        guard let h = try? FileHandle(forReadingFrom: url) else { throw Failure.io("Can't open \(url.path).") }
        defer { try? h.close() }
        var done: Int64 = 0
        for e in entries {
            if cancelled() { return }
            let parts = e.path.split(separator: "/").map(String.init)
            let dest = parts.reduce(folder) { $0.appendingPathComponent($1) }
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let s = (try? fm.attributesOfItem(atPath: dest.path))?[.size] as? Int64, s == Int64(e.size) {
                done += Int64(e.size)
                progress(done, e.path)
                continue
            }
            let partial = dest.appendingPathExtension("part")
            fm.createFile(atPath: partial.path, contents: nil)
            guard let o = try? FileHandle(forWritingTo: partial) else { throw Failure.io("Can't write \(partial.path).") }
            try h.seek(toOffset: base + UInt64(e.sector) * XboxDiscImage.sector)
            var remaining = Int(e.size)
            while remaining > 0 {
                if cancelled() { try? o.close(); try? fm.removeItem(at: partial); return }
                guard let chunk = try h.read(upToCount: min(remaining, 16 << 20)), !chunk.isEmpty else {
                    try? o.close(); try? fm.removeItem(at: partial)
                    throw Failure.truncated(e.path)
                }
                try o.write(contentsOf: chunk)
                remaining -= chunk.count
                done += Int64(chunk.count)
                progress(done, e.path)
            }
            try o.close()
            _ = try? fm.removeItem(at: dest)
            try fm.moveItem(at: partial, to: dest)
        }
    }
}
