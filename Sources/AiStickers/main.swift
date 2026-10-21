import AppKit
import ServiceManagement

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
    private let loginItem = NSMenuItem(title: "Запускать при входе", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")

    /// Launch at login and the single-instance check need an .app bundle; `swift run` has none.
    private var bundleID: String? { Bundle.main.bundleIdentifier }
    private let loginOffKey = "launchAtLoginOff"

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Two copies would both poll Telegram and fight over every update. The older one stays,
        // so two copies starting together can't both quit.
        let me = NSRunningApplication.current
        if let id = bundleID, NSRunningApplication.runningApplications(withBundleIdentifier: id).contains(where: {
            $0 != me && ($0.launchDate ?? .distantPast, $0.processIdentifier) < (me.launchDate ?? .distantPast, me.processIdentifier)
        }) {
            NSApp.terminate(nil)
            return
        }

        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        status.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "AI Stickers")
        let menu = NSMenu()
        menu.autoenablesItems = false  // so the disabled login item stays disabled under `swift run`
        status.menu = menu

        store.onChange = { [unowned self] in board.syncPinned() }
        board.start()

        if let cfg = Config.load() {
            Task { await Bot(cfg: cfg, store: store).run() }
        } else {
            menu.addItem(withTitle: "⚠️ Нет TELEGRAM_BOT_TOKEN в \(Config.path)", action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: "Показать идеи", action: #selector(showIdeas), keyEquivalent: "").target = self
        loginItem.target = self
        loginItem.isEnabled = bundleID != nil
        menu.addItem(loginItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Выйти", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        applyLaunchAtLogin()
    }

    @objc private func showIdeas() { board.setOpen(true) }

    /// Acts on what the checkmark shows, not on the stored flag, so a failed register can't invert the click.
    @objc private func toggleLaunchAtLogin() {
        if SMAppService.mainApp.status == .requiresApproval {
            SMAppService.openSystemSettingsLoginItems()  // the user switched it off there; only they can allow it
            return
        }
        UserDefaults.standard.set(loginItem.state == .on, forKey: loginOffKey)
        applyLaunchAtLogin()
    }

    /// On by default; the menu checkmark shows what macOS actually has registered.
    private func applyLaunchAtLogin() {
        guard bundleID != nil else { return }
        let service = SMAppService.mainApp
        let off = UserDefaults.standard.bool(forKey: loginOffKey)
        if off && service.status != .notRegistered {
            try? service.unregister()
        } else if !off && service.status == .notRegistered {
            try? service.register()
        }
        loginItem.state = service.status == .enabled ? .on : .off
        loginItem.title = service.status == .requiresApproval
            ? "Запускать при входе — разрешить в Настройках"
            : "Запускать при входе"
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
