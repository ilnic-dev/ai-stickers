import AppKit

struct Config {
    static let path = NSString(string: "~/.config/ai-stickers.env").expandingTildeInPath

    let token: String
    let userId: Int64?
    let ffmpeg: String
    let whisper: String
    let whisperModel: String
    let claude: String

    // KEY=VALUE lines; a GUI app gets no shell PATH, so binaries are absolute paths.
    static func load() -> Config? {
        guard let text = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }
        var env: [String: String] = [:]
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { env[kv[0]] = kv[1] }
        }
        guard let token = env["TELEGRAM_BOT_TOKEN"], !token.isEmpty else { return nil }
        let home = NSHomeDirectory()
        return Config(
            token: token,
            userId: env["TELEGRAM_USER_ID"].flatMap { Int64($0) },
            ffmpeg: env["FFMPEG", default: "/opt/homebrew/bin/ffmpeg"],
            whisper: env["WHISPER_CLI", default: "/opt/homebrew/bin/whisper-cli"],
            whisperModel: env["WHISPER_MODEL", default: "\(home)/.cache/hyperframes/whisper/models/ggml-small.bin"],
            claude: env["CLAUDE_BIN", default: "\(home)/.local/bin/claude"]
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    lazy var board = Board(store: store)
    var status: NSStatusItem!

    func applicationDidFinishLaunching(_ notification: Notification) {
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "AI Stickers")
        let menu = NSMenu()
        status.menu = menu

        store.onChange = { [unowned self] in board.syncPinned() }
        board.start()

        if let cfg = Config.load() {
            Task { await Bot(cfg: cfg, store: store).run() }
        } else {
            menu.addItem(withTitle: "⚠️ Нет TELEGRAM_BOT_TOKEN в \(Config.path)", action: nil, keyEquivalent: "")
        }
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
