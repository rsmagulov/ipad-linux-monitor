#!/bin/sh
# Builds Connector.ipa (unsigned) on Linux with clang + ld64.lld and an iOS SDK
# (iPhoneOS*.sdk in ../.deps, or SDK=/path/to/iPhoneOS.sdk).
set -e
cd "$(dirname "$0")"
DEPS=${DEPS:-../.deps}
CLANG=${CLANG:-$DEPS/llvm/usr/lib/llvm-20/bin/clang}
[ -x "$CLANG" ] || CLANG=clang
SDK=${SDK:-$(ls -d "$DEPS"/iPhoneOS*.sdk 2>/dev/null | tail -1)}
[ -d "$SDK" ] || { echo "no iOS SDK: put iPhoneOS*.sdk into .deps/ or set SDK= (see README)" >&2; exit 1; }
OUT=build
APP=$OUT/Payload/Connector.app

rm -rf "$OUT"
mkdir -p "$APP"
"$CLANG" -target arm64-apple-ios12.0 -isysroot "$SDK" -fuse-ld=lld \
    -O2 -fobjc-arc -Wall -Wno-unused-function \
    -framework UIKit -framework Foundation -framework AVFoundation -framework CoreMedia -framework CoreGraphics -framework QuartzCore -framework Network -framework Security -framework UserNotifications \
    -o "$APP/Connector" main.m
# Each Apple ID needs its own bundle id; keep the one you installed with.
BUNDLE_ID=${BUNDLE_ID:-$(cat "${XDG_CONFIG_HOME:-$HOME/.config}/connector/bundle-id" 2>/dev/null)}
BUNDLE_ID=${BUNDLE_ID:-io.github.connector.$(id -un | tr -cd 'a-zA-Z0-9')}
sed "s/BUNDLE_ID/$BUNDLE_ID/" Info.plist > "$APP/Info.plist"
cp -R en.lproj ru.lproj "$APP/"
printf 'APPL????' > "$APP/PkgInfo"
python3 make-icon.py "$APP/AppIcon76x76@2x~ipad.png" 152
python3 make-icon.py "$APP/AppIcon76x76~ipad.png" 76
(cd "$OUT" && rm -f ../Connector.ipa && python3 -m zipfile -c ../Connector.ipa Payload)
echo "built $(pwd)/Connector.ipa ($BUNDLE_ID)"
