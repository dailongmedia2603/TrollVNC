#!/bin/bash
# Builds tunnel/build/PacketTunnel.appex (WireGuard for Phone Agent).
# devkit/before-package.sh copies it into TrollVNC.app/PlugIns and signs it.
# Needs: Go, clang + iPhoneOS SDK (xcrun, or SDK=/path/to/iPhoneOS.sdk).
set -euo pipefail
cd "$(dirname "$0")"

MINOS=14.0
TARGET="arm64-apple-ios$MINOS"
SDK="${SDK:-$(xcrun --sdk iphoneos --show-sdk-path)}"
CLANG="$(xcrun -f clang)"
OUT=build
APPEX="$OUT/PacketTunnel.appex"

rm -rf "$OUT"
mkdir -p "$APPEX"

echo "[tunnel] libwg.a (wireguard-go)"
(
  cd go
  CGO_ENABLED=1 GOOS=ios GOARCH=arm64 CC="$CLANG" \
    CGO_CFLAGS="-target $TARGET -isysroot $SDK -O2" \
    CGO_LDFLAGS="-target $TARGET -isysroot $SDK" \
    go build -trimpath -ldflags="-s -w" -buildmode=c-archive -o "../$OUT/libwg.a" .
)

echo "[tunnel] PacketTunnel.appex"
"$CLANG" -target "$TARGET" -isysroot "$SDK" -O2 -Wall -Wno-arc-retain-cycles -fobjc-arc -fapplication-extension \
  -I"$OUT" extension/PacketTunnelProvider.m "$OUT/libwg.a" \
  -framework Foundation -framework NetworkExtension -framework CoreFoundation -framework Security -lresolv \
  -e _NSExtensionMain -o "$APPEX/PacketTunnel"
cp extension/Info.plist "$APPEX/Info.plist"
rm -f "$OUT/libwg.a" "$OUT/libwg.h"
echo "[tunnel] done: $APPEX"
