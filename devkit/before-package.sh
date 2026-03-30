#!/bin/bash

set -e

if [ "$THEOS_PACKAGE_SCHEME" = "rootless" ]; then
    /usr/libexec/PlistBuddy -c 'Set :ProgramArguments:0 /var/jb/usr/bin/trollvncserver' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardOutPath /var/jb/tmp/trollvnc-stdout.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
    /usr/libexec/PlistBuddy -c 'Set :StandardErrorPath /var/jb/tmp/trollvnc-stderr.log' "$THEOS_STAGING_DIR/Library/LaunchDaemons/com.82flex.trollvnc.plist"
fi

if [ -z "$THEBOOTSTRAP" ]; then
    exit 0
fi

# Set version information
GIT_COMMIT_COUNT=$(git rev-list --count HEAD)
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $GIT_COMMIT_COUNT" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/Info.plist"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $PACKAGE_VERSION" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/Info.plist"

# Collect executables
cp -rp "$THEOS_STAGING_DIR/usr/bin/trollvncserver" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
cp -rp "$THEOS_STAGING_DIR/usr/bin/trollvncmanager" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

# Bundle sing-box binary (proxy tunnel engine)
if [ -f "$THEOS_STAGING_DIR/usr/bin/sing-box" ]; then
    cp -rp "$THEOS_STAGING_DIR/usr/bin/sing-box" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
    ldid -Sapp/TrollVNC/TrollVNC/TrollVNC.entitlements "$THEOS_STAGING_DIR/Applications/TrollVNC.app/sing-box"
    echo "[before-package] sing-box binary bundled and signed"
elif [ -f "sing-box" ]; then
    cp -rp "sing-box" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
    ldid -Sapp/TrollVNC/TrollVNC/TrollVNC.entitlements "$THEOS_STAGING_DIR/Applications/TrollVNC.app/sing-box"
    echo "[before-package] sing-box binary bundled from project root and signed"
else
    echo "[before-package] WARNING: sing-box binary not found, proxy feature will not work"
fi

# Collect bundle resources
cp -rp "$THEOS_STAGING_DIR/Library/PreferenceBundles/TrollVNCPrefs.bundle" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"
rm -f "$THEOS_STAGING_DIR/Applications/TrollVNC.app/TrollVNCPrefs.bundle/TrollVNCPrefs"
cp -rp "$THEOS_STAGING_DIR/usr/share/trollvnc/webclients" "$THEOS_STAGING_DIR/Applications/TrollVNC.app/"

# Remove unused files
rm -rf "${THEOS_STAGING_DIR:?}/usr"
rm -rf "${THEOS_STAGING_DIR:?}/Library"

# Build and bundle PacketTunnel.appex (VPN Network Extension)
EXTENSION_SRC="PacketTunnel/PacketTunnelProvider.m"
if [ -f "$EXTENSION_SRC" ]; then
    APPEX_DIR="$THEOS_STAGING_DIR/Applications/TrollVNC.app/PlugIns/PacketTunnel.appex"
    mkdir -p "$APPEX_DIR"

    # Compile extension with clang
    SDKROOT=$(xcrun --sdk iphoneos --show-sdk-path 2>/dev/null || echo "/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS.sdk")
    clang -target arm64-apple-ios15.0 \
        -isysroot "$SDKROOT" \
        -framework NetworkExtension -framework Foundation \
        -fobjc-arc \
        -e _NSExtensionMain \
        -o "$APPEX_DIR/PacketTunnel" \
        "$EXTENSION_SRC"

    # Copy Info.plist
    cp PacketTunnel/Info.plist "$APPEX_DIR/"

    # Sign extension with its own entitlements
    ldid -SPacketTunnel/PacketTunnel.entitlements "$APPEX_DIR/PacketTunnel"

    echo "[before-package] PacketTunnel.appex built and signed"
else
    echo "[before-package] WARNING: PacketTunnel source not found, VPN extension not bundled"
fi

# Pseudo code signing
ldid -Sapp/TrollVNC/TrollVNC/TrollVNC.entitlements "$THEOS_STAGING_DIR/Applications/TrollVNC.app"
