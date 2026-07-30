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
