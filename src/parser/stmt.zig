// SPDX-License-Identifier: Apache-2.0
//! Statement-parsing free functions for the jsz ES parser.
//! Called from Parser via thin stubs in parser.zig.
//! All functions receive `p: *Parser` and call back through `p.*` for
//! cross-category parse calls (expression, class, primitives).
const std = @import("std");
const parser_file = @import("./parser.zig");
const Parser = parser_file.Parser;
const ast = @import("./ast.zig");
const Node = ast.Node;
const NodeKind = ast.NodeKind;
const expr_mod = @import("./expr.zig");

// ---------------------------------------------------------------- statements ---

/// M16 Phase 5: parse an import-attributes `with { ... }` or `assert { ... }`
/// clause that may follow a module specifier in import/export declarations.
/// The clause is consumed; the value of a `type` attribute (e.g. `'json'`,
/// `'text'`) is returned so the loader can route the dependency to the right
/// synthetic-module factory (JSON / text). All other attributes are ignored.
fn skipImportAttributes(p: *Parser) ?[]const u8 {
    // `with` is a reserved-word token (kw_with); `assert` is a contextual kw.
    // Only treat it as an attributes clause when a `{` immediately follows. An
    // import without a trailing `;` (ASI) may be followed by a statement whose
    // leading token happens to be `assert`/`with` — e.g.
    //   import {"*" as y} from "./m.js"
    //   assert.sameValue(y, "ok");
    // Consuming the bare `assert` here would swallow the next statement's leading
    // identifier and leave the parser stranded on its `.` (`unexpected token`).
    const is_with = p.current.kind == .kw_with;
    const is_assert = p.current.kind == .identifier and std.mem.eql(u8, p.current.value_str, "assert");
    if (!is_with and !is_assert) return null;
    if (p.peekNext().kind != .left_brace) return null;
    _ = p.advance(); // consume `with` / `assert`
    // Expect `{ ... }` — consume the braced block, tolerating nested braces and
    // string literals (attribute values are string literals).
    if (!p.match(.left_brace)) {
        // Not a braces block — nothing to consume (allow `with` as a no-op).
        return null;
    }
    var type_value: ?[]const u8 = null;
    // State machine to capture `type : <string>` at the top brace level.
    const St = enum { none, key, colon };
    var st: St = .none;
    var depth: u32 = 1;
    while (depth > 0 and !p.check(.eof) and !p.had_error) {
        if (p.check(.left_brace)) {
            depth += 1;
            st = .none;
            _ = p.advance();
        } else if (p.check(.right_brace)) {
            depth -= 1;
            _ = p.advance();
        } else if (depth == 1 and st == .colon and p.check(.string)) {
            type_value = p.current.value_str;
            st = .none;
            _ = p.advance();
        } else if (depth == 1 and st == .key and p.check(.colon)) {
            st = .colon;
            _ = p.advance();
        } else if (depth == 1 and st == .none and
            ((p.current.kind == .identifier or p.current.kind == .string) and
                std.mem.eql(u8, p.current.value_str, "type")))
        {
            st = .key;
            _ = p.advance();
        } else {
            if (p.check(.comma)) st = .none;
            _ = p.advance(); // skip any other token (keys, colons, commas)
        }
    }
    return type_value;
}

/// Append the module-type attribute to a specifier as `<spec>\x00<type>` so the
/// loader keys typed (JSON/text) modules distinctly from a JS import of the same
/// path (module records are keyed by (specifier, type) per spec). Returns the
/// bare specifier when there is no type attribute.
fn typedSpecifier(p: *Parser, modname: []const u8, type_attr: ?[]const u8) []const u8 {
    const ty = type_attr orelse return modname;
    if (ty.len == 0) return modname;
    return std.fmt.allocPrint(p.arena, "{s}\x00{s}", .{ modname, ty }) catch modname;
}

pub fn parseImportDecl(p: *Parser) ?*Node {
    const start = p.current.start;
    // M16 Phase 3: `import(` (dynamic import) and `import.meta` are expressions,
    // not import declarations — route them through expression-statement parsing.
    const nxt = p.peekNext().kind;
    if (nxt == .left_paren or nxt == .dot) {
        return p.parseExprStmt();
    }
    // An `import` *declaration* is only valid in module code; in eval/script
    // code it is an early SyntaxError (dynamic `import(...)` above is allowed).
    if (p.eval_code) return p.fail("import declarations may only appear at the top level of a module");
    _ = p.advance(); // import

    // import "mod";  (side-effect only)
    if (p.current.kind == .string) {
        const modname = p.current.value_str;
        _ = p.advance();
        const type_attr = skipImportAttributes(p); // `with { ... }` / `assert { ... }`
        p.consumeSemicolon();
        const req = p.mkRequire(typedSpecifier(p, modname, type_attr)) orelse return null;
        const stmt = p.makeNode(.expr_stmt, start, p.current.start, .{ .expr_stmt = req }) orelse return null;
        // M16 Phase 5: hoist side-effect imports to the bundle hoist point so
        // require() runs after __modules__ is initialised but before entry assertions.
        // When hoist_no_se is set (sync entries with function exports), side-effect
        // imports are NOT hoisted — they stay in the IIFE body and execute AFTER the
        // pre-hoist `exports.fn = fn` assignments at the top of the IIFE.  This lets
        // circular deps that import the entry's function exports find them callable.
        if (p.hoist_point_seen and !p.hoist_no_se) {
            p.hoisted_import_stmts.append(p.arena, stmt) catch {};
            return p.makeNode(.empty_stmt, start, p.current.start, .{ .empty_stmt = {} });
        }
        return stmt;
    }

    // import source X from "spec";  (source-phase import — ES proposal).
    // Grammar: `import source ImportedBinding FromClause`. We detect it as
    // `source <ident> ...` where the next token is an identifier that is not the
    // `from` keyword (which would make this an ordinary default import of a
    // binding literally named `source`). The binding is bound to the host's
    // module-source object (`__moduleSource__(spec)`), an immutable binding.
    if (p.current.kind == .identifier and std.mem.eql(u8, p.current.value_str, "source")) {
        const nn = p.peekNext();
        // `from` after `source` is ambiguous: `import source from 'mod'` is an
        // ordinary default import of a binding named `source`, while
        // `import source from from 'mod'` binds the *source* to `from`. The
        // token after it decides — a string ends the first form, a second `from`
        // opens the FromClause of the second.
        const nn_is_binding = nn.kind == .identifier and
            (!std.mem.eql(u8, nn.value_str, "from") or p.peekNext2().kind != .string);
        if (nn_is_binding) {
            _ = p.advance(); // consume `source`
            const bind_tok = p.expect(.identifier) orelse return null;
            if (!p.matchContextual("from")) return p.fail("expected 'from' in import declaration");
            const spec_tok = p.expect(.string) orelse return null;
            _ = skipImportAttributes(p);
            p.consumeSemicolon();
            const arg = p.makeNode(.string_literal, start, p.current.start, .{ .string_literal = spec_tok.value_str }) orelse return null;
            const call = p.mkCall1("__moduleSource__", arg) orelse return null;
            const stmt = p.mkVar(bind_tok.value_str, call) orelse return null;
            if (p.hoist_point_seen) {
                p.hoisted_import_stmts.append(p.arena, stmt) catch {};
                return p.makeNode(.empty_stmt, start, p.current.start, .{ .empty_stmt = {} });
            }
            return stmt;
        }
    }

    // `import defer * as ns from 'm'` — deferred namespace import (ES import-defer
    // proposal). `defer` is the keyword ONLY when immediately followed by `*`;
    // `import defer from 'm'` instead imports a default binding literally named
    // `defer`, so it falls through to ordinary import-clause parsing.
    if (p.current.kind == .identifier and std.mem.eql(u8, p.current.value_str, "defer")) {
        const nn = p.peekNext();
        if (nn.kind == .star) {
            _ = p.advance(); // consume `defer`
            _ = p.advance(); // consume `*`
            if (!p.matchContextual("as")) return p.fail("expected 'as' after import defer *");
            const t = p.expect(.identifier) orelse return null;
            const dns_name = t.value_str;
            if (!p.matchContextual("from")) return p.fail("expected 'from' in import declaration");
            const dmodtok = p.expect(.string) orelse return null;
            const dtype = skipImportAttributes(p); // `with { ... }` / `assert { ... }`
            p.consumeSemicolon();
            const arg = p.makeNode(.string_literal, start, p.current.start, .{
                .string_literal = typedSpecifier(p, dmodtok.value_str, dtype),
            }) orelse return null;
            const call = p.mkCall1("__importDefer__", arg) orelse return null;
            const stmt = p.mkVar(dns_name, call) orelse return null;
            // Hoist like ordinary imports so the deferred namespace binding exists
            // before the entry's assertions run (it does not evaluate the module).
            if (p.hoist_point_seen) {
                p.hoisted_import_stmts.append(p.arena, stmt) catch {};
                return p.makeNode(.empty_stmt, start, p.current.start, .{ .empty_stmt = {} });
            }
            return stmt;
        } else if (!(nn.kind == .identifier and std.mem.eql(u8, nn.value_str, "from"))) {
            // `import defer x`, `import defer { … }`, `import defer as ns`, etc.
            // are all SyntaxErrors: `defer` may only precede a `* as` namespace.
            return p.fail("`import defer` must be `import defer * as <name> from`");
        }
        // else: `import defer from 'm'` — `defer` is an ordinary default binding.
    }

    var default_name: ?[]const u8 = null;
    var ns_name: ?[]const u8 = null;
    const Named = struct { imp: []const u8, local: []const u8 };
    var named = std.ArrayList(Named){};

    if (p.current.kind == .identifier) {
        default_name = p.current.value_str;
        _ = p.advance();
        _ = p.match(.comma);
    }
    if (p.match(.star)) {
        if (!p.matchContextual("as")) return p.fail("expected 'as' after import *");
        const t = p.expect(.identifier) orelse return null;
        ns_name = t.value_str;
    } else if (p.match(.left_brace)) {
        while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
            // Import name may be identifier, keyword, or string literal (ES2022).
            const imp = if (p.check(.string)) p.advance() else (p.expectIdentifierName() orelse return null);
            var local = imp.value_str;
            if (p.matchContextual("as")) {
                const lt = p.expect(.identifier) orelse return null;
                local = lt.value_str;
            }
            named.append(p.arena, .{ .imp = imp.value_str, .local = local }) catch return null;
            if (!p.match(.comma)) break;
        }
        _ = p.expect(.right_brace) orelse return null;
    }
    if (!p.matchContextual("from")) return p.fail("expected 'from' in import declaration");
    const modtok = p.expect(.string) orelse return null;
    const modname = modtok.value_str;
    const type_attr = skipImportAttributes(p); // `with { ... }` / `assert { ... }`
    p.consumeSemicolon();

    // A JSON module exposes only a `default` export (ES "json-modules"): an
    // `import { name }` of any other binding is a resolution-phase SyntaxError.
    if (type_attr) |ty| {
        if (std.mem.eql(u8, ty, "json")) {
            for (named.items) |nb| {
                if (!std.mem.eql(u8, nb.imp, "default"))
                    return p.fail("JSON module has no export named other than 'default'");
            }
        }
    }

    const tmp = std.fmt.allocPrint(p.arena, "__esm_{d}", .{start}) catch return null;
    var out = std.ArrayList(*Node){};
    const req = p.mkRequire(typedSpecifier(p, modname, type_attr)) orelse return null;
    // M16 Phase 5: wrap in namespace so named/default imports get live binding,
    // TDZ detection, and assignment-rejection semantics.
    const ns_req = p.mkCall1("__makeNamespace__", req) orelse return null;
    out.append(p.arena, p.mkVar(tmp, ns_req) orelse return null) catch return null;
    if (default_name) |d| {
        const m = p.mkMember(p.mkIdent(tmp) orelse return null, "default") orelse return null;
        out.append(p.arena, p.mkVar(d, m) orelse return null) catch return null;
        p.live_imports.append(p.arena, .{ .name = d, .ns = tmp, .prop = "default" }) catch return null;
    }
    if (ns_name) |n| {
        // `import * as n` → n is a Module Namespace exotic object wrapping the
        // imported module's live exports (ES §10.4.6), not the exports itself.
        const ns_val = p.mkCall1("__makeNamespace__", p.mkIdent(tmp) orelse return null) orelse return null;
        out.append(p.arena, p.mkVar(n, ns_val) orelse return null) catch return null;
        // Treat n as a live import pointing to the namespace's "__ns__" property:
        // reads of `n` return the namespace itself (via __ns__ [[Get]]) and
        // writes (`n = x`) call namespace [[Set]] which throws TypeError in strict mode.
        p.live_imports.append(p.arena, .{ .name = n, .ns = tmp, .prop = "__ns__" }) catch return null;
    }
    for (named.items) |nb| {
        const m = p.mkMember(p.mkIdent(tmp) orelse return null, nb.imp) orelse return null;
        out.append(p.arena, p.mkVar(nb.local, m) orelse return null) catch return null;
        p.live_imports.append(p.arena, .{ .name = nb.local, .ns = tmp, .prop = nb.imp }) catch return null;
    }
    // M16 Phase 5: hoist import stmts to the bundle hoist point so require() runs
    // after __modules__ / __initExports__ are set up but before entry assertions.
    // Guard on hoist_point_seen so unit tests (no bundle marker) keep source order.
    if (p.hoist_point_seen) {
        for (out.items) |s| {
            p.hoisted_import_stmts.append(p.arena, s) catch {};
        }
        return p.makeNode(.empty_stmt, start, p.current.start, .{ .empty_stmt = {} });
    }
    return p.finishMulti(out.items);
}

