# Low-Resource Systems Optimization Guide

**Date:** 2026-04-26  
**Audience:** Hermes Agent on constrained hosts (29G disk, limited RAM)  
**Source:** Industry best practices + tailored for Hermes workflows

---

## TL;DR — 5-Minute Checklist

```bash
# 1. Tmpfs limits — cap /tmp and /dev/shm
sudo mkdir -p /etc/systemd/system/tmp.mount.d
cat | sudo tee /etc/systemd/system/tmp.mount.d/override.conf <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=10%,nr_inodes=500k
EOF
sudo systemctl daemon-reload && sudo systemctl restart tmp.mount

# 2. journald size cap — prevent logs from eating disk
sudo sed -i 's/^#RuntimeMaxUse=/RuntimeMaxUse=100M/' /etc/systemd/journald.conf
sudo sed -i 's/^#SystemMaxUse=/SystemMaxUse=200M/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=150M

# 3. Docker cleanup (if used)
docker system prune -a --volumes -f
cat | sudo tee /etc/docker/daemon.json <<'EOS'
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
EOS
sudo systemctl restart docker

# 4. Weekly cleanup cron
sudo tee /etc/cron.weekly/hermes-clean <<'EOS'
#!/bin/bash
docker image prune -a --filter "until=168h" --force 2>/dev/null || true
rm -rf ~/.hermes/cache/* ~/.hermes/cron/output/*
find ~/.hermes/night-research -type f -mtime +90 -delete 2>/dev/null || true
find /tmp -mindepth 1 -maxdepth 1 -mtime +1 -delete 2>/dev/null || true
EOS
sudo chmod +x /etc/cron.weekly/hermes-clean

# 5. Hermes agent-side disk hygiene (nightly loop 06:30 already)
```

---

## Problem Statement

Your host: **29 GB total storage**, ARM64, running multiple agents + research pipelines.

**Accumulation vectors:**
- **/tmp**: unchecked temp files from scripts, agents, downloads
- **~/.hermes/cache**: LLM response caches, embeddings, intermediate artifacts
- **~/.hermes/cron/output**: logs from every scheduled agent job (grows daily)
- **~/.hermes/night-research**: research artifacts (target: 3–5 MB each, 7–10x/week = 30–50 MB/week)
- **/var/log/journal**: journald logs if persistent mode enabled
- **Docker**: images, volumes, unbounded container logs

At **19G/29G used (68%)**, remaining ~10 GB fills in **2–3 months** without intervention.

---

## System-Level Optimizations

### 1. Tmpfs Hard Limits (Prevent RAM + disk abuse via `/tmp`)

tmpfs grows until ENOSPC or OOM. Default size limit = 50% RAM. Risk: runaway process filling tmpfs → OOM kill.

**Diagnosis:**
```bash
findmnt /tmp
df -hT /tmp      # verify tmpfs type + used
free -h           # available RAM+swap
cat /proc/meminfo | grep -iE 'shmem|memavailable'
```

**Fix — cap to 10% RAM** (safe headroom):
```bash
sudo mkdir -p /etc/systemd/system/tmp.mount.d
sudo tee /etc/systemd/system/tmp.mount.d/override.conf <<'EOF'
[Mount]
Options=mode=1777,strictatime,nosuid,nodev,size=10%,nr_inodes=500k
EOF
sudo systemctl daemon-reload
sudo systemctl restart tmp.mount
```

**Verify:**
```bash
findmnt /tmp
# Size should show 10% of RAM (e.g., 300M on 3GB system)
```

Per-service runtime dirs also use tmpfs (systemd). Add limits via `tmpfiles.d`:
```bash
cat | sudo tee /etc/tmpfiles.d/hermes-clean.conf <<'EOF'
d /run/hermes 0755 root root 10d
EOF
```

**References:** kernel tmpfs(5), Ubuntu 24.04 tmpfs wild guide (2026).

---

### 2. journald Log Size Caps

journald can silently grow if `Storage=persistent`. Even volatile (default) can fill `/run` which is tmpfs.

