#!/usr/bin/env bash
# test-menu.sh: tests for bin/afc-menu — verifies all ACF command shortcuts, section grouping,
# scrolling, direct hotkey dispatch, context-aware Council / Alt+Q actions, and rendering.
# Touches nothing of the live fleet.
#
#   bash _tools/test-menu.sh
set -euo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
MENU="$HERE/bin/afc-menu"

python3 - "$MENU" <<'PY'
import importlib.machinery
import importlib.util
import io
import sys
from unittest import mock

menu_path = sys.argv[1]
loader = importlib.machinery.SourceFileLoader("afc_menu_mod", menu_path)
spec = importlib.util.spec_from_loader("afc_menu_mod", loader)
mod = importlib.util.module_from_spec(spec)
loader.exec_module(mod)

passed = 0
failed = 0


def check(name, cond, detail=""):
    global passed, failed
    if cond:
        passed += 1
        print(f"  ok    {name}")
    else:
        failed += 1
        print(f"  FAIL  {name}" + (f" ({detail})" if detail else ""))


ctx = {
    "sock": "/tmp/fake-tmux.sock",
    "client": "/dev/pts/9",
    "win": "@1",
    "pane": "%5",
    "pid": "12345",
    "cwd": "/tmp/my-project",
    "session": "agents",
}

print(f"ACF menu checks for {menu_path}")

# 1. All fleet shortcuts are present in Commands tab
cmds = mod.build_commands(ctx)
keys = {c["key"] for c in cmds}
expected_keys = {
    "Alt+G", "Alt+M", "Alt+L", "Alt+E",
    "Alt+K", "Alt+Shift+K", "⚙ /settings", "Alt+A", "Alt+O / Alt+0", "Alt+T", "Alt+P",
    "Shift+Tab", "Alt+M / m", "Meta+Alt+R", "Meta+Alt+Q", "Ctrl+C", "Ctrl+D",
    "Alt+\\", "Alt+-", "Alt+W", "Alt+J", "Alt+H", "Alt+U", "Alt+Z", "Alt+Q", "Alt+S", "Alt+X",
    "Ctrl+B %", 'Ctrl+B "',
    "Alt+N", "Alt+C", "Alt+1..0", "Ctrl+B p", "Ctrl+B n", "Meta+Esc", "Meta+A",
    "Ctrl+V", "Alt+V", "Ctrl+Click", "Ctrl+T", "Ctrl+O",
    "Ctrl+B r", "Ctrl+B <", "Ctrl+B >",
}
missing = expected_keys - keys
check("every ACF shortcut key is listed in Commands tab", not missing, f"missing={sorted(missing)}")
check("no command key exceeds 14 chars (fits key column cleanly)", all(len(c["key"]) <= 14 for c in cmds))
check("no command name exceeds 23 chars (fits name column cleanly)", all(len(c["name"]) <= 23 for c in cmds))

# 2. Sections structure & Council immediate visibility
sections = mod.build_command_sections(ctx)
sec_names = [s[0] for s in sections]
check("commands are organized into 6 logical sections with Council immediately at #2",
      len(sections) == 6 and sec_names[1] == "Council (Multi-LLM)", f"got={sec_names}")
council_sections_when_in = [s[0] for s in mod.build_command_sections(ctx, {
    "council_chat": True, "council_member": False, "council_one": False,
    "council_perm_judge": False, "council_name": "", "council_what": "",
    "council_chair": "%5", "window_panes": 2, "project": "",
    "win_council": True, "in_council": True, "chair_target": "%5",
})]
check("inside a Council tab, Council section is promoted to #1",
      council_sections_when_in[0] == "Council (Multi-LLM)", f"got={council_sections_when_in}")

# 3. Context-aware Alt+Q close command
normal_pctx = {
    "council_chat": False, "council_member": False, "council_one": False,
    "council_perm_judge": False, "council_name": "", "council_what": "",
    "council_chair": "", "window_panes": 2, "project": "Demo",
    "win_council": False, "in_council": False, "chair_target": "",
}
q_normal = [c for c in mod.build_commands(ctx, normal_pctx) if c["key"] == "Alt+Q"][0]["cmd"]
check("Alt+Q on multi-pane split enables Minimise option", "Minimise it instead" in q_normal and "-Minimise it instead" not in q_normal)

single_proj_pctx = dict(normal_pctx, window_panes=1)
q_single = [c for c in mod.build_commands(ctx, single_proj_pctx) if c["key"] == "Alt+Q"][0]["cmd"]
check("Alt+Q on single-pane project warns closing project & disables Minimise",
      "Close Demo for good" in q_single and "-Minimise it instead" in q_single)

council_one_pctx = dict(normal_pctx, council_one=True, in_council=True)
q_one = [c for c in mod.build_commands(ctx, council_one_pctx) if c["key"] == "Alt+Q"][0]["cmd"]
check("Alt+Q on council one-view invokes --one-menu", "--one-menu" in q_one)

judge_pctx = dict(normal_pctx, council_perm_judge=True, council_name="supra-omnia", in_council=True)
q_judge = [c for c in mod.build_commands(ctx, judge_pctx) if c["key"] == "Alt+Q"][0]["cmd"]
check("Alt+Q on permanent judge shows judge settings menu", "permanent final judge" in q_judge and "bp_role:JUDGE" in q_judge)

# 4. Context-aware Council commands (outside vs inside council)
council_ctx_cmds = {c["key"]: c for c in mod.build_commands(ctx, normal_pctx)}
check("outside council, Council settings shows helpful hint instead of dead command",
      council_ctx_cmds["⚙ /settings"]["cmd"] is None and "Alt+K" in council_ctx_cmds["⚙ /settings"]["hint"])

in_council_pctx = dict(normal_pctx, council_member=True, council_chair="%9", in_council=True, chair_target="%9")
council_live_cmds = {c["key"]: c for c in mod.build_commands(ctx, in_council_pctx)}
check("inside council, Council settings runs --open-settings",
      "--open-settings" in (council_live_cmds["⚙ /settings"]["cmd"] or ""))
check("inside council, Alt+A runs --add-menu",
      "--add-menu" in (council_live_cmds["Alt+A"]["cmd"] or ""))
check("inside council, Alt+O / Alt+0 sends M-o to council chair",
      "send-keys -t %9 M-o" in (council_live_cmds["Alt+O / Alt+0"]["cmd"] or ""))
check("inside council, Alt+M / m runs afc-model-menu",
      "afc-model-menu" in (council_live_cmds["Alt+M / m"]["cmd"] or ""))
check("inside council, Ctrl+C sends C-c to council chair",
      "send-keys -t %9 C-c" in (council_live_cmds["Ctrl+C"]["cmd"] or ""))
check("inside council, Ctrl+D sends C-d to council chair",
      "send-keys -t %9 C-d" in (council_live_cmds["Ctrl+D"]["cmd"] or ""))
