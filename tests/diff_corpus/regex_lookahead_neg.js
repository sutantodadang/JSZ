// Phase 4d: regex negative lookahead (?!...)
/a(?!b)/.test("ac") + "|" + /a(?!b)/.test("ab")
