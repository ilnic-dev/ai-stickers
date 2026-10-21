# AI Stickers

**Send a thought to a Telegram bot — it shows up as a sticky note on your Mac.**

[Русская версия](README.ru.md)

![Ideas panel dropped down from the menu bar and two stickers pinned to the desktop](docs/screenshot.png)

Ideas come at random moments, and they get lost across dozens of chats and notes apps.
AI Stickers gives them one inbox: a private Telegram bot. Type or dictate a messy thought,
and a few seconds later it sits on your Mac as a short, tidy sticky note with a summary and
a checklist, one click away in the menu bar, or pinned right on your desktop.

## How it works

```
Telegram  ──►  AI Stickers.app on your Mac
(text or voice)   │
                  ├─ voice → text locally: ffmpeg + whisper.cpp
                  ├─ text → sticker via your `claude` CLI (Haiku):
                  │    title · 1–3 sentence summary · todos · up to 2 of your tags
                  └─ sticker → the ideas panel under the menu bar icon
```

- **No server.** The app long-polls Telegram itself. Telegram keeps messages for 24 hours,
  so ideas you send while the Mac sleeps arrive when it wakes.
- **No API keys.** Summaries go through the `claude` CLI and your Claude subscription.
- **Nothing gets lost.** If Claude fails, the raw text becomes the sticker.

## What happens to a message

```
you ──► Telegram ──► AI Stickers on your Mac ──► sticker in the panel
          │  keeps it until the app      │  "typing…" in the chat while it works
          │  picks it up (max 24 h)      └─► reply "📌 Title #tags" = saved
```

1. You send text or a voice note. Telegram holds it on its servers.
2. The running app is always waiting for new messages and gets it within a second. The chat shows "typing…".
3. A voice note is transcribed on your Mac (about 5 s per phrase with `large-v3`).
4. Claude turns the text into a sticker (about 5 s).
5. The sticker is saved, appears in the panel, and the bot replies **📌 Title #tags**.

**The 📌 reply is your receipt.** If it hasn't come, the idea isn't on your Mac yet.

| Situation | What happens |
|---|---|
| Mac on, app running | Sticker in 5–15 s, 📌 reply. |
| Mac asleep or lid closed | Messages wait in Telegram. On wake the app fetches them in order and each one gets its 📌. |
| Mac off, or the app quit | Same: they arrive when the app starts again (at login, if you allowed it). |
| No internet on the Mac | The app retries every 5 s and catches up when the network is back. |
| Not picked up for **more than 24 h** | Telegram drops undelivered bot messages after 24 h; those are lost. Send them again. |
| Processing failed (unreadable voice, file over 20 MB) | The bot replies "⚠️ …". That message is not retried: send it again. |
| Claude unavailable (signed out, usage limit) | The sticker is still saved, with your original text as its title and summary. |
| App crashed in the middle of a message | That message is delivered again on the next start (a duplicate is possible). |
| The app runs on two Macs | Don't: two copies reading one bot take messages from each other. Run it on one Mac. |

## Features

- **Menu bar icon** 📝 with the number of open ideas next to it. Click it to drop down the panel; click outside, click the icon again or press Esc to close it.
- **Cards expand on hover**: summary, a checklist (ticks are saved), tags, a copy button (title, summary, checklist and tags as text) and delete with a few seconds to undo.
- **Tags.** Filter chips at the top of the panel; pick several at once. On a card, `×` removes a tag and `+ тег` adds an existing or a new one.
- **Mixed Russian and English voice notes** come out right: English terms stay in Latin script, and the sticker is written in the language you mostly spoke.
- **`#tag` in a message** sets that tag right away. Claude adds up to 2 more, but only from tags you already use.
- **«позже» (later)** is a built-in tag that hides ideas that are not relevant yet; one click shows them again.
- **Pin to the desktop.** Drag a card out of the panel and it becomes a free-floating sticker. Move it by its ✥ handle, hover it to see the checklist, send it back to the panel with one click.
- **Right-click the icon** for the menu: show ideas, launch at login, interface language, quit.
- **English or Russian interface**, switched in the menu bar («Язык / Language»); it follows the system language by default. Stickers stay in the language you spoke them in.
- **Can start at login** (it asks on first launch), has no Dock icon, and only one copy runs at a time.

## Requirements

