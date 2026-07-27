// Wave 62a: \s / \S over multi-byte Unicode whitespace in non-/u mode.
// \s matches the full WhiteSpace + LineTerminator set regardless of the /u
// flag; \S is its complement and must match non-whitespace multi-byte chars
// (e.g. U+180E Mongolian Vowel Separator, non-whitespace since Unicode 6.3).
var out = [];
// U+3000 IDEOGRAPHIC SPACE is whitespace: \s matches, \S does not.
out.push(/\s/.test(String.fromCharCode(0x3000)));   // true
out.push(/\S/.test(String.fromCharCode(0x3000)));   // false
// U+180E is NOT whitespace: \S matches it fully (replace consumes all 3 bytes).
out.push(String.fromCharCode(0x180E).replace(/\S+/g, "X"));   // "X"
// U+0860 has a 0xA0 tail byte; \S+ must still consume the whole code point.
out.push(String.fromCharCode(0x0860).replace(/\S+/g, "X"));   // "X"
// NBSP (U+00A0) is whitespace even though 0xA0 also appears as a UTF-8 tail byte.
out.push(/^\s$/.test(String.fromCharCode(0x00A0)));  // true
// Anchored run over a string of Unicode spaces.
out.push(/^\s+$/.test("  　﻿ "));  // true
// \S does not match any of those whitespace chars.
out.push(/\S/.test("  　﻿"));  // false
out.join(",");
