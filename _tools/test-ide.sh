#!/usr/bin/env bash
# test-ide.sh: tests for bin/afc-ide, the small code view (view, edit, delete). Touches nothing of
# yours: a made-up project in a temp folder and a tmux server of its own, both removed afterwards.
#
#   bash _tools/test-ide.sh          test bin/afc-ide of this folder
#   bash _tools/test-ide.sh --keep   leave the temp folder for a look
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
KEEP=0; [[ "${1:-}" == --keep ]] && KEEP=1
T=$(mktemp -d /tmp/acf-ide-test.XXXXXX)
SOCK="acfide-$$"
TM=$(command -v tmux || echo "$HOME/.local/bin/tmux")
tm() { "$TM" -L "$SOCK" -f /dev/null "$@"; }
cleanup() { tm kill-server 2>/dev/null; tp kill-server 2>/dev/null; exec 9>&- 2>/dev/null; (( KEEP )) || rm -rf "$T"; }
tp() { "$TM" -L "${SOCK}p" -f "$T/popup.conf" "$@"; }
trap cleanup EXIT
ln -s "$HERE/bin/afc-ide" "$T/afc-ide"      # the repo path may hold "$$": tmux runs commands through sh

echo "units (text width, edits, undo, files, input)"
python3 -I - "$HERE/bin/afc-ide" "$T" <<'EOF'
import importlib.machinery, importlib.util, json, os, stat, sys
path, T = sys.argv[1], sys.argv[2]
loader = importlib.machinery.SourceFileLoader("afc_ide", path)
spec = importlib.util.spec_from_loader("afc_ide", loader); m = importlib.util.module_from_spec(spec); loader.exec_module(m)
ok = bad = 0
def check(name, cond, info=""):
    global ok, bad
    if cond: ok += 1; print(f"  ok    {name}")
    else: bad += 1; print(f"  FAIL  {name}  {info}")

# width: a tab to the next 4-column stop, CJK 2 columns, control chars 1
check("col_of: tab stops and wide characters", m.col_of("\tab你x", 5) == 9 and m.col_of("ab\tc", 3) == 4, m.col_of("\tab你x", 5))
check("idx_at: a click on a wide char's right half lands after it, past the end gives the length",
      m.idx_at("a你b", 1) == 1 and m.idx_at("a你b", 2) == 2 and m.idx_at("a你b", 3) == 2 and m.idx_at("ab", 99) == 2)
check("visible: scrolled view expands tabs, a wide char cut at either edge shows as spaces",
      m.visible("\tx", 0, 6) == "    x" and m.visible("你好", 1, 2) == "  " and m.visible("ab\x01", 0, 9) == "ab?")

# edits and undo
d = m.Doc("/x", "def f():\n    return 1\n", 0)
d.cy, d.cx = 1, 10; d.newline()
check("Enter keeps the line's indent", d.lines[1:3] == ["    return", "     1"], d.lines)
d = m.Doc("/x", "def f():\n    return 1\n", 0)
d.cy, d.cx = 0, 8; d.newline(); d.insert("x"); d.insert("y")
check("Enter after 'def f():' starts the new line at the same indent (none here), typed text follows", d.lines[:2] == ["def f():", "xy"], d.lines)
d.step(True)
check("undo takes back the typed word in one step", d.lines[:2] == ["def f():", ""], d.lines)
d.step(True); d.step(False)
check("undo again takes back the Enter; redo brings it back", d.lines[:2] == ["def f():", ""] and len(d.lines) == 4, d.lines)
d = m.Doc("/x", "ab\ncd", 0); d.cy, d.cx = 1, 0; d.backspace()
check("Backspace at a line start joins it to the line above", d.lines == ["abcd"] and d.cx == 2, d.lines)
d.cx = 2; d.delete(); d.cx = 3; d.delete()
check("Delete removes a char; at the very end it does nothing", d.lines == ["abd"], d.lines)
d = m.Doc("/x", "a\nb\nc", 0); d.cy = 2; d.delete_line()
check("Ctrl+K deletes the line; the cursor stays on a real line", d.lines == ["a", "b"] and d.cy == 1, (d.lines, d.cy))
d = m.Doc("/x", "only", 0); d.delete_line()
check("Ctrl+K on the only line leaves it empty", d.lines == [""])
d = m.Doc("/x", "x", 0)
for _ in range(400): d.insert("\n", kind="enter")
check(f"undo keeps at most {m.MAX_UNDO} steps", len(d.undo) == m.MAX_UNDO, len(d.undo))
d = m.Doc("/x", "foo.bar_baz qux", 0); d.move("wright"); a = d.cx; d.move("wright"); b = d.cx
check("Ctrl+Right moves by words", (a, b) == (3, 11), (a, b))

