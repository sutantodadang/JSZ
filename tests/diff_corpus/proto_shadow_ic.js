var p=({x:1}); var o=Object.create(p);
var a=o.x; o.x=99; var b=o.x; p.x=50; var c=o.x;
""+a+","+b+","+c;
