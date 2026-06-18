# e2e coverage map

These suites drive the *real* stack (dev server + worker + ACP over stdio,
only the `claude-agent-acp` binary swapped for the mock) through a headless
Electron window via `ElectronCall.Testing`. They assert against the rendered
DOM only — no internal-API calls.

They replace the legacy `../electron/` harness, which booted `unified_app(state)`
directly (an internal API). Each `../electron/` test is deleted once a suite
here covers its behaviour; what is still listed in `../electron/runtests.jl`
is the remaining backlog.

## Suites

| File                  | Covers                                                                 |
|-----------------------|------------------------------------------------------------------------|
| `workflows.jl`        | dashboard, new-project folder picker, chat reply, edit tool + diff expand, bash tool, thinking, agent switch |
| `chat_features.jl`    | streaming accumulation, markdown (h1/ul/pre/strong/a), responsive layout (480/1280), multi-chat switching |
| `embedded_app.jl`     | `bt_show_app` dial-back eval bridge + embedded frame render            |
| `scroll_persist.jl`   | new content follows to bottom (followMode), overflow, history survives a browser reconnect |
| `worker_lifecycle.jl` | worker online on dashboard, killed process → offline                   |
| `cross_worker.jl`     | a second worker registers (2 online), kill → 1                         |
| `todo_taskbar.jl`     | live todo as a pinned panel, plan update mutates it in place (done/active), turn end finalizes to one bubble + drops the pin |
| `tool_rendering.jl`   | tool kinds: multi-edit diff stack, search rows, bt_julia_eval stdout/result sections, read-as-code, move/fetch header summaries, execute status pill pending→in_progress→completed |
| `lens.jl`             | lens search bar: vocabulary, autocomplete, apply filter (only matching messages visible), clear, save chip + persist + delete |
| `errors.jl`           | an error reply renders an inline `[error: …]` bubble; busy clears after the failed turn |

## Retired from `../electron/` (behaviour now covered above)

`test_layout.jl`, `test_mobile.jl`, `test_responsive_pane.jl` → `chat_features.jl`
(responsive); `test_chat_input.jl`, `test_chat_messages.jl` → `workflows.jl`;
`test_chat_streaming.jl`, `test_markdown.jl` → `chat_features.jl`;
`test_dashboard.jl` → `workflows.jl`/`worker_lifecycle.jl`; `test_persistence.jl`
→ `scroll_persist.jl`; `test_worker_handshake.jl`, `test_worker_disconnect.jl`
→ `worker_lifecycle.jl`; `test_todo_taskbar.jl` → `todo_taskbar.jl`;
`test_tool_variants.jl`, `test_tool_kinds_extra.jl` → `tool_rendering.jl`;
`test_lens.jl` (the UI test) → `lens.jl` (the root `test/test_lens.jl` lens-core
unit test stays — it is headless, not a UI test).

## Backlog (still in `../electron/`, not yet ported)

Portable with the mock, just not done yet:

- `test_streamed_tool_input.jl` — partial `rawInput` streaming; needs the mock
  to emit partial tool-input frames.
- `test_chat_errors.jl` — the inline `[error: …]` path is covered by `errors.jl`;
  what remains is the transport-DEATH path (agent process dies → session_alive
  false → header restart button "dead"), which depends on `is_session_dead_error`
  classification and overlaps the restart suite.
- `test_virtual_scroll.jl`, `test_keyed_list.jl`, `test_chat_remount.jl`,
  `test_chat_controls.jl`, `test_auto_prompt.jl`, `test_folder_threads.jl`,
  `test_chat_show*.jl` — assorted UI behaviours.

Acknowledged gaps that are NOT a simple port:

- `test_follow_pill.jl`, `test_scroll_chase.jl`, `test_scroll_stress.jl` — the
  "scroll up to read history disengages follow-mode, click the pill to
  re-engage" flow. The chat uses a custom wheel/pan/spring scroller that does
  not respond to a synthetic `wheel`/`scrollTop` change OR to a real
  `webContents.sendInputEvent` mouseWheel in a headless `show=false` window
  (verified three ways — see the header of `scroll_persist.jl`). Needs real
  hardware input on a visible window.
- `test_chat_attach.jl` — attachments go through the OS file-picker dialog,
  which is not drivable in the headless harness.
- `test_worker_move.jl`, `test_cross_worker_sync.jl` — cross-worker project
  *move*. The move control (`.bt-open-on-select`, `project_widget.jl`) does not
  render in the chat view or the Home dashboard in the harness, and new-project
  worker assignment is non-deterministic (`first(keys(workers))`). Needs
  locating where `project_widget` mounts before it can be driven. Registration
  + disconnect across workers IS covered by `cross_worker.jl`.
- `test_chat_cancel.jl` — cancelling a turn. Meaningless against a scripted
  mock agent; needs a real agent to interrupt.
- `test_remotesync.jl` — RemoteSync file-sync unit, not a UI behaviour.
