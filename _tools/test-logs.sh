#!/usr/bin/env bash
# test-logs.sh: tests for bin/afc-logs (chat log ingestion, redaction, SQLite locking/journal mode,
# search/show/handoff/summary, and boundary/failure paths). Touches nothing of yours: its own fake
# HOME, cache, project folder and synthetic Claude/Codex/Gemini chat files under one temp folder.
#
#   bash _tools/test-logs.sh              test bin/afc-logs of this folder
#   bash _tools/test-logs.sh --keep       leave the temp folder for inspection
set -uo pipefail
HERE="$(cd "$(dirname "$0")/.." && pwd)"
LOGS="$HERE/bin/afc-logs"
KEEP=0
while (( $# )); do
  case "$1" in
    --keep) KEEP=1 ;;
    *) sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'; exit 2 ;;
  esac
  shift
done

T=$(mktemp -d /tmp/acf-test-logs.XXXXXX)
trap '(( KEEP )) && echo "kept: $T" || rm -rf "$T"' EXIT

H="$T/home"
PROJ="$T/proj"
CACHE="$T/cache"
LIST="$T/log-projects"
mkdir -p "$H/.config/agents" "$H/.claude/projects/testproj" \
         "$H/.codex/sessions/2026/11/25" \
         "$H/.gemini/tmp/projhash/chats" \
         "$PROJ" "$CACHE"

# Synthetic project marker
printf 'proj\n' > "$PROJ/CLAUDE.md"
printf '%s\n' "$PROJ" > "$H/.gemini/tmp/projhash/.project_root"

