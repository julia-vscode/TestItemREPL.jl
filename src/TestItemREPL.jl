module TestItemREPL

using ReplMaker
using TestItemRunnerCore: run_tests, kill_test_processes, terminate_process,
    get_active_processes, RunProfile, ProcessInfo,
    TestrunResult, TestrunResultTestitem, TestrunResultTestitemProfile,
    TestrunResultMessage, TestrunResultDefinitionError,
    CancellationTokenSource, cancel, get_token
using JuliaWorkspaces
using JuliaWorkspaces.URIs2: uri2filepath

# ── Background run state ──────────────────────────────────────────────

mutable struct BackgroundRun
    task::Task
    cts::CancellationTokenSource
    result::Union{Nothing,TestrunResult}
    error::Union{Nothing,Exception}
    start_time::Float64
end

const _bg_run = Ref{Union{Nothing,BackgroundRun}}(nothing)
const _last_result = Ref{Union{Nothing,TestrunResult}}(nothing)

# ── Argument parsing ──────────────────────────────────────────────────

function parse_args(parts)
    positional = String[]
    kwargs = Dict{Symbol,String}()
    flags = Set{Symbol}()
    for p in parts
        if startswith(p, "--")
            body = p[3:end]
            if contains(body, '=')
                k, v = split(body, '='; limit=2)
                kwargs[Symbol(k)] = v
            else
                push!(flags, Symbol(body))
            end
        else
            push!(positional, p)
        end
    end
    return positional, kwargs, flags
end

# ── Commands ──────────────────────────────────────────────────────────

function cmd_help()
    printstyled("TestItemREPL commands:\n\n"; bold=true)
    println("  help                          Show this help message")
    println("  list [path]                   List discovered test items")
    println("  list --tags=tag1,tag2         Filter by tags")
    println("  run [path|name]               Run tests (blocking, Ctrl+C to cancel)")
    println("  run --tags=t1,t2              Filter by tags")
    println("  run --workers=N               Max parallel workers (default: nthreads)")
    println("  run --timeout=S               Timeout in seconds (default: 300)")
    println("  run --coverage                Enable coverage")
    println("  run& [same options]           Run tests in background")
    println("  status                        Show background run status")
    println("  cancel                        Cancel active background run")
    println("  results                       Show last test run results")
    println("  processes                     Show active test processes")
    println("  kill                          Kill all test processes")
    nothing
end

function cmd_list(args)
    positional, kwargs, flags = parse_args(args)
    path = isempty(positional) ? pwd() : positional[1]

    if !isdir(path)
        printstyled("Error: "; color=:red, bold=true)
        println("'$path' is not a directory")
        return nothing
    end

    jw = JuliaWorkspaces.workspace_from_folders([path])
    all_items = JuliaWorkspaces.get_test_items(jw)

    tag_filter = if haskey(kwargs, :tags)
        Set(Symbol.(split(kwargs[:tags], ',')))
    else
        nothing
    end

    count = 0
    for (uri, items) in pairs(all_items)
        textfile = JuliaWorkspaces.get_text_file(jw, uri)
        filepath = uri2filepath(uri)
        for item in items.testitems
            if tag_filter !== nothing && isempty(intersect(Set(item.option_tags), tag_filter))
                continue
            end
            line, _ = JuliaWorkspaces.position_at(textfile.content, item.code_range.start)
            tags_str = isempty(item.option_tags) ? "" : " [$(join(item.option_tags, ", "))]"
            printstyled("  $(item.name)"; bold=true)
            print("  $filepath:$line")
            if !isempty(tags_str)
                printstyled(tags_str; color=:cyan)
            end
            println()
            count += 1
        end
    end

    if count == 0
        println("  No test items found.")
    else
        println()
        println("$count test item(s) found.")
    end
    nothing
end

