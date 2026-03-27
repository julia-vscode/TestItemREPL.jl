module TestItemREPL

include("pkg_imports.jl")

using .ReplMaker
# import ProgressMeter
# import TestItemControllers
using .TestItemControllers: TestItemController, ControllerCallbacks
using .TestItemControllers.CancellationTokens: CancellationTokenSource, CancellationToken,
    cancel, get_token, is_cancellation_requested
using .AutoHashEquals: @auto_hash_equals
using .JuliaWorkspaces
using .JuliaWorkspaces.URIs2: URI, filepath2uri, uri2filepath
using .TestItemControllers.JSON
using .PrecompileTools: @compile_workload, @setup_workload
using Logging
using Dates

include("dashboard.jl")

# ── Logging filter (suppress TestItemControllers below Warn) ──────────

struct ModuleFilterLogger <: AbstractLogger
    wrapped::AbstractLogger
end

Logging.shouldlog(logger::ModuleFilterLogger, level, _module, group, id) = true
Logging.min_enabled_level(logger::ModuleFilterLogger) = Logging.Debug
Logging.catch_exceptions(logger::ModuleFilterLogger) = Logging.catch_exceptions(logger.wrapped)

function Logging.handle_message(logger::ModuleFilterLogger, level, message, _module, group, id, filepath, line; kwargs...)
    # Suppress TestItemControllers logs below Warn
    mod_name = string(parentmodule(_module))
    if (mod_name == "TestItemREPL.TestItemControllers" || string(_module) == "TestItemREPL.TestItemControllers") && level < Logging.Warn
        return nothing
    end
    Logging.handle_message(logger.wrapped, level, message, _module, group, id, filepath, line; kwargs...)
end

# ── Public types (inlined from TestItemRunnerCore) ────────────────────

@auto_hash_equals struct RunProfile
    name::String
    coverage::Bool
    env::Dict{String,Any}
end

struct ProcessInfo
    id::String
    package_name::String
    status::String
end

struct TestrunResultMessage
    message::String
    uri::URI
    line::Int
    column::Int
end

struct TestrunResultTestitemProfile
    profile_name::String
    status::Symbol
    duration::Union{Float64,Missing}
    messages::Union{Vector{TestrunResultMessage},Missing}
    output::Union{String,Missing}
end

struct TestrunResultTestitem
    name::String
    uri::URI
    profiles::Vector{TestrunResultTestitemProfile}
end

struct TestrunResultDefinitionError
    message::String
    uri::URI
    line::Int
    column::Int
end

struct TestrunResult
    definition_errors::Vector{TestrunResultDefinitionError}
    testitems::Vector{TestrunResultTestitem}
    process_outputs::Dict{String,String}
end

# ── Per-run context (keyed by testrun_id) ─────────────────────────────

mutable struct RunContext
    testitems_by_id::Dict{String,TestItemControllers.TestItemDetail}
    environments::Vector{RunProfile}
    environment_name::String
    progress_ui::Symbol
    progressbar_next::Function
    count_success::Int
    count_fail::Int
    count_error::Int
    count_skipped::Int
    n_total::Int
    responses::Vector{Any}
    outputs::Dict{String,Vector{String}}
    launch_header_printed::Bool
    dashboard_state::Union{Nothing,DashboardState}
end

# ── Run history ───────────────────────────────────────────────────────

mutable struct TestrunRecord
    id::String
    start_time::Float64
    end_time::Union{Nothing,Float64}
    status::Symbol  # :running, :completed, :cancelled, :errored
    result::Union{Nothing,TestrunResult}
    path::String
    cts::Union{Nothing,CancellationTokenSource}
end

# ── Runner state singleton ────────────────────────────────────────────

mutable struct TestItemRunner
    controller::TestItemController
    lock::ReentrantLock
    run_contexts::Dict{String,RunContext}
    processes::Dict{String,ProcessInfo}
    process_outputs::Dict{String,Vector{String}}
    run_history::Vector{TestrunRecord}
    run_counter::Ref{Int}
    max_history::Int
    reactor_task::Union{Nothing,Task}
end

function TestItemRunner(controller::TestItemController; max_history::Int=20)
    TestItemRunner(
        controller,
        ReentrantLock(),
        Dict{String,RunContext}(),
        Dict{String,ProcessInfo}(),
        Dict{String,Vector{String}}(),
        Vector{TestrunRecord}(),
        Ref(0),
        max_history,
        nothing,
    )
end

const _g_runner = Ref{Union{Nothing,TestItemRunner}}(nothing)
const _g_runner_lock = ReentrantLock()

function get_run_context(testrun_id::String)
    runner = get_runner()
    lock(runner.lock) do
        get(runner.run_contexts, testrun_id, nothing)
    end
end

function get_active_processes()
    runner = get_runner()
    lock(runner.lock) do
        collect(values(runner.processes))
    end
end

function get_run_history()
    runner = get_runner()
    lock(runner.lock) do
        copy(runner.run_history)
    end
end

function get_active_runs()
    runner = get_runner()
    lock(runner.lock) do
        filter(r -> r.status == :running, runner.run_history)
    end
end

function cancel_run(id::String)
    runner = get_runner()
    lock(runner.lock) do
        idx = findfirst(r -> r.id == id || startswith(r.id, id), runner.run_history)
        if idx !== nothing
            rec = runner.run_history[idx]
            if rec.status == :running && rec.cts !== nothing
                cancel(rec.cts)
                return true
            end
        end
        return false
    end
end

function get_last_run_id()
    runner = get_runner()
    lock(runner.lock) do
        isempty(runner.run_history) ? nothing : runner.run_history[1].id
    end
end

function get_run_result(id::String)
    runner = get_runner()
    cached = lock(runner.lock) do
        idx = findfirst(r -> r.id == id, runner.run_history)
        idx === nothing && return nothing
        runner.run_history[idx].result
    end
    cached !== nothing && return cached
    # If still running, build a snapshot from the live RunContext
    ctx = lock(runner.lock) do
        get(runner.run_contexts, id, nothing)
    end
    ctx === nothing && return nothing
    _build_result_from_context(runner, id, ctx)
end

