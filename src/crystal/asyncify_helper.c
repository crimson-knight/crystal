/*
 * crystal_asyncify_helper.c - Asyncify runtime wrappers for Crystal fiber support
 *
 * This file provides wrapper functions that Crystal code calls to interact
 * with the asyncify runtime. The wrappers are compiled to a standalone .wasm
 * module and merged into the main module AFTER the asyncify pass, which
 * avoids name collisions between the helper's imports and the asyncify
 * pass's generated function definitions.
 *
 * Architecture:
 *   1. Crystal compiles to WASM with crystal_* functions as unresolved imports
 *   2. wasm-opt --asyncify adds asyncify_* function definitions
 *   3. wasm-merge combines main module + this helper, resolving:
 *      - main's crystal_* imports → this helper's crystal_* exports
 *      - this helper's asyncify_* imports → main's asyncify_* exports
 *
 * The crystal_asyncify_switch function is the key switch point:
 *   During unwind: calls asyncify_start_unwind to begin unwinding
 *   During rewind: calls asyncify_stop_rewind to terminate rewinding
 */

/* Import asyncify runtime functions from the main Crystal module.
 * These are provided by wasm-opt's asyncify pass as module exports.
 * We use import_module "crystal_main" so wasm-merge can resolve them
 * against the main module's exports. */
__attribute__((import_module("crystal_main"), import_name("asyncify_start_unwind")))
extern void asyncify_start_unwind(void *data);

__attribute__((import_module("crystal_main"), import_name("asyncify_stop_unwind")))
extern void asyncify_stop_unwind(void);

__attribute__((import_module("crystal_main"), import_name("asyncify_start_rewind")))
extern void asyncify_start_rewind(void *data);

__attribute__((import_module("crystal_main"), import_name("asyncify_stop_rewind")))
extern void asyncify_stop_rewind(void);

__attribute__((import_module("crystal_main"), import_name("asyncify_get_state")))
extern int asyncify_get_state(void);

/*
 * Crystal fiber switch point.
 * Called from Crystal's swapcontext (which IS asyncified).
 * This function is NOT asyncified (merged after the asyncify pass).
 *
 * During unwind: starts the asyncify unwind with the given data buffer.
 * During rewind: stops the asyncify rewind so execution resumes normally.
 */
__attribute__((export_name("crystal_asyncify_switch")))
void crystal_asyncify_switch(void *unwind_data) {
    int state = asyncify_get_state();
    if (state == 2) {
        /* State is REWINDING - we've been replayed to the suspension point.
         * Stop the rewind so the caller resumes normally. */
        asyncify_stop_rewind();
        return;
    }
    /* State is NORMAL - initiate the unwind to suspend this fiber. */
    asyncify_start_unwind(unwind_data);
}

/* Wrapper for asyncify_stop_unwind, called from _start after unwind completes */
__attribute__((export_name("crystal_stop_unwind")))
void crystal_stop_unwind(void) {
    asyncify_stop_unwind();
}

/* Wrapper for asyncify_start_rewind, called from _start to resume a fiber */
__attribute__((export_name("crystal_start_rewind")))
void crystal_start_rewind(void *data) {
    asyncify_start_rewind(data);
}

/* Wrapper for asyncify_stop_rewind */
__attribute__((export_name("crystal_stop_rewind")))
void crystal_stop_rewind(void) {
    asyncify_stop_rewind();
}

/* Wrapper for asyncify_get_state */
__attribute__((export_name("crystal_get_state")))
int crystal_get_state(void) {
    return asyncify_get_state();
}
