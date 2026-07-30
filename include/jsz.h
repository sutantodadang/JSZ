/* SPDX-License-Identifier: Apache-2.0
 *
 * jsz C API — embed the jsz JavaScript engine from C (or any language with
 * a C FFI: Rust, Go, Python ctypes, ...).
 *
 * Quick start (see examples/embed.c for a runnable version):
 *
 *   jsz_isolate *iso = jsz_isolate_new();
 *   jsz_context *ctx = jsz_context_new(iso);
 *   if (jsz_eval(ctx, "6 * 7", NULL) == JSZ_OK)
 *       printf("%s\n", jsz_last_string(ctx));   // "42"
 *   jsz_context_free(ctx);
 *   jsz_isolate_free(iso);
 *
 * Memory contract:
 *   - jsz_eval copies the source; the caller may free it immediately.
 *   - The pointer from jsz_last_string is owned by the context and is valid
 *     until the next jsz_eval on that context (or jsz_context_free).
 *   - Free every handle exactly once with its matching _free function.
 *
 * Thread contract: an isolate and its contexts must be used from one thread
 * at a time (same rule as the Zig API).
 */
#ifndef JSZ_H
#define JSZ_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct jsz_isolate jsz_isolate;
typedef struct jsz_context jsz_context;

/* jsz_eval status codes. */
enum {
    JSZ_OK = 0,          /* result available via jsz_last_string/number */
    JSZ_EXCEPTION = 1,   /* uncaught JS exception; message via jsz_last_string */
    JSZ_PARSE_ERROR = 2, /* SyntaxError; message via jsz_last_string */
    JSZ_ERR_NOMEM = 3    /* allocation failed or NULL argument */
};

/* Engine version string, e.g. "0.1.0". Static storage. */
const char *jsz_version(void);

/* Isolate: one JS heap + GC. NULL on allocation failure. */
jsz_isolate *jsz_isolate_new(void);
void jsz_isolate_free(jsz_isolate *iso);

/* Context: one global environment inside an isolate. */
jsz_context *jsz_context_new(jsz_isolate *iso);
void jsz_context_free(jsz_context *ctx);

/* Resource limits for untrusted code; 0 = unlimited. Limit breaches surface
 * as JSZ_EXCEPTION, never a crash. gas caps executed bytecode instructions,
 * time_ms caps wall-clock, mem_bytes caps live heap bytes. */
void jsz_context_set_limits(jsz_context *ctx, size_t mem_bytes,
                            uint64_t gas, uint64_t time_ms);

/* Evaluate NUL-terminated source. name is used in stack traces (NULL →
 * "<eval>"). Returns a JSZ_* status code. */
int jsz_eval(jsz_context *ctx, const char *src, const char *name);

/* Display string of the last result (JSZ_OK) or error message (JSZ_EXCEPTION
 * / JSZ_PARSE_ERROR). Owned by the context — valid until the next jsz_eval.
 * NULL if nothing has been evaluated. */
const char *jsz_last_string(jsz_context *ctx);

/* If the last result was a JS number, writes it to out and returns true. */
bool jsz_last_number(jsz_context *ctx, double *out);

/* Force a full garbage-collection cycle. */
void jsz_gc(jsz_context *ctx);

/* ---------------------------------------------------------- native fns --- */

/* Value handle: a pointer-boxed engine value. bits == 0 means undefined.
 * Handles from jsz_number/jsz_string/... stay valid for the context's
 * lifetime; handles received as callback arguments are only guaranteed for
 * the duration of that callback. */
typedef struct { uint64_t bits; } jsz_value;

/* A C function callable from JS.
 *   ctx      — the calling context (usable for jsz_number/jsz_string/...)
 *   userdata — the pointer given to jsz_register_function, verbatim
 *   args     — argc call arguments (may be NULL when argc == 0)
 *   result   — write the return value here; leave untouched for undefined
 * Return 0 for a normal return. A nonzero return throws a JS exception
 * "native function failed (code N)" that JS can catch. Re-entrancy (calling
 * jsz_eval from inside a callback) is supported. */
typedef int (*jsz_native_fn)(jsz_context *ctx, void *userdata,
                             const jsz_value *args, size_t argc,
                             jsz_value *result);

/* Register `fn` as a global JS function named `name`. May be called before
 * or between evals. Returns JSZ_OK or JSZ_ERR_NOMEM. */
int jsz_register_function(jsz_context *ctx, const char *name,
                          jsz_native_fn fn, void *userdata);

/* ------------------------------------------------------------ value API --- */

/* Constructors (context-owned; the string is copied). */
jsz_value jsz_number(jsz_context *ctx, double n);
jsz_value jsz_string(jsz_context *ctx, const char *s);
jsz_value jsz_boolean(jsz_context *ctx, bool b);
jsz_value jsz_undefined(jsz_context *ctx);
jsz_value jsz_null(jsz_context *ctx);

/* Inspection. */
bool jsz_is_number(jsz_value v);
bool jsz_is_string(jsz_value v);
bool jsz_is_bool(jsz_value v);
bool jsz_is_undefined(jsz_value v);
double jsz_as_number(jsz_value v);            /* 0 for non-numbers */
bool jsz_as_bool(jsz_value v);
/* Display string of any value (ToString-for-printing). Owned by the context;
 * valid until jsz_context_free. NULL on failure. */
const char *jsz_as_string(jsz_context *ctx, jsz_value v);

#ifdef __cplusplus
}
#endif

#endif /* JSZ_H */
