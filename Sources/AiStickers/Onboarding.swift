import AppKit
import SwiftUI

/// The setup window: create a bot, paste its token, press Start, done. Shown until the bot has an owner.
@MainActor @Observable
final class Onboarding {
    enum Step: Int { case token = 1, start, done }

    var step: Step
    var token = ""
    var botName: String?
    var owner: String?
    var checking = false
    var error: String?
    var launchAtLogin: Bool
    var claimCode: String
    var tools = Tool.check()

    /// The app saves the token and (re)starts the bot with it.
    let connect: (String) -> Void
    /// "Start" pressed on the last step, with the launch-at-login choice.
    let finish: (Bool) -> Void

    init(config: Config, claimCode: String, launchAtLogin: Bool,
         connect: @escaping (String) -> Void, finish: @escaping (Bool) -> Void) {
        self.claimCode = claimCode
        self.launchAtLogin = launchAtLogin
        self.connect = connect
        self.finish = finish
        step = config.token == nil ? .token : config.userId == nil ? .start : .done
        if let token = config.token {
            Task { botName = try? await Bot.username(token: token) }
        }
    }

    func checkToken() {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty, !checking else { return }
        checking = true
        error = nil
        Task {
            defer { checking = false }
            do {
                botName = try await Bot.username(token: t)
                connect(t)
                step = .start
            } catch {
                self.error = tr("Токен не подошёл. Скопируй его из сообщения BotFather целиком.",
                                "That token didn't work. Copy it whole from BotFather's message.")
            }
        }
    }

    func claimed(by name: String) {
        owner = name
        step = .done
    }

    /// Back to step 1 to connect a different bot (a new token also clears the owner).
    func startOver() {
        token = ""
        botName = nil
        owner = nil
        error = nil
        step = .token
    }
}

/// A tool the app runs, whether it's installed, and the command that installs it.
struct Tool: Identifiable {
    let id: String
    let purpose: String
    let ok: Bool
    let install: String

    static func check() -> [Tool] {
        let c = Config.load()
        let fm = FileManager.default
        return [
            Tool(id: "ffmpeg", purpose: tr("голосовые", "voice notes"),
                 ok: fm.isExecutableFile(atPath: c.ffmpeg), install: "brew install ffmpeg"),
            Tool(id: "whisper-cli", purpose: tr("распознавание речи", "speech to text"),
                 ok: fm.isExecutableFile(atPath: c.whisper), install: "brew install whisper-cpp"),
            Tool(id: tr("модель whisper", "whisper model"), purpose: tr("распознавание речи", "speech to text"),
                 ok: fm.fileExists(atPath: c.whisperModel),
                 install: "mkdir -p ~/.cache/hyperframes/whisper/models && curl -L -o ~/.cache/hyperframes/whisper/models/ggml-large-v3.bin https://huggingface.co/ggerganov/whisper.cpp/resolve/main/ggml-large-v3.bin"),
            Tool(id: "claude", purpose: tr("сводки и теги (войди в аккаунт после установки)", "summaries and tags (sign in after installing)"),
                 ok: fm.isExecutableFile(atPath: c.claude), install: "curl -fsSL https://claude.ai/install.sh | bash && claude"),
        ]
    }
}

@MainActor
final class OnboardingWindow {
    let model: Onboarding
    private let window: NSWindow

    init(model: Onboarding) {
        self.model = model
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 540, height: 620), styleMask: [.titled, .closable],
                          backing: .buffered, defer: false)
        window.title = "AI Stickers"
        window.isReleasedWhenClosed = false
        window.contentView = NSHostingView(rootView: OnboardingView(model: model, close: { [weak self] in self?.window.close() }))
    }

    func show() {
        window.center()
        NSApp.activate(ignoringOtherApps: true)  // a menu bar app's window would open behind others
        window.makeKeyAndOrderFront(nil)
    }
}

