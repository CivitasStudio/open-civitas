# Open Civitas Phase 3 — `civitas-shell` Spec

**Status:** Draft — awaiting John's review
**Author:** Wayland
**Date:** 2026-05-09
**Scope:** Full-screen TTY chat client. v0 = chat-only; built and tested against Bob (Phase 2). Boot-into-chat (`getty@tty1` swap) and ISO integration are Phase 4.

---

## Mission

`civitas-shell` is the OS's primary user interface. The user logs in and lands directly in conversation with their agent. Bash exists, but it is reachable only via the `/bash` slash-command escape. This is the shell that makes the "Chromebook for an AI agent" framing real.

v0 is intentionally narrow:
- **Chat-only.** No ambient sidebars, no system-status panels, no multi-tab. Just transcript + input.
- **Local agent only.** Talks to the OpenClaw gateway at `http://127.0.0.1:18789`. No remote endpoints.
- **One target: Bob.** Built and validated against the Phase 2 VM. Other agents may work, but Bob is the supported substrate.

---

## UX

### Layout

```
┌──────────────────────────────────────────────────────────────┐
│                                                              │
│  Bob                                                         │
│    Hello. I'm Bob, your test agent. How can I help?          │
│                                                              │
│  You                                                         │
│    What model are you running on?                            │
│                                                              │
│  Bob                                                         │
│    I'm running on gemma4:e2b via local Ollama, no external   │
│    APIs.                                                     │
│                                                              │
│                                                              │
├──────────────────────────────────────────────────────────────┤
│ > _                                                          │
└──────────────────────────────────────────────────────────────┘
```

- **Transcript region** — scrollable, fills the terminal minus one input row. Speaker labels (`Bob` / `You`) on their own line; messages indented two spaces. No timestamps in v0.
- **Input row** — single line by default; `Shift-Enter` adds a newline (input area grows up to 5 rows, then scrolls internally). `Enter` sends.
- **Status overlay** — when the agent is generating, a transient status line overlays the bottom border: `thinking ●●●` (animated). When the gateway or model is unhealthy, the same line shows the error in red. Not a permanent status bar — appears only when there is something to say.
- **Color** — minimal. Speaker labels bold. User input column inherits terminal default. Errors red. No theming in v0.

### Streaming

Token-streaming is mandatory. Gemma4:e2b on CPU is ~5–10 tokens/sec; without streaming the UX is unusable. Tokens render into the active `Bob` block as they arrive over SSE.

### Keys

| Key | Behavior |
|---|---|
| `Enter` | Send message |
| `Shift-Enter` | Newline in input |
| `Ctrl-L` | Clear visible transcript (scrollback retained on disk) |
| `Ctrl-C` | Cancel in-flight generation; do **not** exit the shell |
| `PgUp` / `PgDn` | Scroll transcript |
| `Ctrl-D` on empty input | No-op (intentional — exiting is `/exit` if not boot-locked) |

---

## Architecture

```
┌──────────────────────┐    HTTP POST     ┌──────────────────────┐
│   civitas-shell      │ ──────────────►  │  OpenClaw gateway    │
│   (Node + ink)       │ ◄── SSE stream ──│  127.0.0.1:18789     │
└──────────────────────┘                  └──────────────────────┘
        │                                            │
        │ reads ~/.openclaw/openclaw.json            │ routes via channel adapter:
        │ for bearer token + channel ID              │ channels.civitasShell
        │                                            ▼
        │                                  ┌──────────────────────┐
        │                                  │  agent (Bob)         │
        │                                  │  ollama/gemma4:e2b   │
        ▼                                  └──────────────────────┘
~/.openclaw/workspace/civitas-shell/
  transcripts/<session-id>.jsonl  (append-only history)
```

### Runtime

