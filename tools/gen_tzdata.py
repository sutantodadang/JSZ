#!/usr/bin/env python3
"""Generate a Zig zone table from the system IANA tz database."""
import os, re, struct, hashlib, sys

ROOT = "/usr/share/zoneinfo"
SKIP_DIRS = {"posix", "right"}
SKIP_FILES = {"localtime", "posixrules", "Factory", "leapseconds", "tzdata.zi",
              "iso3166.tab", "zone.tab", "zone1970.tab", "leap-seconds.list", "SECURITY"}

def collect():
    names = {}
    for dirpath, dirnames, filenames in os.walk(ROOT):
        rel_dir = os.path.relpath(dirpath, ROOT)
        if rel_dir == ".":
            rel_dir = ""
        parts = rel_dir.split(os.sep) if rel_dir else []
        if parts and parts[0] in SKIP_DIRS:
            dirnames[:] = []
            continue
        for f in filenames:
            name = "/".join(parts + [f]) if parts else f
            if f in SKIP_FILES or name in SKIP_FILES:
                continue
            path = os.path.join(dirpath, f)
            try:
                with open(path, "rb") as fh:
                    data = fh.read()
            except OSError:
                continue
            if not data.startswith(b"TZif"):
                continue
            names[name] = data
    return names

def footer(data):
    """The trailing POSIX TZ string of a TZif v2+ file."""
    if data[4:5] in (b"2", b"3", b"4"):
        # Find the second TZif header, then take the trailing "\n...\n".
        second = data.find(b"TZif", 4)
        if second < 0:
            return None
        tail = data[second:]
        nl = tail.rfind(b"\n")
        if nl < 0:
            return None
        start = tail.rfind(b"\n", 0, nl)
        if start < 0:
            return None
        return tail[start + 1:nl].decode("ascii", "replace")
    return None

def parse_offset(s, i):
    """[+-]hh[:mm[:ss]] -> (seconds, next index). POSIX sign is inverted."""
    sign = 1
    if i < len(s) and s[i] in "+-":
        if s[i] == "-":
            sign = -1
        i += 1
    j = i
    while j < len(s) and s[j].isdigit():
        j += 1
    if j == i:
        return None, i
    total = int(s[i:j])
    i = j
    for _ in range(2):
        if i < len(s) and s[i] == ":":
            i += 1
            j = i
            while j < len(s) and s[j].isdigit():
                j += 1
            total = total * 60 + int(s[i:j] or 0)
            i = j
        else:
            total *= 60
    return sign * total, i

def parse_abbr(s, i):
    if i < len(s) and s[i] == "<":
        j = s.index(">", i)
        return s[i:j + 1], j + 1
    j = i
    while j < len(s) and (s[j].isalpha()):
        j += 1
    return s[i:j], j

def parse_tz(tz):
    """POSIX TZ string -> (std_offset_sec, dst_save_sec, rule|None) or None."""
    if not tz:
        return None
    i = 0
    abbr, i = parse_abbr(tz, i)
    if not abbr:
        return None
    off, i = parse_offset(tz, i)
    if off is None:
        return None
    std_off = -off  # POSIX offsets are west-positive
    if i >= len(tz):
        return (std_off, 0, None)
    dabbr, i = parse_abbr(tz, i)
    if not dabbr:
        return (std_off, 0, None)
    dst_off = std_off + 3600
    if i < len(tz) and tz[i] != ",":
        o2, i = parse_offset(tz, i)
        if o2 is not None:
            dst_off = -o2
    if i >= len(tz) or tz[i] != ",":
        return (std_off, dst_off - std_off, None)
    parts = tz[i + 1:].split(",")
    if len(parts) != 2:
        return None
    rule = []
    for p in parts:
        spec, _, timestr = p.partition("/")
        m = re.fullmatch(r"M(\d+)\.(\d+)\.(\d+)", spec)
        if not m:
            return None  # Jn / n forms are not modelled
        month, week, dow = int(m.group(1)), int(m.group(2)), int(m.group(3))
        sec = 2 * 3600
        if timestr:
            v, k = parse_offset(timestr, 0)
            if v is None or k != len(timestr):
                return None
            sec = v
        rule.append((month, week, dow, sec))
    return (std_off, dst_off - std_off, tuple(rule))


# CLDR aliases the tzdata "zoneinfo-only" zone names onto real city zones; the
# ECMA-402 canonicalization the tests expect follows CLDR, not tzdata.
CLDR_ALIASES = {
    "CET": "Europe/Brussels",
    "CST6CDT": "America/Chicago",
    "EET": "Europe/Athens",
    "EST": "America/Panama",
    "EST5EDT": "America/New_York",
    "HST": "Pacific/Honolulu",
    "MET": "Europe/Brussels",
    "MST": "America/Phoenix",
    "MST7MDT": "America/Denver",
    "PST8PDT": "America/Los_Angeles",
    "WET": "Europe/Lisbon",
}

