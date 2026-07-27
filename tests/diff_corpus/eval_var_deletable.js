// Wave 62c: a var introduced by direct eval is deletable; after delete the
// binding is gone, so a closure that reads it throws ReferenceError.
(function(){ eval('var x = 5; delete x; this.__pd = function(){ return x; };'); try { __pd(); return 'accessible'; } catch(e){ return e.name; } })()