pub fn parseExportDecl(p: *Parser) ?*Node {
    const start = p.current.start;
    // An `export` declaration is only valid in module code; in eval/script code
    // it is an early SyntaxError (sec-scripts §A.5).
    if (p.eval_code) return p.fail("export declarations may only appear at the top level of a module");
    _ = p.advance(); // export

    // export default <assignmentExpr>;
    if (p.match(.kw_default)) {
        // export default function [*] [Name]() {} — detect as function declaration.
        const is_async_kw = p.currentIsAsyncKw() and p.peekNext().kind == .kw_function and !p.peekNext().line_terminator_before;
        if (p.current.kind == .kw_function or is_async_kw) {
            const fn_start = p.current.start;
            const is_async = is_async_kw;
            if (is_async) _ = p.advance(); // consume 'async'
            _ = p.advance(); // consume 'function'
            const is_gen = p.match(.star);
            if (p.current.kind == .identifier) {
                // Named: export default function F(){} → function_decl F + exports.default = F
                const fn_name = p.current.value_str;
                _ = p.advance();
                const parsed_params = p.parseFunctionParams() orelse return null;
                const prev_gen = p.in_generator_function;
                p.in_generator_function = is_gen;
                const body = p.parseFunctionBody() orelse {
                    p.in_generator_function = prev_gen;
                    return null;
                };
                p.in_generator_function = prev_gen;
                if (!parser_file.checkStrictDirectiveSimpleParams(p, parsed_params.non_simple, body)) return null;
                const is_strict = parser_file.hasUseStrict(body);
                const fn_decl = p.makeNode(.function_decl, fn_start, p.current.start, .{
                    .function_decl = .{
                        .name = fn_name,
                        .params = parsed_params.params,
                        .param_defaults = parsed_params.param_defaults,
                        .expected_argc = parsed_params.expected_argc,
                        .rest_param = parsed_params.rest_param,
                        .body = body,
                        .is_generator = is_gen,
                        .is_async = is_async,
                        .is_strict = is_strict,
                    },
                }) orelse return null;
                const assign = if (p.hoist_point_seen or p.fn_nesting_depth > 0)
                    p.mkLiveLocalExport("default", fn_name) orelse return null
                else
                    p.mkExportAssign("default", p.mkIdent(fn_name) orelse return null) orelse return null;
                var out2 = std.ArrayList(*Node){};
                out2.append(p.arena, fn_decl) catch return null;
                out2.append(p.arena, assign) catch return null;
                return p.finishMulti(out2.items);
            } else {
                // Anonymous: export default function(){} or function*(){}
                // Use a hoistable function declaration with an internal sentinel name so
                // self-importing cycles see the default export before the body runs.
                // The sentinel is translated to "default" by the fn.name getter at runtime.
                const parsed_params = p.parseFunctionParams() orelse return null;
                const prev_gen = p.in_generator_function;
                p.in_generator_function = is_gen;
                const body = p.parseFunctionBody() orelse {
                    p.in_generator_function = prev_gen;
                    return null;
                };
                p.in_generator_function = prev_gen;
                if (!parser_file.checkStrictDirectiveSimpleParams(p, parsed_params.non_simple, body)) return null;
                const is_strict = parser_file.hasUseStrict(body);
                const internal_name = if (is_gen) "__esm_dflt_gen__" else "__esm_dflt_fn__";
                const fn_decl = p.makeNode(.function_decl, fn_start, p.current.start, .{
                    .function_decl = .{
                        .name = internal_name,
                        .params = parsed_params.params,
                        .param_defaults = parsed_params.param_defaults,
                        .expected_argc = parsed_params.expected_argc,
                        .rest_param = parsed_params.rest_param,
                        .body = body,
                        .is_generator = is_gen,
                        .is_async = is_async,
                        .is_strict = is_strict,
                    },
                }) orelse return null;
                p.consumeSemicolon();
                const ident = p.mkIdent(internal_name) orelse return null;
                const assign = p.mkExportAssign("default", ident) orelse return null;
                var out = std.ArrayList(*Node){};
                out.append(p.arena, fn_decl) catch return null;
                out.append(p.arena, assign) catch return null;
                return p.finishMulti(out.items);
            }
        }
        // Set name hint for anonymous class / other anonymous expression.
        p.export_default_name_hint = "default";
        const expr = p.parseAssignmentExpr() orelse return null;
        p.export_default_name_hint = null;
        p.consumeSemicolon();
        return p.mkExportAssign("default", expr);
    }

    // export * [as ns] from "mod"  — re-export all (or as namespace).
    if (p.match(.star)) {
        if (p.matchContextual("as")) {
            // export * as ns from "mod" → exports.ns = __makeNamespace__(require("mod"))
            // ns may be an identifier, keyword, or string literal (ES2022).
            const ns_tok = if (p.check(.string)) p.advance() else (p.expectIdentifierName() orelse return null);
            if (!p.matchContextual("from")) return p.fail("expected 'from' after export * as");
            const mod_tok = p.expect(.string) orelse return null;
            _ = skipImportAttributes(p);
            p.consumeSemicolon();
            const req = p.mkRequire(mod_tok.value_str) orelse return null;
            const ns_val = p.mkCall1("__makeNamespace__", req) orelse return null;
            const stmt = p.mkExportAssign(ns_tok.value_str, ns_val);
            // Hoist in bundle mode so source-order eval matches spec (import and
            // export-from declarations all run before the module body).
            if (p.hoist_point_seen) {
                if (stmt) |s| p.hoisted_import_stmts.append(p.arena, s) catch {};
                return p.makeNode(.empty_stmt, start, start, .{ .empty_stmt = {} });
            }
            return stmt;
        } else {
            // export * from "mod" → __exportStar__(exports, require("mod"))
            // __exportStar__ copies all properties except 'default' (ES spec §2.2.2.3).
            if (!p.matchContextual("from")) return p.fail("expected 'from' after export *");
            const mod_tok = p.expect(.string) orelse return null;
            _ = skipImportAttributes(p);
            p.consumeSemicolon();
            const req = p.mkRequire(mod_tok.value_str) orelse return null;
            const callee = p.mkIdent("__exportStar__") orelse return null;
            const exports_id = p.mkIdent("exports") orelse return null;
            var aa = std.ArrayList(*Node){};
            aa.append(p.arena, exports_id) catch return null;
            aa.append(p.arena, req) catch return null;
            const call = p.makeNode(.call_expr, start, start, .{
                .call_expr = .{ .callee = callee, .args = aa.items },
            }) orelse return null;
            const stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = call });
            // Hoist in bundle mode.
            if (p.hoist_point_seen) {
                if (stmt) |s| p.hoisted_import_stmts.append(p.arena, s) catch {};
                return p.makeNode(.empty_stmt, start, start, .{ .empty_stmt = {} });
            }
            return stmt;
        }
    }

    // export { a, b as c } [from "mod"];
    // Specifier names may be identifiers, keywords, or string literals (ES2022).
    if (p.match(.left_brace)) {
        const Spec = struct { local: []const u8, exported: []const u8 };
        var specs = std.ArrayList(Spec){};
        while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
            const l = if (p.check(.string)) p.advance() else (p.expectIdentifierName() orelse return null);
            var exported = l.value_str;
            if (p.matchContextual("as")) {
                const e = if (p.check(.string)) p.advance() else (p.expectIdentifierName() orelse return null);
                exported = e.value_str;
            }
            specs.append(p.arena, .{ .local = l.value_str, .exported = exported }) catch return null;
            if (!p.match(.comma)) break;
        }
        _ = p.expect(.right_brace) orelse return null;

        var tmp: ?[]const u8 = null;
        var out = std.ArrayList(*Node){};
        if (p.matchContextual("from")) {
            const modtok = p.expect(.string) orelse return null;
            _ = skipImportAttributes(p);
            tmp = std.fmt.allocPrint(p.arena, "__esm_{d}", .{start}) catch return null;
            const req = p.mkRequire(modtok.value_str) orelse return null;
            out.append(p.arena, p.mkVar(tmp.?, req) orelse return null) catch return null;
        }
        p.consumeSemicolon();
        for (specs.items) |sp| {
            if (tmp) |t| {
                // Re-export (`export { X as Y } from './mod'`):
                // Use a live getter (via __liveReexport__) both in bundle entry
                // mode (hoist_point_seen) AND in dep factory bodies
                // (fn_nesting_depth > 0) — live getters fix circular dependency
                // cycles where the source module hasn't fully evaluated yet.
                // Standalone mode (no bundle marker, no nesting) uses a snapshot.
                if (p.hoist_point_seen or p.fn_nesting_depth > 0) {
                    const src = p.mkMember(p.mkIdent(t) orelse return null, sp.local) orelse return null;
                    out.append(p.arena, p.mkExportGetter(sp.exported, src) orelse return null) catch return null;
                } else {
                    const value = (p.mkMember(p.mkIdent(t) orelse return null, sp.local) orelse return null);
                    out.append(p.arena, p.mkExportAssign(sp.exported, value) orelse return null) catch return null;
                }
            } else {
                // Local export (`export { X }` or `export { X as Y }`): snapshot
                const value = (p.mkIdent(sp.local) orelse return null);
                out.append(p.arena, p.mkExportAssign(sp.exported, value) orelse return null) catch return null;
                if (std.mem.eql(u8, sp.local, sp.exported)) {
                    p.live_exports.append(p.arena, sp.local) catch {};
                } else {
                    p.live_export_aliases.append(p.arena, .{ .local = sp.local, .exported = sp.exported }) catch {};
                }
            }
        }
        // Hoist ONLY empty-binding re-exports (`export {} from 'mod'`) in bundle mode:
        // these are pure side-effect imports and must run before the module body to
        // match spec evaluation order. Non-empty re-exports (`export { a } from`) are
        // left in place because they snapshot live values that may not be initialized yet.
        if (p.hoist_point_seen and tmp != null and specs.items.len == 0) {
            for (out.items) |s| p.hoisted_import_stmts.append(p.arena, s) catch {};
            return p.makeNode(.empty_stmt, start, p.current.start, .{ .empty_stmt = {} });
        }
        return p.finishMulti(out.items);
    }

    // export <declaration>: var/let/const/function/class
    const decl = p.parseStatement() orelse return null;
    var names = std.ArrayList([]const u8){};
    p.collectDeclNames(decl, &names);
    // A multi-declarator `export let a, b, c;` lowers to a `block_stmt` wrapping
    // the individual var_decls. Left as a block it would (1) block-scope the
    // bindings away from the rest of the module body and (2) hide the var_decls
    // from `makeExportLive`, which only scans top-level statements — so neither
    // the live-binding rewrite nor importers would observe later assignments.
    // Flatten it: keep the first declarator as the returned statement and splice
    // the rest into the module's statement stream (before the export snapshots).
    var result_decl = decl;
    if (decl.kind == .block_stmt) {
        const body = decl.data.block_stmt.body;
        if (body.len > 0) {
            result_decl = body[0];
            for (body[1..]) |d| {
                p.extra_stmts.append(p.arena, d) catch {
                    p.had_error = true;
                    return null;
                };
            }
        }
    }
    for (names.items) |nm| {
        const a = p.mkExportAssign(nm, p.mkIdent(nm) orelse return null) orelse return null;
        p.extra_stmts.append(p.arena, a) catch {
            p.had_error = true;
            return null;
        };
    }
    // var exports are always made live (no TDZ, fine in all modes).
    // let/const exports are made live only when __initExports__ will pre-set TDZ
    // markers on the exports object: bundle dep factories (fn_nesting_depth > 0),
    // bundle entry (hoist_point_seen), or script mode (unit tests, !is_module).
    // Standalone evalModule (no bundle) keeps env-level TDZ for let/const — the
    // GET_GLOBAL_OPT handler already throws for TemporalDeadZone.
    // Register live exports for every declarator name, including each name of a
    // multi-declarator `export let a, b, c;` (which lowers to a block_stmt).
    p.registerDeclLiveExports(decl);
    return result_decl;
}

