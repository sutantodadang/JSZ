// CanonicalizeUnicodeLocaleId (ECMA-402 §6.2.3 / UTS #35 §3.2.1): parse a
// BCP-47 tag into its `unicode_locale_id` pieces, normalize their case, apply
// the CLDR alias replacements, and re-emit the subtags in canonical order.
//
// The alias tables below are the parts of `supplementalMetadata.xml` and
// `bcp47/*.xml` that a locale identifier can actually name. They are data, not
// behaviour: everything that acts on them lives in `canonicalize`.

const std = @import("std");

/// The parsed pieces of a `unicode_locale_id`, all already lowercased.
const Parsed = struct {
    language: []const u8,
    script: []const u8 = "",
    region: []const u8 = "",
    variants: [][]const u8 = &.{},
    /// `-u-`/`-t-`/… sequences, in source order; `singleton` is the key letter.
    extensions: []Extension = &.{},
    /// The `x-…` private-use sequence body ("" when absent).
    private_use: []const u8 = "",
};

const Extension = struct { singleton: u8, subtags: [][]const u8 };

fn isAlpha(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphabetic(c)) return false;
    return s.len > 0;
}

fn isDigits(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isDigit(c)) return false;
    return s.len > 0;
}

fn isAlnum(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isAlphanumeric(c)) return false;
    return s.len > 0;
}

fn isVariant(s: []const u8) bool {
    if (s.len >= 5 and s.len <= 8) return isAlnum(s);
    return s.len == 4 and std.ascii.isDigit(s[0]) and isAlnum(s);
}

