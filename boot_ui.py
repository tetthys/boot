#!/usr/bin/env python3
"""
boot_ui.py - Minimal Python UI backend (Rich-only)

Subcommands:
  log --level LVL -- message...
  banner TEXT
  hr
  table --headers JSON_ARRAY [--sort-by COL|INDEX] [--desc]   # rows via stdin (TSV)
  kv --json JSON_OBJECT [--pad N]
  timeline                                                     # lines: "left<TAB>text"
  spinner [--label TEXT] -- CMD ARGS...
  progress --percent N [--label TEXT]

Environment:
  BOOT_NO_COLOR=1            disable console colors
  BOOT_EMOJI=0               disable emoji icons
  BOOT_TS=time|none          timestamp in console logs
  BOOT_THEME=light|dark|mono color theme (default: dark)
  BOOT_LOG_FORMAT=text|json  console log format (default: text)
  BOOT_LOG_FILE=/path/file        append plain text logs
  BOOT_LOG_JSON_FILE=/path/file   append JSONL logs (one JSON per line)
"""

from __future__ import annotations
import argparse, json, os, sys, subprocess, datetime
from typing import List

try:
    from rich.console import Console
    from rich.rule import Rule
    from rich.table import Table
    from rich.spinner import Spinner
    from rich.live import Live
except Exception as e:
    print(f"[boot:ui] Python package 'rich' is required: {e}", file=sys.stderr)
    sys.exit(1)

# ----- Console / Theme ---------------------------------------------------------

is_no_color = os.environ.get("BOOT_NO_COLOR", "0") == "1"
theme = os.environ.get("BOOT_THEME", "dark").lower()
log_format = os.environ.get("BOOT_LOG_FORMAT", "text").lower()

console = Console(
    force_terminal=not is_no_color,
    color_system=None if is_no_color or theme == "mono" else "auto",
    stderr=True,
)

def _styles():
    if theme == "light":
        return {"debug":"bright_cyan","info":"green","notice":"blue","warn":"dark_orange","error":"bold red","success":"bold green","header":"bold blue"}
    if theme == "mono":
        return {k:"" for k in ["debug","info","notice","warn","error","success","header"]}
    return {"debug":"cyan","info":"green","notice":"blue","warn":"yellow","error":"bold red","success":"bold green","header":"bold cyan"}
STY = _styles()

EMOJI = {"debug":"🧩","info":"ℹ️","notice":"🔔","warn":"⚠️","error":"❌","success":"✅"}
def _emoji(lvl: str) -> str:
    return "" if os.environ.get("BOOT_EMOJI","1") != "1" else EMOJI.get(lvl, "●")

def _ts() -> str:
    return datetime.datetime.now().strftime("%H:%M:%S") if os.environ.get("BOOT_TS","time")=="time" else ""

# ----- Optional file/JSON log sinks -------------------------------------------

LOG_FILE = os.environ.get("BOOT_LOG_FILE") or ""
LOG_JSON_FILE = os.environ.get("BOOT_LOG_JSON_FILE") or ""

def _write(path: str, text: str) -> None:
    try:
        with open(path, "a", encoding="utf-8") as f:
            f.write(text)
            if not text.endswith("\n"):
                f.write("\n")
    except Exception:
        pass

def _sinks(level: str, message: str) -> None:
    iso = datetime.datetime.now().isoformat(timespec="seconds")
    if LOG_FILE:
        _write(LOG_FILE, f"[{iso}] [{level}] {message}")
    if LOG_JSON_FILE:
        _write(LOG_JSON_FILE, json.dumps({"ts": iso, "level": level, "msg": message, "pid": os.getpid()}, ensure_ascii=False))

# ----- Commands ---------------------------------------------------------------

def cmd_log(a):
    level = (a.level or "info").lower()
    msg = " ".join(a.message or [])
    t = _ts()
    if log_format == "json":
        console.print_json(data={"ts": t or None, "level": level, "msg": msg})
    else:
        mark = _emoji(level)
        sty = STY.get(level, "")
        prefix = "[boot]" if not sty else f"[{sty}][boot][/]"
        tpart = f"[dim]{t}[/] " if t else ""
        if mark:
            console.print(f"{prefix} {tpart}[{sty}]{mark}[/] {msg}" if sty else f"{prefix} {tpart}{mark} {msg}")
        else:
            console.print(f"{prefix} {tpart}{msg}")
    _sinks(level, msg)

def cmd_banner(a):
    console.print(Rule(title=f"[bold]{a.text}[/bold]", style=STY.get("header", "")))

def cmd_hr(_a):
    console.print(Rule(style="" if theme == "mono" else "grey50"))

def _sort_index(sort_by: str, headers: List[str]) -> int | None:
    if not sort_by:
        return None
    if sort_by.isdigit():
        i = int(sort_by) - 1
        return i if 0 <= i < len(headers) else None
    try:
        return headers.index(sort_by)
    except ValueError:
        return None

