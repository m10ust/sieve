#!/usr/bin/env python3
"""sieve - find and grep in one vocabulary.

Spec decisions of 2026-09-23, implemented:

  * bare form works:    sieve hacker          names AND contents, in .
  * selectors:          --files / --text      narrow to one half, combine for both
  * literal by default, regex behind --regex. foo(bar) is safe to type.
  * one readable list, grouped per file, each hit marked with why it matched
  * always says something, even when nothing matched, and always says how long it took
  * exit codes in the grep family: 0 matched, 1 nothing, 2 misuse

The heavy lifting is delegated to tools that are already on the box and already
faster: fd lists files (parallel), rg reads contents (parallel, across all cores).
Both are optional. Without them sieve walks and reads in-process, same output, and
the summary line says which engine did the work.
"""
from __future__ import annotations

import base64
import json
import os
import re
import shutil
import subprocess
import sys
import time

VERSION = "0.3.1"

SKIP_DIRS = {
    ".git", ".hg", ".svn", ".bzr",
    "__pycache__", ".mypy_cache", ".pytest_cache", ".ruff_cache",
    "node_modules", ".venv", "venv", ".tox",
    ".cache", ".rustup", ".cargo", ".npm", ".gem", ".gradle",
}
# Path suffixes: the machine's own bookkeeping. Measured on the rig 2026-09-23, these
# carried about 353,000 of the 653,329 files in the home, over half the tree, and none
# of it is the user's own material. --no-ignore walks them anyway, and the summary line
# always says what was skipped.
SKIP_PATH_SUFFIXES = (
    ".local/share/flatpak", ".local/share/mise", ".local/share/uv",
    ".local/share/nvim", ".local/share/sia", ".local/share/Trash",
    ".config/google-chrome", ".config/vesktop", ".config/Hermes",
    ".config/Code", ".mozilla",
)
BINARY_SNIFF = 4096
MAX_FILE_BYTES = 10 * 1024 * 1024


# --------------------------------------------------------------------------- colour
class Pal:
    """Three roles at most: the file, the reason, the match. Nothing else."""

    def __init__(self, on: bool):
        if on:
            self.file = "\033[1;36m"
            self.reason = "\033[2m"
            self.match = "\033[91m"
            self.none = "\033[2m"
            self.reset = "\033[0m"
        else:
            self.file = self.reason = self.match = self.none = self.reset = ""


def colour_wanted(mode: str) -> bool:
    if mode == "always":
        return True
    if mode == "never":
        return False
    if os.environ.get("NO_COLOR"):
        return False
    return sys.stdout.isatty()


# --------------------------------------------------------------------------- args
USAGE = """sieve - find and grep in one vocabulary

usage:
  sieve PATTERN [options]              names AND contents, in .
  sieve --files PATTERN                names only, no file is opened
  sieve --text PATTERN                 contents only

options:
  --in DIR            where to look (default .)
  --named GLOB        only files whose name matches GLOB (repeatable)
  --today             only files modified today
  --since Nd|Nh|Nm    only files modified within the window, e.g. 3d
  --bigger SIZE       only files larger than SIZE (k/M/G)
  --no-bigger SIZE    skip files larger than SIZE (default 10M)
  --regex             treat PATTERN as a regex (default is a plain literal)
  -i, --ignore-case   case-insensitive
  --files             match file names only
  --text              match file contents only
  -c, --count         one count per file instead of the lines
  -m, --max-per-file N  show at most N lines per file
  --no-ignore         do not skip .git, node_modules and friends
  --color WHEN        auto (default), always, never
  --explain           print the find and grep this stood in for
  --version           print the version
  -h, --help          this text

exit: 0 something matched, 1 nothing matched, 2 the command was wrong
"""


class Fail(Exception):
    pass


def parse_size(text: str, flag: str) -> int:
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([kKmMgG]?)", text.strip())
    if not m:
        raise Fail("%s wants a size like 10k or 2M, got %r" % (flag, text))
    value = float(m.group(1))
    unit = m.group(2).lower()
    mult = {"": 1, "k": 1024, "m": 1024 ** 2, "g": 1024 ** 3}[unit]
    return int(value * mult)


def parse_window(text: str) -> float:
    m = re.fullmatch(r"(\d+(?:\.\d+)?)\s*([dhm]?)", text.strip())
    if not m:
        raise Fail("--since wants 3d, 12h or 30m, got %r" % text)
    value = float(m.group(1))
    unit = m.group(2).lower()
    mult = {"": 86400.0, "d": 86400.0, "h": 3600.0, "m": 60.0}[unit]
    return value * mult


