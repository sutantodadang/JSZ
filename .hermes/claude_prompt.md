# Cross-Realm Implementation for JSZ

Implement production-level cross-realm support in JSZ so 14 `proto-from-ctor-realm` test262 tests pass. Worktree at `/home/sutanto/JSZ-wt-cross-realm` (branch `cross-realm`, forked from `feature/mi16-phase4`). Test262 symlinked.

## Plan Overview

The spec's `GetPrototypeFromConstructor` falls through to `GetFunctionRealm` when `new_target.prototype` is null. Every function must track its creating `Realm`. `$262.createRealm()` creates a real second Realm with its own TypedArray constructors.

### Files to modify
1. `src/bytecode/function.zig` — BcClosure: add `realm: ?*anyopaque`
2. `src/value/value.zig` — NativeFnEntry: add `realm: ?*anyopaque`
3. `src/runtime/realm.zig` — Realm: add `realm_id`, `ta_kind_prototypes[]`, `getFunctionRealm()`, `setValueRealm()`
4. `src/vm/isolate.zig` — IsolateImpl: add `realms` list
5. `src/vm/bc_vm.zig` — BcVm: add `realmAsOpaque()`; fix `protoFromNewTarget()`; set `.realm` on all BcClosure sites
6. `src/vm/ops/call.zig` — opNewClosure, opTailCall, opTailMethodCall: set `.realm`
7. `src/runtime/builtins/typed_array.zig` — `applyNewTargetProto()`: add GetFunctionRealm fallback; `nativeArrayBufferCtor`: realm-aware
8. `src/test/test262_runner.zig` — implement native `$262.createRealm`

---

## Phase 1: Add realm tracking to function types

### 1.1 BcClosure — `src/bytecode/function.zig` line 65

Add field after `obj: ?*anyopaque = null`:
```zig
/// Which Realm created this closure (for GetFunctionRealm). Opaque to avoid
/// circular import with runtime/realm.zig. Null = primary realm.
realm: ?*anyopaque = null,
```

### 1.2 NativeFnEntry — `src/value/value.zig` line 24

Add field after `name_deleted: bool = false`:
```zig
/// Which Realm created this native function. Null = primary realm.
realm: ?*anyopaque = null,
```

Also add a helper function:
```zig
pub fn setValueRealm(v: Value, realm: ?*anyopaque) void {
    var jsv = v.toPtr();
    switch (jsv.*) {
        .native_function => |*e| e.realm = realm,
        .bc_function => |*c| c.realm = realm,
        else => {},
    }
}
```

---

## Phase 2: Realm struct changes — `src/runtime/realm.zig`

### 2.1 Realm struct (line 2141)

Add fields:
```zig
realm_id: u32,
/// Per-kind TypedArray prototypes for GetPrototypeFromConstructor fallback.
/// Indexed by typed_array.TypedArrayKind enum (i8=0, u8=1, ..., f64=10).
ta_kind_prototypes: [11]?*JsObject = [_]?*JsObject{null} ** 11,
/// %TypedArray%.prototype (shared base of all TA prototype chains).
ta_shared_prototype: ?*JsObject = null,
/// DataView.prototype
dv_prototype: ?*JsObject = null,
```

### 2.2 Global realm counter
```zig
/// Monotonic counter for assigning realm_id across the process.
pub var next_realm_id: u32 = 1; // 0 reserved for the primary realm
```

### 2.3 In Realm.init() — set realm_id
```zig
realm_id = 0, // primary realm
// OR for secondary realms:
realm_id = @atomicRmw(&next_realm_id, .Add, 1, .Monotonic) - 1;
```

### 2.4 After TA builtins are registered in `ensureRealm` / `Realm.init` flow

After all 11 TypedArray constructors + %TypedArray% + DataView are registered and their prototypes available on the global env, populate `ta_kind_prototypes` and `ta_shared_prototype`.

The TA constructors are registered in the `registerAllBuiltins` function (or inline in `ensureRealm`). After registration:
```zig
// Populate TA kind prototypes
const typed_array_mod = @import("builtins/typed_array.zig");
const ta_intrinsic = typed_array_mod.active_typedarray_proto; // %TypedArray%.prototype
for (&realm.ta_kind_prototypes, typed_array_mod.TA_NAMES, 0..) |*slot, name, i| {
    if (global_env.lookup(name)) |ctor_val| {
        if (ctor_val.bits != 0 and ctor_val.unbox() == .object) {
            const ctor = ctor_val.toPtr().object;
            if (ctor.get("prototype")) |pv| {
                if (pv.bits != 0 and pv.unbox() == .object) {
                    slot.* = pv.toPtr().object;
                }
            }
        }
    } else |_| {}
}
realm.ta_shared_prototype = typed_array_mod.active_typedarray_proto;
realm.dv_prototype = typed_array_mod.active_dataview_proto;
```

The TA names array is:
```zig
const TA_NAMES = [_][]const u8{
    "Int8Array", "Uint8Array", "Uint8ClampedArray",
    "Int16Array", "Uint16Array", "Int32Array", "Uint32Array",
    "Float16Array", "Float32Array", "Float64Array",
    "BigInt64Array", "BigUint64Array",
};
```