# Synthetic Claude JSONL with secrets + one malformed line
CLAUDE_SRC="$H/.claude/projects/testproj/11111111-1111-1111-1111-111111111111.jsonl"
cat > "$CLAUDE_SRC" <<EOF
{"type":"user","timestamp":"2026-11-25T10:00:00Z","cwd":"$PROJ","message":{"role":"user","content":"Fix token sk-ant-1234567890abcdefghij and API_KEY=supersecretvalue99 and https://alice:hunter2@db.local/app"}}
not valid json at all {{{
{"type":"assistant","timestamp":"2026-11-25T10:00:05Z","cwd":"$PROJ","message":{"role":"assistant","model":"claude-opus-4-7","content":[{"type":"text","text":"Checked ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 and fixed the parser."}]}}
EOF

# Synthetic Codex JSONL
CODEX_SRC="$H/.codex/sessions/2026/11/25/rollout-2026-11-25T10-01-00-22222222-2222-2222-2222-222222222222.jsonl"
cat > "$CODEX_SRC" <<EOF
{"timestamp":"2026-11-25T10:01:00Z","type":"session_meta","payload":{"id":"22222222-2222-2222-2222-222222222222","cwd":"$PROJ"}}
{"timestamp":"2026-11-25T10:01:02Z","type":"response_item","payload":{"type":"message","role":"user","content":[{"type":"input_text","text":"Audit codex migration path"}]}}
{"timestamp":"2026-11-25T10:01:06Z","type":"response_item","payload":{"type":"message","role":"assistant","content":[{"type":"output_text","text":"Verified codex rollout ingestion."}]}}
EOF

# Synthetic Gemini JSONL
GEMINI_SRC="$H/.gemini/tmp/projhash/chats/session-2026-11-25T10-02-33333333.jsonl"
cat > "$GEMINI_SRC" <<EOF
{"sessionId":"33333333-3333-3333-3333-333333333333","startTime":"2026-11-25T10:02:00.000Z"}
{"id":"m1","type":"user","timestamp":"2026-11-25T10:02:01.000Z","content":"Check gemini effort limits"}
{"id":"m2","type":"gemini","timestamp":"2026-11-25T10:02:04.000Z","model":"gemini-4-neon","content":"Gemini effort is verified."}
EOF

run_logs() {
  env -u AFC_LOGS_CACHE -u AFC_LOGS_LIST -u AFC_LOGS_HOME \
    HOME="$H" AFC_LOGS_CACHE="$CACHE" AFC_LOGS_LIST="$LIST" AFC_LOGS_HOME="$PROJ" \
    python3 "$LOGS" "$@"
}

pass=0; fail=0
ok()  { echo "  ok:   $1"; pass=$((pass + 1)); }
bad() { echo "  FAIL: $1${2:+ ($2)}"; fail=$((fail + 1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1" "${3:-}"; fi; }

echo "1. Dry-run and initial ingestion"
dry_out=$(run_logs run --dry-run --force 2>&1)
check "dry-run reports changed files without creating acf.db" \
  '[[ "$dry_out" == *"DRY RUN:"* && ! -e "$PROJ/logs/acf/acf.db" ]]' "$dry_out"

run_out=$(run_logs run --force 2>&1)
DB="$PROJ/logs/acf/acf.db"
check "run --force creates acf.db and ingests Claude, Codex, Gemini" \
  '[[ -f "$DB" && "$run_out" == *"claude"* && "$run_out" == *"codex"* && "$run_out" == *"gemini"* ]]' "$run_out"

echo "2. SQLite safety, journal mode, permissions, and concurrent RO reader"
py_check=$(python3 - "$DB" <<'PY'
import os, sqlite3, sys
db_path = sys.argv[1]
mode = os.stat(db_path).st_mode & 0o777
con = sqlite3.connect(db_path, timeout=10)
jm = con.execute("PRAGMA journal_mode").fetchone()[0].lower()
threads = dict(con.execute("SELECT tool, count(*) FROM threads GROUP BY tool").fetchall())
texts = [r[0] for r in con.execute("SELECT text FROM entries").fetchall()]
# Concurrent read-only connection while writer connection is open
ro = sqlite3.connect(f"file:{db_path}?mode=ro", uri=True, timeout=5)
ro_count = ro.execute("SELECT count(*) FROM entries").fetchone()[0]
ro.close()
con.close()
joined = "\n".join(texts)
print(f"mode={oct(mode)} jm={jm} tools={sorted(threads.items())} ro={ro_count}")
assert mode == 0o600, f"expected 0600, got {oct(mode)}"
assert jm == "delete", f"expected delete journal mode for NTFS safety, got {jm}"
assert threads.get("claude") == 1 and threads.get("codex") == 1 and threads.get("gemini") == 1, threads
assert ro_count >= 6, f"expected >=6 entries, got {ro_count}"
# Secret redaction checks
for leak in ("sk-ant-1234567890abcdefghij", "supersecretvalue99", "hunter2", "ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789"):
    assert leak not in joined, f"secret leaked into acf.db: {leak}"
assert "[redacted]" in joined, "expected [redacted] marker"
assert "fixed the parser" in joined and "Verified codex rollout ingestion" in joined and "Gemini effort is verified" in joined
PY
)
rc=$?
check "acf.db is 0600, DELETE journal mode, concurrent RO safe, and redacts all secrets" '[[ $rc -eq 0 ]]' "$py_check"

echo "3. Incremental append and file truncation re-read"
cat >> "$CLAUDE_SRC" <<EOF
{"type":"user","timestamp":"2026-11-25T10:05:00Z","cwd":"$PROJ","message":{"role":"user","content":"Follow-up incremental marker alpha99"}}
EOF
inc_out=$(run_logs run --force 2>&1)
check "incremental run appends only the new entry" \
  '[[ "$inc_out" == *"1 changed source file(s), added 1 entries"* ]]' "$inc_out"

# Truncate/rewrite smaller file: offset must reset to 0
cat > "$CLAUDE_SRC" <<EOF
{"type":"user","timestamp":"2026-11-25T10:06:00Z","cwd":"$PROJ","message":{"role":"user","content":"Rewritten shorter file marker beta77"}}
EOF
trunc_out=$(run_logs run --force 2>&1)
srch_beta=$(cd "$PROJ" && run_logs search beta77 2>&1)
check "truncated source file re-reads from byte 0" \
  '[[ "$srch_beta" == *"beta77"* ]]' "$trunc_out | $srch_beta"

echo "4. CLI query commands (status, threads, search, show, handoff, summary, prune-md)"
st_out=$(cd "$PROJ" && run_logs status 2>&1)
check "status reports threads and entries" '[[ "$st_out" == *"threads"* ]]' "$st_out"

th_out=$(cd "$PROJ" && run_logs threads 2>&1)
check "threads lists all 3 providers" '[[ "$th_out" == *"claude"* && "$th_out" == *"codex"* && "$th_out" == *"gemini"* ]]' "$th_out"

sh_out=$(cd "$PROJ" && run_logs show 11111111 2>&1)
check "show prints thread by prefix id" '[[ "$sh_out" == *"fixed the parser"* ]]' "$sh_out"

ho_out=$(cd "$PROJ" && run_logs handoff 11111111 --stdout 2>&1)
check "handoff --stdout emits pickup brief" '[[ "$ho_out" == *"acf.db"* && "$ho_out" == *"fixed the parser"* ]]' "$ho_out"

sum_out=$(cd "$PROJ" && run_logs summary "$PROJ" --stdout 2>&1)
sum_lines=$(printf '%s\n' "$sum_out" | wc -l)
check "summary --stdout is capped at <=50 lines" '[[ -n "$sum_out" && $sum_lines -le 50 ]]' "lines=$sum_lines"

pr_out=$(cd "$PROJ" && run_logs prune-md --dry-run 2>&1)
check "prune-md --dry-run succeeds cleanly" '[[ "$pr_out" == *"DRY RUN:"* ]]' "$pr_out"

echo "5. Boundary and failure cases"
(cd "$PROJ" && run_logs show nonexistent-id-9999 >/dev/null 2>&1); bad_rc=$?
check "show unknown thread exits non-zero" '[[ $bad_rc -ne 0 ]]' "rc=$bad_rc"

lock_out=$(python3 - "$CACHE/run.lock" "$LOGS" "$H" "$CACHE" "$LIST" "$PROJ" <<'PY'
import fcntl, os, subprocess, sys
lock_path, logs_bin, home, cache, lst, proj = sys.argv[1:]
with open(lock_path, "w") as lf:
    fcntl.flock(lf, fcntl.LOCK_EX | fcntl.LOCK_NB)
    env = dict(os.environ, HOME=home, AFC_LOGS_CACHE=cache, AFC_LOGS_LIST=lst, AFC_LOGS_HOME=proj)
    r = subprocess.run(["python3", logs_bin, "run", "--force"], env=env, capture_output=True, text=True, timeout=10)
    print(f"rc={r.returncode} out={r.stdout.strip()}")
PY
)
check "held run.lock skips cleanly with exit 0 instead of blocking or failing" \
  '[[ "$lock_out" == *"rc=0"* && "$lock_out" == *"another afc-logs run is going"* ]]' "$lock_out"

echo
echo "$pass passed, $fail failed"
(( fail == 0 ))