/// Detect a `using <BindingIdentifier>` declaration at the current position.
/// `using` is contextual: it is only a declaration when an identifier follows on
/// the same line (no ASI break). `using\nx` is two statements; `using = 1`,
/// `using.x`, `using(...)` are ordinary expressions.
pub fn atUsingDecl(p: *Parser) bool {
    if (p.current.kind != .identifier or !std.mem.eql(u8, p.current.value_str, "using")) return false;
    const nx = p.peekNext();
    if (nx.line_terminator_before) return false;
    return nx.kind == .identifier or nx.kind == .kw_of;
}

/// Detect an `await using <BindingIdentifier>` declaration. Only valid in an
/// async context — module top level or inside a function body (at script top
/// level `await` is an ordinary identifier, so this stays an expression).
pub fn atAwaitUsingDecl(p: *Parser) bool {
    if (p.current.kind != .identifier or !std.mem.eql(u8, p.current.value_str, "await")) return false;
    if (!(p.is_module or p.fn_nesting_depth > 0)) return false;
    const nx = p.peekNext();
    if (nx.line_terminator_before or nx.kind != .identifier or
        !std.mem.eql(u8, nx.value_str, "using")) return false;
    const nx2 = p.peekNext2();
    if (nx2.line_terminator_before) return false;
    return nx2.kind == .identifier or nx2.kind == .kw_of;
}

/// Parse a `using` / `await using` declaration statement (explicit resource
/// management). Lowered to `let` bindings: scoping, TDZ and per-iteration
/// freshness match `let`. Each declarator must be a BindingIdentifier with a
/// required initializer (UsingDeclaration grammar §13.x).
pub fn parseUsingDeclStmt(p: *Parser, is_await: bool) ?*Node {
    const start = p.current.start;
    if (is_await) _ = p.advance(); // consume `await`
    _ = p.advance(); // consume `using`
    var decls = std.ArrayList(*Node){};
    while (true) {
        const d_start = p.current.start;
        if (p.check(.left_bracket) or p.check(.left_brace)) {
            return p.fail("using declaration requires a binding identifier");
        }
        const name_tok = if (p.check(.kw_of)) p.advance() else (p.expect(.identifier) orelse return null);
        const name: []const u8 = if (name_tok.kind == .kw_of) "of" else name_tok.value_str;
        var init_node: ?*Node = null;
        if (p.match(.eq)) {
            init_node = p.parseAssignmentExpr();
        } else {
            return p.fail("using declaration requires an initializer");
        }
        const d = p.makeNode(.var_decl, d_start, p.current.start, .{
            .var_decl = .{ .kind = .let, .name = name, .init = init_node, .using_kind = if (is_await) .await_using_ else .using_ },
        }) orelse return null;
        decls.append(p.arena, d) catch {
            p.had_error = true;
            return null;
        };
        if (!p.match(.comma)) break;
    }
    p.consumeSemicolon();
    if (decls.items.len == 1) return decls.items[0];
    // Transparent container: these using bindings belong to the enclosing scope.
    return p.makeNode(.block_stmt, start, p.current.start, .{ .block_stmt = .{ .body = decls.items, .lexical_scope = false } });
}

pub fn parseStatement(p: *Parser) ?*Node {
    if (p.had_error) return null;
    // A statement can begin with a RegularExpressionLiteral, but the lexer read
    // `/` as division because the token before it was a `}` (see
    // Parser.relexCurrentAsRegex). Statement position settles it: `{}/re/`,
    // `class A{}/re/` and `function f(){}/re/` are a declaration then a regex.
    p.relexCurrentAsRegex();
    // Explicit resource management: `using x = ...` / `await using x = ...`
    // declarations. Only recognized when a binding identifier follows (see
    // atUsingDecl/atAwaitUsingDecl); otherwise `using`/`await` stay ordinary.
    if (atAwaitUsingDecl(p)) return parseUsingDeclStmt(p, true);
    if (atUsingDecl(p)) return parseUsingDeclStmt(p, false);
    // Phase 8: a statement starting with `await` is an await-expression statement,
    // not a label/identifier — route to expression parsing (which desugars await).
    // In module mode, `await` is always a keyword. In script mode, `await` is an
    // identifier unless followed by a valid operand (for top-level await support).
    if (p.current.kind == .identifier and std.mem.eql(u8, p.current.value_str, "await") and
        (p.is_module or expr_mod.isAwaitOperandStart(p.peekNext().kind))) {
        return p.parseExprStmt();
    }
    // W2-async: `async function foo() {}` declaration. `async` is contextual
    // (a plain identifier); only treat it as a keyword when `function`
    // immediately follows on the same line.
    if (p.currentIsAsyncKw() and p.peekNext().kind == .kw_function and !p.peekNext().line_terminator_before) {
        p.async_kw_start = p.current.start; // remember `async` position for the source span
        _ = p.advance(); // consume `async`
        return p.parseFunctionDecl(true);
    }
    // `yield` is a valid label in sloppy-mode code outside a generator (it is
    // only a reserved word in strict/generator context). It lexes as `kw_yield`,
    // so the identifier-label path below misses it.
    if (p.check(.kw_yield) and !p.strict and !p.in_generator_function and p.peekNext().kind == .colon) {
        const saved = p.current;
        _ = p.advance(); // `yield`
        _ = p.advance(); // `:`
        const body = p.parseStatement() orelse return null;
        return p.makeNode(.labeled_stmt, saved.start, p.current.start, .{
            .labeled_stmt = .{ .name = "yield", .body = body },
        });
    }
    // Phase 4d: labeled statement — identifier followed by colon.
    if (p.current.kind == .identifier) {
        // Peek ahead: if next non-whitespace token is ':', this is a labeled stmt.
        // We need to save/restore state if it's not a label.
        // Simple approach: save state and check.
        const saved_tok = p.current;
        _ = p.advance();
        if (p.current.kind == .colon) {
            // It's a label!
            _ = p.advance(); // consume ':'
            const label_name = saved_tok.value_str;
            const body = p.parseStatement() orelse return null;
            return p.makeNode(.labeled_stmt, saved_tok.start, p.current.start, .{
                .labeled_stmt = .{ .name = label_name, .body = body },
            });
        } else {
            // Not a label — restore by re-parsing as expr statement.
            // We consumed the identifier, so construct an identifier node.
            const ident_node = p.makeNode(.identifier, saved_tok.start, saved_tok.end, .{
                .identifier = if (std.mem.eql(u8, saved_tok.value_str, "undefined")) blk: {
                    // It was an undefined literal but we already consumed it.
                    // Just return an undefined literal stmt.
                    break :blk saved_tok.value_str;
                } else saved_tok.value_str,
            }) orelse return null;
            // Now parse the rest as an expression starting from ident_node.
            const full_expr = p.parseExprFromIdent(ident_node) orelse return null;
            p.consumeSemicolon();
            return p.makeNode(.expr_stmt, ident_node.start, p.current.start, .{ .expr_stmt = full_expr });
        }
    }
    return switch (p.current.kind) {
        .left_brace => p.parseBlock(),
        .kw_var => p.parseVarDeclStmt(),
        .kw_let => p.parseLexicalDeclStmt(.let),
        .kw_const => p.parseLexicalDeclStmt(.const_),
        .kw_class => p.parseClassDeclStmt(),
        .kw_import => p.parseImportDecl(),
        .kw_export => p.parseExportDecl(),
        .kw_function => p.parseFunctionDecl(false),
        .kw_if => p.parseIfStmt(),
        .kw_while => blk: {
            p.iteration_depth += 1;
            defer p.iteration_depth -= 1;
            break :blk p.parseWhileStmt();
        },
        .kw_do => blk: {
            p.iteration_depth += 1;
            defer p.iteration_depth -= 1;
            break :blk p.parseDoWhileStmt();
        },
        .kw_with => p.parseWithStmt(),
        .kw_for => blk: {
            p.iteration_depth += 1;
            defer p.iteration_depth -= 1;
            break :blk p.parseForStmt();
        },
        .kw_return => p.parseReturnStmt(),
        .kw_break => p.parseBreakStmt(),
        .kw_continue => p.parseContinueStmt(),
        .kw_throw => p.parseThrowStmt(),
        .kw_try => p.parseTryStmt(),
        .kw_switch => blk: {
            p.switch_depth += 1;
            defer p.switch_depth -= 1;
            break :blk p.parseSwitchStmt();
        },
        .semicolon => {
            const start = p.current.start;
            _ = p.advance();
            return p.makeNode(.empty_stmt, start, start + 1, .{ .empty_stmt = {} });
        },
        .kw_debugger => {
            const start = p.current.start;
            _ = p.advance();
            p.consumeSemicolon();
            return p.makeNode(.debugger_stmt, start, p.current.start, .{ .debugger_stmt = {} });
        },
        else => p.parseExprStmt(),
    };
}

