#!/usr/bin/env bash
# gnome-shell aborts without a system bus and a login1 service. Start both as
# root (logind standalone, no systemd PID 1), then hand off to run.sh as the
# unprivileged session user.
set -euo pipefail

mkdir -p /run/dbus
rm -f /run/dbus/pid /run/dbus/system_bus_socket
dbus-daemon --system --fork
/usr/lib/systemd/systemd-logind > /var/log/logind.log 2>&1 &
for _ in $(seq 1 20); do
  gdbus call --system --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus \
    --method org.freedesktop.DBus.NameHasOwner org.freedesktop.login1 2>/dev/null | grep -q true && break
  sleep 0.5
done
mkdir -p /home/tester/evidence
chown tester:tester /home/tester/evidence
exec runuser -u tester -- env HOME=/home/tester /opt/testbed/run.sh "$@"
