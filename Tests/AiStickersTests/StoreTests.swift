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

@Test @MainActor func removeCanBeUndone() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stickers-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let store = Store(url: url)
    let (a, b, c) = (sticker("a"), sticker("b"), sticker("c"))
    [a, b, c].forEach(store.add)
    store.remove(b.id)
    #expect(Store(url: url).stickers.map(\.title) == ["a", "c"])
    store.undoRemove()
    #expect(store.removed == nil)
    #expect(Store(url: url).stickers.map(\.title) == ["a", "b", "c"])

    store.remove(a.id)
    store.remove(c.id)
    store.forgetRemoved(a.id)  // a stale timer must not drop the newer offer
    #expect(store.removed?.sticker.id == c.id)
    store.forgetRemoved(c.id)
    store.undoRemove()
    #expect(store.stickers.map(\.title) == ["b"])
}

@Test func pinnedStickerClampsToNearestScreen() {
    let screens = [CGRect(x: 0, y: 0, width: 1000, height: 800), CGRect(x: 1000, y: 0, width: 800, height: 600)]
    let card = CGSize(width: 220, height: 100)
    #expect(clampTopLeft(CGPoint(x: 300, y: 500), card: card, screens: screens) == CGPoint(x: 300, y: 500))
    #expect(clampTopLeft(CGPoint(x: 900, y: 500), card: card, screens: screens) == CGPoint(x: 900, y: 500))  // across the seam
    #expect(clampTopLeft(CGPoint(x: 900, y: 700), card: card, screens: screens) == CGPoint(x: 780, y: 700))  // half off the top-right
    // A monitor that used to be on the right is gone: back onto the nearest edge of the second screen.
    #expect(clampTopLeft(CGPoint(x: 2500, y: 700), card: card, screens: screens) == CGPoint(x: 1580, y: 600))
    #expect(clampTopLeft(CGPoint(x: -400, y: 50), card: card, screens: screens) == CGPoint(x: 0, y: 100))
    #expect(clampTopLeft(CGPoint(x: 5, y: 5), card: card, screens: []) == CGPoint(x: 5, y: 5))
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
    #expect(hashtags(in: "#- #_").isEmpty)
}

@Test func mixedSpeechKeepsItsMainLanguage() {
    #expect(isMostlyCyrillic("надо заресетить usage в Claude и проверить pull request"))
    #expect(!isMostlyCyrillic("reset the Claude usage before midnight, потом билд"))
    #expect(!isMostlyCyrillic(""))
}

@Test func laterHasAnEnglishName() {
    #expect(normalizeTag("#Later") == laterTag)
    #expect(hashtags(in: "посмотреть потом #later") == [laterTag])
}

@Test @MainActor func oldLaterTagIsFoldedIntoBuiltIn() throws {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("stickers-\(UUID()).json")
    defer { try? FileManager.default.removeItem(at: url) }
    let old = #"[{"id":"11111111-1111-1111-1111-111111111111","created":0,"title":"t","summary":"s","todo":[],"raw":"r","tags":["later","видео","позже"]}]"#
    try Data(old.utf8).write(to: url)
    #expect(Store(url: url).stickers.first?.tags == [laterTag, "видео"])
}
