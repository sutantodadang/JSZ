// ES2022 `d` flag: hasIndices, its place in `flags`, and the `indices` array.
var re = /(?<first>a)(z)?(b)/d;
var m = re.exec('xxab');
var out = [];
out.push(re.hasIndices);
out.push(re.flags);
out.push(/a/dgi.flags);
out.push(JSON.stringify(m.indices));
out.push(JSON.stringify(m.indices.groups));
out.push(String(m.indices[2]));
out.push(/a/.hasIndices);
out.push('indices' in /a/.exec('a'));
out.join('|');
