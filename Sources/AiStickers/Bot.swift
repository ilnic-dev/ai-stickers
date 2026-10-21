import Foundation

struct BotError: Error, CustomStringConvertible {
    let description: String
    init(_ d: String) { description = d }
}

private struct Response<T: Decodable>: Decodable { let ok: Bool; let result: T?; let description: String? }
private struct Update: Decodable { let update_id: Int; let message: Message? }
private struct Message: Decodable {
    struct Ref: Decodable { let id: Int64 }
    struct FileRef: Decodable { let file_id: String }
    let chat: Ref
    let from: Ref?
    let text: String?
    let caption: String?
    let voice: FileRef?
    let audio: FileRef?
    let video_note: FileRef?
}
private struct TGFile: Decodable { let file_path: String }
private struct Note: Decodable { let title: String; let summary: String; let todo: [String]; let tags: [String] }
private struct ClaudeOutput: Decodable { let structured_output: Note? }

/// Telegram long polling is the queue: ideas sent while the Mac sleeps wait on Telegram's side (up to 24h).
struct Bot {
    let cfg: Config
    let store: Store

    func run() async {
        var offset = 0
        while true {
            do {
                let updates: [Update] = try await call("getUpdates", ["offset": offset, "timeout": 50, "allowed_updates": ["message"]])
                for u in updates {
                    if let m = u.message { await handle(m) }
                    offset = u.update_id + 1  // confirmed on the next getUpdates, so a crash mid-idea re-delivers it
                }
            } catch {
                print("poll:", describe(error))
                try? await Task.sleep(for: .seconds(5))
            }
        }
    }

    private func handle(_ m: Message) async {
        guard let from = m.from?.id else { return }
        guard let owner = cfg.userId else {
            await reply(m.chat.id, "Твой Telegram ID: \(from)\nДобавь строку TELEGRAM_USER_ID=\(from) в \(Config.path) и перезапусти приложение.")
            return
        }
        guard from == owner else { return }
        if m.text?.hasPrefix("/") == true {
            await reply(m.chat.id, "Кидай мысль текстом или голосом — она станет стикером на маке.")
            return
        }

        do {
            var raw = m.text ?? m.caption ?? ""
            if let file = m.voice ?? m.audio ?? m.video_note {
                raw = [raw, try await transcribe(file.file_id)].filter { !$0.isEmpty }.joined(separator: "\n")
            }
            guard !raw.isEmpty else { return }
            // "позже" hides an idea; only the user sets it (#позже or the panel), never Claude.
            var sticker = summarize(raw, vocabulary: await store.vocabulary.filter { $0 != laterTag })
            let picked = hashtags(in: raw)
            sticker.tags = picked + sticker.tags.filter { !picked.contains($0) }
            await store.add(sticker)
            await reply(m.chat.id, (["📌 \(sticker.title)"] + sticker.tags.map { "#\($0)" }).joined(separator: " "))
        } catch {
            await reply(m.chat.id, "⚠️ Не получилось: \(describe(error))")
        }
    }

    private func transcribe(_ fileId: String) async throws -> String {
        let file: TGFile = try await call("getFile", ["file_id": fileId])
        let url = URL(string: "https://api.telegram.org/file/bot\(cfg.token)/\(file.file_path)")!
        let (data, _) = try await URLSession.shared.data(from: url)

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = dir.appendingPathComponent("in"), wav = dir.appendingPathComponent("in.wav")
        try data.write(to: src)

        _ = try exec(cfg.ffmpeg, ["-y", "-loglevel", "error", "-i", src.path, "-ar", "16000", "-ac", "1", wav.path])
        return try exec(cfg.whisper, ["-m", cfg.whisperModel, "-l", "auto", "-nt", "-np", "-f", wav.path])
            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Never loses the idea: if Claude fails, the raw text becomes the sticker.
    private func summarize(_ raw: String, vocabulary: [String]) -> Sticker {
        let schema = #"{"type":"object","properties":{"title":{"type":"string"},"summary":{"type":"string"},"todo":{"type":"array","items":{"type":"string"}},"tags":{"type":"array","items":{"type":"string"}}},"required":["title","summary","todo","tags"]}"#
        let system = """
        You turn a raw idea (often a messy voice transcript) into a sticky note. Write in the language of the idea.
        title: the idea in at most 6 words.
        summary: 1-3 clean sentences keeping every concrete detail (names, numbers, links, places).
        todo: only actions the author stated or clearly implied, as short imperatives; empty if none. Never invent tasks.
        tags: 0-2 tags copied exactly from this list, only when they clearly fit; never new ones: \(vocabulary.joined(separator: ", "))
        """
        do {
            let out = try exec(cfg.claude, [
                "-p", "--model", "haiku", "--tools", "", "--strict-mcp-config", "--disable-slash-commands",
                "--no-session-persistence", "--setting-sources", "", "--system-prompt", system,
                "--json-schema", schema, "--output-format", "json", raw,
            ], cwd: FileManager.default.temporaryDirectory)
            if let n = try JSONDecoder().decode(ClaudeOutput.self, from: Data(out.utf8)).structured_output {
                var tags: [String] = []
                for t in n.tags.map(normalizeTag) where vocabulary.contains(t) && !tags.contains(t) { tags.append(t) }
                return Sticker(title: n.title, summary: n.summary, todo: n.todo, raw: raw, tags: Array(tags.prefix(2)))
            }
        } catch {
            print("claude:", error)
        }
        return Sticker(title: String(raw.prefix(60)), summary: raw, todo: [], raw: raw)
    }

    private func reply(_ chat: Int64, _ text: String) async {
        let _: Response<Message>? = try? await call("sendMessage", ["chat_id": chat, "text": text])
    }

    private func call<T: Decodable>(_ method: String, _ params: [String: Any]) async throws -> T {
        var req = URLRequest(url: URL(string: "https://api.telegram.org/bot\(cfg.token)/\(method)")!)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONSerialization.data(withJSONObject: params)
        req.timeoutInterval = 70
        let (data, _) = try await URLSession.shared.data(for: req)
        let r = try JSONDecoder().decode(Response<T>.self, from: data)
        guard r.ok, let result = r.result else { throw BotError("\(method): \(r.description ?? "unknown error")") }
        return result
    }
}

/// URLError carries the request URL, which contains the bot token: never print or send it.
private func describe(_ error: Error) -> String {
    if let e = error as? URLError { return "ошибка сети (\(e.code.rawValue))" }
    return "\(error)"
}

// ponytail: blocks a cooperative thread while the tool runs; fine for one serial poll loop.
func exec(_ exe: String, _ args: [String], cwd: URL? = nil) throws -> String {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    if let cwd { p.currentDirectoryURL = cwd }
    let out = Pipe()
    p.standardOutput = out
    p.standardError = FileHandle.nullDevice
    try p.run()
    let data = out.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    guard p.terminationStatus == 0 else { throw BotError("\((exe as NSString).lastPathComponent) exited \(p.terminationStatus)") }
    return String(decoding: data, as: UTF8.self)
}
