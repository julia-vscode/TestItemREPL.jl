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

struct DashboardLogEntry
    name::String
    profile_name::String
    status::Symbol  # :passed, :failed, :errored, :skipped
    duration::Union{Nothing,Float64}  # milliseconds
    summary_message::String  # first error line for failures, empty otherwise
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
    log_entries::Vector{DashboardLogEntry}
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
        DashboardLogEntry[],
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

function dashboard_push_log_entry!(state::DashboardState, entry::DashboardLogEntry)
    lock(state.lock) do
        push!(state.log_entries, entry)
        if length(state.log_entries) > 2000
            deleteat!(state.log_entries, 1:length(state.log_entries) - 1500)
        end
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

function dashboard_push_process_line!(state::DashboardState, process_id::String, line::String)
    lock(state.lock) do
        idx = findfirst(p -> p.id == process_id, state.processes)
        if idx !== nothing
            push!(state.processes[idx].output_lines, line)
            if length(state.processes[idx].output_lines) > 2000
                deleteat!(state.processes[idx].output_lines, 1:length(state.processes[idx].output_lines) - 1500)
            end
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
    log_entries::Vector{DashboardLogEntry}
end

function snapshot(state::DashboardState)::DashboardSnapshot
    lock(state.lock) do
        # Deep copy processes so output_lines are independent
        procs = [DashboardProcess(p.id, p.package_name, p.status, copy(p.output_lines)) for p in state.processes]
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
            procs,
            copy(state.log_entries),
        )
    end
end

# ── Tree row type for filesystem tree ─────────────────────────────────

struct TreeRow
    indent::Int
    kind::Symbol  # :dir or :testitem
    label::String
    status::Symbol  # :none for dirs, test status for items
    expanded::Bool  # only meaningful for dirs
    duration::Union{Nothing,Float64}
    item_idx::Int  # index into snap.testitems, 0 for dirs
    dir_path::String  # full dir path for dirs, "" for items
    count_passed::Int  # summary counts for dirs
    count_total::Int
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
    # Active tab: 1=Tests, 2=Processes
    active_tab::Int = 1
    # Focused panel: 1=log, 2=left pane, 3=right pane
    focus::Int = 2
    # Log scroll
    log_offset::Int = 0
    log_following::Bool = true
    # Tree navigation (Tests tab, left pane)
    tree_cursor::Int = 1
    tree_offset::Int = 0
    tree_expanded::Set{String} = Set{String}()
    tree_rows::Vector{TreeRow} = TreeRow[]
    tree_initialized::Bool = false
    # Detail pane scroll (Tests tab, right pane)
    detail_offset::Int = 0
    # Process list selection (Processes tab, left pane)
    process_selected::Int = 1
    # Process output scroll (Processes tab, right pane)
    process_output_offset::Int = 0
    process_output_following::Bool = true
    # Cached snapshot for rendering
    snap::Union{Nothing,DashboardSnapshot} = nothing
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

    # Tab/Shift-Tab cycle focus: 1=log, 2=left pane, 3=right pane
    if evt.key == :tab
        m.focus = mod1(m.focus + 1, 3)
        return
    end
    if evt.key == :backtab
        m.focus = mod1(m.focus - 1, 3)
        return
    end

    # Number keys switch active tab
    if evt.key == :char && evt.char == '1'
        m.active_tab = 1
        return
    end
    if evt.key == :char && evt.char == '2'
        m.active_tab = 2
        return
    end

    # Delegate arrow keys to focused panel
    if m.focus == 1
        _handle_log_key!(m, evt)
    elseif m.focus == 2
        if m.active_tab == 1
            _handle_tree_key!(m, evt)
        else
            _handle_process_list_key!(m, evt)
        end
    elseif m.focus == 3
        if m.active_tab == 1
            _handle_detail_key!(m, evt)
        else
            _handle_process_output_key!(m, evt)
        end
    end
end

