// Phase 4d: String.prototype.replace with function callback using capture groups
"a1b2".replace(/(\w)(\d)/g, function(m, a, b){return b+a;})
