# Open Civitas Phase 3 — `civitas-shell` Spec

**Status:** Draft v2 — **GREENLIT** (Alex + John, 2026-05-10). All three pre-code gates closed. Implementation may begin.
**Author:** Wayland
**Date:** 2026-05-09 (v1) / 2026-05-10 (v2 — open items closed)
**Scope:** Full-screen TTY chat client. v0 = chat-only; built and tested against Bob (Phase 2). Boot-into-chat (`getty@tty1` swap) and ISO integration are Phase 4.

**v2 changes (2026-05-10, after Forge investigation):**
- Open item #1 (local channel adapter) → **resolved, Phase 3-A dropped.** OpenClaw 2026.5.7 already exposes WebChat WS methods (`chat.send`, `chat.history`, `chat.abort`) on the existing Gateway. civitas-shell becomes a third client of that protocol — no gateway-side code, no new channel plugin, no `openclaw.json` schema changes.
- Open item #2 (auth) → **resolved.** Auth is the existing `gateway.auth.token` / `gateway.auth.password` shared secret (loopback included). No per-channel bearer field.
- Open item #3 (session semantics) → **flipped.** Sessions are gateway-owned and persistent; `chat.history` returns a `sessionId` that subsequent `chat.send` calls reuse. Matches Control UI / macOS app behavior. Local JSONL transcripts dropped — gateway is the source of truth.
- Transport changed from HTTP+SSE → WebSocket (the existing Gateway WS, same protocol the macOS/iOS chat UIs use).

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

Token-streaming is mandatory. Gemma4:e2b on CPU is ~5–10 tokens/sec; without streaming the UX is unusable. Tokens render into the active `Bob` block as they arrive over the WebSocket connection as `chat` gateway events.

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
┌──────────────────────┐   WebSocket (WS)  ┌──────────────────────┐
│   civitas-shell      │ ◄────────────────► │  OpenClaw gateway    │
│   (Node + ink)       │  chat.send/history │  127.0.0.1:18789     │
└──────────────────────┘                    └──────────────────────┘
        │                                            │
        │ reads ~/.openclaw/openclaw.json            │ existing WebChat WS
        │ for gateway.auth.token (shared secret)     │ session routing
        │                                            ▼
        │                                  ┌──────────────────────┐
        │                                  │  agent (Bob)         │
        │                                  │  ollama/gemma4:e2b   │
        └──────────────────────────────────┘
                 no client-side transcript storage —
                 gateway is the source of truth
