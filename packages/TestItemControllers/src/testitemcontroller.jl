mutable struct TestItemController{ERR_HANDLER<:Union{Function,Nothing},CB<:ControllerCallbacks}
    err_handler::ERR_HANDLER
    callbacks::CB

    reactor_channel::Channel{ReactorMessage}

    test_processes::Dict{String,TestProcessState}       # flat lookup by process ID
    process_pool::Dict{TestEnvironment,Vector{String}}   # pool of process IDs by env
    test_runs::Dict{String,TestRunState}

    testprocess_precompile_not_required::Set{
        @NamedTuple{
            julia_cmd::String,
            julia_args::Vector{String},
            env::Dict{String,Union{String,Nothing}},
            coverage::Bool
        }
    }

    precompiled_envs::Set{TestEnvironment}

    error_handler_file::Union{Nothing,String}
    crash_reporting_pipename::Union{Nothing,String}

    log_level::Symbol
    controller_fsm::FSM{ControllerPhase}

    function TestItemController(
        callbacks::CB,
        err_handler::ERR_HANDLER=nothing;
        error_handler_file=nothing,
        crash_reporting_pipename=nothing,
        log_level::Symbol=:Info) where {ERR_HANDLER<:Union{Function,Nothing},CB<:ControllerCallbacks}

        return new{ERR_HANDLER,CB}(
            err_handler,
            callbacks,
            Channel{ReactorMessage}(Inf),
            Dict{String,TestProcessState}(),
            Dict{TestEnvironment,Vector{String}}(),
            Dict{String,TestRunState}(),
            Set{@NamedTuple{julia_cmd::String,julia_args::Vector{String},env::Dict{String,Union{String,Nothing}},coverage::Bool}}(),
            Set{TestEnvironment}(),
            error_handler_file,
            crash_reporting_pipename,
            log_level,
            controller_fsm("controller")
        )
    end
end

function shutdown(controller::TestItemController)
    @info "Queueing controller shutdown"
    put!(controller.reactor_channel, ShutdownMsg())
end

function terminate_test_process(controller::TestItemController, id::String)
    @debug "Terminating test process" id
    put!(controller.reactor_channel, TerminateTestProcessMsg(id))
    return nothing
end

# ═══════════════════════════════════════════════════════════════════════════════
# Reactor event loop
# ═══════════════════════════════════════════════════════════════════════════════

function Base.run(controller::TestItemController)
    while true
        msg = take!(controller.reactor_channel)
        @debug "Reactor msg" msg_type=typeof(msg).name.name

        should_stop = handle!(controller, msg)
        should_stop === true && break
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Controller-level handlers
# ═══════════════════════════════════════════════════════════════════════════════

function handle!(c::TestItemController, ::ShutdownMsg)
    @info "Shutting down controller, terminating $(length(c.test_processes)) test process(es)"
    transition!(c.controller_fsm, ControllerShuttingDown; reason="shutdown requested")

    # Cancel all active test runs and signal completion
    for (trid, tr) in c.test_runs
        if state(tr.fsm) ∉ (TestRunCancelled, TestRunCompleted)
            CancellationTokens.cancel(tr.cancellation_source)
            for (id, _) in tr.remaining_items
                c.callbacks.on_testitem_skipped(trid, id)
            end
            transition!(tr.fsm, TestRunCancelled; reason="shutdown")
            try put!(tr.completion_channel, missing) catch end
        end
    end

    # Shutdown all processes
    for (pid, ps) in c.test_processes
        if state(ps.fsm) != ProcessDead
            _shutdown_test_process!(c, ps)
        end
    end

    if isempty(c.test_processes)
        transition!(c.controller_fsm, ControllerStopped; reason="no processes to drain")
        return true  # break reactor loop
    end
    return false
end

function handle!(c::TestItemController, msg::TestProcessStatusChangedMsg)
    @debug "Forwarding test process status change" id=msg.testprocess_id status=msg.status
    if c.callbacks.on_process_status_changed !== nothing
        c.callbacks.on_process_status_changed(msg.testprocess_id, msg.status)
    end
    return false
end

function handle!(c::TestItemController, msg::TestProcessOutputMsg)
    @debug "Forwarding test process output" id=msg.testprocess_id ncodeunits=ncodeunits(msg.output)
    if c.callbacks.on_process_output !== nothing
        c.callbacks.on_process_output(msg.testprocess_id, msg.output)
    end
    return false
end

function handle!(c::TestItemController, msg::TerminateTestProcessMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        @debug "Ignoring terminate request for unknown process" testprocess_id=msg.testprocess_id
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) == ProcessDead
        @debug "Ignoring terminate request for already-dead process" testprocess_id=msg.testprocess_id
        return false
    end

    @info "Terminating test process '$(msg.testprocess_id)' via request"
    _kill_julia_process!(ps)

    if ps.testrun_id !== nothing
        put!(c.reactor_channel, TestProcessTerminatedInRunMsg(ps.testrun_id, msg.testprocess_id, true))
    end
    put!(c.reactor_channel, TestProcessTerminatedMsg(msg.testprocess_id))

    return false
end

function handle!(c::TestItemController, msg::TestProcessTerminatedMsg)
    @info "Test process '$(msg.testprocess_id)' terminated"

    if haskey(c.test_processes, msg.testprocess_id)
        ps = c.test_processes[msg.testprocess_id]
        if state(ps.fsm) != ProcessDead
            transition!(ps.fsm, ProcessDead; reason="terminated")
        end

        # Remove from pool
        pool_ids = get(c.process_pool, ps.env, String[])
        idx = findfirst(isequal(msg.testprocess_id), pool_ids)
        if idx !== nothing
            deleteat!(pool_ids, idx)
        end

        delete!(c.test_processes, msg.testprocess_id)

        if c.callbacks.on_process_terminated !== nothing
            c.callbacks.on_process_terminated(msg.testprocess_id)
        end
    end

    # If shutting down and all processes gone, transition to stopped
    if state(c.controller_fsm) == ControllerShuttingDown && isempty(c.test_processes)
        transition!(c.controller_fsm, ControllerStopped; reason="all processes terminated")
        return true  # break reactor loop
    end
    return false
end

