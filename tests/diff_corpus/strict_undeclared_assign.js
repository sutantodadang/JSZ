// Phase 4d: strict-mode undeclared assignment throws ReferenceError in bc VM
function f(){"use strict"; try{ xyz_undef=1; return "no-throw"; }catch(e){return e.name;}}
function g(){ glob_undef=1; return "ok"; }
f() + "|" + g()
