import Tachikoma

# ── Dashboard data types ──────────────────────────────────────────────

mutable struct DashboardTestItem
    name::String
    uri::String
    profile_name::String
    status::Symbol  # :pending, :running, :passed, :failed, :errored, :skipped
    duration::Union{Nothing,Float64}  # milliseconds
    messages::Vector{String}
    output::String
end

mutable struct DashboardProcess
    id::String
    package_name::String
    status::String
    output_lines::Vector{String}
end

mutable struct DashboardState
    lock::ReentrantLock
    run_id::String
    run_status::Symbol  # :running, :completed, :cancelled, :errored
    start_time::Float64
    end_time::Union{Nothing,Float64}
    n_total::Int
    count_success::Int
    count_fail::Int
    count_error::Int
    count_skipped::Int
    testitems::Vector{DashboardTestItem}
    processes::Vector{DashboardProcess}
    process_output_lines::Vector{String}  # aggregated raw output
    definition_errors::Vector{String}
end

function DashboardState(run_id::String, n_total::Int)
    DashboardState(
        ReentrantLock(),
        run_id,
        :running,
        time(),
        nothing,
        n_total,
        0, 0, 0, 0,
        DashboardTestItem[],
        DashboardProcess[],
        String[],
        String[],
    )
end

function DashboardState()
    DashboardState("", 0)
end

function dashboard_push_testitem!(state::DashboardState, item::DashboardTestItem)
    lock(state.lock) do
        push!(state.testitems, item)
    end
end

function dashboard_update_process!(state::DashboardState, id::String, package_name::String, status::String)
    lock(state.lock) do
        idx = findfirst(p -> p.id == id, state.processes)
        if idx !== nothing
            state.processes[idx].status = status
        else
            push!(state.processes, DashboardProcess(id, package_name, status, String[]))
        end
    end
end

function dashboard_remove_process!(state::DashboardState, id::String)
    lock(state.lock) do
        filter!(p -> p.id != id, state.processes)
    end
end

function dashboard_push_process_output!(state::DashboardState, line::String)
    lock(state.lock) do
        push!(state.process_output_lines, line)
        # Cap at 2000 lines
        if length(state.process_output_lines) > 2000
            deleteat!(state.process_output_lines, 1:length(state.process_output_lines) - 1500)
        end
    end
end

function dashboard_set_completed!(state::DashboardState, status::Symbol)
    lock(state.lock) do
        state.run_status = status
        state.end_time = time()
    end
end

# ── Snapshot for render thread ────────────────────────────────────────

struct DashboardSnapshot
    run_id::String
    run_status::Symbol
    start_time::Float64
    end_time::Union{Nothing,Float64}
    n_total::Int
    count_success::Int
    count_fail::Int
    count_error::Int
    count_skipped::Int
    testitems::Vector{DashboardTestItem}
    processes::Vector{DashboardProcess}
    process_output_lines::Vector{String}
end

function snapshot(state::DashboardState)::DashboardSnapshot
    lock(state.lock) do
        DashboardSnapshot(
            state.run_id,
            state.run_status,
            state.start_time,
            state.end_time,
            state.n_total,
            state.count_success,
            state.count_fail,
            state.count_error,
            state.count_skipped,
            copy(state.testitems),
            copy(state.processes),
            copy(state.process_output_lines),
        )
    end
end

# ── Tachikoma dashboard model ────────────────────────────────────────

const _STATUS_ICONS = Dict(
    :passed  => "✓",
    :failed  => "✗",
    :errored => "✗",
    :skipped => "⊘",
    :running => "⏳",
    :pending => "·",
)

