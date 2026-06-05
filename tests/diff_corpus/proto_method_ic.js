function C(){ this.v=1; } C.prototype.m=7;
var a=new C(); var b=new C();
var s=0; for(var i=0;i<4;i++){ s=s+a.m+b.m; }
s;
