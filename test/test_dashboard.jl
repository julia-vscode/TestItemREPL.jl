using Test
using Tachikoma
import Tachikoma: Frame, Buffer, Rect, KeyEvent, pre_render!

# Bring in TestItemREPL dashboard types
push!(LOAD_PATH, joinpath(@__DIR__, ".."))
using TestItemREPL: DashboardState, DashboardTestItem, DashboardProcess,
    DashboardLogEntry, TestRunDashboard, DashboardSnapshot,
    dashboard_push_testitem!, dashboard_update_process!,
    dashboard_remove_process!, dashboard_push_log_entry!,
    dashboard_push_process_line!, dashboard_set_completed!, snapshot

# CancellationTokens is re-exported through TestItemControllers
using TestItemREPL: CancellationTokenSource, cancel, get_token, is_cancellation_requested

# ── Helpers ───────────────────────────────────────────────────────────

function make_state(; n_total=5, run_id="test-run-1")
    DashboardState(run_id, n_total)
end

function make_model(state; cts=nothing)
    TestRunDashboard(; state=state, cts=cts)
end

function render_model(model; width=120, height=40)
    tb = TestBackend(width, height)
    pre_render!(model)
    rect = Rect(1, 1, width, height)
    f = Frame(tb.buf, rect, Tachikoma.GraphicsRegion[], Tachikoma.PixelSnapshot[])
    Tachikoma.view(model, f)
    tb
end

# ── DashboardState unit tests ────────────────────────────────────────

@testset "DashboardState construction" begin
    ds = make_state()
    @test ds.run_status == :running
    @test ds.n_total == 5
    @test ds.run_id == "test-run-1"
    @test ds.count_success == 0
    @test ds.count_fail == 0
    @test ds.count_error == 0
    @test ds.count_skipped == 0
    @test isempty(ds.testitems)
    @test isempty(ds.processes)
    @test isempty(ds.log_entries)
end

@testset "DashboardState no-arg constructor" begin
    ds = DashboardState()
    @test ds.run_id == ""
    @test ds.n_total == 0
    @test ds.run_status == :running
end

@testset "dashboard_push_testitem!" begin
    ds = make_state()
    item = DashboardTestItem("test_foo", "file:///test.jl", "Default", :running, nothing, String[], "")
    dashboard_push_testitem!(ds, item)
    @test length(ds.testitems) == 1
    @test ds.testitems[1].name == "test_foo"
    @test ds.testitems[1].status == :running
end

@testset "dashboard_update_process!" begin
    ds = make_state()
    # Add a new process
    dashboard_update_process!(ds, "proc-1", "MyPkg", "Launching")
    @test length(ds.processes) == 1
    @test ds.processes[1].id == "proc-1"
    @test ds.processes[1].package_name == "MyPkg"
    @test ds.processes[1].status == "Launching"

    # Update existing process
    dashboard_update_process!(ds, "proc-1", "MyPkg", "Running tests")
    @test length(ds.processes) == 1
    @test ds.processes[1].status == "Running tests"
end

@testset "dashboard_remove_process!" begin
    ds = make_state()
    dashboard_update_process!(ds, "proc-1", "MyPkg", "Running")
    dashboard_update_process!(ds, "proc-2", "OtherPkg", "Running")
    @test length(ds.processes) == 2

    dashboard_remove_process!(ds, "proc-1")
    @test length(ds.processes) == 1
    @test ds.processes[1].id == "proc-2"
end

@testset "dashboard_push_log_entry!" begin
    ds = make_state()
    entry1 = DashboardLogEntry("test_a", "Default", :passed, 100.0, "")
    entry2 = DashboardLogEntry("test_b", "Default", :failed, 200.0, "assertion failed")
    dashboard_push_log_entry!(ds, entry1)
    dashboard_push_log_entry!(ds, entry2)
    @test length(ds.log_entries) == 2
    @test ds.log_entries[1].name == "test_a"
    @test ds.log_entries[2].status == :failed
end

@testset "dashboard_push_log_entry! cap" begin
    ds = make_state()
    for i in 1:2100
        dashboard_push_log_entry!(ds, DashboardLogEntry("test_$i", "D", :passed, 10.0, ""))
    end
    @test length(ds.log_entries) <= 2000
    @test length(ds.log_entries) < 2100  # definitely trimmed
