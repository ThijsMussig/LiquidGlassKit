#!/bin/sh
# Use Homebrew's GNU make instead of the system's ancient make 3.81
export THEOS=/Users/thijsmussig/theos
MAKE=/opt/homebrew/opt/make/libexec/gnubin/make

# If called with explicit arguments (e.g. "package"), just run make directly.
# Pass THEOS_PACKAGE_SCHEME=roothide on the command line to choose the roothide build.
if [ $# -gt 0 ]; then
    exec $MAKE "$@"
fi

# Delete old packages to prevent confusion
rm -f packages/*.deb

build_target() {
    local SCHEME=$1
    local ARCH=$2
    local OUT_NAME=$3
    
    echo "[LiquidGlass] Building $OUT_NAME package ($ARCH)…"
    $MAKE clean
    
    if [ -z "$SCHEME" ]; then
        $MAKE package ARCHS=$ARCH THEOS_PACKAGE_ARCH=iphoneos-$ARCH > /dev/null || exit 1
    else
        $MAKE THEOS_PACKAGE_SCHEME=$SCHEME package ARCHS=$ARCH THEOS_PACKAGE_ARCH=iphoneos-$ARCH > /dev/null || exit 1
    fi
    
    LATEST_DEB=$(ls -t packages/*.deb 2>/dev/null | head -n 1)
    if [ -n "$LATEST_DEB" ]; then
        mv "$LATEST_DEB" "packages/LiquidGlass-${OUT_NAME}_${ARCH}.deb"
    fi
}

build_target "" "arm64" "Rootful"
build_target "" "arm64e" "Rootful"
build_target "rootless" "arm64" "Rootless"
build_target "rootless" "arm64e" "Rootless"
build_target "roothide" "arm64" "Roothide"
build_target "roothide" "arm64e" "Roothide"

echo "[LiquidGlass] Done"
ls -1 packages/*.deb