```

### Runtime

**Node + [ink](https://github.com/vadimdemedes/ink) (React-based TUI).** Reuses the Node LTS that Phase 1 installs — no new runtime dependency. Ships as `@civitasstudio/civitas-shell` on npm; `install.sh --with-civitas-shell` performs `npm install -g @civitasstudio/civitas-shell`.

Why ink over alternatives:
- **vs. blessed** — ink's React model handles streaming token updates and component re-renders cleanly; blessed requires manual repaint logic.
- **vs. Python textual / Go bubbletea / Rust ratatui** — all add a new toolchain to the substrate. Node is already there.

### Transport

**WebSocket — the existing Gateway WS protocol.** Same transport used by the OpenClaw macOS/iOS chat UIs and Control UI. No gateway-side code required; civitas-shell is a third client of an already-shipped protocol.

Key WS methods (confirmed in `src/gateway/server-methods-list.ts` at v2026.5.7):
- `chat.history` — fetch transcript for a session key; returns `sessionId` + message array. Bounded output; oversized entries replaced with placeholder.
- `chat.send` — post a user message; params: `{sessionKey, sessionId?, message, idempotencyKey}`. Gateway streams reply events back over the WS connection.
- `chat.abort` — cancel an in-flight generation. Maps to `Ctrl-C`.

Reply streaming arrives as `chat` gateway events on the WS connection (same event bus as all other gateway pushes).

**Note:** `@openclaw/sdk` exists in the OpenClaw monorepo but is `private: true` and not published to npm. civitas-shell implements the WS protocol directly using the `ws` npm package — no private SDK dependency.

### Auth

civitas-shell reads `gateway.auth.token` (or `gateway.auth.password`) from `~/.openclaw/openclaw.json` and passes it as the WS shared secret on connect. Loopback connections still require this credential per gateway default config. No per-channel bearer token; no new config fields.

### Sessions

Sessions are **gateway-owned and persistent**. On launch:
1. civitas-shell calls `chat.history` with the agent's default session key (`agent:main:main`).
2. Gateway returns the stored transcript + a `sessionId`.
3. Shell renders the last N=50 messages as context, then prompts for input.
4. Each `chat.send` includes the `sessionId` returned by step 2, so reconnects and relaunches continue the same conversation automatically.

Crash/reattach is free — same behavior as Control UI. No client-side JSONL; the gateway JSONL is the canonical record.

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
2. Adds a `civitas-shell` binary on PATH.

That's it. No `openclaw.json` mutations — civitas-shell uses the existing gateway WS endpoint and reads auth from the config file that `install.sh` already writes. No new `channels.*` block needed.

**Phase 4 will add** a `--boot-mode chat` flag that swaps `getty@tty1.service` for a unit that runs `civitas-shell` directly. Out of scope for Phase 3.

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

### 3. Persistence / reconnect

1. Launch `civitas-shell`, send "Remember the number 42."
2. `/exit`.
3. Launch `civitas-shell` again. Verify the previous exchange is replayed at top of transcript via `chat.history`.
4. Verify no new JSONL file is created by civitas-shell — history lives in the gateway session store only.

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
2. ✅ `civitas-shell` launches, connects to Gateway WS, reads auth from `openclaw.json` without manual config.
3. ✅ Streaming round-trip with Bob works end-to-end. Response is persona-aware (Bob, gemma4:e2b).
4. ✅ `/bash` escape and return works without losing transcript or input focus.
5. ✅ Relaunch replays prior conversation via `chat.history`. No client-side JSONL created.
6. ✅ `Ctrl-C` sends `chat.abort` and cancels in-flight generation without exiting the shell.
7. ✅ Gateway-down state shows a clear, non-fatal error and recovers without re-typing.
8. ✅ No non-loopback connections originate from the civitas-shell process during a session.
9. ✅ `install.sh --with-civitas-shell` installs the binary and puts it on PATH. No `openclaw.json` changes required.

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

## Open Items

All three original open items resolved on 2026-05-10 via Forge source inspection (v2026.5.7 tag):

1. **Local-channel adapter** → closed. WebChat WS (`chat.send` / `chat.history` / `chat.abort`) is built into the Gateway. No adapter needed, Phase 3-A dropped.
2. **Bearer token field** → closed. Auth is `gateway.auth.token` / `gateway.auth.password` (shared secret). Loopback requires it. No new config fields.
3. **Session semantics** → closed. Persistent gateway-owned sessions via `sessionId` from `chat.history`. One-per-launch design dropped.

**Gate status (2026-05-10):**
- (1) SSE→WS line — ✅ already correct in spec (§UX/Streaming already read "WebSocket connection").
- (2) Slash command set flip — ✅ John approved 2026-05-10.
- (3) Smoke test — ✅ closed by Alex. `agent-send` WS round-trip against Bob verified: endpoint up, auth works on loopback, persistent session confirmed, streaming end-to-end pass. Wall time 3m35s on gemma4:e2b CPU — expected. See `inbox/2026-05-10-bob-smoke-result.md` for full results.

---

## Sub-step Delivery

Phase 3 is delivered in five sequential sub-steps. Each ends with a real on-Bob verification before the next begins. Ping Alex at the end of each sub-step.

**Process rules:**
- Verification is the deliverable, not a nice-to-have. Don't skip it to compress the schedule.
- If a tool call needs >90s of agent silence, kick it off async and check next turn — the gateway kills at 90s and will loop the session. (Phase 1 lesson, reinforced today.)
- Do not depend on the private `@openclaw/sdk` module — implement the WS protocol directly with the `ws` npm package. Use OpenClaw CLI source under `/usr/lib/node_modules/openclaw/dist/` as the envelope-shape reference.

---

### 3a — WS client core (~1 day)

**Scope:**
- npm package skeleton (`@civitasstudio/civitas-shell`, MIT, private scope to start).
- WS connect to `ws://127.0.0.1:18789`, auth via `gateway.auth.token` from `~/.openclaw/openclaw.json`.
- Implement `chat.history`, `chat.send` (with `idempotencyKey`), `chat.abort`.
- `--noninteractive --send <text>` mode — sends one message, streams reply tokens to stdout, exits.
- No UI yet. Plain stdout output.

