// Wave 45a: `break` nested inside an if/block/try within a switch case must
// exit the switch -- not fall through, and not break the enclosing loop.
// A switch is a break target but never a continue target.
var RES = [];

// break inside `if` inside `default`, with no enclosing loop
function getId(c) {
  var end = 0;
  switch (c) {
    case '_':
      end += 1;
      break;
    default:
      if (/[A-Za-z]/.test(c)) { end += 1; break; }
      return null;
  }
  return "end:" + end;
}
RES.push(getId('_'), getId('f'), String(getId('(')));

// break inside `if` inside a switch inside a while: breaks the switch only
var loop = [];
var i = 0;
while (i < 3) {
  switch (i) {
    default:
      if (true) { loop.push(i); break; }
      loop.push("x");
  }
  i += 1;
}
RES.push(loop.join(","));

// continue inside a switch continues the enclosing loop
var cont = [];
for (var j = 0; j < 4; j++) {
  switch (j) {
    case 1: continue;
    default: cont.push(j);
  }
}
RES.push(cont.join(","));

// labeled break from inside a switch exits the labeled loop
var lb = [];
outer: for (var a = 0; a < 3; a++) {
  for (var b = 0; b < 3; b++) {
    switch (b) {
      case 1:
        if (a === 1) { break outer; }
        break;
      default: lb.push(a + ":" + b);
    }
  }
}
RES.push(lb.join(","));

// labeled continue from inside a switch
var lc = [];
L: for (var x = 0; x < 3; x++) {
  switch (x) {
    default:
      if (x === 1) { continue L; }
      lc.push(x);
  }
}
RES.push(lc.join(","));

// `break Lbl` inside a switch exits the labeled block
var zb = [];
Lbl: {
  switch (1) {
    case 1:
      zb.push("in");
      if (true) { break Lbl; }
      zb.push("unreachable");
  }
  zb.push("after-switch");
}
zb.push("after-block");
RES.push(zb.join(","));

// nested switches: the inner break exits only the inner switch
var ns = [];
switch (1) {
  case 1:
    switch (2) {
      case 2:
        if (true) { break; }
        ns.push("bad-inner");
    }
    ns.push("outer-continues");
    break;
}
RES.push(ns.join(","));

// break inside try inside switch still runs finally
var tb = [];
switch (1) {
  case 1:
    try { break; } finally { tb.push("finally"); }
}
tb.push("after");
RES.push(tb.join(","));

// a directly labeled switch: `break L` from inside it exits the switch
var dls = [];
L2: switch (1) {
  case 1:
    dls.push("a");
    if (true) { break L2; }
    dls.push("bad");
}
dls.push("after");
RES.push(dls.join(","));

// `break L` from a loop nested inside a labeled switch exits the switch
var lsl = [];
M: switch (1) {
  case 1:
    for (var m = 0; m < 3; m++) {
      if (m === 1) { break M; }
      lsl.push(m);
    }
    lsl.push("bad");
}
RES.push(lsl.join(","));

// a plain break inside a loop inside a switch breaks the loop, not the switch
var lis = [];
switch (1) {
  case 1:
    for (var n = 0; n < 3; n++) {
      if (n === 1) { break; }
      lis.push(n);
    }
    lis.push("after-loop");
}
RES.push(lis.join(","));

RES.join(" | ")