check("inside council, Meta+Alt+R runs --restart-wipe",
      "--restart-wipe" in (council_live_cmds["Meta+Alt+R"]["cmd"] or ""))
check("inside council, Meta+Alt+Q runs --end-all",
      "--end-all" in (council_live_cmds["Meta+Alt+Q"]["cmd"] or ""))


def make_app(pctx_override=None):
    with mock.patch.object(mod, "load_pane_context", return_value=pctx_override or normal_pctx), \
         mock.patch.object(mod, "load_sessions", return_value=[]), \
         mock.patch.object(mod, "load_settings", return_value={}), \
         mock.patch.object(mod, "read_cgroup_summary", return_value={}), \
         mock.patch.object(mod, "load_about", return_value={
             "branch": "main", "commit": "abc", "tmux_v": "tmux 3.8",
             "autonice": "active", "cg": {}, "providers": [], "win_cnt": 1, "pane_cnt": 1
         }), \
         mock.patch.object(mod, "run_out", return_value="active"):
        return mod.MenuApp(ctx)


# 5. Direct hotkey dispatch inside Commands tab
app = make_app()
app.handle_key("\x1bm")  # Alt+M
check("pressing Alt+M inside Commands tab runs model menu immediately",
      not app.running and "afc-model-menu" in (app.pending_cmd or ""))

app = make_app()
app.handle_key("\x1bq")  # Alt+Q
check("pressing Alt+Q inside Commands tab runs close confirmation menu",
      not app.running and "display-menu" in (app.pending_cmd or ""))

app = make_app()
app.handle_key("\x16")  # Ctrl+V
check("pressing Ctrl+V inside Commands tab runs smart paste",
      not app.running and "--paste" in (app.pending_cmd or ""))

app = make_app()
app.handle_key("\x1b3")  # Alt+3
check("pressing Alt+3 inside Commands tab selects window 3",
      not app.running and "select-window -t agents:=3" in (app.pending_cmd or ""))

app = make_app(in_council_pctx)
app.handle_key("\x1b0")  # Alt+0 inside council
check("pressing Alt+0 inside council toggles council view (M-o)",
      not app.running and "send-keys -t %9 M-o" in (app.pending_cmd or ""))

app = make_app(in_council_pctx)
app.handle_key("\x1b[98~")  # Meta+Alt+Q inside council
check("pressing Meta+Alt+Q inside council runs --end-all",
      not app.running and "--end-all" in (app.pending_cmd or ""))

app = make_app(normal_pctx)
app.handle_key("\x1ba")  # Alt+A outside council
check("pressing Alt+A outside council stays open and shows council hint",
      app.running and "Council only" in app.status_msg)

# 6. Meta+Esc and Alt+Esc toggle close
app = make_app()
app.handle_key("\x1b[99~")
check("Meta+Esc closes the menu cleanly", not app.running and app.pending_cmd is None)

app = make_app()
app.handle_key("\x1b\x1b")
check("Alt+Esc closes the menu cleanly", not app.running and app.pending_cmd is None)

# 7. Scrolling, PgDn/PgUp/Home/End, and rendering at 84x32 & 60x20
app = make_app()
for dims in ((84, 32), (60, 20)):
    with mock.patch.object(mod, "get_term_size", return_value=dims):
        buf = io.StringIO()
        with mock.patch.object(sys, "stdout", buf):
            app.sel[0] = 0
            app.scroll[0] = 0
            app.render()
            first_screen = buf.getvalue()
            first_row_is_header = app.command_rows[app.scroll[0]][0] == "header"
            header_rows = {
                3 + (d_idx - app.scroll[0])
                for d_idx in range(app.scroll[0], min(len(app.command_rows), app.scroll[0] + (dims[1] - 4)))
                if app.command_rows[d_idx][0] == "header"
            }
            mapped_keys = set(app.row_map.keys())
            app.handle_key("\x1b[6~")  # PageDown
            app.render()
            after_pgdn = app.sel[0]
            app.handle_key("\x1b[F")   # End
            app.render()
            at_end = app.sel[0] == len(app.commands) - 1
            app.handle_key("\x1b[H")   # Home
            app.render()
            at_home = app.sel[0] == 0 and app.scroll[0] == 0
        check(f"render {dims[0]}x{dims[1]} shows top section header and never maps headers as clickable",
              first_row_is_header and not (header_rows & mapped_keys))
        if dims == (84, 32):
            council_keys = [
                "Alt+K", "Alt+Shift+K", "⚙ /settings", "Alt+A", "Alt+O / Alt+0",
                "Alt+T", "Alt+P", "Shift+Tab", "Alt+M / m", "Meta+Alt+R",
                "Meta+Alt+Q", "Ctrl+C", "Ctrl+D",
            ]
            missing_vis = [k for k in council_keys if k not in first_screen]
            check("all 13 Council shortcuts are visible immediately on first open at 84x32",
                  not missing_vis, f"not visible={missing_vis}")
        check(f"PgDn/End/Home navigation works cleanly at {dims[0]}x{dims[1]}",
              after_pgdn > 0 and at_end and at_home)

# 8. History tab: multi-project acf.db loading, filtering, search, inspector, resume & rendering
import json
import os
import sqlite3
import tempfile

check("History tab is registered as tab #3 in TABS",
      mod.TABS == ["Commands", "Sessions", "History", "Config", "About"], f"got={mod.TABS}")

