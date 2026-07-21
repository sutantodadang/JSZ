var g = new Intl.Segmenter("en", { granularity: "grapheme" });
var w = new Intl.Segmenter("en", { granularity: "word" });
var out = [];
out.push([...g.segment("áb\r\n")].map(function (v) { return v.segment.length + ":" + v.index; }).join(","));
out.push([...w.segment("Hello world! 1.23, a,b")].map(function (v) { return v.segment + "/" + v.isWordLike; }).join("|"));
out.push(JSON.stringify(new Intl.Segmenter("EN-us").resolvedOptions()));
out.push(Object.getOwnPropertyNames([...w.segment("hi")][0]).join(","));
out.push(String(w.segment("abc").containing(1).segment));
out.join("\n");