struct OnboardingView: View {
    @Bindable var model: Onboarding
    let close: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 14) {
                Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 52, height: 52)
                VStack(alignment: .leading, spacing: 3) {
                    Text(tr("Подключим Telegram-бота", "Let's connect your Telegram bot")).font(.system(size: 20, weight: .bold))
                    Text(tr("Мысли, которые ты пишешь боту, станут стикерами на этом маке.",
                            "Thoughts you send to the bot become sticky notes on this Mac."))
                        .foregroundStyle(.secondary)
                }
            }

            StepCard(number: 1, title: tr("Создай бота и вставь токен", "Create a bot and paste its token"),
                     state: state(of: .token), summary: model.botName.map { "@" + $0 }) {
                Text(tr("Открой @BotFather, отправь /newbot, придумай имя и username, который заканчивается на «bot». В ответ придёт токен вида 123456:ABC…",
                        "Open @BotFather, send /newbot, pick a name and a username ending in “bot”. It replies with a token like 123456:ABC…"))
                    .fixedSize(horizontal: false, vertical: true)
                Button(tr("Открыть @BotFather", "Open @BotFather")) { open("https://t.me/BotFather") }
                HStack {
                    TextField(tr("Вставь токен сюда", "Paste the token here"), text: $model.token)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                        .onSubmit { model.checkToken() }
                    Button(tr("Подключить", "Connect")) { model.checkToken() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(model.token.trimmingCharacters(in: .whitespaces).isEmpty || model.checking)
                }
                if model.checking { ProgressView().controlSize(.small) }
                if let error = model.error { Text(error).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
            }

            StepCard(number: 2, title: tr("Нажми Start у своего бота", "Press Start in your bot"),
                     state: state(of: .start), summary: model.owner) {
                Text(tr("Открой бота кнопкой ниже и нажми Start: так он узнает, что это ты, и дальше будет принимать сообщения только от тебя.",
                        "Open the bot with the button below and press Start: that's how it learns it's you, and from then on it only accepts your messages."))
                    .fixedSize(horizontal: false, vertical: true)
                if let name = model.botName {
                    Button(tr("Открыть @\(name) в Telegram", "Open @\(name) in Telegram")) { open("https://t.me/\(name)?start=\(model.claimCode)") }
                }
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(tr("Жду твоё сообщение боту…", "Waiting for your message to the bot…")).foregroundStyle(.secondary)
                }
                Button(tr("Это не тот бот — вставить другой токен", "Wrong bot — paste a different token")) { model.startOver() }
                    .buttonStyle(.link)
            }

            StepCard(number: 3, title: tr("Готово", "Done"), state: state(of: .done), summary: nil) {
                Text(tr("Пиши или наговаривай боту мысли — они появятся в панели под иконкой в меню-баре.",
                        "Send the bot thoughts as text or voice — they show up in the panel under the menu bar icon."))
                    .fixedSize(horizontal: false, vertical: true)
                Toggle(tr("Запускать AI Stickers при входе в систему", "Open AI Stickers when I log in"), isOn: $model.launchAtLogin)
                HStack {
                    Button(tr("Начать", "Start")) {
                        model.finish(model.launchAtLogin)
                        close()
                    }
                    .keyboardShortcut(.defaultAction)
                    Button(tr("Подключить другого бота", "Connect a different bot")) { model.startOver() }
                        .buttonStyle(.link)
                }
            }

            Divider()
            ToolsList(model: model)
        }
        .padding(24)
        .frame(width: 540)
    }

    private func state(of step: Onboarding.Step) -> StepStatus {
        step.rawValue < model.step.rawValue ? .done : step == model.step ? .active : .upcoming
    }

    private func open(_ link: String) {
        if let url = URL(string: link) { NSWorkspace.shared.open(url) }
    }
}

enum StepStatus { case done, active, upcoming }

/// One numbered step: open while it's the current one, a checked one-liner once done, dimmed before.
struct StepCard<Content: View>: View {
    let number: Int
    let title: String
    let state: StepStatus
    let summary: String?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                ZStack {
                    Circle().fill(state == .upcoming ? Color.secondary.opacity(0.2) : Palette.sticky)
                    if state == .done {
                        Image(systemName: "checkmark").font(.system(size: 11, weight: .bold))
                    } else {
                        Text("\(number)").font(.system(size: 12, weight: .bold))
                    }
                }
                .foregroundStyle(Palette.ink)
                .frame(width: 24, height: 24)
                Text(title).font(.system(size: 14, weight: .semibold))
                if state == .done, let summary { Text(summary).foregroundStyle(.secondary) }
            }
            .opacity(state == .upcoming ? 0.5 : 1)
            if state == .active {
                VStack(alignment: .leading, spacing: 10) { content() }
                    .padding(.leading, 34)
            }
        }
    }
}

/// What the app needs on this Mac, with a copyable install command for anything missing.
struct ToolsList: View {
    let model: Onboarding

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(tr("Что нужно на этом маке", "What this Mac needs")).font(.system(size: 13, weight: .semibold))
                Spacer()
                Button(tr("Проверить снова", "Check again")) { model.tools = Tool.check() }.controlSize(.small)
            }
            ForEach(model.tools) { tool in
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Image(systemName: tool.ok ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .foregroundStyle(tool.ok ? .green : .orange)
                        Text(tool.id).font(.system(size: 12, weight: .medium))
                        Text("— " + tool.purpose).font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                    if !tool.ok {
                        HStack(alignment: .top, spacing: 6) {
                            Text(tool.install)
                                .font(.system(size: 11, design: .monospaced))
                                .textSelection(.enabled)
                                .fixedSize(horizontal: false, vertical: true)
                            Button {
                                NSPasteboard.general.clearContents()
                                NSPasteboard.general.setString(tool.install, forType: .string)
                            } label: { Image(systemName: "doc.on.doc") }
                            .buttonStyle(.borderless)
                            .help(tr("Скопировать команду для Терминала", "Copy the command for Terminal"))
                        }
                        .padding(.leading, 22)
                    }
                }
            }
            if model.tools.contains(where: { !$0.ok }) {
                Text(tr("Без них бот работает, но голосовые не распознаются, а стикеры делаются из исходного текста.",
                        "The bot works without them, but voice notes aren't transcribed and stickers use your raw text."))
                    .font(.system(size: 11)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}