pub fn parseBlock(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.expect(.left_brace) orelse return null;
    var body = std.ArrayList(*Node){};
    while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
        const s = p.parseStatement() orelse break;
        body.append(p.arena, s) catch {
            p.had_error = true;
            break;
        };
    }
    _ = p.expect(.right_brace) orelse return null;
    const end = p.current.start;
    const items = desugarUsingScope(p, body.items, start);
    return p.makeNode(.block_stmt, start, end, .{ .block_stmt = .{ .body = items } });
}

/// Note whether `it` (a top-level statement of some lexical scope) is a `using`
/// or `await using` declaration. Multi-declarator forms lower to a *transparent*
/// container block (`lexical_scope == false`), so recurse into those.
fn collectUsing(it: *Node, has_sync: *bool, has_async: *bool) void {
    if (it.kind == .var_decl) {
        switch (it.data.var_decl.using_kind) {
            .using_ => has_sync.* = true,
            .await_using_ => has_async.* = true,
            .none => {},
        }
    } else if (it.kind == .block_stmt and !it.data.block_stmt.lexical_scope) {
        for (it.data.block_stmt.body) |b| collectUsing(b, has_sync, has_async);
    }
}

/// Rewrite each `using x = e` / `await using x = e` in place to a plain
/// `let x = __ds.use(e)`: the disposable-stack `use` performs AddDisposableResource
/// (validating @@dispose / @@asyncDispose, no-op for null/undefined) and returns
/// the resource, so the binding keeps its value while registering for disposal.
fn rewriteUsingDecls(p: *Parser, it: *Node, ds_name: []const u8, start: u32) void {
    if (it.kind == .var_decl and it.data.var_decl.using_kind != .none) {
        var init = it.data.var_decl.init orelse return;
        // NamedEvaluation: `using x = () => {}` names the function "x". Wrapping the
        // initializer in `use(...)` would otherwise leave an anonymous-function
        // argument unnamed, so apply the name before the wrap.
        const is_anon = switch (init.kind) {
            .function_expr => init.data.function_expr.name == null,
            .call_expr => init.data.call_expr.anon_class_iife,
            else => false,
        };
        if (is_anon) {
            const namer = p.makeNode(.identifier, start, start, .{ .identifier = "__nameFn__" }) orelse return;
            const key = p.makeNode(.string_literal, start, start, .{ .string_literal = it.data.var_decl.name }) orelse return;
            var nargs = std.ArrayList(*Node){};
            nargs.append(p.arena, init) catch return;
            nargs.append(p.arena, key) catch return;
            init = p.makeNode(.call_expr, start, start, .{ .call_expr = .{ .callee = namer, .args = nargs.items } }) orelse return;
        }
        const ds_id = p.makeNode(.identifier, start, start, .{ .identifier = ds_name }) orelse return;
        const use_id = p.makeNode(.identifier, start, start, .{ .identifier = "use" }) orelse return;
        const use_member = p.makeNode(.member_expr, start, start, .{
            .member_expr = .{ .object = ds_id, .property = use_id, .computed = false },
        }) orelse return;
        var args = std.ArrayList(*Node){};
        args.append(p.arena, init) catch return;
        const use_call = p.makeNode(.call_expr, start, start, .{
            .call_expr = .{ .callee = use_member, .args = args.items },
        }) orelse return;
        it.data.var_decl.init = use_call;
        it.data.var_decl.using_kind = .none;
    } else if (it.kind == .block_stmt and !it.data.block_stmt.lexical_scope) {
        for (it.data.block_stmt.body) |b| rewriteUsingDecls(p, b, ds_name, start);
    }
}

/// Explicit Resource Management (§13.16): if `items` (a lexical scope's statement
/// list) declares any `using` / `await using` resources, wrap the scope so those
/// resources are disposed when it exits — normally or abruptly — in reverse
/// order, aggregating disposal errors into a SuppressedError:
///
///   let __ds_N = new DisposableStack();          // AsyncDisposableStack if async
///   try { <stmts; each `using x = e` -> `let x = __ds_N.use(e)`> }
///   finally { __ds_N.dispose(); }                // await __ds_N.disposeAsync()
///
/// Returns `items` unchanged when the scope declares no resources.
pub fn desugarUsingScope(p: *Parser, items: []*Node, start: u32) []*Node {
    var has_sync = false;
    var has_async = false;
    for (items) |it| collectUsing(it, &has_sync, &has_async);
    if (!has_sync and !has_async) return items;
    const is_async = has_async;

    const ds_name = std.fmt.allocPrint(p.arena, "__ds_{d}__", .{p.param_destruct_counter}) catch return items;
    p.param_destruct_counter += 1;

    for (items) |it| rewriteUsingDecls(p, it, ds_name, start);

    return wrapItemsInDisposal(p, items, ds_name, is_async, start) orelse items;
}

/// Build the disposal scaffolding around `body_items` (whose top-level `using`
/// declarations have already been rewritten to `__ds.use(...)` with the same
/// `ds_name`): a fresh (Async)DisposableStack, a try/catch/finally that captures
/// a body throw and disposes via `__usingDispose__`/`__usingDisposeAsync__`.
/// Returns the wrapping statement list, or null on an allocation failure.
fn wrapItemsInDisposal(p: *Parser, body_items: []*Node, ds_name: []const u8, is_async: bool, start: u32) ?[]*Node {
    // let __ds = new (Async)DisposableStack();
    const ctor_name = if (is_async) "AsyncDisposableStack" else "DisposableStack";
    const ctor_id = p.makeNode(.identifier, start, start, .{ .identifier = ctor_name }) orelse return null;
    const new_expr = p.makeNode(.new_expr, start, start, .{ .new_expr = .{ .callee = ctor_id, .args = &[_]*Node{} } }) orelse return null;
    const ds_decl = p.makeNode(.var_decl, start, start, .{ .var_decl = .{ .kind = .let, .name = ds_name, .init = new_expr } }) orelse return null;

    // Names for the caught-error flag/value threaded into disposal, so a body
    // throw becomes the innermost `suppressed` of the SuppressedError chain.
    const err_name = std.fmt.allocPrint(p.arena, "__uerr_{s}", .{ds_name}) catch return null;
    const has_name = std.fmt.allocPrint(p.arena, "__uhas_{s}", .{ds_name}) catch return null;
    const cvar_name = std.fmt.allocPrint(p.arena, "__uc_{s}", .{ds_name}) catch return null;

    const try_block = p.makeNode(.block_stmt, start, start, .{ .block_stmt = .{ .body = body_items, .lexical_scope = true } }) orelse return null;

    // catch (__uc) { __uerr = __uc; __uhas = true; }
    const catch_body = blk: {
        const uc_id = p.makeNode(.identifier, start, start, .{ .identifier = cvar_name }) orelse return null;
        const err_id = p.makeNode(.identifier, start, start, .{ .identifier = err_name }) orelse return null;
        const a1 = p.makeNode(.assignment_expr, start, start, .{ .assignment_expr = .{ .op = .assign, .target = err_id, .value = uc_id } }) orelse return null;
        const has_id = p.makeNode(.identifier, start, start, .{ .identifier = has_name }) orelse return null;
        const true_lit = p.makeNode(.bool_literal, start, start, .{ .bool_literal = true }) orelse return null;
        const a2 = p.makeNode(.assignment_expr, start, start, .{ .assignment_expr = .{ .op = .assign, .target = has_id, .value = true_lit } }) orelse return null;
        var cb = std.ArrayList(*Node){};
        cb.append(p.arena, p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = a1 }) orelse return null) catch return null;
        cb.append(p.arena, p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = a2 }) orelse return null) catch return null;
        break :blk p.makeNode(.block_stmt, start, start, .{ .block_stmt = .{ .body = cb.items, .lexical_scope = true } }) orelse return null;
    };

    // finalizer: `__usingDispose__(__ds, __uhas, __uerr);` (await for async).
    const helper_name = if (is_async) "__usingDisposeAsync__" else "__usingDispose__";
    const helper_id = p.makeNode(.identifier, start, start, .{ .identifier = helper_name }) orelse return null;
    var dargs = std.ArrayList(*Node){};
    dargs.append(p.arena, p.makeNode(.identifier, start, start, .{ .identifier = ds_name }) orelse return null) catch return null;
    dargs.append(p.arena, p.makeNode(.identifier, start, start, .{ .identifier = has_name }) orelse return null) catch return null;
    dargs.append(p.arena, p.makeNode(.identifier, start, start, .{ .identifier = err_name }) orelse return null) catch return null;
    var disp_expr = p.makeNode(.call_expr, start, start, .{ .call_expr = .{ .callee = helper_id, .args = dargs.items } }) orelse return null;
    if (is_async) {
        const aw = p.makeNode(.identifier, start, start, .{ .identifier = "__await__" }) orelse return null;
        var aargs = std.ArrayList(*Node){};
        aargs.append(p.arena, disp_expr) catch return null;
        disp_expr = p.makeNode(.call_expr, start, start, .{ .call_expr = .{ .callee = aw, .args = aargs.items } }) orelse return null;
    }
    const disp_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = disp_expr }) orelse return null;
    var fin_body = std.ArrayList(*Node){};
    fin_body.append(p.arena, disp_stmt) catch return null;
    const finalizer = p.makeNode(.block_stmt, start, start, .{ .block_stmt = .{ .body = fin_body.items, .lexical_scope = true } }) orelse return null;
    const try_stmt = p.makeNode(.try_stmt, start, start, .{ .try_stmt = .{
        .block = try_block,
        .handler = .{ .param_name = cvar_name, .body = catch_body },
        .finalizer = finalizer,
    } }) orelse return null;

    // let __uerr = undefined; let __uhas = false;
    const err_decl = p.makeNode(.var_decl, start, start, .{ .var_decl = .{ .kind = .let, .name = err_name, .init = null } }) orelse return null;
    const false_lit = p.makeNode(.bool_literal, start, start, .{ .bool_literal = false }) orelse return null;
    const has_decl = p.makeNode(.var_decl, start, start, .{ .var_decl = .{ .kind = .let, .name = has_name, .init = false_lit } }) orelse return null;

    var out = std.ArrayList(*Node){};
    out.append(p.arena, ds_decl) catch return null;
    out.append(p.arena, err_decl) catch return null;
    out.append(p.arena, has_decl) catch return null;
    out.append(p.arena, try_stmt) catch return null;
    return out.items;
}