@kwdef mutable struct TestRunDashboard <: Tachikoma.Model
    quit::Bool = false
    state::DashboardState
    cts::Union{Nothing,CancellationTokenSource} = nothing
    tick::Int = 0
    # Focused panel: 1=test list, 2=detail, 3=process output
    focus::Int = 1
    # Test list selection
    selected::Int = 1
    list_offset::Int = 0
    # Process output scroll
    output_offset::Int = 0
    output_following::Bool = true
    # Detail pane scroll
    detail_offset::Int = 0
    # Cached snapshot for rendering
    snap::Union{Nothing,DashboardSnapshot} = nothing
    # Track how many output lines we've pushed to scroll pane
    last_output_count::Int = 0
end

Tachikoma.should_quit(m::TestRunDashboard) = m.quit

function Tachikoma.update!(m::TestRunDashboard, evt::Tachikoma.KeyEvent)
    snap = m.snap
    is_running = snap !== nothing && snap.run_status == :running

    if evt.key == :escape
        m.quit = true
        return
    end

    if evt.key == :char && evt.char == 'c' && is_running && m.cts !== nothing
        cancel(m.cts)
        return
    end

    if evt.key == :char && (evt.char == 'q' || evt.char == 'Q')
        if !is_running
            m.quit = true
        end
        return
    end

    if evt.key == :tab
        m.focus = mod1(m.focus + 1, 3)
        return
    end
    # Shift-tab (backtab)
    if evt.key == :backtab
        m.focus = mod1(m.focus - 1, 3)
        return
    end

    # Number keys to jump to panel
    if evt.key == :char && evt.char in ('1', '2', '3')
        m.focus = Int(evt.char) - Int('0')
        return
    end

    # Delegate arrow keys to focused panel
    if m.focus == 1
        _handle_list_key!(m, evt)
    elseif m.focus == 2
        _handle_detail_key!(m, evt)
    elseif m.focus == 3
        _handle_output_key!(m, evt)
    end
end

function _handle_list_key!(m::TestRunDashboard, evt::Tachikoma.KeyEvent)
    snap = m.snap
    snap === nothing && return
    n = length(snap.testitems)
    n == 0 && return
    if evt.key == :down
        m.selected = min(m.selected + 1, n)
        m.detail_offset = 0  # reset detail scroll on selection change
    elseif evt.key == :up
        m.selected = max(m.selected - 1, 1)
        m.detail_offset = 0
    elseif evt.key == :home
        m.selected = 1
        m.detail_offset = 0
    elseif evt.key == :end_key
        m.selected = n
        m.detail_offset = 0
    elseif evt.key == :pagedown
        m.selected = min(m.selected + 10, n)
        m.detail_offset = 0
    elseif evt.key == :pageup
        m.selected = max(m.selected - 10, 1)
        m.detail_offset = 0
    end
end

function _handle_detail_key!(m::TestRunDashboard, evt::Tachikoma.KeyEvent)
    if evt.key == :down
        m.detail_offset += 1
    elseif evt.key == :up
        m.detail_offset = max(m.detail_offset - 1, 0)
    elseif evt.key == :pagedown
        m.detail_offset += 10
    elseif evt.key == :pageup
        m.detail_offset = max(m.detail_offset - 10, 0)
    end
end

function _handle_output_key!(m::TestRunDashboard, evt::Tachikoma.KeyEvent)
    if evt.key == :down
        m.output_offset += 1
        m.output_following = false
    elseif evt.key == :up
        m.output_offset = max(m.output_offset - 1, 0)
        m.output_following = false
    elseif evt.key == :pagedown
        m.output_offset += 10
        m.output_following = false
    elseif evt.key == :pageup
        m.output_offset = max(m.output_offset - 10, 0)
        m.output_following = false
    elseif evt.key == :end_key
        m.output_following = true
    end
end

function Tachikoma.pre_render!(m::TestRunDashboard)
    m.tick += 1
    m.snap = snapshot(m.state)
    # Clamp selection
    n = length(m.snap.testitems)
    if n > 0
        m.selected = clamp(m.selected, 1, n)
    end
end

