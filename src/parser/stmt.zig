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

// ---------------------------------------------------------------- statements ---

/// M16 Phase 5: skip an import-attributes `with { ... }` or `assert { ... }`
/// clause that may follow a module specifier in import/export declarations.
/// The clause is parsed and discarded (JSZ does not enforce attributes).
fn skipImportAttributes(p: *Parser) void {
    // `with` is a reserved-word token (kw_with); `assert` is a contextual kw.
    const is_with = p.current.kind == .kw_with;
    const is_assert = p.current.kind == .identifier and std.mem.eql(u8, p.current.value_str, "assert");
    if (!is_with and !is_assert) return;
    _ = p.advance(); // consume `with` / `assert`
    // Expect `{ ... }` — skip the braced block, tolerating nested braces and
    // string literals (attribute values are string literals).
    if (!p.match(.left_brace)) {
        // Not a braces block — nothing to skip (allow `with` as a no-op).
        return;
    }
    var depth: u32 = 1;
    while (depth > 0 and !p.check(.eof) and !p.had_error) {
        if (p.check(.left_brace)) {
            depth += 1;
            _ = p.advance();
        } else if (p.check(.right_brace)) {
            depth -= 1;
            _ = p.advance();
        } else if (p.check(.string)) {
            _ = p.advance(); // skip string literal (attribute value)
        } else {
            _ = p.advance(); // skip any other token (keys, colons, commas)
        }
    }
}

