# Agent contract

Swift (language mode 5) · SwiftUI + AppKit · SwiftPM · Swift Testing

Determine your role from the prompt.

---

## Role A — Worker (default)

You were delegated one scoped task by an orchestrator.

- Touch **only** the files named in the prompt. If the task requires a file that
  was not named, stop and report it rather than expanding scope.
- Run the verification command from the prompt. Do not claim success without it.
- Do not commit, branch, or open PRs unless explicitly told to.
- Do not modify `.orchestrator/` — the orchestrator owns the ledger.
- Final output: **≤10 lines.** Files changed, verification result, blockers.
  No narration.

### Architecture
- `Sources/AiStickers/Bot.swift`: Telegram, transcription, Claude. No AppKit/SwiftUI.
- `Sources/AiStickers/Store.swift`: model, persistence, pure logic. No AppKit.
- `Sources/AiStickers/Board.swift`, `Views.swift`: windows and views; state changes go through `Store`.

Never: write `stickers.json` outside `Store`; import AppKit into `Bot.swift` or `Store.swift`.

### House rules
- New `Sticker` fields decode with `decodeIfPresent` + default; old files must still load.
- No new dependencies; `Package.swift` changes need the orchestrator's approval.
- Binaries come from `Config` as absolute paths.
- User-facing strings in Russian.
- Tests use Swift Testing (`import Testing`, `@Test`, `#expect`) and test behaviour through `Store`'s public functions.

### Verify
```
swift build && swift test
```

---

## Role B — Fallback orchestrator

Invoked as "Resume orchestration per AGENTS.md" — the primary orchestrator ran
out of quota. You are driving now.

### Resume protocol — before any action
1. `cat .orchestrator/handoff.md`
2. `cat .orchestrator/STATE.md`
3. `orch status`
4. `git log --oneline -15 && git status --short`
5. Restate: **goal / last verified task / next task / blockers**.
6. Re-verify anything in `delegated` state. A delegated task is a claim, not a fact.
7. Only then act.

**Never infer project state from conversation history.** `.orchestrator/` is the
source of truth.

### While orchestrating
- One task = one ledger entry = one commit:
  `orch add` → `orch start` → `orch done | orch block`
- Append architectural decisions to `STATE.md`; never rewrite existing ones.
- Run `orch handoff` after each completed task.
- Leave `blocked` tasks blocked. Surface them to the human rather than guessing.
- Always verify yourself with the command above.
