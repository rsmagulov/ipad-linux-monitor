#!/bin/sh
# One-time setup (run with sudo): lets your user switch the virtual display
# connector without a password, now and after every reboot, and opens the
# firewall port for Wi-Fi/internet connections.
set -e
[ "$(id -u)" = 0 ] || { echo "run as: sudo $0" >&2; exit 1; }
DIR=$(cd "$(dirname "$(readlink -f "$0")")/.." && pwd)
GROUP=plugdev

# Any HDMI/DP port may become the virtual monitor (see connector-config).
rm -f /etc/udev/rules.d/70-connector-virtual-display.rules # older versions
[ -f /usr/lib/udev/rules.d/70-connector.rules ] || install -m644 "$DIR/scripts/70-connector.rules" /etc/udev/rules.d/
udevadm control --reload

for f in /sys/class/drm/card*-HDMI-A-*/status /sys/class/drm/card*-DP-*/status; do
    [ -e "$f" ] || continue
    chgrp "$GROUP" "$f"
    chmod g+w "$f"
done
echo "udev: group $GROUP may switch HDMI/DP ports"
systemctl enable --now usbmuxd >/dev/null 2>&1 || true
# Wi-Fi/internet: the iPad connects to TCP 27183 (TLS with the paired key)
# and finds the laptop with a UDP 27183 broadcast.
if command -v ufw >/dev/null 2>&1 && ufw status | grep -q "Status: active"; then
    ufw allow 27183/tcp comment 'Connector: iPad over Wi-Fi/internet' >/dev/null
    ufw allow 27183/udp comment 'Connector: iPad finds the laptop' >/dev/null
    echo "ufw: opened port 27183 (tcp, udp)"
fi
echo "done; make sure your user is in the '$GROUP' group (id -nG)"
