#!/bin/sh
set -e
mkdir -p /var/state/ups
/opt/nut-install/bin/usbhid-ups -a ups -u root
/opt/nut-install/sbin/upsd -F -u root &

# upsd stays up when the driver dies, so DSM would keep showing "Connected"
# while no OB event can ever arrive again. Exit instead and let the Compose
# restart policy rebuild both. upsd's own MAXAGE debounces brief USB glitches.
while sleep 30; do
    /opt/nut-install/bin/upsc ups@127.0.0.1 ups.status >/dev/null 2>&1 && continue
    echo "UPS data unavailable, exiting so Docker restarts the stack" >&2
    exit 1
done