function handle!(c::TestItemController, msg::ReturnToPoolMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        @debug "Ignoring return_to_pool for unknown process" id=msg.testprocess_id
        return false
    end
    ps = c.test_processes[msg.testprocess_id]
    if state(ps.fsm) == ProcessIdle
        @debug "Ignoring duplicate return_to_pool" id=msg.testprocess_id
        return false
    end

    @info "Test process '$(msg.testprocess_id)' finished its test run, returning to pool"
    _clear_testrun_on_process!(ps)

    if state(ps.fsm) == ProcessStarting
        # Process is still starting up; testrun cleared, it will transition to Idle
        # when TestProcessLaunchedMsg arrives and sees testrun_id is null
        @debug "Cleared testrun metadata while process is still starting" id=msg.testprocess_id
    elseif state(ps.fsm) != ProcessDead
        transition!(ps.fsm, ProcessIdle; reason="returned to pool")
    end

    if c.callbacks.on_process_status_changed !== nothing
        c.callbacks.on_process_status_changed(msg.testprocess_id, "Idle")
    end

    # If shutting down, immediately terminate the returned process
    if state(c.controller_fsm) == ControllerShuttingDown
        _shutdown_test_process!(c, ps)
    end
    return false
end

function handle!(c::TestItemController, msg::GetProcsForTestRunMsg)
    # Guard: reject new test runs during shutdown
    if state(c.controller_fsm) != ControllerRunning
        @warn "Rejecting test run request during shutdown" testrun_id=msg.testrun_id
        if haskey(c.test_runs, msg.testrun_id)
            tr = c.test_runs[msg.testrun_id]
            CancellationTokens.cancel(tr.cancellation_source)
        end
        return false
    end

    @debug "Acquiring test processes for test run" testrun_id=msg.testrun_id env_count=length(msg.proc_count_by_env)

    our_procs = Dict{TestEnvironment,Vector{String}}()

    for (k, v) in pairs(msg.proc_count_by_env)
        our_procs[k] = String[]

        pool_ids = get!(c.process_pool, k) do
            String[]
        end

        # Find idle processes in pool
        existing_idle_ids = filter(pool_ids) do pid
            haskey(c.test_processes, pid) && state(c.test_processes[pid].fsm) == ProcessIdle
        end

        @info "Test environment\n\nProject Uri: $(k.project_uri)\nPackage Uri: $(k.package_uri)\nPackage Name: $(k.package_name)\nJulia command: $(k.juliaCmd)\nJulia Num Threads: $(k.juliaNumThreads)\nMode: $(k.mode)\nEnv: $(k.env)\n\nWe need $v procs, there are $(length(pool_ids)) processes, of which $(length(existing_idle_ids)) are idle."

        # Grab existing idle procs
        for pid in Iterators.take(existing_idle_ids, v)
            ps = c.test_processes[pid]
            @info "Reusing idle test process '$(pid)' for package '$(k.package_name)'"

            testrun_token = haskey(c.test_runs, msg.testrun_id) ?
                CancellationTokens.get_token(c.test_runs[msg.testrun_id].cancellation_source) : nothing

            _setup_testrun_on_process!(ps, msg.testrun_id, msg.test_setups, msg.coverage_root_uris, msg.log_level, testrun_token)

            transition!(ps.fsm, ProcessReviseOrStart; reason="reused for testrun")

            push!(our_procs[k], pid)

            env_hash = get(msg.env_content_hash_by_env, k, nothing)

            if ps.endpoint === nothing || env_hash != ps.test_env_content_hash
                # No endpoint or hash changed — need full restart
                @debug "Restarting process (no endpoint or env hash changed)" testprocess_id=pid
                ps.test_env_content_hash = env_hash
                transition!(ps.fsm, ProcessStarting; reason="restart needed")
                _launch_julia_process!(c, ps)
            else
                # Try revise
                transition!(ps.fsm, ProcessRevising; reason="revising")
                put!(c.reactor_channel, TestProcessStatusChangedMsg(pid, "Revising"))
                _start_revise!(c, ps, env_hash)
            end
        end

        # Pre-1.10 Julia version precompile hack
        if !(
            (
                julia_cmd=k.juliaCmd,
                julia_args=k.juliaArgs,
                env=k.env,
                coverage=k.mode == "Coverage"
            ) in c.testprocess_precompile_not_required)

            @debug "Checking whether test environment precompilation is needed"
            coverage_arg = k.mode == "Coverage" ? "--code-coverage=user" : "--code-coverage=none"

            jlEnv = copy(ENV)

            # During precompilation, Julia restricts JULIA_LOAD_PATH to dependency paths only
            # (no "@" entry), which prevents child processes from using their own active project.
            if ccall(:jl_generating_output, Cint, ()) == 1
                delete!(jlEnv, "JULIA_LOAD_PATH")
            end

            for (ek, ev) in pairs(k.env)
                if ev !== nothing
                    jlEnv[ek] = ev
                elseif haskey(jlEnv, ek)
                    delete!(jlEnv, ek)
                end
            end

            julia_version_as_string = read(Cmd(`$(k.juliaCmd) $(k.juliaArgs) --version`, detach=false, env=jlEnv), String)
            julia_version_as_string = julia_version_as_string[length("julia version")+2:end]
            julia_version = VersionNumber(julia_version_as_string)

            if julia_version <= v"1.10.0"
                testserver_precompile_script = joinpath(@__DIR__, "../testprocess/app/testserver_precompile.jl")

                precompile_success = success(Cmd(`$(k.juliaCmd) $(k.juliaArgs) --check-bounds=yes --startup-file=no --history-file=no --depwarn=no $coverage_arg $testserver_precompile_script`, detach=false, env=jlEnv))

                @debug "Precompile of test server" precompile_success

                push!(c.testprocess_precompile_not_required, (
                    julia_cmd=k.juliaCmd,
                    julia_args=k.juliaArgs,
                    env=k.env,
                    coverage=k.mode == "Coverage"
                ))
            end
        end

        precompile_required = !(k in c.precompiled_envs)
        identified_precompile_proc = false

        while length(our_procs[k]) < v
            @info "Launching new test process for package '$(k.package_name)'"

            this_is_the_precompile_proc = precompile_required && !identified_precompile_proc
            identified_precompile_proc = true

            env_hash = get(msg.env_content_hash_by_env, k, nothing)
            testprocess_id = string(UUIDs.uuid4())

            # Create TestProcessState and register it
            ps = TestProcessState(testprocess_id, k;
                is_precompile_process=this_is_the_precompile_proc,
                test_env_content_hash=env_hash)
            c.test_processes[testprocess_id] = ps

            push!(pool_ids, testprocess_id)

            testrun_token = haskey(c.test_runs, msg.testrun_id) ?
                CancellationTokens.get_token(c.test_runs[msg.testrun_id].cancellation_source) : nothing

            _setup_testrun_on_process!(ps, msg.testrun_id, msg.test_setups, msg.coverage_root_uris, msg.log_level, testrun_token)

            transition!(ps.fsm, ProcessStarting; reason="new process")
            _launch_julia_process!(c, ps)

            push!(our_procs[k], testprocess_id)

            if c.callbacks.on_process_created !== nothing
                c.callbacks.on_process_created(testprocess_id, k.package_name, k.package_uri, k.project_uri, k.mode == "Coverage", k.env)
            end
        end
    end

    @info "Sending $(sum(length, values(our_procs), init=0)) test process(es) to test run '$(msg.testrun_id)'"
    put!(
        c.reactor_channel,
        ProcsAcquiredMsg(msg.testrun_id, our_procs)
    )
    return false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Test-run handlers
# ═══════════════════════════════════════════════════════════════════════════════

function handle!(c::TestItemController, msg::ProcsAcquiredMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        @debug "Ignoring ProcsAcquiredMsg for unknown test run" testrun_id=msg.testrun_id
        return false
    end
    tr = c.test_runs[msg.testrun_id]

    if state(tr.fsm) == TestRunCancelled
        # Cancellation arrived before process acquisition completed.
        @info "Returning $(sum(length, values(msg.procs), init=0)) process(es) to pool after deferred cancellation"
        for pid in Iterators.flatten(values(msg.procs))
            if haskey(c.test_processes, pid)
                ps = c.test_processes[pid]
                put!(c.reactor_channel, ReturnToPoolMsg(pid, ps.env))
            end
        end
        return false
    end

    transition!(tr.fsm, TestRunProcsAcquired; reason="procs acquired")
    tr.procs = msg.procs

    @info "Acquired $(sum(length, values(msg.procs), init=0)) test process(es) for test run"

    # Distribute test items over test processes
    for (env, proc_ids) in pairs(msg.procs)
        assigned_for_env = 0
        n_procs_for_env = length(proc_ids)
        for pid in proc_ids
            tr.stolen_ids_by_proc[pid] = String[]

            if !haskey(tr.testitem_ids_by_proc, pid)
                # Divvy up items: take a chunk for this process
                all_env_items = _get_unchunked_items(tr, env)
                procs_remaining = n_procs_for_env - assigned_for_env
                chunk_size = max(1, div(length(all_env_items), procs_remaining, RoundUp))
                chunk = splice!(all_env_items, 1:min(chunk_size, length(all_env_items)))
                tr.testitem_ids_by_proc[pid] = chunk
                assigned_for_env += 1
                @info "Assigned $(length(chunk)) test item(s) to process '$(pid)'"
            end
        end
    end

    # Dispatch buffered ready notifications
    for pid in tr.processes_ready_before_acquired
        if haskey(tr.testitem_ids_by_proc, pid) && haskey(c.test_processes, pid)
            ps = c.test_processes[pid]
            items_for_proc = [tr.remaining_items[id] for id in tr.testitem_ids_by_proc[pid] if haskey(tr.remaining_items, id)]
            @debug "Dispatching buffered test items to ready process" testrun_id=msg.testrun_id process_id=pid assigned=length(items_for_proc)
            if state(ps.fsm) == ProcessReadyToRun
                transition!(ps.fsm, ProcessRunning; reason="dispatching buffered items")
            end
            _send_run_testitems!(c, ps, items_for_proc)
            push!(tr.items_dispatched_to_procs, pid)
        end
    end

    return false
end

function handle!(c::TestItemController, msg::TestRunCancelledMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]

    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    @info "Test run cancelled, skipping $(length(tr.remaining_items)) remaining test item(s)"

    if state(tr.fsm) == TestRunWaitingForProcs
        transition!(tr.fsm, TestRunCancelled; reason="cancelled before procs acquired")
    elseif state(tr.fsm) in (TestRunProcsAcquired, TestRunRunning)
        transition!(tr.fsm, TestRunCancelled; reason="cancelled")
    else
        transition!(tr.fsm, TestRunCancelled; reason="cancelled from $(state(tr.fsm))")
    end

    CancellationTokens.cancel(tr.cancellation_source)

    # Report all remaining test items as skipped
    for (id, _) in tr.remaining_items
        c.callbacks.on_testitem_skipped(msg.testrun_id, id)
    end

    # Kill Julia processes and return all processes to pool
    if tr.procs !== nothing
        for pid in Iterators.flatten(values(tr.procs))
            if haskey(c.test_processes, pid)
                ps = c.test_processes[pid]
                _kill_julia_process!(ps)
                put!(c.reactor_channel, ReturnToPoolMsg(pid, ps.env))
            end
        end
    end

    # Signal completion
    try put!(tr.completion_channel, missing) catch end
    return false
end

function handle!(c::TestItemController, msg::ReadyToRunTestItemsMsg)
    if !haskey(c.test_runs, msg.testrun_id) || !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    ps = c.test_processes[msg.testprocess_id]

    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    if state(tr.fsm) == TestRunProcsAcquired || state(tr.fsm) == TestRunRunning
        @info "Test process '$(msg.testprocess_id)' is ready, dispatching test items"
        items_for_proc = [tr.remaining_items[id] for id in get(tr.testitem_ids_by_proc, msg.testprocess_id, String[]) if haskey(tr.remaining_items, id)]
        if state(ps.fsm) == ProcessReadyToRun
            transition!(ps.fsm, ProcessRunning; reason="dispatching items")
        end
        _send_run_testitems!(c, ps, items_for_proc)
        push!(tr.items_dispatched_to_procs, msg.testprocess_id)
    elseif state(tr.fsm) == TestRunWaitingForProcs
        @info "Test process '$(msg.testprocess_id)' is ready, waiting for process acquisition to finish"
        push!(tr.processes_ready_before_acquired, msg.testprocess_id)
    end
    return false
end

function handle!(c::TestItemController, msg::PrecompileDoneMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]

    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    @info "Test process '$(msg.testprocess_id)' completed precompilation for package '$(msg.env.package_name)'"
    push!(c.precompiled_envs, msg.env)

    # Notify peer processes that are waiting for precompile
    if tr.procs !== nothing && haskey(tr.procs, msg.env)
        for pid in tr.procs[msg.env]
            if pid != msg.testprocess_id && haskey(c.test_processes, pid)
                ps = c.test_processes[pid]
                ps.precompile_done = true
                if state(ps.fsm) == ProcessWaitingForPrecompile
                    @debug "Peer process completed precompile, activating" testprocess_id=pid
                    transition!(ps.fsm, ProcessActivatingEnv; reason="precompile_by_other_proc_done")
                    _activate_env!(c, ps)
                end
            end
        end
    end
    return false
end

function handle!(c::TestItemController, msg::AttachDebuggerMsg)
    c.callbacks.on_attach_debugger(msg.testrun_id, msg.debug_pipe_name)
    return false
end

function handle!(c::TestItemController, msg::TestItemStartedMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    if state(tr.fsm) == TestRunProcsAcquired
        transition!(tr.fsm, TestRunRunning; reason="first test item started")
    end

    c.callbacks.on_testitem_started(msg.testrun_id, msg.testitem_id)

    # Start timeout if item has one
    if haskey(c.test_processes, msg.testprocess_id) && haskey(tr.remaining_items, msg.testitem_id)
        ps = c.test_processes[msg.testprocess_id]
        item = tr.remaining_items[msg.testitem_id]
        ps.current_testitem_id = msg.testitem_id
        ps.current_testitem_started_at = time()

        if item.timeout !== nothing
            ps.timeout_cs = CancellationTokens.CancellationTokenSource(item.timeout)
            ps.timeout_reg = CancellationTokens.register(CancellationTokens.get_token(ps.timeout_cs)) do
                try
                    put!(c.reactor_channel, TestItemTimeoutMsg(msg.testrun_id, msg.testprocess_id, msg.testitem_id))
                catch
                end
            end
        end
    end
    return false
end

function _cancel_timeout!(ps::TestProcessState)
    if ps.timeout_cs !== nothing
        CancellationTokens.cancel(ps.timeout_cs)
        ps.timeout_cs = nothing
    end
    if ps.timeout_reg !== nothing
        try close(ps.timeout_reg) catch end
        ps.timeout_reg = nothing
    end
    ps.current_testitem_id = nothing
    ps.current_testitem_started_at = nothing
end

function handle!(c::TestItemController, msg::TestItemPassedMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    # Cancel timeout
    if haskey(c.test_processes, msg.testprocess_id)
        _cancel_timeout!(c.test_processes[msg.testprocess_id])
    end

    # Handle stolen tracking
    stolen_idx = findfirst(isequal(msg.testitem_id), get(tr.stolen_ids_by_proc, msg.testprocess_id, String[]))
    if stolen_idx !== nothing
        deleteat!(tr.stolen_ids_by_proc[msg.testprocess_id], stolen_idx)
    end

    if haskey(tr.remaining_items, msg.testitem_id)
        delete!(tr.remaining_items, msg.testitem_id)
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)

        c.callbacks.on_testitem_passed(msg.testrun_id, msg.testitem_id, msg.duration)

        if msg.coverage !== nothing && msg.coverage !== missing
            append!(tr.coverage, map(i -> CoverageTools.FileCoverage(uri2filepath(i.uri), "", i.coverage), msg.coverage))
        end
    else
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)
    end

    _check_stealing!(c, tr, msg.testprocess_id)
    _check_testrun_complete!(c, tr)
    return false
end

function handle!(c::TestItemController, msg::TestItemFailedMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    if haskey(c.test_processes, msg.testprocess_id)
        _cancel_timeout!(c.test_processes[msg.testprocess_id])
    end

    stolen_idx = findfirst(isequal(msg.testitem_id), get(tr.stolen_ids_by_proc, msg.testprocess_id, String[]))
    if stolen_idx !== nothing
        deleteat!(tr.stolen_ids_by_proc[msg.testprocess_id], stolen_idx)
    end

    if haskey(tr.remaining_items, msg.testitem_id)
        delete!(tr.remaining_items, msg.testitem_id)
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)

        c.callbacks.on_testitem_failed(
            msg.testrun_id,
            msg.testitem_id,
            TestItemControllerProtocol.TestMessage[
                TestItemControllerProtocol.TestMessage(
                    message = i.message,
                    expectedOutput = i.expectedOutput,
                    actualOutput = i.actualOutput,
                    uri = i.location.uri,
                    line = i.location.position.line,
                    column = i.location.position.character
                ) for i in msg.messages
            ],
            msg.duration
        )
    else
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)
    end

    _check_stealing!(c, tr, msg.testprocess_id)
    _check_testrun_complete!(c, tr)
    return false
end

function handle!(c::TestItemController, msg::TestItemErroredMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    if haskey(c.test_processes, msg.testprocess_id)
        _cancel_timeout!(c.test_processes[msg.testprocess_id])
    end

    stolen_idx = findfirst(isequal(msg.testitem_id), get(tr.stolen_ids_by_proc, msg.testprocess_id, String[]))
    if stolen_idx !== nothing
        deleteat!(tr.stolen_ids_by_proc[msg.testprocess_id], stolen_idx)
    end

    if haskey(tr.remaining_items, msg.testitem_id)
        delete!(tr.remaining_items, msg.testitem_id)
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)

        c.callbacks.on_testitem_errored(
            msg.testrun_id,
            msg.testitem_id,
            TestItemControllerProtocol.TestMessage[
                TestItemControllerProtocol.TestMessage(
                    message = i.message,
                    expectedOutput = missing,
                    actualOutput = missing,
                    uri = i.location.uri,
                    line = i.location.position.line,
                    column = i.location.position.character
                ) for i in msg.messages
            ],
            msg.duration
        )
    else
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)
    end

    _check_stealing!(c, tr, msg.testprocess_id)
    _check_testrun_complete!(c, tr)
    return false
