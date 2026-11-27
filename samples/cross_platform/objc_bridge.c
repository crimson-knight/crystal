// Crystal Cross-Platform Demo - ObjC Runtime Bridge
//
// Type-safe wrappers around objc_msgSend for ARM64 (AArch64).
//
// WHY THIS FILE EXISTS:
//   On ARM64, objc_msgSend is a raw assembly trampoline. It does NOT know
//   the types of the method's arguments or return value. Instead, the
//   CALLER must set up the registers according to the ARM64 calling
//   convention (AAPCS64) before branching into objc_msgSend:
//
//     - Integer/pointer arguments: x0, x1, x2, x3, x4, x5, x6, x7
//       (x0 = self, x1 = _cmd, x2+ = method args)
//     - Float/double arguments:   d0, d1, d2, d3, d4, d5, d6, d7
//       (independent bank -- floats do NOT consume integer registers)
//     - Return value: x0 (integer/pointer) or d0 (float/double),
//       or d0-d3 for Homogeneous Floating-point Aggregates (HFA) like CGRect
//
//   If you call objc_msgSend through a function pointer cast that has
//   fewer double parameters than the actual ObjC method expects, the
//   compiler will NOT load values into the higher d-registers. Those
//   registers will contain whatever garbage was left from prior computation.
//
//   Example of the bug this fixes:
//     +[NSColor colorWithRed:green:blue:alpha:] needs 4 doubles in d0-d3.
//     If you cast objc_msgSend as f(id, SEL, double) and call it with
//     one double, only d0 gets the red value. d1 (green), d2 (blue), and
//     d3 (alpha) are UNDEFINED -- you get a random color, or a crash if
//     alpha happens to be 0.0 (invisible) or NaN.
//
// RULE: Every unique combination of (return_type, parameter_types) that
//       passes through objc_msgSend MUST have its own correctly-typed
//       wrapper function.
//
// NAMING CONVENTION:
//   objc_send                          -> (id, SEL) -> id
//   objc_send_{arg_types}              -> (id, SEL, args...) -> void
//   objc_send_{arg_types}_ret_{rtype}  -> (id, SEL, args...) -> rtype
//
//   Arg type codes:
//     id   = void* (object pointer)     d    = double (CGFloat)
//     bool = int (BOOL)                 long = long (NSInteger)
//     ulong = unsigned long (NSUInteger) sel  = SEL
//     rect = CGRect (4 doubles, HFA)    point = CGPoint (2 doubles, HFA)
//     size = CGSize (2 doubles, HFA)    cstr = const char*
//
// Compile: clang -c objc_bridge.c -o objc_bridge.o -arch arm64
//          (or just: clang -c objc_bridge.c -o objc_bridge.o)

#include <objc/runtime.h>
#include <objc/message.h>

// --- Geometry types (match CoreGraphics layout) ---
// These are Homogeneous Floating-point Aggregates (HFA) on ARM64:
// CGPoint: 2 doubles -> passed/returned in d0,d1
// CGSize:  2 doubles -> passed/returned in d0,d1 (or d2,d3 if second HFA arg)
// CGRect:  4 doubles -> passed/returned in d0,d1,d2,d3

typedef struct { double x, y; } CGPoint;
typedef struct { double width, height; } CGSize;
typedef struct { CGPoint origin; CGSize size; } CGRect;

// ============================================================================
// Section 1: Basic message sends (integer/pointer args only)
// ============================================================================

// (id, SEL) -> id
// Selectors: alloc, init, new, autorelease, retain, release, copy,
//   sharedApplication, contentView, window, superview, whiteColor,
//   blackColor, clearColor, redColor, blueColor, run, class, description
void* objc_send(void* self, SEL sel) {
    return ((void* (*)(void*, SEL))objc_msgSend)(self, sel);
}

// (id, SEL, id) -> id
// Selectors: setTitle:, setStringValue:, setFont:, setTextColor:,
//   setDelegate:, setTarget:, makeKeyAndOrderFront:, initWithContentView:,
//   objectForKey:, valueForKey:, performSelector:
void* objc_send_id(void* self, SEL sel, void* arg1) {
    return ((void* (*)(void*, SEL, void*))objc_msgSend)(self, sel, arg1);
}

// (id, SEL, id, id) -> id
// Selectors: initWithFrame:style: (UIKit), setValue:forKey:,
//   dictionaryWithObject:forKey:
void* objc_send_id_id(void* self, SEL sel, void* arg1, void* arg2) {
    return ((void* (*)(void*, SEL, void*, void*))objc_msgSend)(self, sel, arg1, arg2);
}