end

@testset "dashboard_push_process_line!" begin
    ds = make_state()
    dashboard_update_process!(ds, "proc-1", "MyPkg", "Running")
    dashboard_push_process_line!(ds, "proc-1", "Line 1")
    dashboard_push_process_line!(ds, "proc-1", "Line 2")
    @test length(ds.processes[1].output_lines) == 2
    @test ds.processes[1].output_lines[1] == "Line 1"
end

@testset "dashboard_push_process_line! cap" begin
    ds = make_state()
    dashboard_update_process!(ds, "proc-1", "MyPkg", "Running")
    for i in 1:2100
        dashboard_push_process_line!(ds, "proc-1", "Line $i")
    end
    @test length(ds.processes[1].output_lines) <= 2000
end

@testset "dashboard_set_completed!" begin
    ds = make_state()
    @test ds.run_status == :running
    @test ds.end_time === nothing

    dashboard_set_completed!(ds, :completed)
    @test ds.run_status == :completed
    @test ds.end_time !== nothing
end

@testset "snapshot" begin
    ds = make_state(; n_total=3)
    dashboard_push_testitem!(ds, DashboardTestItem("a", "", "Default", :passed, 100.0, String[], ""))
    ds.count_success = 1

    snap = snapshot(ds)
    @test snap isa DashboardSnapshot
    @test snap.run_id == "test-run-1"
    @test snap.n_total == 3
    @test snap.count_success == 1
    @test length(snap.testitems) == 1
    @test snap.testitems[1].name == "a"
end

# ── TestRunDashboard model tests ─────────────────────────────────────

@testset "model construction" begin
    ds = make_state()
    m = make_model(ds)
    @test m.quit == false
    @test m.focus == 2
    @test m.active_tab == 1
    @test m.tree_cursor == 1
    @test Tachikoma.should_quit(m) == false
end

@testset "update! ESC quits" begin
    ds = make_state()
    m = make_model(ds)
    Tachikoma.update!(m, KeyEvent(:escape))
    @test m.quit == true
    @test Tachikoma.should_quit(m) == true
end

@testset "update! Tab cycles focus" begin
    ds = make_state()
    m = make_model(ds)
    pre_render!(m)  # need snap for update
    @test m.focus == 2  # starts on left pane
    Tachikoma.update!(m, KeyEvent(:tab))
    @test m.focus == 3
    Tachikoma.update!(m, KeyEvent(:tab))
    @test m.focus == 1
    Tachikoma.update!(m, KeyEvent(:tab))
    @test m.focus == 2
end

@testset "update! number keys switch tabs" begin
    ds = make_state()
    m = make_model(ds)
    pre_render!(m)
    @test m.active_tab == 1
    Tachikoma.update!(m, KeyEvent('2'))
    @test m.active_tab == 2
    Tachikoma.update!(m, KeyEvent('1'))
    @test m.active_tab == 1
end

@testset "update! arrow keys navigate tree" begin
    ds = make_state(; n_total=3)
    for name in ["test_a", "test_b", "test_c"]
        dashboard_push_testitem!(ds, DashboardTestItem(name, "file:///src/test.jl", "Default", :passed, 50.0, String[], ""))
    end
    m = make_model(ds)
    m.focus = 2  # left pane (tree)
    m.active_tab = 1  # Tests tab
    pre_render!(m)  # builds tree_rows

    # tree_rows: dir row + 3 item rows = 4
    @test length(m.tree_rows) == 4
    @test m.tree_cursor == 1
    Tachikoma.update!(m, KeyEvent(:down))
    @test m.tree_cursor == 2
    Tachikoma.update!(m, KeyEvent(:down))
    @test m.tree_cursor == 3
    Tachikoma.update!(m, KeyEvent(:down))
    @test m.tree_cursor == 4
    Tachikoma.update!(m, KeyEvent(:down))
    @test m.tree_cursor == 4  # clamped
    Tachikoma.update!(m, KeyEvent(:up))
    @test m.tree_cursor == 3
end