end

function handle!(c::TestItemController, msg::TestItemSkippedStolenMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    stolen_idx = findfirst(isequal(msg.testitem_id), get(tr.stolen_ids_by_proc, msg.testprocess_id, String[]))
    if stolen_idx !== nothing
        deleteat!(tr.stolen_ids_by_proc[msg.testprocess_id], stolen_idx)
    end

    # Cancel timeout if this item is the active one
    if haskey(c.test_processes, msg.testprocess_id)
        ps = c.test_processes[msg.testprocess_id]
        if ps.current_testitem_id == msg.testitem_id
            _cancel_timeout!(ps)
        end
    end

    _check_stealing!(c, tr, msg.testprocess_id)
    _check_testrun_complete!(c, tr)
    return false
end

function handle!(c::TestItemController, msg::AppendOutputMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    c.callbacks.on_append_output(msg.testrun_id, msg.testitem_id, msg.output)
    return false
end

function handle!(c::TestItemController, msg::TestProcessTerminatedInRunMsg)
    if !haskey(c.test_runs, msg.testrun_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return false
    end

    terminated_proc_id = msg.testprocess_id

    # Collect remaining items from the dead process's queue.
    items_to_redistribute = String[]
    if haskey(tr.testitem_ids_by_proc, terminated_proc_id)
        for testitem_id in tr.testitem_ids_by_proc[terminated_proc_id]
            if haskey(tr.remaining_items, testitem_id)
                push!(items_to_redistribute, testitem_id)
            end
        end
        empty!(tr.testitem_ids_by_proc[terminated_proc_id])
    end
    if haskey(tr.stolen_ids_by_proc, terminated_proc_id)
        empty!(tr.stolen_ids_by_proc[terminated_proc_id])
    end

    # Find the environment of the terminated process
    terminated_env = nothing
    if tr.procs !== nothing
        for (env, pids) in pairs(tr.procs)
            idx = findfirst(isequal(terminated_proc_id), pids)
            if idx !== nothing
                terminated_env = env
                deleteat!(pids, idx)
                break
            end
        end
    end

    # Note: TestProcessTerminatedMsg for pool cleanup is posted by testprocess.jl's
    # event loop (alongside this TestProcessTerminatedInRunMsg), so we don't post it here.

    if isempty(items_to_redistribute)
        @info "Test process '$(terminated_proc_id)' terminated during test run, no remaining items to redistribute"
        _check_testrun_complete!(c, tr)
        return false
    end

    # If explicitly terminated by user, error remaining items instead of redistributing
    if msg.skip_remaining
        @info "Test process '$(terminated_proc_id)' terminated by user, erroring $(length(items_to_redistribute)) remaining item(s)"
        for testitem_id in items_to_redistribute
            if haskey(tr.remaining_items, testitem_id)
                item = tr.remaining_items[testitem_id]
                delete!(tr.remaining_items, testitem_id)
                c.callbacks.on_testitem_errored(
                    msg.testrun_id,
                    testitem_id,
                    TestItemControllerProtocol.TestMessage[
                        TestItemControllerProtocol.TestMessage(
                            message = "Test process terminated by user for test item '$(item.label)'",
                            expectedOutput = missing,
                            actualOutput = missing,
                            uri = item.uri,
                            line = item.line,
                            column = item.column
                        )
                    ],
                    missing
                )
            end
        end
        _check_testrun_complete!(c, tr)
        return false
    end

    # If shutting down, skip remaining items instead of redistributing
    if state(c.controller_fsm) != ControllerRunning || terminated_env === nothing
        @info "Test process '$(terminated_proc_id)' terminated, skipping $(length(items_to_redistribute)) remaining item(s) (controller shutting down or env unknown)"
        for testitem_id in items_to_redistribute
            if haskey(tr.remaining_items, testitem_id)
                delete!(tr.remaining_items, testitem_id)
                c.callbacks.on_testitem_skipped(msg.testrun_id, testitem_id)
            end
        end
        _check_testrun_complete!(c, tr)
        return false
    end

    # Identify whether the crash happened while a test item was actively running.
    # ps.current_testitem_id is set in TestItemStartedMsg and cleared in _cancel_timeout!
    # (called on passed/failed/errored).  It is NOT cleared by _kill_julia_process!, so it
    # is still valid here (TestProcessTerminatedMsg hasn't been processed yet).
    ps = haskey(c.test_processes, terminated_proc_id) ? c.test_processes[terminated_proc_id] : nothing
    crashed_item_id = ps !== nothing ? ps.current_testitem_id : nothing

    if crashed_item_id !== nothing && haskey(tr.remaining_items, crashed_item_id)
        # A test item was actively running when the process crashed — error it immediately.
        item = tr.remaining_items[crashed_item_id]
        delete!(tr.remaining_items, crashed_item_id)
        filter!(!isequal(crashed_item_id), items_to_redistribute)
        _cancel_timeout!(ps)
        @info "Test process '$(terminated_proc_id)' crashed while running test item '$(item.label)', erroring it immediately"
        c.callbacks.on_testitem_errored(
            msg.testrun_id,
            crashed_item_id,
            TestItemControllerProtocol.TestMessage[
                TestItemControllerProtocol.TestMessage(
                    message = "Test process crashed while running test item '$(item.label)'",
                    expectedOutput = missing,
                    actualOutput = missing,
                    uri = item.uri,
                    line = item.line,
                    column = item.column
                )
            ],
            missing
        )
    elseif crashed_item_id === nothing
        # No item was actively running when the process died.
        # Distinguish startup crash from post-run kill (timeout handler, etc.)
        # by checking whether the process ever reached ProcessRunning.
        process_was_running = ps !== nothing && state(ps.fsm) in (ProcessRunning, ProcessIdle)
        if !process_was_running
            # True startup crash — process never ran any item. Error all queued items.
            @info "Test process '$(terminated_proc_id)' crashed during startup, erroring $(length(items_to_redistribute)) queued item(s)"
            for testitem_id in items_to_redistribute
                if haskey(tr.remaining_items, testitem_id)
                    item = tr.remaining_items[testitem_id]
                    delete!(tr.remaining_items, testitem_id)
                    c.callbacks.on_testitem_errored(
                        msg.testrun_id,
                        testitem_id,
                        TestItemControllerProtocol.TestMessage[
                            TestItemControllerProtocol.TestMessage(
                                message = "Test process crashed before running test item '$(item.label)'",
                                expectedOutput = missing,
                                actualOutput = missing,
                                uri = item.uri,
                                line = item.line,
                                column = item.column
                            )
                        ],
                        missing
                    )
                end
            end
            _check_testrun_complete!(c, tr)
            return false
        end
        # else: process was functional and was killed after running items (e.g., timeout).
        # Fall through to redistribute remaining un-started items.
        @info "Test process '$(terminated_proc_id)' terminated after running items, redistributing $(length(items_to_redistribute)) remaining item(s)"
    end

    # Redistribute remaining un-started items (if any) to another process.
    if isempty(items_to_redistribute)
        _check_testrun_complete!(c, tr)
        return false
    end

    @info "Redistributing $(length(items_to_redistribute)) un-started item(s) from crashed process '$(terminated_proc_id)'"

    # Try to find another live process in the same env
    recipient_pid = nothing
    if tr.procs !== nothing && haskey(tr.procs, terminated_env)
        for pid in tr.procs[terminated_env]
            if pid != terminated_proc_id && haskey(c.test_processes, pid) && state(c.test_processes[pid].fsm) != ProcessDead && c.test_processes[pid].endpoint !== nothing
                recipient_pid = pid
                break
            end
        end
    end

    if recipient_pid !== nothing
        # Redistribute to existing process
        rps = c.test_processes[recipient_pid]
        append!(get!(tr.testitem_ids_by_proc, recipient_pid, String[]), items_to_redistribute)

        items_to_run = [tr.remaining_items[id] for id in items_to_redistribute if haskey(tr.remaining_items, id)]
        @info "Redistributing $(length(items_to_run)) item(s) to existing process '$(recipient_pid)'"
        _send_run_testitems!(c, rps, items_to_run)
    else
        # Create a new replacement process for the un-started items
        env = terminated_env
        profile = tr.profiles[1]

        env_content_hash = nothing
        for id in items_to_redistribute
            if haskey(tr.remaining_items, id)
                env_content_hash = tr.remaining_items[id].env_content_hash
                break
            end
        end

        @info "Creating new replacement process for package '$(env.package_name)'"

        precompile_already_done = env in c.precompiled_envs

        testprocess_id = string(UUIDs.uuid4())

        new_ps = TestProcessState(testprocess_id, env;
            is_precompile_process=precompile_already_done,
            precompile_done=precompile_already_done,
            test_env_content_hash=env_content_hash)
        new_ps.testrun_id = msg.testrun_id
        c.test_processes[testprocess_id] = new_ps

        pool_ids = get!(c.process_pool, env) do; String[]; end
        push!(pool_ids, testprocess_id)

        if tr.procs !== nothing
            push!(get!(tr.procs, env) do; String[]; end, testprocess_id)
        end

        tr.testitem_ids_by_proc[testprocess_id] = items_to_redistribute
        tr.stolen_ids_by_proc[testprocess_id] = String[]

        testrun_token = CancellationTokens.get_token(tr.cancellation_source)

        server_test_setups = [
            TestItemServerProtocol.TestsetupDetails(
                packageUri = i.package_uri,
                name = i.name,
                kind = i.kind,
                uri = i.uri,
                line = i.line,
                column = i.column,
                code = i.code
            ) for i in tr.test_setups
        ]

        _setup_testrun_on_process!(new_ps, msg.testrun_id, server_test_setups, profile.coverage_root_uris, profile.log_level, testrun_token)

        transition!(new_ps.fsm, ProcessStarting; reason="replacement process")
        _launch_julia_process!(c, new_ps)

        if c.callbacks.on_process_created !== nothing
            c.callbacks.on_process_created(testprocess_id, env.package_name, env.package_uri, env.project_uri, env.mode == "Coverage", env.env)
        end
    end

    return false
end

function handle!(c::TestItemController, msg::TestItemTimeoutMsg)
    if !haskey(c.test_runs, msg.testrun_id) || !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    tr = c.test_runs[msg.testrun_id]
    ps = c.test_processes[msg.testprocess_id]

    # Guard against stale timeout
    if ps.current_testitem_id != msg.testitem_id
        return false
    end

    item = get(tr.remaining_items, msg.testitem_id, nothing)
    item_label = item !== nothing ? item.label : msg.testitem_id
    timeout_val = item !== nothing && item.timeout !== nothing ? item.timeout : "?"

    @warn "Test item '$(item_label)' timed out after $(timeout_val) seconds"

    _cancel_timeout!(ps)

    # Report item as errored
    if haskey(tr.remaining_items, msg.testitem_id)
        delete!(tr.remaining_items, msg.testitem_id)
        _remove_from_proc_queue!(tr, msg.testprocess_id, msg.testitem_id)

        c.callbacks.on_testitem_errored(
            msg.testrun_id,
            msg.testitem_id,
            TestItemControllerProtocol.TestMessage[
                TestItemControllerProtocol.TestMessage(
                    message = "Test item '$(item_label)' timed out after $(timeout_val) seconds",
                    expectedOutput = missing,
                    actualOutput = missing,
                    uri = item !== nothing ? item.uri : missing,
                    line = item !== nothing ? item.line : missing,
                    column = item !== nothing ? item.column : missing
                )
            ],
            missing
        )
    end

    # Kill the process
    if ps.jl_process !== nothing
        try kill(ps.jl_process) catch end
    end

    # Post terminated in run message to handle redistribution
    put!(c.reactor_channel, TestProcessTerminatedInRunMsg(msg.testrun_id, msg.testprocess_id, false))
    return false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Process-lifecycle handlers (from IO tasks)
# ═══════════════════════════════════════════════════════════════════════════════

function handle!(c::TestItemController, msg::TestProcessLaunchedMsg)
    @debug "Handling TestProcessLaunchedMsg" testprocess_id=msg.testprocess_id process_known=haskey(c.test_processes, msg.testprocess_id)
    if !haskey(c.test_processes, msg.testprocess_id)
        # Process was removed (e.g. shutdown), kill the stale Julia process
        try kill(msg.jl_process) catch end
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessStarting
        # Process was cancelled/dead while starting, kill the stale process
        @debug "Ignoring TestProcessLaunchedMsg in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        try kill(msg.jl_process) catch end
        return false
    end

    ps.jl_process = msg.jl_process
    ps.endpoint = msg.endpoint

    if ps.testrun_id === nothing
        # Process launched but testrun already ended (e.g. cancelled while starting)
        transition!(ps.fsm, ProcessIdle; reason="launched_without_testrun")
        return false
    end

    if ps.is_precompile_process || ps.precompile_done
        @debug "Activating environment after launch" testprocess_id=msg.testprocess_id precompile_process=ps.is_precompile_process precompile_done=ps.precompile_done
        transition!(ps.fsm, ProcessActivatingEnv; reason="testprocess_launched")
        _activate_env!(c, ps)
    else
        transition!(ps.fsm, ProcessWaitingForPrecompile; reason="waiting_for_peer_precompile")
    end

    return false
end

function handle!(c::TestItemController, msg::TestProcessActivatedMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessActivatingEnv
        @debug "Ignoring TestProcessActivatedMsg in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        return false
    end

    if ps.testrun_id !== nothing && haskey(c.test_runs, ps.testrun_id) && state(c.test_runs[ps.testrun_id].fsm) in (TestRunCancelled, TestRunCompleted)
        @debug "Test run already ended, returning process to idle" testprocess_id=msg.testprocess_id
        transition!(ps.fsm, ProcessDead; reason="testrun_cancelled_during_activation")
        put!(c.reactor_channel, ReturnToPoolMsg(msg.testprocess_id, ps.env))
        return false
    end

    transition!(ps.fsm, ProcessConfiguringTestRun; reason="testprocess_activated")

    if ps.env.mode == "Debug" && ps.testrun_id !== nothing
        @debug "Requesting debugger attachment" testprocess_id=msg.testprocess_id debug_pipe_name=ps.debug_pipe_name
        put!(c.reactor_channel, AttachDebuggerMsg(ps.testrun_id, ps.debug_pipe_name))
    end

    @debug "Configuring test run on process" testprocess_id=msg.testprocess_id mode=ps.env.mode
    _configure_testrun!(c, ps)

    return false
end

function handle!(c::TestItemController, msg::TestProcessTestSetupsLoadedMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessConfiguringTestRun
        @debug "Ignoring TestProcessTestSetupsLoadedMsg in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        return false
    end

    if ps.testrun_id !== nothing && haskey(c.test_runs, ps.testrun_id) && state(c.test_runs[ps.testrun_id].fsm) in (TestRunCancelled, TestRunCompleted)
        @debug "Test run already ended, returning process to idle" testprocess_id=msg.testprocess_id
        transition!(ps.fsm, ProcessDead; reason="testrun_cancelled_during_configuration")
        put!(c.reactor_channel, ReturnToPoolMsg(msg.testprocess_id, ps.env))
        return false
    end

    transition!(ps.fsm, ProcessReadyToRun; reason="testprocess_testsetups_loaded")
    @info "Process is ready to run test items" testprocess_id=msg.testprocess_id

    if ps.testrun_id !== nothing
        put!(c.reactor_channel, ReadyToRunTestItemsMsg(ps.testrun_id, msg.testprocess_id))
    end

    return false
end

function handle!(c::TestItemController, msg::TestProcessReviseResultMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessRevising
        @debug "Ignoring TestProcessReviseResultMsg in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        return false
    end

    if msg.needs_restart
        @debug "Revise requested restart" testprocess_id=msg.testprocess_id
        _kill_julia_process!(ps)
        transition!(ps.fsm, ProcessStarting; reason="restart_after_revise")
        _launch_julia_process!(c, ps)
    else
        @debug "Revise completed without restart, skipping activation" testprocess_id=msg.testprocess_id
        transition!(ps.fsm, ProcessConfiguringTestRun; reason="revise_success")

        if ps.env.mode == "Debug" && ps.testrun_id !== nothing
            @debug "Requesting debugger attachment" testprocess_id=msg.testprocess_id debug_pipe_name=ps.debug_pipe_name
            put!(c.reactor_channel, AttachDebuggerMsg(ps.testrun_id, ps.debug_pipe_name))
        end

        @debug "Configuring test run on process" testprocess_id=msg.testprocess_id mode=ps.env.mode
        _configure_testrun!(c, ps)
    end

    return false
end

function handle!(c::TestItemController, msg::ActivationFailedMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) != ProcessActivatingEnv
        @debug "Ignoring ActivationFailedMsg in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        return false
    end

    @error "Environment activation failed for process" testprocess_id=msg.testprocess_id is_precompile=ps.is_precompile_process error=msg.error_message

    if ps.testrun_id === nothing || !haskey(c.test_runs, ps.testrun_id)
        # No active test run — just kill process
        _kill_julia_process!(ps)
        transition!(ps.fsm, ProcessDead; reason="activation_failed_no_testrun")
        put!(c.reactor_channel, TestProcessTerminatedMsg(ps.id))
        return false
    end

    tr = c.test_runs[ps.testrun_id]
    testrun_id = ps.testrun_id

    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        _kill_julia_process!(ps)
        transition!(ps.fsm, ProcessDead; reason="activation_failed_testrun_ended")
        put!(c.reactor_channel, TestProcessTerminatedMsg(ps.id))
        return false
    end

    if ps.is_precompile_process
        # Precompile process failure is deterministic — all processes for this env will fail.
        # Error ALL remaining items for this environment and kill all peer processes.
        env = ps.env

        # Collect all items for this environment
        items_to_error = String[]
        if tr.procs !== nothing && haskey(tr.procs, env)
            for pid in tr.procs[env]
                if haskey(tr.testitem_ids_by_proc, pid)
                    for testitem_id in tr.testitem_ids_by_proc[pid]
                        if haskey(tr.remaining_items, testitem_id)
                            push!(items_to_error, testitem_id)
                        end
                    end
                    empty!(tr.testitem_ids_by_proc[pid])
                end
            end
        end

        # Error all collected items
        for testitem_id in items_to_error
            if haskey(tr.remaining_items, testitem_id)
                item = tr.remaining_items[testitem_id]
                delete!(tr.remaining_items, testitem_id)
                c.callbacks.on_testitem_errored(
                    testrun_id,
                    testitem_id,
                    TestItemControllerProtocol.TestMessage[
                        TestItemControllerProtocol.TestMessage(
                            message = "Environment activation failed for package '$(env.package_name)': $(msg.error_message)",
                            expectedOutput = missing,
                            actualOutput = missing,
                            uri = item.uri,
                            line = item.line,
                            column = item.column
                        )
                    ],
                    missing
                )
            end
        end

        # Kill all peer processes for this environment (they're waiting for precompile that will never come)
        if tr.procs !== nothing && haskey(tr.procs, env)
            for pid in tr.procs[env]
                if haskey(c.test_processes, pid)
                    peer = c.test_processes[pid]
                    _kill_julia_process!(peer)
                    if state(peer.fsm) != ProcessDead
                        transition!(peer.fsm, ProcessDead; reason="activation_failed_precompile_process")
                    end
                    put!(c.reactor_channel, TestProcessTerminatedMsg(pid))
                end
            end
        end
    else
        # Non-precompile process — error only items assigned to this process
        if haskey(tr.testitem_ids_by_proc, ps.id)
            for testitem_id in tr.testitem_ids_by_proc[ps.id]
                if haskey(tr.remaining_items, testitem_id)
                    item = tr.remaining_items[testitem_id]
                    delete!(tr.remaining_items, testitem_id)
                    c.callbacks.on_testitem_errored(
                        testrun_id,
                        testitem_id,
                        TestItemControllerProtocol.TestMessage[
                            TestItemControllerProtocol.TestMessage(
                                message = "Environment activation failed for package '$(ps.env.package_name)': $(msg.error_message)",
                                expectedOutput = missing,
                                actualOutput = missing,
                                uri = item.uri,
                                line = item.line,
                                column = item.column
                            )
                        ],
                        missing
                    )
                end
            end
            empty!(tr.testitem_ids_by_proc[ps.id])
        end

        _kill_julia_process!(ps)
        transition!(ps.fsm, ProcessDead; reason="activation_failed")
        put!(c.reactor_channel, TestProcessTerminatedMsg(ps.id))
    end

    _check_testrun_complete!(c, tr)

    return false
end

function handle!(c::TestItemController, msg::TestProcessIOErrorMsg)
    if !haskey(c.test_processes, msg.testprocess_id)
        return false
    end
    ps = c.test_processes[msg.testprocess_id]

    if state(ps.fsm) in (ProcessDead, ProcessIdle)
        @debug "Ignoring IO error for process in state $(state(ps.fsm))" testprocess_id=msg.testprocess_id
        return false
    end

    @warn "Test process IO error" testprocess_id=msg.testprocess_id error_type=msg.error_type fsm_state=state(ps.fsm) has_testrun=(ps.testrun_id !== nothing) testrun_id=something(ps.testrun_id, "none")

    _kill_julia_process!(ps)

    if msg.error_type == :restart && ps.testrun_id !== nothing
        # Restart the process for the current testrun
        transition!(ps.fsm, ProcessStarting; reason="restart_after_io_error")
        _launch_julia_process!(c, ps)
    else
        # Fatal error — terminate
        if ps.testrun_id !== nothing
            put!(c.reactor_channel, TestProcessTerminatedInRunMsg(ps.testrun_id, ps.id, false))
        end
        put!(c.reactor_channel, TestProcessTerminatedMsg(ps.id))
    end

    return false
end

# ═══════════════════════════════════════════════════════════════════════════════
# Process management helpers
# ═══════════════════════════════════════════════════════════════════════════════

function _kill_julia_process!(ps::TestProcessState)
    if ps.julia_proc_cs !== nothing
        try CancellationTokens.cancel(ps.julia_proc_cs) catch end
    end
    if ps.jl_process !== nothing
        try kill(ps.jl_process) catch end
    end
    ps.jl_process = nothing
    ps.endpoint = nothing
    ps.julia_proc_cs = nothing
end

function _clear_testrun_on_process!(ps::TestProcessState)
    if ps.testrun_watcher_registration !== nothing
        try close(ps.testrun_watcher_registration) catch end
        ps.testrun_watcher_registration = nothing
    end
    ps.testrun_id = nothing
    ps.testrun_token = nothing
    ps.test_setups = nothing
    ps.coverage_root_uris = nothing
end

function _setup_testrun_on_process!(ps::TestProcessState, testrun_id::String, test_setups, coverage_root_uris, log_level::Symbol, testrun_token)
    ps.testrun_id = testrun_id
    ps.testrun_token = testrun_token
    ps.test_setups = test_setups
    ps.coverage_root_uris = coverage_root_uris
    ps.proc_log_level = log_level
end

function _shutdown_test_process!(c::TestItemController, ps::TestProcessState)
    @debug "Shutting down test process" testprocess_id=ps.id
    CancellationTokens.cancel(ps.cs)
    _kill_julia_process!(ps)
    if ps.testrun_id !== nothing
        put!(c.reactor_channel, TestProcessTerminatedInRunMsg(ps.testrun_id, ps.id, false))
    end
    put!(c.reactor_channel, TestProcessTerminatedMsg(ps.id))
end

function _launch_julia_process!(c::TestItemController, ps::TestProcessState)
    ps.julia_proc_cs = if ps.testrun_token !== nothing && !CancellationTokens.is_cancellation_requested(ps.testrun_token)
        CancellationTokens.CancellationTokenSource(CancellationTokens.get_token(ps.cs), ps.testrun_token)
    else
        CancellationTokens.CancellationTokenSource(CancellationTokens.get_token(ps.cs))
    end

    # Capture the token now so the catch block doesn't read a potentially-null
    # ps.julia_proc_cs (which can happen if _kill_julia_process! races with us).
    launch_token = CancellationTokens.get_token(ps.julia_proc_cs)

    @debug "Launching Julia process for test process" testprocess_id=ps.id package=ps.env.package_name mode=ps.env.mode is_precompile=ps.is_precompile_process precompile_done=ps.precompile_done testrun_id=something(ps.testrun_id, "none")
    put!(c.reactor_channel, TestProcessStatusChangedMsg(ps.id, "Launching"))

    Base.ScopedValues.@with logging_node => "tp_$(ps.id[1:5])" @async try
        start(ps.id, c.reactor_channel, ps, ps.env, ps.debug_pipe_name,
              c.error_handler_file, c.crash_reporting_pipename,
              launch_token)
    catch err
        if !CancellationTokens.is_cancellation_requested(launch_token)
            @error "Error in test process IO" testprocess_id=ps.id exception=(err, catch_backtrace())
        end
        try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
    end
end

function _activate_env!(c::TestItemController, ps::TestProcessState)
    put!(c.reactor_channel, TestProcessStatusChangedMsg(ps.id, "Activating"))
    @async try
        result = JSONRPC.send(
            ps.endpoint,
            TestItemServerProtocol.testserver_activate_env_request_type,
            TestItemServerProtocol.ActivateEnvParams(
                projectUri = something(ps.env.project_uri, missing),
                packageUri = ps.env.package_uri,
                packageName = ps.env.package_name
            )
        )

        if result.status == "failed"
            @error "Environment activation failed" testprocess_id=ps.id error=coalesce(result.error, "unknown error")
            put!(c.reactor_channel, ActivationFailedMsg(ps.id, coalesce(result.error, "Environment activation failed")))
            return
        end

        if ps.is_precompile_process && ps.testrun_id !== nothing
            put!(c.reactor_channel, PrecompileDoneMsg(ps.testrun_id, ps.env, ps.id))
        end
        put!(c.reactor_channel, TestProcessActivatedMsg(ps.id))
    catch err
        @error "Error activating environment" testprocess_id=ps.id exception=(err, catch_backtrace())
        try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :restart)) catch end
    end
end

function _configure_testrun!(c::TestItemController, ps::TestProcessState)
    if ps.endpoint === nothing
        @warn "Cannot configure test run: process has no endpoint" testprocess_id=ps.id
        try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
        return
    end
    @async try
        JSONRPC.send(
            ps.endpoint,
            TestItemServerProtocol.configure_testrun_request_type,
            TestItemServerProtocol.ConfigureTestRunRequestParams(
                mode = ps.env.mode,
                logLevel = string(ps.proc_log_level),
                coverageRootUris = something(ps.coverage_root_uris, missing),
                testSetups = ps.test_setups
            )
        )
        put!(c.reactor_channel, TestProcessTestSetupsLoadedMsg(ps.id))
    catch err
        @error "Error configuring test run" testprocess_id=ps.id exception=(err, catch_backtrace())
        try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :restart)) catch end
    end
end

function _send_run_testitems!(c::TestItemController, ps::TestProcessState, items)
    if ps.endpoint === nothing
        @warn "Cannot send test items: process has no endpoint" testprocess_id=ps.id
        try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :fatal)) catch end
        return
    end
    put!(c.reactor_channel, TestProcessStatusChangedMsg(ps.id, "Running"))
    @async try
        JSONRPC.send(
            ps.endpoint,
            TestItemServerProtocol.testserver_run_testitems_batch_request_type,
            TestItemServerProtocol.RunTestItemsRequestParams(
                mode = ps.env.mode,
                coverageRootUris = something(ps.coverage_root_uris, missing),
                testItems = TestItemServerProtocol.RunTestItem[
                    TestItemServerProtocol.RunTestItem(
                        id = i.id,
                        uri = i.uri,
                        name = i.label,
                        packageName = something(i.package_name, missing),
                        packageUri = something(i.package_uri, missing),
                        useDefaultUsings = i.option_default_imports,
                        testSetups = i.test_setups,
                        line = i.code_line,
                        column = i.code_column,
                        code = i.code,
                    ) for i in items
                ],
            )
        )
    catch err
        @error "Error running testitems" testprocess_id=ps.id exception=(err, catch_backtrace())
        try put!(c.reactor_channel, TestProcessIOErrorMsg(ps.id, :restart)) catch end
    end
