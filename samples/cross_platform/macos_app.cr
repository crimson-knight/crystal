# Crystal Cross-Platform Demo - macOS Native App
#
# A native macOS AppKit application using the ObjC runtime C API.
# Features NSVisualEffectView for glass/translucent effects.
#
# Build:
#   clang -c objc_bridge.c -o objc_bridge.o
#   crystal build macos_app.cr --link-flags="objc_bridge.o" -o macos_app
#
# Run:
#   ./macos_app

require "./app_core"

@[Link(framework: "AppKit")]
@[Link(framework: "Foundation")]
@[Link(framework: "CoreGraphics")]
lib LibObjC
  alias Id = Void*
  alias SEL = Void*
  alias Class = Void*

  struct CGRect
    x : Float64
    y : Float64
    width : Float64
    height : Float64
  end

  fun objc_getClass(name : UInt8*) : Class
  fun sel_registerName(name : UInt8*) : SEL
  fun objc_allocateClassPair(superclass : Class, name : UInt8*, extra : LibC::SizeT) : Class
  fun objc_registerClassPair(cls : Class)
  fun class_addMethod(cls : Class, sel : SEL, imp : Void*, types : UInt8*) : Bool

  # Bridge functions from objc_bridge.c
  fun objc_send(self : Id, sel : SEL) : Id
  fun objc_send_id(self : Id, sel : SEL, arg1 : Id) : Id
  fun objc_send_id_id(self : Id, sel : SEL, arg1 : Id, arg2 : Id) : Id
  fun objc_send_bool(self : Id, sel : SEL, arg1 : Int32)
  fun objc_send_long(self : Id, sel : SEL, arg1 : Int64) : Id
  fun objc_send_int(self : Id, sel : SEL, arg1 : Int32) : Id
  fun objc_send_void_id(self : Id, sel : SEL, arg1 : Id)
  fun objc_send_sel(self : Id, sel : SEL, arg1 : SEL)
  fun objc_send_double(self : Id, sel : SEL, arg1 : Float64)
  fun objc_send_double_ret_id(self : Id, sel : SEL, arg1 : Float64) : Id
  fun objc_send_rect(self : Id, sel : SEL, rect : CGRect) : Id
  fun objc_send_rect_ulong_ulong_bool(self : Id, sel : SEL, rect : CGRect, a : UInt64, b : UInt64, c : Int32) : Id
  fun nsstring_from_cstr(s : UInt8*) : Id
  fun objc_get_frame(self : Id) : CGRect
  fun objc_add_subview(parent : Id, child : Id)
  fun objc_set_autoresize(view : Id, mask : UInt64)
end

# --- Helpers ---

def cls(name)
  LibObjC.objc_getClass(name)
end

def sel(name)
  LibObjC.sel_registerName(name)
end

def nsstr(s)
  LibObjC.nsstring_from_cstr(s)
end

def alloc(class_name)
  LibObjC.objc_send(cls(class_name).as(LibObjC::Id), sel("alloc"))
end

def msg(obj, selector)
  LibObjC.objc_send(obj, sel(selector))
end

def msg(obj, selector, arg)
  LibObjC.objc_send_id(obj, sel(selector), arg.as(LibObjC::Id))
end

# --- App State ---

module AppState
  @@label : LibObjC::Id = Pointer(Void).null
  @@click_count : Int32 = 0

  def self.label; @@label; end
  def self.label=(v); @@label = v; end
  def self.click_count; @@click_count; end
  def self.click_count=(v); @@click_count = v; end
end

# --- ObjC Delegate Class ---

app_delegate_cls = LibObjC.objc_allocateClassPair(cls("NSObject"), "CrystalAppDelegate", 0)

did_finish = ->(this : LibObjC::Id, _sel : LibObjC::SEL, _notif : LibObjC::Id) {}
LibObjC.class_addMethod(app_delegate_cls, sel("applicationDidFinishLaunching:"),
  did_finish.pointer.as(Void*), "v@:@")

should_terminate = ->(this : LibObjC::Id, _sel : LibObjC::SEL, _sender : LibObjC::Id) : Bool { true }
LibObjC.class_addMethod(app_delegate_cls, sel("applicationShouldTerminateAfterLastWindowClosed:"),
  should_terminate.pointer.as(Void*), "B@:@")

LibObjC.objc_registerClassPair(app_delegate_cls)

# --- Button Handler ---

button_target_cls = LibObjC.objc_allocateClassPair(cls("NSObject"), "CrystalButtonTarget", 0)

button_clicked = ->(this : LibObjC::Id, _sel : LibObjC::SEL, _sender : LibObjC::Id) {
  AppState.click_count = AppState.click_count + 1
  n = AppState.click_count + 10
  fib = crystal_fibonacci(n)

  # Build result text
  text = nsstr("Clicks: #{AppState.click_count} | fib(#{n}) = #{fib}")
  LibObjC.objc_send_id(AppState.label, sel("setStringValue:"), text)
  nil
}
LibObjC.class_addMethod(button_target_cls, sel("buttonClicked:"),
  button_clicked.pointer.as(Void*), "v@:@")

