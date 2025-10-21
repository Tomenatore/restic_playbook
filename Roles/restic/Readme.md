# Restic Backup Role (Systemd-Based)

Production-ready Ansible role for deploying Restic backups using systemd units and timers. Backups run independently via systemd, decoupled from Ansible execution.

## Features

- **Systemd Integration**: Backups run via systemd timers, not Ansible
- **Instance-Based Units**: Uses systemd instances (`@`) for per-source configuration
- **2-Key Encryption**: Generic + playbook-specific encryption keys
- **Stale Lock Management**: Auto-detection and cleanup of stale locks
- **CheckMK Monitoring**: Per-unit monitoring with custom tags
- **Restic Hooks**: Pre/post-backup tasks as shell scripts
- **Multiple Job Types**: backup, prune, check, scan
- **Syslog Logging**: Centralized logging via syslog
- **Resource Control**: CPU, I/O, and Nice level limits

## Requirements

- Ansible 2.9+
- systemd-based Linux (RHEL/Debian/Ubuntu)
- Restic (installed by role)
- CheckMK agent (optional)

## Quick Start

### 1. Configure Variables

**group_vars/all/vars.yml:**
```yaml
restic_backend_type: "s3"
restic_s3_bucket: "my-backups"
restic_s3_region: "eu-central-1"
restic_s3_access_key: "{{ vault_s3_access_key }}"
restic_s3_secret_key: "{{ vault_s3_secret_key }}"

restic_playbook_password: "{{ vault_restic_playbook_password }}"
restic_generic_password: "{{ vault_restic_generic_password }}"

restic_backup_sources:
  - name: "var-www"
    path: "/var/www"
    tags: ["web"]
    enabled: true

restic_timer_on_calendar: "02:00"  # Daily at 2am
```

### 2. Deploy

```bash
ansible-playbook playbook.yml --ask-vault-pass
```

### 3. Verify

```bash
systemctl list-timers 'restic-*'
journalctl -u 'restic-backup@*' -f
```

## Architecture

### Systemd Units

- `restic-backup@<source>.service/.timer` - Backup per source
- `restic-prune@<source>.service/.timer` - Retention enforcement
- `restic-check@<source>.service/.timer` - Repository integrity
- `restic-scan@<source>.service/.timer` - Statistics collection

### Directory Structure

```
/etc/restic/
├── passwords/
│   ├── generic.key
│   └── playbook.key
├── hooks/
│   ├── pre-backup-<source>.sh
│   └── post-backup-<source>.sh
└── excludes.txt

/usr/local/bin/restic/
├── backup-<source>.sh
├── scan-<source>.sh
└── checkmk-status.sh
```

## 2-Key Encryption

- **Generic Key**: Shared across multiple environments
- **Playbook Key**: Environment-specific (default)

Use `restic_use_playbook_key: false` to switch to generic key.

## Lock Management

This role implements a sophisticated lock management system combining Restic's native locks with intelligent systemd retry logic.

### Overview: Two Lock Systems

#### 1. Restic's Native Repository Lock System
- **Hardcoded in Restic**: Locks older than 30 minutes are considered "stale"
- **Command**: `restic unlock` removes locks older than 30 minutes
- **Not configurable**: The 30-minute threshold is built into Restic
- **Purpose**: Prevents concurrent repository access, handles crash recovery

#### 2. Our Intelligent Lock Detection (ExecStartPre)
- **Configurable**: `restic_lock_max_age_hours: 12` (default)
- **Logic**: Check if locks exist AND if they exceed our threshold
- **Only then**: Call `restic unlock` to clean up crash locks
- **Fresh locks**: Pass through to `--retry-lock` mechanism

### How It Works: Three-Layer Strategy

```
┌─────────────────────────────────────────────────────────────┐
│ Layer 1: ExecStartPre - Stale Lock Detection               │
│ ─────────────────────────────────────────────────────────── │
│ • Check: Does lock exist?                                   │
│ • Check: Is lock older than restic_lock_max_age_hours?     │
│ • If YES: Call 'restic unlock' (crash recovery)            │
│ • If NO: Pass through (let --retry-lock handle it)         │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 2: --retry-lock - Short-term Wait                    │
│ ─────────────────────────────────────────────────────────── │
│ • Backup: --retry-lock 5m (high priority)                  │
│ • Prune/Check/Scan: --retry-lock 30s (low priority)        │
│ • Waits for lock release during this period                │
│ • If timeout: EXIT 1 (triggers Layer 3)                    │
└─────────────────────────────────────────────────────────────┘
                            ↓
┌─────────────────────────────────────────────────────────────┐
│ Layer 3: Systemd Restart - Long-term Retry                 │
│ ─────────────────────────────────────────────────────────── │
│ • Restart=on-failure                                        │
│ • RestartSec=15min (configurable)                          │
│ • Retries until success or max attempts reached            │
│ • Default: Unlimited retries (restic_restart_max_attempts=0)│
└─────────────────────────────────────────────────────────────┘
```

### Configuration Variables

```yaml
# Stale lock detection threshold (crash recovery)
restic_lock_max_age_hours: 12         # Default: 12 hours
# Per-source override:
# lock_max_age_hours: 6

# Retry-lock duration (short-term wait)
restic_retry_lock_duration: "5m"      # Backup default
# Per-source override:
# retry_lock_duration: "10m"

# Systemd restart interval (long-term retry)
restic_restart_sec: "15min"           # Wait between retries
restic_restart_max_attempts: 0        # 0 = unlimited
```

### Scenario Examples

#### Scenario A: Normal Concurrent Operation (Lock < 12 hours)

**Timeline:**
```
14:00:00  Backup starts for source "var-www"
          → Repository LOCKED by backup process

14:30:00  Prune timer fires (weekly schedule)

          [ExecStartPre - Layer 1]
          ├─ restic list locks --no-lock
          ├─ Lock found: 30 minutes old
          ├─ Threshold: 12 hours (43200 seconds)
          ├─ 30min < 12h → NO unlock
          └─ Log: "Lock exists (age: 1800s), will use --retry-lock"

          [ExecStart - Layer 2]
          ├─ restic forget --prune --retry-lock 30s
          ├─ Waits 30 seconds for lock release
          ├─ Lock still held (backup running)
          └─ EXIT 1

          [Systemd - Layer 3]
          ├─ Restart=on-failure triggered
          ├─ Wait RestartSec=15min
          └─ Schedule retry for 14:45:00

14:45:00  Prune Retry #1
          → Same process, backup still running → EXIT 1
          → Next retry: 15:00:00

15:00:00  Prune Retry #2
          → Same process, backup still running → EXIT 1
          → Next retry: 15:15:00

... (continues every 15 minutes) ...

16:00:00  Backup completes
          → Repository UNLOCKED

16:15:00  Prune Retry #N

          [ExecStartPre - Layer 1]
          ├─ restic list locks --no-lock
          ├─ No locks found
          └─ Pass through

          [ExecStart - Layer 2]
          ├─ restic forget --prune --retry-lock 30s
          ├─ No lock detected
          ├─ Prune runs successfully
          └─ EXIT 0 ✓

          [Systemd - Layer 3]
          └─ Success - no more retries
```

**Result**: Prune succeeded after backup completed, ~16 retries over 4 hours.

---

#### Scenario B: Stale Lock from Crash (Lock > 12 hours)

**Timeline:**
```
02:00:00  Backup started yesterday
02:30:00  Server crashed during backup
          → Lock file remains (age: 0 hours)

... 15 hours pass ...

17:30:00  Server rebooted
18:00:00  Next backup timer fires

          [ExecStartPre - Layer 1]
          ├─ restic list locks --no-lock
          ├─ Lock found: 15 hours 30 minutes old (55800 seconds)
          ├─ Threshold: 12 hours (43200 seconds)
          ├─ 15.5h > 12h → YES, call unlock!
          ├─ Log: "Removing stale lock (age: 55800s > 43200s)"
          ├─ Execute: restic unlock
          │  └─ Restic removes lock (>30 min = stale for Restic)
          └─ Lock removed ✓

          [ExecStart - Layer 2]
          ├─ restic backup /var/www --retry-lock 5m
          ├─ No lock detected
          ├─ Backup runs successfully
          └─ EXIT 0 ✓
```

**Result**: Stale lock automatically cleaned up, backup succeeded immediately.

---

#### Scenario C: Backup Priority Over Maintenance

**Timeline:**
```
14:00:00  Prune starts (runs ~30 minutes)
          → Repository LOCKED by prune

14:05:00  Backup timer fires (daily schedule)

          [ExecStartPre - Layer 1]
          ├─ Lock found: 5 minutes old
          ├─ 5min < 12h → NO unlock
          └─ Pass through

          [ExecStart - Layer 2]
          ├─ restic backup /var/www --retry-lock 5m
          ├─ Waits up to 5 MINUTES for lock
          ├─ After 25 minutes: Prune completes
          ├─ Lock released
          ├─ Backup acquires lock and runs
          └─ EXIT 0 ✓

          [Systemd - Layer 3]
          └─ Success - no restart needed
```

**Result**: Backup waited 25 minutes (within 5m retry window), succeeded without restart.

---

#### Scenario D: Multiple Concurrent Sources (No Conflict)

**Timeline:**
```
02:00:00  Backup timer fires for 3 sources

          [Source: var-www]
          ├─ Instance: restic-backup@var-www.service
          ├─ Lock: var-www-specific (per-source isolation)
          └─ Runs independently ✓

          [Source: home]
          ├─ Instance: restic-backup@home.service
          ├─ Lock: home-specific (per-source isolation)
          └─ Runs independently ✓

          [Source: etc]
          ├─ Instance: restic-backup@etc.service
          ├─ Lock: etc-specific (per-source isolation)
          └─ Runs independently ✓
```

**Note**: Restic locks are per-repository. If all sources use the **same repository**, they WILL conflict and retry. Use separate repositories for true parallelism.

---

### Lock Priorities by Operation

| Operation | --retry-lock | Restart | Priority | Reason |
|-----------|-------------|---------|----------|--------|
| **Backup** | 5m | Yes | 🔴 High | Data loss prevention critical |
| **Prune** | 30s | Yes | 🟡 Medium | Space management important |
| **Check** | 30s | Yes | 🟡 Medium | Integrity verification important |
| **Scan** | 30s | No | 🟢 Low | Statistics only, not critical |

### Troubleshooting Lock Issues

#### Problem: "Backup never completes, constant retries"

**Diagnosis:**
```bash
# Check current locks
restic -r s3:bucket/path list locks

# Check lock age
restic -r s3:bucket/path list locks | grep "at"

# Check systemd retry status
systemctl status restic-backup@var-www.service
journalctl -u restic-backup@var-www.service -f
```

**Common causes:**
1. Another process holding lock (check other backups, manual runs)
2. Network issues preventing lock release
3. Stuck process (check `ps aux | grep restic`)

**Solutions:**
```bash
# Manual unlock (removes locks >30 min)
restic -r s3:bucket/path unlock

# Force kill stuck process
systemctl stop restic-backup@var-www.service
killall -9 restic
restic -r s3:bucket/path unlock

# Adjust thresholds
# In group_vars or playbook:
restic_lock_max_age_hours: 6     # More aggressive cleanup
restic_restart_sec: "5min"       # Faster retries
```

---

#### Problem: "Prune never runs, always retries"

**Likely cause**: Backup runs too long, prune can't get lock

**Solution 1 - Increase retry window:**
```yaml
restic_backup_sources:
  - name: "large-dataset"
    path: "/mnt/data"
    retry_lock_duration: "10m"    # Prune can wait longer
```

**Solution 2 - Adjust schedules:**
```yaml
# Backup daily at 02:00
restic_timer_on_calendar: "daily"

# Prune weekly on Sunday at 04:00 (when backup unlikely to run)
restic_prune_timer_on_calendar: "Sun *-*-* 04:00:00"
```

**Solution 3 - Separate repositories:**
```yaml
# Use different repos per source to avoid conflicts
restic_repository: "s3:bucket/{{ inventory_hostname }}/{{ item.name }}"
```

---

### Advanced Configuration

#### Per-Source Lock Configuration