function Tachikoma.view(m::TestRunDashboard, f::Tachikoma.Frame)
    buf = f.buffer
    snap = m.snap
    snap === nothing && return

    is_running = snap.run_status == :running
    done = snap.count_success + snap.count_fail + snap.count_error + snap.count_skipped

    # ── Main layout: header(1) + progress(3) + body(fill) + output(8) + footer(1)
    rows = Tachikoma.split_layout(
        Tachikoma.Layout(Tachikoma.Vertical, [
            Tachikoma.Fixed(1),   # header
            Tachikoma.Fixed(3),   # progress block
            Tachikoma.Fill(),     # body (test list + detail)
            Tachikoma.Fixed(8),   # process output
            Tachikoma.Fixed(1),   # footer
        ]),
        f.area,
    )
    length(rows) < 5 && return

    header_area, progress_area, body_area, output_area, footer_area = rows[1], rows[2], rows[3], rows[4], rows[5]

    # ── Header
    _render_header!(buf, header_area, snap, is_running)

    # ── Progress
    _render_progress!(buf, progress_area, snap, done, m.tick)

    # ── Body: split horizontally — test list (50%) + detail (50%)
    body_cols = Tachikoma.split_layout(
        Tachikoma.Layout(Tachikoma.Horizontal, [Tachikoma.Percent(50), Tachikoma.Fill()]),
        body_area,
    )
    length(body_cols) >= 2 || return
    list_area, detail_area = body_cols[1], body_cols[2]

    _render_test_list!(buf, list_area, snap, m.selected, m.list_offset, m.focus == 1)
    _render_detail!(buf, detail_area, snap, m.selected, m.detail_offset, m.focus == 2)

    # ── Process output
    _render_output!(buf, output_area, snap, m.output_offset, m.output_following, m.focus == 3)

    # ── Footer
    _render_footer!(buf, footer_area, is_running)
end

# ── Render helpers ────────────────────────────────────────────────────

function _render_header!(buf, area, snap, is_running)
    elapsed = if snap.end_time !== nothing
        snap.end_time - snap.start_time
    else
        time() - snap.start_time
    end
    elapsed_str = _format_duration(elapsed)

    status_str = if is_running
        "Running"
    elseif snap.run_status == :completed
        "Completed"
    elseif snap.run_status == :cancelled
        "Cancelled"
    elseif snap.run_status == :errored
        "Errored"
    else
        string(snap.run_status)
    end

    status_style = if is_running
        Tachikoma.tstyle(:warning, bold=true)
    elseif snap.run_status == :completed && snap.count_fail == 0 && snap.count_error == 0
        Tachikoma.tstyle(:success, bold=true)
    else
        Tachikoma.tstyle(:error, bold=true)
    end

    Tachikoma.render(Tachikoma.StatusBar(
        left=[
            Tachikoma.Span("  Test Run #$(snap.run_id) ", Tachikoma.tstyle(:primary, bold=true)),
            Tachikoma.Span("— $status_str ", status_style),
        ],
        right=[
            Tachikoma.Span("$(elapsed_str)  ", Tachikoma.tstyle(:text_dim)),
        ],
    ), area, buf)
end

