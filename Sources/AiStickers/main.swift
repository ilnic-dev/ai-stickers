import AppKit
import ServiceManagement

struct Config {
    static let path = NSString(string: "~/.config/ai-stickers.env").expandingTildeInPath

    let token: String
    let userId: Int64?
    let ffmpeg: String
    let whisper: String
    let whisperModel: String
    let whisperPrompt: String  // extra words whisper should expect, e.g. names and jargon you use
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
            // large-v3 handles Russian mixed with English far better than small; use it when it's there.
            whisperModel: env["WHISPER_MODEL"] ?? ["large-v3", "small"]
                .map { "\(home)/.cache/hyperframes/whisper/models/ggml-\($0).bin" }
                .first { FileManager.default.fileExists(atPath: $0) } ?? "\(home)/.cache/hyperframes/whisper/models/ggml-small.bin",
            whisperPrompt: env["WHISPER_PROMPT", default: ""],
            claude: env["CLAUDE_BIN", default: "\(home)/.local/bin/claude"]
        )
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    lazy var board = Board(store: store, anchor: { [unowned self] in status.button?.window?.frame })
    var status: NSStatusItem!
    private var menu = NSMenu()
    private var loginItem = NSMenuItem()
    private var configMissing = false

    /// Launch at login and the single-instance check need an .app bundle; `swift run` has none.
    private var bundleID: String? { Bundle.main.bundleIdentifier }
    private let loginOffKey = "launchAtLoginOff"

    /// Opening the app again from Applications or Spotlight shows the panel: the way in if the
    /// menu bar icon is hidden behind the notch.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        board.setOpen(true)
        return false
    }

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

        // Left click opens the panel, right (or ⌃) click the menu.
        status = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        status.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "AI Stickers")
        status.button?.imagePosition = .imageLeading
        status.button?.target = self
        status.button?.action = #selector(statusClicked)
        status.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
        store.onChange = { [unowned self] in
            board.storeChanged()
            showCount()
        }
        showCount()
        board.start()

        if let cfg = Config.load() {
            Task { await Bot(cfg: cfg, store: store).run() }
        } else {
            configMissing = true
        }
        buildMenu()
    }

    /// Rebuilt whenever the interface language changes; menu titles are plain strings.
    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false  // so the disabled login item stays disabled under `swift run`
        if configMissing {
            menu.addItem(withTitle: tr("⚠️ Нет TELEGRAM_BOT_TOKEN в ", "⚠️ No TELEGRAM_BOT_TOKEN in ") + Config.path, action: nil, keyEquivalent: "")
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: tr("Показать идеи", "Show ideas"), action: #selector(showIdeas), keyEquivalent: "").target = self

        loginItem = NSMenuItem(title: "", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.isEnabled = bundleID != nil
        menu.addItem(loginItem)

        // Named in both languages so it can be found whichever one is on.
        let language = NSMenuItem(title: "Язык / Language", action: nil, keyEquivalent: "")
        language.submenu = NSMenu()
        for (title, english) in [("Русский", false), ("English", true)] {
            let item = NSMenuItem(title: title, action: #selector(pickLanguage(_:)), keyEquivalent: "")
            item.target = self
            item.tag = english ? 1 : 0
            item.state = Lang.shared.english == english ? .on : .off
            language.submenu?.addItem(item)
        }
        menu.addItem(language)

        menu.addItem(.separator())
        menu.addItem(withTitle: tr("Выйти", "Quit"), action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        self.menu = menu
        applyLaunchAtLogin()
    }

    @objc private func showIdeas() { board.setOpen(true) }

    @objc private func statusClicked() {
        let event = NSApp.currentEvent
        // Without a token the menu is where the warning is, so a plain click shows it too.
        if configMissing || event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
            status.button?.highlight(true)
            menu.popUp(positioning: nil, at: NSPoint(x: 0, y: (status.button?.bounds.height ?? 22) + 4), in: status.button)
            status.button?.highlight(false)
        } else {
            board.toggle()
        }
    }

    /// Open ideas next to the icon (pinned ones too, "позже" not), nothing when there are none.
    private func showCount() {
        let count = store.stickers.filter { !$0.isLater }.count
        status.button?.title = count > 0 ? " \(count)" : ""
        status.button?.setAccessibilityLabel(tr("AI Stickers, идей: ", "AI Stickers, ideas: ") + "\(count)")
    }

    @objc private func pickLanguage(_ item: NSMenuItem) {
        Lang.shared.set(english: item.tag == 1)  // SwiftUI views redraw by themselves
        buildMenu()
        showCount()  // its VoiceOver label is translated too
    }

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
        loginItem.title = tr("Запускать при входе", "Launch at login")
        guard bundleID != nil else { return }
        let service = SMAppService.mainApp
        let off = UserDefaults.standard.bool(forKey: loginOffKey)
        if off && service.status != .notRegistered {
            try? service.unregister()
        } else if !off && service.status == .notRegistered {
            try? service.register()
        }
        loginItem.state = service.status == .enabled ? .on : .off
        if service.status == .requiresApproval {
            loginItem.title = tr("Запускать при входе — разрешить в Настройках", "Launch at login — allow in System Settings")
        }
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    let delegate = AppDelegate()
    app.delegate = delegate
    app.run()
}
