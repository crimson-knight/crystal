# Crystal Cross-Platform Demo

A single Crystal codebase that compiles to **7 targets**: macOS (native GUI), iOS (device + simulator), Android, WASM, and Linux (x86_64 + aarch64).

## Quick Start

```bash
# Build and launch the macOS native app with glass effects
make macos

# Cross-compile for all other targets
make ios
make android
make wasm
make linux
```

## Architecture

```
app_core.cr          <- Shared business logic (compiles everywhere)
     |
     +-- macos_app.cr + objc_bridge.c   <- macOS: AppKit native GUI
     +-- ios/CrystalBridge.h            <- iOS: Swift bridging header
     +-- android/jni_bridge.c           <- Android: JNI bridge to Java
```

**Key insight**: The Crystal code (`app_core.cr`) is identical across all platforms. Platform-specific UI shells call into Crystal's exported `fun` declarations via standard C FFI.

## Target Triples

| Target | Triple | Linker |
|--------|--------|--------|
| macOS native | `aarch64-apple-darwin` | system `cc` |
| iOS simulator | `aarch64-apple-ios17.0-simulator` | `xcrun --sdk iphonesimulator clang` |
| iOS device | `aarch64-apple-ios17.0` | `xcrun --sdk iphoneos clang` |
| Android | `aarch64-linux-android31` | NDK `clang` |
| WASM | `wasm32-wasi` | `wasm-ld` |
| Linux x86_64 | `x86_64-linux-gnu` | `cc` |
| Linux aarch64 | `aarch64-linux-gnu` | `cc` |

## Compile-Time Platform Detection

Crystal's `flag?()` macro system detects the target at compile time:

```crystal
fun crystal_get_platform_id : Int32
  {% if flag?(:macos) %}
    1
  {% elsif flag?(:ios) %}
    2
  {% elsif flag?(:android) %}
    3
  {% elsif flag?(:wasm32) %}
    4
  {% elsif flag?(:linux) %}
    5
  {% end %}
end
```

Available flags: `:macos`, `:ios`, `:apple`, `:darwin`, `:android`, `:unix`, `:linux`, `:wasm32`, `:wasi`

## macOS Native App

The macOS app uses AppKit via the Objective-C runtime C API - no Swift, no Xcode required.

### Glass Effects

Uses `NSVisualEffectView` for translucent glass backgrounds:

```crystal
visual_effect = LibObjC.objc_send_rect(
  alloc("NSVisualEffectView"), sel("initWithFrame:"), frame)
# Material: HUDWindow (dark translucent)
LibObjC.objc_send_long(visual_effect, sel("setMaterial:"), 13_i64)
# Blending: behind window content
LibObjC.objc_send_long(visual_effect, sel("setBlendingMode:"), 0_i64)
# Always active (even when window loses focus)
LibObjC.objc_send_long(visual_effect, sel("setState:"), 1_i64)
```

For macOS 26+ Liquid Glass, replace with `NSGlassEffectView`:
```crystal
glass_view = LibObjC.objc_send_rect(
  alloc("NSGlassEffectView"), sel("initWithFrame:"), frame)
LibObjC.objc_send_double(glass_view, sel("setCornerRadius:"), 16.0)
```

### ObjC Bridge

On ARM64, `objc_msgSend` requires typed function pointer casts. The `objc_bridge.c` file provides safe wrappers:

```c
// Integer args go in x0-x7 registers
void* objc_send_long(void* self, SEL sel, long arg1);
// Float/double args go in d0-d7 registers
void* objc_send_double_ret_id(void* self, SEL sel, double arg1);
// CGRect is a struct, passed in registers on ARM64
void* objc_send_rect(void* self, SEL sel, CGRect rect);
```

## iOS Integration

### Step 1: Cross-compile Crystal
```bash
make ios  # produces build/crystal_ios_sim.o
ar rcs build/libcrystal_ios.a build/crystal_ios_sim.o
```

### Step 2: Add to Xcode project
1. Drag `libcrystal_ios.a` into your Xcode project
2. Add `ios/CrystalBridge.h` as the Objective-C Bridging Header
3. Call Crystal functions from Swift:

```swift
let result = crystal_add(17, 25)       // 42
let fib = crystal_fibonacci(20)        // 6765
let platform = crystal_get_platform_id() // 2 (iOS)
```

### Glass Effects on iOS

For UIKit glass effects, use `UIVisualEffectView` + `UIBlurEffect`:
```swift
let blur = UIBlurEffect(style: .systemMaterial)
let effectView = UIVisualEffectView(effect: blur)
```

For iOS 26+ Liquid Glass:
```swift
let glass = UIGlassEffect()
glass.isInteractive = true
let effectView = UIVisualEffectView(effect: glass)
```

## Android Integration

### Step 1: Cross-compile Crystal
```bash
make android  # produces build/crystal_android.o
```

### Step 2: Create shared library with JNI bridge
```bash
$ANDROID_NDK_HOME/toolchains/llvm/prebuilt/*/bin/clang \
  --target=aarch64-linux-android31 \
  -shared -o build/libcrystal.so \
  build/crystal_android.o android/jni_bridge.c -llog
```

### Step 3: Add to Android project
1. Copy `libcrystal.so` to `app/src/main/jniLibs/arm64-v8a/`
2. Create JNI binding class:

```java
public class CrystalLib {
    static { System.loadLibrary("crystal"); }
    public static native int add(int a, int b);
    public static native long fibonacci(int n);
    public static native int getPlatformId();
}
```

## Asset Pipeline Integration

The [asset_pipeline](https://github.com/crimsonknight/asset_pipeline) shard provides a type-safe HTML component system for web targets. For native platforms, the same component architecture pattern applies but renders to native widgets instead of HTML:

| Layer | Web (asset_pipeline) | macOS | iOS | Android |
|-------|---------------------|-------|-----|---------|
| **Components** | Crystal classes | Crystal classes | Crystal classes | Crystal classes |
| **Rendering** | HTML strings | ObjC runtime (AppKit) | ObjC runtime (UIKit) | JNI (Android Views) |
| **Styling** | CSS utilities | NSAppearance | UIAppearance | Material themes |
| **Events** | Stimulus/JS | NSTarget-Action | UIControl events | View.OnClickListener |

The shared business logic layer (`app_core.cr`) is platform-independent. UI components are thin platform-specific wrappers that call the same Crystal core.

## Requirements

- Crystal 1.20.0-dev with cross-platform target support
- LLVM 21.1.8
- Xcode (for iOS/macOS SDK)
- Android NDK 28+ (for Android)
- wasmtime (for running WASM)

## File Reference

| File | Purpose |
|------|---------|
| `app_core.cr` | Shared business logic - compiles for all 7 targets |
| `macos_app.cr` | macOS native AppKit app with NSVisualEffectView glass |
| `objc_bridge.c` | ARM64 type-safe objc_msgSend wrappers |
| `ios/CrystalBridge.h` | C header for Swift bridging |
| `android/jni_bridge.c` | JNI bridge between Java and Crystal |
| `Makefile` | Build system for all targets |