function _build_result_from_context(runner::TestItemRunner, testrun_id::String, ctx::RunContext)
    testitem_outputs = ctx.outputs
    collected_process_outputs = lock(runner.lock) do
        Dict{String,String}(pid => join(chunks) for (pid, chunks) in runner.process_outputs)
    end
    testitems = TestrunResultTestitem[
        TestrunResultTestitem(
            ti.testitem.label,
            URI(ti.testitem.uri),
            [TestrunResultTestitemProfile(
                ti.testenvironment.name,
                ti.result.status,
                ti.result.duration,
                ti.result.messages === missing ? missing : [TestrunResultMessage(msg.message, msg.uri === missing ? URI("") : URI(msg.uri), coalesce(msg.line, 0), coalesce(msg.column, 0)) for msg in ti.result.messages],
                haskey(testitem_outputs, ti.testitem.id) ? join(testitem_outputs[ti.testitem.id]) : missing
            )]
        ) for ti in ctx.responses
    ]
    TestrunResult(TestrunResultDefinitionError[], testitems, collected_process_outputs)
end

function _prune_history!(runner::TestItemRunner)
    while length(runner.run_history) > runner.max_history
        idx = findlast(r -> r.status != :running, runner.run_history)
        idx === nothing && break
        deleteat!(runner.run_history, idx)
    end
end

function terminate_process(id::String)
    if _g_runner[] !== nothing
        TestItemControllers.terminate_test_process(_g_runner[].controller, id)
    end
end

# ── Runner initialization ─────────────────────────────────────────────

function get_runner()
    _g_runner[] !== nothing && return _g_runner[]
    lock(_g_runner_lock) do
        _g_runner[] !== nothing && return _g_runner[]

        callbacks = TestItemControllers.ControllerCallbacks(
            on_testitem_started = (testrun_id, testitem_id) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                ds = ctx.dashboard_state
                if ds !== nothing
                    testitem = ctx.testitems_by_id[testitem_id]
                    dashboard_push_testitem!(ds, DashboardTestItem(
                        testitem.label, string(testitem.uri), ctx.environment_name,
                        :running, nothing, String[], ""))
                end
            end,
            on_testitem_passed = (testrun_id, testitem_id, duration) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                ctx.count_success += 1
                testitem = ctx.testitems_by_id[testitem_id]
                if ctx.progress_ui == :log
                    duration_string = duration !== missing ? " ($(duration)ms)" : ""
                    println("✓ $(ctx.environment_name) $(uri2filepath(URI(testitem.uri))):$(testitem.label) → passed$duration_string")
                end
                if ctx.progress_ui == :bar
                    ctx.progressbar_next()
                end
                push!(ctx.responses, (testitem=testitem, testenvironment=ctx.environments[1], result=(status=:passed, messages=missing, duration=duration)))
                ds = ctx.dashboard_state
                if ds !== nothing
                    lock(ds.lock) do
                        ds.count_success = ctx.count_success
                        idx = findlast(t -> t.name == testitem.label && t.status == :running, ds.testitems)
                        if idx !== nothing
                            ds.testitems[idx].status = :passed
                            ds.testitems[idx].duration = duration !== missing ? Float64(duration) : nothing
                        end
                    end
                    dashboard_push_log_entry!(ds, DashboardLogEntry(
                        testitem.label, ctx.environment_name, :passed,
                        duration !== missing ? Float64(duration) : nothing, ""))
                end
            end,
            on_testitem_failed = (testrun_id, testitem_id, messages, duration) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                ctx.count_fail += 1
                testitem = ctx.testitems_by_id[testitem_id]
                if ctx.progress_ui == :log
                    duration_string = duration !== missing ? " ($(duration)ms)" : ""
                    println("✗ $(ctx.environment_name) $(uri2filepath(URI(testitem.uri))):$(testitem.label) → failed$duration_string")
                end
                if ctx.progress_ui == :bar
                    ctx.progressbar_next()
                end
                push!(ctx.responses, (testitem=testitem, testenvironment=ctx.environments[1], result=(status=:failed, messages=messages, duration=duration)))
                ds = ctx.dashboard_state
                if ds !== nothing
                    msg_strs = messages !== missing ? [string(m.message) for m in messages] : String[]
                    lock(ds.lock) do
                        ds.count_fail = ctx.count_fail
                        idx = findlast(t -> t.name == testitem.label && t.status == :running, ds.testitems)
                        if idx !== nothing
                            ds.testitems[idx].status = :failed
                            ds.testitems[idx].duration = duration !== missing ? Float64(duration) : nothing
                            ds.testitems[idx].messages = msg_strs
                        end
                    end
                    summary_msg = isempty(msg_strs) ? "" : first(split(msg_strs[1], '\n'))
                    dashboard_push_log_entry!(ds, DashboardLogEntry(
                        testitem.label, ctx.environment_name, :failed,
                        duration !== missing ? Float64(duration) : nothing, summary_msg))
                end
            end,
            on_testitem_errored = (testrun_id, testitem_id, messages, duration) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                ctx.count_error += 1
                testitem = ctx.testitems_by_id[testitem_id]
                if ctx.progress_ui == :log
                    duration_string = duration !== missing ? " ($(duration)ms)" : ""
                    println("✗ $(ctx.environment_name) $(uri2filepath(URI(testitem.uri))):$(testitem.label) → errored$duration_string")
                end
                if ctx.progress_ui == :bar
                    ctx.progressbar_next()
                end
                push!(ctx.responses, (testitem=testitem, testenvironment=ctx.environments[1], result=(status=:errored, messages=messages, duration=duration)))
                ds = ctx.dashboard_state
                if ds !== nothing
                    msg_strs = messages !== missing ? [string(m.message) for m in messages] : String[]
                    lock(ds.lock) do
                        ds.count_error = ctx.count_error
                        idx = findlast(t -> t.name == testitem.label && t.status == :running, ds.testitems)
                        if idx !== nothing
                            ds.testitems[idx].status = :errored
                            ds.testitems[idx].duration = duration !== missing ? Float64(duration) : nothing
                            ds.testitems[idx].messages = msg_strs
                        end
                    end
                    summary_msg = isempty(msg_strs) ? "" : first(split(msg_strs[1], '\n'))
                    dashboard_push_log_entry!(ds, DashboardLogEntry(
                        testitem.label, ctx.environment_name, :errored,
                        duration !== missing ? Float64(duration) : nothing, summary_msg))
                end
            end,
            on_testitem_skipped = (testrun_id, testitem_id) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                ctx.count_skipped += 1
                testitem = ctx.testitems_by_id[testitem_id]
                if ctx.progress_ui == :log
                    println("⊘ $(ctx.environment_name) $(uri2filepath(URI(testitem.uri))):$(testitem.label) → skipped")
                end
                if ctx.progress_ui == :bar
                    ctx.progressbar_next()
                end
                push!(ctx.responses, (testitem=testitem, testenvironment=ctx.environments[1], result=(status=:skipped, messages=missing, duration=missing)))
                ds = ctx.dashboard_state
                if ds !== nothing
                    lock(ds.lock) do
                        ds.count_skipped = ctx.count_skipped
                        idx = findlast(t -> t.name == testitem.label && t.status == :running, ds.testitems)
                        if idx !== nothing
                            ds.testitems[idx].status = :skipped
                        end
                    end
                    dashboard_push_log_entry!(ds, DashboardLogEntry(
                        testitem.label, ctx.environment_name, :skipped, nothing, ""))
                end
            end,
            on_append_output = (testrun_id, testitem_id, output) -> begin
                ctx = get_run_context(testrun_id)
                ctx === nothing && return
                testitem_id === nothing && return  # process-level output; captured by on_process_output
                if !haskey(ctx.outputs, testitem_id)
                    ctx.outputs[testitem_id] = String[]
                end
                push!(ctx.outputs[testitem_id], output)
                ds = ctx.dashboard_state
                if ds !== nothing && testitem_id !== nothing
                    testitem = get(ctx.testitems_by_id, testitem_id, nothing)
                    if testitem !== nothing
                        lock(ds.lock) do
                            idx = findlast(t -> t.name == testitem.label, ds.testitems)
                            if idx !== nothing
                                ds.testitems[idx].output *= output
                            end
                        end
                    end
                end
            end,
            on_attach_debugger = (testrun_id, debug_pipename) -> nothing,
            on_process_created = (id, package_name, package_uri, project_uri, coverage, env) -> begin
                runner = _g_runner[]
                lock(runner.lock) do
                    runner.processes[id] = ProcessInfo(id, package_name, "Launching")
                end
                # Update all active dashboard states
                lock(runner.lock) do
                    for ctx in values(runner.run_contexts)
                        ds = ctx.dashboard_state
                        ds !== nothing && dashboard_update_process!(ds, id, package_name, "Launching")
                    end
                end
            end,
            on_process_terminated = (id) -> begin
                runner = _g_runner[]
                lock(runner.lock) do
                    delete!(runner.processes, id)
                end
                lock(runner.lock) do
                    for ctx in values(runner.run_contexts)
                        ds = ctx.dashboard_state
                        ds !== nothing && dashboard_remove_process!(ds, id)
                    end
                end
            end,
            on_process_status_changed = (id, status) -> begin
                runner = _g_runner[]
                pkg_name = ""
                lock(runner.lock) do
                    if haskey(runner.processes, id)
                        old = runner.processes[id]
                        pkg_name = old.package_name
                        runner.processes[id] = ProcessInfo(old.id, old.package_name, status)
                    end
                end
                # Update dashboard states
                lock(runner.lock) do
                    for ctx in values(runner.run_contexts)
                        ds = ctx.dashboard_state
                        ds !== nothing && dashboard_update_process!(ds, id, pkg_name, status)
                    end
                end
                if status == "Launching"
                    lock(runner.lock) do
                        for ctx in values(runner.run_contexts)
                            if ctx.progress_ui == :bar
                                if !ctx.launch_header_printed
                                    ctx.launch_header_printed = true
                                    printstyled("  Launching test processes"; color=:cyan)
                                end
                                printstyled("."; color=:cyan)
                            end
                        end
                    end
                end
            end,
            on_process_output = (id, output) -> begin
                runner = _g_runner[]
                lock(runner.lock) do
                    if !haskey(runner.process_outputs, id)
                        runner.process_outputs[id] = String[]
                    end
                    push!(runner.process_outputs[id], output)
                end
                # Push to dashboard states (per-process output)
                lock(runner.lock) do
                    for ctx in values(runner.run_contexts)
                        ds = ctx.dashboard_state
                        ds !== nothing && dashboard_push_process_line!(ds, id, output)
                    end
                end
            end,
        )

        controller = TestItemController(callbacks)
        runner = TestItemRunner(controller)
        _g_runner[] = runner
        runner.reactor_task = @async try
            run(runner.controller)
        catch err
            Base.display_error(err, catch_backtrace())
        end

        return runner
    end