function _render_progress!(buf, area, snap, done, tick)
    inner = Tachikoma.render(Tachikoma.Block(; border_style=Tachikoma.tstyle(:border)), area, buf)

    prog_rows = Tachikoma.split_layout(
        Tachikoma.Layout(Tachikoma.Vertical, [Tachikoma.Fixed(1), Tachikoma.Fixed(1)]),
        inner,
    )
    length(prog_rows) < 2 && return

    # Gauge
    ratio = snap.n_total > 0 ? clamp(done / snap.n_total, 0.0, 1.0) : 0.0
    gauge_style = if snap.count_fail > 0 || snap.count_error > 0
        Tachikoma.tstyle(:error)
    elseif snap.run_status == :completed
        Tachikoma.tstyle(:success)
    else
        Tachikoma.tstyle(:primary)
    end
    Tachikoma.render(Tachikoma.Gauge(ratio;
        filled_style=gauge_style,
        empty_style=Tachikoma.tstyle(:text_dim, dim=true),
        tick=tick,
    ), prog_rows[1], buf)

    # Summary text
    parts = String[]
    push!(parts, "$done/$(snap.n_total)")
    snap.count_success > 0 && push!(parts, "$(snap.count_success) passed")
    snap.count_fail > 0 && push!(parts, "$(snap.count_fail) failed")
    snap.count_error > 0 && push!(parts, "$(snap.count_error) errored")
    snap.count_skipped > 0 && push!(parts, "$(snap.count_skipped) skipped")
    summary = join(parts, "  ·  ")
    Tachikoma.set_string!(buf, prog_rows[2].x, prog_rows[2].y, summary, Tachikoma.tstyle(:text))
end

function _render_test_list!(buf, area, snap, selected, list_offset, focused)
    border_style = focused ? Tachikoma.tstyle(:accent) : Tachikoma.tstyle(:border)
    n = length(snap.testitems)
    title = " Tests ($n) "
    inner = Tachikoma.render(Tachikoma.Block(; title=title, border_style=border_style), area, buf)
    inner.height <= 0 && return

    visible_rows = inner.height
    # Ensure selected item is visible
    if selected > list_offset + visible_rows
        list_offset = selected - visible_rows
    end
    if selected <= list_offset
        list_offset = selected - 1
    end
    list_offset = max(list_offset, 0)

    for row_idx in 1:visible_rows
        item_idx = list_offset + row_idx
        item_idx > n && break

        item = snap.testitems[item_idx]
        y = inner.y + row_idx - 1

        is_selected = item_idx == selected
        icon = get(_STATUS_ICONS, item.status, "?")
        duration_str = if item.duration !== nothing
            _format_ms(item.duration)
        else
            ""
        end

        name_width = max(inner.width - 12, 10)
        name = length(item.name) > name_width ? item.name[1:name_width-1] * "…" : item.name

        row_style = if is_selected && focused
            Tachikoma.tstyle(:accent, bold=true)
        elseif is_selected
            Tachikoma.tstyle(:text, bold=true)
        elseif item.status == :passed
            Tachikoma.tstyle(:success)
        elseif item.status in (:failed, :errored)
            Tachikoma.tstyle(:error)
        elseif item.status == :skipped
            Tachikoma.tstyle(:text_dim)
        else
            Tachikoma.tstyle(:text)
        end

        icon_style = if item.status == :passed
            Tachikoma.tstyle(:success, bold=true)
        elseif item.status in (:failed, :errored)
            Tachikoma.tstyle(:error, bold=true)
        elseif item.status == :skipped
            Tachikoma.tstyle(:text_dim)
        else
            Tachikoma.tstyle(:text_dim)
        end

        # Selection marker
        marker = is_selected ? "▸ " : "  "
        Tachikoma.set_string!(buf, inner.x, y, marker, row_style)
        Tachikoma.set_string!(buf, inner.x + 2, y, icon * " ", icon_style)
        Tachikoma.set_string!(buf, inner.x + 4, y, name, row_style)
        if !isempty(duration_str)
            dur_x = inner.x + inner.width - length(duration_str)
            if dur_x > inner.x + 5
                Tachikoma.set_string!(buf, dur_x, y, duration_str, Tachikoma.tstyle(:text_dim))
            end
        end
    end

    # Scrollbar indicator if needed
    if n > visible_rows
        _draw_scrollbar!(buf, inner, list_offset, n, visible_rows)
    end
end

