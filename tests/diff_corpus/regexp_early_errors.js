// A malformed pattern must be a SyntaxError at compile time, in both the
// Annex B (no /u) and the strict Unicode grammars.
function kind(p, f) {
  try { new RegExp(p, f); return 'ok'; } catch (e) { return e.constructor.name; }
}
var cases = [
  ['a**', ''], ['+a', ''], ['(*)', ''], ['a{1}{1,}', ''], ['{1}', ''],
  ['^*', ''], ['$*', ''], ['(?<=a)*', ''],
  ['a??', ''], ['(?=a)*', ''], ['{', ''], [']', ''], ['}', ''], ['a{', ''],
  ['(?=.)*', 'u'], ['a{1', 'u'], ['}', 'u'], ['\\1', 'u'], ['\\01', 'u'],
  ['\\x', 'u'], ['\\c', 'u'], ['\\A', 'u'], ['[\\d-a]', 'u'], ['[a-\\d]', 'u'],
  ['\\1(a)', 'u'], ['\\$', 'u'], ['[\\-]', 'u'], ['\\cA', 'u'],
  ['\\c', ''], ['\\1', ''], ['[\\d-a]', ''], ['\\x', '']
];
var out = [];
for (var i = 0; i < cases.length; i++) out.push(kind(cases[i][0], cases[i][1]));
out.join('|');