function _handle_log_key!(m::TestRunDashboard, evt::Tachikoma.KeyEvent)
    if evt.key == :down
        m.log_offset += 1
        m.log_following = false
    elseif evt.key == :up
        m.log_offset = max(m.log_offset - 1, 0)
        m.log_following = false
    elseif evt.key == :pagedown
        m.log_offset += 10
        m.log_following = false
    elseif evt.key == :pageup
        m.log_offset = max(m.log_offset - 10, 0)
        m.log_following = false
    elseif evt.key == :end_key
        m.log_following = true
    end
end

function _handle_tree_key!(m::TestRunDashboard, evt::Tachikoma.KeyEvent)
    n = length(m.tree_rows)
    n == 0 && return
    if evt.key == :down
        m.tree_cursor = min(m.tree_cursor + 1, n)
        m.detail_offset = 0
    elseif evt.key == :up
        m.tree_cursor = max(m.tree_cursor - 1, 1)
        m.detail_offset = 0
    elseif evt.key == :home
        m.tree_cursor = 1
        m.detail_offset = 0
    elseif evt.key == :end_key
        m.tree_cursor = n
        m.detail_offset = 0
    elseif evt.key == :pagedown
        m.tree_cursor = min(m.tree_cursor + 10, n)
        m.detail_offset = 0
    elseif evt.key == :pageup
        m.tree_cursor = max(m.tree_cursor - 10, 1)
        m.detail_offset = 0
    elseif evt.key == :enter || (evt.key == :char && evt.char == ' ')
        # Toggle expand/collapse on directory nodes
        if m.tree_cursor >= 1 && m.tree_cursor <= n
            row = m.tree_rows[m.tree_cursor]
            if row.kind == :dir
                if row.dir_path in m.tree_expanded
                    delete!(m.tree_expanded, row.dir_path)
                else
                    push!(m.tree_expanded, row.dir_path)
                end
            end
        end
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

function _handle_process_list_key!(m::TestRunDashboard, evt::Tachikoma.KeyEvent)
    snap = m.snap
    snap === nothing && return
    n = length(snap.processes)
    n == 0 && return
    if evt.key == :down
        m.process_selected = min(m.process_selected + 1, n)
        m.process_output_offset = 0
        m.process_output_following = true
    elseif evt.key == :up
        m.process_selected = max(m.process_selected - 1, 1)
        m.process_output_offset = 0
        m.process_output_following = true
    elseif evt.key == :home
        m.process_selected = 1
        m.process_output_offset = 0
        m.process_output_following = true
    elseif evt.key == :end_key
        m.process_selected = n
        m.process_output_offset = 0
        m.process_output_following = true
    end
end

function _handle_process_output_key!(m::TestRunDashboard, evt::Tachikoma.KeyEvent)
    if evt.key == :down
        m.process_output_offset += 1
        m.process_output_following = false
    elseif evt.key == :up
        m.process_output_offset = max(m.process_output_offset - 1, 0)
        m.process_output_following = false
    elseif evt.key == :pagedown
        m.process_output_offset += 10
        m.process_output_following = false
    elseif evt.key == :pageup
        m.process_output_offset = max(m.process_output_offset - 10, 0)
        m.process_output_following = false
    elseif evt.key == :end_key
        m.process_output_following = true
    end
end

# ── Tree construction ─────────────────────────────────────────────────

function _uri_to_relpath(uri::String)
    # Extract file path from URI and return a relative-ish path
    path = uri
    if startswith(path, "file:///")
        path = path[8:end]  # Remove file:///
    elseif startswith(path, "file://")
        path = path[7:end]
    end
    # Normalize path separators
    path = replace(path, '\\' => '/')
    # Try to make it relative by stripping common prefix
    # Just use the path as-is; the tree will group by directory components
    return path
end

