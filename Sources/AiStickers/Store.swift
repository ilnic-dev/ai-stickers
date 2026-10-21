import Foundation
import Observation

struct Sticker: Codable, Identifiable, Equatable {
    var id = UUID()
    var created = Date()
    var title: String
    var summary: String
    var todo: [String]
    var raw: String
    var tags: [String] = []
    var done: Set<Int> = []  // indexes of checked todos
    var pinned = false       // floats on the desktop instead of sitting in the panel
    var left: Double?        // top-left corner of a pinned sticker
    var top: Double?

    var isLater: Bool { tags.contains(laterTag) }
    var openTodos: Int { todo.indices.filter { !done.contains($0) }.count }
}

// In an extension so the memberwise init survives. Fields added after v0 may be missing on disk.
extension Sticker {
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id)
        created = try c.decode(Date.self, forKey: .created)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        todo = try c.decode([String].self, forKey: .todo)
        raw = try c.decode(String.self, forKey: .raw)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        done = try c.decodeIfPresent(Set<Int>.self, forKey: .done) ?? []
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
        left = try c.decodeIfPresent(Double.self, forKey: .left)
        top = try c.decodeIfPresent(Double.self, forKey: .top)
    }
}

/// The built-in tag for ideas that are not relevant yet: hidden from the panel by default.
let laterTag = "позже"

func normalizeTag(_ s: String) -> String {
    s.trimmingCharacters(in: .whitespacesAndNewlines)
        .trimmingCharacters(in: CharacterSet(charactersIn: "#"))
        .lowercased()
}

private let hashtagPattern = try! Regex(#"(?:^|[^\p{L}\p{N}])#([\p{L}\p{N}_-]+)"#)

/// `#тег` words in a message, normalized, in order, without duplicates.
func hashtags(in text: String) -> [String] {
    var seen: [String] = []
    for m in text.matches(of: hashtagPattern) {
        let tag = normalizeTag(String(m.output[1].substring ?? ""))
        if !seen.contains(tag) { seen.append(tag) }
    }
    return seen
}

/// What the panel lists: unpinned, newest first. A sticker matches the filter if it has any of its tags.
/// "позже" stays hidden unless shown explicitly or picked in the filter.
func panelStickers(_ all: [Sticker], filter: Set<String>, showLater: Bool) -> [Sticker] {
    let laterPicked = filter.contains(laterTag)
    return all.filter { s in
        !s.pinned
            && (showLater || laterPicked || !s.isLater)
            && (filter.isEmpty || !filter.isDisjoint(with: s.tags))
    }
    .sorted { $0.created > $1.created }
}

/// Every tag in use, most used first, and "позже" always last.
func tagVocabulary(_ all: [Sticker]) -> [String] {
    var counts: [String: Int] = [:]
    for s in all { for t in s.tags where t != laterTag { counts[t, default: 0] += 1 } }
    let sorted = counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    return sorted + [laterTag]
}

@MainActor @Observable
final class Store {
    private(set) var stickers: [Sticker] = []
    @ObservationIgnored var onChange: (() -> Void)?
    @ObservationIgnored private let url: URL

    init(url: URL? = nil) {
        if let url {
            self.url = url
        } else {
            let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("AiStickers")
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            self.url = dir.appendingPathComponent("stickers.json")
        }
        guard let data = try? Data(contentsOf: self.url) else { return }
        do {
            stickers = try JSONDecoder().decode([Sticker].self, from: data)
        } catch {
            // Keep an unreadable file instead of overwriting it with an empty list.
            try? FileManager.default.moveItem(at: self.url, to: self.url.appendingPathExtension("broken-\(Int(Date().timeIntervalSince1970))"))
        }
    }

    var vocabulary: [String] { tagVocabulary(stickers) }

    func add(_ s: Sticker) { stickers.append(s); save(); onChange?() }
    func remove(_ id: UUID) { stickers.removeAll { $0.id == id }; save(); onChange?() }

    func update(_ id: UUID, _ change: (inout Sticker) -> Void) {
        guard let i = stickers.firstIndex(where: { $0.id == id }) else { return }
        change(&stickers[i])
        save()
        onChange?()
    }

    /// Window moves land here; silent so redrawing never feeds back into another move.
    func place(_ id: UUID, left: Double, top: Double) {
        guard let i = stickers.firstIndex(where: { $0.id == id }) else { return }
        stickers[i].left = left
        stickers[i].top = top
        save()
    }

    private func save() {
        let enc = JSONEncoder()
        enc.outputFormatting = .prettyPrinted
        try? enc.encode(stickers).write(to: url, options: .atomic)
    }
}
