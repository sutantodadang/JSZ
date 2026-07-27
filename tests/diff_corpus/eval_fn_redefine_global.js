// Wave 62c: a function declaration in eval reuses CreateGlobalFunctionBinding,
// so an existing configurable global property is redefined writable+enumerable.
(function(){ Object.defineProperty(globalThis, 'ffredef', { value: 1, writable: false, enumerable: false, configurable: true }); eval('function ffredef(){ return 9; }'); var d = Object.getOwnPropertyDescriptor(globalThis, 'ffredef'); return [d.writable, d.enumerable, d.configurable, ffredef()].join(','); })()