function _build_tree_rows(snap::DashboardSnapshot, expanded::Set{String})
    # Group test items by directory
    dir_items = Dict{String,Vector{Int}}()  # dir_path => [item indices]
    for (idx, item) in enumerate(snap.testitems)
        path = _uri_to_relpath(item.uri)
        dir = _dirname(path)
        if !haskey(dir_items, dir)
            dir_items[dir] = Int[]
        end
        push!(dir_items[dir], idx)
    end

    rows = TreeRow[]

    # Sort directory paths
    sorted_dirs = sort(collect(keys(dir_items)))

    for dir in sorted_dirs
        items = dir_items[dir]
        # Count stats for this dir
        count_passed = count(i -> snap.testitems[i].status == :passed, items)
        count_total = length(items)
        is_expanded = dir in expanded

        dir_label = isempty(dir) ? "." : dir
        push!(rows, TreeRow(0, :dir, dir_label, :none, is_expanded, nothing, 0, dir,
                            count_passed, count_total))

        if is_expanded
            # Sort items alphabetically within directory
            sorted_items = sort(items; by=i -> snap.testitems[i].name)
            for item_idx in sorted_items
                item = snap.testitems[item_idx]
                push!(rows, TreeRow(1, :testitem, item.name, item.status, false,
                                    item.duration, item_idx, "", 0, 0))
            end
        end
    end

    return rows
end

function _dirname(path::String)
    idx = findlast(==('/'), path)
    idx === nothing && return ""
    return path[1:idx-1]
end

function _auto_expand_all!(expanded::Set{String}, snap::DashboardSnapshot)
    for item in snap.testitems
        path = _uri_to_relpath(item.uri)
        dir = _dirname(path)
        push!(expanded, dir)
    end
end

# ── Pre-render ────────────────────────────────────────────────────────

function Tachikoma.pre_render!(m::TestRunDashboard)
    m.tick += 1
    m.snap = snapshot(m.state)

    # Auto-expand all directories on first render
    if !m.tree_initialized && !isempty(m.snap.testitems)
        _auto_expand_all!(m.tree_expanded, m.snap)
        m.tree_initialized = true
    end

    # Also expand any new directories that appear
    for item in m.snap.testitems
        dir = _dirname(_uri_to_relpath(item.uri))
        if !(dir in m.tree_expanded) && !m.tree_initialized
            push!(m.tree_expanded, dir)
        end
    end

    # Build tree rows from snapshot
    m.tree_rows = _build_tree_rows(m.snap, m.tree_expanded)

    # Clamp cursors
    if !isempty(m.tree_rows)
        m.tree_cursor = clamp(m.tree_cursor, 1, length(m.tree_rows))
    end
    n_procs = length(m.snap.processes)
    if n_procs > 0
        m.process_selected = clamp(m.process_selected, 1, n_procs)
    end
end

# ── Main view ─────────────────────────────────────────────────────────

function Tachikoma.view(m::TestRunDashboard, f::Tachikoma.Frame)
    buf = f.buffer
    snap = m.snap
    snap === nothing && return

    is_running = snap.run_status == :running
    done = snap.count_success + snap.count_fail + snap.count_error + snap.count_skipped

    # ── Main layout: header(1) + progress(3) + log(6) + tab_bar(1) + body(fill) + footer(1)
    rows = Tachikoma.split_layout(
        Tachikoma.Layout(Tachikoma.Vertical, [
            Tachikoma.Fixed(1),   # header
            Tachikoma.Fixed(3),   # progress block
            Tachikoma.Fixed(8),   # log panel
            Tachikoma.Fixed(1),   # tab bar
            Tachikoma.Fill(),     # tabbed body
            Tachikoma.Fixed(1),   # footer
        ]),
        f.area,
    )
    length(rows) < 6 && return

    header_area = rows[1]
    progress_area = rows[2]
    log_area = rows[3]
    tab_bar_area = rows[4]
    body_area = rows[5]
    footer_area = rows[6]

    # ── Header
    _render_header!(buf, header_area, snap, is_running)

    # ── Progress
    _render_progress!(buf, progress_area, snap, done, m.tick)

    # ── Log
    _render_log!(buf, log_area, snap, m.log_offset, m.log_following, m.focus == 1)

    # ── Tab bar
    _render_tab_bar!(buf, tab_bar_area, m.active_tab, snap)

    # ── Body: depends on active tab
    if m.active_tab == 1
        # Tests tab: tree (40%) + detail (fill)
        body_cols = Tachikoma.split_layout(
            Tachikoma.Layout(Tachikoma.Horizontal, [Tachikoma.Percent(40), Tachikoma.Fill()]),
            body_area,
        )
        length(body_cols) >= 2 || return
        _render_tree!(buf, body_cols[1], m.tree_rows, m.tree_cursor, m.tree_offset, m.focus == 2)
        _render_detail!(buf, body_cols[2], snap, m.tree_rows, m.tree_cursor, m.detail_offset, m.focus == 3)
    else
        # Processes tab: process list (30%) + process output (fill)
        body_cols = Tachikoma.split_layout(
            Tachikoma.Layout(Tachikoma.Horizontal, [Tachikoma.Percent(30), Tachikoma.Fill()]),
            body_area,
        )
        length(body_cols) >= 2 || return
        _render_process_list!(buf, body_cols[1], snap, m.process_selected, m.focus == 2)
        _render_process_output!(buf, body_cols[2], snap, m.process_selected,
                                m.process_output_offset, m.process_output_following, m.focus == 3)
    end

    # ── Footer
    _render_footer!(buf, footer_area, is_running, m.active_tab, m.focus)
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

