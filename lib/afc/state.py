"""state: shared settings, per-project modes, and tmux helpers for ACF Python tools.

Single source of truth for reading/writing ~/.config/agents/settings,
~/.config/agents/project-modes.json, resolving the tmux binary/socket, and
reading/writing pane-scoped @doctrine / @mental_model options.

Shared by bin/afc-menu, bin/afc-rules, bin/afc-logs, and bin/afc-splash.
"""
import json
import os
import re
import shutil
import subprocess

HOME = os.path.expanduser("~")
CFG_DIR = os.path.join(HOME, ".config", "agents")


def settings_path(path=None):
    if path:
        return path
    return os.environ.get("AGENTS_SETTINGS") or os.path.join(CFG_DIR, "settings")


def project_modes_path(path=None):
    if path:
        return path
    return os.environ.get("AGENTS_PROJECT_MODES") or os.path.join(CFG_DIR, "project-modes.json")


def load_settings(path=None):
    """Parse key/value pairs from the fleet settings file (stripping inline '#' comments)."""
    p = settings_path(path)
    values = {}
    if not os.path.isfile(p):
        return values
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            for raw in f:
                line = raw.split("#", 1)[0].strip()
                if not line:
                    continue
                parts = line.split(None, 1)
                if len(parts) == 2:
                    values[parts[0]] = parts[1].strip()
    except OSError:
        pass
    if "view" not in values and "claude-view" in values:
        values["view"] = values["claude-view"]
    return values


def setting(name, default, path=None):
    """Read a single key from the fleet settings file, matching how `agents` reads it."""
    val = load_settings(path).get(name)
    if not val:
        return default
    return val.split()[0]


def save_setting(key, value, path=None):
    """Update an active line, uncomment a commented line, or append `<key> <value>` atomically."""
    p = settings_path(path)
    parent = os.path.dirname(p)
    if parent:
        os.makedirs(parent, exist_ok=True)
    lines = []
    if os.path.isfile(p):
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            lines = f.readlines()

    active_pat = re.compile(rf"^(\s*){re.escape(key)}(\s+)\S+(.*)$")
    commented_pat = re.compile(rf"^(\s*)#(\s*){re.escape(key)}(\s+)\S+(.*)$")

    replaced = False
    for idx, raw in enumerate(lines):
        m = active_pat.match(raw)
        if m:
            lines[idx] = f"{m.group(1)}{key}{m.group(2)}{value}{m.group(3)}\n"
            replaced = True
            break

    if not replaced:
        for idx, raw in enumerate(lines):
            m = commented_pat.match(raw)
            if m:
                lines[idx] = f"{m.group(1)}{key} {value}{m.group(4)}\n"
                replaced = True
                break

    if not replaced:
        if lines and not lines[-1].endswith("\n"):
            lines[-1] += "\n"
        lines.append(f"{key} {value}\n")

    tmp = f"{p}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        f.writelines(lines)
    os.replace(tmp, p)


def project_key_for(cwd):
    """Canonical project folder for per-project modes: nearest .git ancestor, else realpath(cwd)."""
    if not cwd:
        return ""
    try:
        d = os.path.realpath(os.path.expanduser(cwd))
    except OSError:
        return cwd
    cur = d
    while True:
        if os.path.exists(os.path.join(cur, ".git")):
            return cur
        up = os.path.dirname(cur)
        if up == cur:
            return d
        cur = up


def load_project_modes(path=None):
    p = project_modes_path(path)
    if not os.path.isfile(p):
        return {}
    try:
        with open(p, "r", encoding="utf-8", errors="replace") as f:
            data = json.load(f)
            return data if isinstance(data, dict) else {}
    except (OSError, ValueError):
        return {}


def _write_project_modes(data, path=None):
    p = project_modes_path(path)
    parent = os.path.dirname(p)
    if parent:
        os.makedirs(parent, exist_ok=True)
    tmp = f"{p}.{os.getpid()}.tmp"
    with open(tmp, "w", encoding="utf-8") as f:
        json.dump(data, f, indent=2, ensure_ascii=False)
        f.write("\n")
    os.replace(tmp, p)


def save_project_mode(proj_key, field, value, path=None):
    if not proj_key:
        return
    data = load_project_modes(path)
    entry = dict(data.get(proj_key) or {})
    if not value or value == "inherit":
        entry.pop(field, None)
    else:
        entry[field] = value
    if entry:
        data[proj_key] = entry
    else:
        data.pop(proj_key, None)
    _write_project_modes(data, path)


def clear_project_modes(proj_key, path=None):
    if not proj_key:
        return
    data = load_project_modes(path)
    if proj_key not in data:
        return
    data.pop(proj_key, None)
    _write_project_modes(data, path)


def find_tmux_bin():
    return (
        shutil.which("tmux")
        or next(
            (p for p in (os.path.join(HOME, ".local", "bin", "tmux"), "/usr/bin/tmux", "/opt/homebrew/bin/tmux")
             if os.path.exists(p)),
            "tmux",
        )
    )


def tmux_cmd(sock="", *args, default_sock=None, tmux_bin=None):
    exe = tmux_bin or find_tmux_bin()
    if sock:
        base = [exe, "-S", sock]
    else:
        base = [exe, "-L", default_sock or os.environ.get("AGENTS_SOCK") or "agents"]
    return base + list(args)


def read_pane_modes(tmux_base_cmd, pane_id, timeout=2):
    """Return (doctrine, mental_model) raw pane option strings, or ('', '') on error."""
    if not pane_id:
        return "", ""
    try:
        r = subprocess.run(
            list(tmux_base_cmd) + ["display-message", "-p", "-t", pane_id, "#{@doctrine}\t#{@mental_model}"],
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        if r.returncode != 0:
            return "", ""
        parts = r.stdout.rstrip("\n").split("\t")
        d = parts[0].strip() if len(parts) > 0 else ""
        m = parts[1].strip() if len(parts) > 1 else ""
        return d, m
    except (OSError, subprocess.SubprocessError):
        return "", ""


def write_pane_mode(tmux_base_cmd, pane_id, field, value, timeout=2):
    """Set or unset @doctrine / @mental_model on pane_id. Returns True on success."""
    if not pane_id:
        return False
    opt = "@doctrine" if field == "doctrine" else "@mental_model"
    sub = ["set", "-pu", "-t", pane_id, opt] if (not value or value == "inherit") else ["set", "-p", "-t", pane_id, opt, value]
    try:
        return subprocess.run(list(tmux_base_cmd) + sub, capture_output=True, timeout=timeout).returncode == 0
    except (OSError, subprocess.SubprocessError):
        return False