class Opts:
    def __init__(self):
        self.pattern = None
        self.root = "."
        self.named = []
        self.mtime_after = None
        self.min_size = 0
        self.max_size = MAX_FILE_BYTES
        self.regex = False
        self.ignore_case = False
        self.files = False
        self.text = False
        self.no_ignore = False
        self.color = "auto"
        self.explain = False
        self.skipped_dirs = 0
        self.count = False
        self.max_per_file = 0          # 0 means no cap
        self.listed_by = "walk"


def parse_args(argv):
    o = Opts()
    i = 0
    while i < len(argv):
        a = argv[i]
        if a in ("-h", "--help"):
            print(USAGE, end="")
            raise SystemExit(0)
        if a == "--version":
            print("sieve " + VERSION)
            raise SystemExit(0)
        if a == "--in":
            i += 1
            if i >= len(argv):
                raise Fail("--in wants a directory")
            o.root = argv[i]
        elif a.startswith("--in="):
            o.root = a.split("=", 1)[1]
        elif a == "--named":
            i += 1
            if i >= len(argv):
                raise Fail("--named wants a glob like '*.py'")
            o.named.append(argv[i])
        elif a.startswith("--named="):
            o.named.append(a.split("=", 1)[1])
        elif a == "--today":
            lt = time.localtime()
            midnight = time.mktime((lt.tm_year, lt.tm_mon, lt.tm_mday, 0, 0, 0, 0, 0, -1))
            o.mtime_after = midnight
        elif a == "--since":
            i += 1
            if i >= len(argv):
                raise Fail("--since wants 3d, 12h or 30m")
            o.mtime_after = time.time() - parse_window(argv[i])
        elif a.startswith("--since="):
            o.mtime_after = time.time() - parse_window(a.split("=", 1)[1])
        elif a in ("--bigger", "--no-bigger"):
            i += 1
            if i >= len(argv):
                raise Fail("%s wants a size" % a)
            size = parse_size(argv[i], a)
            if a == "--bigger":
                o.min_size = size
            else:
                o.max_size = size
        elif a == "--regex":
            o.regex = True
        elif a in ("-i", "--ignore-case"):
            o.ignore_case = True
        elif a == "--files":
            o.files = True
        elif a == "--text":
            o.text = True
        elif a in ("-c", "--count"):
            o.count = True
        elif a in ("-m", "--max-per-file"):
            i += 1
            if i >= len(argv) or not argv[i].isdigit():
                raise Fail("%s wants a number of lines, e.g. -m 5" % a)
            o.max_per_file = int(argv[i])
        elif a.startswith("--max-per-file="):
            v = a.split("=", 1)[1]
            if not v.isdigit():
                raise Fail("--max-per-file wants a number of lines")
            o.max_per_file = int(v)
        elif a == "--no-ignore":
            o.no_ignore = True
        elif a == "--color":
            i += 1
            if i >= len(argv) or argv[i] not in ("auto", "always", "never"):
                raise Fail("--color wants auto, always or never")
            o.color = argv[i]
        elif a.startswith("--color="):
            v = a.split("=", 1)[1]
            if v not in ("auto", "always", "never"):
                raise Fail("--color wants auto, always or never")
            o.color = v
        elif a == "--explain":
            o.explain = True
        elif a.startswith("-") and a != "-":
            raise Fail("unknown option %s" % a)
        elif o.pattern is None:
            o.pattern = a
        else:
            raise Fail("one pattern at a time, got %r as well as %r" % (a, o.pattern))
        i += 1

    if o.pattern is None:
        raise Fail("no pattern given")

    # selectors: neither means both, which is the whole point of the bare form
    if not o.files and not o.text:
        o.files = o.text = True
    if not os.path.isdir(o.root):
        raise Fail("not a directory: %s" % o.root)
    return o


# --------------------------------------------------------------------------- walking
def walk(root, o):
    """Yield (path, stat), skipping noise unless asked not to. The fallback lister."""
    for dirpath, dirnames, filenames in os.walk(root, followlinks=False):
        if not o.no_ignore:
            keep = []
            for d in dirnames:
                if d in SKIP_DIRS or os.path.join(dirpath, d).endswith(SKIP_PATH_SUFFIXES):
                    o.skipped_dirs += 1
                    continue
                keep.append(d)
            dirnames[:] = keep
        dirnames.sort()
        for fn in sorted(filenames):
            p = os.path.join(dirpath, fn)
            try:
                st = os.stat(p)
            except OSError:
                continue
            if not os.path.isfile(p):
                continue
            yield p, st


