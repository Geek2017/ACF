#!/usr/bin/env python3
"""tune-specs.py: compute machine-proportional ACF cgroup, autonice, and /tmp limits.

Detects host RAM (/proc/meminfo) and CPU cores (os.cpu_count), or accepts --ram-mib / --cpus
for simulation and testing. Always guarantees:
  agents_max + app_max + acchat_max <= total host RAM (on desktop Linux).

Usage:
  tune-specs.py --show [--ram-gb N] [--cpus N] [--headless]
  tune-specs.py --field <name> [--ram-gb N] [--cpus N] [--headless]
  tune-specs.py apply <relpath> <src> <dst> [--ram-gb N] [--cpus N] [--headless]
"""
import argparse
import os
import re
import sys


def detect_ram_mib():
    """Return total host RAM in MiB from /proc/meminfo (fallback 16384 MiB)."""
    try:
        with open("/proc/meminfo", encoding="utf-8") as f:
            for line in f:
                if line.startswith("MemTotal:"):
                    kb = int(line.split()[1])
                    if kb > 0:
                        return max(1024, kb // 1024)
    except (OSError, ValueError):
        pass
    return 16384


def detect_cpus():
    """Return logical CPU count (>= 1)."""
    return max(1, int(os.cpu_count() or 4))


def _clamp(val, lo, hi):
    return max(lo, min(hi, val))


def _round_step(val, step):
    return max(step, int(round(val / step)) * step)


def fmt_mem(mib):
    """Format MiB as clean systemd value ('12G' for exact GiB, else '12800M')."""
    mib = int(mib)
    if mib >= 1024 and mib % 1024 == 0:
        return f"{mib // 1024}G"
    return f"{mib}M"


def compute_limits(ram_mib, cpus, desktop=True):
    """Return deterministic, bounded resource limits sized to (ram_mib, cpus, desktop)."""
    ram_mib = max(2048, int(ram_mib))
    cpus = max(1, int(cpus))

    # CPU: leave ~40% of cores free for desktop UI; ~20% free on headless/WSL.
    if cpus == 1:
        agents_cpu = 80 if desktop else 90
    elif desktop:
        agents_cpu = _clamp(_round_step(cpus * 60, 50), 100, (cpus - 1) * 100)
    else:
        agents_cpu = _clamp(_round_step(cpus * 80, 50), 100, cpus * 100 - 50)
    council_cpu = _clamp(_round_step(agents_cpu * 0.85, 50), 100, agents_cpu)

    # Memory: keep hard ceilings strictly within host RAM.
    if desktop:
        acchat_max = _clamp(_round_step(ram_mib * 0.095, 128), 512, 4096)
        acchat_high = max(384, _round_step(acchat_max * 0.88, 128))
        agents_high = _clamp(_round_step(ram_mib * 0.51, 256), 1024, int(ram_mib * 0.60))
        agents_max = agents_high + _clamp(_round_step(ram_mib * 0.025, 256), 256, 2048)
        budget_max = int(ram_mib * 0.975)
        avail_for_app = max(512, budget_max - agents_max - acchat_max)
        app_max = _clamp(_round_step(avail_for_app, 256), 512, max(512, int(ram_mib * 0.42)))
        # Enforce strict sum invariant: agents_max + app_max + acchat_max <= ram_mib.
        while agents_max + app_max + acchat_max > ram_mib and app_max > 512:
            app_max -= 256
        while agents_max + app_max + acchat_max > ram_mib and agents_max > agents_high:
            agents_max -= 256
        app_margin = _clamp(_round_step(app_max * 0.07, 256), 256, 1024)
        app_high = max(384, app_max - app_margin)
    else:
        acchat_max = 0
        acchat_high = 0
        app_max = 0
        app_high = 0
        agents_high = _clamp(_round_step(ram_mib * 0.72, 256), 1024, int(ram_mib * 0.80))
        agents_max = min(int(ram_mib * 0.88), agents_high + _clamp(_round_step(ram_mib * 0.06, 256), 256, 2048))

    agents_swap = _clamp(_round_step(agents_high * 0.045, 128), 256, 2048)
    app_swap = _clamp(_round_step(app_max * 0.25, 256), 512, 4096) if desktop else 0
    acchat_swap = _clamp(_round_step(acchat_max * 0.22, 128), 256, 1024) if desktop else 0

    council_high = _clamp(_round_step(agents_high * 0.35, 256), 1024, 16384)
    council_max = min(agents_max, council_high + _clamp(_round_step(council_high * 0.25, 256), 512, 4096))
    council_swap = _clamp(_round_step(council_high * 0.065, 128), 128, 1024)
    express_low = _clamp(_round_step(agents_high * 0.25, 256), 512, 8192)

    agents_tasks = _clamp(_round_step((agents_high / 1024.0) * 300, 500), 1500, 12000)
    council_tasks = _clamp(_round_step(agents_tasks * 0.17, 100), 300, 2000)

    # autonice concurrency slots: scale gently with both cores and RAM.
    if cpus >= 16 and ram_mib >= 48 * 1024:
        slots_heavy = 3
    elif cpus >= 8 and ram_mib >= 28 * 1024:
        slots_heavy = 2
    else:
        slots_heavy = 1

    if ram_mib >= 48 * 1024:
        slots_dev = 4
    elif ram_mib >= 30 * 1024:
        slots_dev = 3
    elif ram_mib >= 14 * 1024:
        slots_dev = 2
    else:
        slots_dev = 1

    tmp_mib = _clamp(_round_step(ram_mib * 0.085, 256), 512, 4096)

    return {
        "ram_mib": ram_mib,
        "cpus": cpus,
        "desktop": desktop,
        "agents_cpu": f"{agents_cpu}%",
        "agents_high": fmt_mem(agents_high),
        "agents_max": fmt_mem(agents_max),
        "agents_swap": fmt_mem(agents_swap),
        "agents_tasks": str(agents_tasks),
        "app_high": fmt_mem(app_high) if desktop else "max",
        "app_max": fmt_mem(app_max) if desktop else "max",
        "app_swap": fmt_mem(app_swap) if desktop else "max",
        "acchat_high": fmt_mem(acchat_high) if desktop else "max",
        "acchat_max": fmt_mem(acchat_max) if desktop else "max",
        "acchat_swap": fmt_mem(acchat_swap) if desktop else "max",
        "council_cpu": f"{council_cpu}%",
        "council_high": fmt_mem(council_high),
        "council_max": fmt_mem(council_max),
        "council_swap": fmt_mem(council_swap),
        "council_tasks": str(council_tasks),
        "express_low": fmt_mem(express_low),
        "slots_heavy": str(slots_heavy),
        "slots_dev": str(slots_dev),
        "tmp_size": fmt_mem(tmp_mib),
        "sum_high_mib": agents_high + app_high + acchat_high,
        "sum_max_mib": agents_max + app_max + acchat_max,
    }


def _sub_kv(text, key, val):
    return re.sub(rf"(?m)^({re.escape(key)}=).*$", rf"\g<1>{val}", text)


def _sub_slot(text, cls, val):
    return re.sub(rf"(?m)^(slots[ \t]+{re.escape(cls)}[ \t]+)[0-9]+$", rf"\g<1>{val}", text)


def transform(relpath, content, lim):
    """Rewrite machine-specific keys in a supported config file; pass others through unchanged."""
    norm = relpath.lstrip("./")
    if norm == "config/systemd/user/agents.slice":
        content = _sub_kv(content, "CPUQuota", lim["agents_cpu"])
        content = _sub_kv(content, "MemoryHigh", lim["agents_high"])
        content = _sub_kv(content, "MemoryMax", lim["agents_max"])
        content = _sub_kv(content, "MemorySwapMax", lim["agents_swap"])
        content = _sub_kv(content, "TasksMax", lim["agents_tasks"])
        return content
    if norm == "config/systemd/user/app.slice.d/memory.conf":
        content = _sub_kv(content, "MemoryHigh", lim["app_high"])
        content = _sub_kv(content, "MemoryMax", lim["app_max"])
        content = _sub_kv(content, "MemorySwapMax", lim["app_swap"])
        return content
    if norm == "config/systemd/user/agents-council.slice":
        content = _sub_kv(content, "CPUQuota", lim["council_cpu"])
        content = _sub_kv(content, "MemoryHigh", lim["council_high"])
        content = _sub_kv(content, "MemoryMax", lim["council_max"])
        content = _sub_kv(content, "MemorySwapMax", lim["council_swap"])
        content = _sub_kv(content, "TasksMax", lim["council_tasks"])
        return content
    if norm == "config/systemd/user/agents-express.slice":
        return _sub_kv(content, "MemoryLow", lim["express_low"])
    if norm == "config/autonice/rules":
        content = _sub_slot(content, "heavy", lim["slots_heavy"])
        content = _sub_slot(content, "dev", lim["slots_dev"])
        return content
    return content


def main():
    p = argparse.ArgumentParser(description="Auto-size ACF limits to host RAM and CPU specs.")
    p.add_argument("--ram-gb", type=float, default=None, help="Override detected RAM in GiB")
    p.add_argument("--ram-mib", type=int, default=None, help="Override detected RAM in MiB")
    p.add_argument("--cpus", type=int, default=None, help="Override detected CPU core count")
    p.add_argument("--headless", action="store_true", help="Compute limits for headless/WSL host")
    p.add_argument("--show", action="store_true", help="Print computed limits summary")
    p.add_argument("--field", type=str, default=None, help="Print one computed field value")
    p.add_argument("cmd", nargs="*", help="Optional: apply <relpath> <src> <dst>")
    args = p.parse_args()

    if args.ram_mib is not None:
        if args.ram_mib <= 0:
            sys.stderr.write("error: --ram-mib must be > 0\n")
            return 2
        ram_mib = args.ram_mib
    elif args.ram_gb is not None:
        if args.ram_gb <= 0:
            sys.stderr.write("error: --ram-gb must be > 0\n")
            return 2
        ram_mib = int(round(args.ram_gb * 1024))
    else:
        ram_mib = detect_ram_mib()
    if args.cpus is not None and args.cpus < 1:
        sys.stderr.write("error: --cpus must be >= 1\n")
        return 2
    cpus = args.cpus if args.cpus is not None else detect_cpus()
    lim = compute_limits(ram_mib, cpus, desktop=not args.headless)

    if args.field:
        if args.field not in lim:
            sys.stderr.write(f"unknown field: {args.field}\n")
            return 2
        print(lim[args.field])
        return 0

    if args.cmd:
        if len(args.cmd) != 4 or args.cmd[0] != "apply":
            sys.stderr.write("usage: tune-specs.py apply <relpath> <src> <dst>\n")
            return 2
        _, relpath, src, dst = args.cmd
        with open(src, encoding="utf-8") as f:
            raw = f.read()
        out = transform(relpath, raw, lim)
        with open(dst, "w", encoding="utf-8") as f:
            f.write(out)
        return 0

    mode = "desktop" if lim["desktop"] else "headless"
    print(f"Host specs ({mode}): {ram_mib / 1024:.1f} GiB RAM, {cpus} CPU cores")
    print(f"  agents.slice  : CPU={lim['agents_cpu']} high={lim['agents_high']} max={lim['agents_max']} swap={lim['agents_swap']} tasks={lim['agents_tasks']}")
    if lim["desktop"]:
        print(f"  app.slice     : high={lim['app_high']} max={lim['app_max']} swap={lim['app_swap']}")
        print(f"  acchat.slice  : high={lim['acchat_high']} max={lim['acchat_max']} swap={lim['acchat_swap']}")
        print(f"  Total budget  : soft={lim['sum_high_mib']/1024:.2f} GiB | hard={lim['sum_max_mib']/1024:.2f} GiB (host {ram_mib/1024:.2f} GiB)")
    print(f"  council.slice : CPU={lim['council_cpu']} high={lim['council_high']} max={lim['council_max']} swap={lim['council_swap']} tasks={lim['council_tasks']}")
    print(f"  express.slice : low={lim['express_low']}")
    print(f"  autonice      : heavy={lim['slots_heavy']} dev={lim['slots_dev']}")
    print(f"  /tmp tmpfs    : size={lim['tmp_size']}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
