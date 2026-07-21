// A positive assertion contributes its captures to the overall match; a
// negative one does not. A pattern that IS a bare assertion still matches
// (zero-width) at the first position where it holds.
var out = [];
out.push(JSON.stringify(/(?=(a+))/.exec('baaabac')));
out.push(String(/(?=a)/.exec('ba').index));
out.push(JSON.stringify(/(?=(a))a/.exec('a')));
out.push(JSON.stringify(/x(?=(a))/.exec('xa')));
out.push(JSON.stringify(/(a)(?=(b))/.exec('ab')));
out.push(JSON.stringify(/(?!(a))b/.exec('b')));
out.push(JSON.stringify(/(?<=(a))b/.exec('ab')));
out.push(String(/(?=a)/.test('a')));
out.join('|');
