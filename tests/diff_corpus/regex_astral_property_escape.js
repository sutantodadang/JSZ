// Wave 45a: astral code points built via `\u{...}` / String.fromCodePoint are
// stored as a WTF-8 surrogate pair; `/u` mode must still see one code point.
var s = String.fromCodePoint(0x1E900);
[
  /\p{Script=Adlam}/u.test(s),
  /^\p{Script=Adlam}$/u.test(s),
  /^\u{1E900}$/u.test("\u{1E900}"),
  /^.$/u.test("\u{1E900}"),
  /^[\p{Script=Adlam}]$/u.test(s),
  /^\p{L}$/u.test(s),
  // Without /u the pair is two separate UTF-16 code units.
  /^.$/.test(s),
  "\u{1F600}".replace(/./gu, "X"),
  "a\u{1F600}b".match(/./gu).length
].join(",")
