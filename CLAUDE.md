# AI Stickers

Native macOS app: ideas sent to a Telegram bot become sticky notes on screen.

## Stack
Swift 6 toolchain (language mode 5) · SwiftUI + AppKit · SwiftPM, no dependencies · Swift Testing

## Verify
```
swift build && swift test
```
Run it yourself. There is no CI: verification is local, PRs are still required.

## Architecture — one executable target, three concerns
- `Bot.swift`: Telegram polling, voice → text, idea → sticker via `claude -p`. No AppKit/SwiftUI.
- `Store.swift`: `Sticker` model, JSON persistence, pure filtering/tag logic. No AppKit.
- `Board.swift` / `Views.swift`: windows and SwiftUI views. Read and mutate state only through `Store`.
- `main.swift`: config loading and app wiring.
- `Onboarding.swift`: the setup window; writes the config only through `Config.set`.

Boundary rules:
- UI never writes `stickers.json` directly; `Store` is the only writer.
- `Bot` reaches `Store` only through `await store.…` (Store is `@MainActor`).

## Never modify without asking
`Package.swift` (adding dependencies), the `~/.config/ai-stickers.env` keys, the on-disk shape of `stickers.json`.

## Conventions workers get wrong here
- `stickers.json` must stay readable: every new `Sticker` field is decoded with `decodeIfPresent` and a default.
- External tools (ffmpeg, whisper-cli, claude) are absolute paths from `Config`; a GUI app has no shell `PATH`.
- User-facing strings go through `tr(ru, en)`, Russian first; never a bare literal.
- Never log or echo the Telegram token.

## Delivery
Every feature: own branch → PR whose body explains what changed and how it works, with `Closes #N` → local verify → review → squash-merge → delete branch.