def fd_list(root, o):
    """List files with fd, which is parallel, or fall back to our own walk.

    Paths come back normalised the same way ripgrep's do, so the names half and
    the contents half line up on one key. Stat is not called here: it is only
    needed when a --today/--since/--bigger filter is actually in play.
    """
    fd = shutil.which("fd")
    if fd:
        cmd = [fd, "-H", "-I", "-t", "f", "."]
        if not o.no_ignore:
            for d in sorted(SKIP_DIRS):
                cmd += ["-E", d]
            for s in SKIP_PATH_SUFFIXES:
                cmd += ["-E", "**/%s" % s]
        cmd.append(root)
        try:
            proc = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                  text=True, encoding="utf-8", errors="replace")
            paths = [os.path.normpath(p) for p in proc.stdout.splitlines() if p]
            if paths or proc.returncode in (0, 1):
                return paths, "fd"
        except OSError:
            pass
    return [os.path.normpath(p) for p, _st in walk(root, o)], "walk"


def wanted_by_stat(st, o):
    if o.mtime_after is not None and st.st_mtime < o.mtime_after:
        return False
    if st.st_size < o.min_size:
        return False
    return True


def wanted_by_name(path, o):
    if not o.named:
        return True
    import fnmatch
    base = os.path.basename(path)
    return any(fnmatch.fnmatch(base, g) or fnmatch.fnmatch(path, g) for g in o.named)


def sniff(path):
    """True binary, False text, None when the file cannot be opened at all.

    An unreadable file is not a binary. It is a file you cannot read, and the
    summary says so in its own words rather than folding it into another number.
    """
    try:
        with open(path, "rb") as fh:
            chunk = fh.read(BINARY_SNIFF)
    except OSError:
        return None
    return b"\0" in chunk


# --------------------------------------------------------------------------- match
def build_name_matcher(o):
    if o.regex:
        flags = re.IGNORECASE if o.ignore_case else 0
        return re.compile(o.pattern, flags)
    return o.pattern.lower() if o.ignore_case else o.pattern


def name_hits(path, matcher, o):
    base = os.path.basename(path)
    if o.regex:
        return bool(matcher.search(base))
    hay = base.lower() if o.ignore_case else base
    return matcher in hay


def build_line_matcher(o):
    flags = re.IGNORECASE if o.ignore_case else 0
    if o.regex:
        try:
            return re.compile(o.pattern, flags)
        except re.error as e:
            raise Fail("that regex will not compile: %s" % e)
    return re.compile(re.escape(o.pattern), flags)


def read_lines(path, o):
    """List of (lineno, text), or None when the file cannot be read."""
    try:
        if os.path.getsize(path) > o.max_size:
            return None
        with open(path, "r", encoding="utf-8", errors="replace") as fh:
            return list(enumerate(fh, 1))
    except (OSError, UnicodeError):
        return None


LONG_LINE = 200


def clip(text, rx, limit=LONG_LINE):
    """A match buried in a huge line is unreadable and floods the scrollback.

    Short lines print whole. Long ones print a window around the first match,
    with an ellipsis on whichever side was cut, and a count of any further
    matches on that same line.
    """
    s = text.rstrip("\n")
    if len(s) <= limit:
        return s
    m = rx.search(s)
    if not m:
        return s[:limit] + " ..."
    start = max(0, m.start() - 80)
    end = min(len(s), m.end() + 80)
    lead = "..." if start > 0 else ""
    tail = "..." if end < len(s) else ""
    more = len(rx.findall(s)) - 1
    note = "" if more <= 0 else "   (+%d more on this line)" % more
    return "%s%s%s%s%s%s" % (lead, s[start:m.start()], s[m.start():m.end()],
                             s[m.end():end], tail, note)


def highlight(line, rx, pal):
    if not pal.match:
        return line.rstrip("\n")
    return rx.sub(lambda m: pal.match + m.group(0) + pal.reset, line.rstrip("\n"))


# --------------------------------------------------------------------------- explain
def explain_line(o):
    pattern = o.pattern if o.regex else "'" + o.pattern.replace("'", "'\\''") + "'"
    bits = []
    for g in o.named:
        bits.append("-name '%s'" % g)
    if o.mtime_after is not None:
        bits.append("-newermt '@%d'" % int(o.mtime_after))
    if o.min_size:
        bits.append("-size +%dc" % o.min_size)
    find_part = " ".join(["find", o.root] + bits + ["-type", "f"])
    out = []
    if o.files:
        cond = "-iname" if o.ignore_case else "-name"
        out.append(" ".join(["find", o.root] + bits + [cond, "'*%s*'" % o.pattern, "-type", "f"]))
    if o.text:
        grep_flags = "-nH"
        if o.regex:
            grep_flags += " -E"
        if o.ignore_case:
            grep_flags += " -i"
        out.append("%s -print0 | xargs -0 grep %s --color=auto -- %s"
                   % (find_part, grep_flags, pattern))
    return "\n           ".join(out) if out else "# nothing to do"


