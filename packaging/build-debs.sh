#!/bin/sh
# Builds connector_*.deb for several Debian/Ubuntu releases, each in a Docker
# container of that release: ffmpeg and OpenSSL versions differ between
# releases, so a package fits only the release it was built on.
# Usage: packaging/build-debs.sh [image ...]   (default: the list below)
# The iPad app is built here once and packed into every package; they land in dist/.
set -e
cd "$(dirname "$0")/.."
IMAGES=${*:-ubuntu:20.04 ubuntu:22.04 ubuntu:24.04 ubuntu:26.04 debian:12 debian:13}

ios/build.sh
SRC=$(mktemp -d)
trap 'rm -rf "$SRC"' EXIT
git ls-files -z | tar --null -T - -c | tar -x -C "$SRC"   # tracked files as they are now
cp ios/Connector.ipa "$SRC/ios/"
mkdir -p dist

failed=
for image in $IMAGES; do
    echo "== $image"
    docker run --rm -v "$SRC:/src:ro" -v "$PWD/dist:/out" -e DEBIAN_FRONTEND=noninteractive \
        -e OWNER="$(id -u):$(id -g)" "$image" sh -ec '
        apt-get update -qq
        apt-get install -y -qq --no-install-recommends build-essential libx11-dev libxext-dev \
            libxfixes-dev libxrandr-dev libxtst-dev libavcodec-dev libavutil-dev libswscale-dev \
            libusbmuxd-dev libssl-dev libxkbcommon-dev pkg-config >/dev/null
        cp -r /src /build && cd /build
        KEEP_IPA=1 packaging/build-deb.sh
        # The package must install on this release (every Depends exists) and start.
        apt-get install -y -qq --no-install-recommends ./connector_*.deb >/dev/null
        /usr/lib/connector/host/connector-host -V
        cp connector_*.deb /out/ && chown "$OWNER" /out/connector_*.deb' ||
        failed="$failed $image"
done
ls -l dist
[ -z "$failed" ] || { echo "failed:$failed" >&2; exit 1; }
