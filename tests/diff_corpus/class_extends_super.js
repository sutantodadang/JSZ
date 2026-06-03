// W2: class extends + super method + super constructor
class A{ constructor(x){ this.x=x; } m(){ return this.x; } } class B extends A{ constructor(){ super(5); } m(){ return super.m()+1; } } (new B()).m()
