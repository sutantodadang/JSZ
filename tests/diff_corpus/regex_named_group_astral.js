// Wave 62a: named-capture group names with astral (surrogate-pair) identifiers,
// and \u{...} identifier escapes producing the same key as the literal char.
var out = [];
// Literal astral ID_Start group name.
out.push("brown".match(/(?<𝓑𝓻𝓸𝔀𝓷>brown)/u).groups.𝓑𝓻𝓸𝔀𝓷); // "brown"
// \u{...} escapes in the property-access identifier resolve to the same key.
out.push("brown".match(/(?<𝓑𝓻𝓸𝔀𝓷>brown)/u).groups.\u{1d4d1}\u{1d4fb}\u{1d4f8}\u{1d500}\u{1d4f7}); // "brown"
// Astral \u escape in an ordinary identifier equals its literal spelling.
var \u{1d4d1} = "ok";
out.push(𝓑); // "ok"
out.join(",");
