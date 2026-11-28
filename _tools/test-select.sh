#!/usr/bin/env bash
# test-select.sh: tests for bin/afc-select, Ctrl+A in an agent's chat box. Finds the typed text on
# screens drawn the way each agent draws its box (SGR codes as tmux's capture-pane -e gives them),
# and leaves alone what is not typed text: a placeholder, an empty box, a shell. No tmux, no agent.
#
#   bash _tools/test-select.sh
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
python3 - "$HERE/bin/afc-select" <<'PY'
import importlib.machinery, importlib.util, sys
ld = importlib.machinery.SourceFileLoader("sel", sys.argv[1])
sp = importlib.util.spec_from_loader("sel", ld); m = importlib.util.module_from_spec(sp); ld.exec_module(m)
E, R = "\x1b", "─" * 60
ok = bad = 0
def check(name, screen, cx, cy, want):
    global ok, bad
    box = m.find_box([m.parse(l) for l in screen.split("\n")], cx, cy)
    got = None if not box else [m.text_of(c) for _, c in box]
    if got == want: ok += 1; print(f"  ok    {name}")
    else: bad += 1; print(f"  FAIL  {name}\n        got {got!r}, expected {want!r}")
claude = f"some reply\n\n{E}[38;5;244m{R}\n{E}[39m❯ alpha beta\n  second line\n{E}[38;5;244m{R}\n{E}[39m  ⏵⏵ auto mode on"
check("Claude: every row of the box, the prompt mark left out", claude, 13, 4, ["alpha beta", "second line"])
check("... the cursor on its first row still takes the rows under it", claude, 4, 3, ["alpha beta", "second line"])
check("Claude's faint placeholder is not typed text", f"{E}[38;5;244m{R}\n{E}[39m❯ {E}[2mTry \"fix it\"{E}[0m\n{R}", 2, 1, None)
check("an empty box", f"{R}\n> \n{R}", 2, 1, None)
check("Antigravity", f"{E}[90m{R}\n{E}[94m>{E}[39m hello typed text\n{E}[90m{R}", 18, 1, ["hello typed text"])
gem = (f"{E}[38;2;95;95;95m▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄▄\n{E}[39m{E}[48;2;95;95;95m {E}[38;2;215;175;255m> "
       f"{E}[38;2;255;255;255mhello typed text{E}[7m{E}[39m {E}[0m\n{E}[38;2;95;95;95m▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀▀")
check("Gemini: text after its boxed > mark", gem, 19, 1, ["hello typed text"])
check("Gemini's grey placeholder is not typed text",
      f"▄▄▄▄▄▄▄▄▄▄▄▄\n{E}[48;2;95;95;95m {E}[38;2;215;175;255m> {E}[38;2;175;175;175m Type your message{E}[0m\n▀▀▀▀▀▀▀▀▀▀▀▀", 3, 1, None)
check("Codex: no rule under the box, a blank row ends it",
      f"• Hello\n\n{E}[1m›{E}[0m hello typed text\n  more of it\n\n  GPT-6 high · /tmp/x", 12, 3, ["hello typed text", "more of it"])
check("Codex: an earlier › message above the box is not taken", f"› old message\n• reply\n\n› new text\n\n  status", 10, 3, ["new text"])
check("Copilot's boxed ┃ mark", f"╻▄▄▄▄▄▄▄▄▄▄▄▄\n┃ copilot text\n╹▀▀▀▀▀▀▀▀▀▀▀▀", 14, 1, ["copilot text"])
check("a shell prompt is no box", "user@host:~$ ls -la", 18, 0, None)
check("a > typed inside the text (not in the prompt's column) is not a prompt mark",
      f"{R}\n❯ first\n  > quoted\n{R}", 10, 2, ["first", "> quoted"])
check("the cursor outside any box (a rule between it and the mark)", f"❯ text\n{R}\nmenu item", 3, 2, None)

def assert_eq(name, got, want):
    global ok, bad
    if got == want: ok += 1; print(f"  ok    {name}")
    else: bad += 1; print(f"  FAIL  {name}\n        got {got!r}, expected {want!r}")

# Fast-path helpers: reverse-video cursor detection, cursor-sized clear counts, batched select cmds, shell key dispatcher
assert_eq("Gemini fake reverse-video cursor position detected", m._find_rev_cursor(gem.split("\n"), 1, 1, 3), (19, 1))
c_rows = [m.parse(l) for l in claude.split("\n")]
c_box = m.find_box(c_rows, 13, 4)
assert_eq("clear_counts at end sends tight deletes", m.clear_counts(c_box, 13, 4), (28, 4))
assert_eq("clear_counts at start sends tight backspaces", m.clear_counts(c_box, 2, 3), (4, 28))
assert_eq("clear_counts in middle splits around cursor", m.clear_counts(c_box, 6, 3), (10, 24))

cmds_single = m._build_select_cmds("%1", c_rows, 13, 4, 3, c_box[0][1], 4, c_box[1][1], 60)
assert_eq("batched select starts with copy-mode -H and includes begin-selection",
          (cmds_single[:4], "begin-selection" in cmds_single, "cursor-up" in cmds_single, "cursor-down" in cmds_single),
          (["copy-mode", "-H", "-t", "%1"], True, True, True))

wide_rows = [m.parse("❯ 你好ab")]
wide_box = m.find_box(wide_rows, 8, 0)
assert_eq("char_steps counts wide CJK chars as 1 tmux step each",
          (m.char_steps(wide_rows[0], 2), m.char_steps(wide_rows[0], 7, past=True)),
          (2, 6))

sh_cmd = m._key_shell_cmd("12", 30, 36, 4)
assert_eq("shell key dispatcher has zero '%' and zero single quotes",
          ("%" not in sh_cmd, "'" not in sh_cmd, "#{q:@acf_key_12}" in sh_cmd, "-H 3b" in sh_cmd),
          (True, True, True, True))

print(f"\n{ok} passed, {bad} failed")
sys.exit(1 if bad else 0)
PY