# --------------------------------------------------------------------------- engines
def _rg_globs(o):
    """Hand ripgrep the same ignore list the lister uses, so the set of files read
    is the same either way."""
    globs = []
    for d in sorted(SKIP_DIRS):
        globs += ["--glob", "!**/%s/**" % d]
    for s in SKIP_PATH_SUFFIXES:
        globs += ["--glob", "!**/%s/**" % s]
    return globs


def _rg_text(obj):
    """ripgrep hands back either text or base64 bytes, depending on whether the
    payload is valid UTF-8. A search tool must never die on an odd file, so both
    shapes are accepted and undecodable bytes come back lossy rather than fatal.
    """
    if not isinstance(obj, dict):
        return ""
    if "text" in obj:
        return obj["text"]
    raw = obj.get("bytes")
    if raw is None:
        return ""
    try:
        return base64.b64decode(raw).decode("utf-8", "replace")
    except Exception:
        return ""


def rg_scan(rg, o):
    """Search contents with ripgrep, across all cores.

    Returns {path: [(lineno, text)]} with normalised paths. ripgrep decides what
    counts as text, which beats our own sniff, and it walks and reads in parallel.
    """
    cmd = [rg, "--json", "--no-ignore", "--hidden", "--no-messages",
           "--threads", "0", "--max-filesize", "%d" % o.max_size]
    if o.regex:
        cmd += ["-e", o.pattern]
    else:
        cmd += ["--fixed-strings", "-e", o.pattern]
    if o.ignore_case:
        cmd.append("--ignore-case")
    cmd += _rg_globs(o)
    for g in o.named:
        cmd += ["--glob", g]
    cmd.append(o.root)

    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                text=True, encoding="utf-8", errors="replace")
    except OSError:
        return {}, {"failed": True}

    found = {}
    for raw in proc.stdout:
        if not raw.startswith("{"):
            continue
        try:
            ev = json.loads(raw)
        except ValueError:
            continue
        if ev.get("type") != "match":
            continue
        try:
            data = ev["data"]
            path = _rg_text(data.get("path"))
            if not path:
                continue
            found.setdefault(os.path.normpath(path), []).append(
                (data.get("line_number") or 0, _rg_text(data.get("lines"))))
        except Exception:
            # one unparseable event must never end the search
            continue
    proc.stdout.close()
    err = proc.stderr.read()
    proc.stderr.close()
    proc.wait()
    if proc.returncode not in (0, 1) and not found:
        return {}, {"failed": True, "stderr": err[:200]}
    return found, {}


# --------------------------------------------------------------------------- run
def run(o, pal):
    name_rx = build_name_matcher(o)
    line_rx = build_line_matcher(o)

    looked = 0
    skipped_binary = 0
    unreadable = 0
    skipped_big = 0
    name_map = {}
    text_map = {}
    engine = "in-process"

    # the names half: a fast listing (fd) plus our own name match. Stat is only
    # called when a time or size filter is actually in play.
    if o.files:
        paths, o.listed_by = fd_list(o.root, o)
        need_stat = o.mtime_after is not None or o.min_size > 0
        for path in paths:
            looked += 1
            if not wanted_by_name(path, o):
                continue
            if need_stat:
                try:
                    st = os.stat(path)
                except OSError:
                    continue
                if not wanted_by_stat(st, o):
                    continue
            if name_hits(path, name_rx, o):
                name_map[path] = True

    # the contents half: ripgrep when it is installed, in-process otherwise
    if o.text:
        rg = shutil.which("rg")
        fail = None
        if rg:
            text_map, fail = rg_scan(rg, o)
            if fail:
                text_map = {}
            else:
                engine = "rg"
        if fail or not rg:
            if not o.files:
                for _p, _st in walk(o.root, o):
                    looked += 1
            for path, st in walk(o.root, o):
                if not wanted_by_stat(st, o) or not wanted_by_name(path, o):
                    continue
                sniffed = sniff(path)
                if sniffed is None:
                    unreadable += 1
                    continue
                if sniffed:
                    skipped_binary += 1
                    continue
                lines = read_lines(path, o)
                if lines is None:
                    if os.path.getsize(path) > o.max_size:
                        skipped_big += 1
                    continue
                hits = [(n, t) for n, t in lines if line_rx.search(t)]
                if hits:
                    text_map[os.path.normpath(path)] = hits

    blocks = []
    files_by_name = 0
    files_with_text = 0
    lines_total = 0
    for path in sorted(set(name_map) | set(text_map)):
        named = path in name_map
        hits = text_map.get(path, [])
        if named:
            files_by_name += 1
        if hits:
            files_with_text += 1
            lines_total += len(hits)
        reason = "name+content" if named and hits else ("name" if named else "content")
        blocks.append((path, reason, named, hits))

    return blocks, dict(
        looked=looked, by_name=files_by_name, with_text=files_with_text,
        lines=lines_total, binary=skipped_binary, big=skipped_big, engine=engine,
        unreadable=unreadable,
        lister=o.listed_by, ignored=not o.no_ignore,
    )


