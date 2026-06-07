# Plotpane / floating-window / resident-chat-state spec

Reconstructed verbatim from the user's messages (do NOT lose this again; it was
specced over multiple sessions). Source lines in the session transcript:
10556, 10564, 10569 (docking model), 18947 (resident state — the main one),
12635 todo items (167, 172, 174), plus the chosen decisions.

## 1. Docking model — three homes for a `bt_show_app` output
A `bt_show_app` output is ONE DOM node that physically moves between containers
(`bt_show_app.dom → move_to → popup_window → move_to → plotpane_container`). You
drag the actual output div; nothing is re-rendered or duplicated.

- **Inline** (default): rendered in the chat, respecting its collapsed state.
- **Floating window**: a `position:absolute` DIV you can drag + resize. It is a
  **chat-global** detach target — it remembers its size + position from the last
  time something was shown in it. Default pop-out size ≈ **2/3 of available
  screen real estate**.
- **Plotpane** (right column): drag-and-drop the floating window into the
  plotpane → it resizes to fill that column. The plotpane is the future home of
  a file editor too.

### Button design (refined 2026-06-05)
- **Detach = the `⤢` button in the tool header**, rendered only for tools that
  carry a live embed (`has_app`: `bonito_app` kind OR a `shown_app:` reference).
  ⤢ is the conventional "open in a window" glyph and where users expect detach.
- **Full-chat-width = a `»` button vertically centered on the bubble's RIGHT
  edge**, revealed only while the body is expanded (no point widening an empty
  header). Toggles `«`/`»`.

### Detach / minimize behavior
- **Detach**: the inline output becomes empty (replaced by a small indicator);
  its DOM node moves into the floating window (or wherever the chat's detach
  target currently is — floating OR docked in plotpane).
- **A NEW `bt_show_app` detach** lands in the *current* floating-window position
  (floating, or docked in the plotpane column).
- **Minimize**: hide the DOM node WITHOUT resetting any state. Restoring gives
  the content back, respecting the collapsed state.
- Workflow: pop out → play around with the dashboard → minimize.

## 2. Resident per-chat state (THE main requirement)
Apps are **resident to the chat**, together with their **collapse + plotpane +
floating-window state**. Switching between home / chat A / chat B must lose
NOTHING:
- In chat A with a floating window → go to chat B → A's floating window is gone
  (B shows B's own setup + apps, if any). Go back to A → the floating window is
  found exactly where you left it.
- Same for the plotpane contents and which apps are open vs collapsed.
- Floating window must NOT show on the home page; chat→home→chat must not mess
  with its position.
- Decision: **keep-alive = DOM preservation with an LRU cap** (preserve each
  chat's DOM subtree so state survives navigation; evict oldest beyond the cap).
- Decision: divider width is remembered **per chat**.
- Decision: build scope **all at once** (the whole feature, not incremental).

## 3. Plotpane fills the whitespace (refined 2026-06-05)
- When the plotpane is OPEN it fills the **entire** area to the right of the chat
  — no gap, no fixed-width column. The chat becomes a left-aligned, resizable
  column (`--bt-chat-width`, clamped to its reading range) and the plotpane is
  `flex:1`, taking everything else out to the viewport edge. "Everything right of
  the chat scrollbar is the drop / editor / plotpane zone."
- The `chat | plotpane` divider therefore resizes the **chat** (drag right →
  wider chat / narrower pane; left → the reverse); the pane auto-fills. The chat
  width is persisted **per chat**.
- When the plotpane is CLOSED the chat returns to centered + capped (unchanged
  from the old look).
- **Drag-to-dock**: dragging the floating window highlights the **whole** right
  region (a fixed overlay covering chat-edge → viewport-edge), not a thin strip;
  releasing anywhere over it docks.
- A full-width toggle on the output pill to extend it to the **full width of the
  chat window** — implemented as the `»` right-edge button (see Button design).
- Detaching another app **replaces** the one in the surface (one detached app per
  chat; the previous returns to its inline bubble).

## Why the first attempt was reverted (failure modes to AVOID this time)
1. CSS broke the chat's flex-height + scroll, and wasted the whitespace (the
   exact thing it was supposed to fix). → verify scroll + flex sizing in a real
   browser, at multiple widths.
2. The keep-alive / overlay restructure orphaned the dashboard's `KeyedList`s
   (`Cannot set null.bonitoKeyedList` flood) → message processing halted. → the
   keep-alive container must not break the dashboard/sidebar KeyedList mounting;
   verify the dashboard still renders + chat still receives messages.

## Verification plan (this is the part that was missing last time)
Drive it through the electron + fake-agent harness (test_bonito_app_churn.jl
patterns). Assert, in a real browser:
- inline → detach → floating window appears at remembered pos/size; minimize/restore.
- drag float → plotpane docks + fills the right whitespace.
- two-stage divider drag: chat slides right-into-left-whitespace, then shrinks at the wall.
- chat A (float at X) → chat B → chat A: float still at X; collapsed/open apps preserved; plotpane contents preserved.
- chat → home → chat: float hidden on home, restored on return.
- the app stays INTERACTIVE after every move (click → worker → re-render still works).
- dashboard KeyedLists intact; chat scroll works; no `null.bonitoKeyedList`.