// (id, SEL, id, id, id) -> id
// Selectors: initWithTitle:action:keyEquivalent: (NSMenuItem)
void* objc_send_id_id_id(void* self, SEL sel, void* arg1, void* arg2, void* arg3) {
    return ((void* (*)(void*, SEL, void*, void*, void*))objc_msgSend)(self, sel, arg1, arg2, arg3);
}

// (id, SEL, int) -> void
// Selectors: setBezeled:, setDrawsBackground:, setEditable:, setSelectable:,
//   activateIgnoringOtherApps:, setHidden:, setEnabled:, setTranslatesAutoresizingMaskIntoConstraints:
void objc_send_bool(void* self, SEL sel, int arg1) {
    ((void (*)(void*, SEL, int))objc_msgSend)(self, sel, arg1);
}

// (id, SEL, long) -> id
// Selectors: setActivationPolicy:, setMaterial:, setBlendingMode:,
//   setState:, setBezelStyle:, setAlignment:, setLineBreakMode:,
//   setTag:, viewWithTag:, setNumberOfLines:, setContentHuggingPriority:
void* objc_send_long(void* self, SEL sel, long arg1) {
    return ((void* (*)(void*, SEL, long))objc_msgSend)(self, sel, arg1);
}

// (id, SEL, unsigned long) -> id
// Selectors: objectAtIndex:, setAutoresizingMask: (when returning id)
void* objc_send_ulong(void* self, SEL sel, unsigned long arg1) {
    return ((void* (*)(void*, SEL, unsigned long))objc_msgSend)(self, sel, arg1);
}

// (id, SEL, int) -> id
// Selectors: numberWithInt:, initWithInt:
void* objc_send_int(void* self, SEL sel, int arg1) {
    return ((void* (*)(void*, SEL, int))objc_msgSend)(self, sel, arg1);
}

// (id, SEL, id) -> void
// Selectors: addSubview:, removeFromSuperview doesn't take arg but
//   addObject:, removeObject:, setContentView:, orderOut:
void objc_send_void_id(void* self, SEL sel, void* arg1) {
    ((void (*)(void*, SEL, void*))objc_msgSend)(self, sel, arg1);
}

// (id, SEL, SEL) -> void
// Selectors: setAction:, setDoubleAction:, performSelector:
void objc_send_sel(void* self, SEL sel, SEL arg1) {
    ((void (*)(void*, SEL, SEL))objc_msgSend)(self, sel, arg1);
}

// (id, SEL, id, SEL) -> void
// Selectors: addTarget:action: (partial -- UIKit uses addTarget:action:forControlEvents:)
void objc_send_id_sel(void* self, SEL sel, void* arg1, SEL arg2) {
    ((void (*)(void*, SEL, void*, SEL))objc_msgSend)(self, sel, arg1, arg2);
}

// (id, SEL, id, SEL, unsigned long) -> void
// Selectors: addTarget:action:forControlEvents: (UIKit UIControl)
void objc_send_id_sel_ulong(void* self, SEL sel, void* arg1, SEL arg2, unsigned long arg3) {
    ((void (*)(void*, SEL, void*, SEL, unsigned long))objc_msgSend)(self, sel, arg1, arg2, arg3);
}

// (id, SEL, id, long) -> id
// Selectors: insertObject:atIndex:, constraintEqualToAnchor:constant: (mix types)
void* objc_send_id_long(void* self, SEL sel, void* arg1, long arg2) {
    return ((void* (*)(void*, SEL, void*, long))objc_msgSend)(self, sel, arg1, arg2);
}

// ============================================================================
// Section 2: Double/float register sends
//
// ARM64 float register allocation:
//   Each double argument occupies one d-register (d0, d1, d2, ...).
//   Integer arguments are INDEPENDENT -- they go in x-registers.
//   You MUST have exactly the right number of double params in the cast.
// ============================================================================

// (id, SEL, double) -> void
// Selectors: setAlphaValue:, setCornerRadius:, setLineWidth:
void objc_send_1d(void* self, SEL sel, double arg1) {
    ((void (*)(void*, SEL, double))objc_msgSend)(self, sel, arg1);
}

// (id, SEL, double) -> id
// Selectors: boldSystemFontOfSize:, systemFontOfSize:, labelFontOfSize:,
//   titleFontOfSize:, menuFontOfSize:, messageFontOfSize:,
//   fontWithSize: (instance method), userFontOfSize:,
//   userFixedPitchFontOfSize:
void* objc_send_1d_ret_id(void* self, SEL sel, double d0) {
    return ((void* (*)(void*, SEL, double))objc_msgSend)(self, sel, d0);
}