/// Wrap a `for (using x = e; …)` C-style loop (whose `using` init declarations
/// dispose once, at loop exit) in a disposal scope block. `for_stmt` is the built
/// ForStatement; `using_decls` are its init declarations (still tagged
/// `using_kind`). Returns a `block_stmt` node, or `for_stmt` unchanged on failure.
pub fn wrapForUsing(p: *Parser, for_stmt: *Node, using_decls: []*Node, start: u32) *Node {
    var has_async = false;
    for (using_decls) |d| {
        if (d.kind == .var_decl and d.data.var_decl.using_kind == .await_using_) has_async = true;
    }
    const ds_name = std.fmt.allocPrint(p.arena, "__ds_{d}__", .{p.param_destruct_counter}) catch return for_stmt;
    p.param_destruct_counter += 1;
    for (using_decls) |d| rewriteUsingDecls(p, d, ds_name, start);
    var inner = std.ArrayList(*Node){};
    inner.append(p.arena, for_stmt) catch return for_stmt;
    const wrapped = wrapItemsInDisposal(p, inner.items, ds_name, has_async, start) orelse return for_stmt;
    return p.makeNode(.block_stmt, start, p.current.start, .{ .block_stmt = .{ .body = wrapped, .lexical_scope = true } }) orelse for_stmt;
}

/// Build the per-iteration body of a `for (using x of it)` loop: a disposal scope
/// that registers the current binding `x` (`__ds.use(x)`) then runs the original
/// body, disposing `x` when the iteration exits. `is_async` selects the async
/// disposal path for `for (await using x of it)`. Returns a `block_stmt`, or null
/// on failure.
fn wrapForOfUsing(p: *Parser, name: []const u8, body: *Node, is_async: bool, start: u32) ?*Node {
    const ds_name = std.fmt.allocPrint(p.arena, "__ds_{d}__", .{p.param_destruct_counter}) catch return null;
    p.param_destruct_counter += 1;
    // __ds.use(x);
    const ds_id = p.makeNode(.identifier, start, start, .{ .identifier = ds_name }) orelse return null;
    const use_id = p.makeNode(.identifier, start, start, .{ .identifier = "use" }) orelse return null;
    const use_member = p.makeNode(.member_expr, start, start, .{ .member_expr = .{ .object = ds_id, .property = use_id, .computed = false } }) orelse return null;
    const x_id = p.makeNode(.identifier, start, start, .{ .identifier = name }) orelse return null;
    var uargs = std.ArrayList(*Node){};
    uargs.append(p.arena, x_id) catch return null;
    const use_call = p.makeNode(.call_expr, start, start, .{ .call_expr = .{ .callee = use_member, .args = uargs.items } }) orelse return null;
    const use_stmt = p.makeNode(.expr_stmt, start, start, .{ .expr_stmt = use_call }) orelse return null;
    var inner = std.ArrayList(*Node){};
    inner.append(p.arena, use_stmt) catch return null;
    inner.append(p.arena, body) catch return null;
    const wrapped = wrapItemsInDisposal(p, inner.items, ds_name, is_async, start) orelse return null;
    return p.makeNode(.block_stmt, start, p.current.start, .{ .block_stmt = .{ .body = wrapped, .lexical_scope = true } });
}

pub fn parseVarDeclStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'var'
    return p.parseVarDeclarators(start, .var_, true);
}

pub fn parseLexicalDeclStmt(p: *Parser, kind: ast.VarKind) ?*Node {
    const start = p.current.start;
    const kw_line = p.current.line;
    _ = p.advance(); // consume let/const
    // ASI: `let` followed by `{` or `[` on a DIFFERENT line is an expression
    // statement `let;` in non-strict mode (let is a valid identifier).
    // `const` has no such ASI case (it is always a declaration).
    if (kind == .let and p.current.line > kw_line and
        (p.current.kind == .left_brace or p.current.kind == .left_bracket))
    {
        const id = p.makeNode(.identifier, start, start, .{ .identifier = "let" }) orelse return null;
        return p.makeNode(.expr_stmt, start, p.current.start, .{ .expr_stmt = id });
    }
    return p.parseVarDeclarators(start, kind, true);
}

/// Parse one or more var declarators (comma separated). Returns a sequence
/// if multiple, single VarDecl if one. For for-loop init this is fine.
pub fn parseVarDeclarators(p: *Parser, start: u32, kind: ast.VarKind, consume_semicolon: bool) ?*Node {
    var decls = std.ArrayList(*Node){};
    while (true) {
        const d = p.parseVarDeclarator(kind) orelse return null;
        decls.append(p.arena, d) catch {
            p.had_error = true;
            return null;
        };
        if (!p.match(.comma)) break;
    }
    if (consume_semicolon) p.consumeSemicolon();
    if (decls.items.len == 1) return decls.items[0];
    // Multiple declarators: wrap in a transparent block_stmt (bindings belong to
    // the enclosing scope, not a fresh block scope).
    return p.makeNode(.block_stmt, start, p.current.start, .{ .block_stmt = .{ .body = decls.items, .lexical_scope = false } });
}

pub fn parseVarDeclarator(p: *Parser, kind: ast.VarKind) ?*Node {
    const start = p.current.start;
    if (p.check(.left_bracket) or p.check(.left_brace)) {
        return parseDestructuringDeclarator(p, kind, start);
    }
    // `yield` is a valid BindingIdentifier in sloppy-mode code outside a
    // generator (`var yield = 4;`); the strict/generator cases are rejected by
    // the future-reserved-word check below or the parser's generator context.
    const yield_as_ident = p.check(.kw_yield) and !p.strict and !p.in_generator_function;
    const name_tok = if (p.check(.kw_of) or yield_as_ident) p.advance() else (p.expect(.identifier) orelse return null);
    const name: []const u8 = if (name_tok.kind == .kw_of) "of" else name_tok.value_str;
    if (p.staticBlockReservedIdent(name)) |msg| return p.fail(msg);
    // Strict-mode early error: a future-reserved word (or `eval`/`arguments`)
    // may not be a binding identifier in strict code (ES §13.1.1, §12.7.2).
    if (p.strict and parser_file.isStrictReservedWord(name)) {
        if (!p.had_error) {
            p.had_error = true;
            p.error_info = parser_file.ParseError{
                .message = "unexpected strict-mode reserved word as binding name",
                .line = name_tok.line,
                .column = name_tok.column,
            };
        }
        return null;
    }
    var init_node: ?*Node = null;
    if (p.match(.eq)) {
        // NamedEvaluation: `let x = class {}` names the anonymous class after the
        // binding. A class expression desugars to an IIFE, so the compiler's
        // function name-hint can't reach the constructor; thread the name in via
        // the parser's anonymous-name hint, which parseClassExpr consumes.
        const set_class_hint = p.check(.kw_class) and p.export_default_name_hint == null;
        if (set_class_hint) p.export_default_name_hint = name;
        init_node = p.parseAssignmentExpr();
        if (set_class_hint) p.export_default_name_hint = null;
    }
    if (kind == .const_ and init_node == null) {
        if (!p.had_error) {
            p.had_error = true;
            p.error_info = parser_file.ParseError{
                .message = "const declaration requires an initializer",
                .line = name_tok.line,
                .column = name_tok.column,
            };
        }
        return null;
    }
    const end = p.current.start;
    return p.makeNode(.var_decl, start, end, .{ .var_decl = .{ .kind = kind, .name = name, .init = init_node } });
}

