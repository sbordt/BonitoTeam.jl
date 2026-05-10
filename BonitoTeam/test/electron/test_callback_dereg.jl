# Regression test for the "splice during forEach skips next callback" bug
# that caused remounted chats to silently drop their first range response.
#
# Bonito's Observable.notify iterates `#callbacks.forEach((cb) => { ... if
# (cb(value) === false) #callbacks.splice(i, 1) })`. Returning `false`
# from cb mutates the array mid-iteration and forEach happily skips the
# next slot. So when the OLD BonitoChat self-deregistered via
# `return false`, the brand-new BonitoChat's callback (registered right
# after the old one) was skipped on the very next notify — exactly the
# notify carrying the rangeResponse it had just requested.
#
# The fix: callbacks no-op when destroyed instead of returning false.
# This file proves that contract directly, in JS, against a stand-in
# Observable so we don't need a full chat mount.
isdefined(Main, :TH) || include(joinpath(@__DIR__, "helpers.jl"))

state = TH.make_state(; n_workers = 1, n_projects = 1)
ctx   = TH.open_window(state)

results = Pair{String,Bool}[]
record(name, ok) = push!(results, name => ok)

try
    TH.section("Production BonitoChat callbacks return undefined, never false") do
        # Read the live BonitoChat source from the DOM (it's loaded as an
        # asset). This catches anyone re-introducing `return false`.
        #
        # The chat itself isn't required to be mounted for this assertion —
        # we just need the class on `window`.
        has_class = TH.eval_js(ctx, "typeof window.BonitoChat === 'function'")
        record("window.BonitoChat exists", @TH.test_true has_class)
        # Verify the registered callbacks return undefined when destroyed.
        # We construct a tiny Observable-like fake whose .on() captures
        # callbacks, then create a BonitoChat against it, destroy it, and
        # call each captured callback to inspect the return.
        callback_returns = TH.eval_js(ctx, """
            (() => {
                const calls = [];
                const fakeObs = () => ({
                    value: 0,
                    on(cb) { calls.push(cb); },
                });
                const fakeContainer = document.createElement('div');
                fakeContainer.className = 'bt-messages';
                fakeContainer.innerHTML = '<div class="bt-spacer-top"></div><div class="bt-spacer-bottom"></div>';
                document.body.appendChild(fakeContainer);
                const obs = {
                    totalCount:           fakeObs(),
                    requestRange:         { value: null, notify: () => {} },
                    rangeResponse:        fakeObs(),
                    newMsg:               fakeObs(),
                    requestToolRender:    { notify: () => {} },
                    requestThoughtRender: { notify: () => {} },
                    initialCount:         0,
                };
                const bc = new window.BonitoChat(fakeContainer, obs);
                bc.destroy();
                // Now invoke each captured callback. The fix's contract is
                // that they return *undefined* when destroyed, not false.
                const out = calls.map(cb => {
                    try { return cb('whatever'); }
                    catch (e) { return { err: String(e) }; }
                });
                document.body.removeChild(fakeContainer);
                return out.map(r => r === false ? 'FALSE' :
                                     r === undefined ? 'undefined' :
                                     typeof r === 'object' && r !== null ? JSON.stringify(r) :
                                     String(r));
            })()
        """)
        @info "captured callback returns" callback_returns
        record("at least 3 callbacks were registered (totalCount/newMsg/rangeResponse)",
               @TH.test_true (length(callback_returns) >= 3))
        record("none of them return false on destroyed instance",
               @TH.test_true !any(==("FALSE"), callback_returns))
    end

    TH.section("Two consecutive BonitoChats: notify reaches the second") do
        # The actual scenario from the bug report. Build a stand-in
        # Observable that mirrors Bonito's #callbacks + forEach + splice
        # behaviour. Verify that even after old.destroy(), notify still
        # fires the new chat's callback.
        ok = TH.eval_js(ctx, """
            (() => {
                // Stand-in matching Bonito.bundled.js's Observable.notify
                // semantics — forEach + splice on the live array.
                class StandIn {
                    constructor() { this.value = 0; this._cbs = []; }
                    on(cb) { this._cbs.push(cb); }
                    notify(val) {
                        this.value = val;
                        this._cbs.forEach((cb, i, arr) => {
                            const ret = cb(val);
                            if (ret === false) arr.splice(arr.indexOf(cb), 1);
                        });
                    }
                }
                const totalCount   = new StandIn();
                const newMsg       = new StandIn();
                const rangeResponse= new StandIn();
                const requestRange = { value: null, notify: () => {} };
                const requestToolRender    = { notify: () => {} };
                const requestThoughtRender = { notify: () => {} };
                const c1 = document.createElement('div');
                c1.className = 'bt-messages';
                c1.innerHTML = '<div class="bt-spacer-top"></div><div class="bt-spacer-bottom"></div>';
                document.body.appendChild(c1);
                const obs = {
                    totalCount, requestRange, rangeResponse, newMsg,
                    requestToolRender, requestThoughtRender, initialCount: 0,
                };
                const old = new window.BonitoChat(c1, obs);

                const c2 = document.createElement('div');
                c2.className = 'bt-messages';
                c2.innerHTML = '<div class="bt-spacer-top"></div><div class="bt-spacer-bottom"></div>';
                document.body.appendChild(c2);

                old.destroy();
                const fresh = new window.BonitoChat(c2, obs);

                // Trip a notify; the FRESH chat must see it.
                let freshSawIt = false;
                const orig = fresh.refresh.bind(fresh);
                fresh.refresh = () => { freshSawIt = true; orig(); };
                totalCount.notify(7);

                document.body.removeChild(c1);
                document.body.removeChild(c2);
                return freshSawIt && fresh.totalCount === 7;
            })()
        """)
        record("fresh BonitoChat received notify after old's destroy",
               @TH.test_true ok)
    end

finally
    TH.report!("Callback de-register regression", results)
    TH.shutdown(ctx)
end