```bash
# Check current
grep '^Storage' /etc/systemd/journald.conf || echo "Storage=auto (default)"

# Cap
sudo sed -i 's/^#RuntimeMaxUse=/RuntimeMaxUse=100M/' /etc/systemd/journald.conf
sudo sed -i 's/^#SystemMaxUse=/SystemMaxUse=200M/' /etc/systemd/journald.conf
sudo sed -i 's/^#MaxRetentionSec=/MaxRetentionSec=7d/' /etc/systemd/journald.conf
sudo systemctl restart systemd-journald
sudo journalctl --vacuum-size=150M
```

Result: logs bounded at ~200 MB on disk, 100 MB in RAM.

---

### 3. Docker Storage Hygiene (if applicable)

If Docker used, often largest disk consumer.

**Global limits** (`/etc/docker/daemon.json`):
```json
{
  "log-driver": "json-file",
  "log-opts": {"max-size": "10m", "max-file": "3"}
}
```
Limits each container to 30 MB logs max.

**Weekly prune** (`/etc/cron.weekly/docker-cleanup`):
```bash
docker image prune -a --filter "until=168h" --force
docker container prune --force
docker network prune --force
docker builder prune -a --force
```

**Monitor:** `docker system df -v`; `du -sh /var/lib/docker/containers/*/`

**Storage driver:** confirm `overlay2` (`docker info | grep 'Storage Driver'`).

---

### 4. System-Level Weekly Cleanup (Complement to Agent Jobs)

**Script:** `/etc/cron.weekly/system-cleanup`
```bash
#!/bin/bash
apt-get clean
rm -rf /var/cache/thumbnails/*
rm -rf /home/*/.cache/lxsession/* 2>/dev/null
find /tmp -mindepth 1 -maxdepth 1 -mtime +3 -delete 2>/dev/null || true
journalctl --vacuum-size=100M 2>/dev/null || true
find ~/.hermes -name "*.log" -mtime +30 -delete 2>/dev/null || true
```

Agent handles Hermes-specific cleanup; system cron handles distro-level debris.

---

## Hermes-Specific Optimizations

### A. Session Storage Pruning (SQLite)

Sessions table unbounded. Policy:
- Inactive > 30d → `.gz` archive in `~/.hermes/sessions/archive/`
- Inactive > 90d → delete (unless pinned)

**Implementation:** add to Disk Cleanup job:
```bash
sqlite3 ~/.hermes/memory.db "UPDATE sessions SET status='archived' WHERE last_active < date('now', '-30 days')"
gzip ~/.hermes/sessions/*.db 2>/dev/null || true
```

### B. Nightly Research Rotation (now: keep 2d archive)

Enhance `~/.hermes/scripts/prune-night-research.sh`:
```bash
#!/bin/bash
DIR=~/.hermes/night-research
# Keep 7 days verbatim
find "$DIR" -type f -mtime +7 -mtime -30 -name "*.md" -exec gzip -9 {} \;
# Archive older, then delete
find "$DIR" -type f -mtime +30 -delete 2>/dev/null || true
```

---

### C. Cache LRU Eviction (Size-Bounded)

Cache unbounded → regrows after purge. Implement LRU:

**File:** `~/.hermes/lib/cache_manager.py`

```python
import os, time, heapq
CACHE_DIR = os.path.expanduser("~/.hermes/cache")
MAX_TOTAL_MB = 100

def enforce_lru():
    entries = []
    for f in os.listdir(CACHE_DIR):
        fp = os.path.join(CACHE_DIR, f)
        if os.path.isfile(fp):
            size = os.path.getsize(fp)
            mtime = os.path.getmtime(fp)
            entries.append((fp, size, mtime))
    total = sum(s for _, s, _ in entries)
    # LRU order (oldest mtime first)
    entries.sort(key=lambda x: x[2])
    while total > MAX_TOTAL_MB * 1024 * 1024 and entries:
        fp, size, _ = entries.pop(0)
        os.remove(fp)
        total -= size

if __name__ == "__main__":
    enforce_lru()
```

Hook: call after every `write_file()` to cache, plus nightly (06:30).

---

### D. Agent Context Compression (Three-Layer Strategy)

On constrained RAM, active context (conversation history) competes with LLM context window — expensive at scale.

**Layer 1 — Micro-Compact** (per turn, silent)
- Replace `{tool_result}` > 3 turns old with placeholder `[Previously used: tool_name]`
- No LLM cost, O(1) heuristic

