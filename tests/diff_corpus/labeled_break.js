var count = 0;
outer: for (var i = 0; i < 5; i++) {
  for (var j = 0; j < 5; j++) {
    if (j === 2) break outer;
    count += 1;
  }
}
count
