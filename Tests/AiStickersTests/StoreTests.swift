import Foundation
import Testing
@testable import AiStickers

private func sticker(_ title: String, tags: [String] = [], pinned: Bool = false, age: TimeInterval = 0) -> Sticker {
    Sticker(created: Date(timeIntervalSince1970: 1_000_000 - age), title: title, summary: "", todo: [], raw: "", tags: tags, pinned: pinned)
}

@Test func v0FileStillLoads() throws {
    let v0 = #"[{"id":"11111111-1111-1111-1111-111111111111","created":782000000,"title":"t","summary":"s","todo":["a","b"],"raw":"r","left":12,"top":800}]"#
    let s = try #require(try JSONDecoder().decode([Sticker].self, from: Data(v0.utf8)).first)
    #expect(s.tags.isEmpty && s.done.isEmpty && !s.pinned && s.left == 12)
    #expect(s.openTodos == 2)
}

@Test @MainActor func storeRoundTrips() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stickers-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let a = Store(url: url)
    let s = sticker("idea", tags: ["видео"])
    a.add(s)
    a.update(s.id) { $0.done.insert(0); $0.pinned = true }
    #expect(Store(url: url).stickers == a.stickers)
}

@Test func panelHidesPinnedAndLater() {
    let all = [sticker("a"), sticker("pinned", pinned: true), sticker("later", tags: [laterTag])]
    #expect(panelStickers(all, filter: [], showLater: false).map(\.title) == ["a"])
    #expect(panelStickers(all, filter: [], showLater: true).map(\.title) == ["a", "later"])
    #expect(panelStickers(all, filter: [laterTag], showLater: false).map(\.title) == ["later"])
}

@Test func filterMatchesAnyTagNewestFirst() {
    let all = [
        sticker("old video", tags: ["видео"], age: 100),
        sticker("biz", tags: ["бизнес"], age: 50),
        sticker("personal", tags: ["личное"]),
        sticker("new video", tags: ["видео", "бизнес"]),
    ]
    #expect(panelStickers(all, filter: ["видео", "бизнес"], showLater: false).map(\.title) == ["new video", "biz", "old video"])
}

@Test func vocabularyByUseWithLaterLast() {
    let all = [sticker("1", tags: ["b", laterTag]), sticker("2", tags: ["a", "b"]), sticker("3", tags: ["c"])]
    #expect(tagVocabulary(all) == ["b", "a", "c", laterTag])
    #expect(tagVocabulary([]) == [laterTag])
}

@Test func tagsAreNormalized() {
    #expect(normalizeTag("  #Видео ") == "видео")
    #expect(normalizeTag("Новый тег,") == "новый-тег")
}

@Test func hashtagsAreParsed() {
    #expect(hashtags(in: "снять ролик #Видео и #бизнес, ещё раз #видео") == ["видео", "бизнес"])
    #expect(hashtags(in: "без тегов, но с C# и 100%").isEmpty)
    #expect(hashtags(in: "цены https://site.com/page#pricing #идея-") == ["идея"])
}