// (id, SEL, double, double) -> id
// Selectors:
//   +[NSColor colorWithWhite:alpha:]                  (white in d0, alpha in d1)
//   +[NSFont monospacedSystemFontOfSize:weight:]      (size in d0, weight in d1)
//   +[NSFont monospacedDigitSystemFontOfSize:weight:] (size in d0, weight in d1)
//   +[NSFont systemFontOfSize:weight:]                (size in d0, weight in d1)
void* objc_send_2d_ret_id(void* self, SEL sel, double d0, double d1) {
    return ((void* (*)(void*, SEL, double, double))objc_msgSend)(self, sel, d0, d1);
}

// (id, SEL, double, double, double) -> id
// Selectors:
//   +[NSColor colorWithHue:saturation:brightness:]  (no alpha variant -- rare)
//   +[NSColor colorWithWhite:alpha:] -- no, that's 2d
//   (reserved for 3-double methods)
void* objc_send_3d_ret_id(void* self, SEL sel, double d0, double d1, double d2) {
    return ((void* (*)(void*, SEL, double, double, double))objc_msgSend)(self, sel, d0, d1, d2);
}

// (id, SEL, double, double, double, double) -> id
// Selectors:
//   +[NSColor colorWithRed:green:blue:alpha:]             (r,g,b,a in d0-d3)
//   +[NSColor colorWithHue:saturation:brightness:alpha:]  (h,s,b,a in d0-d3)
//   +[NSColor colorWithSRGBRed:green:blue:alpha:]         (r,g,b,a in d0-d3)
//   +[NSColor colorWithDeviceRed:green:blue:alpha:]       (r,g,b,a in d0-d3)
//   +[NSColor colorWithCalibratedRed:green:blue:alpha:]   (r,g,b,a in d0-d3)
//   +[NSColor colorWithDeviceHue:saturation:brightness:alpha:]
//   +[UIColor colorWithRed:green:blue:alpha:]             (UIKit)
void* objc_send_4d_ret_id(void* self, SEL sel, double d0, double d1, double d2, double d3) {
    return ((void* (*)(void*, SEL, double, double, double, double))objc_msgSend)(
        self, sel, d0, d1, d2, d3);
}

// (id, SEL, double, double) -> void
// Selectors: setFrameSize: via CGSize (but CGSize is HFA, see section 3)
//   This is for two independent double args, not an HFA struct.
void objc_send_2d(void* self, SEL sel, double d0, double d1) {
    ((void (*)(void*, SEL, double, double))objc_msgSend)(self, sel, d0, d1);
}

// (id, SEL, id, double) -> id
// Selectors: fontWithName:size: (NSString* in x2, CGFloat in d0)
//   Note: on ARM64 the id goes in x2, the double goes in d0 -- they use
//   SEPARATE register banks, so this is NOT the same as (id, SEL, double, id).
void* objc_send_id_1d_ret_id(void* self, SEL sel, void* arg1, double d0) {
    return ((void* (*)(void*, SEL, void*, double))objc_msgSend)(self, sel, arg1, d0);
}

// ============================================================================
// Section 3: CGRect / CGPoint / CGSize sends (HFA arguments)
//
// On ARM64, CGRect (4 doubles) is a Homogeneous Floating-point Aggregate.
// It is passed in d0-d3 (NOT on the stack, NOT in x-registers).
// CGPoint (2 doubles) goes in d0-d1.  CGSize (2 doubles) in d0-d1.
//
// For RETURN values: CGRect returns in d0-d3, CGPoint in d0-d1, CGSize in d0-d1.
// This is regular objc_msgSend, NOT objc_msgSend_stret (stret is x86_64 only
// for structs; ARM64 uses HFA registers for <= 4 float members).
// ============================================================================

// (id, SEL, CGRect) -> id
// Selectors: initWithFrame: (NSView, NSControl, NSTextField, NSButton,
//   NSVisualEffectView, UIView, etc.)
void* objc_send_rect(void* self, SEL sel, CGRect rect) {
    return ((void* (*)(void*, SEL, CGRect))objc_msgSend)(self, sel, rect);
}

// (id, SEL, CGRect) -> void
// Selectors: setFrame:, setNeedsDisplayInRect:, scrollRectToVisible:
void objc_send_rect_void(void* self, SEL sel, CGRect rect) {
    ((void (*)(void*, SEL, CGRect))objc_msgSend)(self, sel, rect);
}