end

function _send_steal!(c::TestItemController, ps::TestProcessState, testitem_ids::Vector{String})
    if ps.endpoint === nothing
        @warn "Cannot steal test items: process has no endpoint" testprocess_id=ps.id
        return
    end
    @async try
        JSONRPC.send(
            ps.endpoint,
            TestItemServerProtocol.testserver_steal_testitems_request_type,
            TestItemServerProtocol.StealTestItemsRequestParams(
                testItemIds = testitem_ids
            )
        )
    catch err
        @error "Error stealing testitems" testprocess_id=ps.id exception=(err, catch_backtrace())
    end
end

function _start_revise!(c::TestItemController, ps::TestProcessState, new_env_hash)
    if ps.endpoint === nothing
        @warn "Cannot revise: process has no endpoint" testprocess_id=ps.id
        try put!(c.reactor_channel, TestProcessReviseResultMsg(ps.id, true)) catch end
        return
    end
    @async try
        needs_restart = false

        if new_env_hash != ps.test_env_content_hash
            needs_restart = true
        else
            res = JSONRPC.send(ps.endpoint, TestItemServerProtocol.testserver_revise_request_type, nothing)
            if res == "success"
                needs_restart = false
            elseif res == "failed"
                needs_restart = true
            else
                error("Unexpected revise result: $res")
            end
        end

        ps.test_env_content_hash = new_env_hash
        put!(c.reactor_channel, TestProcessReviseResultMsg(ps.id, needs_restart))
    catch err
        @error "Error during revise" testprocess_id=ps.id exception=(err, catch_backtrace())
        try put!(c.reactor_channel, TestProcessReviseResultMsg(ps.id, true)) catch end
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# Test-run helper functions
# ═══════════════════════════════════════════════════════════════════════════════