```yaml
restic_backup_sources:
  - name: "critical-database"
    path: "/var/lib/mysql"
    lock_max_age_hours: 4          # Aggressive crash detection
    retry_lock_duration: "10m"     # Wait longer for lock

  - name: "large-files"
    path: "/mnt/storage"
    lock_max_age_hours: 24         # Tolerant of long operations
    retry_lock_duration: "15m"     # Very patient
```

#### Debugging Lock Behavior

Enable debug logging:
```yaml
restic_debug_mode: true            # WARNING: Logs passwords!
```

Watch locks in real-time:
```bash
# Terminal 1: Watch service
journalctl -u restic-backup@var-www.service -f

# Terminal 2: Monitor locks
watch -n 5 'restic -r s3:bucket/path list locks'

# Terminal 3: Check retry count
systemctl show restic-backup@var-www.service | grep Restart
```

## Pre/Post-Backup Hooks

Uses Restic's **native hook system** (`RESTIC_PRE_SCRIPT`, `RESTIC_POST_SCRIPT`). Restic automatically calls these scripts before/after backup.

**Hooks are optional** - if not present, backup runs without hooks.

### Example Hook Scripts

See `hooks/pre-backup-example.sh` and `hooks/post-backup-example.sh` in the playbook directory for comprehensive examples with:
- Database dumps
- Service management
- LVM snapshots
- Docker containers
- And more...

### Option 1: Global Hooks Directory

Create hooks in your playbook directory:

```bash
your-playbook/
  hooks/
    pre-backup-database.sh    # For source "database"
    post-backup-database.sh
    pre-backup-files.sh       # For source "files"
    post-backup-files.sh
```

Configure role to copy them:

```yaml
restic_custom_hooks_dir: "{{ playbook_dir }}/hooks"
```

Role copies `pre-backup-<source>.sh` and `post-backup-<source>.sh` to target hosts.

### Option 2: Per-Source Hook Scripts

Specify hook scripts per source:

```yaml
restic_backup_sources:
  - name: "database"
    path: "/var/lib/postgresql"
    enabled: true
    hook_pre_script: "{{ playbook_dir }}/scripts/db-pre-backup.sh"
    hook_post_script: "{{ playbook_dir }}/scripts/db-post-backup.sh"

  - name: "files"
    path: "/var/files"
    enabled: true
    hook_pre_script: "{{ playbook_dir }}/scripts/files-pre.sh"
    # No post-hook for this source
```

Allows different hook scripts per source with custom naming.

### Option 3: Manual Hook Management

Create hooks directly on target hosts:

```bash
# On target host
mkdir -p /etc/restic/hooks
vi /etc/restic/hooks/pre-backup-database.sh
vi /etc/restic/hooks/post-backup-database.sh
chmod +x /etc/restic/hooks/*.sh
```

No Ansible configuration needed - just create the hooks manually.

### Hook Script Requirements

- **Pre-hook**: Exit code 0 = continue, non-zero = abort backup
- **Post-hook**: Receives backup exit status as `$1`
- **Executable**: Scripts must have execute permission (`chmod +x`)
- **Naming**: `pre-backup-<source-name>.sh`, `post-backup-<source-name>.sh`
- **Location**: `/etc/restic/hooks/` (default, configurable via `restic_hooks_dir`)

## CheckMK Integration

Service names:
- `Restic_backup_<source>`
- `Restic_prune_<source>`
- `Restic_check_<source>`
- `Restic_scan_<source>`

Status codes: `0=OK`, `1=WARNING`, `2=CRITICAL`

Metrics: `size`, `files` (backup/scan only)

## Systemd Management

```bash
# List timers
systemctl list-timers 'restic-*'

# Check status
systemctl status restic-backup@var-www.timer
systemctl status restic-backup@var-www.service

# View logs
journalctl -u 'restic-backup@*' -f
journalctl -u restic-backup@var-www.service

# Manual trigger
systemctl start restic-backup@var-www.service

# Enable/disable
systemctl enable restic-backup@var-www.timer
systemctl disable restic-backup@var-www.timer
```

## Key Variables

### Backend (S3)

| Variable | Default | Description |
|----------|---------|-------------|
| `restic_backend_type` | `s3` | Backend type |
| `restic_s3_bucket` | - | S3 bucket |
| `restic_s3_region` | `eu-central-1` | AWS region |
| `restic_s3_endpoint` | - | Custom endpoint |

