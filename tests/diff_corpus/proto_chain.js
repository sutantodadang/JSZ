// Phase 3a: prototype chain via Object.create.
var proto = ({greet: function() { return "hello"; }});
var o = Object.create(proto);
o.name = "world";
o.greet() + " " + o.name
