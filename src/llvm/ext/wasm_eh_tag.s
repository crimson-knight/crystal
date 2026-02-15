# Define the __cpp_exception tag with signature (i32)
# This satisfies wasm-ld without pulling in libcxxabi/libcxx runtime.
# Crystal uses LLVM's funclet-based exception handling which lowers to
# WASM try_table/catch/throw instructions. These reference the
# __cpp_exception tag, which must be defined in the linked binary.

.tagtype __cpp_exception i32

.globl __cpp_exception
__cpp_exception:
