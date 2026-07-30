/* SPDX-License-Identifier: Apache-2.0
 * C embedding example — built and run by `zig build example-capi`.
 * Exercises eval, number/string results, exceptions, parse errors, limits.
 */
#include <stdio.h>
#include <string.h>
#include "jsz.h"

static int failures = 0;

static void expect(int cond, const char *what) {
    if (!cond) {
        fprintf(stderr, "FAIL: %s\n", what);
        failures++;
    }
}

/* Native callbacks exposed to JS. */

static int host_add(jsz_context *ctx, void *userdata,
                    const jsz_value *args, size_t argc, jsz_value *result) {
    int *calls = (int *)userdata;
    (*calls)++;
    double a = argc > 0 ? jsz_as_number(args[0]) : 0;
    double b = argc > 1 ? jsz_as_number(args[1]) : 0;
    *result = jsz_number(ctx, a + b);
    return 0;
}

static int host_greet(jsz_context *ctx, void *userdata,
                      const jsz_value *args, size_t argc, jsz_value *result) {
    (void)userdata;
    char buf[128];
    const char *who = (argc > 0 && jsz_is_string(args[0]))
        ? jsz_as_string(ctx, args[0]) : "nobody";
    snprintf(buf, sizeof buf, "hello %s", who);
    *result = jsz_string(ctx, buf);
    return 0;
}

static int host_fail(jsz_context *ctx, void *userdata,
                     const jsz_value *args, size_t argc, jsz_value *result) {
    (void)ctx; (void)userdata; (void)args; (void)argc; (void)result;
    return 42; /* -> JS exception "native function failed (code 42)" */
}