**Reference:** `~/bin/agent-send` is a 70-line bash wrapper over the same round-trip — read it for the protocol pattern.

**Verify (→ spec test #1):**
- `civitas-shell --noninteractive --send "Hello, who are you?"` against Bob streams a reply identifying as Bob / `gemma4:e2b`.
- Re-run with same `idempotencyKey` does **not** double-send.
- `journalctl --user -u openclaw-gateway` on Bob shows no non-loopback traffic.

---

### 3b — Ink TUI (~1–2 days)

**Scope:**
- Transcript region (scrollable, fills terminal minus input row).
- Single-line input row; Shift-Enter grows up to 5 rows.
- Speaker labels (`Bob` / `You`) bold, messages indented 2 spaces.
- Streaming token render into active speaker block.
- Status overlay: `thinking ●●●` (animated); red errors on gateway failure.
- Key bindings per spec §Keys.
- Transcript replay at launch via `chat.history` (last 50 messages).

**Verify (→ spec tests #3, #4, #5):**
- Interactive launch on Bob's console — token-by-token rendering works.
- Mid-stream `Ctrl-C` cancels, status clears, input returns, shell does not exit.
- `systemctl --user stop openclaw-gateway` → red status; restart → next send works without re-typing.
- Relaunch — prior conversation appears at top.

---

### 3c — Slash commands, non-bash (~½ day)

**Scope:**
- `/clear`, `/model`, `/help`, `/exit` (with `--login-shell` flag gate that disables `/exit`; default off).
- Slash detection: input begins with `/`, no spaces before word boundary. `\/foo` sends literal slash-prefix to agent.

**Verify:**
- Each command matches its spec table row.
- `\/help` literal reaches the agent, not the help dispatcher.

---

### 3d — `/bash` PTY escape (~1 day) — TRICKIEST

**Scope:**
- `/bash` spawns `$SHELL` (or `/bin/bash`) as child PTY taking over the terminal.
- Ink rendering suspends; child PTY has full terminal control.
- On child exit: transcript intact, input focus restored, terminal mode restored cleanly.

**Gnarly bits to handle:** signal forwarding, `tcsetattr` save/restore around the child, ink unmount/remount lifecycle, `SIGWINCH` re-propagation on resize. Test in a real TTY, not an IDE pseudoterminal.

**Verify (→ spec test #2):**
- Launch, type `/bash`, get a real bash prompt. `whoami` → `bob`. `exit` → civitas-shell resumes, transcript intact.
- Terminal echo + line-discipline normal after return.
- Send a message after returning — streaming still works; no zombies in `ps`.

---

### 3e — Install integration (~½ day)

**Scope:**
- `install.sh --with-civitas-shell` flag (default off Phase 3; default on Phase 4 ISO).
- When enabled: `npm install -g @civitasstudio/civitas-shell` after Node is installed.
- `civitas-shell` binary on PATH. No `openclaw.json` mutations. Idempotent.

**Verify (→ spec test #6):**
- Fresh Ubuntu 26.04 libvirt VM on Forge (preserve Alex's pubkey if Bob is reused).
- `install.sh --with-civitas-shell` from scratch → `civitas-shell --noninteractive --send "hi"` works.
- `ss -tnp | grep -v '127.0.0.1\|::1' | grep civitas-shell` returns nothing.

---

**Total estimate:** ~4–5 days.

---

## References

- Phase 0 spec: [`docs/v0-spec.md`](v0-spec.md)
- Phase 2 spec: [`docs/v0-phase2-bob-spec.md`](v0-phase2-bob-spec.md)
- OpenClaw essentials: `~/.openclaw/workspace/handbook/openclaw-essentials.md`
- ink (TUI library): https://github.com/vadimdemedes/ink
- Gateway WS methods source: `src/gateway/server-methods-list.ts` (OpenClaw v2026.5.7)
- Gateway WS chat handler: `src/gateway/server-methods/chat.ts`
- WebChat docs: `docs/web/webchat.md`