/// `let/const/var [a, b = 1, ...r] = rhs` / `let/const/var {a, b: c = 1, ...r} = rhs`.
/// Parses the pattern as an ARRAY/OBJECT LITERAL EXPRESSION — array patterns
/// reuse `parseArrayLiteral` (already handles elision/defaults/rest/nesting via
/// `a=9` -> assignment_expr, `...r` -> spread_expr, `[[a],b]` -> nested
/// literals); object patterns use `expr_mod.parseObjectPattern`, the pattern-only
/// grammar that additionally accepts a trailing `...rest`. The RHS is bound to a
/// fresh temp of the declared `kind`, then `desugarParamPattern` walks the
/// pattern emitting one decl per binding (also of `kind`) into a local list,
/// scoped via `p.destruct_out`/`p.destruct_kind` (saved/restored so this can't
/// leak into unrelated arrow-param desugaring). Destructuring declarations
/// always require an initializer, even for `var`/`let` (spec: only a bare
/// identifier binding may omit one).
fn parseDestructuringDeclarator(p: *Parser, kind: ast.VarKind, start: u32) ?*Node {
    const pattern: *Node = if (p.check(.left_bracket))
        p.parseArrayLiteral() orelse return null
    else
        expr_mod.parseObjectPattern(p) orelse return null;
    _ = p.expect(.eq) orelse return null;
    const rhs = p.parseAssignmentExpr() orelse return null;
    const tmp_name = std.fmt.allocPrint(p.arena, "__destruct_{d}", .{start}) catch return null;

    var body = std.ArrayList(*Node){};
    const tmp_decl = p.makeNode(.var_decl, start, p.current.start, .{
        .var_decl = .{ .kind = kind, .name = tmp_name, .init = rhs },
    }) orelse return null;
    body.append(p.arena, tmp_decl) catch return null;
    const tmp_ref = p.makeNode(.identifier, start, start, .{ .identifier = tmp_name }) orelse return null;

    var decls_out = std.ArrayList(*Node){};
    const saved_out = p.destruct_out;
    const saved_kind = p.destruct_kind;
    p.destruct_out = &decls_out;
    p.destruct_kind = kind;
    const ok = expr_mod.desugarParamPattern(p, pattern, tmp_ref);
    p.destruct_out = saved_out;
    p.destruct_kind = saved_kind;
    if (!ok) return null;
    body.appendSlice(p.arena, decls_out.items) catch return null;

    return p.makeNode(.block_stmt, start, p.current.start, .{
        .block_stmt = .{ .body = body.items, .lexical_scope = false },
    });
}

pub fn parseFunctionDecl(p: *Parser, is_async: bool) ?*Node {
    // For `async function`, the caller has already consumed `async` and recorded
    // its start in `async_kw_start` so the source span (used by toString) begins
    // at `async`. Otherwise the span begins at `function`.
    const start = if (is_async and p.async_kw_start != 0) p.async_kw_start else p.current.start;
    p.async_kw_start = 0;
    _ = p.advance(); // consume 'function'
    const is_generator = p.match(.star);
    const name_tok = p.expect(.identifier) orelse return null;
    const name = name_tok.value_str;
    if (!parser_file.checkStrictBindingName(p, name, name_tok.line, name_tok.column)) return null;
    const parsed_params = p.parseFunctionParams() orelse return null;
    const prev_gen = p.in_generator_function;
    p.in_generator_function = is_generator;
    const body = p.parseFunctionBody() orelse {
        p.in_generator_function = prev_gen;
        return null;
    };
    p.in_generator_function = prev_gen;
    if (!parser_file.checkStrictDirectiveSimpleParams(p, parsed_params.non_simple, body)) return null;
    const is_strict = parser_file.hasUseStrict(body);
    return p.makeNode(.function_decl, start, p.current.start, .{
        .function_decl = .{
            .name = name,
            .params = parsed_params.params,
            .param_defaults = parsed_params.param_defaults,
            .expected_argc = parsed_params.expected_argc,
            .rest_param = parsed_params.rest_param,
            .body = body,
            .is_generator = is_generator,
            .is_async = is_async,
            .is_strict = is_strict,
            .source_text = p.sourceSlice(start, p.prev_end),
        },
    });
}

pub fn parseIfStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'if'
    _ = p.expect(.left_paren) orelse return null;
    const test_ = p.parseExpression() orelse return null;
    _ = p.expect(.right_paren) orelse return null;
    const consequent = p.parseStatement() orelse return null;
    var alternate: ?*Node = null;
    if (p.match(.kw_else)) {
        alternate = p.parseStatement();
    }
    return p.makeNode(.if_stmt, start, p.current.start, .{
        .if_stmt = .{ .test_ = test_, .consequent = consequent, .alternate = alternate },
    });
}

pub fn parseWhileStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'while'
    _ = p.expect(.left_paren) orelse return null;
    const test_ = p.parseExpression() orelse return null;
    _ = p.expect(.right_paren) orelse return null;
    const body = p.parseStatement() orelse return null;
    return p.makeNode(.while_stmt, start, p.current.start, .{
        .while_stmt = .{ .test_ = test_, .body = body },
    });
}

pub fn parseWithStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    // A `with` statement in strict-mode code is an early SyntaxError (ES §14.11.1).
    if (p.strict) return p.fail("strict mode code may not include a with statement");
    _ = p.advance(); // consume 'with'
    _ = p.expect(.left_paren) orelse return null;
    const object = p.parseExpression() orelse return null;
    _ = p.expect(.right_paren) orelse return null;
    const body = p.parseStatement() orelse return null;
    return p.makeNode(.with_stmt, start, p.current.start, .{
        .with_stmt = .{ .object = object, .body = body },
    });
}

pub fn parseDoWhileStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'do'
    const body = p.parseStatement() orelse return null;
    _ = p.expect(.kw_while) orelse return null;
    _ = p.expect(.left_paren) orelse return null;
    const test_ = p.parseExpression() orelse return null;
    _ = p.expect(.right_paren) orelse return null;
    p.consumeSemicolon();
    return p.makeNode(.do_while_stmt, start, p.current.start, .{
        .do_while_stmt = .{ .body = body, .test_ = test_ },
    });
}