# files: CRLF, bytes that are not UTF-8 and the file's mode survive a save; binary and big files are refused
p = os.path.join(T, "w.txt")
with open(p, "wb") as f: f.write(b"one\r\ntwo \xff\r\n")
os.chmod(p, 0o750)
d, why = m.load(p)
d.cy, d.cx = 0, 3; d.insert("!")
why = m.save(d)
check("save: CRLF, a non-UTF-8 byte and the file mode stay; no temp file left beside it",
      why is None and open(p, "rb").read() == b"one!\r\ntwo \xff\r\n" and stat.S_IMODE(os.stat(p).st_mode) == 0o750
      and not [n for n in os.listdir(T) if ".afc-ide." in n], (why, open(p, "rb").read()))
b = os.path.join(T, "b.bin"); open(b, "wb").write(b"ab\0cd")
big = os.path.join(T, "big.txt"); open(big, "wb").write(b"x" * (m.MAX_BYTES + 1))
check("load refuses a binary file and one over the size limit", m.load(b)[1] == "not opened: a binary file" and "MB" in m.load(big)[1])
os.remove(b); os.remove(big)
ro = os.path.join(T, "ro"); os.makedirs(ro); q = os.path.join(ro, "f.txt"); open(q, "w").write("a")
d, _ = m.load(q); d.insert("b"); os.chmod(ro, 0o500)
why = m.save(d)
check("save into a folder that cannot be written: says why, the file stays as it was", why and why.startswith("not saved") and open(q).read() == "a", why)
os.chmod(ro, 0o700)

# input
k, rest = m.tokens("a\x1b[A\x1b[1;5C\x1b[<0;10;5M\x1b[<0;10;5m\x1b[200~x\ny\x1b[201~\x1bOH")
check("tokens: keys, arrows, a mouse press and its release, a paste, SS3 Home",
      k == ["a", "\x1b[A", "\x1b[1;5C", ("mouse", 0, 10, 5), ("release", 0, 10, 5), ("paste", "x\ny"), "\x1bOH"] and rest == "", k)
k, rest = m.tokens("b\x1b[200~half")
k2, rest2 = m.tokens(rest + " more\x1b[201~")
check("tokens: a paste split over two reads comes out whole", k == ["b"] and k2 == [("paste", "half more")] and rest2 == "", (k, k2))
check("tokens: a lone Esc waits (it may start a sequence)", m.tokens("\x1b") == ([], "\x1b"))

# colours: the language from the name or the #! line; tokens; states that carry over lines
N = {v: k for k, v in m.HL.items()}; N[m.HL["str"]] = "str"
def kinds(lang, lines):
    st, out = None, []
    for t in lines:
        sp, st = m.scan(lang, t, st)
        out.append([(t[a:b], N[c]) for a, b, c in sp])
    return out, st
check("language: by extension, by #! line, tmux.conf, Markdown, else plain text",
      [m.language(p, f) for p, f in (("a.py", ""), ("bin/x", "#!/usr/bin/env bash"), ("x", "#!/usr/bin/env -S python3 -I"),
                                     ("tmux.conf", ""), ("R.md", ""), (".bashrc", ""), ("notes.txt", ""))]
      == ["Python", "Shell", "Python", "Config", "Markdown", "Shell", None])
