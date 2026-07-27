// Wave 62c: JSONNumber requires a digit after '.' and after the exponent, so
// '1.', '1.e3', '.5' and '1e' are all SyntaxErrors; valid forms still parse.
[' 1.', '1.e3', '.5', '1e', '1e+'].map(function(s){ try { JSON.parse(s); return 'ok'; } catch(e){ return e.name === 'SyntaxError' ? 'err' : 'other'; } }).concat([JSON.parse('1.5'), JSON.parse('4e2'), JSON.parse('1.5e-3')]).join(',')