# ── Log panel ─────────────────────────────────────────────────────────

function _render_log!(buf, area, snap, log_offset, log_following, focused)
    border_style = focused ? Tachikoma.tstyle(:accent) : Tachikoma.tstyle(:border)
    n = length(snap.log_entries)
    title = " Log ($n) "
    inner = Tachikoma.render(Tachikoma.Block(; title=title, border_style=border_style), area, buf)
    inner.height <= 0 && return

    visible = inner.height
    offset = if log_following
        max(n - visible, 0)
    else
        clamp(log_offset, 0, max(n - visible, 0))
    end

    for row_idx in 1:visible
        entry_idx = offset + row_idx
        entry_idx > n && break

        entry = snap.log_entries[entry_idx]
        y = inner.y + row_idx - 1

        icon = get(_STATUS_ICONS, entry.status, "?")
        icon_style = if entry.status == :passed
            Tachikoma.tstyle(:success, bold=true)
        elseif entry.status in (:failed, :errored)
            Tachikoma.tstyle(:error, bold=true)
        else
            Tachikoma.tstyle(:text_dim)
        end

        duration_str = entry.duration !== nothing ? " ($(_format_ms(entry.duration)))" : ""
        profile_str = " [$(entry.profile_name)]"
        main_text = "$(entry.name)$(profile_str)$(duration_str)"

        text_style = if entry.status == :passed
            Tachikoma.tstyle(:success)
        elseif entry.status in (:failed, :errored)
            Tachikoma.tstyle(:error)
        else
            Tachikoma.tstyle(:text_dim)
        end

        Tachikoma.set_string!(buf, inner.x, y, "$icon ", icon_style)
        avail = inner.width - 2
        if !isempty(entry.summary_message)
            msg_text = " — $(entry.summary_message)"
            full_text = main_text * msg_text
            if length(full_text) > avail
                full_text = full_text[1:min(avail, length(full_text))]
            end
            Tachikoma.set_string!(buf, inner.x + 2, y, main_text, text_style)
            msg_x = inner.x + 2 + length(main_text)
            if msg_x < inner.x + inner.width
                msg_avail = inner.x + inner.width - msg_x
                msg_display = length(msg_text) > msg_avail ? msg_text[1:msg_avail] : msg_text
                Tachikoma.set_string!(buf, msg_x, y, msg_display, Tachikoma.tstyle(:text_dim))
            end
        else
            display_text = length(main_text) > avail ? main_text[1:avail] : main_text
            Tachikoma.set_string!(buf, inner.x + 2, y, display_text, text_style)
        end
    end

    if n > visible
        _draw_scrollbar!(buf, inner, offset, n, visible)
    end
end

# ── Tab bar ───────────────────────────────────────────────────────────

