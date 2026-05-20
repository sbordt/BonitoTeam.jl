const ChatStyles = Bonito.Styles(
    # ── Tokens (shared with the dashboard) ────────────────────────────────────
    CSS(":root",
        "--bt-bg"            => "#fafaf9",
        "--bt-surface"       => "#ffffff",
        "--bt-surface-2"     => "#f8fafc",
        "--bt-border"        => "rgba(15,23,42,0.08)",
        "--bt-border-strong" => "rgba(15,23,42,0.14)",
        "--bt-text"          => "#0f172a",
        "--bt-text-muted"    => "#64748b",
        "--bt-text-faint"    => "#94a3b8",
        "--bt-accent"        => "#3b82f6",
        "--bt-accent-hover"  => "#2563eb",
        "--bt-success"       => "#10b981",
        "--bt-error"         => "#ef4444",
        "--bt-warning"       => "#f59e0b",
        "--bt-shadow-sm"     => "0 1px 2px rgba(15,23,42,0.05)",
        "--bt-shadow-md"     => "0 4px 12px rgba(15,23,42,0.08)",
        "--bt-radius"        => "8px",
        "--bt-radius-sm"     => "6px"),

    # ── Reset ────────────────────────────────────────────────────────────────
    CSS("html, body",
        "height" => "100%", "margin" => "0", "padding" => "0",
        "overflow" => "hidden"),

    # ── App shell — flex column that fills its container ────────────────────
    # The chat is always mounted inside the unified shell's `.bt-main` slot
    # (a flex column with defined height). `width/height: 100%` + `min-height: 0`
    # makes us a well-behaved flex child: we fill the slot, and `.bt-messages`
    # below can shrink past content height to enable its internal scroll.
    CSS(".bt-app",
        "width" => "100%", "height" => "100%", "min-height" => "0",
        # position:relative so the absolutely-positioned new-message
        # pill (below) anchors to .bt-app rather than the document.
        "position" => "relative",
        "display" => "flex", "flex-direction" => "column",
        "font-family" => "'Inter', system-ui, -apple-system, sans-serif",
        "font-size" => "14px",
        "background" => "var(--bt-bg)",
        "color" => "var(--bt-text)",
        "box-sizing" => "border-box",
        "overscroll-behavior" => "none",
        "-webkit-font-smoothing" => "antialiased"),

    # ── Header ───────────────────────────────────────────────────────────────
    # Outer spans full width (border-bottom looks correct); inner row caps at
    # the same content width as messages/input on desktop.
    CSS(".bt-header",
        "display" => "flex", "justify-content" => "center",
        "padding" => "10px 16px",
        "background" => "var(--bt-surface)",
        "border-bottom" => "1px solid var(--bt-border)",
        "flex-shrink" => "0",
        "min-height" => "44px",
        "box-sizing" => "border-box"),
    CSS(".bt-header-row",
        "display" => "flex", "align-items" => "center", "gap" => "10px",
        "width" => "100%", "max-width" => "880px"),
    CSS(".bt-header-back",
        "color" => "var(--bt-text)", "text-decoration" => "none",
        "font-size" => "20px", "line-height" => "1",
        "padding" => "4px 10px", "border-radius" => "6px",
        "transition" => "background 80ms, color 80ms",
        "flex-shrink" => "0"),
    CSS(".bt-header-back:hover",
        "background" => "var(--bt-surface-2)",
        "color" => "var(--bt-accent)"),
    # Title shrinks to fit but doesn't grow — keeps the Sync button right next
    # to the title rather than pushed to the far edge.
    CSS(".bt-header-title",
        "font-weight" => "600", "font-size" => "14px",
        "min-width" => "0", "overflow" => "hidden",
        "text-overflow" => "ellipsis", "white-space" => "nowrap",
        "flex" => "0 1 auto"),
    CSS(".bt-header-cwd",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px",
        "color" => "var(--bt-text-muted)", "font-weight" => "400",
        "margin-left" => "6px"),
    CSS(".bt-header-sync",
        "appearance" => "none",
        "border" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-text)",
        "font-size" => "12px", "padding" => "4px 10px",
        "border-radius" => "6px",
        "cursor" => "pointer",
        # Stable width: per-file progress labels can be long ("Sending
        # 137/999: src/some/long/path/file.jl"); without a min-width the
        # header reflows on every file. min-width pins the steady-state
        # idle "Sync" label area, max-width caps so a wildly long path
        # gets truncated rather than blowing out the header. tabular-nums
        # keeps digit columns the same width so the counter doesn't dance.
        "min-width" => "260px", "max-width" => "360px",
        "text-align" => "left",
        "white-space" => "nowrap",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis",
        "font-variant-numeric" => "tabular-nums",
        "transition" => "background 80ms"),
    CSS(".bt-header-sync:hover",
        "background" => "var(--bt-surface-2)"),

    # ── Status dot (online/offline/streaming) ────────────────────────────────
    CSS(".bt-dot",
        "display" => "inline-block",
        "width" => "8px", "height" => "8px",
        "border-radius" => "50%", "flex-shrink" => "0"),
    CSS(".bt-dot-online",
        "background" => "var(--bt-success)",
        "box-shadow" => "0 0 0 3px rgba(16,185,129,0.18)"),
    CSS(".bt-dot-offline", "background" => "var(--bt-text-faint)"),

    # ── Session-ended banner ─────────────────────────────────────────────────
    # Shown when the ACP connection drops mid-conversation. Mirrors the
    # bt-error style but adds a Restart action; sits between header and
    # message scroll so it's always visible.
    CSS(".bt-banner-error",
        "background" => "#fef2f2", "color" => "#b91c1c",
        "border" => "1px solid #fecaca",
        "border-radius" => "var(--bt-radius)",
        "padding" => "10px 14px",
        "margin" => "12px 16px 0",
        "display" => "flex", "align-items" => "center", "gap" => "12px",
        "font-size" => "13px"),
    CSS(".bt-banner-error .bt-btn",
        "flex-shrink" => "0"),
    CSS(".bt-banner-detail",
        "color" => "#7f1d1d", "font-size" => "12px",
        "margin-top" => "2px",
        "font-family" => "ui-monospace, monospace",
        "white-space" => "nowrap", "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    CSS(".bt-btn-secondary",
        "background" => "var(--bt-surface)", "color" => "var(--bt-text)",
        "border" => "1px solid var(--bt-border-strong)",
        "padding" => "6px 12px", "border-radius" => "var(--bt-radius-sm)",
        "font-size" => "13px", "cursor" => "pointer"),
    CSS(".bt-btn-secondary:hover",
        "background" => "var(--bt-surface-2)"),

    # ── Messages container ───────────────────────────────────────────────────
    # On wide screens the column self-centers (max-width + align-self), so
    # bubbles don't sprawl across a 1440px+ viewport. Scrollbar stays at the
    # right edge of the column rather than the screen edge — natural for a
    # chat app with content margins.
    CSS(".bt-messages",
        "flex" => "1 1 0", "min-height" => "0",
        "overflow-y" => "auto", "overflow-x" => "hidden",
        "-webkit-overflow-scrolling" => "touch",
        "overscroll-behavior-y" => "contain",
        "overflow-anchor" => "auto",
        "padding" => "16px",
        "display" => "flex", "flex-direction" => "column",
        "gap" => "10px",
        "width" => "100%", "max-width" => "880px",
        "align-self" => "center",
        "box-sizing" => "border-box"),
    CSS(".bt-spacer-top, .bt-spacer-bottom",
        "flex-shrink" => "0", "overflow-anchor" => "none"),

    # ── User message ─────────────────────────────────────────────────────────
    # max-width caps the bubble at a comfortable reading width on wide screens.
    # `flex-shrink: 0` is defensive (see .bt-tool-msg note) — even though
    # this rule has no `overflow` today, future styling shouldn't be able to
    # make message bubbles collapse under spacer pressure.
    CSS(".bt-user-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-end",
        "max-width" => "min(80%, 640px)",
        "background" => "var(--bt-accent)", "color" => "#fff",
        "border-radius" => "12px 12px 2px 12px",
        "padding" => "10px 14px",
        "font-size" => "14px", "line-height" => "1.5",
        "white-space" => "pre-wrap", "word-break" => "break-word",
        "box-shadow" => "var(--bt-shadow-sm)"),

    # ── Agent message ────────────────────────────────────────────────────────
    CSS(".bt-agent-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(85%, 760px)",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "2px 12px 12px 12px",
        "padding" => "10px 14px",
        "font-size" => "14px", "line-height" => "1.55",
        "word-break" => "break-word",
        "box-shadow" => "var(--bt-shadow-sm)"),

    # Streaming cursor blink
    CSS(".bt-stream-text::after",
        "content" => "\"▋\"",
        "animation" => "bt-cursor 0.8s step-end infinite",
        "color" => "var(--bt-accent)",
        "margin-left" => "1px"),
    CSS("@keyframes bt-cursor",
        CSS("0%, 100%", "opacity" => "1"),
        CSS("50%", "opacity" => "0")),

    # ── Thought (extended thinking) ──────────────────────────────────────────
    CSS(".bt-thought-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(85%, 760px)",
        "border" => "1px dashed var(--bt-border-strong)",
        "border-radius" => "10px",
        "background" => "transparent",
        "color" => "var(--bt-text-muted)"),
    CSS(".bt-thought-details", "padding" => "0"),
    CSS(".bt-thought-summary",
        "padding" => "8px 12px",
        "cursor" => "pointer",
        "user-select" => "none",
        "list-style" => "none",
        "font-size" => "13px",
        "display" => "flex", "align-items" => "center", "gap" => "6px"),
    CSS(".bt-thought-summary::-webkit-details-marker", "display" => "none"),
    CSS(".bt-thought-summary::before",
        "content" => "\"▸\"",
        "color" => "var(--bt-text-faint)",
        "transition" => "transform 120ms"),
    CSS("details[open] > .bt-thought-summary::before",
        "transform" => "rotate(90deg)"),
    CSS(".bt-thought-body",
        "padding" => "0 12px 10px 28px",
        "white-space" => "pre-wrap", "word-break" => "break-word",
        "font-size" => "12.5px", "line-height" => "1.5",
        "color" => "var(--bt-text-muted)"),
    CSS(".bt-thought-loading, .bt-tool-loading",
        "color" => "var(--bt-text-faint)",
        "font-style" => "italic", "font-size" => "12px",
        "padding" => "4px 0"),

    # ── Tool call card ───────────────────────────────────────────────────────
    # NOTE: `flex-shrink: 0` is load-bearing. `.bt-messages` is a flex column
    # container, and per the CSS Flexbox spec, a flex item with any
    # `overflow` keyword set has its default `min-height` switch from `auto`
    # (content height) to `0`. Combined with the virtual-scroll spacer-top
    # whose height runs into the thousands of px, that lets every tool card
    # shrink down to a 1px slit (border only). Same trap would catch any
    # other bubble that grows an `overflow: hidden`, so we apply the same
    # `flex-shrink: 0` to the other message types defensively below.
    CSS(".bt-tool-msg",
        "flex-shrink" => "0",
        "align-self" => "flex-start",
        "max-width" => "min(92%, 800px)",
        "background" => "var(--bt-surface)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "font-size" => "13px",
        "box-shadow" => "var(--bt-shadow-sm)",
        "overflow" => "hidden"),
    CSS(".bt-tool-header",
        "display" => "flex", "align-items" => "center", "gap" => "8px",
        "padding" => "8px 12px",
        "cursor" => "pointer",
        "user-select" => "none",
        "transition" => "background 80ms"),
    CSS(".bt-tool-header:hover",
        "background" => "var(--bt-surface-2)"),
    CSS(".bt-tool-toggle",
        "color" => "var(--bt-text-faint)", "font-size" => "11px",
        "transition" => "transform 120ms",
        "flex-shrink" => "0",
        "width" => "10px"),
    CSS(".bt-tool-header[data-expanded=\"true\"] .bt-tool-toggle",
        "transform" => "rotate(90deg)"),
    CSS(".bt-tool-kind",
        "font-size" => "13px", "flex-shrink" => "0"),
    CSS(".bt-tool-title",
        "flex" => "1 1 auto", "min-width" => "0",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px",
        "overflow" => "hidden", "text-overflow" => "ellipsis",
        "white-space" => "nowrap"),
    CSS(".bt-tool-summary",
        "color" => "var(--bt-text-muted)", "font-size" => "11.5px",
        "flex-shrink" => "0",
        "white-space" => "nowrap"),

    # Tool status — slim pill, harmonized with dashboard
    CSS(".bt-tool-status",
        "display" => "inline-flex", "align-items" => "center",
        "gap" => "4px",
        "font-size" => "11px", "font-weight" => "500",
        "padding" => "1px 8px",
        "border-radius" => "999px",
        "white-space" => "nowrap", "flex-shrink" => "0"),
    CSS(".bt-status-pending",
        "background" => "rgba(245,158,11,0.12)", "color" => "#92400e"),
    CSS(".bt-status-in_progress",
        "background" => "rgba(59,130,246,0.12)", "color" => "#1d4ed8"),
    CSS(".bt-status-completed",
        "background" => "rgba(16,185,129,0.12)", "color" => "#047857"),
    CSS(".bt-status-failed",
        "background" => "rgba(239,68,68,0.12)", "color" => "#b91c1c"),

    CSS(".bt-tool-body",
        "padding" => "0 12px 10px",
        "border-top" => "1px solid var(--bt-border)"),
    CSS(".bt-tool-empty",
        "padding" => "8px 0",
        "color" => "var(--bt-text-faint)",
        "font-style" => "italic", "font-size" => "12px"),
    CSS(".bt-tool-md",
        "font-size" => "13px", "line-height" => "1.5",
        "padding-top" => "8px"),

    # Eval-section blocks (BonitoMCP bt_julia_eval output): a tiny uppercase
    # label (STDOUT / RESULT / ERROR) above the Monaco-rendered body of each
    # section, so the input code, captured output, and return value are
    # visually distinct in the tool body.
    CSS(".bt-section-label",
        "font-size" => "10.5px", "font-weight" => "600",
        "letter-spacing" => "0.08em", "text-transform" => "uppercase",
        "color" => "var(--bt-text-faint)",
        "margin" => "12px 0 4px"),
    CSS(".bt-eval-section + .bt-eval-section",
        "margin-top" => "4px"),
    CSS(".bt-eval-section:first-child .bt-section-label",
        "margin-top" => "8px"),

    # ── Edit-tool inline preview ─────────────────────────────────────────────
    # Server-rendered diff snippet between the tool header and the lazy body.
    # Capped at ~100px (~7-8 lines) with a fade gradient at the bottom so
    # there's a visual hint that "more lives in the expanded body".
    CSS(".bt-edit-preview",
        "max-height" => "100px",
        "overflow"   => "hidden",
        "position"   => "relative",
        "padding"    => "6px 12px 8px",
        # border-box so the 100px cap is the actual rendered height — keeps
        # the lightweight contract honest no matter what padding lands here.
        "box-sizing" => "border-box",
        "border-top" => "1px solid var(--bt-border)",
        "background" => "var(--bt-surface-2)",
        "font-family" => "ui-monospace, monospace",
        "font-size"  => "11.5px",
        "line-height" => "1.4"),
    # Bottom fade so the truncation is intentional-looking rather than
    # an awkward hard cut.
    CSS(".bt-edit-preview::after",
        "content" => "''",
        "position" => "absolute",
        "left" => "0", "right" => "0", "bottom" => "0",
        "height" => "20px",
        "background" => "linear-gradient(to bottom, rgba(248,250,252,0), var(--bt-surface-2))",
        "pointer-events" => "none"),
    CSS(".bt-edit-preview-path",
        "color" => "var(--bt-text-muted)",
        "font-weight" => "600",
        "padding-bottom" => "2px"),
    CSS(".bt-edit-preview-line",
        "white-space" => "pre",
        "overflow" => "hidden",
        "text-overflow" => "ellipsis"),
    CSS(".bt-edit-preview-del",
        "color" => "#b91c1c",
        "background" => "rgba(239,68,68,0.06)"),
    CSS(".bt-edit-preview-add",
        "color" => "#047857",
        "background" => "rgba(16,185,129,0.08)"),
    CSS(".bt-edit-preview-more",
        "color" => "var(--bt-text-faint)",
        "font-style" => "italic",
        "padding-top" => "2px"),

    # ── Diff blocks (multi-edit) ─────────────────────────────────────────────
    # Single-diff body just shows the editor; multi-edit bodies stack diffs
    # with subtle separators + monospace path headers so you can tell which
    # file each chunk belongs to.
    CSS(".bt-diff-block", "padding-top" => "8px"),
    CSS(".bt-multi-diff .bt-diff-block + .bt-diff-block",
        "margin-top" => "12px",
        "border-top" => "1px solid var(--bt-border)",
        "padding-top" => "12px"),
    CSS(".bt-diff-header",
        "font-family" => "ui-monospace, monospace",
        "font-size" => "11px",
        "color" => "var(--bt-text-muted)",
        "padding" => "2px 0 6px",
        "word-break" => "break-all"),

    # ── Search results ───────────────────────────────────────────────────────
    CSS(".bt-search-results",
        "padding" => "8px 0",
        "font-size" => "12px",
        "max-height" => "400px",
        "overflow-y" => "auto"),
    CSS(".bt-search-row",
        "padding" => "3px 0",
        "display" => "flex", "align-items" => "baseline", "gap" => "4px",
        "min-width" => "0"),
    CSS(".bt-search-path",
        "color" => "var(--bt-accent)", "font-weight" => "600",
        "font-family" => "ui-monospace, monospace",
        "flex-shrink" => "0"),
    CSS(".bt-search-line",
        "color" => "var(--bt-text-muted)",
        "font-family" => "ui-monospace, monospace",
        "flex-shrink" => "0"),
    CSS(".bt-search-snippet",
        "color" => "var(--bt-text)",
        "background" => "none", "padding" => "0",
        "font-family" => "ui-monospace, monospace", "font-size" => "12px",
        "flex" => "1 1 auto", "min-width" => "0",
        "overflow" => "hidden",
        "white-space" => "nowrap",
        "text-overflow" => "ellipsis"),
    CSS(".bt-search-raw",
        "color" => "var(--bt-text-muted)",
        "font-family" => "ui-monospace, monospace", "font-size" => "11px",
        "padding" => "2px 0",
        "white-space" => "pre-wrap"),

    # ── Plan ─────────────────────────────────────────────────────────────────
    CSS(".bt-plan-msg",
        "align-self" => "flex-start",
        "max-width" => "min(88%, 760px)",
        "border" => "1px solid var(--bt-border)",
        "border-radius" => "var(--bt-radius-sm)",
        "background" => "var(--bt-surface)",
        "padding" => "10px 14px",
        "font-size" => "13px",
        "box-shadow" => "var(--bt-shadow-sm)"),
    CSS(".bt-plan-entry",
        "display" => "flex", "align-items" => "flex-start",
        "gap" => "8px", "padding" => "3px 0",
        "color" => "var(--bt-text)"),
    CSS(".bt-plan-status",
        "width" => "16px", "flex-shrink" => "0",
        "text-align" => "center",
        "color" => "var(--bt-text-muted)",
        "font-weight" => "600"),

    # ── Markdown inside agent bubble ─────────────────────────────────────────
    CSS(".bt-agent-msg .markdown-body, .bt-agent-msg .markdown",
        "background" => "none", "border" => "none", "padding" => "0",
        "font-size" => "inherit", "font-family" => "inherit",
        "color" => "inherit", "line-height" => "1.55"),
    CSS(".bt-agent-msg .markdown-body > *:first-child, .bt-agent-msg .markdown > *:first-child",
        "margin-top" => "0"),
    CSS(".bt-agent-msg .markdown-body > *:last-child, .bt-agent-msg .markdown > *:last-child",
        "margin-bottom" => "0"),
    CSS(".bt-agent-msg pre",
        "background" => "#0f172a", "color" => "#e2e8f0",
        "border-radius" => "var(--bt-radius-sm)",
        "padding" => "10px 14px",
        "overflow-x" => "auto",
        "font-size" => "12px", "line-height" => "1.5",
        "margin" => "8px 0"),
    CSS(".bt-agent-msg code",
        "background" => "rgba(15,23,42,0.06)",
        "border-radius" => "3px",
        "padding" => "1px 5px",
        "font-size" => "12.5px",
        "font-family" => "ui-monospace, monospace"),
    CSS(".bt-agent-msg pre code",
        "background" => "none", "padding" => "0",
        "color" => "inherit"),

    # ── Busy indicator ───────────────────────────────────────────────────────
    CSS(".bt-busy",
        "flex-shrink" => "0", "height" => "0", "overflow" => "hidden",
        "display" => "flex", "gap" => "4px", "align-items" => "center",
        "padding" => "0 16px",
        "transition" => "height 150ms ease, padding 150ms ease"),
    CSS(".bt-busy.bt-busy-active",
        "height" => "28px", "padding" => "4px 16px"),
    CSS(".bt-busy-dot",
        "width" => "7px", "height" => "7px", "border-radius" => "50%",
        "background" => "var(--bt-accent)",
        "animation" => "bt-pulse 1.2s ease-in-out infinite"),
    CSS(".bt-busy-dot:nth-child(2)", "animation-delay" => "0.2s"),
    CSS(".bt-busy-dot:nth-child(3)", "animation-delay" => "0.4s"),
    CSS("@keyframes bt-pulse",
        CSS("0%, 100%", "opacity" => "0.3", "transform" => "scale(0.8)"),
        CSS("50%",      "opacity" => "1",   "transform" => "scale(1.2)")),

    # ── New-messages pill ────────────────────────────────────────────────────
    # Floats above the input area when followMode is off and new content
    # arrived in scrollback. Click → re-engage follow + scroll to bottom.
    # Hidden by default; .bt-new-msg-pill-visible toggles display. The slow
    # 2.5s pulse is via box-shadow so the button geometry doesn't shift.
    CSS(".bt-new-msg-pill",
        "display" => "none",
        "position" => "absolute",
        "left" => "50%",
        # Bottom offset sits above the input area; chosen large enough
        # that on mobile (where the input area can grow to ~120px with
        # an expanded textarea + attachments strip) the pill stays clear.
        "bottom" => "92px",
        "transform" => "translateX(-50%)",
        "z-index" => "20",
        "align-items" => "center", "gap" => "8px",
        "padding" => "8px 16px",
        "border" => "none", "border-radius" => "999px",
        "background" => "linear-gradient(135deg, #10b981 0%, #059669 100%)",
        "color" => "#fff",
        "font-family" => "inherit", "font-size" => "13px",
        "font-weight" => "500",
        "cursor" => "pointer",
        "box-shadow" => "0 4px 14px rgba(16, 185, 129, 0.45)",
        "animation" => "bt-new-msg-pulse 2.5s ease-in-out infinite"),
    CSS(".bt-new-msg-pill.bt-new-msg-pill-visible",
        "display" => "inline-flex"),
    CSS(".bt-new-msg-pill:hover",
        "filter" => "brightness(1.08)"),
    CSS(".bt-new-msg-pill:active",
        "transform" => "translateX(-50%) scale(0.96)"),
    CSS(".bt-new-msg-pill-arrow",
        "font-size" => "16px", "line-height" => "1"),
    CSS("@keyframes bt-new-msg-pulse",
        CSS("0%, 100%",
            "box-shadow" => "0 4px 14px rgba(16, 185, 129, 0.45)"),
        CSS("50%",
            "box-shadow" => "0 4px 28px rgba(16, 185, 129, 0.85)")),

    # ── Input area ───────────────────────────────────────────────────────────
    # Outer area spans full width (so the top border + background look right);
    # inner row is centered with the same max-width as the messages column.
    # Column flex so the thumbnail strip (.bt-attachments) sits above the
    # input row when an attachment is queued.
    CSS(".bt-input-area",
        "flex-shrink" => "0",
        "border-top" => "1px solid var(--bt-border)",
        "padding" => "12px 14px",
        "padding-bottom" => "max(12px, env(safe-area-inset-bottom))",
        "display" => "flex", "flex-direction" => "column", "align-items" => "center",
        "gap" => "8px",
        "background" => "var(--bt-surface)"),
    CSS(".bt-input-row",
        "display" => "flex", "gap" => "8px", "align-items" => "flex-end",
        "width" => "100%", "max-width" => "880px"),

    # ── Attachment thumbnail strip ──────────────────────────────────────────
    # Sits above .bt-input-row. Hidden (display:none) when there's nothing
    # queued so the empty div doesn't add stray spacing. Thumbnails scroll
    # horizontally on overflow rather than wrapping — keeps the input row
    # in the same screen position regardless of attachment count.
    CSS(".bt-attachments",
        "display" => "none",
        "width" => "100%", "max-width" => "880px"),
    CSS(".bt-attachments.bt-attachments-active",
        "display" => "flex",
        "gap" => "8px",
        "flex-wrap" => "wrap",
        "align-items" => "flex-start"),
    CSS(".bt-attachment-thumb",
        "position" => "relative",
        "width" => "64px", "height" => "64px",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "8px",
        "overflow" => "hidden",
        "background" => "var(--bt-bg)",
        "flex-shrink" => "0"),
    CSS(".bt-attachment-thumb img",
        "width" => "100%", "height" => "100%",
        "object-fit" => "cover",
        "display" => "block"),
    CSS(".bt-attachment-remove",
        "position" => "absolute",
        "top" => "2px", "right" => "2px",
        "width" => "20px", "height" => "20px",
        "border" => "none", "border-radius" => "50%",
        "background" => "rgba(0,0,0,0.6)", "color" => "#fff",
        "font-size" => "16px", "line-height" => "20px",
        "padding" => "0", "cursor" => "pointer",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "center"),
    CSS(".bt-attachment-remove:hover",
        "background" => "rgba(220,38,38,0.85)"),
    CSS(".bt-attach-error",
        "color" => "var(--bt-error)",
        "font-size" => "12px",
        "padding" => "4px 8px",
        "border-radius" => "6px",
        "background" => "rgba(239,68,68,0.08)",
        "border" => "1px solid rgba(239,68,68,0.3)",
        "flex-basis" => "100%",
        "box-sizing" => "border-box"),

    # Drag-over highlight on .bt-app: subtle inset ring so it's clear the
    # drop zone is "the whole chat", not just one nested element.
    CSS(".bt-app.bt-drag-over",
        "box-shadow" => "inset 0 0 0 3px var(--bt-accent)"),
    CSS(".bt-text-input",
        "flex" => "1 1 auto", "min-width" => "0",
        "border" => "1px solid var(--bt-border-strong)",
        "border-radius" => "20px",
        "padding" => "10px 14px",
        "font-size" => "16px",                          # iOS no-zoom threshold
        "min-height" => "40px", "max-height" => "120px",
        "font-family" => "inherit",
        "color" => "var(--bt-text)",
        "background" => "var(--bt-bg)",
        "outline" => "none", "box-sizing" => "border-box",
        "resize" => "none", "overflow-y" => "auto",
        "line-height" => "1.4",
        "transition" => "border-color 120ms, box-shadow 120ms"),
    CSS(".bt-text-input::placeholder",
        "color" => "var(--bt-text-faint)"),
    CSS(".bt-text-input:focus",
        "border-color" => "var(--bt-accent)",
        "box-shadow" => "0 0 0 3px rgba(59,130,246,0.18)"),
    # Thin, modern scrollbar instead of the Linux/Electron default with up/down
    # arrow buttons. Only visible when textarea grows past max-height.
    CSS(".bt-text-input",
        "scrollbar-width" => "thin",
        "scrollbar-color" => "var(--bt-border-strong) transparent"),
    CSS(".bt-text-input::-webkit-scrollbar",
        "width" => "6px"),
    CSS(".bt-text-input::-webkit-scrollbar-thumb",
        "background" => "var(--bt-border-strong)",
        "border-radius" => "3px"),
    CSS(".bt-text-input::-webkit-scrollbar-button",
        "display" => "none"),

    # Send / stop buttons — circles, big enough for thumb. `box-sizing:
    # border-box` is load-bearing: stop has a 1px border, send doesn't, so
    # without it the buttons end up 42x42 vs 40x40 and the row baselines
    # disagree by a pixel.
    CSS(".bt-send-btn, .bt-stop-btn",
        "border" => "none", "border-radius" => "50%",
        "width" => "40px", "height" => "40px",
        "box-sizing" => "border-box",
        "font-size" => "20px",                       # larger glyph fills the circle
        "line-height" => "1",
        "cursor" => "pointer", "flex-shrink" => "0",
        "display" => "flex", "align-items" => "center",
        "justify-content" => "center", "padding" => "0",
        "transition" => "background 120ms, transform 80ms, opacity 120ms"),
    CSS(".bt-send-btn",
        "background" => "var(--bt-accent)", "color" => "#fff"),
    CSS(".bt-send-btn:hover",  "background" => "var(--bt-accent-hover)"),
    CSS(".bt-send-btn:active", "transform" => "scale(0.95)"),
    CSS(".bt-send-btn:disabled",
        "opacity" => "0.4", "cursor" => "not-allowed"),
    CSS(".bt-stop-btn",
        "background" => "var(--bt-surface)",
        "color" => "var(--bt-error)",
        "border" => "1px solid var(--bt-border-strong)"),
    CSS(".bt-stop-btn:hover",
        "background" => "rgba(239,68,68,0.08)",
        "border-color" => "var(--bt-error)"),

    # ── Spinner (used by bt_show preview while streaming from worker) ────────
    CSS(".bt-spinner",
        "width" => "14px", "height" => "14px",
        "border-radius" => "50%",
        "border" => "2px solid var(--bt-border)",
        "border-top-color" => "var(--bt-accent)",
        "animation" => "bt-spin 0.7s linear infinite",
        "flex-shrink" => "0",
        "display" => "inline-block"),
    CSS("@keyframes bt-spin", CSS("to", "transform" => "rotate(360deg)")),

    # ── Responsive ───────────────────────────────────────────────────────────
    CSS("@media (max-width: 480px)",
        # Tighter padding on very small screens
        CSS(".bt-messages", "padding" => "12px"),
        CSS(".bt-input-area", "padding" => "10px 12px",
            "padding-bottom" => "max(10px, env(safe-area-inset-bottom))"),
        # Slightly tighter bubbles
        CSS(".bt-user-msg, .bt-agent-msg", "max-width" => "88%"),
        CSS(".bt-tool-msg",                "max-width" => "100%"),
        CSS(".bt-plan-msg",                "max-width" => "100%"),
        # Hide the cwd path in the header — not enough room
        CSS(".bt-header-cwd", "display" => "none"),
        # Title takes the available horizontal space and ellipsizes; the
        # sync button shrinks to its content width. On desktop the sync
        # button reserves 260px so per-file progress labels don't reflow
        # the header, but on a 360-414px phone column that 260px reserve
        # covers the project name. Drop it on mobile: long progress labels
        # still truncate via `text-overflow: ellipsis` (declared on the
        # base `.bt-header-sync` rule), so the row never overflows.
        CSS(".bt-header-title", "flex" => "1 1 auto"),
        CSS(".bt-header-sync",
            "min-width" => "0", "max-width" => "none",
            "flex" => "0 1 auto")),
)
