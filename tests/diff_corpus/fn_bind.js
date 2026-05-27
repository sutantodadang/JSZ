function greet(g) { return g + " " + this.name; }
var f = greet.bind({ name: "JS" }, "Hello");
f()