function _remove_from_proc_queue!(tr::TestRunState, proc_id::String, testitem_id::String)
    if haskey(tr.testitem_ids_by_proc, proc_id)
        idx = findfirst(isequal(testitem_id), tr.testitem_ids_by_proc[proc_id])
        if idx !== nothing
            deleteat!(tr.testitem_ids_by_proc[proc_id], idx)
        end
    end
end

function _item_env(item::TestItemDetail, tr::TestRunState)
    profile = tr.profiles[1]
    return TestEnvironment(
        item.project_uri,
        item.package_uri,
        item.package_name,
        profile.julia_cmd,
        profile.julia_args,
        profile.julia_num_threads,
        profile.mode,
        profile.julia_env
    )
end

"""Get items for an env that haven't been assigned to a process yet."""
function _get_unchunked_items(tr::TestRunState, env::TestEnvironment)
    assigned = Set{String}()
    for (_, ids) in tr.testitem_ids_by_proc
        union!(assigned, ids)
    end
    items = [id for (id, item) in tr.remaining_items if _item_env(item, tr) == env && id ∉ assigned]
    return items
end

function _check_stealing!(c::TestItemController, tr::TestRunState, finished_proc_id::String)
    if !haskey(tr.testitem_ids_by_proc, finished_proc_id)
        return
    end

    remaining_for_proc = length(tr.testitem_ids_by_proc[finished_proc_id])
    pending_stolen = length(get(tr.stolen_ids_by_proc, finished_proc_id, String[]))

    if remaining_for_proc > 0 || pending_stolen > 0
        return
    end

    # This process has nothing left to do — try to steal
    if !haskey(c.test_processes, finished_proc_id)
        return
    end
    ps = c.test_processes[finished_proc_id]

    # Find the env for this process in the testrun
    proc_env = nothing
    procs_in_same_env = String[]
    if tr.procs !== nothing
        for (env, pids) in pairs(tr.procs)
            if finished_proc_id in pids
                proc_env = env
                procs_in_same_env = pids
                break
            end
        end
    end

    if proc_env === nothing
        # Process not in any env for this testrun, return to pool
        put!(c.reactor_channel, ReturnToPoolMsg(finished_proc_id, ps.env))
        return
    end

    @info "Test process '$(finished_proc_id)' finished all assigned test items (package '$(proc_env.package_name)')"

    # Find best steal candidate
    best_candidate_id = nothing
    best_count = 1  # only steal if victim has >1 items

    for candidate_pid in procs_in_same_env
        n = length(get(tr.testitem_ids_by_proc, candidate_pid, String[]))
        if n > best_count
            best_count = n
            best_candidate_id = candidate_pid
        end
    end

    if best_candidate_id === nothing
        # Only return to pool here if the testrun won't be completing immediately
        # (which would return all procs). This avoids duplicate ReturnToPoolMsg.
        pending_stolen = sum(length, values(tr.stolen_ids_by_proc); init=0)
        if !isempty(tr.remaining_items) || pending_stolen > 0
            @info "No work to steal, returning test process '$(finished_proc_id)' to pool"
            put!(c.reactor_channel, ReturnToPoolMsg(finished_proc_id, ps.env))
        end
        return
    end

    # Steal half the items from the end of the victim's queue
    victim_ids = tr.testitem_ids_by_proc[best_candidate_id]
    steal_range = (div(length(victim_ids), 2, RoundUp) + 1):lastindex(victim_ids)
    testitem_ids_to_steal = victim_ids[steal_range]

    @info "Stealing $(length(testitem_ids_to_steal)) test item(s) from process '$(best_candidate_id)' to process '$(finished_proc_id)'"

    deleteat!(victim_ids, steal_range)
    append!(get!(tr.testitem_ids_by_proc, finished_proc_id, String[]), testitem_ids_to_steal)

    if best_candidate_id in tr.items_dispatched_to_procs
        for id in testitem_ids_to_steal
            push!(get!(tr.stolen_ids_by_proc, best_candidate_id, String[]), id)
        end

        if haskey(c.test_processes, best_candidate_id)
            victim_ps = c.test_processes[best_candidate_id]
            _send_steal!(c, victim_ps, testitem_ids_to_steal)
        end
    end

    # Send items to thief
    items_to_run = [tr.remaining_items[id] for id in testitem_ids_to_steal if haskey(tr.remaining_items, id)]
    _send_run_testitems!(c, ps, items_to_run)
    return