// (id, SEL, CGRect, unsigned long, unsigned long, int) -> id
// Selectors: initWithContentRect:styleMask:backing:defer:
//   CGRect in d0-d3, styleMask in x2, backing in x3, defer in x4
void* objc_send_rect_ulong_ulong_bool(void* self, SEL sel, CGRect rect,
                                       unsigned long a, unsigned long b, int c) {
    return ((void* (*)(void*, SEL, CGRect, unsigned long, unsigned long, int))objc_msgSend)(
        self, sel, rect, a, b, c);
}

// (id, SEL, CGPoint) -> id
// Selectors: initWithLocation: (hypothetical), hitTest:
void* objc_send_point(void* self, SEL sel, CGPoint point) {
    return ((void* (*)(void*, SEL, CGPoint))objc_msgSend)(self, sel, point);
}

// (id, SEL, CGPoint) -> void
// Selectors: setFrameOrigin:, setContentOffset: (UIKit)
void objc_send_point_void(void* self, SEL sel, CGPoint point) {
    ((void (*)(void*, SEL, CGPoint))objc_msgSend)(self, sel, point);
}

// (id, SEL, CGSize) -> void
// Selectors: setFrameSize:, setContentSize:, setMinSize:, setMaxSize:
void objc_send_size_void(void* self, SEL sel, CGSize size) {
    ((void (*)(void*, SEL, CGSize))objc_msgSend)(self, sel, size);
}

// (id, SEL) -> CGRect   (return is HFA in d0-d3)
// Selectors: frame, bounds, visibleRect, alignmentRect
CGRect objc_send_ret_rect(void* self, SEL sel) {
    return ((CGRect (*)(void*, SEL))objc_msgSend)(self, sel);
}

// (id, SEL) -> CGPoint  (return is HFA in d0-d1)
// Selectors: frameOrigin (hypothetical accessor)
CGPoint objc_send_ret_point(void* self, SEL sel) {
    return ((CGPoint (*)(void*, SEL))objc_msgSend)(self, sel);
}

// (id, SEL) -> CGSize   (return is HFA in d0-d1)
// Selectors: frameSize (hypothetical accessor), intrinsicContentSize, fittingSize
CGSize objc_send_ret_size(void* self, SEL sel) {
    return ((CGSize (*)(void*, SEL))objc_msgSend)(self, sel);
}

// (id, SEL) -> double
// Selectors: alphaValue, doubleValue, floatValue (promoted), cornerRadius
double objc_send_ret_double(void* self, SEL sel) {
    return ((double (*)(void*, SEL))objc_msgSend)(self, sel);
}

// (id, SEL) -> long
// Selectors: tag, integerValue, count (NSArray), numberOfItems
long objc_send_ret_long(void* self, SEL sel) {
    return ((long (*)(void*, SEL))objc_msgSend)(self, sel);
}

// (id, SEL) -> int (BOOL)
// Selectors: isHidden, isEnabled, isEditable, isBezeled
int objc_send_ret_bool(void* self, SEL sel) {
    return ((int (*)(void*, SEL))objc_msgSend)(self, sel);
}

// ============================================================================
// Section 4: Convenience helpers
//
// High-level helpers that encapsulate common multi-step ObjC patterns.
// These are NOT just wrappers -- they embed specific selectors to reduce
// the number of bridge crossings from Crystal.
// ============================================================================

// --- NSString ---

void* nsstring_from_cstr(const char* s) {
    return ((void* (*)(void*, SEL, const char*))objc_msgSend)(
        (void*)objc_getClass("NSString"),
        sel_registerName("stringWithUTF8String:"), s);
}

// --- NSColor factories ---

// +[NSColor colorWithRed:green:blue:alpha:]
void* nscolor_rgba(double r, double g, double b, double a) {
    return ((void* (*)(void*, SEL, double, double, double, double))objc_msgSend)(
        (void*)objc_getClass("NSColor"),
        sel_registerName("colorWithRed:green:blue:alpha:"),
        r, g, b, a);
}

// +[NSColor colorWithSRGBRed:green:blue:alpha:]
void* nscolor_srgba(double r, double g, double b, double a) {
    return ((void* (*)(void*, SEL, double, double, double, double))objc_msgSend)(
        (void*)objc_getClass("NSColor"),
        sel_registerName("colorWithSRGBRed:green:blue:alpha:"),
        r, g, b, a);
}

