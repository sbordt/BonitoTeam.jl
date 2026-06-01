using Test, Jail

@testset "Jail" begin

    @testset "JailConfig defaults" begin
        cfg = JailConfig()
        @test cfg.gpu === true
        @test cfg.network === true
        @test cfg.backend === Jail.default_backend()
    end

    # ── Windows / native integrity-level sandbox ─────────────────────────────
    @static if Sys.iswindows()
        @testset "default backend" begin
            @test Jail.default_backend() === :integrity
        end

        @testset "cmd shape (julia self-relaunch launcher)" begin
            work = mktempdir()
            c  = jail(Cmd(["cmd", "/c", "echo hi"]); whitelist = [work])
            ex = collect(String, c.exec)
            @test occursin("julia", lowercase(ex[1]))
            @test any(a -> occursin("_lowbox_launcher.jl", a), ex)
            @test work in ex
            @test "--" in ex
            @test ex[end-2:end] == ["cmd", "/c", "echo hi"]   # command after `--`
        end

        # Real end-to-end: launches at Low integrity via the launcher and
        # checks the write-isolation guarantee on the host filesystem.
        @testset "real low-integrity write isolation" begin
            work    = mktempdir()
            outside = mktempdir()
            src = joinpath(work, "src.txt"); write(src, "seed\n")
            ok   = joinpath(work,    "ok.txt")
            evil = joinpath(outside, "evil.txt")

            run(jail(Cmd(["cmd", "/c", "copy", src, ok]); whitelist = [work]))
            @test isfile(ok)             # whitelist (Low-labelled) write reaches host

            try
                run(jail(Cmd(["cmd", "/c", "copy", src, evil]); whitelist = [work]))
            catch
            end
            @test !isfile(evil)          # write outside whitelist is denied

            rm(work; recursive = true, force = true)
            rm(outside; recursive = true, force = true)
        end

        @testset "stdio flows through the jail" begin
            out = read(jail(Cmd(["cmd", "/c", "echo", "HELLO_JAILED"])), String)
            @test occursin("HELLO_JAILED", out)
        end
    end

    # ── Linux / bwrap + landrun (CI; not exercised on the Windows dev box) ────
    @static if Sys.islinux()
        @testset "default backend present" begin
            @test Jail.default_backend() in (:bwrap, :landrun)
        end
        if Sys.which("bwrap") !== nothing
            @testset "bwrap command shape" begin
                work = mktempdir()
                c = jail(Cmd(["echo", "hi"]); whitelist = [work], backend = :bwrap, gpu = false)
                ex = collect(String, c.exec)
                @test endswith(ex[1], "bwrap")
                @test "--bind" in ex
                @test work in ex
                @test ex[end-1:end] == ["echo", "hi"]
            end
        end
    end

    # ── macOS / sandbox-exec (untested backend; construct-only smoke) ─────────
    @static if Sys.isapple()
        @testset "default backend" begin
            @test Jail.default_backend() === :sandbox_exec
        end
        if Sys.which("sandbox-exec") !== nothing
            @testset "sandbox-exec profile shape" begin
                work = mktempdir()
                c = jail(Cmd(["echo", "hi"]); whitelist = [work])
                ex = collect(String, c.exec)
                @test ex[1] == "sandbox-exec"
                @test ex[2] == "-p"
                @test occursin("(deny default)", ex[3])
                @test occursin(work, ex[3])
                @test ex[end-1:end] == ["echo", "hi"]
            end
        end
    end
end