function _render_tab_bar!(buf, area, active_tab, snap)
    has_failures = snap.count_fail > 0 || snap.count_error > 0
    n_procs = length(snap.processes)

    # Build tab labels
    tests_label = "Tests"
    if has_failures
        tests_label *= " ●"
    end
    procs_label = "Processes ($n_procs)"

    x = area.x + 1

    # Tab 1: Tests
    tab1_text = " 1:$tests_label "
    if active_tab == 1
        Tachikoma.set_string!(buf, x, area.y, tab1_text, Tachikoma.tstyle(:accent, bold=true))
    else
        style = has_failures ? Tachikoma.tstyle(:error) : Tachikoma.tstyle(:text_dim)
        Tachikoma.set_string!(buf, x, area.y, tab1_text, style)
    end
    x += length(tab1_text) + 1

    # Tab 2: Processes
    tab2_text = " 2:$procs_label "
    if active_tab == 2
        Tachikoma.set_string!(buf, x, area.y, tab2_text, Tachikoma.tstyle(:accent, bold=true))
    else
        Tachikoma.set_string!(buf, x, area.y, tab2_text, Tachikoma.tstyle(:text_dim))
    end
end

# ── Tree panel (Tests tab, left) ─────────────────────────────────────

function _render_tree!(buf, area, tree_rows, tree_cursor, tree_offset, focused)
    border_style = focused ? Tachikoma.tstyle(:accent) : Tachikoma.tstyle(:border)
    n = length(tree_rows)
    n_items = count(r -> r.kind == :testitem, tree_rows)
    title = " Test Items ($n_items) "
    inner = Tachikoma.render(Tachikoma.Block(; title=title, border_style=border_style), area, buf)
    inner.height <= 0 && return

    visible_rows = inner.height

    # Ensure cursor is visible
    if tree_cursor > tree_offset + visible_rows
        tree_offset = tree_cursor - visible_rows
    end
    if tree_cursor <= tree_offset
        tree_offset = tree_cursor - 1
    end
    tree_offset = max(tree_offset, 0)

    for row_idx in 1:visible_rows
        idx = tree_offset + row_idx
        idx > n && break

        row = tree_rows[idx]
        y = inner.y + row_idx - 1
        is_cursor = idx == tree_cursor
        indent_str = repeat("  ", row.indent)

        if row.kind == :dir
            # Directory node
            expand_icon = row.expanded ? "▾ " : "▸ "
            suffix = " ($(row.count_passed)/$(row.count_total))"
            text = indent_str * expand_icon * row.label * suffix

            style = if is_cursor && focused
                Tachikoma.tstyle(:accent, bold=true)
            elseif is_cursor
                Tachikoma.tstyle(:text, bold=true)
            else
                Tachikoma.tstyle(:primary)
            end

            if length(text) > inner.width
                text = text[1:inner.width]
            end
            Tachikoma.set_string!(buf, inner.x, y, text, style)
        else
            # Test item node
            icon = get(_STATUS_ICONS, row.status, "?")
            icon_style = if row.status == :passed
                Tachikoma.tstyle(:success, bold=true)
            elseif row.status in (:failed, :errored)
                Tachikoma.tstyle(:error, bold=true)
            elseif row.status == :skipped
                Tachikoma.tstyle(:text_dim)
            else
                Tachikoma.tstyle(:text_dim)
            end

            row_style = if is_cursor && focused
                Tachikoma.tstyle(:accent, bold=true)
            elseif is_cursor
                Tachikoma.tstyle(:text, bold=true)
            elseif row.status == :passed
                Tachikoma.tstyle(:success)
            elseif row.status in (:failed, :errored)
                Tachikoma.tstyle(:error)
            elseif row.status == :skipped
                Tachikoma.tstyle(:text_dim)
            else
                Tachikoma.tstyle(:text)
            end

            duration_str = row.duration !== nothing ? _format_ms(row.duration) : ""
            name_avail = max(inner.width - length(indent_str) - 4 - length(duration_str) - 1, 5)
            name = length(row.label) > name_avail ? row.label[1:name_avail-1] * "…" : row.label

            # Marker
            marker = is_cursor ? "▸ " : "  "
            prefix = indent_str * marker
            Tachikoma.set_string!(buf, inner.x, y, prefix, row_style)
            Tachikoma.set_string!(buf, inner.x + length(prefix), y, icon * " ", icon_style)
            Tachikoma.set_string!(buf, inner.x + length(prefix) + 2, y, name, row_style)

            if !isempty(duration_str)
                dur_x = inner.x + inner.width - length(duration_str)
                if dur_x > inner.x + length(prefix) + 3
                    Tachikoma.set_string!(buf, dur_x, y, duration_str, Tachikoma.tstyle(:text_dim))
                end
            end
        end
    end

    if n > visible_rows
        _draw_scrollbar!(buf, inner, tree_offset, n, visible_rows)
    end
