#!/bin/sh
# Use Homebrew's GNU make instead of the system's ancient make 3.81
export THEOS=/Users/thijsmussig/theos
MAKE=/opt/homebrew/opt/make/libexec/gnubin/make

# If called with explicit arguments (e.g. "package"), just run make directly.
# Pass THEOS_PACKAGE_SCHEME=roothide on the command line to choose the roothide build.
if [ $# -gt 0 ]; then
    exec $MAKE "$@"
fi

echo "[LiquidGlass] Building rootful package (arm64 + arm64e)…"
$MAKE package || exit 1

echo "[LiquidGlass] Building rootless package (arm64 + arm64e)…"
$MAKE THEOS_PACKAGE_SCHEME=rootless package || exit 1

echo "[LiquidGlass] Building roothide package (arm64e)…"
$MAKE THEOS_PACKAGE_SCHEME=roothide package THEOS_PACKAGE_ARCH=iphoneos-arm64e || exit 1

echo "[LiquidGlass] Done. Packages:"
ls -1 packages/*.deb 2>/dev/null | grep -v "^$"