function _render_detail!(buf, area, snap, selected, detail_offset, focused)
    border_style = focused ? Tachikoma.tstyle(:accent) : Tachikoma.tstyle(:border)
    n = length(snap.testitems)

    if n == 0 || selected < 1 || selected > n
        # Show process overview
        inner = Tachikoma.render(Tachikoma.Block(; title=" Processes ", border_style=border_style), area, buf)
        _render_process_tree!(buf, inner, snap)
        return
    end

    item = snap.testitems[selected]
    title = " $(item.name) "
    inner = Tachikoma.render(Tachikoma.Block(; title=title, border_style=border_style), area, buf)
    inner.height <= 0 && return

    lines = String[]
    push!(lines, "Status: $(item.status)")
    if item.duration !== nothing
        push!(lines, "Duration: $(_format_ms(item.duration))")
    end
    push!(lines, "Profile: $(item.profile_name)")
    push!(lines, "URI: $(item.uri)")
    push!(lines, "")

    if !isempty(item.messages)
        push!(lines, "── Messages ──")
        for msg in item.messages
            for ml in split(msg, '\n')
                push!(lines, "  " * ml)
            end
        end
        push!(lines, "")
    end

    if !isempty(item.output)
        push!(lines, "── Output ──")
        for ol in split(item.output, '\n')
            push!(lines, "  " * ol)
        end
    end

    # Render with offset
    detail_offset = min(detail_offset, max(length(lines) - inner.height, 0))
    for row_idx in 1:inner.height
        line_idx = detail_offset + row_idx
        line_idx > length(lines) && break
        y = inner.y + row_idx - 1
        line = lines[line_idx]
        if length(line) > inner.width
            line = line[1:inner.width]
        end
        style = if startswith(line, "──")
            Tachikoma.tstyle(:primary, bold=true)
        elseif startswith(line, "Status: failed") || startswith(line, "Status: errored")
            Tachikoma.tstyle(:error)
        elseif startswith(line, "Status: passed")
            Tachikoma.tstyle(:success)
        else
            Tachikoma.tstyle(:text)
        end
        Tachikoma.set_string!(buf, inner.x, y, line, style)
    end

    if length(lines) > inner.height
        _draw_scrollbar!(buf, inner, detail_offset, length(lines), inner.height)
    end
end

function _render_process_tree!(buf, inner, snap)
    inner.height <= 0 && return
    y = inner.y
    n_procs = length(snap.processes)
    header = "Processes ($n_procs)"
    Tachikoma.set_string!(buf, inner.x, y, header, Tachikoma.tstyle(:primary, bold=true))
    y += 1

    for proc in snap.processes
        y > inner.y + inner.height - 1 && break
        status_style = if proc.status == "Running"
            Tachikoma.tstyle(:success)
        elseif proc.status == "Launching" || proc.status == "Activating"
            Tachikoma.tstyle(:warning)
        else
            Tachikoma.tstyle(:text_dim)
        end
        line = "  $(proc.package_name) [$(proc.status)]"
        if length(line) > inner.width
            line = line[1:inner.width]
        end
        Tachikoma.set_string!(buf, inner.x, y, line, status_style)
        y += 1
    end

    if n_procs == 0
        if y <= inner.y + inner.height - 1
            Tachikoma.set_string!(buf, inner.x + 2, y, "No processes yet", Tachikoma.tstyle(:text_dim))
        end
    end
end

function _render_output!(buf, area, snap, output_offset, following, focused)
    border_style = focused ? Tachikoma.tstyle(:accent) : Tachikoma.tstyle(:border)
    inner = Tachikoma.render(Tachikoma.Block(; title=" Process Output ", border_style=border_style), area, buf)
    inner.height <= 0 && return

    lines = snap.process_output_lines
    n = length(lines)
    visible = inner.height

    offset = if following
        max(n - visible, 0)
    else
        min(output_offset, max(n - visible, 0))
    end

    for row_idx in 1:visible
        line_idx = offset + row_idx
        line_idx > n && break
        y = inner.y + row_idx - 1
        line = lines[line_idx]
        if length(line) > inner.width
            line = line[1:inner.width]
        end
        Tachikoma.set_string!(buf, inner.x, y, line, Tachikoma.tstyle(:text))
    end

    if n > visible
        _draw_scrollbar!(buf, inner, offset, n, visible)
    end