**Node + [ink](https://github.com/vadimdemedes/ink) (React-based TUI).** Reuses the Node LTS that Phase 1 installs — no new runtime dependency. Ships as `@civitasstudio/civitas-shell` on npm; `install.sh --with-civitas-shell` performs `npm install -g @civitasstudio/civitas-shell`.

Why ink over alternatives:
- **vs. blessed** — ink's React model handles streaming token updates and component re-renders cleanly; blessed requires manual repaint logic.
- **vs. Python textual / Go bubbletea / Rust ratatui** — all add a new toolchain to the substrate. Node is already there.

### Transport

**HTTP + SSE.** Mirrors how OpenClaw's existing web channel speaks to its frontend.

- `POST /channels/civitas-shell/message` — body: `{sessionId, text}`. Returns 202 + `eventStreamUrl`.
- `GET <eventStreamUrl>` — SSE; emits `token`, `tool_call_start`, `tool_call_end`, `done`, `error` events.
- Bearer token from `agents.defaults.bearerToken` (or whichever `openclaw.json` field already holds it — verify against current OpenClaw release before implementation).

### Channel registration

`civitas-shell` registers itself as a first-class OpenClaw channel under `channels.civitasShell` in `openclaw.json`. The shell process talks to the gateway over the standard channel API; the gateway routes inbound messages into the agent's session and dispatches outbound replies back to the shell. Same pattern as Telegram / web.

This means heartbeats and agent-initiated messages can target civitas-shell as a delivery channel — useful later (e.g., a scheduled reminder showing up in-shell at boot).

**Open implementation question:** does OpenClaw 2026.5.7 already expose a generic local-channel adapter, or do we need to ship one as part of this phase? **To verify with Alex / handbook before code.** If we need to ship one, scope grows: a small Node module registering `civitasShell` as a channel adapter inside the gateway. Track as a Phase 3 Phase-A deliverable.

### Persistence

Each shell launch is one session. Transcripts stored at:

```
~/.openclaw/workspace/civitas-shell/
  transcripts/
    2026-05-09T19-32-00Z.jsonl
    2026-05-09T20-15-00Z.jsonl
```

JSONL: one record per message (`{ts, role, text}`). On launch, the most recent transcript is replayed into the screen (last N=50 messages, configurable). The agent's own session memory is owned by OpenClaw — civitas-shell's transcripts exist only so the user can see what was said.

---

## Slash Commands (v0)

| Command | Behavior |
|---|---|
| `/bash` | Suspend the chat UI, spawn `$SHELL` (or `/bin/bash`) as a child PTY taking over the terminal. On shell exit, restore civitas-shell with the transcript intact. |
| `/clear` | Clear visible transcript (does **not** delete on-disk history). |
| `/model` | Print current agent model + gateway health one-liner. |
| `/help` | List commands. |
| `/exit` | Exit civitas-shell to the parent process. **Disabled when launched as login shell or via getty@tty1** — in that mode there is no parent to exit to. |

Slash commands are detected only when the input begins with `/` and contains no spaces before the word boundary. Anything else is sent to the agent verbatim — including messages that happen to start with `/` (use `\/foo` to send a literal slash-prefix message to the agent).

Punted to v1: file attachments, image render, `/files`, history search, `/agent` switching, theming.

---

## Configuration & install integration

**Installer flag:** `install.sh --with-civitas-shell` (default off in Phase 3; default **on** when launched in Phase 4 ISO mode).

When enabled, the installer:
1. `npm install -g @civitasstudio/civitas-shell` (after Node is in place).
2. Adds `channels.civitasShell` block to `openclaw.json`.
3. Creates `~/.openclaw/workspace/civitas-shell/transcripts/` directory.
4. Adds a `civitas-shell` binary on PATH.

**Phase 4 will add** a `--boot-mode chat` flag that swaps `getty@tty1.service` for a unit that runs `civitas-shell` directly. Out of scope for Phase 3.

`openclaw.json` block (added by installer):

```json
{
  "channels": {
    "civitasShell": {
      "default": {
        "enabled": true
      }
    }
  }
}
```

No bearer token, secret, or port config in this block — civitas-shell speaks to the gateway over loopback as the same UNIX user, and reuses `agents.defaults.bearerToken` (existing) for the channel API call.

---

## Validation Procedure

All run on Bob (Phase 2 VM) over SSH from Wayland.

### 1. Round-trip on streaming

```bash
ssh bob "civitas-shell --noninteractive --send 'Hello, who are you?'"
```

**Expected:** prints streamed response token-by-token to stdout, exits 0. Response identifies as Bob, references gemma4:e2b, no Anthropic/OpenAI traffic in `journalctl --user -u openclaw-gateway`.

### 2. Slash-command escape

Interactive on `bob` console:
1. Launch `civitas-shell`.
2. Type `/bash`. UI suspends, bash prompt appears.
3. Run `whoami` → returns `bob`.
4. `exit`. Civitas-shell resumes, transcript intact, input focus restored.

### 3. Persistence

1. Launch `civitas-shell`, send "Remember the number 42."
2. `/exit`.
3. Launch `civitas-shell` again. Verify the previous exchange is replayed at top of transcript.
4. Verify file `~/.openclaw/workspace/civitas-shell/transcripts/<ts>.jsonl` exists and contains both turns.

### 4. Cancellation mid-stream

1. Send a long-output prompt ("Write a long essay about cities.").
2. Once tokens start streaming, press `Ctrl-C`.
3. Streaming halts; status line clears; input prompt returns. Shell does **not** exit.

### 5. Gateway-down handling

1. `systemctl --user stop openclaw-gateway` on Bob.
2. Send a message in civitas-shell.
3. **Expected:** red status line `gateway unreachable — retrying…`. When gateway returns, message sends without a re-type.

### 6. No external traffic

While civitas-shell session is open:
```bash
ss -tnp | grep -v '127.0.0.1\|::1' | grep civitas-shell || echo "loopback only"
```
Must print `loopback only`.

---

## Success Criteria (Phase 3 complete)

1. ✅ `npm install -g @civitasstudio/civitas-shell` on Bob succeeds.
2. ✅ `civitas-shell` launches, displays prompt, reads bearer token from `openclaw.json` without manual config.
3. ✅ Streaming round-trip with Bob works end-to-end. Response is persona-aware (Bob, gemma4:e2b).
4. ✅ `/bash` escape and return works without losing transcript or input focus.
5. ✅ Transcripts persist to `~/.openclaw/workspace/civitas-shell/transcripts/` and replay on next launch.
6. ✅ `Ctrl-C` cancels in-flight generation without exiting the shell.
7. ✅ Gateway-down state shows a clear, non-fatal error and recovers without re-typing.
8. ✅ No non-loopback connections originate from the civitas-shell process during a session.
9. ✅ `install.sh --with-civitas-shell` adds the channel block to `openclaw.json` and the binary to PATH.

---

## Explicit Non-Goals for Phase 3

| Not in v0 | Deferred to |
|---|---|
| Boot-into-chat (getty@tty1 swap, login-shell binding) | Phase 4 (ISO + boot integration) |
| Ambient status panels (disk, RAM, gateway state visible at all times) | Post-v1 (or never — chat-only is the design) |
| File attachments, image rendering, multi-tab | v1 |
| History search, agent switching, theming | v1 |
| Multiple concurrent agents per shell | Out of scope until v1 multi-agent story exists |
| Remote agent connections (talking to a non-localhost OpenClaw) | Out of scope; civitas-shell is local-only by design |
| Windows / macOS native packaging | Phase 5 (format wrappers) |

---

## Open Items (resolve before Phase 3 implementation)

1. **Local-channel adapter.** Confirm whether OpenClaw 2026.5.7 already supports a generic `civitasShell`-style channel via existing local adapter, or whether Phase 3 must ship a small adapter module. **Owner:** Wayland to verify against handbook + gateway source on Forge. If new adapter needed, treat as Phase 3-A deliverable before the shell client itself.
2. **Bearer token field.** Confirm exact field name in `openclaw.json` / how channels authenticate to the gateway over loopback. May need none if gateway trusts loopback connections from same UID.
3. **Session ID semantics.** One session per launch (current design) vs. one persistent session that survives relaunches. Persistent is more "agent-OS"-shaped but complicates session pruning. **Recommend one-per-launch in v0**, with relaunch transcript replay closing the UX gap. Revisit if it feels wrong on Bob.

---

## References

- Phase 0 spec: [`docs/v0-spec.md`](v0-spec.md)
- Phase 2 spec: [`docs/v0-phase2-bob-spec.md`](v0-phase2-bob-spec.md)
- OpenClaw essentials: `~/.openclaw/workspace/handbook/openclaw-essentials.md`
- ink (TUI library): https://github.com/vadimdemedes/ink
