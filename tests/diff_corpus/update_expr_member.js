// Update expressions (++/--) must write the result back to member targets,
// not just to simple variables. Covers postfix/prefix on static props,
// computed keys, and array elements, plus the value the expression yields.
var out = [];
var o = { x: 0 };
o.x++;
out.push(o.x);            // 1  (postfix writes back)
o.x--;
out.push(o.x);            // 0
++o.x;
out.push(o.x);            // 1  (prefix writes back)
--o.x;
out.push(o.x);            // 0

var p = { n: 5 };
var post = p.n++;
out.push(post + "/" + p.n); // "5/6" (postfix yields old value)
var pre = ++p.n;
out.push(pre + "/" + p.n);  // "7/7" (prefix yields new value)

var a = [10, 20];
a[0]++;
a[1]--;
out.push(a.join(",")); // "11,19"

var k = "cnt";
var m = {};
m[k] = 0;
m[k]++;
m[k]++;
out.push(m.cnt); // 2 (computed-key write-back)

// Nested member target: the write-back lands on the inner object.
var nested = { inner: { count: 41 } };
nested.inner.count++;
out.push(nested.inner.count); // 42

out.join("|")
