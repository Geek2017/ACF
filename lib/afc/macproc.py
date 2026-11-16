"""macproc: what the fleet reads from /proc on Linux, asked of macOS instead.

macOS has no /proc. The same facts come from libproc and sysctl, reached through ctypes, so there
is nothing to install. Only this user's own processes can be read, which is all the fleet looks at.
Used by afc-procfs (for the shell programs) and afc-agent-info. Never imported on Linux.
"""
import ctypes, ctypes.util, struct

_libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
_libproc = ctypes.CDLL("/usr/lib/libproc.dylib", use_errno=True)

# The fleet tells the agents apart by the short process name Linux shows. On a Mac two of them
# are called something else: Claude's program file is claude.exe, Antigravity's is antigravity.
NAMES = {"claude.exe": "claude", "antigravity": "agy"}

_BSDINFO, _VNODEPATH, _FDLIST, _FDPATH = 3, 9, 1, 2      # proc_pidinfo / proc_pidfdinfo flavors
_BSDINFO_SIZE, _VNODEPATH_SIZE, _FDPATH_SIZE = 136, 2352, 1200
_VINFO, _FILEINFO, _PATH = 152, 24, 1024                 # sizes inside those structs
_VNODE_FD = 1


def _cstr(raw):
    return raw.split(b"\0", 1)[0].decode("utf-8", "replace")


def info(pid):
    """(parent pid, short name, start time in seconds) of one process, or None."""
    buf = ctypes.create_string_buffer(_BSDINFO_SIZE)
    if _libproc.proc_pidinfo(pid, _BSDINFO, ctypes.c_uint64(0), buf, _BSDINFO_SIZE) != _BSDINFO_SIZE:
        return None
    raw = buf.raw
    name = _cstr(raw[64:96]) or _cstr(raw[48:64])
    return struct.unpack("I", raw[16:20])[0], NAMES.get(name, name), struct.unpack("Q", raw[120:128])[0]


def table():
    """{pid: (parent pid, short name, start time)} of every process that can be read."""
    n = _libproc.proc_listallpids(None, 0)
    pids = (ctypes.c_int * (max(n, 0) + 256))()
    n = _libproc.proc_listallpids(pids, ctypes.sizeof(pids))
    out = {}
    for pid in pids[:max(n, 0)]:
        if pid > 0:
            i = info(pid)
            if i:
                out[pid] = i
    return out


def under(pid, procs, levels=4):
    """The pids running under one, that many levels down (the pid itself comes first)."""
    kids = {}
    for p, (ppid, _, _) in procs.items():
        kids.setdefault(ppid, []).append(p)
    out, level = [pid], [pid]
    for _ in range(levels):
        level = [k for p in level for k in kids.get(p, [])]
        if not level:
            break
        out += level
    return out


def argv_env(pid):
    """(arguments, environment as a dict) of one process; ([], {}) when it cannot be read."""
    mib = (ctypes.c_int * 3)(1, 49, pid)                 # CTL_KERN, KERN_PROCARGS2
    size = ctypes.c_size_t(0)
    if _libc.sysctl(mib, 3, None, ctypes.byref(size), None, 0) != 0 or not size.value:
        return [], {}
    buf = ctypes.create_string_buffer(size.value)
    if _libc.sysctl(mib, 3, buf, ctypes.byref(size), None, 0) != 0:
        return [], {}
    raw = buf.raw[:size.value]
    if len(raw) < 4:
        return [], {}
    argc = struct.unpack("i", raw[:4])[0]
    rest = raw[4:].split(b"\0", 1)                       # the program's path, then padding
    parts = rest[1].lstrip(b"\0").split(b"\0") if len(rest) > 1 else []
    argv = [a.decode("utf-8", "replace") for a in parts[:argc]]
    env = {}
    for e in parts[argc:]:
        if b"=" in e:
            k, v = e.split(b"=", 1)
            env[k.decode("utf-8", "replace")] = v.decode("utf-8", "replace")
    return argv, env


def cwd(pid):
    """The folder a process is in, or ''."""
    buf = ctypes.create_string_buffer(_VNODEPATH_SIZE)
    if _libproc.proc_pidinfo(pid, _VNODEPATH, ctypes.c_uint64(0), buf, _VNODEPATH_SIZE) <= 0:
        return ""
    return _cstr(buf.raw[_VINFO:_VINFO + _PATH])


def open_files(pid):
    """[(fd, path)] of the files a process holds open (files only: no sockets or pipes)."""
    size = _libproc.proc_pidinfo(pid, _FDLIST, ctypes.c_uint64(0), None, 0)
    if size <= 0:
        return []
    buf = ctypes.create_string_buffer(size + 8 * 32)
    size = _libproc.proc_pidinfo(pid, _FDLIST, ctypes.c_uint64(0), buf, ctypes.sizeof(buf))
    out = []
    for i in range(0, max(size, 0) - 7, 8):
        fd, kind = struct.unpack("iI", buf.raw[i:i + 8])
        if kind != _VNODE_FD:
            continue
        one = ctypes.create_string_buffer(_FDPATH_SIZE)
        if _libproc.proc_pidfdinfo(pid, fd, _FDPATH, one, _FDPATH_SIZE) > 0:
            path = _cstr(one.raw[_FILEINFO + _VINFO:_FILEINFO + _VINFO + _PATH])
            if path:
                out.append((fd, path))
    return out