end

function _check_testrun_complete!(c::TestItemController, tr::TestRunState)
    if state(tr.fsm) in (TestRunCancelled, TestRunCompleted)
        return
    end

    remaining = length(tr.remaining_items)
    pending_stolen = sum(length, values(tr.stolen_ids_by_proc); init=0)

    if remaining == 0 && pending_stolen == 0
        coverage_results = missing
        if !isempty(tr.coverage)
            coverage_results = map(CoverageTools.merge_coverage_counts(tr.coverage)) do i
                TestItemControllerProtocol.FileCoverage(
                    uri = filepath2uri(i.filename),
                    coverage = i.coverage
                )
            end
        end

        @info "Test run '$(tr.id)' completed"
        transition!(tr.fsm, TestRunCompleted; reason="all items done")

        # Return all processes to pool
        if tr.procs !== nothing
            for pid in Iterators.flatten(values(tr.procs))
                if haskey(c.test_processes, pid)
                    ps = c.test_processes[pid]
                    put!(c.reactor_channel, ReturnToPoolMsg(pid, ps.env))
                end
            end
        end

        try put!(tr.completion_channel, coverage_results) catch end
    else
        @debug "$(remaining) test item(s) remaining ($(pending_stolen) pending stolen confirmation(s))"
    end
end

