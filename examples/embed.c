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