end

# ── Main entry point ──────────────────────────────────────────────────

function run_tests(
            path;
            filter=nothing,
            verbose=false,
            max_workers::Int=min(Sys.CPU_THREADS, 8),
            timeout=60*5,
            fail_on_detection_error=true,
            return_results=false,
            print_failed_results=true,
            print_summary=true,
            progress_ui=:bar,
            environments=[RunProfile("Default", false, Dict{String,Any}())],
            julia_cmd::String="julia",
            julia_args::Vector{String}=String[],
            token=nothing,
            dashboard_state::Union{Nothing,DashboardState}=nothing
        )
    if progress_ui == :none
        print_summary = false
        print_failed_results = false
    end

    runner = get_runner()
    tic = runner.controller
    runner.run_counter[] += 1
    testrun_id = string(runner.run_counter[])

    cts_for_history = if token !== nothing
        nothing
    else
        nothing
    end
    record = TestrunRecord(testrun_id, time(), nothing, :running, nothing, string(path), cts_for_history)
    lock(runner.lock) do
        pushfirst!(runner.run_history, record)
        _prune_history!(runner)
    end

    jw = JuliaWorkspaces.workspace_from_folders(([path]))
    _add_active_project!(jw, path)

    testitems = []
    testerrors = []
    for (uri, items) in pairs(JuliaWorkspaces.get_test_items(jw))
        project_details = JuliaWorkspaces.get_test_env(jw, uri)
        textfile = JuliaWorkspaces.get_text_file(jw, uri)

        for item in items.testitems            
            line, column = JuliaWorkspaces.position_at(textfile.content, item.code_range.start)
            push!(testitems, (
                uri=uri,
                line=line,
                column=column,
                code=textfile.content.content[item.code_range],
                env=project_details,
                detail=item),
            )
        end

        for item in items.testerrors
            line, column = JuliaWorkspaces.position_at(textfile.content, item.range.start)
            push!(testerrors,
                (
                    uri=string(uri),
                    line=line,
                    column=column,
                    message=item.message
                )
            )
        end
    end

    responses = []

    if length(testerrors) == 0  || fail_on_detection_error==false
        if filter !== nothing
            cd(path) do
                filter!(i->filter((filename=uri2filepath(i.uri), name=i.detail.name, tags=i.detail.option_tags, package_name=i.env.package_name)), testitems)
            end
        end

        n_total = length(testitems)*length(environments)

        if progress_ui != :none
            n_files = length(unique(i.uri for i in testitems))
            printstyled("  Discovered $n_total test item(s) in $n_files file(s)\n"; color=:cyan)
        end

        p = ProgressMeter.Progress(n_total;
            barglyphs=ProgressMeter.BarGlyphs('┣','━','╸',' ','┫'),
            color=:green, enabled=progress_ui==:bar)

        debuglogger = Logging.ConsoleLogger(stderr, Logging.Warn)

        environment_name = environments[1].name

        Logging.with_logger(debuglogger) do

            testitems_to_run_by_id = Dict{String, TestItemControllers.TestItemDetail}()
                    for (uri, file_info) in pairs(JuliaWorkspaces.get_test_items(jw))
                        project_details = JuliaWorkspaces.get_test_env(jw, uri)
                        textfile = JuliaWorkspaces.get_text_file(jw, uri)
                        for item in file_info.testitems
                            testitems_to_run_by_id[item.id] = TestItemControllers.TestItemDetail(
                                item.id,
                                string(item.uri),
                                item.name,
                                project_details.package_name,
                                string(project_details.package_uri),
                                project_details.project_uri === nothing ? nothing : string(project_details.project_uri),
                                string(project_details.env_content_hash),
                                item.option_default_imports,
                                string.(item.option_setup),
                                JuliaWorkspaces.position_at(textfile.content, item.code_range.start)[1],
                                JuliaWorkspaces.position_at(textfile.content, item.code_range.start)[2],
                                textfile.content.content[item.code_range],
                                JuliaWorkspaces.position_at(textfile.content, item.code_range.stop)[1],
                                JuliaWorkspaces.position_at(textfile.content, item.code_range.stop)[2],
                                Float64(timeout)
                            )
                        end
                    end

            if filter !== nothing
                filtered_ids = Set(i.detail.id for i in testitems)
                for id in collect(keys(testitems_to_run_by_id))
                    if !(id in filtered_ids)
                        delete!(testitems_to_run_by_id, id)
                    end
                end
            end

            if isempty(testitems_to_run_by_id)
                @warn "No test items to run" filter_applied=(filter !== nothing)
            end

            ctx = RunContext(
                testitems_to_run_by_id,
                environments,
                environment_name,
                progress_ui,
                () -> nothing,
                0, 0, 0, 0,
                n_total,
                responses,
                Dict{String,Vector{String}}(),
                false,
                dashboard_state,
            )

            # Update dashboard state with discovered totals
            if dashboard_state !== nothing
                lock(dashboard_state.lock) do
                    dashboard_state.run_id = testrun_id
                    dashboard_state.n_total = n_total
                end
            end

            ctx.progressbar_next = () -> begin
                if ctx.launch_header_printed
                    ctx.launch_header_printed = false
                    println()
                end
                done = ctx.count_success + ctx.count_fail + ctx.count_error + ctx.count_skipped
                if done >= ctx.n_total
                    # Final update — erase the progress bar
                    ProgressMeter.cancel(p, ""; keep=false)
                else
                    parts = String[]
                    ctx.count_success > 0 && push!(parts, "$(ctx.count_success) passed")
                    ctx.count_fail > 0 && push!(parts, "$(ctx.count_fail) failed")
                    ctx.count_error > 0 && push!(parts, "$(ctx.count_error) errored")
                    ctx.count_skipped > 0 && push!(parts, "$(ctx.count_skipped) skipped")
                    detail = isempty(parts) ? "" : " ($(join(parts, ", ")))"
                    ProgressMeter.next!(
                        p,
                        showvalues = [
                            (Symbol("Progress"), "$done/$(ctx.n_total)$detail"),
                        ]
                    )
                end
            end

            lock(runner.lock) do
                runner.run_contexts[testrun_id] = ctx
            end

            ret = try
                TestItemControllers.execute_testrun(
                    tic,
                    testrun_id,
                    [
                        TestItemControllers.TestProfile(
                            i.name,
                            "$(i.name) Profile",
                            julia_cmd,
                            julia_args,
                            missing,
                            Dict{String,Union{String,Nothing}}(k => v isa AbstractString ? string(v) : v === nothing ? nothing : string(v) for (k,v) in i.env),
                            max_workers,
                            i.coverage ? "Coverage" : "Normal",
                            nothing,
                            :Info
                        ) for i in environments
                    ],
                    collect(TestItemControllers.TestItemDetail, values(testitems_to_run_by_id)),
                    let
                        setups = TestItemControllers.TestSetupDetail[]
                        for (uri, file_info) in pairs(JuliaWorkspaces.get_test_items(jw))
                            project_details = JuliaWorkspaces.get_test_env(jw, uri)
                            project_details.package_uri === nothing && continue
                            textfile = JuliaWorkspaces.get_text_file(jw, uri)
                            for setup in file_info.testsetups
                                push!(setups, TestItemControllers.TestSetupDetail(
                                    string(project_details.package_uri),
                                    string(setup.name),
                                    string(setup.kind),
                                    string(uri),
                                    JuliaWorkspaces.position_at(textfile.content, setup.code_range.start)[1],
                                    JuliaWorkspaces.position_at(textfile.content, setup.code_range.start)[2],
                                    textfile.content.content[setup.code_range]
                                ))
                            end
                        end
                        setups
                    end,
                    token,
                )
            catch err
                @error "TestItemControllers.execute_testrun failed" exception=(err, catch_backtrace())
                rethrow(err)
            finally
                # Safety-net: clear progress bar in case of cancellation/error/zero tests
                try; ProgressMeter.cancel(p, ""; keep=false); catch; end
                # Mark dashboard as completed
                if dashboard_state !== nothing
                    try
                        ds_status = if token !== nothing && CancellationTokens.is_cancelled(token)
                            :cancelled
                        elseif ctx.count_error > 0 || ctx.count_fail > 0
                            :completed
                        else
                            :completed
                        end
                        dashboard_set_completed!(dashboard_state, ds_status)
                    catch
                    end
                end
                try
                    partial = _build_result_from_context(runner, testrun_id, ctx)
                    lock(runner.lock) do
                        idx = findfirst(r -> r.id == testrun_id, runner.run_history)
                        if idx !== nothing && runner.run_history[idx].result === nothing
                            runner.run_history[idx].result = partial
                        end
                    end
                catch
                end
                lock(runner.lock) do
                    delete!(runner.run_contexts, testrun_id)
                end
            end

            if any(env -> env.coverage, environments) && ret !== missing && ret !== nothing
                @info "Coverage data collected but not yet processed"
            end

            count_success = ctx.count_success
            count_fail = ctx.count_fail
            count_error = ctx.count_error
            count_skipped = ctx.count_skipped
            testitem_outputs = ctx.outputs

            if ctx.launch_header_printed
                println()
            end
        end
    else
        count_success = 0
        count_fail = 0
        count_error = 0
        count_skipped = 0
        testitem_outputs = Dict{String,Vector{String}}()
    end

    if print_summary
        println()
        parts = String[]
        length(testerrors) > 0 && push!(parts, "$(length(testerrors)) definition error$(ifelse(length(testerrors)==1,"", "s"))")
        push!(parts, "$(length(responses)) tests ran")
        count_success > 0 && push!(parts, "\e[32m$(count_success) passed\e[0m")
        count_fail > 0 && push!(parts, "\e[31m$(count_fail) failed\e[0m")
        count_error > 0 && push!(parts, "\e[31m$(count_error) errored\e[0m")
        count_skipped > 0 && push!(parts, "$(count_skipped) skipped")
        println(join(parts, ", "), ".")
    end

    if print_failed_results
        for te in testerrors
            println()
            println("Definition error at $(uri2filepath(URI(te.uri))):$(te.line)")
            println("  $(te.message)")
        end
    
        for i in responses
            if i.result.status in (:failed, :errored) 
                println()
                label = i.result.status == :failed ? "FAIL" : "ERROR"
                printstyled("  [$label] $(i.testitem.label)"; color=:red, bold=true)
                if i.result.duration !== missing
                    print(" ($(i.result.duration)ms)")
                end
                println()
                if i.result.messages!==missing                
                    for j in i.result.messages
                        println("    ", replace(j.message, "\n"=>"\n    "))
                    end
                end
            end
        end
    end

    collected_process_outputs = lock(runner.lock) do
        Dict{String,String}(id => join(chunks) for (id, chunks) in runner.process_outputs)
    end

    duplicated_testitems = TestrunResultTestitem[
        TestrunResultTestitem(
            ti.testitem.label,
            URI(ti.testitem.uri),
            [TestrunResultTestitemProfile(
                ti.testenvironment.name,
                ti.result.status,
                ti.result.duration,
                ti.result.messages === missing ? missing : [TestrunResultMessage(msg.message, msg.uri === missing ? URI("") : URI(msg.uri), coalesce(msg.line, 0), coalesce(msg.column, 0)) for msg in ti.result.messages],
                haskey(testitem_outputs, ti.testitem.id) ? join(testitem_outputs[ti.testitem.id]) : missing
            )]
        ) for ti in responses
    ]

    dedup_dict = Dict{Tuple{String, URI}, TestrunResultTestitem}()
    for ti in duplicated_testitems
        k = (ti.name, ti.uri)
        if haskey(dedup_dict, k)
            append!(dedup_dict[k].profiles, ti.profiles)
        else
            dedup_dict[k] = TestrunResultTestitem(ti.name, ti.uri, copy(ti.profiles))
        end
    end
    deduplicated_testitems = collect(values(dedup_dict))

    typed_results = TestrunResult(
        TestrunResultDefinitionError[TestrunResultDefinitionError(i.message, URI(i.uri), i.line, i.column) for i in testerrors],
        deduplicated_testitems,
        collected_process_outputs,
    )

    lock(runner.lock) do
        idx = findfirst(r -> r.id == testrun_id, runner.run_history)
        if idx !== nothing
            runner.run_history[idx].result = typed_results
            runner.run_history[idx].status = :completed
            runner.run_history[idx].end_time = time()
        end
    end

    return return_results ? typed_results : testrun_id
