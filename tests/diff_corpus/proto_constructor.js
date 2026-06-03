// W2: plain constructor function + prototype method via new
function C(v){ this.v=v; } C.prototype.get=function(){ return this.v+2; }; (new C(10)).get()