with tempfile.TemporaryDirectory(prefix="afc-menu-hist-") as tmp:
    proj_a = os.path.join(tmp, "$$AFocus", "AlphaApp")
    proj_b = os.path.join(tmp, "BetaService")
    os.makedirs(os.path.join(proj_a, "logs", "acf"), exist_ok=True)
    os.makedirs(os.path.join(proj_b, "logs", "acf"), exist_ok=True)

    gem_src = os.path.join(tmp, "session-2026-11-24T03-16-2d813e72.jsonl")
    with open(gem_src, "w", encoding="utf-8") as gf:
        gf.write(json.dumps({"sessionId": "2d813e72-a44d-43cb-891f-4fd79ade7be5"}) + "\n")

    def init_db(db_path, threads, entries):
        db = sqlite3.connect(db_path)
        db.executescript("""
            CREATE TABLE threads (
              id TEXT PRIMARY KEY, tool TEXT, account TEXT, cwd TEXT, title TEXT, parent TEXT,
              first_ts TEXT, last_ts TEXT, models TEXT, cost_usd REAL, tokens_in INTEGER, tokens_out INTEGER,
              md_file TEXT, source TEXT);
            CREATE TABLE entries (
              id INTEGER PRIMARY KEY, thread TEXT, ts TEXT, kind TEXT, who TEXT, model TEXT, text TEXT, hash TEXT);
            CREATE TABLE usage (
              thread TEXT, msg TEXT, model TEXT, input INTEGER, output INTEGER, cache_read INTEGER, cache_write INTEGER,
              PRIMARY KEY (thread, msg));
        """)
        db.executemany("INSERT INTO threads VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?)", threads)
        db.executemany("INSERT INTO entries (thread, ts, kind, who, model, text, hash) VALUES (?,?,?,?,?,?,?)", entries)
        db.commit()
        db.close()

    init_db(
        os.path.join(proj_a, "logs", "acf", "acf.db"),
        [
            ("claude:11111111-aaaa-bbbb-cccc-000000000001", "claude", "nick", proj_a,
             "Fix checkout race condition", None, "2026-11-24T10:00:00Z", "2026-11-24T12:30:00Z",
             "claude-opus-5-5", 12.45, 50000, 8000, None, ""),
            ("claude:sub-1@11111111", "claude", "nick", proj_a,
             "Subagent helper (should be hidden)", "claude:11111111-aaaa-bbbb-cccc-000000000001",
             "2026-11-24T11:00:00Z", "2026-11-24T11:05:00Z", "claude-sonnet", None, None, None, None, ""),
        ],
        [
            ("claude:11111111-aaaa-bbbb-cccc-000000000001", "2026-11-24T10:00:00Z", "user", None, None,
             "Please fix the checkout race condition.", None),
            ("claude:11111111-aaaa-bbbb-cccc-000000000001", "2026-11-24T10:01:00Z", "tool_call", "Read", "claude-opus-5-5",
             '{"file_path": "checkout.py"}', None),
            ("claude:11111111-aaaa-bbbb-cccc-000000000001", "2026-11-24T10:02:00Z", "assistant", None, "claude-opus-5-5",
             "Added a row-level lock around inventory reservation.", None),
        ],
    )
    init_db(
        os.path.join(proj_b, "logs", "acf", "acf.db"),
        [
            ("gemini:session-2026-11-24T03-16-2d813e72", "gemini", "main", proj_b,
             "Audit BetaService webhooks", None, "2026-11-24T14:00:00Z", "2026-11-24T15:00:00Z",
             "gemini-3-pro", None, 12000, 3000, None, gem_src),
            ("codex:22222222-dddd-eeee-ffff-000000000002", "codex", "work", proj_b,
             "Refactor auth middleware", None, "2026-11-23T08:00:00Z", "2026-11-23T09:00:00Z",
             "gpt-5-codex", None, 9000, 2000, None, ""),
        ],
        [
            ("gemini:session-2026-11-24T03-16-2d813e72", "2026-11-24T14:00:00Z", "user", None, None,
             "Check webhook signature validation.", None),
            ("gemini:session-2026-11-24T03-16-2d813e72", "2026-11-24T14:05:00Z", "assistant", None, "gemini-3-pro",
             "Signature checks use constant-time compare.", None),
        ],
    )

    log_list = os.path.join(tmp, "log-projects")
    with open(log_list, "w", encoding="utf-8") as lf:
        lf.write(f"{proj_a}\n{proj_b}\n/nonexistent/project\n")

    with mock.patch.object(mod, "LOG_PROJECTS_PATH", log_list), \
         mock.patch.object(mod, "PROJECTS_PATH", os.path.join(tmp, "no-projects")), \
         mock.patch.object(mod, "HOME", os.path.join(tmp, "fake-home")):
        hist = mod.load_history(cwd=proj_a)
        check("load_history merges all projects, sorts newest-first, and excludes subagents",
              len(hist) == 3 and [h["tool"] for h in hist] == ["gemini", "claude", "codex"],
              f"got={[(h['tool'], h['title']) for h in hist]}")

        app = make_app()
        check("History is lazy-loaded (not queried on startup while on Commands tab)",
              not app.history_loaded and len(app.history_all) == 0)

        app.handle_key("3")  # Switch to History tab (Level 1: consolidated dates)
        check("pressing 3 switches to History tab and consolidates sessions per date",
              app.tab == mod.TAB_HISTORY and app.history_loaded and len(app.history_filtered) == 3 and len(app.history_date_groups) == 2,
              f"groups={[(g['date_key'], g['count']) for g in app.history_date_groups]}")

        # Render Level 1 (Dates list) at 84x32 and 60x20
        for dims in ((84, 32), (60, 20)):
            with mock.patch.object(mod, "get_term_size", return_value=dims):
                buf = io.StringIO()
                with mock.patch.object(sys, "stdout", buf):
                    app.render()
                dates_out = buf.getvalue()
                check(f"History Level 1 renders consolidated date list cleanly at {dims[0]}x{dims[1]}",
                      "Nov 24, 2026" in dates_out and "Nov 23, 2026" in dates_out and "2 chats" in dates_out and "Today" not in dates_out)

        # Tool filter updates date groups
        app.handle_key("t")
        check("pressing t cycles tool filter cleanly",
              app.history_tool_filter == "gemini" and len(app.history_filtered) == 1 and len(app.history_date_groups) == 1)
        app.handle_key("c")
        check("pressing c clears all History filters",
              app.history_tool_filter == "" and len(app.history_filtered) == 3 and len(app.history_date_groups) == 2)

        # Project filter
        app.handle_key("p")
        check("pressing p filters by a specific project",
              bool(app.history_proj_filter) and len(app.history_filtered) in (1, 2))
        app.handle_key("c")

        # Inline search narrows date groups to matching dates
        app.handle_key("/")
        for ch in "checkout":
            app.handle_key(ch)
        check("inline / search live-filters sessions and date groups across all projects",
              app.history_searching and len(app.history_filtered) == 1 and len(app.history_date_groups) == 1 and "checkout" in app.history_filtered[0]["title"].lower())
        app.handle_key("\r")  # apply search
        check("Enter exits search typing while preserving filtered results",
              not app.history_searching and len(app.history_filtered) == 1)

        # Enter on a date row opens Level 2 (Date's 2-row Task cards)
        app.handle_key("\r")
        check("Enter on History date row drills into Level 2 (Date's Task cards)",
              app.history_date_key == "2026-11-24" and app.history_detail is None)

        # Open Level 3 thread preview inspector via i
        app.handle_key("i")
        check("pressing i on a Task card opens Level 3 thread detail inspector",
              app.history_detail is not None and app.history_detail_data["users"] == 1 and app.history_detail_data["assistants"] == 1)

        # Toggle tools inside Level 3 inspector & render at 84x32 and 60x20
        for dims in ((84, 32), (60, 20)):
            with mock.patch.object(mod, "get_term_size", return_value=dims):
                buf = io.StringIO()
                with mock.patch.object(sys, "stdout", buf):
                    app.render()
                detail_out = buf.getvalue()
                check(f"History Level 3 detail renders cleanly at {dims[0]}x{dims[1]}",
                      "← Nov 24, 2026" in detail_out and ("Hand off" in detail_out or "Handoff" in detail_out) and "checkout" in detail_out.lower())

        app.handle_key("t")  # show tool calls
        check("pressing t inside History detail toggles tool calls on",
              app.history_detail_tools and any(b["kind"] == "tool_call" for b in app.history_detail_data["blocks"]))

        # Resume command preserves $$ path safely and resolves Gemini sessionId
        claude_resume = mod.build_history_resume_cmd(ctx, hist[1])
        check("Resume command quotes $$ project path safely with cd && exec agents --pane restore",
              "$$AFocus" in claude_resume and "--pane restore 0 claude nick 11111111-aaaa-bbbb-cccc-000000000001" in claude_resume,
              claude_resume)
        gem_resume = mod.build_history_resume_cmd(ctx, hist[0])
        check("Resume command resolves Gemini sessionId from source file",
              "2d813e72-a44d-43cb-891f-4fd79ade7be5" in gem_resume, gem_resume)

        # Esc pops Level 3 -> Level 2, then clear filters & render Level 2 Task cards at 84x32 and 60x20
        app.handle_key("\x1b")
        check("Esc inside Level 3 detail returns to Level 2 Date Task cards",
              app.running and app.history_detail is None and app.history_date_key == "2026-11-24")
        app.handle_key("c")
        for dims in ((84, 32), (60, 20)):
            with mock.patch.object(mod, "get_term_size", return_value=dims):
                buf = io.StringIO()
                with mock.patch.object(sys, "stdout", buf):
                    app.render()
                cards_out = buf.getvalue()
                check(f"History Level 2 renders 2-row Task cards cleanly at {dims[0]}x{dims[1]}",
                      "← History" in cards_out and "AlphaApp" in cards_out and "BetaService" in cards_out and "Task: " in cards_out and "CLAUDE nick" in cards_out)

        # Esc pops Level 2 -> Level 1 Dates list
        app.handle_key("\x1b")
        check("Esc inside Level 2 Date view returns to Level 1 Dates list without closing menu",
              app.running and app.history_date_key is None and app.tab == mod.TAB_HISTORY)

        # Clicking or pressing Enter on a Level 2 Task card goes straight to it!
        with mock.patch.object(mod, "find_live_pane_for_history", return_value=("@7", "%42")):
            live_app = make_app()
            live_app.handle_key("3")
            live_app.handle_key("\r")  # open date 2026-11-24
            live_app.handle_key("\r")  # go to first Task card
            check("Enter/Click on History Task card jumps to live pane when session is already open",
                  not live_app.running and "select-window -t @7" in (live_app.pending_cmd or "") and "select-pane -t %42" in (live_app.pending_cmd or ""))

        with mock.patch.object(mod, "find_live_pane_for_history", return_value=None):
            res_app = make_app()
            res_app.handle_key("3")
            res_app.handle_key("\r")  # open date 2026-11-24
            res_app.handle_key("\r")  # go to first Task card (Gemini, has native source file)
            check("Enter/Click on History Task card natively resumes session when source file exists",
                  not res_app.running and "--pane restore 0 gemini main 2d813e72-a44d-43cb-891f-4fd79ade7be5" in (res_app.pending_cmd or ""))

            # Missing native source file (e.g. pruned >30d Claude session) auto-falls back to compact acf.db handoff
            arch_app = make_app()
            arch_app.handle_key("3")
            arch_app.handle_key("\r")  # open date 2026-11-24
            arch_app.handle_key("j")   # move to Claude card (source="" -> missing native file)
            arch_app.handle_key("\r")
            check("Enter/Click on archived session (missing source) auto-falls back to acf-logs handoff",
                  not arch_app.running and "afc-logs" in (arch_app.pending_cmd or "") and "handoff" in (arch_app.pending_cmd or "") and "--pane handoff 0 claude nick" in (arch_app.pending_cmd or ""),
                  arch_app.pending_cmd or "")

        # H key opens cross-LLM Handoff Picker, puts other providers first, and launches handoff brief
        fake_targets = [
            {"tool": "codex", "account": "main", "same": False, "prov_col": mod.FG_GREEN},
            {"tool": "agy", "account": "main", "same": False, "prov_col": mod.FG_BLUE},
            {"tool": "gemini", "account": "main", "same": True, "prov_col": mod.FG_CYAN},
        ]
        with mock.patch.object(mod, "load_handoff_targets", return_value=fake_targets):
            ho_app = make_app()
            ho_app.handle_key("3")
            ho_app.handle_key("\r")  # open date 2026-11-24
            ho_app.handle_key("H")   # open Handoff LLM picker
            check("pressing H on History Task card opens cross-LLM Handoff Picker",
                  ho_app.history_handoff_item is not None and len(ho_app.history_handoff_targets) == 3)
            for dims in ((84, 32), (60, 20)):
                with mock.patch.object(mod, "get_term_size", return_value=dims):
                    buf = io.StringIO()
                    with mock.patch.object(sys, "stdout", buf):
                        ho_app.render()
                    ho_out = buf.getvalue()
                    check(f"History Handoff Picker renders cleanly at {dims[0]}x{dims[1]}",
                          "Hand off:" in ho_out and "CODEX" in ho_out and "AGY" in ho_out)
            ho_app.handle_key("\r")  # hand off Gemini session to Codex!
            check("selecting another LLM in Handoff Picker runs afc-logs handoff + agents --pane handoff",
                  not ho_app.running and "handoff gemini:session-2026-11-24T03-16-2d813e72" in (ho_app.pending_cmd or "")
                  and "--pane handoff 0 codex main" in (ho_app.pending_cmd or ""),
                  ho_app.pending_cmd or "")

        # Verify `afc-logs handoff` generates compact pickup brief with goal, edited files & cut-off point
        import subprocess as _sp
        env_ho = dict(os.environ, AFC_LOGS_LIST=log_list)
        logs_bin = os.path.join(os.path.dirname(menu_path), "afc-logs")
        ho_res = _sp.run([logs_bin, "handoff", "claude:11111111-aaaa-bbbb-cccc-000000000001", "--stdout"],
                         capture_output=True, text=True, env=env_ho, timeout=5)
        brief_txt = ho_res.stdout
        check("afc-logs handoff outputs compact pickup brief with goal, cut-off point & acf.db pointer",
              ho_res.returncode == 0 and "# Handoff Brief: Fix checkout race condition" in brief_txt
              and "Original Request" in brief_txt and "Where It Left Off" in brief_txt
              and "afc-logs show claude:11111111-aaaa-bbbb-cccc-000000000001" in brief_txt,
              f"rc={ho_res.returncode} out={brief_txt[:120]!r}")

        # Top 10 dates cap by default + custom date range search (d key / Dates pill) + scrollbar on Level 1 & Level 2
        many_dates = []
        for i in range(40):
            day_ts = f"2026-{(10 if i < 20 else 9):02d}-{(28 - (i % 20)):02d}T12:00:00Z"
            dk, dlbl, dshort = mod._date_parts_for_ts(day_ts)
            many_dates.append(dict(hist[0], id=f"claude:day-{i}", last_ts=day_ts, date_key=dk, date_label=dlbl, date_short=dshort, title=f"Day #{i}"))
        app.history_all = many_dates
        app.history_loaded = True
        app.history_loaded_scope = ("all", None, None)
        app._apply_history_filter()
        check("History Level 1 defaults to Top 10 dates only",
              len(app.history_date_groups) == 10 and app.history_date_mode == "top"
              and app.history_date_groups[0]["date_key"] == "2026-10-28"
              and app.history_date_groups[-1]["date_key"] == "2026-10-19",
              f"got {len(app.history_date_groups)} dates")

        # Custom date range via d key (typing still works seamlessly inside the visual Calendar Date Picker)
        app.handle_key("d")
        for ch in "2026-10-10..2026-10-15":
            app.handle_key(ch)
        app.handle_key("\r")
        range_keys = [g["date_key"] for g in app.history_date_groups]
        check("History d key filters by custom YYYY-MM-DD..YYYY-MM-DD date range",
              not app.history_date_editing and app.history_date_mode == "range"
              and len(range_keys) == 6 and range_keys[0] == "2026-10-15" and range_keys[-1] == "2026-10-10",
              f"got {range_keys}")

        # Visual Calendar Date-Range Picker: render, mouse 2-click (reverse order auto-swap), month nav & presets
        app.open_history_date_picker()
        app.dp_year, app.dp_month = 2026, 10
        app.dp_cursor = mod.datetime.date(2026, 10, 20)
        app.dp_start = None
        app.dp_end = None
        with mock.patch.object(mod, "get_term_size", return_value=(84, 24)):
            dp_buf = io.StringIO()
            with mock.patch.object(sys, "stdout", dp_buf):
                app.render()
            dp_out = dp_buf.getvalue()
            check("Calendar Date-Range Picker renders cleanly at 84x24 with 31 clickable days and preset pills",
                  "Date Range Picker" in dp_out and "October 2026" in dp_out
                  and len(app.dp_day_rects) == 31 and any(a == "preset" for *_, a, _ in app.dp_btn_rects),
                  f"days={len(app.dp_day_rects)} btns={len(app.dp_btn_rects)}")
            # Click Oct 16 then Oct 12 (reverse order -> auto-swaps to 2026-10-12..2026-10-16 -> 5 days)
            r16 = next((r, cs) for r, cs, ce, d in app.dp_day_rects if d == mod.datetime.date(2026, 10, 16))
            r12 = next((r, cs) for r, cs, ce, d in app.dp_day_rects if d == mod.datetime.date(2026, 10, 12))
            app.handle_mouse(0, r16[1], r16[0], "M")
            step1_ok = app.history_date_editing and app.dp_start == mod.datetime.date(2026, 10, 16) and app.dp_end is None
            app.handle_mouse(0, r12[1], r12[0], "M")
            picked_keys = [g["date_key"] for g in app.history_date_groups]
            check("Calendar picker 2-click selects Start→End range (auto-swapping reverse clicks)",
                  step1_ok and not app.history_date_editing and app.history_date_mode == "range"
                  and picked_keys == ["2026-10-16", "2026-10-15", "2026-10-14", "2026-10-13", "2026-10-12"],
                  f"step1={step1_ok} keys={picked_keys}")

        # Keyboard arrows + month switch ([/]) + 2x Enter inside picker + compact 60x20 render + preset click
        app.open_history_date_picker()
        app.dp_year, app.dp_month = 2026, 10
        app.dp_cursor = mod.datetime.date(2026, 10, 15)
        app.dp_start = None
        app.dp_end = None
        app.handle_key("[")  # previous month -> Sept 2026
        prev_ok = (app.dp_year, app.dp_month) == (2026, 9)
        app.handle_key("\r")  # Start = 2026-09-15
        app.handle_key("\x1b[C")  # Right -> 2026-09-16
        app.handle_key("\x1b[C")  # Right -> 2026-09-17
        app.handle_key("\r")  # End = 2026-09-17 -> applies 3 days
        kb_keys = [g["date_key"] for g in app.history_date_groups]
        check("Calendar picker keyboard month nav ([) + arrows + 2x Enter applies range",
              prev_ok and not app.history_date_editing and kb_keys == ["2026-09-17", "2026-09-16", "2026-09-15"],
              f"prev_ok={prev_ok} kb_keys={kb_keys}")

        app.open_history_date_picker()
        with mock.patch.object(mod, "get_term_size", return_value=(60, 20)):
            dp_narrow = io.StringIO()
            with mock.patch.object(sys, "stdout", dp_narrow):
                app.render()
            top10_btn = next((r, cs) for r, cs, ce, act, pl in app.dp_btn_rects if act == "preset" and pl == "top10")
            app.handle_mouse(0, top10_btn[1], top10_btn[0], "M")
            check("Calendar picker renders cleanly at 60x20 and Quick Preset pill applies Top 10",
                  "Date Range Picker" in dp_narrow.getvalue() and not app.history_date_editing
                  and app.history_date_mode == "top" and len(app.history_date_groups) == 10)

        # parse_date_range handles single date, month, Nd, all, invalid
        ref_today = mod.datetime.date(2026, 11, 25)
        check("parse_date_range handles single date, YYYY-MM, Nd, all, and rejects garbage",
              mod.parse_date_range("2026-10-12", ref_today)[:3] == ("range", "2026-10-12", "2026-10-12")
              and mod.parse_date_range("2026-10", ref_today)[:3] == ("range", "2026-10-01", "2026-10-31")
              and mod.parse_date_range("7d", ref_today)[:3] == ("range", "2026-11-19", "2026-11-25")
              and mod.parse_date_range("all", ref_today)[0] == "all"
              and mod.parse_date_range("not-a-date", ref_today) is None)

        # SQL-level date pruning on real temp acf.db
        sql_one_day = mod.load_history(cwd=proj_a, start_date="2026-11-23", end_date="2026-11-23")
        sql_top1 = mod.load_history(cwd=proj_a, max_dates=1)
        check("load_history pushes custom start/end date range into SQLite query",
              len(sql_one_day) == 1 and sql_one_day[0]["date_key"] == "2026-11-23" and len(sql_top1) >= 2,
              f"one_day={len(sql_one_day)} top1={len(sql_top1)}")

        # Switch to 'all' dates to verify Level 1 scrollbar across all 40 dates
        app.history_all = many_dates
        app.history_loaded_scope = ("all", None, None)
        app._apply_history_date_spec("all")
        with mock.patch.object(mod, "get_term_size", return_value=(84, 20)):
            buf = io.StringIO()
            with mock.patch.object(sys, "stdout", buf):
                app.render()
            sb_out = buf.getvalue()
            check("History Level 1 dates list renders right-edge vertical scrollbar (┃/│) when scrollable",
                  "┃" in sb_out and "│" in sb_out and app.scrollbar_rect is not None and app.scrollbar_rect[5] == "history_dates")
            top_r, bot_r, sb_col = app.scrollbar_rect[:3]
            app.handle_mouse(0, sb_col, bot_r, "M")
            d_bot = app.sel[mod.TAB_HISTORY] == len(app.history_date_groups) - 1 and app.scroll[mod.TAB_HISTORY] > 0
            app.handle_mouse(32, sb_col, top_r, "M")
            d_top = app.sel[mod.TAB_HISTORY] == 0 and app.scroll[mod.TAB_HISTORY] == 0
            check("clicking & dragging Level 1 dates scrollbar jumps to bottom and top cleanly",
                  d_bot and d_top)

        # Pressing c resets Dates back to Top 10
        app.handle_key("c")
        check("History c key resets custom date range back to Top 10",
              app.history_date_mode == "top" and app.history_date_range_label == "Top 10" and len(app.history_date_groups) == 10)

        many_same_day = [dict(hist[i % len(hist)], id=f"claude:same-{i}", last_ts="2026-11-24T12:00:00Z",
                              date_key="2026-11-24", date_label="Nov 24, 2026 (Tue)", date_short="Nov 24, 2026",
                              title=f"Same-day task #{i}") for i in range(40)]
        app.history_all = many_same_day
        app._apply_history_filter()
        app.handle_key("\r")  # enter 2026-11-24
        with mock.patch.object(mod, "get_term_size", return_value=(84, 20)):
            buf = io.StringIO()
            with mock.patch.object(sys, "stdout", buf):
                app.render()
            sb_cards_out = buf.getvalue()
            check("History Level 2 Task cards render right-edge vertical scrollbar (┃/│) when scrollable",
                  "┃" in sb_cards_out and "│" in sb_cards_out and app.scrollbar_rect is not None and app.scrollbar_rect[5] == "history_cards")
            top_r, bot_r, sb_col = app.scrollbar_rect[:3]
            app.handle_mouse(0, sb_col, bot_r, "M")
            c_bot = app.history_date_sel == len(many_same_day) - 1 and app.history_date_scroll > 0
            app.handle_mouse(32, sb_col, top_r, "M")
            c_top = app.history_date_sel == 0 and app.history_date_scroll == 0
            check("clicking & dragging Level 2 Task cards scrollbar jumps to bottom and top cleanly",
                  c_bot and c_top)

        # 9. Doctrine, Mental Model, STE-Lite & DO-178C-Lite in Config, Sessions Inspector & History Level 2
        cfg_settings_path = os.path.join(tmp, "settings")
        cfg_pm_path = os.path.join(tmp, "project-modes.json")
        with mock.patch.object(mod, "SETTINGS_PATH", cfg_settings_path), \
             mock.patch.object(mod, "PROJECT_MODES_PATH", cfg_pm_path), \
             mock.patch.object(mod, "save_pane_mode") as m_save_pane:
            cfg_app = make_app()
            cfg_app.proj_key = proj_a
            cfg_app.proj_name = "AlphaApp"
            cfg_app.proj_modes = {}
            cfg_app.pane_modes = {"doctrine": "inherit", "mental-model": "inherit"}
            cfg_app.handle_key("4")  # Config tab
            citems = cfg_app._config_items()
            ckeys = [c["key"] for c in citems]
            check("Config tab exposes pane/proj Doctrine & Model, STE-Lite, DO-178C-Lite, Hygiene, Summary, SITREP & clear-modes",
                  all(k in ckeys for k in ("pane-doctrine", "pane-model", "proj-doctrine", "proj-model",
                                           "clear-modes", "style-ste", "code-do178c", "search-hygiene",
                                           "memory-summary", "sitrep", "doctrine", "mental-model")))

            # Core defaults: style-ste (CLS) and code-do178c (SAS) default ON; search-hygiene, memory-summary & sitrep default OFF
            ste_idx = ckeys.index("style-ste")
            do_idx = ckeys.index("code-do178c")
            hyg_idx = ckeys.index("search-hygiene")
            mem_idx = ckeys.index("memory-summary")
            sit_idx = ckeys.index("sitrep")
            check("Config tab defaults style-ste and code-do178c to on and sitrep to off",
                  citems[ste_idx]["default"] == "on" and citems[do_idx]["default"] == "on" and citems[sit_idx]["default"] == "off")
            # Toggle style-ste & code-do178c off then back on; toggle search-hygiene, memory-summary & sitrep on
            for idx_t in (ste_idx, do_idx):
                cfg_app.sel[mod.TAB_CONFIG] = idx_t
                cfg_app.handle_key("\r")
            off_cfg = mod.load_settings()
            for idx_t in (ste_idx, do_idx, hyg_idx, mem_idx, sit_idx):
                cfg_app.sel[mod.TAB_CONFIG] = idx_t
                cfg_app.handle_key("\r")
            saved_cfg = mod.load_settings()
            check("Config tab toggles style-ste, code-do178c, search-hygiene, memory-summary & sitrep and persists",
                  off_cfg.get("style-ste") == "off" and off_cfg.get("code-do178c") == "off"
                  and saved_cfg.get("style-ste") == "on" and saved_cfg.get("code-do178c") == "on"
                  and saved_cfg.get("search-hygiene") == "on" and saved_cfg.get("memory-summary") == "on"
                  and saved_cfg.get("sitrep") == "on")

            # Config tab: x switches off, c/Del deletes (resets to inherit)
            pdoc_idx = ckeys.index("proj-doctrine")
            cfg_app.sel[mod.TAB_CONFIG] = pdoc_idx
            cfg_app.handle_key("x")
            off_ok = cfg_app.proj_modes.get("doctrine") == "off"
            cfg_app.handle_key("\x1b[3~")  # Del
            del_ok = "doctrine" not in cfg_app.proj_modes
            check("Config tab x switches project mode off and Del/c deletes override back to inherit",
                  off_ok and del_ok)

            cfg_app.sel[mod.TAB_CONFIG] = 0
            with mock.patch.object(mod, "get_term_size", return_value=(84, 32)):
                buf = io.StringIO()
                with mock.patch.object(sys, "stdout", buf):
                    cfg_app.render()
                hdr_out = buf.getvalue()
                # Top header sits at body_top (row 3) and must not be clickable; item 0 sits at row 4
                check("Config tab groups Pane / Project / Global Modes / Fleet under non-clickable headers",
                      "This Pane (" in hdr_out and "This Project (" in hdr_out
                      and "Global Modes (" in hdr_out and "Fleet & Resource Settings" in hdr_out
                      and 3 not in cfg_app.row_map and cfg_app.row_map.get(4) == 0)

            cfg_app.sel[mod.TAB_CONFIG] = do_idx
            for dims in ((84, 32), (60, 20)):
                with mock.patch.object(mod, "get_term_size", return_value=dims):
                    buf = io.StringIO()
                    with mock.patch.object(sys, "stdout", buf):
                        cfg_app.render()
                    cfg_out = buf.getvalue()
                    check(f"Config tab with active modes renders cleanly at {dims[0]}x{dims[1]}",
                          "style-ste" in cfg_out and "code-do178c" in cfg_out and "STE=on" in cfg_out and "DO-178C=on" in cfg_out)

            # Session Inspector: see, click-cycle, switch off & delete Doctrine / Mental Model pills
            fake_win = {"kind": "window", "wid": "@1", "win_idx": "1", "win_name": "AlphaApp",
                        "label": "1  AlphaApp", "badge": "▶ working", "cmd": "tmux select-window -t @1"}
            fake_agents = [{
                "pane_idx": "0", "pane_id": "%5", "active": True, "provider": "claude",
                "account": "nick", "prov_col": mod.FG_CYAN, "express": False,
                "model": "opus-5-5", "tokens": "42k", "proj_key": proj_a,
                "pane_doctrine": "inherit", "pane_model": "inherit",
                "proj_doctrine": "inherit", "proj_model": "inherit",
                "eff_doctrine": "off", "eff_model": "off",
                "badge": "▶ working", "badge_col": mod.FG_CYAN,
                "task": "Wire modes into menu", "cmd": "tmux select-pane -t %5",
            }]
            sess_app = make_app()
            sess_app.proj_key = proj_a
            sess_app.pane_modes = {"doctrine": "inherit", "mental-model": "inherit"}
            sess_app.tab = mod.TAB_SESSIONS
            sess_app.inspect_win = fake_win
            sess_app.inspect_agents = fake_agents
            with mock.patch.object(mod, "get_term_size", return_value=(84, 32)):
                buf = io.StringIO()
                with mock.patch.object(sys, "stdout", buf):
                    sess_app.render()
                s_out = buf.getvalue()
                check("Session Inspector renders D:off, M:off & ✕ pills at 84x32",
                      "D:off" in s_out and "M:off" in s_out and "✕" in s_out
                      and bool(sess_app.agent_doc_rects) and bool(sess_app.agent_mod_rects) and bool(sess_app.agent_clr_rects))

                # Left-click D: pill -> cycles to mdmp without closing menu
                r_doc, (c1, _c2, _i) = next(iter(sess_app.agent_doc_rects.items()))
                sess_app.handle_mouse(0, c1, r_doc, "M")
                check("clicking D: pill in Session Inspector cycles pane Doctrine to mdmp & stays open",
                      sess_app.running and fake_agents[0]["eff_doctrine"] == "mdmp"
                      and sess_app.pane_modes["doctrine"] == "mdmp")

                # Left-click M: pill -> cycles to ooda
                r_mod, (mc1, _mc2, _mi) = next(iter(sess_app.agent_mod_rects.items()))
                sess_app.handle_mouse(0, mc1, r_mod, "M")
                check("clicking M: pill in Session Inspector cycles pane Mental Model to ooda",
                      fake_agents[0]["eff_model"] == "ooda" and sess_app.pane_modes["mental-model"] == "ooda")

                # Left-click ✕ pill -> first click switches off, second click deletes pane override
                r_clr, (xc1, _xc2, _xi) = next(iter(sess_app.agent_clr_rects.items()))
                sess_app.handle_mouse(0, xc1, r_clr, "M")
                first_off = fake_agents[0]["pane_doctrine"] == "off" and fake_agents[0]["pane_model"] == "off"
                sess_app.handle_mouse(0, xc1, r_clr, "M")
                second_del = fake_agents[0]["pane_doctrine"] == "inherit" and fake_agents[0]["pane_model"] == "inherit"
                check("clicking ✕ pill in Session Inspector switches off first, then deletes override",
                      first_off and second_del)

                # Keyboard d/m/x/c in Session Inspector
                sess_app.handle_key("d")
                sess_app.handle_key("m")
                kb_on = fake_agents[0]["eff_doctrine"] == "mdmp" and fake_agents[0]["eff_model"] == "ooda"
                sess_app.handle_key("x")
                kb_off = fake_agents[0]["pane_doctrine"] == "off" and fake_agents[0]["pane_model"] == "off"
                sess_app.handle_key("c")
                kb_del = fake_agents[0]["pane_doctrine"] == "inherit" and fake_agents[0]["pane_model"] == "inherit"
                check("Session Inspector keys d/m/x/c cycle, switch off & delete pane modes cleanly",
                      kb_on and kb_off and kb_del)

            # History Level 2 Date Task Cards: see, click-cycle, switch off & delete per-project Doctrine / Mental Model
            hmode_app = make_app()
            hmode_app.handle_key("3")   # History tab
            hmode_app.handle_key("\r")  # open 2026-11-24 Task cards
            with mock.patch.object(mod, "get_term_size", return_value=(84, 32)):
                buf = io.StringIO()
                with mock.patch.object(sys, "stdout", buf):
                    hmode_app.render()
                hm_out = buf.getvalue()
                check("History Level 2 Task cards render D:off, M:off & ✕ pills on Task row at 84x32",
                      "D:off" in hm_out and "M:off" in hm_out and "✕" in hm_out
                      and bool(hmode_app.hist_doc_rects) and bool(hmode_app.hist_mod_rects) and bool(hmode_app.hist_clr_rects))

                # Click D: and M: on first History card -> saves project modes for BetaService
                hr_doc, (hc1, _hc2, _hi) = next(iter(hmode_app.hist_doc_rects.items()))
                hr_mod, (hmc1, _hmc2, _hmi) = next(iter(hmode_app.hist_mod_rects.items()))
                hr_clr, (hxc1, _hxc2, _hxi) = next(iter(hmode_app.hist_clr_rects.items()))
                hmode_app.handle_mouse(0, hc1, hr_doc, "M")
                hmode_app.handle_mouse(0, hmc1, hr_mod, "M")
                pm_after = mod.load_project_modes().get(mod.project_key_for(proj_b), {})
                check("clicking D:/M: on History Task card sets project Doctrine & Model without closing menu",
                      hmode_app.running and pm_after.get("doctrine") == "mdmp" and pm_after.get("mental-model") == "ooda",
                      f"pm={pm_after}")

                # Click ✕ -> switches off first, second click deletes entry from project-modes.json
                hmode_app.handle_mouse(0, hxc1, hr_clr, "M")
                pm_off = mod.load_project_modes().get(mod.project_key_for(proj_b), {})
                hmode_app.handle_mouse(0, hxc1, hr_clr, "M")
                pm_del = mod.load_project_modes().get(mod.project_key_for(proj_b))
                check("clicking ✕ on History Task card switches project off first, then deletes override",
                      pm_off.get("doctrine") == "off" and pm_off.get("mental-model") == "off" and pm_del is None,
                      f"off={pm_off} del={pm_del}")

                # Keyboard d/m/x/X on History Level 2 Task card
                hmode_app.handle_key("d")
                hmode_app.handle_key("m")
                hmode_app.handle_key("x")
                hkb_off = mod.load_project_modes().get(mod.project_key_for(proj_b), {})
                hmode_app.handle_key("X")
                hkb_del = mod.load_project_modes().get(mod.project_key_for(proj_b))
                check("History Level 2 keys d/m/x/X cycle, switch off & delete project modes cleanly",
                      hkb_off.get("doctrine") == "off" and hkb_del is None)

                # Session id column + ⧉ copy icon: click and `y` copy the provider's own session id
                copied = []
                with mock.patch.object(mod, "copy_to_clipboard", side_effect=lambda t, s="": copied.append(t) or True):
                    buf = io.StringIO()
                    with mock.patch.object(sys, "stdout", buf):
                        hmode_app.render()
                    cp_row, (cp_c1, cp_c2, cp_i) = next(iter(hmode_app.hist_copy_rects.items()))
                    cp_item = hmode_app._current_date_group()["items"][cp_i]
                    want_sid = cp_item["id"].split(":", 1)[-1]
                    hmode_app.handle_mouse(0, cp_c2, cp_row, "M")
                    hmode_app.handle_key("y")
                check("History Level 2 shows short session id + ⧉; click & y copy the full session id",
                      "⧉" in buf.getvalue() and cp_item["short_id"] in buf.getvalue()
                      and copied == [want_sid, want_sid] and hmode_app.running
                      and want_sid in hmode_app.status_msg,
                      f"copied={copied} want={want_sid} msg={hmode_app.status_msg!r}")

            # afc-logs summary generates hard-capped <=50-line SUMMARY.md with thread IDs
            sum_bin = os.path.join(mod.REPO_ROOT, "bin", "afc-logs")
            r_sum = mod.subprocess.run([sys.executable, "-I", sum_bin, "summary", proj_a, "--max-lines", "25"],
                                       capture_output=True, text=True, timeout=10)
            sum_file = os.path.join(proj_a, "logs", "acf", "SUMMARY.md")
            sum_txt = open(sum_file, encoding="utf-8").read() if os.path.isfile(sum_file) else ""
            sum_lines = sum_txt.splitlines()
            check("afc-logs summary writes hard-capped <=25-line SUMMARY.md with thread IDs and show hint",
                  r_sum.returncode == 0 and 5 <= len(sum_lines) <= 25
                  and "claude:11111111-aaaa-bbbb-cccc-000000000001" in sum_txt
                  and "afc-logs show" in sum_txt,
                  f"rc={r_sum.returncode} lines={len(sum_lines)}")

            # Shared lib/afc/state.py direct unit checks
            st = mod.afc_state
            st_set = os.path.join(tmp, "state-settings")
            with open(st_set, "w", encoding="utf-8") as f:
                f.write("# splash off\nclaude-view compact # inline note\nstart-gap 2 # comment\n")
            s_vals = st.load_settings(st_set)
            st.save_setting("splash", "on", st_set)
            st.save_setting("start-gap", "1", st_set)
            st.save_setting("new-key", "yes", st_set)
            s_after = st.load_settings(st_set)
            check("lib/afc/state.py parses inline comments, aliases claude-view->view, uncomments & updates atomically",
                  s_vals.get("view") == "compact" and s_vals.get("start-gap") == "2"
                  and st.setting("splash", "off", st_set) == "on"
                  and s_after.get("start-gap") == "1" and s_after.get("new-key") == "yes",
                  f"before={s_vals} after={s_after}")

            git_repo = os.path.join(tmp, "git-proj")
            git_sub = os.path.join(git_repo, "sub", "deep")
            os.makedirs(os.path.join(git_repo, ".git"), exist_ok=True)
            os.makedirs(git_sub, exist_ok=True)
            st_pm = os.path.join(tmp, "state-pm.json")
            pk = st.project_key_for(git_sub)
            st.save_project_mode(pk, "doctrine", "mdmp", st_pm)
            st.save_project_mode(pk, "mental-model", "ooda", st_pm)
            pm_both = st.load_project_modes(st_pm).get(pk)
            st.save_project_mode(pk, "doctrine", "inherit", st_pm)
            pm_one = st.load_project_modes(st_pm).get(pk)
            st.clear_project_modes(pk, st_pm)
            pm_none = st.load_project_modes(st_pm).get(pk)
            check("lib/afc/state.py resolves .git ancestor key and saves/inherits/clears project modes",
                  pk == os.path.realpath(git_repo)
                  and pm_both == {"doctrine": "mdmp", "mental-model": "ooda"}
                  and pm_one == {"mental-model": "ooda"} and pm_none is None,
                  f"pk={pk} both={pm_both} one={pm_one} none={pm_none}")

            check("lib/afc/state.py builds tmux_cmd for explicit socket and default -L socket",
                  st.tmux_cmd("/tmp/s", "list-panes", tmux_bin="/usr/bin/tmux") == ["/usr/bin/tmux", "-S", "/tmp/s", "list-panes"]
                  and st.tmux_cmd("", "list-panes", default_sock="agents", tmux_bin="/usr/bin/tmux") == ["/usr/bin/tmux", "-L", "agents", "list-panes"])

            # History Level 3 detail colors You: red and SITREP green (both ```diff and plain lines)
            det_app = make_app()
            det_app.history_detail = {"tool": "claude", "prov_col": mod.FG_CYAN}
            det_app.history_detail_data = {
                "blocks": [{
                    "kind": "assistant", "ts": "18:00", "who": "", "model": "",
                    "text": "Done.\n\n```diff\n- You: push sandbox\n\n+ SITREP · D:MDMP · M:OODA · P5 ASSESS · Done: ok\n```\n\nYou: plain check\nSITREP · D:MDMP · M:OODA · P5 ASSESS · Done: ok",
                }],
            }
            det_lines = det_app._build_history_detail_lines(100)
            col_map = {txt.strip(): col for col, txt in det_lines if txt.strip()}
            check("History Level 3 detail colors You:/- You: red and SITREP/+ SITREP green",
                  col_map.get("- You: push sandbox") == mod.FG_RED
                  and col_map.get("+ SITREP · D:MDMP · M:OODA · P5 ASSESS · Done: ok") == mod.FG_GREEN
                  and col_map.get("You: plain check") == mod.FG_RED
                  and col_map.get("SITREP · D:MDMP · M:OODA · P5 ASSESS · Done: ok") == mod.FG_GREEN,
                  f"col_map={col_map}")

print(f"\n{passed} passed, {failed} failed")
sys.exit(1 if failed else 0)
PY