end

function kill_test_processes()
    if _g_runner[] !== nothing
        runner = _g_runner[]
        TestItemControllers.shutdown(runner.controller)
        if runner.reactor_task !== nothing
            TestItemControllers.wait_for_shutdown(runner.controller, runner.reactor_task)
            runner.reactor_task = nothing
        end
    end
end

function kill_test_process(id::String)
    if _g_runner[] !== nothing
        TestItemControllers.terminate_test_process(_g_runner[].controller, id)
    end
end

# ── Active project helper ─────────────────────────────────────────────

function _add_active_project!(jw, path)
    proj = Base.active_project()
    proj === nothing && return
    project_folder = dirname(proj)
    # Set fallback regardless — harmless if project is already discovered
    JuliaWorkspaces.set_input_fallback_test_project!(jw.runtime, filepath2uri(project_folder))
    # If project folder is outside the scanned path, add its files
    norm_path = normpath(path) * Base.Filesystem.path_separator
    norm_proj = normpath(project_folder) * Base.Filesystem.path_separator
    if !startswith(norm_proj, norm_path)
        isfile(proj) && JuliaWorkspaces.add_file_from_disc!(jw, proj)
        manifest = joinpath(project_folder, "Manifest.toml")
        isfile(manifest) && JuliaWorkspaces.add_file_from_disc!(jw, manifest)
    end
