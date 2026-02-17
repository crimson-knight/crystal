# Crystal Cross-Platform Demo - Build System
#
# Usage:
#   make macos       - Build and run native macOS app with glass effects
#   make ios         - Cross-compile for iOS simulator (aarch64)
#   make ios-device  - Cross-compile for iOS device (aarch64)
#   make android     - Cross-compile for Android (aarch64, API 31)
#   make wasm        - Cross-compile for WASM
#   make linux       - Cross-compile for Linux aarch64
#   make all         - Build all targets
#   make clean       - Remove build artifacts

CRYSTAL     := ../../bin/crystal
CRYSTAL_FLAGS := --prelude=empty
BUILD_DIR   := build
ROOT_DIR    := $(shell cd ../.. && pwd)

# Android NDK (set ANDROID_NDK_HOME if not default)
ANDROID_NDK_HOME ?= /opt/homebrew/share/android-commandlinetools/ndk/28.2.13676358
NDK_CLANG   := $(shell ls $(ANDROID_NDK_HOME)/toolchains/llvm/prebuilt/*/bin/clang 2>/dev/null | head -1)
ANDROID_API := 31

# WASM
WASM_LIBS   ?= /tmp/wasm32-wasi-libs

.PHONY: all macos ios ios-device android wasm linux clean

all: macos ios android wasm linux

# ============================================================
# macOS: Native AppKit app with glass effect
# ============================================================

$(BUILD_DIR)/objc_bridge.o: objc_bridge.c
	@mkdir -p $(BUILD_DIR)
	clang -c $< -o $@

macos: $(BUILD_DIR)/objc_bridge.o
	@mkdir -p $(BUILD_DIR)
	$(CRYSTAL) build macos_app.cr \
		--link-flags="$(CURDIR)/$(BUILD_DIR)/objc_bridge.o" \
		-o $(BUILD_DIR)/macos_app
	@echo ""
	@echo "=== macOS app built ==="
	@file $(BUILD_DIR)/macos_app
	@echo "Run: ./$(BUILD_DIR)/macos_app"
	@echo ""
	./$(BUILD_DIR)/macos_app &

# ============================================================
# iOS Simulator (aarch64)
# ============================================================

ios:
	@mkdir -p $(BUILD_DIR)
	$(CRYSTAL) build app_core.cr \
		--cross-compile \
		--target aarch64-apple-ios17.0-simulator \
		$(CRYSTAL_FLAGS) \
		-o $(BUILD_DIR)/crystal_ios_sim
	@echo ""
	@echo "=== iOS simulator object built ==="
	@file $(BUILD_DIR)/crystal_ios_sim.o
	@echo ""
	@echo "To create a static library:"
	@echo "  ar rcs $(BUILD_DIR)/libcrystal_ios.a $(BUILD_DIR)/crystal_ios_sim.o"
	@echo ""
	@echo "Then add libcrystal_ios.a + ios/CrystalBridge.h to your Xcode project."

# ============================================================
# iOS Device (aarch64)
# ============================================================

ios-device:
	@mkdir -p $(BUILD_DIR)
	$(CRYSTAL) build app_core.cr \
		--cross-compile \
		--target aarch64-apple-ios17.0 \
		$(CRYSTAL_FLAGS) \
		-o $(BUILD_DIR)/crystal_ios_device
	@echo ""
	@echo "=== iOS device object built ==="
	@file $(BUILD_DIR)/crystal_ios_device.o

# ============================================================
# Android (aarch64, API 31)
# ============================================================

android:
	@mkdir -p $(BUILD_DIR)
	$(CRYSTAL) build app_core.cr \
		--cross-compile \
		--target aarch64-linux-android$(ANDROID_API) \
		$(CRYSTAL_FLAGS) \
		-o $(BUILD_DIR)/crystal_android
	@echo ""
	@echo "=== Android object built ==="
	@file $(BUILD_DIR)/crystal_android.o
	@echo ""
	@echo "To create shared library with JNI bridge:"
	@echo "  $(NDK_CLANG) --target=aarch64-linux-android$(ANDROID_API) \\"
	@echo "    -shared -o $(BUILD_DIR)/libcrystal.so \\"
	@echo "    $(BUILD_DIR)/crystal_android.o android/jni_bridge.c -llog"

# ============================================================
# WASM (wasm32-wasi)
# ============================================================

wasm:
	@mkdir -p $(BUILD_DIR)
	$(CRYSTAL) build app_core.cr \
		--cross-compile \
		--target wasm32-wasi \
		$(CRYSTAL_FLAGS) \
		-o $(BUILD_DIR)/crystal_wasm
	@echo ""
	@echo "=== WASM object built ==="
	@file $(BUILD_DIR)/crystal_wasm.wasm

# ============================================================
# Linux (aarch64)
# ============================================================

linux:
	@mkdir -p $(BUILD_DIR)
	$(CRYSTAL) build app_core.cr \
		--cross-compile \
		--target aarch64-linux-gnu \
		$(CRYSTAL_FLAGS) \
		-o $(BUILD_DIR)/crystal_linux_arm
	@echo ""
	@echo "=== Linux aarch64 object built ==="
	@file $(BUILD_DIR)/crystal_linux_arm.o

# ============================================================

clean:
	rm -rf $(BUILD_DIR)