end

function _render_footer!(buf, area, is_running)
    hints = if is_running
        [
            Tachikoma.Span("  [ESC] ", Tachikoma.tstyle(:accent)),
            Tachikoma.Span("detach  ", Tachikoma.tstyle(:text_dim)),
            Tachikoma.Span("[c] ", Tachikoma.tstyle(:accent)),
            Tachikoma.Span("cancel  ", Tachikoma.tstyle(:text_dim)),
            Tachikoma.Span("[Tab] ", Tachikoma.tstyle(:accent)),
            Tachikoma.Span("focus  ", Tachikoma.tstyle(:text_dim)),
            Tachikoma.Span("[↑↓] ", Tachikoma.tstyle(:accent)),
            Tachikoma.Span("navigate  ", Tachikoma.tstyle(:text_dim)),
            Tachikoma.Span("[1-3] ", Tachikoma.tstyle(:accent)),
            Tachikoma.Span("panel", Tachikoma.tstyle(:text_dim)),
        ]
    else
        [
            Tachikoma.Span("  [q/ESC] ", Tachikoma.tstyle(:accent)),
            Tachikoma.Span("exit  ", Tachikoma.tstyle(:text_dim)),
            Tachikoma.Span("[Tab] ", Tachikoma.tstyle(:accent)),
            Tachikoma.Span("focus  ", Tachikoma.tstyle(:text_dim)),
            Tachikoma.Span("[↑↓] ", Tachikoma.tstyle(:accent)),
            Tachikoma.Span("navigate  ", Tachikoma.tstyle(:text_dim)),
            Tachikoma.Span("[1-3] ", Tachikoma.tstyle(:accent)),
            Tachikoma.Span("panel", Tachikoma.tstyle(:text_dim)),
        ]
    end
    Tachikoma.render(Tachikoma.StatusBar(left=hints), area, buf)
end

# ── Utility helpers ───────────────────────────────────────────────────

function _format_duration(seconds::Float64)
    if seconds < 60
        return "$(round(seconds; digits=1))s"
    else
        m = floor(Int, seconds / 60)
        s = round(seconds - m * 60; digits=0)
        return "$(m)m $(Int(s))s"
    end
end

function _format_ms(ms::Float64)
    if ms < 1000
        return "$(round(Int, ms))ms"
    else
        return "$(_format_duration(ms / 1000))"
    end
end

function _draw_scrollbar!(buf, inner, offset, total, visible)
    total <= 0 && return
    bar_height = inner.height
    bar_height <= 0 && return
    thumb_height = max(1, round(Int, visible / total * bar_height))
    thumb_pos = round(Int, offset / max(total - visible, 1) * (bar_height - thumb_height))
    x = inner.x + inner.width - 1
    for i in 0:bar_height-1
        y = inner.y + i
        ch = if i >= thumb_pos && i < thumb_pos + thumb_height
            '█'
        else
            '░'
        end
        Tachikoma.set_char!(buf, x, y, ch, Tachikoma.tstyle(:text_dim))
    end
end

# ── Launch function ───────────────────────────────────────────────────

function launch_dashboard(state::DashboardState, cts::Union{Nothing,CancellationTokenSource};
                          on_stdout=nothing, on_stderr=nothing)
    model = TestRunDashboard(; state=state, cts=cts)
    kwargs = Dict{Symbol,Any}(
        :default_bindings => false,
        :fps => 30,
    )
    if on_stdout !== nothing
        kwargs[:on_stdout] = on_stdout
    end
    if on_stderr !== nothing
        kwargs[:on_stderr] = on_stderr
    end
    Tachikoma.app(model; kwargs...)
    return model
end