int main(void) {
    printf("jsz %s (C API)\n", jsz_version());

    jsz_isolate *iso = jsz_isolate_new();
    expect(iso != NULL, "isolate_new");
    jsz_context *ctx = jsz_context_new(iso);
    expect(ctx != NULL, "context_new");

    /* Numbers */
    expect(jsz_eval(ctx, "6 * 7", NULL) == JSZ_OK, "eval 6*7 ok");
    double n = 0;
    expect(jsz_last_number(ctx, &n) && n == 42.0, "42 as number");
    expect(strcmp(jsz_last_string(ctx), "42") == 0, "42 as string");

    /* State persists across evals in one context */
    expect(jsz_eval(ctx, "var greet = function (w) { return 'hello ' + w; };",
                    "setup.js") == JSZ_OK, "define greet");
    expect(jsz_eval(ctx, "greet('from C')", NULL) == JSZ_OK, "call greet");
    expect(strcmp(jsz_last_string(ctx), "hello from C") == 0, "greet result");
    expect(!jsz_last_number(ctx, &n), "string result is not a number");

    /* Uncaught exception */
    expect(jsz_eval(ctx, "null.x", NULL) == JSZ_EXCEPTION, "null.x throws");
    expect(jsz_last_string(ctx) != NULL, "exception message present");

    /* Parse error */
    expect(jsz_eval(ctx, "function (", NULL) == JSZ_PARSE_ERROR, "parse error");

    /* Gas limit stops a runaway loop as an exception, not a hang/crash */
    jsz_context_set_limits(ctx, 0, 1000000, 0);
    expect(jsz_eval(ctx, "while (true) {}", NULL) == JSZ_EXCEPTION,
           "gas limit interrupts infinite loop");
    jsz_context_set_limits(ctx, 0, 0, 0);

    /* Engine still healthy after the interrupt */
    expect(jsz_eval(ctx, "[1,2,3].map(function(x){return x*2}).join(',')",
                    NULL) == JSZ_OK, "eval after interrupt");
    expect(strcmp(jsz_last_string(ctx), "2,4,6") == 0, "map result");

    /* Native functions: C callbacks callable from JS */
    int add_calls = 0;
    expect(jsz_register_function(ctx, "hostAdd", host_add, &add_calls) == JSZ_OK,
           "register hostAdd");
    expect(jsz_register_function(ctx, "hostGreet", host_greet, NULL) == JSZ_OK,
           "register hostGreet");
    expect(jsz_register_function(ctx, "hostFail", host_fail, NULL) == JSZ_OK,
           "register hostFail");

    expect(jsz_eval(ctx, "hostAdd(2, 3) + hostAdd(10, 20)", NULL) == JSZ_OK,
           "call hostAdd");
    double n2 = 0;
    expect(jsz_last_number(ctx, &n2) && n2 == 35.0, "hostAdd result 35");
    expect(add_calls == 2, "userdata counter saw 2 calls");

    expect(jsz_eval(ctx, "hostGreet('C world')", NULL) == JSZ_OK, "call hostGreet");
    expect(strcmp(jsz_last_string(ctx), "hello C world") == 0, "hostGreet result");

    expect(jsz_eval(ctx,
        "var caught = '';"
        "try { hostFail(); } catch (e) { caught = '' + e; }"
        "caught",
        NULL) == JSZ_OK, "hostFail caught in JS");
    expect(strstr(jsz_last_string(ctx), "code 42") != NULL,
           "hostFail message carries code");

    /* Native fn result feeding JS logic + undefined return */
    expect(jsz_eval(ctx,
        "[1,2,3].map(function (x) { return hostAdd(x, 100); }).join(',')",
        NULL) == JSZ_OK, "hostAdd inside map");
    expect(strcmp(jsz_last_string(ctx), "101,102,103") == 0, "map over native fn");
    expect(add_calls == 5, "counter followed the map calls");

    /* Objects and arrays built from C */
    jsz_value obj = jsz_object_new(ctx);
    expect(jsz_is_object(obj) && !jsz_is_array(obj), "object_new");
    expect(jsz_set(ctx, obj, "name", jsz_string(ctx, "widget")) == JSZ_OK, "set name");
    expect(jsz_set(ctx, obj, "count", jsz_number(ctx, 3)) == JSZ_OK, "set count");
    expect(strcmp(jsz_as_string(ctx, jsz_get(ctx, obj, "name")), "widget") == 0, "get name");
    expect(jsz_typeof(jsz_get(ctx, obj, "count")) == JSZ_TYPE_NUMBER, "typeof count");
    expect(jsz_is_undefined(jsz_get(ctx, obj, "missing")), "absent prop undefined");

    jsz_value arr = jsz_array_new(ctx);
    expect(jsz_is_array(arr), "array_new");
    for (uint32_t i = 0; i < 4; i++)
        expect(jsz_set_index(ctx, arr, i, jsz_number(ctx, i * 10)) == JSZ_OK, "set_index");
    expect(jsz_array_length(ctx, arr) == 4, "array length 4");
    expect(jsz_as_number(jsz_get_index(ctx, arr, 2)) == 20.0, "get_index 2");

    /* Cross the boundary: C-built data visible to JS, protected across GC */
    expect(jsz_set(ctx, obj, "items", arr) == JSZ_OK, "attach array to object");
    expect(jsz_protect(ctx, obj) == JSZ_OK, "protect obj");
    jsz_gc(ctx); /* obj+arr must survive: only C (and the root) reference them */
    expect(jsz_set_global(ctx, "widget", obj) == JSZ_OK, "set_global widget");
    expect(jsz_eval(ctx,
        "widget.name + ':' + widget.count + ':' + widget.items.join('-')",
        NULL) == JSZ_OK, "JS reads C-built object");
    expect(strcmp(jsz_last_string(ctx), "widget:3:0-10-20-30") == 0, "widget contents");
    jsz_unprotect(ctx, obj);

    /* get_global + last_value */
    expect(jsz_eval(ctx, "({ answer: 42 })", NULL) == JSZ_OK, "eval object literal");
    jsz_value ans = jsz_last_value(ctx);
    expect(jsz_is_object(ans), "last_value is object");
    expect(jsz_as_number(jsz_get(ctx, ans, "answer")) == 42.0, "last_value.answer");
    expect(jsz_is_function(jsz_get_global(ctx, "hostAdd")), "get_global finds native fn");

    /* Call a JS closure from C */
    expect(jsz_eval(ctx,
        "var mkAdder = function (base) { return function (x) { return base + x; } };"
        "var add7 = mkAdder(7); 0",
        NULL) == JSZ_OK, "define closure");
    jsz_value add7 = jsz_get_global(ctx, "add7");
    expect(jsz_is_function(add7), "add7 is function");
    jsz_value cargs[1] = { jsz_number(ctx, 35) };
    jsz_value cres = jsz_undefined(ctx);
    expect(jsz_call(ctx, add7, cargs, 1, &cres) == JSZ_OK, "jsz_call ok");
    expect(jsz_as_number(cres) == 42.0, "closure result 42");
    jsz_value bad = jsz_get_global(ctx, "hostFail");
    expect(jsz_call(ctx, bad, NULL, 0, NULL) == JSZ_EXCEPTION, "jsz_call exception");

    /* JSON bridge */
    const char *enc = jsz_json_encode(ctx, ans);
    expect(enc != NULL && strcmp(enc, "{\"answer\":42}") == 0, "json_encode");
    jsz_value dec = jsz_json_decode(ctx, "{\"a\":[1,2,3],\"b\":\"x\"}");
    expect(jsz_is_object(dec), "json_decode object");
    expect(jsz_array_length(ctx, jsz_get(ctx, dec, "a")) == 3, "decoded array len");
    expect(jsz_is_undefined(jsz_json_decode(ctx, "{oops")), "json_decode bad input");

    /* ES module eval */
    expect(jsz_eval_module(ctx,
        "const three = 3; export default three;", "mod.js") == JSZ_OK,
        "eval_module");

    jsz_gc(ctx);

    jsz_context_free(ctx);
    jsz_isolate_free(iso);

    if (failures == 0) {
        printf("C API example: all checks passed\n");
        return 0;
    }
    fprintf(stderr, "C API example: %d failures\n", failures);
    return 1;
}