end

# ── Juliaup channel resolution ────────────────────────────────────────

const _juliaup_config = Ref{Union{Nothing,Dict,Symbol}}(nothing)

function _load_juliaup_config()
    _juliaup_config[] !== nothing && return _juliaup_config[]
    try
        output = read(`juliaup api getconfig1`, String)
        _juliaup_config[] = JSON.parse(output)
    catch
        _juliaup_config[] = :unavailable
    end
    return _juliaup_config[]
end

function _resolve_juliaup_channel(channel_name::String)
    config = _load_juliaup_config()
    if config === :unavailable
        error("Juliaup is not available. Install Juliaup or run without +channel.")
    end
    # Search default channel first, then other channels
    default = config["DefaultChannel"]
    if default["Name"] == channel_name
        return (julia_cmd=default["File"], julia_args=String.(default["Args"]), version=default["Version"])
    end
    for ch in config["OtherChannels"]
        if ch["Name"] == channel_name
            return (julia_cmd=ch["File"], julia_args=String.(ch["Args"]), version=ch["Version"])
        end
    end
    error("Juliaup channel '$channel_name' is not installed. Use `juliaup list` to see available channels.")
end

# ── Background run state ──────────────────────────────────────────────

mutable struct BackgroundRun
    task::Task
    cts::CancellationTokenSource
    result::Union{Nothing,TestrunResult}
    error::Union{Nothing,Exception}
    start_time::Float64
    dashboard_state::Union{Nothing,DashboardState}
    run_id::Union{Nothing,String}