end

# ── Detail panel (Tests tab, right) ──────────────────────────────────

function _render_detail!(buf, area, snap, tree_rows, tree_cursor, detail_offset, focused)
    border_style = focused ? Tachikoma.tstyle(:accent) : Tachikoma.tstyle(:border)

    # Determine what to show based on tree cursor
    if isempty(tree_rows) || tree_cursor < 1 || tree_cursor > length(tree_rows)
        inner = Tachikoma.render(Tachikoma.Block(; title=" Detail ", border_style=border_style), area, buf)
        inner.height > 0 && Tachikoma.set_string!(buf, inner.x + 1, inner.y, "No selection", Tachikoma.tstyle(:text_dim))
        return
    end

    row = tree_rows[tree_cursor]

    if row.kind == :dir
        # Show directory summary
        title = " $(row.label) "
        inner = Tachikoma.render(Tachikoma.Block(; title=title, border_style=border_style), area, buf)
        inner.height <= 0 && return

        lines = String[]
        push!(lines, "Directory: $(row.label)")
        push!(lines, "Total: $(row.count_total) test items")
        push!(lines, "Passed: $(row.count_passed)")
        failed_count = 0
        errored_count = 0
        running_count = 0
        pending_count = 0
        skipped_count = 0
        # Count from testitems matching this dir
        for item in snap.testitems
            dir = _dirname(_uri_to_relpath(item.uri))
            if dir == row.dir_path
                if item.status == :failed
                    failed_count += 1
                elseif item.status == :errored
                    errored_count += 1
                elseif item.status == :running
                    running_count += 1
                elseif item.status == :pending
                    pending_count += 1
                elseif item.status == :skipped
                    skipped_count += 1
                end
            end
        end
        failed_count > 0 && push!(lines, "Failed: $failed_count")
        errored_count > 0 && push!(lines, "Errored: $errored_count")
        running_count > 0 && push!(lines, "Running: $running_count")
        pending_count > 0 && push!(lines, "Pending: $pending_count")
        skipped_count > 0 && push!(lines, "Skipped: $skipped_count")

        for (i, line) in enumerate(lines)
            i > inner.height && break
            y = inner.y + i - 1
            display_line = length(line) > inner.width ? line[1:inner.width] : line
            style = if startswith(line, "Directory:")
                Tachikoma.tstyle(:primary, bold=true)
            elseif startswith(line, "Failed:") || startswith(line, "Errored:")
                Tachikoma.tstyle(:error)
            elseif startswith(line, "Passed:")
                Tachikoma.tstyle(:success)
            else
                Tachikoma.tstyle(:text)
            end
            Tachikoma.set_string!(buf, inner.x, y, display_line, style)
        end
        return
    end

    # Test item detail
    item_idx = row.item_idx
    if item_idx < 1 || item_idx > length(snap.testitems)
        inner = Tachikoma.render(Tachikoma.Block(; title=" Detail ", border_style=border_style), area, buf)
        return
    end

    item = snap.testitems[item_idx]
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

# ── Process list panel (Processes tab, left) ──────────────────────────