pub fn parseForStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'for'
    // `for await (... of ...)`: consume 'await' and remember it so the for-of is
    // lowered to the async-iterator protocol (awaiting each step).
    var for_await = false;
    if (p.current.kind == .identifier and std.mem.eql(u8, p.current.value_str, "await")) {
        for_await = true;
        _ = p.advance();
    }
    _ = p.expect(.left_paren) orelse return null;

    // Explicit resource management head: `for (using x of it)` /
    // `for (await using x of it)`. Lowered to a `let` for-of binding (fresh per
    // iteration). Only for-of is valid — for-in / C-style for with a using
    // declaration is a SyntaxError.
    if (atAwaitUsingDecl(p) or atUsingDecl(p)) {
        const is_await = atAwaitUsingDecl(p);
        const using_kind: ast.UsingKind = if (is_await) .await_using_ else .using_;
        if (is_await) _ = p.advance(); // consume `await`
        _ = p.advance(); // consume `using`
        if (p.check(.left_bracket) or p.check(.left_brace)) {
            return p.fail("using declaration requires a binding identifier");
        }
        const name_tok = if (p.check(.kw_of)) p.advance() else (p.expect(.identifier) orelse return null);
        const name: []const u8 = if (name_tok.kind == .kw_of) "of" else name_tok.value_str;
        // `for (using x of it)`: per-iteration for-of binding (lowered to `let`).
        // Each iteration's resource is disposed at the END of that iteration, so
        // the body is wrapped in its own disposal scope that registers `x`.
        if (p.check(.kw_of)) {
            _ = p.advance(); // consume `of`
            const right = p.parseAssignmentExpr() orelse return null;
            _ = p.expect(.right_paren) orelse return null;
            const body = p.parseStatement() orelse return null;
            const left = p.makeNode(.var_decl, name_tok.start, name_tok.end, .{
                .var_decl = .{ .kind = .let, .name = name, .init = null },
            }) orelse return null;
            const wrapped_body = wrapForOfUsing(p, name, body, is_await, start) orelse body;
            return p.makeNode(.for_in_stmt, start, p.current.start, .{
                .for_in_stmt = .{ .left = left, .right = right, .body = wrapped_body, .iterate_values = true, .is_await = for_await },
            });
        }
        // `for (using x = e; cond; incr)`: C-style head with a required
        // initializer; the resource disposes once, when the loop exits. Build the
        // ForStatement, then wrap it in a disposal scope.
        if (for_await) return p.fail("'for await' requires an 'of' loop");
        var decls = std.ArrayList(*Node){};
        {
            var d_name = name;
            var d_start = name_tok.start;
            while (true) {
                if (!p.match(.eq)) return p.fail("using declaration requires an initializer");
                p.no_in = true;
                const init_node = p.parseAssignmentExpr();
                p.no_in = false;
                const d = p.makeNode(.var_decl, d_start, p.current.start, .{
                    .var_decl = .{ .kind = .let, .name = d_name, .init = init_node, .using_kind = using_kind },
                }) orelse return null;
                decls.append(p.arena, d) catch return null;
                if (!p.match(.comma)) break;
                const nt = p.expect(.identifier) orelse return null;
                d_name = nt.value_str;
                d_start = nt.start;
            }
        }
        _ = p.expect(.semicolon) orelse return null;
        const init_node: ?*Node = if (decls.items.len == 1) decls.items[0] else p.makeNode(.block_stmt, start, p.current.start, .{
            .block_stmt = .{ .body = decls.items, .lexical_scope = false },
        });
        const for_stmt = p.parseForTail(start, init_node) orelse return null;
        return wrapForUsing(p, for_stmt, decls.items, start);
    }

    // Detect for-in: for (var/let/const x in obj) or for (x in obj)
    // `let` only begins a LexicalDeclaration when a BindingIdentifier / `[` /
    // `{` follows. In sloppy code `for (let in obj)` is a for-in whose target is
    // the *identifier* `let`, so leave it to the expression path below.
    const let_is_decl = !p.check(.kw_let) or p.strict or blk: {
        const nk = p.peekNext().kind;
        break :blk nk == .identifier or nk == .left_bracket or nk == .left_brace;
    };
    if (let_is_decl and (p.check(.kw_var) or p.check(.kw_let) or p.check(.kw_const))) {
        // save position: for (var/let/const NAME in ...) is for-in
        const decl_kind: ast.VarKind = if (p.check(.kw_var)) .var_ else if (p.check(.kw_let)) .let else .const_;
        _ = p.advance(); // consume declaration keyword
        if (p.check(.left_bracket) or p.check(.left_brace)) {
            return p.parseForDestructuring(start, decl_kind, for_await);
        }
        if (p.check(.identifier)) {
            const name_tok = p.current;
            _ = p.advance(); // consume identifier
            if (p.check(.kw_in)) {
                // It's for-in: for (var/let/const name in expr)
                _ = p.advance(); // consume 'in'
                const right = p.parseExpression() orelse return null;
                _ = p.expect(.right_paren) orelse return null;
                const body = p.parseStatement() orelse return null;
                // Create a var_decl node as the left side
                const left = p.makeNode(.var_decl, name_tok.start, name_tok.end, .{
                    .var_decl = .{ .kind = decl_kind, .name = name_tok.value_str, .init = null },
                }) orelse return null;
                return p.makeNode(.for_in_stmt, start, p.current.start, .{
                    .for_in_stmt = .{ .left = left, .right = right, .body = body, .iterate_values = false },
                });
            } else if (p.check(.kw_of)) {
                _ = p.advance(); // consume 'of'
                const right = p.parseExpression() orelse return null;
                _ = p.expect(.right_paren) orelse return null;
                const body = p.parseStatement() orelse return null;
                const left = p.makeNode(.var_decl, name_tok.start, name_tok.end, .{
                    .var_decl = .{ .kind = decl_kind, .name = name_tok.value_str, .init = null },
                }) orelse return null;
                return p.makeNode(.for_in_stmt, start, p.current.start, .{
                    .for_in_stmt = .{ .left = left, .right = right, .body = body, .iterate_values = true, .is_await = for_await },
                });
            } else if (p.check(.eq) or p.check(.comma) or p.check(.semicolon)) {
                // Normal for loop: for (var/let/const name = ...; ...)
                // Handle initializer if present
                var init_val: ?*Node = null;
                if (p.match(.eq)) {
                    // [~In]: `in` here separates the head from the enumerated
                    // object, so it must not be consumed as an operator.
                    p.no_in = true;
                    init_val = p.parseAssignmentExpr();
                    p.no_in = false;
                }
                // Annex B.3.5: a `var` for-in head may carry an initializer
                // (`for (var a = 0 in obj)`). It is evaluated once, before the
                // enumerated object, and assigned to the binding; the loop then
                // proceeds as an ordinary for-in.
                if (init_val != null and decl_kind == .var_ and p.check(.kw_in)) {
                    _ = p.advance(); // consume `in`
                    const right = p.parseExpression() orelse return null;
                    _ = p.expect(.right_paren) orelse return null;
                    const body = p.parseStatement() orelse return null;
                    const left = p.makeNode(.var_decl, name_tok.start, name_tok.end, .{
                        .var_decl = .{ .kind = .var_, .name = name_tok.value_str, .init = init_val },
                    }) orelse return null;
                    return p.makeNode(.for_in_stmt, start, p.current.start, .{
                        .for_in_stmt = .{ .left = left, .right = right, .body = body, .iterate_values = false },
                    });
                }
                if (decl_kind == .const_ and init_val == null) {
                    if (!p.had_error) {
                        p.had_error = true;
                        p.error_info = parser_file.ParseError{
                            .message = "const declaration requires an initializer",
                            .line = name_tok.line,
                            .column = name_tok.column,
                        };
                    }
                    return null;
                }
                const first_decl = p.makeNode(.var_decl, name_tok.start, p.current.start, .{
                    .var_decl = .{ .kind = decl_kind, .name = name_tok.value_str, .init = init_val },
                }) orelse return null;
                var decls = std.ArrayList(*Node){};
                decls.append(p.arena, first_decl) catch {
                    p.had_error = true;
                    return null;
                };
                while (p.match(.comma)) {
                    const d = p.parseVarDeclarator(decl_kind) orelse return null;
                    decls.append(p.arena, d) catch {
                        p.had_error = true;
                        return null;
                    };
                }
                _ = p.expect(.semicolon) orelse return null;
                const init_node: ?*Node = if (decls.items.len == 1) decls.items[0] else p.makeNode(.block_stmt, start, p.current.start, .{
                    .block_stmt = .{ .body = decls.items, .lexical_scope = false },
                });
                return p.parseForTail(start, init_node);
            } else {
                // Unexpected — treat as for (var/let name; ...).
                // const without initializer is invalid and already checked above.
                const first_decl = p.makeNode(.var_decl, name_tok.start, name_tok.end, .{
                    .var_decl = .{ .kind = decl_kind, .name = name_tok.value_str, .init = null },
                }) orelse return null;
                _ = p.expect(.semicolon) orelse return null;
                return p.parseForTail(start, first_decl);
            }
        } else {
            _ = p.expect(.semicolon) orelse return null;
            return p.parseForTail(start, null);
        }
    } else if (!p.check(.semicolon)) {
        // for (expr in ...) or for (expr; ...)
        // Parse the expression
        const expr = p.parseAssignmentExpr() orelse return null;
        // `for (lhs in rhs)`: parseAssignmentExpr eagerly consumed `in` as a
        // binary operator. Detect this and split it back into a for-in.
        if (expr.kind == .binary_expr and
            expr.data.binary_expr.op == .in and
            (p.check(.right_paren) or p.check(.comma)))
        {
            // The head's right-hand side is an `Expression`, so a comma sequence
            // may continue past what the binary `in` swallowed:
            // `for (x in null, {key: 0})` enumerates the object, not `null`.
            var right = expr.data.binary_expr.right;
            if (p.check(.comma)) {
                var seq = std.ArrayList(*Node){};
                seq.append(p.arena, right) catch return null;
                while (p.match(.comma)) {
                    const nxt = p.parseAssignmentExpr() orelse return null;
                    seq.append(p.arena, nxt) catch return null;
                }
                right = p.makeNode(.sequence_expr, start, p.current.start, .{
                    .sequence_expr = .{ .exprs = seq.items },
                }) orelse return null;
            }
            _ = p.expect(.right_paren) orelse return null;
            const body = p.parseStatement() orelse return null;
            return p.makeNode(.for_in_stmt, start, p.current.start, .{
                .for_in_stmt = .{
                    .left = expr.data.binary_expr.left,
                    .right = right,
                    .body = body,
                    .iterate_values = false,
                },
            });
        }
        if (p.check(.kw_in)) {
            // for-in with assignment expression left side
            _ = p.advance(); // consume 'in'
            const right = p.parseExpression() orelse return null;
            _ = p.expect(.right_paren) orelse return null;
            const body = p.parseStatement() orelse return null;
            return p.makeNode(.for_in_stmt, start, p.current.start, .{
                .for_in_stmt = .{ .left = expr, .right = right, .body = body, .iterate_values = false },
            });
        }
        if (p.check(.kw_of)) {
            _ = p.advance(); // consume 'of'
            const right = p.parseExpression() orelse return null;
            _ = p.expect(.right_paren) orelse return null;
            const body = p.parseStatement() orelse return null;
            return p.makeNode(.for_in_stmt, start, p.current.start, .{
                .for_in_stmt = .{ .left = expr, .right = right, .body = body, .iterate_values = true, .is_await = for_await },
            });
        }
        // Normal for: consume remaining of init expr (may be comma-separated)
        var final_expr = expr;
        if (p.check(.comma)) {
            var exprs = std.ArrayList(*Node){};
            exprs.append(p.arena, expr) catch {
                p.had_error = true;
                return null;
            };
            while (p.match(.comma)) {
                const e = p.parseAssignmentExpr() orelse return null;
                exprs.append(p.arena, e) catch {
                    p.had_error = true;
                    return null;
                };
            }
            final_expr = p.makeNode(.sequence_expr, expr.start, p.current.start, .{
                .sequence_expr = .{ .exprs = exprs.items },
            }) orelse return null;
        }
        const init_node = p.makeNode(.expr_stmt, final_expr.start, final_expr.end, .{ .expr_stmt = final_expr });
        _ = p.expect(.semicolon) orelse return null;
        return p.parseForTail(start, init_node);
    } else {
        _ = p.expect(.semicolon) orelse return null;
        return p.parseForTail(start, null);
    }
}

/// `for (let/const/var [a, b=1, ...r] of x) BODY` / `for (let/const/var {a,
/// b: c, ...r} of x) BODY` (also for-in). Parses the pattern the same way as
/// `parseDestructuringDeclarator` (array patterns via `parseArrayLiteral`,
/// object patterns via `expr_mod.parseObjectPattern`) so defaults/rest/nesting
/// work identically. Desugars to `for (let/const/var __t of x) { <binding
/// decls from desugarParamPattern>; BODY }` — the per-iteration destructuring
/// happens INSIDE the loop body, which already gets a fresh lexical
/// environment each iteration via the existing for-in/for-of lowering, so
/// `const`/`let` bindings stay fresh per iteration without any extra work here.
pub fn parseForDestructuring(p: *Parser, start: u32, kind: ast.VarKind, for_await: bool) ?*Node {
    const pattern: *Node = if (p.check(.left_bracket))
        p.parseArrayLiteral() orelse return null
    else
        expr_mod.parseObjectPattern(p) orelse return null;

    // C-style `for (var [a] = init; test; update)`: a destructuring declaration
    // in the init clause (not a for-of/for-in head). Desugar the binding into a
    // transparent block of declarations and continue with the C-style tail.
    if (p.check(.eq)) {
        _ = p.advance(); // consume '='
        const rhs = p.parseAssignmentExpr() orelse return null;
        const tmp_name = std.fmt.allocPrint(p.arena, "__forbind_{d}", .{start}) catch return null;
        var body = std.ArrayList(*Node){};
        const tmp_decl = p.makeNode(.var_decl, start, p.current.start, .{
            .var_decl = .{ .kind = kind, .name = tmp_name, .init = rhs },
        }) orelse return null;
        body.append(p.arena, tmp_decl) catch return null;
        const tmp_ref = p.makeNode(.identifier, start, start, .{ .identifier = tmp_name }) orelse return null;
        var decls_out2 = std.ArrayList(*Node){};
        const saved_out2 = p.destruct_out;
        const saved_kind2 = p.destruct_kind;
        p.destruct_out = &decls_out2;
        p.destruct_kind = kind;
        const ok2 = expr_mod.desugarParamPattern(p, pattern, tmp_ref);
        p.destruct_out = saved_out2;
        p.destruct_kind = saved_kind2;
        if (!ok2) return null;
        body.appendSlice(p.arena, decls_out2.items) catch return null;
        const init_block = p.makeNode(.block_stmt, start, p.current.start, .{
            .block_stmt = .{ .body = body.items, .lexical_scope = false },
        }) orelse return null;
        _ = p.expect(.semicolon) orelse return null;
        return parseForTail(p, start, init_block);
    }

    const iterate_values = if (p.check(.kw_of)) true else if (p.check(.kw_in)) false else {
        p.had_error = true;
        p.error_info = parser_file.ParseError{ .message = "expected 'of' or 'in' in for destructuring", .line = p.current.line, .column = p.current.column };
        return null;
    };
    _ = p.advance(); // consume of/in
    const right = p.parseExpression() orelse return null;
    _ = p.expect(.right_paren) orelse return null;
    const orig_body = p.parseStatement() orelse return null;

    const tmp_name = std.fmt.allocPrint(p.arena, "__forbind_{d}", .{start}) catch return null;
    const tmp_ref = p.makeNode(.identifier, start, start, .{ .identifier = tmp_name }) orelse return null;

    var decls_out = std.ArrayList(*Node){};
    const saved_out = p.destruct_out;
    const saved_kind = p.destruct_kind;
    p.destruct_out = &decls_out;
    p.destruct_kind = kind;
    const ok = expr_mod.desugarParamPattern(p, pattern, tmp_ref);
    p.destruct_out = saved_out;
    p.destruct_kind = saved_kind;
    if (!ok) return null;

    // Build the per-iteration destructuring declarations + original body. The
    // wrapper block is a real lexical scope for `let`/`const` heads: the names
    // bound by the pattern belong to the loop's per-iteration environment, not
    // to the block that encloses the `for` statement. Without it,
    // `for (let {value} of parts)` would declare `value` in the enclosing block
    // and poison any earlier read of an outer `value` with a TDZ error.
    const lexical_head = kind == .let or kind == .const_;
    var body_stmts = std.ArrayList(*Node){};
    body_stmts.appendSlice(p.arena, decls_out.items) catch return null;
    body_stmts.append(p.arena, orig_body) catch return null;
    const new_body = p.makeNode(.block_stmt, start, p.current.start, .{ .block_stmt = .{ .body = body_stmts.items, .lexical_scope = lexical_head } }) orelse return null;
    const left = p.makeNode(.var_decl, start, start, .{ .var_decl = .{ .kind = kind, .name = tmp_name, .init = null } }) orelse return null;
    return p.makeNode(.for_in_stmt, start, p.current.start, .{
        .for_in_stmt = .{ .left = left, .right = right, .body = new_body, .iterate_values = iterate_values, .is_await = for_await },
    });
}