// +[NSColor colorWithHue:saturation:brightness:alpha:]
void* nscolor_hsba(double h, double s, double b, double a) {
    return ((void* (*)(void*, SEL, double, double, double, double))objc_msgSend)(
        (void*)objc_getClass("NSColor"),
        sel_registerName("colorWithHue:saturation:brightness:alpha:"),
        h, s, b, a);
}

// +[NSColor colorWithWhite:alpha:]
void* nscolor_white_alpha(double white, double alpha) {
    return ((void* (*)(void*, SEL, double, double))objc_msgSend)(
        (void*)objc_getClass("NSColor"),
        sel_registerName("colorWithWhite:alpha:"),
        white, alpha);
}

// --- NSFont factories ---

// +[NSFont systemFontOfSize:]
void* nsfont_system(double size) {
    return ((void* (*)(void*, SEL, double))objc_msgSend)(
        (void*)objc_getClass("NSFont"),
        sel_registerName("systemFontOfSize:"), size);
}

// +[NSFont boldSystemFontOfSize:]
void* nsfont_bold_system(double size) {
    return ((void* (*)(void*, SEL, double))objc_msgSend)(
        (void*)objc_getClass("NSFont"),
        sel_registerName("boldSystemFontOfSize:"), size);
}

// +[NSFont systemFontOfSize:weight:]
void* nsfont_system_weight(double size, double weight) {
    return ((void* (*)(void*, SEL, double, double))objc_msgSend)(
        (void*)objc_getClass("NSFont"),
        sel_registerName("systemFontOfSize:weight:"), size, weight);
}

// +[NSFont monospacedSystemFontOfSize:weight:]
void* nsfont_monospaced_system(double size, double weight) {
    return ((void* (*)(void*, SEL, double, double))objc_msgSend)(
        (void*)objc_getClass("NSFont"),
        sel_registerName("monospacedSystemFontOfSize:weight:"), size, weight);
}

// +[NSFont monospacedDigitSystemFontOfSize:weight:]
void* nsfont_monospaced_digit(double size, double weight) {
    return ((void* (*)(void*, SEL, double, double))objc_msgSend)(
        (void*)objc_getClass("NSFont"),
        sel_registerName("monospacedDigitSystemFontOfSize:weight:"), size, weight);
}

// +[NSFont fontWithName:size:]  (name is NSString* in x2, size is double in d0)
void* nsfont_named(void* name, double size) {
    return ((void* (*)(void*, SEL, void*, double))objc_msgSend)(
        (void*)objc_getClass("NSFont"),
        sel_registerName("fontWithName:size:"), name, size);
}

// --- Frame / geometry helpers ---

// -[NSView frame]  (returns CGRect as HFA in d0-d3)
CGRect objc_get_frame(void* self) {
    return ((CGRect (*)(void*, SEL))objc_msgSend)(self, sel_registerName("frame"));
}

// -[NSView bounds]
CGRect objc_get_bounds(void* self) {
    return ((CGRect (*)(void*, SEL))objc_msgSend)(self, sel_registerName("bounds"));
}

// -[NSView setFrame:]
void objc_set_frame(void* self, CGRect frame) {
    ((void (*)(void*, SEL, CGRect))objc_msgSend)(self, sel_registerName("setFrame:"), frame);
}

// --- Subview helpers ---

void objc_add_subview(void* parent, void* child) {
    ((void (*)(void*, SEL, void*))objc_msgSend)(
        parent, sel_registerName("addSubview:"), child);
}

void objc_set_autoresize(void* view, unsigned long mask) {
    ((void (*)(void*, SEL, unsigned long))objc_msgSend)(
        view, sel_registerName("setAutoresizingMask:"), mask);
}

// ============================================================================
// Backward compatibility aliases
//
// These preserve the old API names so existing Crystal code continues to
// compile. They simply delegate to the correctly-named functions above.
// New code should use the explicit names (objc_send_1d, objc_send_1d_ret_id,
// etc.) or the convenience helpers (nscolor_rgba, nsfont_system, etc.).
// ============================================================================

// Old name: objc_send_double -> renamed to objc_send_1d
void objc_send_double(void* self, SEL sel, double arg1) {
    objc_send_1d(self, sel, arg1);
}

// Old name: objc_send_double_ret_id -> renamed to objc_send_1d_ret_id
void* objc_send_double_ret_id(void* self, SEL sel, double arg1) {
    return objc_send_1d_ret_id(self, sel, arg1);
}