end

const _bg_run = Ref{Union{Nothing,BackgroundRun}}(nothing)
const _last_result = Ref{Union{Nothing,TestrunResult}}(nothing)
const _last_run_id = Ref{Union{Nothing,String}}(nothing)

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
    println("  run [+channel] [path|name]    Run tests (interactive dashboard)")
    println("  run +lts                      Run tests using a Juliaup channel")
    println("  run --tags=t1,t2              Filter by tags")
    println("  run --workers=N               Max parallel workers (default: min(nthreads,8))")
    println("  run --timeout=S               Timeout in seconds (default: 300)")
    println("  run --coverage                Enable coverage")
    println("  run& [same options]           Run tests in background")
    println("  showrun                       Attach dashboard to background run")
    println("  status                        Show background run status")
    println("  cancel [id]                   Cancel background run (or run by id)")
    println("  results [id]                  Show results (last run, or run #id)")
    println("  results --name=<pattern>      Filter results by test item name")
    println("  results --verbose             Show full per-profile details")
    println("  results --output              Show captured output for test items")
    println("  process-log <id>              Show output log for a test process")
    println("  runs [--active]               List all test runs (history)")
    println("  processes                     Show active test processes")
    println("  kill [process-id]             Kill all or a specific test process")
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
    _add_active_project!(jw, path)
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

function _build_run_kwargs(args; return_results=false, juliaup_channel::Union{Nothing,String}=nothing)
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
        :progress_ui => :bar,
    )

    if juliaup_channel !== nothing
        resolved = _resolve_juliaup_channel(juliaup_channel)
        run_kwargs[:julia_cmd] = resolved.julia_cmd
        run_kwargs[:julia_args] = resolved.julia_args
        printstyled("Using Julia $(resolved.version) (+$(juliaup_channel) channel)\n"; color=:cyan)
    end

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

