# ---------------------------------------------------------------
# LiquidGlass – iOS 16 Jailbreak Tweak
# Requires Theos (https://theos.dev) and Xcode 16+
# Target device: arm64 iPhone/iPad running iOS 14.0 – 16.x (jailbroken)
# ---------------------------------------------------------------

export ARCHS = arm64 arm64e
# clang:<sdk-version>:<deployment-target>  — iOS 26 SDK, deploy back to iOS 14
export TARGET = iphone:clang:26.0:14.0
# Default scheme is rootless. Pass THEOS_PACKAGE_SCHEME=roothide on the command
# line (make THEOS_PACKAGE_SCHEME=roothide package) to produce the roothide .deb.
# Both schemes install to /var/jb — RootHide remaps that to its hidden path at runtime.
THEOS_PACKAGE_SCHEME ?= rootless
export THEOS_PACKAGE_SCHEME
# Swift 6 is required – internal import + trailing‐comma call syntax
export SWIFT_VERSION = 6

include $(THEOS)/makefiles/common.mk

# ---------------------------------------------------------------
# Tweak target
# ---------------------------------------------------------------
TWEAK_NAME = LiquidGlass

# All Swift source files compiled into the dylib
LiquidGlass_FILES = \
	Tweak.x \
	Sources/LiquidGlassBridge.swift \
	liquidglasskit/Sources/LiquidGlassKit/LiquidGlassView.swift \
	liquidglasskit/Sources/LiquidGlassKit/LiquidGlassEffectView.swift \
	liquidglasskit/Sources/LiquidGlassKit/LiquidGlassSlider.swift \
	liquidglasskit/Sources/LiquidGlassKit/LiquidGlassSwitch.swift \
	liquidglasskit/Sources/LiquidGlassKit/LiquidLensView.swift \
	liquidglasskit/Sources/LiquidGlassKit/ZeroCopyBridge.swift

LiquidGlass_CFLAGS   = -fobjc-arc
# Suppress Swift 6 strict-concurrency warnings that don't affect runtime
LiquidGlass_SWIFTFLAGS = -suppress-warnings

LiquidGlass_FRAMEWORKS = \
	UIKit \
	MetalKit \
	MetalPerformanceShaders \
	CoreVideo

# ---------------------------------------------------------------
# Shader pre-compilation step
# Produces layout/Library/LiquidGlass/LiquidGlassKitShaderResources.bundle/default.metallib
# before the tweak dylib is linked.
# ---------------------------------------------------------------
SHADER_BUNDLE  = layout/Library/LiquidGlass/LiquidGlassKitShaderResources.bundle
SHADER_SRC     = liquidglasskit/Sources/LiquidGlassKit
AIR_FRAG       = $(THEOS_OBJ_DIR)/LGFragment.air
AIR_VERT       = $(THEOS_OBJ_DIR)/LGVertex.air

before-all::
	@echo "[LiquidGlass] Compiling Metal shaders for iOS arm64…"
	@mkdir -p $(SHADER_BUNDLE) $(THEOS_OBJ_DIR)
	xcrun -sdk iphoneos metal \
		-target air64-apple-ios14.0 \
		-c $(SHADER_SRC)/LiquidGlassFragment.metal \
		-o $(AIR_FRAG)
	xcrun -sdk iphoneos metal \
		-target air64-apple-ios14.0 \
		-c $(SHADER_SRC)/LiquidGlassVertex.metal \
		-o $(AIR_VERT)
	xcrun -sdk iphoneos metallib \
		$(AIR_FRAG) $(AIR_VERT) \
		-o $(SHADER_BUNDLE)/default.metallib
	@echo "[LiquidGlass] Metal shaders compiled → $(SHADER_BUNDLE)/default.metallib"

# ---------------------------------------------------------------
# Preferences bundle (shown as a Settings pane via PreferenceLoader)
# ---------------------------------------------------------------
BUNDLE_NAME = LiquidGlassPrefs
LiquidGlassPrefs_FILES = LiquidGlassPrefs/LiquidGlassPrefsController.m
LiquidGlassPrefs_CFLAGS = -fobjc-arc -F$(THEOS)/vendor/include
LiquidGlassPrefs_LDFLAGS = -undefined dynamic_lookup
LiquidGlassPrefs_INSTALL_PATH = /Library/PreferenceBundles
LiquidGlassPrefs_RESOURCE_DIRS = LiquidGlassPrefs/Resources

# ---------------------------------------------------------------
include $(THEOS)/makefiles/tweak.mk
include $(THEOS)/makefiles/bundle.mk