LibObjC.objc_registerClassPair(button_target_cls)

# --- Create Window ---

# NSApplication
app = msg(cls("NSApplication").as(LibObjC::Id), "sharedApplication")
LibObjC.objc_send_long(app, sel("setActivationPolicy:"), 0_i64) # NSApplicationActivationPolicyRegular

# Delegate
delegate = msg(alloc("CrystalAppDelegate"), "init")
LibObjC.objc_send_id(app, sel("setDelegate:"), delegate)

# Window: 520x380
#   NSWindowStyleMaskTitled (1) | Closable (2) | Miniaturizable (4) | Resizable (8) = 15
#   NSBackingStoreBuffered = 2
win_rect = LibObjC::CGRect.new(x: 200.0, y: 200.0, width: 520.0, height: 380.0)
window = LibObjC.objc_send_rect_ulong_ulong_bool(
  alloc("NSWindow"), sel("initWithContentRect:styleMask:backing:defer:"),
  win_rect, 15_u64, 2_u64, 0)

LibObjC.objc_send_id(window, sel("setTitle:"), nsstr("Crystal Cross-Platform Demo"))

# --- Glass Effect (NSVisualEffectView) ---

content_view = msg(window, "contentView")
content_frame = LibObjC.objc_get_frame(content_view)

visual_effect = LibObjC.objc_send_rect(
  alloc("NSVisualEffectView"), sel("initWithFrame:"), content_frame)

# Material: NSVisualEffectMaterialHUDWindow = 13 (dark translucent)
LibObjC.objc_send_long(visual_effect, sel("setMaterial:"), 13_i64)
# Blending: NSVisualEffectBlendingModeBehindWindow = 0
LibObjC.objc_send_long(visual_effect, sel("setBlendingMode:"), 0_i64)
# State: NSVisualEffectStateActive = 1 (always active, even unfocused)
LibObjC.objc_send_long(visual_effect, sel("setState:"), 1_i64)
# Fill entire content area: width-sizable (2) | height-sizable (16) = 18
LibObjC.objc_set_autoresize(visual_effect, 18_u64)

LibObjC.objc_add_subview(content_view, visual_effect)

# --- Title Label ---

title_label = LibObjC.objc_send_rect(
  alloc("NSTextField"), sel("initWithFrame:"),
  LibObjC::CGRect.new(x: 20.0, y: 320.0, width: 480.0, height: 40.0))
LibObjC.objc_send_id(title_label, sel("setStringValue:"), nsstr("Crystal Cross-Platform Demo"))
font = LibObjC.objc_send_double_ret_id(cls("NSFont").as(LibObjC::Id), sel("boldSystemFontOfSize:"), 22.0)
LibObjC.objc_send_id(title_label, sel("setFont:"), font)
LibObjC.objc_send_bool(title_label, sel("setBezeled:"), 0)
LibObjC.objc_send_bool(title_label, sel("setDrawsBackground:"), 0)
LibObjC.objc_send_bool(title_label, sel("setEditable:"), 0)
LibObjC.objc_send_bool(title_label, sel("setSelectable:"), 0)
# White text for glass background
white = msg(cls("NSColor").as(LibObjC::Id), "whiteColor")
LibObjC.objc_send_id(title_label, sel("setTextColor:"), white)
LibObjC.objc_add_subview(visual_effect, title_label)

# --- Info Labels ---

# Platform info
platform_id = crystal_get_platform_id()
platform_name = case platform_id
                when 1 then "macOS"
                when 2 then "iOS"
                when 3 then "Android"
                when 4 then "WASM"
                when 5 then "Linux"
                else        "Unknown"
                end

info_label = LibObjC.objc_send_rect(
  alloc("NSTextField"), sel("initWithFrame:"),
  LibObjC::CGRect.new(x: 20.0, y: 275.0, width: 480.0, height: 25.0))
LibObjC.objc_send_id(info_label, sel("setStringValue:"),
  nsstr("Platform: #{platform_name} | add(17,25)=#{crystal_add(17, 25)} | fib(20)=#{crystal_fibonacci(20)}"))
small_font = LibObjC.objc_send_double_ret_id(cls("NSFont").as(LibObjC::Id), sel("systemFontOfSize:"), 13.0)
LibObjC.objc_send_id(info_label, sel("setFont:"), small_font)
LibObjC.objc_send_bool(info_label, sel("setBezeled:"), 0)
LibObjC.objc_send_bool(info_label, sel("setDrawsBackground:"), 0)
LibObjC.objc_send_bool(info_label, sel("setEditable:"), 0)
light_gray = LibObjC.objc_send_double_ret_id(cls("NSColor").as(LibObjC::Id), sel("colorWithWhite:alpha:"), 0.85)
LibObjC.objc_send_id(info_label, sel("setTextColor:"), light_gray)
LibObjC.objc_add_subview(visual_effect, info_label)

