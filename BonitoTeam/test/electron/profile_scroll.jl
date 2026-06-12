# Scroll profiling harness. Measures the REAL costs, not theories:
#   • refresh()/visibleRange() per-call time at growing chat sizes (is the
#     scroll hot path O(N)?)
#   • live ResizeObserver count + cache size
#   • rAF cadence in THIS window (settles the hidden-window-throttle question)
#   • the post-burst "gap" curve over time (does the chase never settle =
#     broken, or settle slowly = timing?)
#
# Run:  julia --project=. test/electron/profile_scroll.jl [show]
#   pass `show` as arg1 to open a VISIBLE window.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))
using BonitoTeam, Statistics

SHOW = length(ARGS) >= 1 && ARGS[1] == "show"

state = TH.make_state(; n_workers = 0, n_projects = 1)
proj  = state.projects[]["p-1"]
model = BonitoTeam.ChatModel(state, proj.server_path; project_id = proj.id,
                             transport = TH.mock_transport(; scripted = []))
BonitoTeam.start_chat_client!(model)

ctx = TH.open_window(state; show = SHOW)
println("=== profile_scroll  (show=$SHOW) ===")

try
    @assert TH.wait_for(ctx,
        """document.querySelector('.bt-side-item[data-project-id="p-1"]') !== null""";
        timeout = 8.0) "no sidebar"
    TH.eval_js(ctx, """document.querySelector('.bt-side-item[data-project-id="p-1"]').click()""")
    @assert TH.wait_for(ctx, "document.querySelector('.bt-text-input') !== null";
                        timeout = 15.0) "no chat"

    # rAF cadence in this window — settles the throttle question with data.
    raf = TH.eval_js(ctx, """(async () => {
        const ts = [];
        await new Promise(res => {
            let n = 0;
            const step = (t) => { ts.push(t); if (++n < 12) requestAnimationFrame(step); else res(); };
            requestAnimationFrame(step);
        });
        const d = []; for (let i = 1; i < ts.length; i++) d.push(ts[i] - ts[i-1]);
        d.sort((a,b)=>a-b);
        return { medianMs: Math.round(d[d.length>>1]), maxMs: Math.round(d[d.length-1]) };
    })()""")
    println("rAF interval: median=$(raf["medianMs"])ms max=$(raf["maxMs"])ms",
            raf["medianMs"] > 50 ? "   ← THROTTLED" : "   ← ~60fps")

    for n in (100, 500, 1500, 3000)
        # Grow the store to 2n messages and re-point the chat at the new count.
        TH.seed_chat_history!(model, n - length(model.msgs_store) ÷ 2)
        BonitoTeam.chat_emit(model, Dict{String,Any}(
            "type" => "msgs.count", "n" => length(model.msgs_store)))
        sleep(0.6)
        # Scroll to a middle offset so visibleRange/indexAt do real work, then
        # time refresh() (the per-scroll-event hot path).
        stats = TH.eval_js(ctx, """(() => {
            const chat = document.querySelector('.bt-messages').__bt_chat;
            const c = chat.container;
            c.scrollTop = Math.floor(c.scrollHeight * 0.5);
            // Warm + time 60 refresh() calls.
            for (let i=0;i<5;i++) chat.refresh();
            const t0 = performance.now();
            for (let i=0;i<60;i++) chat.refresh();
            const refreshMs = (performance.now() - t0) / 60;
            const t1 = performance.now();
            for (let i=0;i<60;i++) chat.visibleRange();
            const vrMs = (performance.now() - t1) / 60;
            return { total: chat.totalCount, ros: chat.ros.size,
                     cache: chat.cache.size, rendered: chat.rendered.size,
                     refreshMs: Math.round(refreshMs*1000)/1000,
                     vrMs: Math.round(vrMs*1000)/1000 };
        })()""")
        println("N=$(lpad(stats["total"],5))  refresh=$(lpad(stats["refreshMs"],7))ms  ",
                "visibleRange=$(lpad(stats["vrMs"],7))ms  ros=$(stats["ros"])  ",
                "cache=$(stats["cache"])  rendered=$(stats["rendered"])")
    end

    # Burst test: 30 chunks to a streaming message, sample the gap curve.
    push!(model.msgs_store, BonitoTeam.AgentMsg("stream-x", ""))
    BonitoTeam.chat_emit(model, Dict{String,Any}("type" => "agent", "id" => "stream-x",
        "streaming" => true, "text" => "", "n" => length(model.msgs_store)))
    sleep(0.3)
    for i in 1:30
        BonitoTeam.chat_emit(model, Dict{String,Any}("type" => "chunk", "id" => "stream-x",
            "text" => "Lorem ipsum dolor sit amet, consectetur adipiscing elit. "))
    end
    curve = TH.eval_js(ctx, """(async () => {
        const c = document.querySelector('.bt-messages');
        const gap = () => Math.round(c.scrollHeight - c.scrollTop - c.clientHeight);
        const out = [];
        for (let i=0;i<20;i++){ out.push(gap()); await new Promise(r=>setTimeout(r,100)); }
        return out;
    })()""")
    println("gap curve (every 100ms, px): ", curve)
    settle_idx = findfirst(g -> g < 200, curve)
    println(settle_idx === nothing ? "  → NEVER settled < 200px in 2s (real problem)" :
            "  → settled < 200px after $((settle_idx-1)*100)ms")

    # ── Real frame-time during a realistic fling over CACHED content.
    # (Only meaningful at 60Hz, i.e. show=true + backgroundThrottling off.)
    # Warm the tail region first so we measure scroll PAINT/handler cost, not
    # one-time fetch+measure. Then oscillate scrollTop within the cached
    # window like a fling and capture every frame's duration.
    if SHOW
        frames = TH.eval_js(ctx, """(async () => {
            const c = document.querySelector('.bt-messages');
            const sleep = ms => new Promise(r=>setTimeout(r,ms));
            // Warm: walk the bottom ~6 viewports so those ranges are cached.
            const vh = c.clientHeight, bottom = c.scrollHeight - vh;
            for (let k=6;k>=0;k--){ c.scrollTop = bottom - k*vh; c.dispatchEvent(new Event('scroll')); await sleep(120); }
            // Measure: oscillate within the cached window on rAF.
            const lo = Math.max(0, bottom - 5*vh), hi = bottom;
            const durs = []; let dir = -1, y = hi;
            await new Promise(res => {
                let last = performance.now(), nf = 0;
                const step = (t) => {
                    durs.push(t - last); last = t;
                    y += dir * (vh/12);
                    if (y < lo) { y = lo; dir = 1; } else if (y > hi) { y = hi; dir = -1; }
                    c.scrollTop = y; c.dispatchEvent(new Event('scroll'));
                    if (++nf < 150) requestAnimationFrame(step); else res();
                };
                requestAnimationFrame(step);
            });
            durs.shift(); durs.sort((a,b)=>a-b);
            const p = q => Math.round(durs[Math.floor(durs.length*q)]*10)/10;
            return { frames: durs.length, p50: p(0.5), p95: p(0.95),
                     max: Math.round(durs[durs.length-1]),
                     dropped: durs.filter(d => d > 20).length,
                     livePills: document.querySelectorAll('.bt-tool-live,.bt-plan-live').length };
        })()""")
        println("FLING over cached content: n=$(frames["frames"])  ",
                "p50=$(frames["p50"])ms  p95=$(frames["p95"])ms  max=$(frames["max"])ms  ",
                "dropped(>20ms)=$(frames["dropped"])  livePills=$(frames["livePills"])")
    end
finally
    TH.shutdown(ctx)
end