k, _ = kinds("Python", ['@dec', 'def f(x=1):  # hi', '    return f"a{x}" + len(y)'])
check("Python: decorator, def name, number, comment, keyword, f-string, builtin",
      ("@dec", "var") in k[0] and ("def", "kw") in k[1] and ("f", "fn") in k[1] and ("1", "num") in k[1]
      and ("# hi", "com") in k[1] and ("return", "kw") in k[2] and ('"a{x}"', "str") in k[2] and ("len", "fn") in k[2], k)
k, st = kinds("Python", ['x = """start', 'middle # not a comment', 'end""" + 1'])
check("Python: a triple-quoted string spans lines; the line after it is code again",
      k[1] == [("middle # not a comment", "str")] and k[2][0] == ('end"""', "str") and ("1", "num") in k[2] and st is None, k)
k, _ = kinds("Shell", ['echo "$HOME" $USER ${X:-1} # done', "it's=1"])
check("Shell: variables, strings, a comment after a space; # inside a word is not a comment",
      ("$USER", "var") in k[0] and ("${X:-1}", "var") in k[0] and ("# done", "com") in k[0] and ('"$HOME"', "str") in k[0], k)
k, _ = kinds("JSON", ['{"key": "value", "n": 2, "ok": true}'])
check("JSON: keys and values in different colours", ('"key"', "key") in k[0] and ('"value"', "str") in k[0] and ("true", "num") in k[0], k)
k, _ = kinds("PowerShell", ['$x = Get-Content -Raw $f  # read', '<# block', 'still #>'])
check("PowerShell: cmdlet, -parameter, variables, block comments over lines",
      ("Get-Content", "fn") in k[0] and ("$x", "var") in k[0] and k[1] == [("<# block", "com")] and k[2] == [("still #>", "com")], k)
k, _ = kinds("Markdown", ["# Title", "- item with `code` and **bold**", "```", "def x(): pass", "```", "after"])
check("Markdown: heading, list mark, inline code, bold, a fenced block, text after it",
      k[0] == [("# Title", "head")] and ("-", "num") in k[1] and ("`code`", "str") in k[1] and ("**bold**", "bold") in k[1]
      and k[3] == [("def x(): pass", "str")] and k[5] == [], k)
k, _ = kinds("Config", ["[Unit]", "Description=x  # c", "bind -n M-i display-popup"])
check("Config: sections, keys, the first word of a command line", k[0] == [("[Unit]", "kw")] and ("Description", "key") in k[1]
      and ("bind", "kw") in k[2], k)
check("a line over the length limit is shown without colours", m.scan("Python", "x" * (m.MAX_HL_LINE + 1), None) == ([], None))
d = m.Doc("/a.py", 'a = 1\nb = 2\nc = 3', 0)
before = d.spans(2)
d.cy, d.cx = 0, 4; d.insert('"""')
after = d.spans(2)
check("an edit recolours the lines below it (an opened string runs on)", ("3", "num") in [(d.lines[2][a:b], N[c]) for a, b, c in before]
      and after == [(0, len(d.lines[2]), m.HL["str"])], (before, after))
p = m.paint("if x:", [(0, 2, m.HL["kw"])], 0, 8)
check("paint: colours, then pads to the width", p.startswith(m.HL["kw"] + "if") and p.endswith(" " * 3) and m.visible("if x:", 0, 8) == "if x:")

# wrapping long lines (on by default; Alt+Z turns it off)
check("wrap_points: rows of the width; a wide char that does not fit goes whole to the next row",
      m.wrap_points("abcdefghij", 4) == [(0, 0), (4, 4), (8, 8)] and m.wrap_points("ab你", 3) == [(0, 0), (2, 2)]
      and m.wrap_points("short", 40) == [(0, 0)])
W = os.path.join(T, "wrap"); os.makedirs(W)
open(os.path.join(W, "long.py"), "w").write("x = '" + "a" * 90 + "'\n" + "\n".join(f"y{i} = {i}" for i in range(60)) + "\n")
app = m.App(W, os.path.join(W, "long.py")); app.size = (60, 20)
d = app.doc(); tw_ = app.textw(d)
rows = app.rows(d, 17)
check("a long line takes several screen rows; only its first row has a line number",
      [(n, k) for n, k, _ in rows[:4]] == [(0, 0), (0, 1), (0, 2), (1, 0)] and rows[0][2][1] == (tw_, tw_), (rows[:4], tw_))
