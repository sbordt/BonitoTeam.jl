const ChatStyles = Bonito.Styles(
    # Global reset
    CSS("html, body",
        "height"   => "100%",
        "margin"   => "0",
        "padding"  => "0",
        "overflow" => "hidden"),

    # App shell — full-viewport flex column
    CSS(".bt-app",
        "display"        => "flex",
        "flex-direction" => "column",
        "height"         => "100svh",          # svh: safe on mobile (accounts for browser chrome)
        "font-family"    => "system-ui, -apple-system, sans-serif",
        "background"     => "var(--bg-primary, #fff)",
        "color"          => "var(--text-primary, #222)",
        "box-sizing"     => "border-box",
        "overscroll-behavior" => "none"),      # prevent pull-to-refresh swallowing

    # Header
    CSS(".bt-header",
        "padding"       => "10px 16px",
        "border-bottom" => "1px solid #ddd",
        "font-size"     => "14px",
        "font-weight"   => "600",
        "background"    => "#f6f8fa",
        "flex-shrink"   => "0",
        "display"       => "flex",
        "align-items"   => "center",
        "gap"           => "8px"),

    # Messages container — scrollable, virtual-scroll aware
    CSS(".bt-messages",
        "flex"                    => "1 1 0",
        "min-height"              => "0",
        "overflow-y"              => "auto",
        "overflow-x"              => "hidden",
        "-webkit-overflow-scrolling" => "touch",   # iOS momentum
        "overscroll-behavior-y"   => "contain",
        "overflow-anchor"         => "auto",       # browser preserves scroll on prepend
        "padding"                 => "12px 16px",
        "display"                 => "flex",
        "flex-direction"          => "column",
        "gap"                     => "8px"),

    # Virtual-scroll spacers — height set by JS
    CSS(".bt-spacer-top, .bt-spacer-bottom",
        "flex-shrink"     => "0",
        "overflow-anchor" => "none"),   # must not anchor, or scroll jumps

    # Message bubbles
    CSS(".bt-user-msg",
        "align-self"    => "flex-end",
        "max-width"     => "80%",
        "background"    => "#0366d6",
        "color"         => "white",
        "border-radius" => "16px 16px 4px 16px",
        "padding"       => "10px 14px",
        "font-size"     => "15px",
        "line-height"   => "1.4",
        "white-space"   => "pre-wrap",
        "word-break"    => "break-word"),

    CSS(".bt-agent-msg",
        "align-self"    => "flex-start",
        "max-width"     => "85%",
        "background"    => "#f6f8fa",
        "border"        => "1px solid #e1e4e8",
        "border-radius" => "4px 16px 16px 16px",
        "padding"       => "10px 14px",
        "font-size"     => "15px",
        "line-height"   => "1.5",
        "word-break"    => "break-word"),

    # Streaming cursor blink
    CSS(".bt-stream-text::after",
        "content"    => "\"▋\"",
        "animation"  => "bt-cursor 0.8s step-end infinite",
        "color"      => "#0366d6"),

    CSS("@keyframes bt-cursor",
        CSS("0%, 100%", "opacity" => "1"),
        CSS("50%",      "opacity" => "0")),

    # Thought bubble (extended thinking)
    CSS(".bt-thought-msg",
        "align-self"    => "flex-start",
        "max-width"     => "85%",
        "border"        => "1px solid #e1e4e8",
        "border-radius" => "4px 16px 16px 16px",
        "font-size"     => "13px",
        "color"         => "#666"),

    CSS(".bt-thought-details",
        "padding" => "0"),

    CSS(".bt-thought-summary",
        "padding"     => "6px 12px",
        "cursor"      => "pointer",
        "font-style"  => "italic",
        "user-select" => "none",
        "list-style"  => "none"),

    CSS(".bt-thought-summary::-webkit-details-marker", "display" => "none"),

    CSS(".bt-thought-body",
        "padding"     => "6px 12px 8px",
        "white-space" => "pre-wrap",
        "word-break"  => "break-word",
        "font-size"   => "12px",
        "line-height" => "1.4",
        "border-top"  => "1px solid #f0f0f0"),

    # Tool call card
    CSS(".bt-tool-msg",
        "align-self"    => "flex-start",
        "max-width"     => "92%",
        "background"    => "#f6f8fa",
        "border"        => "1px solid #e1e4e8",
        "border-left"   => "3px solid #0366d6",
        "border-radius" => "4px",
        "padding"       => "8px 12px",
        "font-size"     => "13px"),

    CSS(".bt-tool-header",
        "display"     => "flex",
        "align-items" => "center",
        "gap"         => "6px"),

    CSS(".bt-tool-kind",
        "font-size"      => "14px",
        "opacity"        => "0.7",
        "flex-shrink"    => "0"),

    CSS(".bt-tool-title",
        "flex"        => "1",
        "font-family" => "monospace",
        "font-size"   => "12px",
        "word-break"  => "break-all"),

    CSS(".bt-tool-status",
        "font-size"    => "11px",
        "padding"      => "2px 7px",
        "border-radius" => "8px",
        "font-weight"  => "600",
        "white-space"  => "nowrap",
        "flex-shrink"  => "0"),

    CSS(".bt-status-pending",    "background" => "#fff3cd", "color" => "#856404"),
    CSS(".bt-status-in_progress","background" => "#cce5ff", "color" => "#004085"),
    CSS(".bt-status-completed",  "background" => "#d4edda", "color" => "#155724"),
    CSS(".bt-status-failed",     "background" => "#f8d7da", "color" => "#721c24"),

    CSS(".bt-tool-preview",
        "margin-top"  => "6px",
        "font-family" => "monospace",
        "font-size"   => "11px",
        "background"  => "rgba(0,0,0,0.04)",
        "padding"     => "4px 8px",
        "border-radius" => "4px",
        "max-height"  => "80px",
        "overflow-y"  => "auto",
        "white-space" => "pre-wrap",
        "word-break"  => "break-all"),

    # Plan
    CSS(".bt-plan-msg",
        "align-self"    => "flex-start",
        "max-width"     => "88%",
        "border"        => "1px solid #e1e4e8",
        "border-radius" => "4px",
        "padding"       => "8px 12px",
        "font-size"     => "13px"),

    CSS(".bt-plan-entry",
        "display"     => "flex",
        "align-items" => "flex-start",
        "gap"         => "8px",
        "padding"     => "3px 0"),

    CSS(".bt-plan-status",
        "width"      => "16px",
        "flex-shrink" => "0",
        "text-align" => "center"),

    # Markdown inside agent bubbles
    CSS(".bt-agent-msg .markdown-body, .bt-agent-msg .markdown",
        "background"   => "none",
        "border"       => "none",
        "padding"      => "0",
        "font-size"    => "inherit",
        "font-family"  => "inherit",
        "color"        => "inherit",
        "line-height"  => "1.5"),

    CSS(".bt-agent-msg .markdown-body > *:first-child, .bt-agent-msg .markdown > *:first-child",
        "margin-top" => "0"),
    CSS(".bt-agent-msg .markdown-body > *:last-child, .bt-agent-msg .markdown > *:last-child",
        "margin-bottom" => "0"),

    CSS(".bt-agent-msg pre",
        "background"    => "#1e1e1e",
        "color"         => "#d4d4d4",
        "border-radius" => "6px",
        "padding"       => "10px 14px",
        "overflow-x"    => "auto",
        "font-size"     => "12px",
        "line-height"   => "1.4",
        "margin"        => "8px 0"),

    CSS(".bt-agent-msg code",
        "background"    => "rgba(0,0,0,0.07)",
        "border-radius" => "3px",
        "padding"       => "1px 4px",
        "font-size"     => "13px"),

    CSS(".bt-agent-msg pre code",
        "background" => "none",
        "padding"    => "0"),

    # Busy indicator
    CSS(".bt-busy",
        "flex-shrink" => "0",
        "height"      => "0",
        "overflow"    => "hidden",
        "display"     => "flex",
        "gap"         => "4px",
        "align-items" => "center",
        "padding"     => "0 16px",
        "transition"  => "height 0.15s"),

    CSS(".bt-busy.bt-busy-active",
        "height"  => "28px",
        "padding" => "4px 16px"),

    CSS(".bt-busy-dot",
        "width"       => "7px",
        "height"      => "7px",
        "border-radius" => "50%",
        "background"  => "#0366d6",
        "animation"   => "bt-pulse 1.2s ease-in-out infinite"),

    CSS(".bt-busy-dot:nth-child(2)", "animation-delay" => "0.2s"),
    CSS(".bt-busy-dot:nth-child(3)", "animation-delay" => "0.4s"),

    CSS("@keyframes bt-pulse",
        CSS("0%, 100%", "opacity" => "0.3", "transform" => "scale(0.8)"),
        CSS("50%",      "opacity" => "1",   "transform" => "scale(1.2)")),

    # Input area — sticks to bottom, mobile-safe
    CSS(".bt-input-area",
        "flex-shrink"  => "0",
        "border-top"   => "1px solid #ddd",
        "padding"      => "10px 12px",
        "padding-bottom" => "max(10px, env(safe-area-inset-bottom))",
        "display"      => "flex",
        "gap"          => "8px",
        "align-items"  => "flex-end",
        "background"   => "#f6f8fa"),

    CSS(".bt-text-input",
        "flex"        => "1",
        "border"      => "1px solid #ccc",
        "border-radius" => "20px",          # pill shape for mobile feel
        "padding"     => "8px 14px",
        "font-size"   => "16px",            # 16px prevents iOS auto-zoom
        "min-height"  => "40px",
        "max-height"  => "120px",
        "font-family" => "inherit",
        "outline"     => "none",
        "box-sizing"  => "border-box",
        "resize"      => "none",
        "overflow-y"  => "auto",
        "line-height" => "1.4"),

    CSS(".bt-text-input:focus", "border-color" => "#0366d6"),

    CSS(".bt-send-btn",
        "background"    => "#0366d6",
        "color"         => "white",
        "border"        => "none",
        "border-radius" => "50%",           # circle button for mobile
        "width"         => "40px",
        "height"        => "40px",
        "font-size"     => "18px",
        "cursor"        => "pointer",
        "flex-shrink"   => "0",
        "display"       => "flex",
        "align-items"   => "center",
        "justify-content" => "center",
        "padding"       => "0"),

    CSS(".bt-send-btn:hover",    "background" => "#0256c0"),
    CSS(".bt-send-btn:disabled", "opacity" => "0.4", "cursor" => "not-allowed"),

    CSS(".bt-stop-btn",
        "background"    => "#dc3545",
        "color"         => "white",
        "border"        => "none",
        "border-radius" => "50%",
        "width"         => "40px",
        "height"        => "40px",
        "font-size"     => "14px",
        "cursor"        => "pointer",
        "flex-shrink"   => "0",
        "display"       => "flex",
        "align-items"   => "center",
        "justify-content" => "center",
        "padding"       => "0"),

    CSS(".bt-stop-btn:hover",    "background" => "#c82333"),
    CSS(".bt-stop-btn:disabled", "opacity" => "0.4", "cursor" => "not-allowed"),
)