function cmd_run(args; juliaup_channel::Union{Nothing,String}=nothing)
    _check_bg_completion()
    local path, run_kwargs
    try
        path, run_kwargs = _build_run_kwargs(args; juliaup_channel)
    catch e
        printstyled("Error: "; color=:red, bold=true)
        println(e.msg)
        return nothing
    end

    cts = CancellationTokenSource()
    run_kwargs[:token] = get_token(cts)
    run_kwargs[:return_results] = false
    run_kwargs[:print_failed_results] = false
    run_kwargs[:print_summary] = false

    ds = DashboardState()
    run_kwargs[:dashboard_state] = ds
    run_kwargs[:progress_ui] = :none

    # Run tests in a background task
    test_task = @async try
        run_tests(path; run_kwargs...)
    catch e
        e
    end

    # Launch interactive dashboard — blocks until user quits
    try
        launch_dashboard(ds, cts)
    catch e
        if !(e isa InterruptException)
            @error "Dashboard error" exception=(e, catch_backtrace())
        end
    end

    # After dashboard exits: collect results or promote to background
    if !istaskdone(test_task)
        # Run is still going — promote to background run
        bg = BackgroundRun(
            test_task,
            cts,
            nothing,
            nothing,
            time(),
            ds,
            nothing,
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
            elseif raw isa String
                _last_run_id[] = raw
                result = get_run_result(raw)
                if result !== nothing
                    bg.result = result
                    _last_result[] = result
                end
            end
        end
        _bg_run[] = bg
        last_id = get_last_run_id()
        if last_id !== nothing
            _last_run_id[] = last_id
        end
        printstyled("Run detached to background. Use 'showrun' to reattach.\n"; color=:cyan)
    else
        # Run finished — collect results
        raw = try
            fetch(test_task)
        catch e
            e
        end
        if raw isa String
            _last_run_id[] = raw
            result = get_run_result(raw)
            if result !== nothing
                _last_result[] = result
            end
        elseif raw isa Exception
            last_id = get_last_run_id()
            if last_id !== nothing
                _last_run_id[] = last_id
                result = get_run_result(last_id)
                if result !== nothing
                    _last_result[] = result
                end
            end
            if !(raw isa InterruptException)
                @error "Test run error" exception=raw
            end
        end
    end
    nothing
end

function cmd_run_bg(args; juliaup_channel::Union{Nothing,String}=nothing)
    _check_bg_completion()

    if _bg_run[] !== nothing && !istaskdone(_bg_run[].task)
        printstyled("A background run is already active. Use 'cancel' first.\n"; color=:yellow)
        return nothing
    end

    local path, run_kwargs
    try
        path, run_kwargs = _build_run_kwargs(args; return_results=true, juliaup_channel)
    catch e
        printstyled("Error: "; color=:red, bold=true)
        println(e.msg)
        return nothing
    end
    cts = CancellationTokenSource()
    run_kwargs[:token] = get_token(cts)
    run_kwargs[:progress_ui] = :none
    run_kwargs[:print_summary] = false
    run_kwargs[:print_failed_results] = false

    ds = DashboardState()
    run_kwargs[:dashboard_state] = ds

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
        ds,
        nothing,
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
        elseif raw isa String
            # return_results=true returns TestrunResult, but capture run ID too
            _last_run_id[] = raw
            result = get_run_result(raw)
            if result !== nothing
                bg.result = result
                _last_result[] = result
            end
        end
    end

    _bg_run[] = bg
    # Retrieve the run ID (it was just created by run_tests)
    last_id = get_last_run_id()
    if last_id !== nothing
        _last_run_id[] = last_id
    end
    id_str = _last_run_id[] !== nothing ? " #$(_last_run_id[])" : ""
    printstyled("Test run$(id_str) started in background.\n"; color=:green)
    nothing
end

function cmd_showrun()
    _check_bg_completion()
    bg = _bg_run[]
    if bg === nothing
        printstyled("No background test run to show.\n"; color=:yellow)
        return nothing
    end
    if bg.dashboard_state === nothing
        printstyled("Background run has no dashboard state.\n"; color=:yellow)
        return nothing
    end
    cts = istaskdone(bg.task) ? nothing : bg.cts
    try
        launch_dashboard(bg.dashboard_state, cts)
    catch e
        if !(e isa InterruptException)
            @error "Dashboard error" exception=(e, catch_backtrace())
        end
    end
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

        # Show progress details from live snapshot
        run_id = _last_run_id[]
        if run_id !== nothing
            result = get_run_result(run_id)
            if result !== nothing
                n_passed = 0; n_failed = 0; n_errored = 0; n_skipped = 0
                for ti in result.testitems
                    for prof in ti.profiles
                        if prof.status == :passed;  n_passed += 1
                        elseif prof.status == :failed;  n_failed += 1
                        elseif prof.status == :errored; n_errored += 1
                        elseif prof.status == :skipped; n_skipped += 1
                        end
                    end
                end
                done = n_passed + n_failed + n_errored + n_skipped
                # Try to get total from run history
                history = get_run_history()
                rec = nothing
                for r in history
                    if r.id == run_id
                        rec = r
                        break
                    end
                end

                parts = String[]
                n_passed > 0 && push!(parts, "\e[32m$(n_passed) passed\e[0m")
                n_failed > 0 && push!(parts, "\e[31m$(n_failed) failed\e[0m")
                n_errored > 0 && push!(parts, "\e[31m$(n_errored) errored\e[0m")
                n_skipped > 0 && push!(parts, "$(n_skipped) skipped")
                detail = isempty(parts) ? "" : " — $(join(parts, ", "))"
                println("  Progress: $done completed$detail")
            end
        end
    end
    nothing
end

function cmd_cancel(args=String[])
    if !isempty(args)
        # Cancel by run ID
        id = args[1]
        if cancel_run(id)
            printstyled("Cancel requested for run $id.\n"; color=:yellow)
        else
            println("No active run found with id '$id'.")
        end
        return nothing
    end

    bg = _bg_run[]
    if bg === nothing || istaskdone(bg.task)
        println("No active background run to cancel.")
        return nothing
    end
    cancel(bg.cts)
    printstyled("Background run cancel requested.\n"; color=:yellow)
    nothing
end

function cmd_results(args=String[])
    _check_bg_completion()

    positional, kwargs, flags = parse_args(args)

    name_filter = get(kwargs, :name, nothing)
    show_verbose = :verbose in flags
    show_output = :output in flags

    result = nothing
    run_id = nothing
    run_record = nothing

    if !isempty(positional)
        # results <id> — look up a specific run
        run_id = positional[1]
        history = get_run_history()
        idx = findfirst(r -> r.id == run_id || startswith(r.id, run_id), history)
        if idx === nothing
            println("No run found with id '#$run_id'.")
            return nothing
        end
        run_record = history[idx]
        run_id = run_record.id
        result = get_run_result(run_id)
    else
        # results — show last run
        result = _last_result[]
        run_id = _last_run_id[]
        if result === nothing && run_id !== nothing
            result = get_run_result(run_id)
        end
        if run_id !== nothing
            history = get_run_history()
            idx = findfirst(r -> r.id == run_id, history)
            if idx !== nothing
                run_record = history[idx]
            end
        end
    end

    if result === nothing
        println("No test results available.")
        return nothing
    end

    # Apply name filter
    testitems = if name_filter !== nothing
        _filter_testitems(result.testitems, name_filter)
    else
        result.testitems
    end

    if name_filter !== nothing && isempty(testitems)
        println("No test items matching '$(name_filter)'.")
        return nothing
    end

    # --verbose: show full per-profile details for each item
    if show_verbose
        for ti in testitems
            _print_testitem_details(ti)
        end
        println()
        return nothing
    end

    # --output: show only captured output for each item
    if show_output
        for ti in testitems
            _print_testitem_output(ti)
        end
        return nothing
    end

    # Default summary view
    n_passed = 0; n_failed = 0; n_errored = 0; n_skipped = 0
    for ti in testitems
        for prof in ti.profiles
            if prof.status == :passed;  n_passed += 1
            elseif prof.status == :failed;  n_failed += 1
            elseif prof.status == :errored; n_errored += 1
            elseif prof.status == :skipped; n_skipped += 1
            end
        end
    end
    total = n_passed + n_failed + n_errored + n_skipped

    # Header
    println()
    id_str = run_id !== nothing ? "Run #$run_id: " : ""
    is_active = run_record !== nothing && run_record.status == :running
    duration_str = ""
    if run_record !== nothing && run_record.end_time !== nothing
        dur = round(run_record.end_time - run_record.start_time; digits=1)
        duration_str = " ($dur s)"
    elseif is_active
        dur = round(time() - run_record.start_time; digits=1)
        duration_str = " ($dur s, in progress)"
    end
    filter_str = name_filter !== nothing ? " (filtered: '$(name_filter)')" : ""

    printstyled("$(id_str)$(total) test(s)$duration_str$filter_str"; bold=true)
    print(" — ")
    parts = String[]
    n_passed > 0 && push!(parts, "\e[32m$(n_passed) passed\e[0m")
    n_failed > 0 && push!(parts, "\e[31m$(n_failed) failed\e[0m")
    n_errored > 0 && push!(parts, "\e[31m$(n_errored) errored\e[0m")
    n_skipped > 0 && push!(parts, "$(n_skipped) skipped")
    println(join(parts, ", "))

    if is_active
        printstyled("  (run still in progress, showing results so far)\n"; color=:yellow)
    end

    if name_filter === nothing && !isempty(result.definition_errors)
        printstyled("\nDefinition errors:\n"; color=:red, bold=true)
        for de in result.definition_errors
            println("  $(uri2filepath(de.uri)):$(de.line) — $(de.message)")
        end
    end

    # Show failed/errored details
    for ti in testitems
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
                        println("    ", replace(msg.message, "\n" => "\n    "))
                    end
                end
            end
        end
    end

    # When all pass, show top 5 slowest tests
    if n_failed == 0 && n_errored == 0 && total > 0
        timed = Tuple{String,Float64}[]
        for ti in testitems
            for prof in ti.profiles
                if prof.duration !== missing
                    push!(timed, (ti.name, prof.duration))
                end
            end
        end
        if !isempty(timed)
            sort!(timed; by=last, rev=true)
            n_show = min(5, length(timed))
            println()
            printstyled("  Slowest tests:\n"; color=:light_black)
            for i in 1:n_show
                name, dur = timed[i]
                printstyled("    $(lpad(string(round(dur; digits=1)), 8))ms"; color=:light_black)
                println("  $name")
            end
        end
    end
    nothing
end

function cmd_kill(args=String[])
    if !isempty(args)
        id = args[1]
        procs = get_active_processes()
        idx = findfirst(p -> p.id == id || startswith(p.id, id), procs)
        if idx === nothing
            println("No active process found matching '$id'.")
            return nothing
        end
        proc = procs[idx]
        kill_test_process(proc.id)
        printstyled("Process $(proc.id) terminated.\n"; color=:yellow)
    else
        kill_test_processes()
        printstyled("All test processes terminated.\n"; color=:yellow)
    end
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
# ── Display helpers ──────────────────────────────────────────────────────

function _filter_testitems(testitems, name_pattern::String)
    pattern_lower = lowercase(name_pattern)
    filter(ti -> contains(lowercase(ti.name), pattern_lower), testitems)
end

function _print_testitem_details(ti)
    printstyled("\n$(ti.name)"; bold=true)
    println("  $(uri2filepath(ti.uri))")

    for prof in ti.profiles
        println()
        status_color = if prof.status == :passed
            :green
        elseif prof.status in (:failed, :errored)
            :red
        elseif prof.status == :skipped
            :light_black
        else
            :default
        end
        printstyled("  [$(prof.profile_name)] $(prof.status)"; color=status_color, bold=true)
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

        if prof.output !== missing && !isempty(prof.output)
            printstyled("    Output:\n"; color=:cyan)
            for line in split(prof.output, '\n')
                println("      ", line)
            end
        end
    end
end

function _print_testitem_output(ti)
    printstyled("Output for $(ti.name):\n"; bold=true)
    has_output = false
    for prof in ti.profiles
        if prof.output !== missing && !isempty(prof.output)
            if length(ti.profiles) > 1
                printstyled("  [$(prof.profile_name)]\n"; color=:cyan)
            end
            println(prof.output)
            has_output = true
        end
    end
    if !has_output
        println("  No output recorded for this test item.")
    end
end

function cmd_process_log(args)
    result = _last_result[]
    if result === nothing
        println("No test results available.")
        return nothing
    end
    if isempty(args)
        println("Usage: process-log <process id>")
        return nothing
    end

    id = args[1]
    # Try exact match, then prefix match
    output = get(result.process_outputs, id, nothing)
    if output === nothing
        matches = filter(k -> startswith(k, id), collect(keys(result.process_outputs)))
        if length(matches) == 1
            output = result.process_outputs[matches[1]]
            id = matches[1]
        elseif length(matches) > 1
            printstyled("Multiple processes match '$id':\n"; color=:yellow)
            for m in matches
                println("  $m")
            end
            return nothing
        end
    end

    if output === nothing
        println("No process output found for '$id'.")
        return nothing
    end

    printstyled("Process output for $id:\n"; bold=true)
    println(output)
    nothing
end



function cmd_runs(args)
    _, kwargs, flags = parse_args(args)
    history = get_run_history()

    if :active in flags
        history = filter(r -> r.status == :running, history)
    end

    if isempty(history)
        if :active in flags
            println("No active test runs.")
        else
            println("No test runs in history.")
        end
        return nothing
    end

    printstyled("Test runs:\n\n"; bold=true)
    printstyled("  $(rpad("#", 6))$(rpad("Started", 12))$(rpad("Duration", 12))$(rpad("Status", 12))$(rpad("Tests", 10))Path\n"; bold=true)
    printstyled("  $(repeat("─", 76))\n"; color=:light_black)

    for r in history
        started = Dates.format(Dates.unix2datetime(r.start_time), "HH:MM:SS")
        duration = if r.end_time !== nothing
            elapsed = r.end_time - r.start_time
            "$(round(elapsed; digits=1))s"
        elseif r.status == :running
            elapsed = time() - r.start_time
            "$(round(elapsed; digits=1))s…"
        else
            "-"
        end
        status_color = if r.status == :running
            :yellow
        elseif r.status == :completed
            :green
        elseif r.status in (:cancelled, :errored)
            :red
        else
            :default
        end

        # Compute test count summary
        tests_str = "-"
        res = r.result
        if res === nothing && r.status == :running
            res = get_run_result(r.id)
        end
        if res !== nothing
            n = length(res.testitems)
            n_done = sum(length(ti.profiles) for ti in res.testitems; init=0)
            tests_str = "$n_done"
        end

        print("  $(rpad(r.id, 6))$(rpad(started, 12))$(rpad(duration, 12))")
        printstyled("$(rpad(r.status, 12))"; color=status_color)
        print("$(rpad(tests_str, 10))")
        println(r.path)
    end
    println()
    println("$(length(history)) run(s). Use 'results <id>' to inspect a run.")
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
        # Extract +channel modifier from args
        juliaup_channel = nothing
        remaining_args = SubString{String}[]
        for a in args
            if startswith(a, "+")
                juliaup_channel = String(a[2:end])
            else
                push!(remaining_args, a)
            end
        end
        if bg_run
            return cmd_run_bg(remaining_args; juliaup_channel)
        else
            return cmd_run(remaining_args; juliaup_channel)
        end
    elseif cmd == "showrun"
        return cmd_showrun()
    elseif cmd == "status" || cmd == "st"
        return cmd_status()
    elseif cmd == "cancel"
        return cmd_cancel(args)
    elseif cmd == "results" || cmd == "res"
        return cmd_results(args)
    elseif cmd == "process-log" || cmd == "plog"
        return cmd_process_log(args)
    elseif cmd == "runs"
        return cmd_runs(args)
    elseif cmd == "processes" || cmd == "procs" || cmd == "ps"
        return cmd_processes()
    elseif cmd == "kill"
        return cmd_kill(args)
    else
        printstyled("Unknown command: $cmd\n"; color=:red)
        println("Type 'help' for available commands.")
        return nothing
    end
end

# ── Precompilation workload ───────────────────────────────────────────

@setup_workload begin
    precompiledata_path = joinpath(@__DIR__, "..", "precompiledata")

    @compile_workload begin
        run_tests(
            precompiledata_path;
            return_results=true,
            print_summary=false,
            print_failed_results=false,
            progress_ui=:log,
            max_workers=1,
            timeout=60,
            fail_on_detection_error=false,
        )
        kill_test_processes()
    end
end

# ── REPL mode registration ───────────────────────────────────────────

function _register_repl_mode()
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

function __init__()
    # Precompilation leaves a stale runner with dead reactor/shutdown controller; reset it
    _g_runner[] = nothing

    global_logger(ModuleFilterLogger(global_logger()))

    if isdefined(Base, :active_repl)
        _register_repl_mode()
    else
        atreplinit() do repl
            @async _register_repl_mode()
        end
    end
end

end # module TestItemREPL