import re
plain = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", app.draw())
check("draw: the wrapped rows show the whole line, nothing cut", plain.count("a" * tw_) == 1 and "a" * (90 - tw_ - (tw_ - 5)) + "'" in plain,
      plain[:400])
d.cx = 5; app.key("\x1b[B")
check("Down inside a wrapped line goes to the row below, same column", (d.cy, d.cx) == (0, 5 + tw_), (d.cy, d.cx))
app.key("\x1b[B"); app.key("\x1b[B")
check("…and on past its last row to the next line", d.cy == 1, (d.cy, d.cx))
app.key("\x1b[A")
check("Up comes back to the long line's last row", d.cy == 0 and d.cx >= 2 * tw_, (d.cy, d.cx))
app.key(("mouse", 0, app.gutter(d) + 4, 4))     # second screen row of the code, 4th column of text
check("mouse: a click on a wrapped row puts the cursor in that part of the line", (d.cy, d.cx) == (0, tw_ + 3), (d.cy, d.cx))
app.key("\x1bz")
check("Alt+Z: no wrap; one row per line, Down goes to the next line", not app.wrap and [n for n, _, _ in app.rows(d, 5)] == [0, 1, 2, 3, 4]
      and (app.key("\x1b[B") or d.cy == 1), app.rows(d, 5))
app.key("\x1bz")
app.key("\x1b[1;5F"); app.draw()
check("the cursor at the end of the file stays on screen", (d.cy, 0) in [(n, k) for n, k, _ in app.rows(d, 17)], (d.cy, d.top))
for _ in range(30): app.key(("mouse", 65, 5, 5))
app.key(("mouse", 64, 5, 5)); app.draw()
check("the wheel scrolls; the cursor follows onto the screen", d.cy in [n for n, _, _ in app.rows(d, 17)])

# scrollbars, the divider, ☰, reopening at a bigger size
check("slider: none when all fits; at the top, the middle and the end of the file",
      m.slider(10, 0, 20, 10) is None and m.slider(100, 0, 10, 10)[:2] == [True, False]
      and m.slider(100, 90, 10, 10)[-1] is True and sum(m.slider(100, 45, 10, 10)) == 1 and m.slider(100, 45, 10, 10).index(True) in (4, 5))
S = os.path.join(T, "sb"); os.makedirs(S)
open(os.path.join(S, "big.py"), "w").write("\n".join(f"v{i} = {i}" for i in range(500)) + "\n")
app = m.App(S, os.path.join(S, "big.py")); app.size = (100, 30)
d = app.doc(); w, h, tw, ew, bh = app.layout()
check("layout: the code's last column is its scrollbar", app.textw(d) == ew - app.gutter(d) - 1, (app.textw(d), ew))
scr = app.draw()
check("draw: the scrollbar's track and slider are on screen", m.C["track"] in scr and m.C["thumb"] in scr)
app.key(("mouse", 0, ew, 2 + bh)); app.key(("release", 0, ew, 2 + bh)); app.draw()
check("click at the bottom of the code's scrollbar: the end of the file, the cursor comes along",
      d.top >= 500 - bh - 1 and d.cy >= d.top, (d.top, d.cy))
