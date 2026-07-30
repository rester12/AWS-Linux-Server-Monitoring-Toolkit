#!/usr/bin/env bash

set -euo pipefail

if [[ "$EUID" -ne 0 ]]; then
    echo "Run this installer with sudo." >&2
    exit 1
fi

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd -- "$SCRIPT_DIR/.." && pwd)"
MONITOR_USER="${MONITOR_USER:-ubuntu}"

if ! id "$MONITOR_USER" >/dev/null 2>&1; then
    echo "The monitoring user '$MONITOR_USER' does not exist." >&2
    exit 1
fi

install -m 0750 "$REPO_DIR/scripts/sys_health_monitor.sh" /usr/local/bin/sys-health-monitor

if [[ ! -f /etc/sys-health-monitor.conf ]]; then
    install -m 0640 -o root -g "$MONITOR_USER" \
        "$REPO_DIR/configs/sys-health-monitor.conf.example" \
        /etc/sys-health-monitor.conf
fi

install -m 0644 "$REPO_DIR/configs/sys-health-monitor.service" /etc/systemd/system/sys-health-monitor.service
install -m 0644 "$REPO_DIR/configs/sys-health-monitor.timer" /etc/systemd/system/sys-health-monitor.timer
install -m 0644 "$REPO_DIR/configs/logrotate-sys-health" /etc/logrotate.d/sys-health-monitor

install -d -m 0750 -o "$MONITOR_USER" -g "$MONITOR_USER" /var/lib/sys-health-monitor
install -d -m 0755 -o "$MONITOR_USER" -g "$MONITOR_USER" /var/www/html
touch /var/log/sys_health.log
chown "$MONITOR_USER":syslog /var/log/sys_health.log
chmod 0640 /var/log/sys_health.log

systemctl daemon-reload
systemctl enable sys-health-monitor.timer

echo "Installation complete."
echo "Edit /etc/sys-health-monitor.conf, test the service, and then start the timer."