function _build_run_kwargs(args; return_results=false)
    positional, kwargs, flags = parse_args(args)
    path = nothing
    name_filter = nothing

    for p in positional
        if isdir(p)
            path = p
        else
            name_filter = p
        end
    end
    if path === nothing
        path = pwd()
    end

    run_kwargs = Dict{Symbol,Any}(
        :return_results => return_results,
        :print_failed_results => true,
        :print_summary => true,
        :progress_ui => :log,
    )

    if haskey(kwargs, :workers)
        run_kwargs[:max_workers] = parse(Int, kwargs[:workers])
    end
    if haskey(kwargs, :timeout)
        run_kwargs[:timeout] = parse(Int, kwargs[:timeout])
    end
    if :coverage in flags
        run_kwargs[:environments] = [RunProfile("Default", true, Dict{String,Any}())]
    end

    tag_filter = if haskey(kwargs, :tags)
        Set(Symbol.(split(kwargs[:tags], ',')))
    else
        nothing
    end

    if tag_filter !== nothing || name_filter !== nothing
        run_kwargs[:filter] = function(info)
            if name_filter !== nothing && !contains(lowercase(string(info.name)), lowercase(name_filter))
                return false
            end
            if tag_filter !== nothing && isempty(intersect(Set(info.tags), tag_filter))
                return false
            end
            return true
        end
    end

    return path, run_kwargs
end

function cmd_run(args)
    _check_bg_completion()
    path, run_kwargs = _build_run_kwargs(args)

    cts = CancellationTokenSource()
    run_kwargs[:token] = get_token(cts)

    try
        result = run_tests(path; return_results=true, run_kwargs...)
        _last_result[] = result
    catch e
        if e isa InterruptException
            cancel(cts)
            printstyled("\nTest run cancelled.\n"; color=:yellow)
        else
            rethrow()
        end
    end
    nothing
end

function cmd_run_bg(args)
    _check_bg_completion()

    if _bg_run[] !== nothing && !istaskdone(_bg_run[].task)
        printstyled("A background run is already active. Use 'cancel' first.\n"; color=:yellow)
        return nothing
    end

    path, run_kwargs = _build_run_kwargs(args; return_results=true)
    cts = CancellationTokenSource()
    run_kwargs[:token] = get_token(cts)
    run_kwargs[:progress_ui] = :log

    bg = BackgroundRun(
        @async(try
            run_tests(path; run_kwargs...)
        catch e
            e
        end),
        cts,
        nothing,
        nothing,
        time(),
    )

    @async begin
        raw = try
            fetch(bg.task)
        catch e
            e
        end
        if raw isa Exception
            bg.error = raw
        elseif raw isa TestrunResult
            bg.result = raw
            _last_result[] = raw
        end
    end

    _bg_run[] = bg
    printstyled("Test run started in background.\n"; color=:green)
    nothing
end

function cmd_status()
    _check_bg_completion()
    bg = _bg_run[]
    if bg === nothing
        println("No background test run.")
        return nothing
    end

    elapsed = round(time() - bg.start_time; digits=1)
    if istaskdone(bg.task)
        if bg.error !== nothing
            printstyled("Background run errored"; color=:red, bold=true)
            println(" after $(elapsed)s: $(bg.error)")
        else
            printstyled("Background run completed"; color=:green, bold=true)
            println(" in $(elapsed)s. Use 'results' to see details.")
        end
    else
        printstyled("Background run in progress"; color=:yellow, bold=true)
        println(" ($(elapsed)s elapsed)")
    end
    nothing
end

function cmd_cancel()
    bg = _bg_run[]
    if bg === nothing || istaskdone(bg.task)
        println("No active background run to cancel.")
        return nothing
    end
    cancel(bg.cts)
    printstyled("Background run cancel requested.\n"; color=:yellow)
    nothing
end