**Layer 2 — Auto-Compact** (threshold: 50K tokens)
1. Serialize full message list → `~/.hermes/transcripts/<session>.jsonl` (persist to disk)
2. Ask LLM: *"Summarize this conversation for continuity (key decisions, file paths, errors, next steps). Max 500 words."*
3. Replace all but last 10 messages with summary bubble
4. Transcript remains on disk for audit

**Layer 3 — Compact Suggest** (>80% of max ctx)
- Agent emits internal `compact_context` tool call before final response
- User sees nothing; agent autonomously compacts to make room

**Cost:** Layer2 ≈ $0.01–$0.05 per compression. Schedules: every ~100 turns.

**Config** (`~/.hermes/config.yaml`):
```yaml
compression:
  micro_compact_after_turns: 3
  auto_compact_tokens: 50000
  manual_suggest_ratio: 0.8
  transcript_path: ~/.hermes/transcripts/
  retention_days: 90
```

---

## Operational Hygiene Cadence

| Cadence | Task | Owner |
|---------|------|-------|
| **Daily (agent, 06:30)** | Clear `~/.hermes/cache/`, `~/.hermes/cron/output/`, prune night-research | Disk Cleanup job |
| **Daily (agent, 09:00)** | Push research → GitHub, then local `rm -rf ~/.hermes/night-research/*` (already pushed artifacts live on GitHub) | Daily Learnings job |
| **Weekly (Sun 06:00)** | Full lint, insights digest, also trigger cache LRU enforcement | Weekly Digest job |
| **Monthly (1st, 02:00)** | `journalctl --vacuum-time=7d`, `git gc --aggressive`, `find ~/.hermes -name "*.log" -mtime +30 -delete` | Monthly Cleanup job |
| **Ad-hoc** | `docker system prune -a` (if Docker used), `journalctl --vacuum-size=150M` | Manual |

---

## Monitoring & Alerting (Add to Hermes Telegram Bot)

Endpoints:
```
/hermes disk        → df -h /home / /tmp /var
/hermes ram         → free -h | grep -E 'Mem|Swap'
/hermes tmpfs       → df -hT /tmp /dev/shm /run | grep tmpfs
```

Thresholds:
- `/home` > 85% used → ⚠️ alert
- `/tmp` tmpfs Used > 85% → alert (potential tmpfs abuse)
- RAM available < 15% → alert (consider OOM risk)

Already have Telegram alerts via cron job output; upgrade to include these.

---

## Cost-Benefit & Effort Matrix

| Optimization | Effort | Saved / month | RAM impact | Priority |
|--------------|--------|---------------|------------|----------|
| journald cap | 5 min | 500 MB–2 GB | none | **HIGH** |
| Weekly system cleanup | 10 min | ~200 MB | none | **HIGH** |
| Cache LRU eviction | 1–2 hrs dev | 100–500 MB | minimal | **MEDIUM** |
| Tmpfs size cap | 10 min | prevents OOM | smaller /tmp | **MEDIUM** |
| Session archive/prune | 30 min dev | 5–10 MB/mo | none | LOW |
| Docker log rotation | 10 min | 10–50 GB/yr | none | **HIGH** |
| Context compression | 2–3 hrs dev | ↓ token spend | ↓ latency | **HIGH** |

Quick wins first (3 hrs total → ~2 GB/mo saved + OOM prevention).

---

## Immediate Next Steps

1. **Now** (manual): journald vacuum + set caps
2. **Today** (commit): add `prune-night-research.sh` to `~/.hermes/scripts/`, commit to GitHub, call from Disk Cleanup job
3. **This week** (dev): implement `cache_manager.py`, hook into write paths
4. **Next sprint** (dev): three-layer context compression for agent
5. **Document** in `docs/operations.md` all thresholds + recovery steps

---

*Researched 2025–2026 best practices: systemd-tmpfiles policies, tmpfs sizing, journald vacuum strategies, Docker log caps, context window compression techniques (OpenAI Agents SDK, LLMingua, sliding window + summarization). Adapted for Hermes agent architecture — 29G host, nightly research flow, memory-constrained operation.*