# --------------------------------------------------------------------------- report
def _extras(o, stats):
    extras = []
    if stats.get("engine") == "rg":
        extras.append("read by rg across all cores")
    elif stats.get("engine") == "in-process":
        extras.append("read in-process, one file at a time")
    if stats.get("lister") == "fd":
        extras.append("listed by fd")
    elif stats.get("lister") == "walk" and stats.get("looked"):
        extras.append("listed by our own walk")
    if stats.get("ignored"):
        extras.append("machine dirs skipped" if not o.skipped_dirs
                      else "%d machine dirs skipped" % o.skipped_dirs)
    if stats["binary"]:
        extras.append("%d binary skipped" % stats["binary"])
    if stats["big"]:
        extras.append("%d over the size cap" % stats["big"])
    if stats.get("unreadable"):
        extras.append("%d unreadable" % stats["unreadable"])
    sec = stats.get("elapsed")
    if sec is not None:
        extras.append("in %.2f s" % sec if sec < 60
                      else "in %d m %02d s" % (int(sec // 60), int(sec % 60)))
    if stats["looked"]:
        extras = ["%d files looked at" % stats["looked"]] + extras
    return "" if not extras else " (%s)" % ", ".join(extras)


def report(o, pal, blocks, stats, line_rx):
    if not blocks:
        print("sieve: nothing matched %s in %s%s" % (o.pattern, o.root, _extras(o, stats)))
        return 1

    total_shown = 0
    hidden = 0
    for path, reason, named, hits in blocks:
        if o.count:
            if hits or named:
                print("%6d  %s" % (len(hits) if hits else 0, path))
                total_shown += 1
                if len(hits) > o.max_per_file > 0:
                    hidden += len(hits) - o.max_per_file
            continue
        print("%s%s%s %s%s%s" % (pal.file, path, pal.reset, pal.reason, reason, pal.reset))
        shown = hits
        if o.max_per_file and len(hits) > o.max_per_file:
            shown = hits[:o.max_per_file]
            hidden += len(hits) - o.max_per_file
        for n, text in shown:
            print("%6d: %s" % (n, highlight(clip(text, line_rx), line_rx, pal)))
        if len(shown) < len(hits):
            print("        ... %d more line%s in this file"
                  % (len(hits) - len(shown), "" if len(hits) - len(shown) == 1 else "s"))
        print()

    if o.count:
        print("%d file%s" % (total_shown, "" if total_shown == 1 else "s"))
        if hidden:
            print("(%d line%s counted but not listed)" % (hidden, "" if hidden == 1 else "s"))

    bits = []
    if stats["by_name"]:
        bits.append("%d by name" % stats["by_name"])
    if stats["with_text"]:
        bits.append("%d file%s with content matches"
                    % (stats["with_text"], "" if stats["with_text"] == 1 else "s"))
    if stats["lines"]:
        bits.append("%d line%s" % (stats["lines"], "" if stats["lines"] == 1 else "s"))
    print("sieve: %s in %s%s" % (", ".join(bits) if bits else "matched", o.root,
                                 _extras(o, stats)))
    return 0


def main(argv=None):
    argv = list(sys.argv[1:] if argv is None else argv)
    try:
        o = parse_args(argv)
    except Fail as e:
        sys.stderr.write("sieve: %s\n\n" % e)
        sys.stderr.write(USAGE)
        return 2

    pal = Pal(colour_wanted(o.color))
    started = time.perf_counter()

    if o.explain:
        print(pal.none + "sieve ran: " + explain_line(o) + pal.reset)

    blocks, stats = run(o, pal)
    stats["elapsed"] = time.perf_counter() - started
    return report(o, pal, blocks, stats, build_line_matcher(o))


if __name__ == "__main__":
    try:
        sys.exit(main())
    except BrokenPipeError:
        # someone closed the pipe, `sieve x | head` is normal usage
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        except OSError:
            pass
        sys.exit(0)
    except KeyboardInterrupt:
        sys.exit(130)