# Computation results
results_label = LibObjC.objc_send_rect(
  alloc("NSTextField"), sel("initWithFrame:"),
  LibObjC::CGRect.new(x: 20.0, y: 195.0, width: 480.0, height: 70.0))
LibObjC.objc_send_id(results_label, sel("setStringValue:"),
  nsstr("multiply(6,7) = #{crystal_multiply(6, 7)}\nfactorial(10) = #{crystal_factorial(10)}\npower(2,20) = #{crystal_power(2, 20)}"))
mono_font = LibObjC.objc_send_double_ret_id(
  cls("NSFont").as(LibObjC::Id), sel("monospacedSystemFontOfSize:weight:"), 12.0)
LibObjC.objc_send_id(results_label, sel("setFont:"), mono_font)
LibObjC.objc_send_bool(results_label, sel("setBezeled:"), 0)
LibObjC.objc_send_bool(results_label, sel("setDrawsBackground:"), 0)
LibObjC.objc_send_bool(results_label, sel("setEditable:"), 0)
green = LibObjC.objc_send_double_ret_id(cls("NSColor").as(LibObjC::Id), sel("colorWithRed:green:blue:alpha:"), 0.4)
LibObjC.objc_send_id(results_label, sel("setTextColor:"), green)
LibObjC.objc_add_subview(visual_effect, results_label)

# --- Result Label (updated by button) ---

AppState.label = LibObjC.objc_send_rect(
  alloc("NSTextField"), sel("initWithFrame:"),
  LibObjC::CGRect.new(x: 20.0, y: 110.0, width: 480.0, height: 30.0))
LibObjC.objc_send_id(AppState.label, sel("setStringValue:"), nsstr("Click the button to compute..."))
LibObjC.objc_send_id(AppState.label, sel("setFont:"), small_font)
LibObjC.objc_send_bool(AppState.label, sel("setBezeled:"), 0)
LibObjC.objc_send_bool(AppState.label, sel("setDrawsBackground:"), 0)
LibObjC.objc_send_bool(AppState.label, sel("setEditable:"), 0)
cyan = LibObjC.objc_send_double_ret_id(cls("NSColor").as(LibObjC::Id), sel("colorWithRed:green:blue:alpha:"), 0.3)
LibObjC.objc_send_id(AppState.label, sel("setTextColor:"), cyan)
LibObjC.objc_add_subview(visual_effect, AppState.label)

# --- Button ---

button = LibObjC.objc_send_rect(
  alloc("NSButton"), sel("initWithFrame:"),
  LibObjC::CGRect.new(x: 180.0, y: 150.0, width: 160.0, height: 40.0))
LibObjC.objc_send_id(button, sel("setTitle:"), nsstr("Compute Fibonacci"))
LibObjC.objc_send_long(button, sel("setBezelStyle:"), 1_i64) # NSBezelStyleRounded

# Wire button to handler
target = msg(alloc("CrystalButtonTarget"), "init")
LibObjC.objc_send_id(button, sel("setTarget:"), target)
LibObjC.objc_send_sel(button, sel("setAction:"), sel("buttonClicked:"))
LibObjC.objc_add_subview(visual_effect, button)

# --- Footer ---

footer = LibObjC.objc_send_rect(
  alloc("NSTextField"), sel("initWithFrame:"),
  LibObjC::CGRect.new(x: 20.0, y: 15.0, width: 480.0, height: 40.0))
LibObjC.objc_send_id(footer, sel("setStringValue:"),
  nsstr("Built with Crystal 1.20.0-dev | LLVM 21.1.8\nNative AppKit + NSVisualEffectView glass effect"))
tiny_font = LibObjC.objc_send_double_ret_id(cls("NSFont").as(LibObjC::Id), sel("systemFontOfSize:"), 10.0)
LibObjC.objc_send_id(footer, sel("setFont:"), tiny_font)
LibObjC.objc_send_bool(footer, sel("setBezeled:"), 0)
LibObjC.objc_send_bool(footer, sel("setDrawsBackground:"), 0)
LibObjC.objc_send_bool(footer, sel("setEditable:"), 0)
dim = LibObjC.objc_send_double_ret_id(cls("NSColor").as(LibObjC::Id), sel("colorWithWhite:alpha:"), 0.55)
LibObjC.objc_send_id(footer, sel("setTextColor:"), dim)
LibObjC.objc_add_subview(visual_effect, footer)

# --- Show and Run ---

LibObjC.objc_send_id(window, sel("makeKeyAndOrderFront:"), Pointer(Void).null)
LibObjC.objc_send_bool(app, sel("activateIgnoringOtherApps:"), 1)
msg(app, "run")