### Backup Sources

```yaml
restic_backup_sources:
  - name: "identifier"                    # Required: alphanumeric + hyphens
    path: "/path/to/backup"               # Required
    tags: ["tag1", "tag2"]                # Optional
    enabled: true                         # Optional
    timeout_seconds: 7200                 # Optional: backup timeout (0 = unlimited)
    lock_max_age_hours: 12                # Optional: stale lock threshold
    retry_lock_duration: "5m"             # Optional: wait duration if locked
    hook_pre_script: "path/to/pre.sh"     # Optional: pre-backup hook script
    hook_post_script: "path/to/post.sh"   # Optional: post-backup hook script
    hook_script_dir: "/etc/restic/hooks"  # Optional: hooks directory
```

### Timers

| Variable | Default | Description |
|----------|---------|-------------|
| `restic_timer_on_calendar` | `daily` | Backup schedule |
| `restic_timer_randomized_delay` | `30min` | Random delay |
| `restic_prune_timer_on_calendar` | `weekly` | Prune schedule |
| `restic_check_timer_on_calendar` | `weekly` | Check schedule |

### Retention

| Variable | Default |
|----------|---------|
| `restic_retention_keep_last` | `7` |
| `restic_retention_keep_daily` | `14` |
| `restic_retention_keep_weekly` | `8` |
| `restic_retention_keep_monthly` | `12` |
| `restic_retention_keep_yearly` | `5` |

### Lock & Retry Management

| Variable | Default | Description |
|----------|---------|-------------|
| `restic_lock_max_age_hours` | `12` | Stale lock threshold for cleanup |
| `restic_retry_lock_duration` | `5m` | Wait time for locks (backup) |
| `restic_restart_sec` | `15min` | Wait between systemd retries |
| `restic_restart_max_attempts` | `0` | Max retries (0=unlimited) |
| `restic_backup_timeout_seconds` | `0` | Backup timeout (0=unlimited) |
| `restic_check_read_data` | `false` | Full data verification |
| `restic_check_read_data_subset` | `""` | Partial check ("1/12", "10%") |

**Note**: Prune/Check/Scan use `--retry-lock 30s` (hardcoded, lower priority than backup).

### Performance

| Variable | Default | Description |
|----------|---------|-------------|
| `restic_cpu_quota` | `80` | CPU % (100=1 core) |
| `restic_io_weight` | `100` | I/O weight |
| `restic_nice_level` | `10` | Nice level |
| `restic_upload_limit_kbps` | `0` | Upload limit (0=unlimited) |

## Troubleshooting

### Check Timers

```bash
systemctl list-timers 'restic-*'
```

### View Logs

```bash
journalctl -u restic-backup@var-www.service -n 100
journalctl -u 'restic-*' --since today
```

### Manual Test

```bash
systemctl start restic-backup@var-www.service
systemctl status restic-backup@var-www.service
```

### Check Locks

```bash
ls -lah /var/run/restic/
```

### CheckMK Status

```bash
cat /var/lib/check_mk_agent/spool/*_Restic_backup_*
```

### Direct Restic Access

```bash
export RESTIC_REPOSITORY="s3:s3.eu-central-1.amazonaws.com/bucket/prefix"
export RESTIC_PASSWORD_FILE="/etc/restic/passwords/playbook.key"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

restic snapshots
restic stats
```

## Migration from Old Role

| Old Variable | New Variable |
|--------------|--------------|
| `backup_target_type` | `restic_backend_type` |
| `s3_bucket` | `restic_s3_bucket` |
| `backup_sources` | `restic_backup_sources` |
| `enable_checkmk` | `restic_enable_checkmk` |
| `retention_policy.keep_daily` | `restic_retention_keep_daily` |

Steps:
1. Update role name: `restic_backup` → `restic`
2. Add `restic_` prefix to all variables
3. Remove Ansible scheduling (cron/Tower)
4. Convert pre/post tasks to hooks
5. Deploy new role
6. Verify: `systemctl list-timers 'restic-*'`

## License

MIT
