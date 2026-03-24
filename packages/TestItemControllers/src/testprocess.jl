# Dispatch handler for JSONRPC messages from the test process.
# Posts ReactorMessages directly to the reactor channel.
JSONRPC.@message_dispatcher dispatch_testprocess_msg begin
    TestItemServerProtocol.started_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemStartedMsg(testrun_id, ps.id, params.testItemId))
        end
    end
    TestItemServerProtocol.passed_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemPassedMsg(testrun_id, ps.id, params.testItemId, params.duration, params.coverage))
        end
    end
    TestItemServerProtocol.failed_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemFailedMsg(testrun_id, ps.id, params.testItemId, params.messages, params.duration))
        end
    end
    TestItemServerProtocol.errored_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemErroredMsg(testrun_id, ps.id, params.testItemId, params.messages, params.duration))
        end
    end
    TestItemServerProtocol.skipped_stolen_notification_type => (params, ctx) -> begin
        reactor_channel, ps = ctx
        testrun_id = ps.testrun_id
        if testrun_id !== nothing
            put!(reactor_channel, TestItemSkippedStolenMsg(testrun_id, ps.id, params.testItemId))
        end
    end
end

function start(testprocess_id, reactor_channel, ps::TestProcessState, env::TestEnvironment, debug_pipe_name, error_handler_file, crash_reporting_pipename, token)
    pipe_name = JSONRPC.generate_pipe_name()
    server = Sockets.listen(pipe_name)

    # Close the server socket if cancellation fires, unblocking Sockets.accept
    server_cancel_reg = CancellationTokens.register(token) do
        try close(server) catch end
    end

    testserver_script = joinpath(@__DIR__, "../testprocess/app/testserver_main.jl")

    pipe_out = Pipe()

    coverage_arg = env.mode == "Coverage" ? "--code-coverage=user" : "--code-coverage=none"

    jlArgs = copy(env.juliaArgs)

    if env.juliaNumThreads!==missing && env.juliaNumThreads == "auto"
        push!(jlArgs, "--threads=auto")
    end

    jlEnv = copy(ENV)

    # During precompilation, Julia restricts JULIA_LOAD_PATH to dependency paths only
    # (no "@" entry), which prevents child processes from using their own active project.
    if ccall(:jl_generating_output, Cint, ()) == 1
        delete!(jlEnv, "JULIA_LOAD_PATH")
    end

    for (k,v) in pairs(env.env)
        if v!==nothing
            jlEnv[k] = v
        elseif haskey(jlEnv, k)
            delete!(jlEnv, k)
        end
    end

    if env.juliaNumThreads!==missing && env.juliaNumThreads!="auto" && env.juliaNumThreads!=""
        jlEnv["JULIA_NUM_THREADS"] = env.juliaNumThreads
    end

    error_handler_file = error_handler_file === nothing ? [] : [error_handler_file]
    crash_reporting_pipename = crash_reporting_pipename === nothing ? [] : [crash_reporting_pipename]

    cmd_args = `$(env.juliaCmd) $(env.juliaArgs) --check-bounds=yes --startup-file=no --history-file=no --depwarn=no $coverage_arg $testserver_script $pipe_name $(debug_pipe_name) $(error_handler_file...) $(crash_reporting_pipename...)`
    @info "Launching Julia test server process" testprocess_id pipe_name
    @debug "Full launch command" testprocess_id cmd=string(cmd_args) testserver_script mode=env.mode
    jl_process = open(
        pipeline(
            Cmd(cmd_args, detach=false, env=jlEnv),
            stdout = pipe_out,
            stderr = pipe_out
        )
    )

    @async try
        begin_marker = "\x1f3805a0ad41b54562a46add40be31ca27"
        end_marker = "\x1f4031af828c3d406ca42e25628bb0aa77"
        buffer = ""
        current_output_testitem_id = nothing
        while !eof(pipe_out)
            data = readavailable(pipe_out)
            data_as_string = String(data)

            # Capture raw output for crash diagnostics
            lock(raw_output_lock) do
                push!(raw_output_chunks, data_as_string)
            end

            buffer *= data_as_string

            output_for_test_proc = IOBuffer()
            output_for_test_items = Pair{Union{Nothing,String},IOBuffer}[]

            i = 1
            while i<=length(buffer)
                might_be_begin_marker = false
                might_be_end_marker = false

                if current_output_testitem_id === nothing
                    j = 1
                    might_be_begin_marker = true
                    while i + j - 1<=length(buffer) && j <= length(begin_marker)
                        if buffer[i + j - 1] != begin_marker[j] || nextind(buffer, i + j - 1) != i + j
                            might_be_begin_marker = false
                            break
                        end
                        j += 1
                    end
                    is_begin_marker = might_be_begin_marker && length(buffer) - i + 1 >= length(begin_marker)

                    if is_begin_marker
                        ti_id_end_index = findfirst("\"", SubString(buffer, i))
                        if ti_id_end_index === nothing
                            break
                        else
                            current_output_testitem_id = SubString(buffer, i + length(begin_marker), i + ti_id_end_index.start - 2)
                            i = nextind(buffer, i + ti_id_end_index.start - 1)
                        end
                    elseif might_be_begin_marker
                        break
                    end
                else
                    j = 1
                    might_be_end_marker = true
                    while i + j - 1<=length(buffer) && j <= length(end_marker)
                        if buffer[i + j - 1] != end_marker[j] || nextind(buffer, i + j - 1) != i + j
                            might_be_end_marker = false
                            break
                        end
                        j += 1
                    end
                    is_end_marker = might_be_end_marker && length(buffer) - i + 1 >= length(end_marker)

                    if is_end_marker
                        current_output_testitem_id = nothing
                        i = i + length(end_marker)
                    elseif might_be_end_marker
                        break
                    end
                end

                if !might_be_begin_marker && !might_be_end_marker
                    print(output_for_test_proc, buffer[i])

                    if length(output_for_test_items) == 0 || output_for_test_items[end].first != current_output_testitem_id
                        push!(output_for_test_items, current_output_testitem_id => IOBuffer())
                    end

                    output_for_ti = output_for_test_items[end].second
                    if !CancellationTokens.is_cancellation_requested(token)
                        print(output_for_ti, buffer[i])
                    end

                    i = nextind(buffer, i)
                end
            end

            buffer = buffer[i:end]

            output_for_test_proc_as_string = String(take!(output_for_test_proc))

            if length(output_for_test_proc_as_string) > 0
                @debug "Forwarding process output chunk" testprocess_id ncodeunits=ncodeunits(output_for_test_proc_as_string)
                put!(
                    reactor_channel,
                    TestProcessOutputMsg(testprocess_id, output_for_test_proc_as_string)
                )
            end

            for (k,v) in output_for_test_items
                output_for_ti_as_string = String(take!(v))

                if length(output_for_ti_as_string) > 0
                    testrun_id = ps.testrun_id
                    if testrun_id !== nothing
                        @debug "Forwarding test item output chunk" testprocess_id testitem_id=something(k, missing) ncodeunits=ncodeunits(output_for_ti_as_string)
                        put!(
                            reactor_channel,
                            AppendOutputMsg(testrun_id, testprocess_id, k, replace(output_for_ti_as_string, "\n"=>"\r\n"))
                        )
                    end
                end
            end
        end
    catch err
        @error "Error reading test process output" testprocess_id exception=(err, catch_backtrace())
    end

    # Accumulate raw output from subprocess so we can log it if it crashes before connecting.
    raw_output_chunks = String[]
    raw_output_lock = ReentrantLock()

    # Watch for subprocess exit before connection — if the process crashes during
    # startup (e.g. precompilation failure), close the server to unblock Sockets.accept.
    connection_established = Ref(false)
    @async try
        wait(jl_process)
        if !connection_established[]
            captured_output = lock(raw_output_lock) do; join(raw_output_chunks); end
            if CancellationTokens.is_cancellation_requested(token)
                @debug "Test process exited before connecting (cancellation requested)" testprocess_id exitcode=jl_process.exitcode pipe_name
            else
                @error "Test process exited before connecting" testprocess_id exitcode=jl_process.exitcode pipe_name captured_output
            end
            try close(server) catch end
        end
    catch
    end

    @info "Waiting for connection from test process" testprocess_id pipe_name
    local socket
    try
        socket = Sockets.accept(server)
    catch err
        close(server_cancel_reg)
        if CancellationTokens.is_cancellation_requested(token)
            @debug "Accept cancelled by token" testprocess_id
            rethrow(err)
        end
        if !process_running(jl_process)
            captured_output = lock(raw_output_lock) do; join(raw_output_chunks); end
            @error "Test process startup failure details" testprocess_id exitcode=jl_process.exitcode captured_output
            error("Test process exited (code $(jl_process.exitcode)) before connecting to named pipe. Output: $(captured_output)")
        end
        @error "Sockets.accept failed unexpectedly" testprocess_id exception=(err, catch_backtrace())
        rethrow(err)
    end
    connection_established[] = true
    close(server_cancel_reg)
    @info "Connection established" testprocess_id

    endpoint = JSONRPC.JSONRPCEndpoint(socket, socket)

    JSONRPC.start(endpoint)

    # Post-connection watchdog: if the OS process exits (e.g. stack overflow crash),
    # close the socket to unblock the JSONRPC layer promptly.
    @async try
        wait(jl_process)
        if !CancellationTokens.is_cancellation_requested(token)
            @warn "Test process exited unexpectedly, closing socket" testprocess_id exitcode=jl_process.exitcode
            try close(socket) catch end
        end
    catch
    end

    @debug "Notifying reactor that process launched" testprocess_id
    put!(reactor_channel, TestProcessLaunchedMsg(testprocess_id, jl_process, endpoint))

    while true
        msg = try
            JSONRPC.get_next_message(endpoint)
        catch err
            if CancellationTokens.is_cancellation_requested(token)
                break
            else
                rethrow(err)
            end
        end
        @debug "Dispatching message from test server" testprocess_id method=msg.method

        dispatch_testprocess_msg(endpoint, msg, (reactor_channel, ps))
    end
end
