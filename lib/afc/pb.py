"""pb: just enough protobuf reading for Antigravity's records, with no protobuf library.

Antigravity (agy) keeps its chats in SQLite, one binary protobuf blob per step or reply. There is
no schema to load, so these helpers walk the wire format and leave it to the caller to know which
field number holds what (worked out by inspection on 2026-11-13; it may move with an agy update).

Shared by ~/.local/bin/afc-agent-info (header bar) and ~/.local/bin/afc-logs (chat log).
"""


def pb_fields(buf):
    """Top-level fields of a protobuf message as (number, value); value is an int or bytes."""
    i, n = 0, len(buf)
    try:
        while i < n:
            key = shift = 0
            while True:
                x = buf[i]; i += 1; key |= (x & 127) << shift; shift += 7
                if x < 128: break
            num, wire = key >> 3, key & 7
            if wire == 0:
                val = shift = 0
                while True:
                    x = buf[i]; i += 1; val |= (x & 127) << shift; shift += 7
                    if x < 128: break
                yield num, val
            elif wire == 2:
                size = shift = 0
                while True:
                    x = buf[i]; i += 1; size |= (x & 127) << shift; shift += 7
                    if x < 128: break
                yield num, bytes(buf[i:i + size]); i += size
            elif wire == 1: i += 8
            elif wire == 5: i += 4
            else: return
    except IndexError:
        return


def pb_get(buf, *path):
    """First value at a path of field numbers, or None."""
    for depth, want in enumerate(path):
        for num, val in pb_fields(buf):
            if num == want:
                if depth == len(path) - 1:
                    return val
                if not isinstance(val, bytes):
                    return None
                buf = val
                break
        else:
            return None
    return None


def pb_all(buf, num):
    """Every value of a repeated field."""
    return [v for n, v in pb_fields(buf or b"") if n == num]


def pb_text(val):
    """bytes -> str when they are readable text (UTF-8, printable apart from line breaks), else None."""
    if not isinstance(val, bytes) or not val:
        return None
    try:
        s = val.decode("utf-8")
    except UnicodeDecodeError:
        return None
    return s if all(c.isprintable() or c in "\n\r\t" for c in s) else None


def pb_strings(buf, skip=(), depth=0, path=""):
    """Every readable text string in a message, depth first, as (dotted path, text). Fields whose
    path starts with an entry of `skip` are left out."""
    out = []
    for num, val in pb_fields(buf or b""):
        p = f"{path}.{num}" if path else str(num)
        if any(p == s or p.startswith(s + ".") for s in skip):
            continue
        if isinstance(val, bytes):
            s = pb_text(val)
            if s is not None and len(s) >= 2:
                out.append((p, s))
            elif depth < 10:
                out.extend(pb_strings(val, skip, depth + 1, p))
    return out