function cmd_results()
    _check_bg_completion()
    result = _last_result[]
    if result === nothing
        println("No test results available.")
        return nothing
    end

    n_passed = 0
    n_failed = 0
    n_errored = 0
    n_skipped = 0

    for ti in result.testitems
        for prof in ti.profiles
            if prof.status == :passed
                n_passed += 1
            elseif prof.status == :failed
                n_failed += 1
            elseif prof.status == :errored
                n_errored += 1
            elseif prof.status == :skipped
                n_skipped += 1
            end
        end
    end

    if !isempty(result.definition_errors)
        printstyled("\nDefinition errors:\n"; color=:red, bold=true)
        for de in result.definition_errors
            println("  $(uri2filepath(de.uri)):$(de.line) — $(de.message)")
        end
    end

    println()
    printstyled("Results: "; bold=true)
    parts = String[]
    n_passed > 0 && push!(parts, "$n_passed passed")
    n_failed > 0 && push!(parts, "$n_failed failed")
    n_errored > 0 && push!(parts, "$n_errored errored")
    n_skipped > 0 && push!(parts, "$n_skipped skipped")
    total = n_passed + n_failed + n_errored + n_skipped
    println("$total test(s): $(join(parts, ", ")).")

    # Show failed/errored details
    for ti in result.testitems
        for prof in ti.profiles
            if prof.status in (:failed, :errored)
                println()
                label = prof.status == :failed ? "FAIL" : "ERROR"
                printstyled("  [$label] $(ti.name)"; color=:red, bold=true)
                if prof.duration !== missing
                    print(" ($(prof.duration)ms)")
                end
                println()
                if prof.messages !== missing
                    for msg in prof.messages
                        println("    $(uri2filepath(msg.uri)):$(msg.line)")
                        println("    ", replace(msg.message, "\n" => "\n    "))
                    end
                end
            end
        end
    end
    nothing
end

function cmd_kill()
    kill_test_processes()
    printstyled("All test processes terminated.\n"; color=:yellow)
    nothing
end

function cmd_processes()
    procs = get_active_processes()
    if isempty(procs)
        println("No active test processes.")
        return nothing
    end

    printstyled("Active test processes:\n\n"; bold=true)
    printstyled("  $(rpad("ID", 38))$(rpad("Package", 30))Status\n"; bold=true)
    printstyled("  $(repeat("─", 78))\n"; color=:light_black)
    for p in procs
        status_color = if p.status == "Running"
            :green
        elseif p.status == "Idle"
            :light_black
        elseif p.status in ("Launching", "Activating", "Revising")
            :yellow
        else
            :default
        end
        print("  $(rpad(p.id, 38))$(rpad(p.package_name, 30))")
        printstyled("$(p.status)\n"; color=status_color)
    end
    println()
    println("$(length(procs)) process(es) active.")
    nothing
end

# ── Helpers ───────────────────────────────────────────────────────────

function _check_bg_completion()
    bg = _bg_run[]
    if bg !== nothing && istaskdone(bg.task)
        if bg.result !== nothing && bg.error === nothing
            elapsed = round(time() - bg.start_time; digits=1)
            printstyled("Background run completed in $(elapsed)s. Use 'results' to see details.\n"; color=:green)
        elseif bg.error !== nothing
            printstyled("Background run errored: $(bg.error)\n"; color=:red)
        end
    end
end

# ── REPL parser ───────────────────────────────────────────────────────

function repl_parser(input::String)
    input = strip(input)
    isempty(input) && return nothing

    # Handle run& syntax: treat "run&" as background run command
    bg_run = false
    if startswith(input, "run&")
        bg_run = true
        input = "run" * input[5:end]  # remove the &
    end

    parts = split(input)
    cmd = lowercase(parts[1])
    args = parts[2:end]

    if cmd == "help" || cmd == "?"
        return cmd_help()
    elseif cmd == "list" || cmd == "ls"
        return cmd_list(args)
    elseif cmd == "run"
        if bg_run
            return cmd_run_bg(args)
        else
            return cmd_run(args)
        end
    elseif cmd == "status" || cmd == "st"
        return cmd_status()
    elseif cmd == "cancel"
        return cmd_cancel()
    elseif cmd == "results" || cmd == "res"
        return cmd_results()
    elseif cmd == "processes" || cmd == "procs" || cmd == "ps"
        return cmd_processes()
    elseif cmd == "kill"
        return cmd_kill()
    else
        printstyled("Unknown command: $cmd\n"; color=:red)
        println("Type 'help' for available commands.")
        return nothing
    end
end

# ── REPL mode registration ───────────────────────────────────────────

function __init__()
    isdefined(Base, :active_repl) || return

    initrepl(
        repl_parser;
        prompt_text="test> ",
        prompt_color=:yellow,
        start_key=')',
        mode_name="TestItem",
        sticky_mode=true,
        valid_input_checker=s -> true,
    )
end

end # module TestItemREPL