function _render_process_list!(buf, area, snap, process_selected, focused)
    border_style = focused ? Tachikoma.tstyle(:accent) : Tachikoma.tstyle(:border)
    n = length(snap.processes)
    title = " Processes ($n) "
    inner = Tachikoma.render(Tachikoma.Block(; title=title, border_style=border_style), area, buf)
    inner.height <= 0 && return

    if n == 0
        Tachikoma.set_string!(buf, inner.x + 1, inner.y, "No processes", Tachikoma.tstyle(:text_dim))
        return
    end

    visible_rows = inner.height
    for row_idx in 1:min(visible_rows, n)
        proc = snap.processes[row_idx]
        y = inner.y + row_idx - 1
        is_selected = row_idx == process_selected

        status_style = if proc.status == "Running"
            Tachikoma.tstyle(:success)
        elseif proc.status == "Launching" || proc.status == "Activating"
            Tachikoma.tstyle(:warning)
        else
            Tachikoma.tstyle(:text_dim)
        end

        row_style = if is_selected && focused
            Tachikoma.tstyle(:accent, bold=true)
        elseif is_selected
            Tachikoma.tstyle(:text, bold=true)
        else
            status_style
        end

        marker = is_selected ? "▸ " : "  "
        text = "$(proc.package_name) [$(proc.status)]"
        if length(marker) + length(text) > inner.width
            text = text[1:max(inner.width - length(marker), 1)]
        end
        Tachikoma.set_string!(buf, inner.x, y, marker, row_style)
        Tachikoma.set_string!(buf, inner.x + length(marker), y, text, row_style)
    end

    if n > visible_rows
        _draw_scrollbar!(buf, inner, 0, n, visible_rows)
    end
end

# ── Process output panel (Processes tab, right) ──────────────────────

function _render_process_output!(buf, area, snap, process_selected, output_offset, following, focused)
    border_style = focused ? Tachikoma.tstyle(:accent) : Tachikoma.tstyle(:border)
    n_procs = length(snap.processes)

    if n_procs == 0 || process_selected < 1 || process_selected > n_procs
        inner = Tachikoma.render(Tachikoma.Block(; title=" Output ", border_style=border_style), area, buf)
        inner.height > 0 && Tachikoma.set_string!(buf, inner.x + 1, inner.y,
            "Select a process to view its output", Tachikoma.tstyle(:text_dim))
        return
    end

    proc = snap.processes[process_selected]
    title = " Output: $(proc.package_name) "
    inner = Tachikoma.render(Tachikoma.Block(; title=title, border_style=border_style), area, buf)
    inner.height <= 0 && return

    lines = proc.output_lines
    n = length(lines)
    visible = inner.height

    offset = if following
        max(n - visible, 0)
    else
        clamp(output_offset, 0, max(n - visible, 0))
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

# ── Footer ────────────────────────────────────────────────────────────

function _render_footer!(buf, area, is_running, active_tab, focus)
    hints = Tachikoma.Span[]

    if is_running
        push!(hints, Tachikoma.Span("  [ESC] ", Tachikoma.tstyle(:accent)))
        push!(hints, Tachikoma.Span("detach  ", Tachikoma.tstyle(:text_dim)))
        push!(hints, Tachikoma.Span("[c] ", Tachikoma.tstyle(:accent)))
        push!(hints, Tachikoma.Span("cancel  ", Tachikoma.tstyle(:text_dim)))
    else
        push!(hints, Tachikoma.Span("  [q/ESC] ", Tachikoma.tstyle(:accent)))
        push!(hints, Tachikoma.Span("exit  ", Tachikoma.tstyle(:text_dim)))
    end

    push!(hints, Tachikoma.Span("[Tab] ", Tachikoma.tstyle(:accent)))
    push!(hints, Tachikoma.Span("focus  ", Tachikoma.tstyle(:text_dim)))
    push!(hints, Tachikoma.Span("[1-2] ", Tachikoma.tstyle(:accent)))
    push!(hints, Tachikoma.Span("tab  ", Tachikoma.tstyle(:text_dim)))
    push!(hints, Tachikoma.Span("[↑↓] ", Tachikoma.tstyle(:accent)))
    push!(hints, Tachikoma.Span("navigate  ", Tachikoma.tstyle(:text_dim)))

    if focus == 2 && active_tab == 1
        push!(hints, Tachikoma.Span("[Enter] ", Tachikoma.tstyle(:accent)))
        push!(hints, Tachikoma.Span("expand  ", Tachikoma.tstyle(:text_dim)))
    end
    if focus == 3 || focus == 1
        push!(hints, Tachikoma.Span("[End] ", Tachikoma.tstyle(:accent)))
        push!(hints, Tachikoma.Span("follow  ", Tachikoma.tstyle(:text_dim)))
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