# ═══════════════════════════════════════════════════════════════════════════════
# execute_testrun — thin wrapper, no callbacks in signature
# ═══════════════════════════════════════════════════════════════════════════════

function execute_testrun(
    controller::TestItemController,
    testrun_id::String,
    profiles::Vector{TestProfile},
    test_items::Vector{TestItemDetail},
    test_setups::Vector{TestSetupDetail},
    token)

    @assert length(profiles) == 1 "Currently one must pass one test profile"

    Base.ScopedValues.@with logging_node => "testrun_$(testrun_id)" begin

        @info "Creating new test run '$(testrun_id)' with $(length(test_items)) test item(s)"

        # Build TestRunState
        tr = TestRunState(
            testrun_id,
            profiles,
            test_items,
            [
                TestSetupDetail(i.package_uri, i.name, i.kind, i.uri, i.line, i.column, i.code)
                for i in test_setups
            ];
            token = token
        )

        # Register cancellation bridge
        testrun_cancel_registration = nothing
        if token !== nothing
            testrun_cancel_registration = CancellationTokens.register(token) do
                try put!(controller.reactor_channel, TestRunCancelledMsg(testrun_id)) catch end
            end
        end

        # Filter invalid items (no package)
        valid_test_items = Dict(i.id => i for i in test_items if i.package_name !== nothing && i.package_uri !== nothing)
        test_items_without_package = [i for i in test_items if i.package_name === nothing || i.package_uri === nothing]

        # Report items without package as failed
        for i in test_items_without_package
            controller.callbacks.on_testitem_failed(
                testrun_id,
                i.id,
                TestItemControllerProtocol.TestMessage[
                    TestItemControllerProtocol.TestMessage(
                        message = "Test item '$(i.label)' is not inside a Julia package. Test items must be inside a package to be run.",
                        expectedOutput = missing,
                        actualOutput = missing,
                        uri = i.uri,
                        line = i.line,
                        column = i.column
                    )
                ],
                missing
            )
            delete!(tr.remaining_items, i.id)
        end

        if isempty(valid_test_items)
            @warn "No valid test items to run"
            if testrun_cancel_registration !== nothing
                try close(testrun_cancel_registration) catch end
            end
            return missing
        end

        # Build environment mapping
        testitem_ids_by_env = Dict{TestEnvironment,Vector{String}}()
        env_content_hash_by_env = Dict{TestEnvironment,Union{Nothing,String}}()

        for i in values(valid_test_items)
            te = _item_env(i, tr)
            push!(get!(testitem_ids_by_env, te) do; String[]; end, i.id)
            env_content_hash_by_env[te] = i.env_content_hash
        end

        # Calculate process counts
        proc_count_by_env = Dict{TestEnvironment,Int}()
        for (k, v) in pairs(testitem_ids_by_env)
            as_share = length(v) / length(valid_test_items)
            n_procs = max(1, min(floor(Int, profiles[1].max_process_count * as_share), length(valid_test_items)))
            proc_count_by_env[k] = n_procs
        end

        # Register test run with controller
        controller.test_runs[testrun_id] = tr
        transition!(tr.fsm, TestRunWaitingForProcs; reason="requesting procs")

        # Build server-side test setup details
        server_test_setups = [
            TestItemServerProtocol.TestsetupDetails(
                packageUri = i.package_uri,
                name = i.name,
                kind = i.kind,
                uri = i.uri,
                line = i.line,
                column = i.column,
                code = i.code
            ) for i in test_setups
        ]

        # Request processes
        put!(
            controller.reactor_channel,
            GetProcsForTestRunMsg(
                testrun_id,
                proc_count_by_env,
                env_content_hash_by_env,
                server_test_setups,
                profiles[1].coverage_root_uris,
                profiles[1].log_level
            )
        )

        # Wait for completion
        coverage_results = take!(tr.completion_channel)

        @debug "Leaving execute_testrun" testrun_id

        if testrun_cancel_registration !== nothing
            try close(testrun_cancel_registration) catch end
        end

        # Clean up test run state
        delete!(controller.test_runs, testrun_id)

        return coverage_results
    end
end
