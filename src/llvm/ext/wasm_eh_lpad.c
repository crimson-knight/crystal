/* __wasm_lpad_context is used by LLVM's WasmEHPrepare pass to communicate
 * exception handling state (landing pad index, LSDA pointer, type selector)
 * between the catch site and the personality function during stack unwinding.
 * Crystal provides this as a simple global struct, compiled for wasm32-wasi. */
struct wasm_lpad_context_t {
    int lpad_index;
    void *lsda;
    int selector;
};
struct wasm_lpad_context_t __wasm_lpad_context = {0, 0, 0};
