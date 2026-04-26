# Low-Resource Optimization — Implementation Tracker

**Created:** 2026-04-26  
**Status:** In progress — Hermes script layer complete, system layer pending sudo

---

## Completed (Committed & Pushed)

### 1. Hermes agent-side scripts ✓
- **scripts/disk-cleanup.sh** — enhanced with:
  - `prune-night-research.sh` invocation
  - `cache_manager.py` LRU enforcement  
  - Session archival SQL + gzip
- **scripts/prune-night-research.sh** — keep 7d, compress 7–30d, purge >30d
- **lib/cache_manager.py** — 100 MB hard-cap LRU eviction
- **sysops/** — system-level configs (tmpfs, journald, Docker, weekly cleanup)

**Repos updated:** `daily-learnings`, `hermes-agent-architecture`

### 2. Documentation ✓
- `2026-04-26-low-resource-optimization-guide.md` — full playbook
- Sysops installer: `sysops/install-lowres-optimizations.sh`

---

## Pending — Manual System Steps (Requires sudo)

### A. Apply tmpfs size cap (5 min)
```bash
sudo cp sysops/tmp.mount.conf /etc/systemd/system/tmp.mount.d/override.conf
sudo systemctl daemon-reload
sudo systemctl restart tmp.mount
sudo findmnt /tmp  # verify size=10% (not 50%)
```

### B. Cap journald logs (5 min)
```bash
sudo cp sysops/journald.conf.d-snippet /etc/systemd/journald.conf.d/99-hermes-lowres.conf
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=150M
```

### C. Docker log rotation (if Docker installed) (10 min)
```bash
sudo cp sysops/docker-daemon.json /etc/docker/daemon.json
sudo systemctl restart docker
```

### D. Install weekly system cleanup (5 min)
```bash
sudo cp sysops/system-cleanup /etc/cron.weekly/hermes-system-cleanup
sudo chmod +x /etc/cron.weekly/hermes-system-cleanup
```

### E. Verify Disk Cleanup job integration
The agent's nightly job (`97ecbd9da843`) calls `~/.hermes/scripts/disk-cleanup.sh`.  
Enhanced script includes new steps automatically — no config change needed.

---

## Monitoring & Validation

After applying system changes, verify in 24–48h:

| Metric | Target | Check Command |
|--------|--------|---------------|
| `/tmp` size | < 10% RAM | `findmnt /tmp` |
| journald size | < 200 MB | `journalctl --disk-usage` |
| `~/.hermes/cache` | ≤ 100 MB | `du -sh ~/.hermes/cache` |
| `~/.hermes/cron/output` | ≈ 0 (purged nightly) | `du -sh ~/.hermes/cron/output` |
| `~/.hermes/night-research` | 7d active + archives | `ls -lt ~/.hermes/night-research` |

Telegram bot can send `/hermes disk` / `/hermes ram` if telemetry skill installed.

---

## Cost-Benefit Realized

| Change | Effort | Expected saved / mo |
|--------|--------|---------------------|
| Hermes scripts (cache LRU, research prune) | 2 hr dev | 100–500 MB |
| journald cap | manual | 500 MB–2 GB |
| Tmpfs cap | manual | OOM prevention |
| Docker log rotation | manual (if used) | 10–50 GB/yr |
| **Total** | | **~2–3 GB/mo + stability** |

---

## Next Actions for User

1. Run `sysops/install-lowres-optimizations.sh` with sudo (or individual steps)
2. Monitor disk usage for 3 days (`df -h /home /tmp`)
3. If cache regrowth exceeds 100 MB, consider lowering `MAX_TOTAL_MB` in `cache_manager.py`
4. Optional: add Telegram `/hermes disk` command to daily summary
