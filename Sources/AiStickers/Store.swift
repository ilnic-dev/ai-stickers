import Foundation
import Observation

enum StickerStatus: String, Codable, CaseIterable {
    case new, inProgress, onHold, postponed

    var label: String {
        switch self {
        case .new: tr("Новая", "New")
        case .inProgress: tr("В работе", "In progress")
        case .onHold: tr("На паузе", "On hold")
        case .postponed: tr("Отложено", "Postponed")
        }
    }
}

enum Priority: Int, Codable, CaseIterable, Comparable {
    case none, low, medium, high

    static func < (a: Priority, b: Priority) -> Bool { a.rawValue < b.rawValue }

    var label: String {
        switch self {
        case .none: tr("Нет", "None")
        case .low: tr("Низкий", "Low")
        case .medium: tr("Средний", "Medium")
        case .high: tr("Высокий", "High")
        }
    }
}

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
    var status: StickerStatus = .new
    var priority: Priority = .none

    var isPostponed: Bool { status == .postponed }
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
        status = try c.decodeIfPresent(StickerStatus.self, forKey: .status) ?? .new
        priority = try c.decodeIfPresent(Priority.self, forKey: .priority) ?? .none
        // "позже" (or "later") used to be a tag; it is the postponed status now.
        if tags.contains(where: { normalizeTag($0) == laterTag }) {
            status = .postponed
            tags.removeAll { normalizeTag($0) == laterTag }
        }
    }
}

/// `#позже` / `#later` in a message postpones the idea instead of becoming a tag.
let laterTag = "позже"

/// Lowercase, one word: "#Новый тег," → "новый-тег", so every tag round-trips as a #hashtag.
func normalizeTag(_ s: String) -> String {
    let tag = s.lowercased()
        .split { $0.isWhitespace || $0 == "," }
        .joined(separator: "-")
        .trimmingCharacters(in: CharacterSet(charactersIn: "#-_"))
    return tag == "later" ? laterTag : tag  // #later works like #позже
}

// MARK: - Interface language

/// The interface language, picked in the menu bar. Stickers keep the language they were spoken in.
// @unchecked: Bot reads `english` off the main thread while the menu may flip it; a stale Bool
// for one reply is harmless.
@Observable
final class Lang: @unchecked Sendable {
    static let shared = Lang()
    private static let key = "uiLanguage"
    private(set) var english: Bool

    private init() {
        let saved = UserDefaults.standard.string(forKey: Lang.key)
        english = (saved ?? (Locale.preferredLanguages.first?.hasPrefix("ru") == true ? "ru" : "en")) == "en"
    }

    func set(english: Bool) {
        self.english = english
        UserDefaults.standard.set(english ? "en" : "ru", forKey: Lang.key)
    }
}

/// The string for the current interface language: `tr("Идеи", "Ideas")`.
func tr(_ ru: String, _ en: String) -> String { Lang.shared.english ? en : ru }

/// How a tag is shown: the built-in one gets its English name in the English interface.

private let hashtagPattern = try! Regex(#"(?:^|\s)#([\p{L}\p{N}_-]+)"#)

/// Cyrillic letters outnumber Latin ones. Told to Claude explicitly: left to judge mixed speech
/// itself, it answers a mostly-Russian note in English.
func isMostlyCyrillic(_ text: String) -> Bool {
    var cyrillic = 0, latin = 0
    for s in text.unicodeScalars where s.properties.isAlphabetic {
        if (0x0400...0x04FF).contains(s.value) { cyrillic += 1 } else if s.isASCII { latin += 1 }
    }
    return cyrillic > latin
}

/// What "copy" puts on the clipboard: title, summary, a markdown checklist and the tags.
func clipboardText(_ s: Sticker) -> String {
    var parts = [s.title]
    if !s.summary.isEmpty && s.summary != s.title { parts.append(s.summary) }
    if !s.todo.isEmpty {
        parts.append(s.todo.enumerated().map { "- [\(s.done.contains($0.offset) ? "x" : " ")] \($0.element)" }.joined(separator: "\n"))
    }
    if !s.tags.isEmpty { parts.append(s.tags.map { "#" + $0 }.joined(separator: " ")) }
    let marks = [s.status == .new ? nil : s.status.label, s.priority == .none ? nil : tr("приоритет: ", "priority: ") + s.priority.label.lowercased()]
    if !marks.compactMap({ $0 }).isEmpty { parts.append(marks.compactMap { $0 }.joined(separator: " · ")) }
    return parts.joined(separator: "\n\n")
}

/// `#тег` words in a message, normalized, in order, without duplicates.
func hashtags(in text: String) -> [String] {
    var seen: [String] = []
    for m in text.matches(of: hashtagPattern) {
        let tag = normalizeTag(String(m.output[1].substring ?? ""))
        if !tag.isEmpty && !seen.contains(tag) { seen.append(tag) }
    }
    return seen
}

/// What the panel lists: unpinned, higher priority first, then newest. A sticker matches the filter if it
/// has any of its tags. Postponed ones stay hidden unless asked for.
func panelStickers(_ all: [Sticker], filter: Set<String>, showPostponed: Bool) -> [Sticker] {
    all.filter { s in
        !s.pinned
            && (showPostponed || !s.isPostponed)
            && (filter.isEmpty || !filter.isDisjoint(with: s.tags))
    }
    .sorted { $0.priority != $1.priority ? $0.priority > $1.priority : $0.created > $1.created }
}

/// Where a pinned sticker's top-left corner may sit: unchanged while the whole card is on screens (even across
/// a seam), otherwise inside the screen nearest to it. Cocoa coordinates: y grows upward, so the card hangs below `p`.
func clampTopLeft(_ p: CGPoint, card: CGSize, screens: [CGRect]) -> CGPoint {
    let corners = [p, CGPoint(x: p.x + card.width, y: p.y), CGPoint(x: p.x, y: p.y - card.height), CGPoint(x: p.x + card.width, y: p.y - card.height)]
    if corners.allSatisfy({ c in screens.contains { $0.contains(c) } }) { return p }
    func distance(_ r: CGRect) -> CGFloat { hypot(max(r.minX - p.x, 0, p.x - r.maxX), max(r.minY - p.y, 0, p.y - r.maxY)) }
    guard let s = screens.min(by: { distance($0) < distance($1) }) else { return p }
    return CGPoint(x: max(min(p.x, s.maxX - card.width), s.minX), y: min(max(p.y, s.minY + card.height), s.maxY))
}

/// Every tag in use, most used first.
func tagVocabulary(_ all: [Sticker]) -> [String] {
    var counts: [String: Int] = [:]
    for s in all { for t in s.tags { counts[t, default: 0] += 1 } }
    return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
}

@MainActor @Observable
final class Store {
    private(set) var stickers: [Sticker] = []
    /// The last deleted sticker and its position, while «Отменить» is still offered.
    private(set) var removed: (sticker: Sticker, index: Int)?
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

    func remove(_ id: UUID) {
        guard let i = stickers.firstIndex(where: { $0.id == id }) else { return }
        removed = (stickers.remove(at: i), i)
        save()
        onChange?()
    }

    func undoRemove() {
        guard let r = removed else { return }
        stickers.insert(r.sticker, at: min(r.index, stickers.count))
        removed = nil
        save()
        onChange?()
    }

    /// The undo offer expired; a newer deletion keeps its own offer.
    func forgetRemoved(_ id: UUID) { if removed?.sticker.id == id { removed = nil } }

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