### 2.5 `setValueRealm` for Realm

Add a helper in realm.zig:
```zig
/// Set the realm on a Value (for GetFunctionRealm). Uses opaque cast to avoid import cycles.
pub fn setRealmOnValue(v: Value, r: *Realm) void {
    val_mod.setValueRealm(v, @ptrCast(r));
}
```

### 2.6 GetFunctionRealm implementation

Add in `src/runtime/realm.zig`:
```zig
pub fn getFunctionRealm(v: Value) ?*Realm {
    const jsv = v.toPtr();
    switch (jsv.*) {
        .native_function => |*e| {
            return if (e.realm) |r| @ptrCast(@alignCast(r)) else null;
        },
        .bc_function => |*c| {
            return if (c.realm) |r| @ptrCast(@alignCast(r)) else null;
        },
        .object => |o| {
            // Proxy: follow [[ProxyTarget]]
            if (o.getSym(active_sym_proxy_target orelse return null)) |target_val| {
                if (target_val.bits != 0) return getFunctionRealm(target_val);
            }
            // Object with __call__: follow the callable to find its realm
            if (o.get("__call__")) |cv| {
                if (cv.bits != 0) return getFunctionRealm(cv);
            }
            return null;
        },
        else => return null,
    }
}
```

---

## Phase 3: Wire realm at all creation sites

### 3.1 opNewClosure — `src/vm/ops/call.zig` line 32

Add to the BcClosure literal:
```zig
.realm = self.realmAsOpaque(),
```

### 3.2 opTailCall (call.zig line ~150)

Same — the closure is `closure` used in the arm that creates a new frame. Add `.realm = self.realmAsOpaque()`.

### 3.3 opTailMethodCall (call.zig line ~299)

Same.

### 3.4 runMainBc eval path — `src/vm/bc_vm.zig` line 596

Add `.realm = self.realmAsOpaque()` to the BcClosure literal.

### 3.5 runMainBc module path — `src/vm/bc_vm.zig` line ~762

Add `.realm = self.realmAsOpaque()` to the BcCallFrame / BcClosure.

### 3.6 bcEvalInEnv — `src/vm/bc_vm.zig` line ~655

Add.

### 3.7 BcVm.realmAsOpaque helper

In BcVm struct `src/vm/bc_vm.zig`:
```zig
fn realmAsOpaque(self: *const BcVm) *anyopaque {
    return @ptrCast(self.realm);
}
```

### 3.8 Realm init — tag all native constructors

In or after `ensureRealm` (isolate.zig) or wherever all builtins are registered, call `setRealmOnValue(v, realm)` for every native function value created. This is done once per realm.

---

## Phase 4: Fix GetPrototypeFromConstructor

### 4.1 protoFromNewTarget — `src/vm/bc_vm.zig` line 395

Current:
```zig
fn protoFromNewTarget(self: *BcVm, new_target: Value, default_proto: ?*JsObject) anyerror!?*JsObject {
    if (new_target.bits == 0) return default_proto;
    const pv = try self.getProp(new_target, "prototype");
    if (pv.bits != 0 and pv.unbox() == .object) return pv.toPtr().object;
    return default_proto;
}
```

New:
```zig
fn protoFromNewTarget(self: *BcVm, new_target: Value, default_proto: ?*JsObject) anyerror!?*JsObject {
    if (new_target.bits == 0) return default_proto;
    const pv = try self.getProp(new_target, "prototype");
    if (pv.bits != 0 and pv.unbox() == .object) return pv.toPtr().object;
    // GetFunctionRealm fallback (ES 9.1.14 step 4)
    const realm_m = @import("../runtime/realm.zig");
    if (realm_m.getFunctionRealm(new_target)) |fr| {
        // For TypedArray, realm.ta_shared_prototype = %TypedArray%.prototype
        if (fr.ta_shared_prototype) |tap| return tap;
        // For DataView:
        if (fr.dv_prototype) |dvp| return dvp;
    }
    return default_proto;
}
```

### 4.2 applyNewTargetProto — `src/runtime/builtins/typed_array.zig` line 900

Current:
```zig
fn applyNewTargetProto(arena: std.mem.Allocator, this_obj: *JsObject) anyerror!void {
    const nt = realm_mod.pending_new_target;
    if (nt.bits == 0) return;
    realm_mod.pending_new_target = Value{}; // consume before the (throwing) Get
    const pv = try vmGet(arena, nt, "prototype");
    if (pv.bits != 0 and pv.unbox() == .object) this_obj.proto = pv.toPtr().object;
}
```

