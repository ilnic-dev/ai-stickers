import AppKit
import ServiceManagement

struct Config {
    static let path = NSString(string: "~/.config/ai-stickers.env").expandingTildeInPath

    let token: String?
    let userId: Int64?
    let ffmpeg: String
    let whisper: String
    let whisperModel: String
    let whisperPrompt: String  // extra words whisper should expect, e.g. names and jargon you use
    let claude: String

    /// Both the token and the owner are known; until then the setup window is what the app shows.
    var isSetUp: Bool { token != nil && userId != nil }

    // KEY=VALUE lines; a GUI app gets no shell PATH, so binaries are absolute paths.
    static func load() -> Config {
        var env: [String: String] = [:]
        let text = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
        for line in text.split(separator: "\n") where !line.hasPrefix("#") {
            let kv = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if kv.count == 2 { env[kv[0]] = kv[1] }
        }
        let home = NSHomeDirectory()
        return Config(
            token: env["TELEGRAM_BOT_TOKEN"].flatMap { $0.isEmpty ? nil : $0 },
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

    /// Sets one key in the config file, keeping every other line. The file holds the bot token: owner-only.
    private static let writing = NSLock()  // the bot (its own task) and the setup window both write

    static func set(_ key: String, _ value: String, in file: String = path) {
        writing.lock()
        defer { writing.unlock() }
        let url = URL(fileURLWithPath: file)
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        lines.removeAll { $0.split(separator: "=", maxSplits: 1).first?.trimmingCharacters(in: .whitespaces) == key }
        while lines.last?.isEmpty == true { lines.removeLast() }
        lines.append("\(key)=\(value)")
        try? (lines.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file)
    }
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let store = Store()
    lazy var board = Board(store: store, anchor: { [unowned self] in status.button?.window?.frame })
    var status: NSStatusItem!
    private var menu = NSMenu()
    private var loginItem = NSMenuItem()
    private var botTask: Task<Void, Never>?
    /// One-time code in the setup window's link to the bot; a new one for every bot start.
    private var claimCode = ""
    private var setup: OnboardingWindow?

    /// Launch at login and the single-instance check need an .app bundle; `swift run` has none.
    private var bundleID: String? { Bundle.main.bundleIdentifier }
    private let loginOffKey = "launchAtLoginOff"
    private let loginAskedKey = "launchAtLoginAsked"

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

        startBot()
        buildMenu()
        if !Config.load().isSetUp {
            showSetup()  // asks about launch at login on its last step
        } else if bundleID != nil && !UserDefaults.standard.bool(forKey: loginAskedKey) {
            DispatchQueue.main.async { self.askLaunchAtLogin() }  // after the icon is up
        }
    }

    /// (Re)starts the bot with whatever token the config holds; the old one stops polling.
    private func startBot() {
        botTask?.cancel()
        let cfg = Config.load()
        guard let token = cfg.token else { return }
        claimCode = UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(16).lowercased()
        setup?.model.claimCode = claimCode
        let bot = Bot(cfg: cfg, token: token, store: store, claimCode: claimCode, onClaim: { [weak self] name in
            await MainActor.run { self?.claimed(by: name) }
        })
        botTask = Task { await bot.run() }
    }

    private func claimed(by name: String) {
        setup?.model.claimed(by: name)
        buildMenu()
    }

    @objc private func showSetup() {
        if setup == nil {
            setup = OnboardingWindow(model: Onboarding(
                config: Config.load(),
                claimCode: claimCode,
                launchAtLogin: !UserDefaults.standard.bool(forKey: loginOffKey),
                connect: { [unowned self] token in
                    Config.set("TELEGRAM_BOT_TOKEN", token)
                    Config.set("TELEGRAM_USER_ID", "")  // a new bot gets a new owner: whoever presses Start
                    startBot()
                    buildMenu()
                },
                finish: { [unowned self] launchAtLogin in
                    if bundleID != nil {
                        UserDefaults.standard.set(!launchAtLogin, forKey: loginOffKey)
                        UserDefaults.standard.set(true, forKey: loginAskedKey)
                        applyLaunchAtLogin()
                    }
                    setup = nil
                    board.setOpen(true)
                }))
        }
        setup?.show()
    }

    /// First launch only: whether to start with the Mac is the user's call, not a silent default.
    private func askLaunchAtLogin() {
        NSApp.activate(ignoringOtherApps: true)  // a menu bar app's alert would open behind other windows
        let alert = NSAlert()
        alert.messageText = tr("Запускать AI Stickers при входе в систему?", "Open AI Stickers when you log in?")
        alert.informativeText = tr("Тогда иконка будет в меню-баре сразу после включения мака. Это можно поменять в меню иконки (правый клик).",
                                   "Then its icon is in the menu bar right after your Mac starts. You can change this in the icon's menu (right-click).")
        alert.addButton(withTitle: tr("Запускать", "Open at login"))
        alert.addButton(withTitle: tr("Не надо", "Not now"))
        let yes = alert.runModal() == .alertFirstButtonReturn
        UserDefaults.standard.set(!yes, forKey: loginOffKey)
        UserDefaults.standard.set(true, forKey: loginAskedKey)
        applyLaunchAtLogin()
    }

    /// Rebuilt whenever the interface language changes; menu titles are plain strings.
    private func buildMenu() {
        let menu = NSMenu()
        menu.autoenablesItems = false  // so the disabled login item stays disabled under `swift run`
        if !Config.load().isSetUp {
            menu.addItem(withTitle: tr("⚠️ Бот не подключён — настроить…", "⚠️ Bot not connected — set up…"), action: #selector(showSetup), keyEquivalent: "").target = self
            menu.addItem(.separator())
        }
        menu.addItem(withTitle: tr("Показать идеи", "Show ideas"), action: #selector(showIdeas), keyEquivalent: "").target = self
        menu.addItem(withTitle: tr("Настроить бота…", "Set up the bot…"), action: #selector(showSetup), keyEquivalent: "").target = self

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
        if !Config.load().isSetUp && event?.type != .rightMouseUp {
            showSetup()  // nothing to show in the panel until the bot is connected
        } else if event?.type == .rightMouseUp || event?.modifierFlags.contains(.control) == true {
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
        UserDefaults.standard.set(true, forKey: loginAskedKey)
        applyLaunchAtLogin()
    }

    /// Follows the first-launch answer or the menu toggle; the checkmark shows what macOS has registered.
    private func applyLaunchAtLogin() {
        loginItem.title = tr("Запускать при входе", "Launch at login")
        guard bundleID != nil else { return }
        let service = SMAppService.mainApp
        let off = UserDefaults.standard.bool(forKey: loginOffKey)
        if !UserDefaults.standard.bool(forKey: loginAskedKey) {
            // Not asked yet: leave macOS as it is until the first-launch question is answered.
        } else if off && service.status != .notRegistered {
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