fn lower(arena: std.mem.Allocator, s: []const u8) ![]const u8 {
    const buf = try arena.alloc(u8, s.len);
    for (s, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf;
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// Split `tag` on `-`, lowercasing every subtag. Rejects empty subtags and any
/// byte outside `[A-Za-z0-9-]` (so a non-ASCII tag never reaches the parser).
fn splitSubtags(arena: std.mem.Allocator, tag: []const u8) !?[][]const u8 {
    if (tag.len == 0 or tag.len > 256) return null;
    var out = std.ArrayListUnmanaged([]const u8){};
    var it = std.mem.splitScalar(u8, tag, '-');
    while (it.next()) |sub| {
        if (sub.len == 0 or sub.len > 8) return null;
        if (!isAlnum(sub)) return null;
        try out.append(arena, try lower(arena, sub));
    }
    return out.items;
}

/// Parse a `unicode_language_id` starting at `subs[i.*]`, advancing `i`.
/// Returns null when the subtags at that position are not one.
fn parseLanguageId(arena: std.mem.Allocator, subs: [][]const u8, i: *usize) !?Parsed {
    if (i.* >= subs.len) return null;
    const lang = subs[i.*];
    const lang_ok = isAlpha(lang) and ((lang.len >= 2 and lang.len <= 3) or (lang.len >= 5 and lang.len <= 8));
    if (!lang_ok) return null;
    i.* += 1;
    var res = Parsed{ .language = lang };
    if (i.* < subs.len and subs[i.*].len == 4 and isAlpha(subs[i.*])) {
        res.script = subs[i.*];
        i.* += 1;
    }
    if (i.* < subs.len and ((subs[i.*].len == 2 and isAlpha(subs[i.*])) or
        (subs[i.*].len == 3 and isDigits(subs[i.*]))))
    {
        res.region = subs[i.*];
        i.* += 1;
    }
    var variants = std.ArrayListUnmanaged([]const u8){};
    while (i.* < subs.len and isVariant(subs[i.*])) : (i.* += 1) {
        // A repeated variant makes the tag structurally invalid.
        for (variants.items) |v| if (std.mem.eql(u8, v, subs[i.*])) return null;
        try variants.append(arena, subs[i.*]);
    }
    res.variants = variants.items;
    return res;
}

/// Parse a whole `unicode_locale_id`. Returns null when `tag` is not one.
fn parse(arena: std.mem.Allocator, tag: []const u8) !?Parsed {
    const subs = (try splitSubtags(arena, tag)) orelse return null;
    var i: usize = 0;
    var res = (try parseLanguageId(arena, subs, &i)) orelse return null;

    var exts = std.ArrayListUnmanaged(Extension){};
    var seen = std.ArrayListUnmanaged(u8){};
    while (i < subs.len) {
        if (subs[i].len != 1) return null;
        const singleton = subs[i][0];
        for (seen.items) |s| if (s == singleton) return null;
        try seen.append(arena, singleton);
        i += 1;
        const body_start = i;
        // `x-` private use takes 1..8-character subtags and swallows the rest of
        // the tag; every other singleton requires 2..8 and stops at the next one.
        const min_len: usize = if (singleton == 'x') 1 else 2;
        while (i < subs.len and subs[i].len >= min_len and subs[i].len <= 8) i += 1;
        if (i == body_start) return null;
        if (singleton == 'x') {
            res.private_use = try std.mem.join(arena, "-", subs[body_start..i]);
            if (i != subs.len) return null;
            break;
        }
        try exts.append(arena, .{ .singleton = singleton, .subtags = subs[body_start..i] });
    }
    res.extensions = exts.items;
    return res;
}

/// Canonicalize the `-u-` body: attributes first (sorted), then keywords sorted
/// by key, with alias-replaced types and the implicit `true` value elided.
fn canonicalizeUnicodeExtension(arena: std.mem.Allocator, subtags: [][]const u8) !?[][]const u8 {
    var attributes = std.ArrayListUnmanaged([]const u8){};
    var keys = std.ArrayListUnmanaged([]const u8){};
    var values = std.ArrayListUnmanaged([]const u8){};

    var idx: usize = 0;
    while (idx < subtags.len and subtags[idx].len != 2) : (idx += 1) {
        try attributes.append(arena, subtags[idx]);
    }
    while (idx < subtags.len) {
        const key = subtags[idx];
        // A `-u-` key is `alphanum alpha`: a digit in second position is not one.
        if (!std.ascii.isAlphabetic(key[1])) return null;
        idx += 1;
        const start = idx;
        while (idx < subtags.len and subtags[idx].len != 2) idx += 1;
        var value: []const u8 = try std.mem.join(arena, "-", subtags[start..idx]);
        value = aliasFor(&unicode_type_aliases, key, value) orelse value;
        // `-u-kb-true` and `-u-kb` mean the same thing; the canonical form omits
        // the value. (The `true` spelling itself arrives via the alias table.)
        if (std.mem.eql(u8, value, "true")) value = "";
        // A duplicate key keeps only its first occurrence.
        var dup = false;
        for (keys.items) |k| {
            if (std.mem.eql(u8, k, key)) dup = true;
        }
        if (dup) continue;
        try keys.append(arena, key);
        try values.append(arena, value);
    }

    std.mem.sort([]const u8, attributes.items, {}, lessThan);
    // Sort the keyword list by key, carrying each value along.
    for (1..@max(keys.items.len, 1)) |k| {
        var j = k;
        while (j > 0 and std.mem.lessThan(u8, keys.items[j], keys.items[j - 1])) : (j -= 1) {
            std.mem.swap([]const u8, &keys.items[j], &keys.items[j - 1]);
            std.mem.swap([]const u8, &values.items[j], &values.items[j - 1]);
        }
    }

    var out = std.ArrayListUnmanaged([]const u8){};
    try out.appendSlice(arena, attributes.items);
    for (keys.items, values.items) |k, v| {
        try out.append(arena, k);
        if (v.len > 0) try out.append(arena, v);
    }
    return out.items;
}

fn isTKey(s: []const u8) bool {
    return s.len == 2 and std.ascii.isAlphabetic(s[0]) and std.ascii.isDigit(s[1]);
}

/// Canonicalize the `-t-` body: the optional `tlang` prefix is itself a locale
/// id, and the `key-value` fields that follow are sorted by key.
fn canonicalizeTransformedExtension(arena: std.mem.Allocator, subtags: [][]const u8) !?[][]const u8 {
    var idx: usize = 0;
    var out = std.ArrayListUnmanaged([]const u8){};
    // A `tlang` is present when the body does not start with a field key
    // (UTS #35 `tkey = alpha digit`, e.g. `d0`, `m0` — distinct from the
    // `alphanum alpha` keys of the `-u-` extension, so the grammar is unambiguous).
    const has_tlang = subtags.len > 0 and !isTKey(subtags[0]);
    if (has_tlang) {
        var tlang = (try parseLanguageId(arena, subtags, &idx)) orelse return null;
        applyLanguageIdAliases(arena, &tlang) catch return null;
        try out.appendSlice(arena, try emitLanguageId(arena, tlang));
    }
    var keys = std.ArrayListUnmanaged([]const u8){};
    var values = std.ArrayListUnmanaged([][]const u8){};
    while (idx < subtags.len) {
        const key = subtags[idx];
        if (!isTKey(key)) return null;
        idx += 1;
        const start = idx;
        while (idx < subtags.len and subtags[idx].len >= 3 and subtags[idx].len <= 8) idx += 1;
        if (idx == start) return null; // a `-t-` field must carry a value
        try keys.append(arena, key);
        try values.append(arena, subtags[start..idx]);
    }
    for (1..@max(keys.items.len, 1)) |k| {
        var j = k;
        while (j > 0 and std.mem.lessThan(u8, keys.items[j], keys.items[j - 1])) : (j -= 1) {
            std.mem.swap([]const u8, &keys.items[j], &keys.items[j - 1]);
            std.mem.swap([][]const u8, &values.items[j], &values.items[j - 1]);
        }
    }
    for (keys.items, values.items) |k, v| {
        try out.append(arena, k);
        try out.appendSlice(arena, v);
    }
    return out.items;
}

/// Emit a parsed language id as canonically-cased subtags.
fn emitLanguageId(arena: std.mem.Allocator, p: Parsed) ![][]const u8 {
    var out = std.ArrayListUnmanaged([]const u8){};
    try out.append(arena, p.language);
    if (p.script.len == 4) {
        const s = try arena.dupe(u8, p.script);
        s[0] = std.ascii.toUpper(s[0]);
        try out.append(arena, s);
    }
    if (p.region.len > 0) {
        try out.append(arena, if (isAlpha(p.region))
            std.ascii.allocUpperString(arena, p.region) catch p.region
        else
            p.region);
    }
    // The canonical order of variants is US-ASCII order.
    const vars = try arena.dupe([]const u8, p.variants);
    std.mem.sort([]const u8, vars, {}, lessThan);
    try out.appendSlice(arena, vars);
    return out.items;
}

fn aliasFor(table: []const [3][]const u8, key: []const u8, value: []const u8) ?[]const u8 {
    for (table) |row| {
        if (std.mem.eql(u8, row[0], key) and std.mem.eql(u8, row[1], value)) return row[2];
    }
    return null;
}

/// Apply the CLDR language / script / region / variant alias replacements in
/// place. A language alias may itself carry a script or region, which fills in
/// only the fields the tag left empty (`sh` → `sr-Latn`, `cnr` → `sr-ME`).
fn applyLanguageIdAliases(arena: std.mem.Allocator, p: *Parsed) !void {
    for (language_aliases) |row| {
        if (!std.mem.eql(u8, row[0], p.language)) continue;
        var it = std.mem.splitScalar(u8, row[1], '-');
        p.language = it.next().?;
        while (it.next()) |extra| {
            if (extra.len == 4) {
                if (p.script.len == 0) p.script = extra;
            } else if (p.region.len == 0) p.region = extra;
        }
        break;
    }
    // Some aliases only apply to a language+region or language+variant pair.
    for (complex_language_aliases) |row| {
        if (std.mem.eql(u8, row[0], p.language) and std.mem.eql(u8, row[1], p.region)) {
            p.language = row[2];
            break;
        }
    }
    if (p.region.len > 0) {
        // A "complex" region alias picks its replacement from the language; the
        // tables below list the pairs CLDR resolves differently from the default.
        for (complex_region_aliases) |row| {
            if (!std.mem.eql(u8, row[0], p.region)) continue;
            if (std.mem.eql(u8, row[1], p.language) or std.mem.eql(u8, row[1], p.script)) {
                p.region = row[2];
                break;
            }
        } else for (region_aliases) |row| {
            if (std.mem.eql(u8, row[0], p.region)) {
                p.region = row[1];
                break;
            }
        }
    }
    if (p.variants.len > 0) {
        var kept = std.ArrayListUnmanaged([]const u8){};
        for (p.variants) |v| {
            var repl: ?[]const u8 = null;
            for (variant_aliases) |row| {
                if (std.mem.eql(u8, row[0], v) and
                    (row[1].len == 0 or std.mem.eql(u8, row[1], p.language)))
                {
                    repl = row[2];
                    break;
                }
            }
            if (repl) |r| {
                // An empty replacement drops the variant; a language-shaped one
                // replaces the language instead (`hy-arevmda` → `hyw`).
                if (r.len == 0) continue;
                if (r[0] == '=') {
                    p.language = r[1..];
                    continue;
                }
                try kept.append(arena, r);
            } else try kept.append(arena, v);
        }
        p.variants = kept.items;
    }
}

/// CanonicalizeUnicodeLocaleId. Returns null when `tag` is not a structurally
/// valid `unicode_locale_id`, which callers surface as a RangeError.
pub fn canonicalize(arena: std.mem.Allocator, tag: []const u8) !?[]const u8 {
    const lowered = try lower(arena, tag);
    // The regular grandfathered tags are not `unicode_locale_id`s at all, so
    // they are mapped before parsing.
    for (grandfathered) |row| {
        if (std.mem.eql(u8, row[0], lowered)) return try canonicalize(arena, row[1]);
    }
    for (language_id_aliases) |row| {
        if (std.mem.startsWith(u8, lowered, row[0]) and
            (lowered.len == row[0].len or lowered[row[0].len] == '-'))
        {
            return try canonicalize(arena, try std.mem.concat(arena, u8, &.{ row[1], lowered[row[0].len..] }));
        }
    }
    var p = (try parse(arena, tag)) orelse return null;
    try applyLanguageIdAliases(arena, &p);

    var out = std.ArrayListUnmanaged([]const u8){};
    try out.appendSlice(arena, try emitLanguageId(arena, p));

    // Extensions are emitted in US-ASCII order of their singleton.
    const exts = try arena.dupe(Extension, p.extensions);
    std.mem.sort(Extension, exts, {}, struct {
        fn lt(_: void, a: Extension, b: Extension) bool {
            return a.singleton < b.singleton;
        }
    }.lt);
    for (exts) |ext| {
        const body: [][]const u8 = switch (ext.singleton) {
            'u' => (try canonicalizeUnicodeExtension(arena, ext.subtags)) orelse return null,
            't' => (try canonicalizeTransformedExtension(arena, ext.subtags)) orelse return null,
            else => ext.subtags,
        };
        if (body.len == 0) continue;
        try out.append(arena, try arena.dupe(u8, &[_]u8{ext.singleton}));
        try out.appendSlice(arena, body);
    }
    if (p.private_use.len > 0) {
        try out.append(arena, "x");
        try out.append(arena, p.private_use);
    }
    return try std.mem.join(arena, "-", out.items);
}

/// The `unicode_language_id` prefix of a canonical tag — what a service uses as
/// its resolved locale once the `-u-` keywords have been consumed.
pub fn languageIdOf(tag: []const u8) []const u8 {
    var pos: usize = 0;
    var end: usize = tag.len;
    var first = true;
    while (pos < tag.len) {
        const dash = std.mem.indexOfScalarPos(u8, tag, pos, '-') orelse tag.len;
        if (!first and dash - pos == 1) {
            end = pos - 1;
            break;
        }
        first = false;
        pos = dash + 1;
    }
    return tag[0..end];
}

// ------------------------------------------------------------------- data ---

/// Regular grandfathered tags (RFC 5646) that CLDR maps to a modern tag. The
/// irregular ones (`i-klingon`, `sgn-BE-FR`, `en-GB-oed`, …) are not
/// `unicode_locale_id`s at all and stay rejected.
const grandfathered = [_][2][]const u8{
    .{ "art-lojban", "jbo" },
    .{ "cel-gaulish", "xtg" },
    .{ "zh-guoyu", "zh" },
    .{ "zh-hakka", "hak" },
    .{ "zh-min-nan", "nan" },
    .{ "zh-xiang", "hsn" },
    .{ "no-bok", "nb" },
    .{ "no-nyn", "nn" },
};

/// `languageAlias` entries whose replacement depends only on the language: the
/// ISO 639-2/T and /B codes that have a 639-1 equivalent, plus the deprecated
/// codes CLDR retires. A replacement may add a script or region subtag.
const language_aliases = [_][2][]const u8{
    // Deprecated / renamed languages.
    .{ "in", "id" },      .{ "iw", "he" },     .{ "ji", "yi" },
    .{ "jw", "jv" },      .{ "mo", "ro" },     .{ "tl", "fil" },
    .{ "sh", "sr-Latn" }, .{ "cnr", "sr-ME" }, .{ "swc", "sw-CD" },
    .{ "aam", "aas" },    .{ "adp", "dz" },    .{ "aue", "ktz" },
    .{ "ayx", "nun" },    .{ "bgm", "bcg" },   .{ "cqu", "quh" },
    .{ "drh", "mn" },     .{ "drw", "fa-AF" }, .{ "gav", "dev" },
    .{ "gfx", "vaj" },    .{ "hrr", "jal" },   .{ "ibi", "opa" },
    .{ "jeg", "oyb" },    .{ "kgc", "tdf" },   .{ "kgh", "kml" },
    .{ "koj", "kwv" },    .{ "krm", "bmf" },   .{ "ktr", "dtp" },
    .{ "kvs", "gdj" },    .{ "kwq", "yam" },   .{ "kxe", "tvd" },
    .{ "kzj", "dtp" },    .{ "kzt", "dtp" },   .{ "lii", "raq" },
    .{ "lmm", "rmx" },    .{ "meg", "cir" },   .{ "mst", "mry" },
    .{ "mwj", "vaj" },    .{ "myt", "mry" },   .{ "nad", "xny" },
    .{ "ncp", "kdz" },    .{ "nnx", "ngv" },   .{ "nts", "pij" },
    .{ "oun", "vaj" },    .{ "pcr", "adx" },   .{ "pmc", "huw" },
    .{ "pmu", "phr" },    .{ "ppa", "bfy" },   .{ "ppr", "lcq" },
    .{ "pry", "prt" },    .{ "puz", "pub" },   .{ "sca", "hle" },
    .{ "skk", "oyb" },    .{ "tdu", "dtp" },   .{ "thc", "tpo" },
    .{ "thx", "oyb" },    .{ "tie", "ras" },   .{ "tkk", "twm" },
    .{ "tlw", "weo" },    .{ "tmp", "tyj" },   .{ "tne", "kak" },
    .{ "tnf", "fa-AF" },  .{ "tsf", "taj" },   .{ "uok", "ema" },
    .{ "xba", "cax" },    .{ "xia", "acn" },   .{ "xkh", "waw" },
    .{ "xsj", "suj" },    .{ "ybd", "rki" },   .{ "yma", "lrr" },
    .{ "ymt", "mtm" },    .{ "yos", "zom" },   .{ "yuu", "yug" },
    // ISO 639-2 codes with a 639-1 equivalent.
    .{ "aar", "aa" },     .{ "abk", "ab" },    .{ "afr", "af" },
    .{ "aka", "ak" },     .{ "alb", "sq" },    .{ "amh", "am" },
    .{ "ara", "ar" },     .{ "arg", "an" },    .{ "arm", "hy" },
    .{ "asm", "as" },     .{ "ava", "av" },    .{ "ave", "ae" },
    .{ "aym", "ay" },     .{ "aze", "az" },    .{ "bak", "ba" },
    .{ "bam", "bm" },     .{ "baq", "eu" },    .{ "bel", "be" },
    .{ "ben", "bn" },     .{ "bih", "bh" },    .{ "bis", "bi" },
    .{ "bod", "bo" },     .{ "bos", "bs" },    .{ "bre", "br" },
    .{ "bul", "bg" },     .{ "bur", "my" },    .{ "cat", "ca" },
    .{ "ces", "cs" },     .{ "cha", "ch" },    .{ "che", "ce" },
    .{ "chi", "zh" },     .{ "chu", "cu" },    .{ "chv", "cv" },
    .{ "cor", "kw" },     .{ "cos", "co" },    .{ "cre", "cr" },
    .{ "cym", "cy" },     .{ "cze", "cs" },    .{ "dan", "da" },
    .{ "deu", "de" },     .{ "div", "dv" },    .{ "dut", "nl" },
    .{ "dzo", "dz" },     .{ "ell", "el" },    .{ "eng", "en" },
    .{ "epo", "eo" },     .{ "est", "et" },    .{ "eus", "eu" },
    .{ "ewe", "ee" },     .{ "fao", "fo" },    .{ "fas", "fa" },
    .{ "fij", "fj" },     .{ "fin", "fi" },    .{ "fra", "fr" },
    .{ "fre", "fr" },     .{ "fry", "fy" },    .{ "ful", "ff" },
    .{ "geo", "ka" },     .{ "ger", "de" },    .{ "gla", "gd" },
    .{ "gle", "ga" },     .{ "glg", "gl" },    .{ "glv", "gv" },
    .{ "gre", "el" },     .{ "grn", "gn" },    .{ "guj", "gu" },
    .{ "hat", "ht" },     .{ "hau", "ha" },    .{ "heb", "he" },
    .{ "her", "hz" },     .{ "hin", "hi" },    .{ "hmo", "ho" },
    .{ "hrv", "hr" },     .{ "hun", "hu" },    .{ "hye", "hy" },
    .{ "ibo", "ig" },     .{ "ice", "is" },    .{ "ido", "io" },
    .{ "iii", "ii" },     .{ "iku", "iu" },    .{ "ile", "ie" },
    .{ "ina", "ia" },     .{ "ind", "id" },    .{ "ipk", "ik" },
    .{ "isl", "is" },     .{ "ita", "it" },    .{ "jav", "jv" },
    .{ "jpn", "ja" },     .{ "kal", "kl" },    .{ "kan", "kn" },
    .{ "kas", "ks" },     .{ "kat", "ka" },    .{ "kau", "kr" },
    .{ "kaz", "kk" },     .{ "khm", "km" },    .{ "kik", "ki" },
    .{ "kin", "rw" },     .{ "kir", "ky" },    .{ "kom", "kv" },
    .{ "kon", "kg" },     .{ "kor", "ko" },    .{ "kua", "kj" },
    .{ "kur", "ku" },     .{ "lao", "lo" },    .{ "lat", "la" },
    .{ "lav", "lv" },     .{ "lim", "li" },    .{ "lin", "ln" },
    .{ "lit", "lt" },     .{ "ltz", "lb" },    .{ "lub", "lu" },
    .{ "lug", "lg" },     .{ "mac", "mk" },    .{ "mah", "mh" },
    .{ "mal", "ml" },     .{ "mao", "mi" },    .{ "mar", "mr" },
    .{ "may", "ms" },     .{ "mkd", "mk" },    .{ "mlg", "mg" },
    .{ "mlt", "mt" },     .{ "mon", "mn" },    .{ "mri", "mi" },
    .{ "msa", "ms" },     .{ "mya", "my" },    .{ "nau", "na" },
    .{ "nav", "nv" },     .{ "nbl", "nr" },    .{ "nde", "nd" },
    .{ "ndo", "ng" },     .{ "nep", "ne" },    .{ "nld", "nl" },
    .{ "nno", "nn" },     .{ "nob", "nb" },    .{ "nor", "no" },
    .{ "nya", "ny" },     .{ "oci", "oc" },    .{ "oji", "oj" },
    .{ "ori", "or" },     .{ "orm", "om" },    .{ "oss", "os" },
    .{ "pan", "pa" },     .{ "per", "fa" },    .{ "pli", "pi" },
    .{ "pol", "pl" },     .{ "por", "pt" },    .{ "pus", "ps" },
    .{ "que", "qu" },     .{ "roh", "rm" },    .{ "ron", "ro" },
    .{ "rum", "ro" },     .{ "run", "rn" },    .{ "rus", "ru" },
    .{ "sag", "sg" },     .{ "san", "sa" },    .{ "sin", "si" },
    .{ "slk", "sk" },     .{ "slo", "sk" },    .{ "slv", "sl" },
    .{ "sme", "se" },     .{ "smo", "sm" },    .{ "sna", "sn" },
    .{ "snd", "sd" },     .{ "som", "so" },    .{ "sot", "st" },
    .{ "spa", "es" },     .{ "sqi", "sq" },    .{ "srd", "sc" },
    .{ "srp", "sr" },     .{ "ssw", "ss" },    .{ "sun", "su" },
    .{ "swa", "sw" },     .{ "swe", "sv" },    .{ "tah", "ty" },
    .{ "tam", "ta" },     .{ "tat", "tt" },    .{ "tel", "te" },
    .{ "tgk", "tg" },     .{ "tgl", "fil" },   .{ "tha", "th" },
    .{ "tib", "bo" },     .{ "tir", "ti" },    .{ "ton", "to" },
    .{ "tsn", "tn" },     .{ "tso", "ts" },    .{ "tuk", "tk" },
    .{ "tur", "tr" },     .{ "twi", "tw" },    .{ "uig", "ug" },
    .{ "ukr", "uk" },     .{ "urd", "ur" },    .{ "uzb", "uz" },
    .{ "ven", "ve" },     .{ "vie", "vi" },    .{ "vol", "vo" },
    .{ "wel", "cy" },     .{ "wln", "wa" },    .{ "wol", "wo" },
    .{ "xho", "xh" },     .{ "yid", "yi" },    .{ "yor", "yo" },
    .{ "zha", "za" },     .{ "zho", "zh" },    .{ "zul", "zu" },
};

/// `languageAlias` entries whose key is a whole language id — CLDR replaces the
/// `hepburn-heploc` variant pair as a unit, not variant by variant.
const language_id_aliases = [_][2][]const u8{
    .{ "ja-latn-hepburn-heploc", "ja-Latn-alalc97" },
};

/// `languageAlias` entries keyed on a language+region pair.
const complex_language_aliases = [_][3][]const u8{};

/// `territoryAlias` entries with a single replacement.
const region_aliases = [_][2][]const u8{
    .{ "bu", "MM" },  .{ "dd", "DE" },  .{ "fx", "FR" },  .{ "tp", "TL" },
    .{ "yd", "YE" },  .{ "zr", "CD" },  .{ "uk", "GB" },  .{ "cs", "RS" },
    .{ "an", "CW" },  .{ "nt", "SA" },  .{ "qu", "EU" },  .{ "su", "RU" },
    .{ "810", "RU" }, .{ "890", "RS" }, .{ "230", "ET" }, .{ "280", "DE" },
    .{ "886", "YE" }, .{ "958", "AA" }, .{ "200", "CZ" }, .{ "062", "034" },
    .{ "530", "CW" }, .{ "532", "CW" }, .{ "536", "SA" }, .{ "582", "FM" },
    .{ "736", "SD" }, .{ "886", "YE" },
};

/// `territoryAlias` entries whose replacement is chosen by the tag's language or
/// script — the "multiple replacement" rows of `supplementalMetadata.xml`.
const complex_region_aliases = [_][3][]const u8{
    .{ "su", "hy", "AM" },   .{ "810", "hy", "AM" },
    .{ "su", "armn", "AM" }, .{ "810", "armn", "AM" },
    .{ "su", "az", "AZ" },   .{ "810", "az", "AZ" },
    .{ "su", "be", "BY" },   .{ "810", "be", "BY" },
    .{ "su", "et", "EE" },   .{ "810", "et", "EE" },
    .{ "su", "ka", "GE" },   .{ "810", "ka", "GE" },
    .{ "su", "kk", "KZ" },   .{ "810", "kk", "KZ" },
    .{ "su", "ky", "KG" },   .{ "810", "ky", "KG" },
    .{ "su", "lt", "LT" },   .{ "810", "lt", "LT" },
    .{ "su", "lv", "LV" },   .{ "810", "lv", "LV" },
    .{ "su", "mo", "MD" },   .{ "810", "mo", "MD" },
    .{ "su", "tg", "TJ" },   .{ "810", "tg", "TJ" },
    .{ "su", "tk", "TM" },   .{ "810", "tk", "TM" },
    .{ "su", "uk", "UA" },   .{ "810", "uk", "UA" },
    .{ "su", "uz", "UZ" },   .{ "810", "uz", "UZ" },
};

/// `variantAlias` entries: `{ variant, language-or-"" , replacement }`. An empty
/// replacement drops the variant; a `=`-prefixed one replaces the language.
const variant_aliases = [_][3][]const u8{
    .{ "heploc", "", "alalc97" },
    .{ "polytoni", "", "polyton" },
    .{ "arevela", "hy", "" },
    .{ "arevmda", "hy", "=hyw" },
    .{ "aaland", "", "" },
};

/// `bcp47` type aliases, as `{ key, deprecated type, canonical type }`.
const unicode_type_aliases = [_][3][]const u8{
    // Booleans: the deprecated "yes" spelling of "true", which is then elided.
    .{ "kb", "yes", "true" },               .{ "kc", "yes", "true" },
    .{ "kh", "yes", "true" },               .{ "kk", "yes", "true" },
    .{ "kn", "yes", "true" },
    // Calendars.
                  .{ "ca", "ethiopic-amete-alem", "ethioaa" },
    .{ "ca", "islamicc", "islamic-civil" },
    // Collation.
    .{ "co", "dictionary", "dict" },
    .{ "co", "gb2312han", "gb2312" },       .{ "co", "phonebook", "phonebk" },
    .{ "co", "traditional", "trad" },       .{ "ks", "primary", "level1" },
    .{ "ks", "secondary", "level2" },       .{ "ks", "tertiary", "level3" },
    .{ "ks", "quaternary", "level4" },      .{ "ks", "quartenary", "level4" },
    .{ "ks", "identical", "identic" },
    // Measurement system.
         .{ "ms", "imperial", "uksystem" },
    // Time zones.
    .{ "tz", "cnckg", "cnsha" },            .{ "tz", "cnhrb", "cnsha" },
    .{ "tz", "cnkhg", "cnsha" },            .{ "tz", "aqams", "nzakl" },
    .{ "tz", "eire", "iedub" },             .{ "tz", "est", "papty" },
    .{ "tz", "gmt0", "gmt" },               .{ "tz", "uct", "utc" },
    .{ "tz", "zulu", "utc" },               .{ "tz", "greenwich", "gmt" },
    .{ "tz", "navajo", "usden" },           .{ "tz", "cuba", "cuhav" },
    .{ "tz", "egypt", "egcai" },            .{ "tz", "iran", "irthr" },
    .{ "tz", "israel", "jeruslm" },         .{ "tz", "jamaica", "jmkin" },
    .{ "tz", "japan", "jptyo" },            .{ "tz", "poland", "plwaw" },
    .{ "tz", "portugal", "ptlis" },         .{ "tz", "singapore", "sgsin" },
    .{ "tz", "turkey", "trist" },
    // Subdivision and region-override aliases.
              .{ "rg", "no23", "no50" },
    .{ "sd", "no23", "no50" },              .{ "rg", "cn11", "cnbj" },
    .{ "sd", "cn11", "cnbj" },              .{ "rg", "cz10a", "cz110" },
    .{ "sd", "cz10a", "cz110" },            .{ "rg", "fra", "frges" },
    .{ "sd", "fra", "frges" },              .{ "rg", "frg", "frges" },
    .{ "sd", "frg", "frges" },              .{ "rg", "lud", "lucl" },
    .{ "sd", "lud", "lucl" },
};

test "locale id: case, order and alias canonicalization" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_][2][]const u8{
        .{ "ab-cd", "ab-CD" },
        .{ "th-th-u-nu-thai", "th-TH-u-nu-thai" },
        .{ "it-u-nu-latn-ca-gregory", "it-u-ca-gregory-nu-latn" },
        .{ "und-u-kb-yes", "und-u-kb" },
        .{ "und-u-ca-islamicc", "und-u-ca-islamic-civil" },
        .{ "ja-latn-hepburn-heploc", "ja-Latn-alalc97" },
        .{ "sh-Cyrl", "sr-Cyrl" },
        .{ "hy-SU", "hy-AM" },
        .{ "ru-810", "ru-RU" },
        .{ "art-lojban", "jbo" },
        .{ "heb-x-private", "he-x-private" },
        .{ "en-a-bar-u-baz-x-u-foo", "en-a-bar-u-baz-x-u-foo" },
    };
    for (cases) |c| {
        const got = (try canonicalize(a, c[0])) orelse return error.TestUnexpectedResult;
        try std.testing.expectEqualStrings(c[1], got);
    }
    try std.testing.expect((try canonicalize(a, "en-us-us")) == null);
}
