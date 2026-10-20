#!/bin/sh
# Builds connector_VERSION~RELEASE_ARCH.deb from this checkout. The package
# depends on this distribution release's libraries (ffmpeg versions differ
# between releases), so build it on the release it is for.
set -e
cd "$(dirname "$0")/.."
PKG_VERSION=$(cat VERSION)
ARCH=$(dpkg --print-architecture)
RELEASE=$(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}")
ROOT=$(mktemp -d)
trap 'rm -rf "$ROOT"' EXIT
chmod 755 "$ROOT"

ios/build.sh || echo "warning: no iPad app in the package (no iOS SDK, see README)" >&2
make install DESTDIR="$ROOT" PREFIX=/usr
install -D -m644 scripts/70-connector.rules "$ROOT/usr/lib/udev/rules.d/70-connector.rules"
install -D -m644 packaging/ufw-connector "$ROOT/etc/ufw/applications.d/connector"
install -D -m644 README.md "$ROOT/usr/share/doc/connector/README.md"
install -D -m644 LICENSE "$ROOT/usr/share/doc/connector/copyright"

# Depends: the packages that provide the libraries connector-host links to
# directly (NEEDED), resolved to paths by ldd.
DEPS=$(objdump -p host/connector-host | awk '/NEEDED/ { print $2 }' | while read -r so; do
    ldd host/connector-host | awk -v so="$so" '$1 == so { print $3 }'
done | while read -r lib; do
    dpkg -S "$lib" 2>/dev/null || dpkg -S "/usr$lib" 2>/dev/null || dpkg -S "$(readlink -f "$lib")" 2>/dev/null || true
done | cut -d: -f1 | grep -v '^libc6$' | sort -u | paste -sd, - | sed 's/,/, /g' |
    sed -E 's/libavcodec-extra([0-9]+)/libavcodec\1 | libavcodec-extra\1/')

mkdir -p "$ROOT/DEBIAN"
cat > "$ROOT/DEBIAN/control" <<CONTROL
Package: connector
Version: $PKG_VERSION~$RELEASE
Architecture: $ARCH
Maintainer: rsmagulov <190504336+rsmagulov@users.noreply.github.com>
Depends: libc6, $DEPS
Recommends: usbmuxd, x11-xserver-utils, libnotify-bin
Homepage: https://github.com/rsmagulov/ipad-linux-monitor
Section: x11
Priority: optional
Description: old iPad as a second monitor for Linux (X11)
 Streams a virtual monitor (a spare HDMI/DP port) to an iOS 12+ iPad over
 the cable, Wi-Fi or the internet, with touch, trackpad and keyboard input.
 After installing: sudo connector-setup; connector-autostart on;
 connector-ipad-install to put the app on the iPad.
CONTROL
cat > "$ROOT/DEBIAN/postinst" <<'POSTINST'
#!/bin/sh
set -e
if [ "$1" = configure ]; then
    udevadm control --reload-rules 2>/dev/null || true
    udevadm trigger --subsystem-match=drm --action=change 2>/dev/null || true
fi
POSTINST
chmod 755 "$ROOT/DEBIAN/postinst"
echo /etc/ufw/applications.d/connector > "$ROOT/DEBIAN/conffiles"

OUT=connector_${PKG_VERSION}~${RELEASE}_$ARCH.deb
dpkg-deb --root-owner-group --build "$ROOT" "$OUT" >/dev/null
echo "built $(pwd)/$OUT"
