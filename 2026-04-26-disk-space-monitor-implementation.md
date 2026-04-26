# Disk Space Monitoring — 24/7 Watchdog

**Date:** 2026-04-26  
**Topic:** Automatic disk space monitoring, threshold-based cleanup escalation  
**Related:** [Low-Resource Optimization Guide](./2026-04-26-low-resource-optimization-guide.md)

---

## Summary

Implemented a 24/7 disk space monitor (`disk-monitor.sh`) that checks free space every 5 minutes. When free space drops below configurable thresholds, it automatically escalates cleanup actions:

- **≤5 GB** — logs notice, optional Telegram alert (silent by default)
- **≤3 GB** — runs quick cleanup (plugin `quick()`: deletes tracked temp/test/cron-output files + empties dirs)
- **≤2 GB** — runs deep cleanup (plugin `deep()` with conservative auto-confirm for large/old items)

The monitor tracks free space trends by logging each check to `~/.hermes/disk-monitor.log`; if current free space is >1 GB below the 3-check moving average, it flags a downward trend in its output.

A Python wrapper (`disk_cleanup_wrapper.py`) calls the `disk-cleanup` plugin's functions standalone without requiring the agent to be running, making the monitor reliable even in tight memory conditions.

---

## Files Added/Modified

| File | Purpose |
|------|---------|
| `scripts/disk-monitor.sh` | 24/7 watchdog with thresholds, lockfile, trend detection |
| `scripts/disk_cleanup_wrapper.py` | Standalone plugin wrapper exposing `quick|deep|status` |
| `crontab` (user) | `*/5 * * * *` → runs `disk-monitor.sh` |
| `~/.hermes/config.yaml` | `plugins.enabled += ["disk-cleanup"]` (plugin now active) |

---

## Verification

```bash
# Manual run
bash ~/.hermes/scripts/disk-monitor.sh

# View monitor trend log
tail -5 ~/.hermes/disk-monitor.log

# Check latest Hermes cron job output for disk monitor
tail -10 ~/.hermes/logs/disk-monitor.log

# Plugin status (once agent has been restarted)
hermes disk-cleanup status
```

---

## Configuration

- Thresholds (editable in script): `THRESHOLD_5GB=5`, `THRESHOLD_3GB=3`, `THRESHOLD_2GB=2`
- Monitor log: `~/.hermes/disk-monitor.log` (epoch + GB free per run)
- Plugin log: `~/.hermes/disk-cleanup/cleanup.log` (auto-created after first plugin cleanup)
- Lockfile: `/tmp/disk-monitor.lock` (prevents overlapping runs)

Telegram alerts are stubbed out (`hermes telegram send …`) and will work once the `telegram` CLI tool is available in PATH.

---

## Rationale

Parallel agent tasks across multiple Telegram channels can generate many ephemeral artifacts (test files, temp session outputs, archived sessions). Even with the `disk-cleanup` plugin running per-session, cumulative churn can fill disk between sessions. A lightweight, independent daemon ensures proactive reclamation before the system hits critical levels, independent of agent uptime.

---

## Next Steps

- [ ] Wire Telegram alerts via `send_message` tool or direct Bot API
- [ ] Add memory pressure monitoring (RAM + swap) and OOM prevention
- [ ] Generalize thresholds per-host (config file in `~/.hermes/`)
