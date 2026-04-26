#!/bin/bash
# Install low-resource system optimizations
# Run with sudo

set -e

echo "[1/5] Installing tmpfs size limit for /tmp..."
install -D -m 644 /home/tokisaki/github/daily-learnings/sysops/tmp.mount.conf /etc/systemd/system/tmp.mount.d/override.conf
systemctl daemon-reload
systemctl restart tmp.mount || true
echo "  /tmp now capped at 10% RAM"

echo "[2/5] Configuring journald size limits..."
install -D -m 644 /home/tokisaki/github/daily-learnings/sysops/journald.conf.d-snippet /etc/systemd/journald.conf.d/99-hermes-lowres.conf
systemctl restart systemd-journald
journalctl --vacuum-size=150M
echo "  journald capped: RuntimeMaxUse=100M, SystemMaxUse=200M"

echo "[3/5] Setting Docker log rotation (if Docker installed)..."
if command -v dockerd &>/dev/null; then
    install -D -m 644 /home/tokisaki/github/daily-learnings/sysops/docker-daemon.json /etc/docker/daemon.json
    systemctl restart docker || true
    echo "  Docker log caps applied (10m x 3 files)"
else
    echo "  Docker not found — skipping"
fi

echo "[4/5] Installing weekly system cleanup..."
install -D -m 755 /home/tokisaki/github/daily-learnings/sysops/system-cleanup /etc/cron.weekly/hermes-system-cleanup
echo "  Weekly system cleanup installed"

echo "[5/5] Enabling tmpfiles.d cleanup rules..."
install -D -m 644 /dev/null /etc/tmpfiles.d/hermes-clean.conf
echo "d /run/hermes 0755 root root 10d" > /etc/tmpfiles.d/hermes-clean.conf
systemd-tmpfiles --create 2>/dev/null || true
echo "  tmpfiles.d rules applied"

echo ""
echo "All optimizations installed. Reboot recommended to verify tmpfs mount."
