// Phase 4b: JSON.parse SyntaxError is catchable
try { JSON.parse('{bad') } catch(e) { e.name }