- macOS 14 or later
- Xcode or the Command Line Tools, only to build from source
- [Homebrew](https://brew.sh): `brew install ffmpeg whisper-cpp`
- A whisper.cpp model from [huggingface.co/ggerganov/whisper.cpp](https://huggingface.co/ggerganov/whisper.cpp/tree/main): `ggml-large-v3.bin` (3 GB, recommended: handles Russian mixed with English) or `ggml-small.bin` (fast, weaker on mixed speech)
- [Claude Code](https://claude.com/claude-code) installed and signed in (`claude` on your machine)
- A Telegram account

## Install

1. **Create a bot.** Message [@BotFather](https://t.me/BotFather), send `/newbot`, copy the token.
2. **Write the config** at `~/.config/ai-stickers.env`:

   ```
   TELEGRAM_BOT_TOKEN=123456:ABC...
   ```

3. **Get the app**, one of two ways:

   - **Download** `AI-Stickers-<version>.zip` from the [latest release](https://github.com/nitsiyevskii/ai-stickers/releases/latest),
     unzip it, move **AI Stickers.app** to Applications and open it. The app isn't notarized, so macOS
     blocks the first launch: open **System Settings → Privacy & Security** and click **Open Anyway**
     (or run `xattr -dr com.apple.quarantine "/Applications/AI Stickers.app"`).
   - **Or build it** (needs Xcode or the Command Line Tools):

     ```bash
     git clone https://github.com/nitsiyevskii/ai-stickers.git
     cd ai-stickers
     ./scripts/install.sh
     ```

     This builds `AI Stickers.app`, copies it to `/Applications` and starts it. Run the same command
     to update after pulling new code.

   On first launch the app asks whether to open at login; change it later in the icon's menu.

4. **Claim the bot.** Send it any message. It replies with your Telegram ID; add it to the config:

   ```
   TELEGRAM_USER_ID=123456789
   ```

   Then restart the app (right-click the menu bar icon → «Выйти», then open AI Stickers from Applications).
   From now on the bot accepts messages only from you and ignores everyone else.

## Configuration

`~/.config/ai-stickers.env`, one `KEY=value` per line; lines starting with `#` are comments.

| Key | Required | Default |
|---|---|---|
| `TELEGRAM_BOT_TOKEN` | yes | — |
| `TELEGRAM_USER_ID` | yes, after step 4 | — |
| `WHISPER_MODEL` | no | `ggml-large-v3.bin` in `~/.cache/hyperframes/whisper/models/` if present, else `ggml-small.bin` there |
| `WHISPER_PROMPT` | no | — (extra words to expect, e.g. `Notion, Figma, my-project`) |
| `FFMPEG` | no | `/opt/homebrew/bin/ffmpeg` |
| `WHISPER_CLI` | no | `/opt/homebrew/bin/whisper-cli` |
| `CLAUDE_BIN` | no | `~/.local/bin/claude` |

Paths must be absolute: an app started at login gets no shell `PATH`.
Point `WHISPER_MODEL` at wherever you saved the model.

Stickers are stored in `~/Library/Application Support/AiStickers/stickers.json`.

## Privacy

- **Voice** is transcribed on your Mac; the audio goes nowhere else.
- **Text** of each idea, plus your tag names, is sent to Claude through your own `claude` CLI to make the summary.
- **Telegram** carries your messages, as with any bot. The token stays in your local config and is never logged.
- **Stickers** are a local JSON file. No server, account or analytics.

## Development

```bash
swift build && swift test   # the definition of "correct" for every change
swift run                   # dev run: no launch at login, no single-instance check
```

| File | Role |
|---|---|
| `Sources/AiStickers/main.swift` | config, menu bar menu, launch at login, startup |
| `Sources/AiStickers/Bot.swift` | Telegram polling, voice → text, idea → sticker via `claude -p` |
| `Sources/AiStickers/Store.swift` | sticker model, JSON storage, filters and tags (pure, tested) |
| `Sources/AiStickers/Board.swift` | windows: the menu bar panel, pinned stickers, dragging |
| `Sources/AiStickers/Views.swift` | SwiftUI views |
| `scripts/build-app.sh` | builds a universal, signed `AI Stickers.app` with its icon |
| `scripts/install.sh` | builds it and installs into `/Applications` |
| `scripts/release.sh` | builds it and publishes a GitHub release: `scripts/release.sh 1.2.0` |
| `Resources/AppIcon.png` | app icon source (1024 px) |

Plain SwiftPM, no dependencies. Every change goes through its own branch and a pull request
that explains what changed and how it works. Rules for contributors and coding agents are in
[CLAUDE.md](CLAUDE.md) and [AGENTS.md](AGENTS.md).

## Limitations

- Telegram is the only input for now.
- The download is ad-hoc signed, not notarized: macOS asks you to confirm the first launch once.
- Tag colors follow alphabetical order, so adding a tag can shift the colors of others.

## License

[MIT](LICENSE) © Ilya Nitsiyeuski
