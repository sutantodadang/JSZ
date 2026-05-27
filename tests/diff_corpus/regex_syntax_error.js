// Phase 4c: invalid pattern -> SyntaxError
try { new RegExp("[") } catch(e) { e.name }
