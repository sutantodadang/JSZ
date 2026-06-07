// Phase 13: Intl.Collator (same-case ASCII — matches byte order across locales).
var c = new Intl.Collator("en");
[c.compare("apple", "banana"), c.compare("banana", "apple"), c.compare("apple", "apple"), typeof Intl].join(",")
