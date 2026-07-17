// Unicode /u flag: codepoint-aware matching, \u{}, \p{} with non-ASCII.
[
  /\u{41}/u.test("A"),        // \u{} for BMP ASCII
  /\u{E9}/u.test("é"),        // \u{} for BMP non-ASCII (é = U+00E9)
  /\p{L}/u.test("é"),         // \p{L} matches é (U+00E9)
  /\p{Lu}/u.test("É"),        // \p{Lu} matches É (uppercase U+00C9)
  /\p{Lu}/u.test("é"),        // \p{Lu} does NOT match é (lowercase)
  /\p{Nd}/u.test("١"),        // Arabic-Indic digit U+0661
  "éé".replace(/\p{L}/gu, "X"), // replace non-ASCII letters
  /./u.test("é"),              // dot matches BMP non-ASCII under /u
  /\p{L}+/u.test("中文"),      // CJK letters
].join("|")