def cmd_table(a):
    try:
        headers = json.loads(a.headers)
    except Exception:
        headers = []
    rows: List[List[str]] = []
    for line in sys.stdin:
        cols = line.rstrip("\n").split("\t")
        if headers:
            if len(cols) < len(headers):
                cols += [""] * (len(headers) - len(cols))
            cols = cols[:len(headers)]
        rows.append(cols)

    idx = _sort_index(a.sort_by or "", headers) if headers else None
    if idx is not None:
        rev = bool(a.desc)
        def _key(r):
            v = r[idx]
            try: return (0, float(v))
            except Exception: return (1, v)
        rows = sorted(rows, key=_key, reverse=rev)

    t = Table(show_header=True, header_style=STY.get("header","bold"), expand=True, padding=(0,1))
    for h in headers:
        t.add_column(str(h))
    for r in rows:
        t.add_row(*r)
    console.print(t)

def cmd_kv(a):
    try:
        data = json.loads(a.json)
    except Exception:
        data = {}
    pad = max(0, int(a.pad))
    if not data:
        return
    kmax = max((len(str(k)) for k in data.keys()), default=0)
    for k in sorted(data.keys(), key=lambda s: str(s)):
        left = f"{' '*pad}{str(k):<{kmax}}"
        if theme == "mono":
            console.print(f"{left} : {data[k]}")
        else:
            console.print(f"[bold]{left}[/] : {data[k]}")

def cmd_timeline(_a):
    lines = [l.rstrip("\n") for l in sys.stdin if l.strip()]
    left = 0; items = []
    for l in lines:
        if "\t" in l:
            a, b = l.split("\t", 1)
        else:
            a, b = "", l
        left = max(left, len(a)); items.append((a, b))
    bullet = "*" if theme == "mono" else "●"
    pipe   = "|" if theme == "mono" else "│"
    for a, b in items:
        console.print(f"{a:<{left}} {bullet} {b}" if theme == "mono" else f"{a:<{left}} [white]{bullet}[/] {b}")
        console.print(" " * left + f" {pipe}")

def cmd_spinner(a):
    cmd = list(a.command or [])
    if cmd and cmd[0] == "--":
        cmd = cmd[1:]
    if not cmd:
        console.print("[red]spinner: no command[/]" if theme != "mono" else "spinner: no command")
        sys.exit(2)
    label = a.label or ""
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    except FileNotFoundError:
        console.print(f"[red]spinner: command not found[/] {' '.join(cmd)}" if theme != "mono" else f"spinner: command not found {' '.join(cmd)}")
        sys.exit(127)
    except Exception as e:
        console.print(f"[red]spinner: {e}[/]" if theme != "mono" else f"spinner: {e}")
        sys.exit(1)
    with Live(Spinner("dots", text=label), refresh_per_second=12, console=console):
        ret = proc.wait()
    out, err = proc.communicate()
    if out: sys.stdout.buffer.write(out)
    if err: sys.stderr.buffer.write(err)
    ok = (ret == 0); mark = "✔" if ok else "✖"
    if theme == "mono":
        console.print(f"{mark} {label}{'' if ok else f' (rc={ret})'}")
    else:
        console.print(f"[bold {'green' if ok else 'red'}]{mark}[/] {label}{'' if ok else f' (rc={ret})'}")
    sys.exit(ret)

def cmd_progress(a):
    try:
        p = int(a.percent)
    except Exception:
        p = 0
    p = max(0, min(100, p))
    label = a.label or ""
    width = max(10, int(getattr(console, "width", 80)) - 12)
    filled = int(width * p / 100)
    bar = "#" * filled + "-" * (width - filled)
    end = "\n" if p == 100 else "\r"
    if theme == "mono":
        console.print(f"[{bar}] {p:3d}% {label}", end=end, soft_wrap=False)
    else:
        console.print(f"[grey70][[/]{bar}[grey70]][/] {p:3d}% {label}", end=end, soft_wrap=False)

# ----- CLI --------------------------------------------------------------------

def main():
    ap = argparse.ArgumentParser(prog="boot_ui")
    sub = ap.add_subparsers(dest="cmd", required=True)

    p=sub.add_parser("log");      p.add_argument("--level", default="info"); p.add_argument("message", nargs="*"); p.set_defaults(func=cmd_log)
    p=sub.add_parser("banner");   p.add_argument("text"); p.set_defaults(func=cmd_banner)
    p=sub.add_parser("hr");       p.set_defaults(func=cmd_hr)

    p=sub.add_parser("table");    p.add_argument("--headers", required=True); p.add_argument("--sort-by", default=""); p.add_argument("--desc", action="store_true"); p.set_defaults(func=cmd_table)

    p=sub.add_parser("kv");       p.add_argument("--json", required=True); p.add_argument("--pad", default="0"); p.set_defaults(func=cmd_kv)

    p=sub.add_parser("timeline"); p.set_defaults(func=cmd_timeline)

    p=sub.add_parser("spinner");  p.add_argument("--label"); p.add_argument("command", nargs=argparse.REMAINDER); p.set_defaults(func=cmd_spinner)

    p=sub.add_parser("progress"); p.add_argument("--percent", required=True); p.add_argument("--label"); p.set_defaults(func=cmd_progress)

    args = ap.parse_args()
    args.func(args)

if __name__ == "__main__":
    main()