UTC_FAMILY = {"GMT", "GMT0", "GMT+0", "GMT-0", "Greenwich", "UCT", "UTC",
              "Universal", "Zulu", "Etc/GMT", "Etc/GMT0", "Etc/GMT+0",
              "Etc/GMT-0", "Etc/Greenwich", "Etc/UCT", "Etc/UTC",
              "Etc/Universal", "Etc/Zulu"}

def main():
    data_by_name = collect()
    zi = os.path.join(ROOT, "tzdata.zi")
    zones_list, links = [], {}
    for line in open(zi):
        line = line.strip()
        if line.startswith("Z"):
            zones_list.append(line.split()[1])
        elif line.startswith("L"):
            _, target, name = line.split()[:3]
            links[name] = target

    def resolve(n, seen=None):
        seen = seen or set()
        while n in links and n not in seen:
            seen.add(n)
            n = links[n]
        return n

    links.update(CLDR_ALIASES)
    # Sorted case-insensitively: lookups binary-search a case-folded name.
    names = sorted(set(zones_list) | set(links), key=lambda n: (n.lower(), n))
    assert len(set(n.lower() for n in names)) == len(names), "case-folded name collision"
    canon_of = {}
    for n in names:
        c = resolve(n)
        canon_of[n] = "UTC" if (n in UTC_FAMILY or c in UTC_FAMILY) else c
    # "UTC" itself must be a name in the table for the family to point at it.
    assert "UTC" in names

    index = {n: i for i, n in enumerate(names)}
    out = []
    out.append("// SPDX-License-Identifier: Apache-2.0")
    out.append("//! Generated from the IANA tz database - do not edit by hand.")
    out.append("//! (tools/gen_tzdata.py, from tzdata.zi + the compiled TZif footers.)")
    out.append("//!")
    out.append("//! Every zone name the database knows, primary names and links alike, with")
    out.append("//! its standard UTC offset and, when it observes DST, the recurring rule from")
    out.append("//! the zone's POSIX TZ footer. `canon` indexes the name that stands for the")
    out.append("//! whole link group, which is what time-zone equality compares. The rules are")
    out.append("//! the zones' *present-day* ones: historical transitions are not modelled.")
    out.append("")
    out.append("/// A recurring DST rule: `week` 1-4 selects the Nth `dow` of the month, 5 the")
    out.append("/// last; `sec` is the transition's local time as seconds past midnight.")
    out.append("pub const Rule = struct {")
    out.append("    start_month: u8,")
    out.append("    start_week: u8,")
    out.append("    start_dow: u8,")
    out.append("    start_sec: i32,")
    out.append("    end_month: u8,")
    out.append("    end_week: u8,")
    out.append("    end_dow: u8,")
    out.append("    end_sec: i32,")
    out.append("};")
    out.append("")
    out.append("pub const Zone = struct {")
    out.append("    name: []const u8,")
    out.append("    canon: u16,")
    out.append("    std_offset_sec: i32,")
    out.append("    dst_save_sec: i32 = 0,")
    out.append("    rule: ?Rule = null,")
    out.append("};")
    out.append("")
    out.append("/// Sorted by case-folded name so lookups can binary-search case-insensitively.")
    out.append("pub const zones = [_]Zone{")
    unparsed = []
    for n in names:
        src_name = resolve(n)
        raw = data_by_name.get(src_name) or data_by_name.get(n)
        parsed = parse_tz(footer(raw)) if raw else None
        if parsed is None:
            if raw is not None:
                unparsed.append(n)
            std_off, dst_save, rule = 0, 0, None
        else:
            std_off, dst_save, rule = parsed
        ci = index[canon_of[n]]
        if rule is None:
            out.append('    .{ .name = "%s", .canon = %d, .std_offset_sec = %d },' % (n, ci, std_off))
        else:
            (sm, sw, sd, ss), (em, ew, ed, es) = rule
            out.append('    .{ .name = "%s", .canon = %d, .std_offset_sec = %d, .dst_save_sec = %d, .rule = .{ '
                       '.start_month = %d, .start_week = %d, .start_dow = %d, .start_sec = %d, '
                       '.end_month = %d, .end_week = %d, .end_dow = %d, .end_sec = %d } },'
                       % (n, ci, std_off, dst_save, sm, sw, sd, ss, em, ew, ed, es))
    out.append("};")
    out.append("")
    sys.stderr.write("zones: %d, unmodelled rules: %d %r\n" % (len(names), len(unparsed), unparsed[:10]))
    print("\n".join(out))

main()
