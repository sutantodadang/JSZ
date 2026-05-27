// Phase 4d: regex positive lookahead (?=...)
/a(?=b)/.test("ab") + "|" + /a(?=b)/.test("ac")
