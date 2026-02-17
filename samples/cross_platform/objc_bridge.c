// Crystal Cross-Platform Demo - ObjC Runtime Bridge
//
// Type-safe wrappers around objc_msgSend for ARM64.
// On ARM64, objc_msgSend is an assembly trampoline that requires
// properly-typed function pointer casts to route arguments through
// the correct register banks (x0-x7 for ints, d0-d7 for floats).
//
// Compile: clang -c objc_bridge.c -o objc_bridge.o

#include <objc/runtime.h>
#include <objc/message.h>

typedef struct { double x, y, width, height; } CGRect;

// --- Basic message sends ---

void* objc_send(void* self, SEL sel) {
    return ((void* (*)(void*, SEL))objc_msgSend)(self, sel);
}

void* objc_send_id(void* self, SEL sel, void* arg1) {
    return ((void* (*)(void*, SEL, void*))objc_msgSend)(self, sel, arg1);
}

void* objc_send_id_id(void* self, SEL sel, void* arg1, void* arg2) {
    return ((void* (*)(void*, SEL, void*, void*))objc_msgSend)(self, sel, arg1, arg2);
}

void objc_send_bool(void* self, SEL sel, int arg1) {
    ((void (*)(void*, SEL, int))objc_msgSend)(self, sel, arg1);
}

void* objc_send_long(void* self, SEL sel, long arg1) {
    return ((void* (*)(void*, SEL, long))objc_msgSend)(self, sel, arg1);
}

void* objc_send_int(void* self, SEL sel, int arg1) {
    return ((void* (*)(void*, SEL, int))objc_msgSend)(self, sel, arg1);
}

void objc_send_void_id(void* self, SEL sel, void* arg1) {
    ((void (*)(void*, SEL, void*))objc_msgSend)(self, sel, arg1);
}

void objc_send_sel(void* self, SEL sel, SEL arg1) {
    ((void (*)(void*, SEL, SEL))objc_msgSend)(self, sel, arg1);
}

// --- Float/double register sends ---

void objc_send_double(void* self, SEL sel, double arg1) {
    ((void (*)(void*, SEL, double))objc_msgSend)(self, sel, arg1);
}

void* objc_send_double_ret_id(void* self, SEL sel, double arg1) {
    return ((void* (*)(void*, SEL, double))objc_msgSend)(self, sel, arg1);
}

// --- CGRect sends ---

void* objc_send_rect(void* self, SEL sel, CGRect rect) {
    return ((void* (*)(void*, SEL, CGRect))objc_msgSend)(self, sel, rect);
}

void* objc_send_rect_ulong_ulong_bool(void* self, SEL sel, CGRect rect,
                                       unsigned long a, unsigned long b, int c) {
    return ((void* (*)(void*, SEL, CGRect, unsigned long, unsigned long, int))objc_msgSend)(
        self, sel, rect, a, b, c);
}

// --- NSString helper ---

void* nsstring_from_cstr(const char* s) {
    return ((void* (*)(void*, SEL, const char*))objc_msgSend)(
        (void*)objc_getClass("NSString"),
        sel_registerName("stringWithUTF8String:"), s);
}

// --- Frame and subview helpers ---

CGRect objc_get_frame(void* self) {
    return ((CGRect (*)(void*, SEL))objc_msgSend)(self, sel_registerName("frame"));
}

void objc_add_subview(void* parent, void* child) {
    ((void (*)(void*, SEL, void*))objc_msgSend)(
        parent, sel_registerName("addSubview:"), child);
}

void objc_set_autoresize(void* view, unsigned long mask) {
    ((void (*)(void*, SEL, unsigned long))objc_msgSend)(
        view, sel_registerName("setAutoresizingMask:"), mask);
}