pub fn parseImportDecl(p: *Parser) ?*Node {
    const start = p.current.start;
    // M16 Phase 3: `import(` (dynamic import) and `import.meta` are expressions,
    // not import declarations — route them through expression-statement parsing.
    const nxt = p.peekNext().kind;
    if (nxt == .left_paren or nxt == .dot) {
        return p.parseExprStmt();
    }
    _ = p.advance(); // import

    // import "mod";  (side-effect only)
    if (p.current.kind == .string) {
        const modname = p.current.value_str;
        _ = p.advance();
        skipImportAttributes(p); // `with { ... }` / `assert { ... }`
        p.consumeSemicolon();
        const req = p.mkRequire(modname) orelse return null;
        const stmt = p.makeNode(.expr_stmt, start, p.current.start, .{ .expr_stmt = req }) orelse return null;
        // M16 Phase 5: hoist side-effect imports to the bundle hoist point so
        // require() runs after __modules__ is initialised but before entry assertions.
        // Only hoist when the bundle marker has been seen (not in unit tests).
        if (p.hoist_point_seen) {
            p.hoisted_import_stmts.append(p.arena, stmt) catch {};
            return p.makeNode(.empty_stmt, start, p.current.start, .{ .empty_stmt = {} });
        }
        return stmt;
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
    skipImportAttributes(p); // `with { ... }` / `assert { ... }`
    p.consumeSemicolon();

    const tmp = std.fmt.allocPrint(p.arena, "__esm_{d}", .{start}) catch return null;
    var out = std.ArrayList(*Node){};
    const req = p.mkRequire(modname) orelse return null;
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
                const is_strict = parser_file.hasUseStrict(body);
                const fn_decl = p.makeNode(.function_decl, fn_start, p.current.start, .{
                    .function_decl = .{
                        .name = fn_name,
                        .params = parsed_params.params,
                        .param_defaults = parsed_params.param_defaults,
                        .rest_param = parsed_params.rest_param,
                        .body = body,
                        .is_generator = is_gen,
                        .is_async = is_async,
                        .is_strict = is_strict,
                    },
                }) orelse return null;
                const assign = p.mkExportAssign("default", p.mkIdent(fn_name) orelse return null) orelse return null;
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
                const is_strict = parser_file.hasUseStrict(body);
                const internal_name = if (is_gen) "__esm_dflt_gen__" else "__esm_dflt_fn__";
                const fn_decl = p.makeNode(.function_decl, fn_start, p.current.start, .{
                    .function_decl = .{
                        .name = internal_name,
                        .params = parsed_params.params,
                        .param_defaults = parsed_params.param_defaults,
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
            skipImportAttributes(p);
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
            skipImportAttributes(p);
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
            skipImportAttributes(p);
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
    if (decl.kind == .var_decl) {
        const vkind = decl.data.var_decl.kind;
        if (vkind == .var_ or !p.is_module or p.fn_nesting_depth > 0 or p.hoist_point_seen) {
            p.live_exports.append(p.arena, decl.data.var_decl.name) catch {};
        }
    }
    return decl;
}

pub fn parseStatement(p: *Parser) ?*Node {
    if (p.had_error) return null;
    // Phase 8: a statement starting with `await` is an await-expression statement,
    // not a label/identifier — route to expression parsing (which desugars await).
    if (p.current.kind == .identifier and std.mem.eql(u8, p.current.value_str, "await")) {
        return p.parseExprStmt();
    }
    // W2-async: `async function foo() {}` declaration. `async` is contextual
    // (a plain identifier); only treat it as a keyword when `function`
    // immediately follows on the same line.
    if (p.currentIsAsyncKw() and p.peekNext().kind == .kw_function and !p.peekNext().line_terminator_before) {
        _ = p.advance(); // consume `async`
        return p.parseFunctionDecl(true);
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
        .kw_while => p.parseWhileStmt(),
        .kw_do => p.parseDoWhileStmt(),
        .kw_for => p.parseForStmt(),
        .kw_return => p.parseReturnStmt(),
        .kw_break => p.parseBreakStmt(),
        .kw_continue => p.parseContinueStmt(),
        .kw_throw => p.parseThrowStmt(),
        .kw_try => p.parseTryStmt(),
        .kw_switch => p.parseSwitchStmt(),
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
    const items = body.items;
    return p.makeNode(.block_stmt, start, end, .{ .block_stmt = .{ .body = items } });
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
    // Multiple declarators: wrap in a block_stmt (not ideal, but works for eval)
    return p.makeNode(.block_stmt, start, p.current.start, .{ .block_stmt = .{ .body = decls.items } });
}

pub fn parseVarDeclarator(p: *Parser, kind: ast.VarKind) ?*Node {
    const start = p.current.start;
    if (p.check(.left_bracket) or p.check(.left_brace)) {
        return p.parseDestructuringDeclarator(kind, start);
    }
    const name_tok = if (p.check(.kw_of)) p.advance() else (p.expect(.identifier) orelse return null);
    const name: []const u8 = if (name_tok.kind == .kw_of) "of" else name_tok.value_str;
    var init_node: ?*Node = null;
    if (p.match(.eq)) {
        init_node = p.parseAssignmentExpr();
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

pub fn parseDestructuringDeclarator(p: *Parser, kind: ast.VarKind, start: u32) ?*Node {
    var names = std.ArrayList([]const u8){};
    const is_array = p.match(.left_bracket);
    if (is_array) {
        while (!p.check(.right_bracket) and !p.check(.eof) and !p.had_error) {
            if (p.check(.comma)) {
                _ = p.advance();
                continue;
            }
            const t = p.expect(.identifier) orelse return null;
            names.append(p.arena, t.value_str) catch return null;
            // Skip optional default value (= expr) — runtime falls back to undefined.
            if (p.match(.eq)) {
                _ = p.parseAssignmentExpr();
            }
            if (!p.match(.comma)) break;
        }
        _ = p.expect(.right_bracket) orelse return null;
    } else {
        _ = p.expect(.left_brace) orelse return null;
        while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
            const key = p.expect(.identifier) orelse return null;
            var bind_name = key.value_str;
            if (p.match(.colon)) {
                const alias = p.expect(.identifier) orelse return null;
                bind_name = alias.value_str;
            }
            names.append(p.arena, bind_name) catch return null;
            // Skip optional default value (= expr) — runtime falls back to undefined.
            if (p.match(.eq)) {
                _ = p.parseAssignmentExpr();
            }
            if (!p.match(.comma)) break;
        }
        _ = p.expect(.right_brace) orelse return null;
    }
    _ = p.expect(.eq) orelse return null;
    const rhs = p.parseAssignmentExpr() orelse return null;
    const tmp_name = std.fmt.allocPrint(p.arena, "__destruct_{d}", .{start}) catch return null;

    var body = std.ArrayList(*Node){};
    const tmp_decl = p.makeNode(.var_decl, start, p.current.start, .{
        .var_decl = .{ .kind = kind, .name = tmp_name, .init = rhs },
    }) orelse return null;
    body.append(p.arena, tmp_decl) catch return null;

    for (names.items, 0..) |n, i| {
        const tmp_id = p.makeNode(.identifier, start, start, .{ .identifier = tmp_name }) orelse return null;
        const access = if (is_array) blk: {
            const idx = p.makeNode(.number_literal, start, start, .{ .number_literal = @floatFromInt(i) }) orelse return null;
            break :blk p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = tmp_id, .property = idx, .computed = true },
            }) orelse return null;
        } else blk: {
            const prop = p.makeNode(.identifier, start, start, .{ .identifier = n }) orelse return null;
            break :blk p.makeNode(.member_expr, start, start, .{
                .member_expr = .{ .object = tmp_id, .property = prop, .computed = false },
            }) orelse return null;
        };
        const vd = p.makeNode(.var_decl, start, p.current.start, .{
            .var_decl = .{ .kind = kind, .name = n, .init = access },
        }) orelse return null;
        body.append(p.arena, vd) catch return null;
    }
    return p.makeNode(.block_stmt, start, p.current.start, .{
        .block_stmt = .{ .body = body.items },
    });
}

pub fn parseFunctionDecl(p: *Parser, is_async: bool) ?*Node {
    const start = p.current.start;
    _ = p.advance(); // consume 'function'
    const is_generator = p.match(.star);
    const name_tok = p.expect(.identifier) orelse return null;
    const name = name_tok.value_str;
    const parsed_params = p.parseFunctionParams() orelse return null;
    const prev_gen = p.in_generator_function;
    p.in_generator_function = is_generator;
    const body = p.parseFunctionBody() orelse {
        p.in_generator_function = prev_gen;
        return null;
    };
    p.in_generator_function = prev_gen;
    const is_strict = parser_file.hasUseStrict(body);
    return p.makeNode(.function_decl, start, p.current.start, .{
        .function_decl = .{
            .name = name,
            .params = parsed_params.params,
            .param_defaults = parsed_params.param_defaults,
            .rest_param = parsed_params.rest_param,
            .body = body,
            .is_generator = is_generator,
            .is_async = is_async,
            .is_strict = is_strict,
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
    // `for await (... of ...)`: consume 'await', treat as regular for-of.
    if (p.current.kind == .identifier and std.mem.eql(u8, p.current.value_str, "await")) {
        _ = p.advance();
    }
    _ = p.expect(.left_paren) orelse return null;

    // Detect for-in: for (var/let/const x in obj) or for (x in obj)
    if (p.check(.kw_var) or p.check(.kw_let) or p.check(.kw_const)) {
        // save position: for (var/let/const NAME in ...) is for-in
        const decl_kind: ast.VarKind = if (p.check(.kw_var)) .var_ else if (p.check(.kw_let)) .let else .const_;
        _ = p.advance(); // consume declaration keyword
        if (p.check(.left_bracket) or p.check(.left_brace)) {
            return p.parseForDestructuring(start, decl_kind);
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
                    .for_in_stmt = .{ .left = left, .right = right, .body = body, .iterate_values = true },
                });
            } else if (p.check(.eq) or p.check(.comma) or p.check(.semicolon)) {
                // Normal for loop: for (var/let/const name = ...; ...)
                // Handle initializer if present
                var init_val: ?*Node = null;
                if (p.match(.eq)) {
                    init_val = p.parseAssignmentExpr();
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
                    .block_stmt = .{ .body = decls.items },
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
            p.check(.right_paren))
        {
            _ = p.expect(.right_paren) orelse return null;
            const body = p.parseStatement() orelse return null;
            return p.makeNode(.for_in_stmt, start, p.current.start, .{
                .for_in_stmt = .{
                    .left = expr.data.binary_expr.left,
                    .right = expr.data.binary_expr.right,
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
                .for_in_stmt = .{ .left = expr, .right = right, .body = body, .iterate_values = true },
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

/// `for (let [a,b] of x) BODY` / `for (let {k} of x) BODY` (also for-in).
/// Desugar: `for (let __t of x) { let a = __t[0], b = __t[1]; BODY }`.
const ForBinding = struct { name: []const u8, key: ?[]const u8, index: usize };
pub fn parseForDestructuring(p: *Parser, start: u32, kind: ast.VarKind) ?*Node {
    var bindings = std.ArrayList(ForBinding){};
    const is_array = p.match(.left_bracket);
    if (is_array) {
        var idx: usize = 0;
        while (!p.check(.right_bracket) and !p.check(.eof) and !p.had_error) {
            if (p.check(.comma)) {
                _ = p.advance();
                idx += 1;
                continue;
            }
            const t = p.expect(.identifier) orelse return null;
            bindings.append(p.arena, .{ .name = t.value_str, .key = null, .index = idx }) catch return null;
            idx += 1;
            if (!p.match(.comma)) break;
        }
        _ = p.expect(.right_bracket) orelse return null;
    } else {
        _ = p.match(.left_brace);
        while (!p.check(.right_brace) and !p.check(.eof) and !p.had_error) {
            const key = p.expect(.identifier) orelse return null;
            var bind_name = key.value_str;
            if (p.match(.colon)) {
                const alias = p.expect(.identifier) orelse return null;
                bind_name = alias.value_str;
            }
            bindings.append(p.arena, .{ .name = bind_name, .key = key.value_str, .index = 0 }) catch return null;
            if (!p.match(.comma)) break;
        }
        _ = p.expect(.right_brace) orelse return null;
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
    // Build the per-iteration destructuring declarations + original body.
    var body_stmts = std.ArrayList(*Node){};
    for (bindings.items) |b| {
        const tmp_id = p.makeNode(.identifier, start, start, .{ .identifier = tmp_name }) orelse return null;
        const access = if (b.key) |k| blk: {
            const prop = p.makeNode(.identifier, start, start, .{ .identifier = k }) orelse return null;
            break :blk p.makeNode(.member_expr, start, start, .{ .member_expr = .{ .object = tmp_id, .property = prop, .computed = false } }) orelse return null;
        } else blk: {
            const idxn = p.makeNode(.number_literal, start, start, .{ .number_literal = @floatFromInt(b.index) }) orelse return null;
            break :blk p.makeNode(.member_expr, start, start, .{ .member_expr = .{ .object = tmp_id, .property = idxn, .computed = true } }) orelse return null;
        };
        const d = p.makeNode(.var_decl, start, start, .{ .var_decl = .{ .kind = kind, .name = b.name, .init = access } }) orelse return null;
        body_stmts.append(p.arena, d) catch return null;
    }
    body_stmts.append(p.arena, orig_body) catch return null;
    const new_body = p.makeNode(.block_stmt, start, p.current.start, .{ .block_stmt = .{ .body = body_stmts.items } }) orelse return null;
    const left = p.makeNode(.var_decl, start, start, .{ .var_decl = .{ .kind = kind, .name = tmp_name, .init = null } }) orelse return null;
    return p.makeNode(.for_in_stmt, start, p.current.start, .{
        .for_in_stmt = .{ .left = left, .right = right, .body = new_body, .iterate_values = iterate_values },
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
        _ = p.expect(.left_paren) orelse return null;
        const catch_param_name: []const u8 = if (p.check(.left_brace) or p.check(.left_bracket)) blk: {
            // Destructuring catch param: skip balanced pattern, bind exc to temp.
            const tmp = std.fmt.allocPrint(p.arena, "__catch_{d}", .{start}) catch return null;
            skipDestructuringPattern(p);
            break :blk tmp;
        } else blk: {
            const tok = p.expect(.identifier) orelse return null;
            break :blk tok.value_str;
        };
        _ = p.expect(.right_paren) orelse return null;
        const catch_body = p.parseBlock() orelse return null;
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
