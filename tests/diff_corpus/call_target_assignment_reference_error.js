var log = [];
function f() { log.push("f"); return {}; }
try { f() = 1; } catch (e) { log.push(e.constructor.name); }
log.join(",")