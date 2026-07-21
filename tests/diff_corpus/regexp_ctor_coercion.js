// RegExp(pattern, flags): a RegExp argument donates its source and (when flags
// are omitted) its flags; everything else is ToString'd.
var out = [];
var re = /x/i;
out.push(RegExp(re) === re);
out.push(new RegExp(re) === re);
var copy = new RegExp(/./gi);
out.push(copy.source + ',' + copy.flags);
var reflagged = new RegExp(/./gi, 'm');
out.push(reflagged.source + ',' + reflagged.flags);
var coerced = new RegExp(
  { toString: undefined, valueOf: function () { return '[z-z]'; } },
  { toString: undefined, valueOf: function () { return 'mig'; } }
);
out.push(coerced.source + ',' + coerced.flags);
out.push(new RegExp(123).source);
try { new RegExp('.', null); out.push('ok'); } catch (e) { out.push(e.constructor.name); }
out.join('|');