pub fn parseForTail(p: *Parser, start: u32, init_node: ?*Node) ?*Node {
    // Test clause
    var test_node: ?*Node = null;
    if (!p.check(.semicolon)) {
        test_node = p.parseExpression();
    }
    _ = p.expect(.semicolon) orelse return null;

    // Update clause
    var update_node: ?*Node = null;
    if (!p.check(.right_paren)) {
        update_node = p.parseExpression();
    }
    _ = p.expect(.right_paren) orelse return null;
    const body = p.parseStatement() orelse return null;
    return p.makeNode(.for_stmt, start, p.current.start, .{
        .for_stmt = .{
            .init = init_node,
            .test_ = test_node,
            .update = update_node,
            .body = body,
        },
    });
}

pub fn parseSwitchStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'switch'
    _ = p.expect(.left_paren) orelse return null;
    const discriminant = p.parseExpression() orelse return null;
    _ = p.expect(.right_paren) orelse return null;
    _ = p.expect(.left_brace) orelse return null;

    var cases = std.ArrayList(ast.SwitchCase){};
    while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
        var test_node: ?*Node = null;
        if (p.check(.kw_case)) {
            _ = p.advance(); // consume 'case'
            test_node = p.parseExpression() orelse return null;
            _ = p.expect(.colon) orelse return null;
        } else if (p.check(.kw_default)) {
            _ = p.advance(); // consume 'default'
            _ = p.expect(.colon) orelse return null;
            test_node = null;
        } else {
            break; // unexpected
        }
        // Parse case body statements until next case/default/}
        var body = std.ArrayList(*Node){};
        while (!p.check(.kw_case) and !p.check(.kw_default) and
            !p.check(.right_brace) and !p.check(.eof) and !p.had_error)
        {
            const s = p.parseStatement() orelse break;
            body.append(p.arena, s) catch {
                p.had_error = true;
                break;
            };
        }
        cases.append(p.arena, ast.SwitchCase{ .test_ = test_node, .body = body.items }) catch {
            p.had_error = true;
            return null;
        };
    }
    _ = p.expect(.right_brace) orelse return null;
    return p.makeNode(.switch_stmt, start, p.current.start, .{
        .switch_stmt = .{ .discriminant = discriminant, .cases = cases.items },
    });
}

pub fn parseReturnStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    // §15.7.1: a class static initialization block is not a function body, so
    // `return` has nothing to return from.
    if (p.in_static_block)
        return p.fail("'return' is not allowed in a class static initialization block");
    // §19.2.1.1: eval code is Script code, so a `return` outside any function
    // body in it is an early SyntaxError — even for a direct eval whose caller
    // happens to be a function.
    if (p.eval_code and p.fn_nesting_depth == 0)
        return p.fail("'return' outside of function");
    _ = p.advance(); // consume 'return'
    // ASI rule: if next token has line terminator before it, return undefined.
    var value: ?*Node = null;
    if (!p.hasSemicolon()) {
        value = p.parseExpression();
    }
    p.consumeSemicolon();
    return p.makeNode(.return_stmt, start, p.current.start, .{ .return_stmt = value });
}

pub fn parseBreakStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance();
    var label: ?[]const u8 = null;
    if (!p.hasSemicolon() and p.check(.identifier)) {
        label = p.current.value_str;
        _ = p.advance();
    }
    // §13.9.1.1: an unlabeled `break` is an early error unless it is nested in an
    // iteration or switch statement. (A labeled break targets a labeled
    // statement, which need not be a loop, so it is not checked here.)
    if (label == null and p.iteration_depth == 0 and p.switch_depth == 0)
        return p.fail("Illegal break statement");
    p.consumeSemicolon();
    return p.makeNode(.break_stmt, start, p.current.start, .{ .break_stmt = label });
}

pub fn parseContinueStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance();
    var label: ?[]const u8 = null;
    if (!p.hasSemicolon() and p.check(.identifier)) {
        label = p.current.value_str;
        _ = p.advance();
    }
    // §13.8.1.1: a `continue` is an early error unless it is nested in an
    // iteration statement (a labeled continue must target an iteration label,
    // which likewise requires an enclosing loop).
    if (p.iteration_depth == 0)
        return p.fail("Illegal continue statement");
    p.consumeSemicolon();
    return p.makeNode(.continue_stmt, start, p.current.start, .{ .continue_stmt = label });
}

pub fn parseThrowStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'throw'
    // ASI: throw cannot have a line terminator after it.
    if (p.current.line_terminator_before) {
        if (!p.had_error) {
            p.had_error = true;
            p.error_info = parser_file.ParseError{
                .message = "illegal newline after throw",
                .line = p.current.line,
                .column = p.current.column,
            };
        }
        return null;
    }
    const argument = p.parseExpression() orelse return null;
    p.consumeSemicolon();
    return p.makeNode(.throw_stmt, start, p.current.start, .{ .throw_stmt = argument });
}

/// Skip a balanced `{...}` or `[...]` destructuring pattern at current position.
fn skipDestructuringPattern(p: *Parser) void {
    const open = p.current.kind;
    const close: @TypeOf(open) = if (open == .left_brace) .right_brace else .right_bracket;
    var depth: u32 = 1;
    _ = p.advance(); // consume opening bracket
    while (!p.check(.eof)) {
        if (p.current.kind == open) {
            depth += 1;
        } else if (p.current.kind == close) {
            depth -= 1;
            if (depth == 0) {
                _ = p.advance(); // consume closing bracket
                return;
            }
        }
        _ = p.advance();
    }
}

pub fn parseTryStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'try'
    const block = p.parseBlock() orelse return null;

    var handler: ?ast.CatchClause = null;
    var finalizer: ?*Node = null;

    if (p.check(.kw_catch)) {
        _ = p.advance(); // consume 'catch'
        // Optional catch binding (ES2019): `catch { ... }` with no `(param)`.
        // An empty param_name signals "no binding" to the lowering pass.
        var catch_param_name: []const u8 = "";
        // A destructuring catch binding (`catch ({a}) {}` / `catch ([a]) {}`) is
        // desugared: the exception is bound to a fresh temp and the pattern's own
        // bindings are introduced by `let` declarations prepended to the body.
        var catch_pattern: ?*Node = null;
        if (p.check(.left_paren)) {
            _ = p.advance(); // consume '('
            catch_param_name = if (p.check(.left_brace) or p.check(.left_bracket)) blk: {
                const tmp = std.fmt.allocPrint(p.arena, "__catch_{d}", .{start}) catch return null;
                catch_pattern = if (p.check(.left_bracket))
                    p.parseArrayLiteral() orelse return null
                else
                    expr_mod.parseObjectPattern(p) orelse return null;
                break :blk tmp;
            } else blk: {
                const tok = p.expect(.identifier) orelse return null;
                break :blk tok.value_str;
            };
            _ = p.expect(.right_paren) orelse return null;
        }
        var catch_body = p.parseBlock() orelse return null;
        if (catch_pattern) |pattern| {
            // Build the per-binding destructuring declarations reading the temp,
            // then wrap them together with the original body in a fresh block so
            // the catch-param bindings share the body's lexical scope.
            const tmp_ref = p.makeNode(.identifier, start, start, .{ .identifier = catch_param_name }) orelse return null;
            var decls_out = std.ArrayList(*Node){};
            const saved_out = p.destruct_out;
            const saved_kind = p.destruct_kind;
            p.destruct_out = &decls_out;
            p.destruct_kind = .let;
            const ok = expr_mod.desugarParamPattern(p, pattern, tmp_ref);
            p.destruct_out = saved_out;
            p.destruct_kind = saved_kind;
            if (!ok) return null;
            var body_stmts = std.ArrayList(*Node){};
            body_stmts.appendSlice(p.arena, decls_out.items) catch return null;
            body_stmts.append(p.arena, catch_body) catch return null;
            catch_body = p.makeNode(.block_stmt, start, p.current.start, .{
                .block_stmt = .{ .body = body_stmts.items, .lexical_scope = true },
            }) orelse return null;
        }
        handler = ast.CatchClause{
            .param_name = catch_param_name,
            .body = catch_body,
        };
    }

    if (p.check(.kw_finally)) {
        _ = p.advance(); // consume 'finally'
        finalizer = p.parseBlock();
    }

    if (handler == null and finalizer == null) {
        if (!p.had_error) {
            p.had_error = true;
            p.error_info = parser_file.ParseError{
                .message = "try statement requires at least a catch or finally clause",
                .line = p.current.line,
                .column = p.current.column,
            };
        }
        return null;
    }

    return p.makeNode(.try_stmt, start, p.current.start, .{
        .try_stmt = .{ .block = block, .handler = handler, .finalizer = finalizer },
    });
}

pub fn parseExprStmt(p: *Parser) ?*Node {
    const start = p.current.start;
    const expr = p.parseExpression() orelse return null;
    p.consumeSemicolon();
    return p.makeNode(.expr_stmt, start, p.current.start, .{ .expr_stmt = expr });
}