app.key(("mouse", 0, ew, 3)); app.key(("mouse", 32, ew, 3 + bh // 2)); app.key(("release", 0, ew, 3 + bh // 2)); app.draw()
check("drag the code's slider to the middle: the middle of the file", 200 <= d.top <= 300 and app.drag is None, d.top)
app.key(("mouse", 0, ew + 1, 10)); app.key(("mouse", 32, 50, 10)); app.key(("release", 0, 50, 10))
check("drag the divider left: the files get wider", app.layout()[2] == 100 - 50 and app.layout()[3] == 49, app.layout())
app.key(("mouse", 0, app.layout()[3] + 1, 10)); app.key(("mouse", 32, 2, 10)); app.key(("release", 0, 2, 10))
check("…never so far that the code gets narrower than its minimum", app.layout()[3] == m.CODE_MIN, app.layout())
app.key(("mouse", 0, app.layout()[3] + 1, 10)); app.key(("mouse", 32, 99, 10)); app.key(("release", 0, 99, 10))
check("…nor the files narrower than theirs", app.layout()[2] == m.TREE_MIN, app.layout())
app.draw(); bx = app.burger[0] + 2
app.key(("mouse", 0, bx, 1))
check("☰ hides the files: the code takes the whole width", app.tree_hidden and app.layout()[2] == 0 and app.layout()[3] == 100)
app.draw(); app.key(("mouse", 0, app.burger[0] + 2, 1))
check("☰ again brings them back", not app.tree_hidden and app.layout()[2] > 0)
app.key(("mouse", 0, app.burger[0] + 2, 1)); app.focus = "edit"; app.key("\x05")
check("Ctrl+E also brings hidden files back, focused", not app.tree_hidden and app.focus == "tree")
check("needs_refit: only when the window grew past the view since it opened",
      m.needs_refit((138, 45), (185, 46), (138, 45)) and not m.needs_refit((185, 46), (185, 46), (138, 45))
      and not m.needs_refit((138, 45), (120, 40), (138, 45)) and not m.needs_refit(None, (185, 46), (80, 24))
      and not m.needs_refit((138, 45), None, (138, 45)))
app.focus = "edit"; d.cy, d.cx = 3, 0; d.insert("# unsaved "); app.wrap = False; app.tree.open.add(S)
st = json.loads(json.dumps(m.dump_state(app)))
b2 = m.load_state(st); d2 = b2.doc()
check("reopening hands over the files, unsaved text, cursor, scroll, wrap and widths",
      d2 and d2.lines[3] == "# unsaved v3 = 3" and d2.modified and (d2.cy, d2.cx, d2.top) == (d.cy, d.cx, d.top)
      and b2.wrap is False and b2.tree_w == app.tree_w and b2.focus == "edit", (d2 and d2.lines[3], b2.focus))

# Ctrl+F: find in the file
lines = ["Alpha beta", "alpha ALPHA", "gamma", "beta alpha"]
check("find_all: lower case matches any case; a capital matches exactly",
      [(n, a_) for n, a_, _ in m.find_all(lines, "alpha")] == [(0, 0), (1, 0), (1, 6), (3, 5)]
      and [(n, a_) for n, a_, _ in m.find_all(lines, "Alpha")] == [(0, 0)] and m.find_all(lines, "") == [])
check("find_all stops counting at its limit", len(m.find_all(["aaaa"] * 5000, "a")) == m.MAX_HITS)
H = m.find_all(lines, "alpha")
check("hit_from: from a place, before it, and round the end of the file",
      m.hit_from(H, (1, 3)) == 2 and m.hit_from(H, (3, 6)) == 0 and m.hit_from(H, (1, 0), back=True, same=False) == 0
      and m.hit_from(H, (0, 0), back=True, same=False) == 3 and m.hit_from([], (0, 0)) is None)
F = os.path.join(T, "find"); os.makedirs(F)
open(os.path.join(F, "f.py"), "w").write("\n".join(lines) + "\n")
app = m.App(F, os.path.join(F, "f.py")); app.size = (100, 30); d = app.doc()
d.cy, d.cx = 1, 3
app.key("\x06"); [app.key(c) for c in "alpha"]
check("Ctrl+F, typing: the cursor goes to the first match from where it was", (d.cy, d.cx) == (1, 6) and app.find["q"] == "alpha")
scr = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", app.draw())
check("the bar shows the count; matches on screen are coloured, the current one brighter",
      "Find: alpha" in scr and "3 of 4" in scr and m.HL["hit_on"] in app.draw() and m.HL["hit"] in app.draw(), scr[-200:])
app.key("\r"); n1 = (d.cy, d.cx); app.key("\r"); n2 = (d.cy, d.cx)
check("Enter: the next match, then round to the top", n1 == (3, 5) and n2 == (0, 0) and app.msg == "back at the top", (n1, n2, app.msg))
app.key("\x1b[A")
check("↑: the previous match, round the bottom", (d.cy, d.cx) == (3, 5))
app.key("\x7f"); app.key("\x7f"); app.key("\x7f"); app.key("\x7f"); app.key("\x7f"); [app.key(c) for c in "zzz"]
check("no match: says so; the cursor stays", app.find["hits"] == [] and "no match" in re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", app.draw()))
app.key("\x7f"); app.key("\x7f"); app.key("\x7f"); [app.key(c) for c in "gamma"]; app.key("esc")
check("Esc closes it; the cursor stays on the match; typing then edits the code there",
      app.find is None and (d.cy, d.cx) == (2, 0) and (app.key("X") or d.lines[2] == "Xgamma"))
app.key("\x06")
check("Ctrl+F again opens with the last search, marked: typing replaces it", app.find["q"] == "gamma" and app.find["fresh"])
app.key("b")
check("…the first key typed replaces it", app.find["q"] == "b")
app.key(("paste", "eta\nignored"))
check("a paste goes into the find box (its first line only)", app.find["q"] == "beta" and d.lines[0] == "Alpha beta")
app.key("\x1b[D")
check("another key (←) closes the finder and does its own job", app.find is None)
app2 = m.App(F); app2.size = (100, 30); app2.key("\x06")
check("Ctrl+F with no file open says so", app2.find is None and "open a file" in app2.msg)

# the app: tree, tabs, delete, quit, the mouse
P = os.path.join(T, "p"); os.makedirs(os.path.join(P, "src")); os.makedirs(os.path.join(P, ".git"))
open(os.path.join(P, "src", "a.py"), "w").write("print(1)\n"); open(os.path.join(P, "z.txt"), "w").write("z\n")
app = m.App(P); app.size = (120, 30)
names = [os.path.basename(i[1]) for i in app.tree.items]
check("tree: folders first, .git hidden", names == ["src", "z.txt"], names)
app.key("\r"); app.key("\x1b[B"); app.key("\r")
check("tree: Enter opens a folder, then a file in a tab with the cursor in it",
      app.doc() and app.doc().path.endswith("src/a.py") and app.focus == "edit")
import re
screen = re.sub(r"\x1b\[[0-9;?]*[A-Za-z]", "", app.draw())     # the text without colours
check("draw: the tab, the path, line numbers and the tree are on screen", "a.py" in screen and "src/a.py" in screen and "print(1)" in screen and "▾ src" in screen)
app.key("x"); app.key("\x05"); app.key("\x1b[B"); app.key("\x1b[3~")
check("Delete on a file in the tree asks first", app.ask and "z.txt" in app.ask[0])
app.key("n")
check("…and 'n' keeps it", os.path.exists(os.path.join(P, "z.txt")) and app.msg == "nothing deleted")
app.key("\x1b[3~"); app.key("y")
check("…and 'y' deletes it, the tree updates", not os.path.exists(os.path.join(P, "z.txt")) and all(i[1] is None or not i[1].endswith("z.txt") for i in app.tree.items))
app.key("\x1b[A"); app.key("\x1b[A"); app.key("\x1b[3~")
check("Delete on a folder is refused", "only files" in app.msg and os.path.isdir(os.path.join(P, "src")))
app.key("\x11")
check("Ctrl+Q with an edit not saved asks; 'n' stays", app.ask and "not saved" in app.ask[0])
app.key("n")
check("…stays open", not app.quit)
app.key(("mouse", 0, 3, 1))     # click the tab's name
check("mouse: a click on a tab focuses the code", app.focus == "edit")
app.key(("mouse", 0, 8, 3))
check("mouse: a click in the code puts the cursor there", (app.doc().cy, app.doc().cx) == (0, 3), (app.doc().cy, app.doc().cx))
app.key("\x13")
check("Ctrl+S saves", open(os.path.join(P, "src", "a.py")).read() == "xprint(1)\n" and not app.doc().modified and app.msg.startswith("saved"))
open(os.path.join(P, "src", "a.py"), "w").write("changed elsewhere\n"); os.utime(os.path.join(P, "src", "a.py"), (1, 1))
app.key("y")                                    # an edit, then save over the change made elsewhere
app.key("\x13")
asked = bool(app.ask) and "changed on disk" in app.ask[0]
app.key("n")
check("Ctrl+S after the file changed on disk asks before overwriting; 'n' keeps the other change",
      asked and open(os.path.join(P, "src", "a.py")).read() == "changed elsewhere\n")
app.draw()                                      # the tab now shows ● : spans move
x = app.tab_spans[0]
app.key(("mouse", 0, x[1], 1))                 # the "×"
check("mouse: the tab's × asks to close an edited file", app.ask and "close it anyway" in app.ask[0])
app.key("y")
check("…'y' closes it, focus goes back to the files", not app.docs and app.focus == "tree")
app.key("\x11")
check("Ctrl+Q with nothing open quits at once", app.quit)
print(f"UNITS {ok} {bad}")
sys.exit(1 if bad else 0)
EOF
urc=$?

echo "in a terminal (tmux)"
pass=0; fail=0
ok()  { pass=$((pass + 1)); printf '  ok    %s\n' "$1"; }
bad() { fail=$((fail + 1)); printf '  FAIL  %s\n' "$1"; [[ -n "${2:-}" ]] && printf '%s\n' "$2" | head -20 | sed 's/^/        /'; }
wait_for() {   # text [tries]: until the screen shows it (at most ~3 s)
  local i; for ((i = 0; i < ${2:-30}; i++)); do tm capture-pane -p -t t 2>/dev/null | grep -qF -- "$1" && return 0; python3 -c 'import time; time.sleep(0.1)'; done; return 1
}
P="$T/proj"; mkdir -p "$P/src"
printf 'def hello():\n\tprint("hi 你好")\n\nx = 1\n' > "$P/src/app.py"
tm new-session -d -x 120 -y 30 -s t "$T/afc-ide $P"
tm set -g remain-on-exit on
wait_for "▸ src" && ok "starts: the tree of the folder on the right" || bad "start" "$(tm capture-pane -p -t t)"
tm send-keys -t t Enter Down Enter
wait_for 'print("hi 你好")' && wait_for "Ln 1, Col 1" && ok "opens a file from the tree: line numbers, tabs, wide characters" || bad "open" "$(tm capture-pane -p -t t)"
tm send-keys -t t Down End Enter; tm send-keys -t t -l 'return 2'; tm send-keys -t t C-s
wait_for "saved src/app.py" && grep -q $'^\treturn 2$' "$P/src/app.py" && ok "types with the indent kept, Ctrl+S saves" || bad "type and save" "$(cat "$P/src/app.py")"
tm send-keys -t t C-Home C-k C-s
wait_for "saved src/app.py" && [[ "$(head -1 "$P/src/app.py")" == $'\tprint("hi 你好")' ]] && ok "Ctrl+K deletes the line" || bad "delete line" "$(cat "$P/src/app.py")"
tm send-keys -t t C-z C-s
python3 -c 'import time; time.sleep(0.3)'
[[ "$(head -1 "$P/src/app.py")" == "def hello():" ]] && ok "Ctrl+Z brings it back" || bad "undo" "$(cat "$P/src/app.py")"
tm send-keys -t t C-f; tm send-keys -t t -l 'hello'; tm send-keys -t t Escape; python3 -c 'import time; time.sleep(0.2)'
tm send-keys -t t -l '_'; tm send-keys -t t C-s
wait_for "saved src/app.py" && grep -q '^def _hello():' "$P/src/app.py" && ok "Ctrl+F finds the word; Esc; typing goes in at the match" || bad "find" "$(head -2 "$P/src/app.py")"
tm send-keys -t t -l 'zz'; tm send-keys -t t C-q
wait_for "not saved: quit anyway" && ok "Ctrl+Q asks when an edit is not saved" || bad "quit ask" "$(tm capture-pane -p -t t | tail -2)"
tm send-keys -t t y
wait_for "Pane is dead" 30 && [[ "$(head -1 "$P/src/app.py")" == "def _hello():" ]] && ok "'y' quits without saving, the terminal is given back" || bad "quit" "$(tm capture-pane -p -t t | tail -3)"

echo "Alt+I in a real tmux client (keys typed into its terminal, as a person would)"
nap() { python3 -c "import time; time.sleep($1)"; }
size_of() {   # the terminal size of the code view now running (columns x rows), or nothing
  local p t
  for p in $(pgrep -f "python3 -I $T/afc-ide"); do
    t=$(readlink "/proc/$p/fd/0" 2>/dev/null); [[ $t == /dev/pts/* ]] || continue
    python3 -c "
import fcntl, termios, struct
with open('/proc/$p/fd/0', 'rb') as f: r, c, _, _ = struct.unpack('hhhh', fcntl.ioctl(f, termios.TIOCGWINSZ, bytes(8)))
print(f'{c}x{r}')"
  done
}
if ! command -v script >/dev/null || [[ ! -d /proc/self/fd ]]; then echo "  skip  needs script(1) and /proc"; else
  Q="$T/pop"; mkdir -p "$Q/src"; printf 'alpha\nbeta\n' > "$Q/notes.txt"
  # the repo's Alt+I line, running this folder's afc-ide
  grep '^bind -n M-i ' "$HERE/tmux/tmux.conf" | sed "s#~/.local/bin/afc-ide#$T/afc-ide#" > "$T/popup.conf"
  mkfifo "$T/keys"; exec 9<>"$T/keys"
  tp new-session -d -x 120 -y 30 -s p -c "$Q"
  (script -qfc "stty cols 120 rows 30; $TM -L ${SOCK}p attach -t p" /dev/null < "$T/keys" >/dev/null 2>&1 &)
  nap 1
  C=$(tp list-clients -F '#{client_name}')
  printf '\033i' >&9; nap 1.2                                   # Alt+I
  [[ "$(size_of)" == 120x30 ]] && ok "Alt+I opens the view full screen: the whole client, status line too (120x30)" || bad "full screen" "view: $(size_of)"
  printf '\033[B\r' >&9; nap 0.4; printf 'X' >&9; printf '\023' >&9; nap 0.5   # Down, Enter (notes.txt), X, Ctrl+S
  [[ "$(head -1 "$Q/notes.txt")" == Xalpha ]] && ok "real keys reach it: arrows, Enter, typing, Ctrl+S" || bad "keys" "$(head -1 "$Q/notes.txt")"
  printf 'Y' >&9; nap 0.3                                         # an edit not saved
  python3 -c "
import fcntl, termios, struct, os
fd = os.open('$C', os.O_RDWR); fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('hhhh', 40, 160, 0, 0)); os.close(fd)"
  kill -WINCH "$(pgrep -f "$TM -L ${SOCK}p attach" | head -1)"
  for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15 16 17 18 19 20 21 22 23 24 25; do [[ "$(size_of)" == 160x40 ]] && break; nap 0.2; done
  [[ "$(size_of)" == 160x40 ]] && ok "the window grows (160x40): the view reopens at the new size by itself" || bad "reopen" "view: $(size_of)"
  printf '\023' >&9; nap 0.5                                     # Ctrl+S in the reopened view
  [[ "$(head -1 "$Q/notes.txt")" == XYalpha ]] && ok "…with the edit that was not saved yet, the file and the cursor as they were" || bad "handover" "$(head -1 "$Q/notes.txt")"
  ls "${XDG_RUNTIME_DIR:-/tmp}"/afc-ide-*.json >/dev/null 2>&1 && bad "a handover file was left behind" || ok "…and no handover file is left behind"
  printf '\021' >&9; nap 0.5                                     # Ctrl+Q
  [[ -z "$(size_of)" ]] && ok "Ctrl+Q closes it" || bad "close" "view: $(size_of)"
  tp kill-server 2>/dev/null
fi

echo
echo "units: $([[ $urc == 0 ]] && echo passed || echo FAILED); terminal: $pass passed, $fail failed"
(( KEEP )) && echo "kept: $T"
(( urc == 0 && fail == 0 ))
