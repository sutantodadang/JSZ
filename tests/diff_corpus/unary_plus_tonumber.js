// Unary + is ToNumber (not ToNumeric): coerces strings/booleans/objects, but
// throws on BigInt and Symbol. Also must preserve -0 and honor valueOf.
function t(f){ try { return String(f()); } catch(e){ return e.constructor.name; } }
[
  t(function(){ return +"3"; }),   t(function(){ return +""; }),
  t(function(){ return +"abc"; }), t(function(){ return +true; }),
  t(function(){ return +null; }),  t(function(){ return +undefined; }),
  t(function(){ return +[]; }),    t(function(){ return +[5]; }),
  t(function(){ return +{}; }),    t(function(){ return +(-0); }),
  t(function(){ return 1/+(-0); }),
  t(function(){ return +"0x1f"; }),
  t(function(){ return +Symbol(); }),
  t(function(){ return +1n; }),
  t(function(){ return +({valueOf:function(){return 1n;}}); }),
  t(function(){ return +({valueOf:function(){return 42;}}); }),
  t(function(){ return +Infinity; }), t(function(){ return +NaN; })
].join('|');