New:
```zig
fn applyNewTargetProto(arena: std.mem.Allocator, this_obj: *JsObject) anyerror!void {
    const nt = realm_mod.pending_new_target;
    if (nt.bits == 0) return;
    realm_mod.pending_new_target = Value{}; // consume before the (throwing) Get
    const pv = try vmGet(arena, nt, "prototype");
    if (pv.bits != 0 and pv.unbox() == .object) {
        this_obj.proto = pv.toPtr().object;
        return;
    }
    // GetFunctionRealm fallback: use realm's %TypedArrayPrototype%
    if (realm_mod.getFunctionRealm(nt)) |fr| {
        // Try per-kind prototype first
        const td = getTdData(this_obj) orelse return;
        const kind_idx = @intFromEnum(td.kind);
        if (kind_idx < fr.ta_kind_prototypes.len) {
            if (fr.ta_kind_prototypes[kind_idx]) |pp| {
                this_obj.proto = pp;
                return;
            }
        }
        // Fall through to shared %TypedArray%.prototype
        if (fr.ta_shared_prototype) |tap| {
            this_obj.proto = tap;
        }
    }
}
```

IMPORTANT: Need to import `realm_mod` at the top of typed_array.zig — it's already imported as `const realm_mod = @import("../../realm.zig");` somewhere in the file.

### 4.3 DataView applyNewTargetProto

Similarly, the DataView constructor path needs the realm fallback. Check where DataView calls applyNewTargetProto or equivalent.

---

## Phase 5: $262.createRealm in the runner

### 5.1 Add a native function `nativeJsxCreateRealm`

In `src/test/test262_runner.zig`, add a native function that:
1. Gets the current isolate from the active context
2. Creates a new Realm via `Realm.init(arena)`
3. Activates the heap (`realm.activateHeap(iso.heap)`)
4. Registers the realm in the isolate's realm list
5. Populates `ta_kind_prototypes` from the new realm's TA constructors
6. Returns a JS object `{global: ..., evalScript: ..., detachArrayBuffer: ..., ...}`

The native function needs access to the isolate. Use the `active_context` thread-local to find it:
```zig
const ctx = @import("../realm.zig").active_context orelse return error.JsException;
```

For getting back to the IsolateImpl, use the same pattern as other native functions:
```zig
const iso = ctx_ptr; // or similar
```

### 5.2 The returned realm object

Build a JS object with:
```zig
var result = JsObject.create(arena, realm.object_prototype);
// global: new realm's globalThis
// detachArrayBuffer: forward to existing detachArrayBuffer
// evalScript: compile + run in new realm's global env
// createRealm: recurse into this same function
// gc: noop
// IsHTMLDDA: ...
```

### 5.3 EvalScript for new realm

The `evalScript` property should be a native function that:
1. Takes a string `s`
2. Compiles and runs `s` as script code in the new realm's global env
3. Returns the result

Use `bcEvalInEnv` or create a similar mechanism.

### 5.4 Register __jszCreateRealm__ on globalThis

In `ensureRealm` or in the runner's prelude eval, add:
```zig
try realm.global_env.define("__jszCreateRealm__", try val_mod.makeNativeFunction(arena, nativeJsxCreateRealm));
```

### 5.5 Update DOLLAR262_PRELUDE

Replace the Proxy-based `createRealm` with:
```js
createRealm: function() { return __jszCreateRealm__(); },
```

---

## Build & Verify

```bash
cd /home/sutanto/JSZ-wt-cross-realm
zig build -Doptimize=ReleaseFast 2>&1
```

Then run:
```bash
# Cross-realm TA tests
./zig-out/bin/test262-runner --full --fail-on-flips --filter "proto-from-ctor-realm"

# Full MI15 sweep
./zig-out/bin/test262-runner --full --fail-on-flips --filter "built-ins/TypedArray"
./zig-out/bin/test262-runner --full --fail-on-flips --filter "ArrayBuffer"
./zig-out/bin/test262-runner --full --fail-on-flips --filter "DataView"
./zig-out/bin/test262-runner --full --fail-on-flips --filter "typedarray"
./zig-out/bin/test262-runner --full --fail-on-flips --filter "staging/sm/TypedArray"

# Unit tests
zig build test 2>&1
```

## Key constraints
- Use `?*anyopaque` for realm pointers to avoid circular imports between function.zig and realm.zig
- Every BcClosure creation site must set `.realm = self.realmAsOpaque()`
- Every makeNativeFunction call during realm init must call `setRealmOnValue`
- The `ta_kind_prototypes` array must be indexed to match TypedArrayKind enum order
- Don't break unit tests or existing test262 conformance

## Note on proxy target symbol
The proxy target symbol is stored in `realm_mod.active_sym_proxy_target` as a `?Value`. Use `@import("../../realm.zig").active_sym_proxy_target` to access it in getFunctionRealm. The proxy target is set on the handler object, not the proxy directly — need to read it from the proxy object's own properties via the private symbol key.

Actually for getFunctionRealm on proxy objects: the proxy's [[ProxyTarget]] is NOT accessible from user code. But in JSZ, it's stored as a private symbol property on the proxy object itself using `active_sym_proxy_target`. So:
```zig
if (o.internal_kind == .proxy) {
    if (o.getSym(active_sym_proxy_target orelse return null)) |target_val| {
        if (target_val.bits != 0) return getFunctionRealm(target_val);
    }
}
```