@testset "update! q quits only when done" begin
    ds = make_state()
    m = make_model(ds)
    pre_render!(m)
    # While running, q should not quit
    Tachikoma.update!(m, KeyEvent('q'))
    @test m.quit == false

    # After completion, q should quit
    dashboard_set_completed!(ds, :completed)
    pre_render!(m)
    Tachikoma.update!(m, KeyEvent('q'))
    @test m.quit == true
end

@testset "update! c cancels run" begin
    cts = CancellationTokenSource()
    ds = make_state()
    m = make_model(ds; cts=cts)
    pre_render!(m)

    @test !is_cancellation_requested(get_token(cts))
    Tachikoma.update!(m, KeyEvent('c'))
    @test is_cancellation_requested(get_token(cts))
end

# ── Rendering tests ──────────────────────────────────────────────────

@testset "view renders header with status" begin
    ds = make_state()
    m = make_model(ds)
    tb = render_model(m)

    # Should find "Running" somewhere in the header
    pos = find_text(tb, "Running")
    @test pos !== nothing
end

@testset "view renders progress" begin
    ds = make_state(; n_total=10)
    ds.count_success = 3
    dashboard_push_testitem!(ds, DashboardTestItem("t1", "", "D", :passed, 100.0, String[], ""))
    dashboard_push_testitem!(ds, DashboardTestItem("t2", "", "D", :passed, 200.0, String[], ""))
    dashboard_push_testitem!(ds, DashboardTestItem("t3", "", "D", :passed, 150.0, String[], ""))

    m = make_model(ds)
    tb = render_model(m)

    # Should find progress info like "3/10" or "3 passed"
    found = find_text(tb, "3") !== nothing || find_text(tb, "passed") !== nothing
    @test found
end

@testset "view renders test items" begin
    ds = make_state(; n_total=2)
    dashboard_push_testitem!(ds, DashboardTestItem("my_test_alpha", "file:///src/test.jl", "Default", :passed, 100.0, String[], ""))
    dashboard_push_testitem!(ds, DashboardTestItem("my_test_beta", "file:///src/test.jl", "Default", :failed, 200.0, ["assertion failed"], ""))
    ds.count_success = 1
    ds.count_fail = 1

    m = make_model(ds)
    tb = render_model(m)

    @test find_text(tb, "my_test_alpha") !== nothing
    @test find_text(tb, "my_test_beta") !== nothing
end

@testset "view renders completed status" begin
    ds = make_state(; n_total=1)
    dashboard_push_testitem!(ds, DashboardTestItem("t1", "", "D", :passed, 50.0, String[], ""))
    ds.count_success = 1
    dashboard_set_completed!(ds, :completed)

    m = make_model(ds)
    tb = render_model(m)

    @test find_text(tb, "Completed") !== nothing
end

@testset "view renders footer keybindings" begin
    ds = make_state()
    m = make_model(ds)
    tb = render_model(m)

    # Footer should mention ESC
    @test find_text(tb, "ESC") !== nothing || find_text(tb, "Esc") !== nothing
end

@testset "view with log entries" begin
    ds = make_state()
    dashboard_push_log_entry!(ds, DashboardLogEntry("test_foo", "Default", :passed, 100.0, ""))

    m = make_model(ds)
    tb = render_model(m)

    # The log entry should appear somewhere
    @test find_text(tb, "test_foo") !== nothing
end

@testset "navigation changes detail view" begin
    ds = make_state(; n_total=2)
    dashboard_push_testitem!(ds, DashboardTestItem("first_test", "file:///src/test.jl", "Default", :passed, 100.0, String[], "some output text"))
    dashboard_push_testitem!(ds, DashboardTestItem("second_test", "file:///src/test.jl", "Default", :failed, 200.0, ["error msg"], ""))
    ds.count_success = 1
    ds.count_fail = 1

    m = make_model(ds)
    m.focus = 2  # left pane (tree)
    tb1 = render_model(m)

    # Navigate tree to second item (first row is dir, items start at row 2)
    Tachikoma.update!(m, KeyEvent(:down))
    Tachikoma.update!(m, KeyEvent(:down))
    tb2 = render_model(m)

    # The cursor should have moved
    @test m.tree_cursor >= 2
end
