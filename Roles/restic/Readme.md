# Restic Backup Role (Systemd-Based)

Production-ready Ansible role for deploying Restic backups using systemd units and timers. Backups run independently via systemd, decoupled from Ansible execution.

## Features

- **Systemd Integration**: Backups run via systemd timers, not Ansible
- **Instance-Based Units**: Uses systemd instances (`@`) for per-source configuration
- **Intelligent Lock Management**: Auto-detection and cleanup of stale locks with retry logic
- **CheckMK Monitoring**: Per-unit monitoring with custom tags
- **Restic Hooks**: Pre/post-backup tasks as shell scripts
- **Multiple Job Types**: backup, prune, check, scan
- **Syslog Logging**: Centralized logging via syslog
- **Resource Control**: CPU, I/O, and Nice level limits
- **S3-Compatible**: Works with AWS S3, MinIO, Wasabi, Backblaze B2, and others

## Requirements

- Ansible 2.9+
- systemd-based Linux (RHEL/Debian/Ubuntu)
- Restic (installed by role)
- CheckMK agent (optional)


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
│   └── repository.key          # Repository encryption password
├── hooks/
│   ├── pre-backup-<source>.sh  # Optional: Pre-backup hooks
│   └── post-backup-<source>.sh # Optional: Post-backup hooks
└── excludes.txt                # Backup exclusion patterns

/usr/local/bin/restic/
├── backup-<source>.sh          # Backup script per source
├── scan-<source>.sh            # Statistics collection script
└── checkmk-status.sh           # CheckMK integration script

/opt/restic/
├── restic-restore.sh           # Helper script for restore operations
└── restic-repo-info.sh         # Helper script for repo stats and diagnostics
```

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

## Helper Scripts

The role deploys two convenient helper scripts to `/opt/restic/` for administrators. These scripts have all environment variables and credentials pre-configured, making restore operations and repository diagnostics quick and easy.

### Restore Helper (`/opt/restic/restic-restore.sh`)

Interactive restore tool with pre-configured repository access.

**Available Commands:**

```bash
# List all snapshots
/opt/restic/restic-restore.sh list

# List snapshots for specific tag
/opt/restic/restic-restore.sh list-tag var-www

# List files in a snapshot
/opt/restic/restic-restore.sh list-files latest
/opt/restic/restic-restore.sh list-files abc123de

# Find files across all snapshots
/opt/restic/restic-restore.sh find "nginx.conf"
/opt/restic/restic-restore.sh find "*.log"

# Restore entire snapshot
/opt/restic/restic-restore.sh restore latest /tmp/restore
/opt/restic/restic-restore.sh restore abc123de /tmp/restore

# Restore specific file
/opt/restic/restic-restore.sh restore-file latest /tmp "etc/nginx/nginx.conf"

# Restore with verification
/opt/restic/restic-restore.sh restore-verify latest /tmp/restore

# Mount repository for browsing (FUSE)
/opt/restic/restic-restore.sh mount /mnt/restic-mount
# Browse: ls /mnt/restic-mount/snapshots/latest/
/opt/restic/restic-restore.sh umount /mnt/restic-mount

# Compare snapshots
/opt/restic/restic-restore.sh diff abc123de xyz789ab

# Repository maintenance
/opt/restic/restic-restore.sh check
/opt/restic/restic-restore.sh unlock
```

**Features:**
- Pre-configured with repository URL and credentials
- Color-coded output for better readability
- Interactive prompts with safety checks
- Built-in help: `/opt/restic/restic-restore.sh help`

### Repository Info Helper (`/opt/restic/restic-repo-info.sh`)

Repository statistics and diagnostic tool.

**Available Commands:**

```bash
# Quick repository status overview
/opt/restic/restic-repo-info.sh status

# Detailed statistics
/opt/restic/restic-repo-info.sh stats
/opt/restic/restic-repo-info.sh stats-raw        # Actual storage used
/opt/restic/restic-repo-info.sh stats-restore    # Uncompressed size

# Snapshot management
/opt/restic/restic-repo-info.sh snapshots
/opt/restic/restic-repo-info.sh snapshots-latest
/opt/restic/restic-repo-info.sh snapshots-json

# Lock management
/opt/restic/restic-repo-info.sh locks
/opt/restic/restic-repo-info.sh unlock

# Repository checks
/opt/restic/restic-repo-info.sh check            # Quick integrity check
/opt/restic/restic-repo-info.sh check-data       # Full data verification (slow!)

# Maintenance
/opt/restic/restic-repo-info.sh prune-dry        # Preview prune operation
/opt/restic/restic-repo-info.sh size             # Size per snapshot
/opt/restic/restic-repo-info.sh cache-clear      # Clear local cache

# Debugging
/opt/restic/restic-repo-info.sh debug            # Show config and env vars
```

**Features:**
- Pre-configured repository access (no manual env setup needed)
- Color-coded output with status indicators
- Human-readable size formatting
- Safety prompts for destructive operations
- Built-in help: `/opt/restic/restic-repo-info.sh help`

**Example Usage:**

```bash
# Quick check before restore
/opt/restic/restic-repo-info.sh status

# Find latest snapshot
/opt/restic/restic-restore.sh list | tail -n 5

# Check repository integrity
/opt/restic/restic-repo-info.sh check

# Restore specific file from yesterday
/opt/restic/restic-restore.sh find "important.txt"
/opt/restic/restic-restore.sh restore abc123de /tmp

# Browse backups interactively
/opt/restic/restic-restore.sh mount /mnt/backup
ls -lah /mnt/backup/snapshots/latest/etc/
cp /mnt/backup/snapshots/latest/etc/nginx/nginx.conf /tmp/
/opt/restic/restic-restore.sh umount /mnt/backup
```

**Configuration:**

Helper scripts location can be customized:

```yaml
restic_helpers_dir: "/opt/restic"  # Default location
```

Scripts are automatically deployed during role execution with appropriate permissions (755) and pre-configured with:
- Repository URL
- Password file path
- S3/backend credentials (if applicable)
- Retention policy (for prune-dry command)

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

## Monitoring & Debugging

### Check Backup Status

**View all timers and next run times:**
```bash
systemctl list-timers 'restic-*'
```

**Check service status:**
```bash
# Specific source
systemctl status restic-backup@var-www.service
systemctl status restic-backup@var-www.timer

# All backup services
systemctl status 'restic-backup@*'

# Check if service failed
systemctl is-failed restic-backup@var-www.service

# See why service failed (exit code, etc.)
systemctl show restic-backup@var-www.service | grep -E 'Result|ExecMainStatus|ActiveState'
```

**Check retry status (after failures):**
```bash
# See restart count
systemctl show restic-backup@var-www.service | grep NRestarts

# See when next retry is scheduled
systemctl list-timers restic-backup@var-www.timer

# Check service uptime/downtime
systemctl show restic-backup@var-www.service | grep -E 'ActiveEnter|InactiveEnter'
```

### View Logs

**System journal logs:**
```bash
# Follow logs in real-time for specific source
journalctl -u restic-backup@var-www.service -f

# Last 100 lines
journalctl -u restic-backup@var-www.service -n 100

# All restic services today
journalctl -u 'restic-*' --since today

# Only errors
journalctl -u 'restic-*' -p err --since today

# Specific time range
journalctl -u restic-backup@var-www.service --since "2024-01-15 02:00" --until "2024-01-15 03:00"

# Follow all restic operations
journalctl -u 'restic-backup@*' -u 'restic-prune@*' -u 'restic-check@*' -f
```

**Syslog (if configured):**
```bash
# Grep syslog for restic entries
grep restic /var/log/syslog | tail -n 100

# Filter by operation
grep "restic-backup" /var/log/syslog
grep "restic-prune" /var/log/syslog

# Filter by source
grep "restic.*var-www" /var/log/syslog
```

**CheckMK spool files:**
```bash
# View all CheckMK status files
ls -lh /var/lib/check_mk_agent/spool/

# View specific backup status
cat /var/lib/check_mk_agent/spool/*_Restic_backup_var-www

# Check all restic services
cat /var/lib/check_mk_agent/spool/*_Restic_*
```

### Manual Operations

**Trigger backup manually:**
```bash
# Start backup immediately (bypasses timer)
systemctl start restic-backup@var-www.service

# Watch status in real-time
watch systemctl status restic-backup@var-www.service

# Or follow logs
journalctl -u restic-backup@var-www.service -f
```

**Stop running backup:**
```bash
systemctl stop restic-backup@var-www.service
```

**Restart services (reload configuration):**
```bash
# Reload systemd after config changes
systemctl daemon-reload

# Restart timer to apply changes
systemctl restart restic-backup@var-www.timer
```

### Repository Access

**Set up environment for manual restic commands:**
```bash
# Export environment variables
export RESTIC_REPOSITORY="s3:s3.eu-central-1.amazonaws.com/my-bucket/restic"
export RESTIC_PASSWORD_FILE="/etc/restic/passwords/repository.key"
export AWS_ACCESS_KEY_ID="your-access-key"
export AWS_SECRET_ACCESS_KEY="your-secret-key"
export AWS_DEFAULT_REGION="eu-central-1"

# Or source from systemd environment
source <(systemctl show restic-backup@var-www.service -p Environment | sed 's/^Environment=//' | tr ' ' '\n' | sed 's/^/export /')
```

**Check repository status:**
```bash
# List all snapshots
restic snapshots

# List snapshots for specific source
restic snapshots --tag var-www

# Show latest snapshot
restic snapshots --last

# Check repository integrity
restic check

# Check repository statistics
restic stats
restic stats --mode restore-size  # Size after restore
restic stats --mode raw-data       # Actual storage used
```

**List repository locks:**
```bash
# View active locks
restic list locks

# Remove stale locks (>30 minutes)
restic unlock
```

**View backup contents:**
```bash
# List files in latest snapshot
restic ls latest

# List files in specific snapshot
restic snapshots  # Get snapshot ID
restic ls abc123def

# Find specific file across all snapshots
restic find "*.conf"
restic find "/etc/nginx/nginx.conf"

# Show differences between snapshots
restic diff snapshot1 snapshot2
```

## Restore Operations

### List Available Snapshots

```bash
# Setup environment (see "Repository Access" above)
export RESTIC_REPOSITORY="s3:..."
export RESTIC_PASSWORD_FILE="/etc/restic/passwords/repository.key"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

# List all snapshots
restic snapshots

# List snapshots for specific source
restic snapshots --tag var-www

# Show snapshot details
restic snapshots --json | jq '.'

# Find when a specific file was last backed up
restic find "/var/www/index.html"
```

### Restore Files

**Restore entire snapshot:**
```bash
# Restore latest snapshot to original location
restic restore latest --target /

# Restore latest snapshot to temporary location
restic restore latest --target /tmp/restore

# Restore specific snapshot
restic snapshots  # Get snapshot ID
restic restore abc123def --target /tmp/restore
```

**Restore specific files/directories:**
```bash
# Restore single file from latest snapshot
restic restore latest --target /tmp/restore --include /etc/nginx/nginx.conf

# Restore entire directory
restic restore latest --target /tmp/restore --include /var/www/mysite

# Restore with wildcard
restic restore latest --target /tmp/restore --include "*.conf"

# Restore excluding certain paths
restic restore latest --target /tmp/restore --exclude /var/www/cache
```

**Restore from specific point in time:**
```bash
# Find snapshot from specific date
restic snapshots --tag var-www

# Or use time-based filter
restic snapshots --tag var-www --json | jq '.[] | select(.time | startswith("2024-01-15"))'

# Restore that snapshot
restic restore <snapshot-id> --target /tmp/restore
```

### Advanced Restore Examples

**Restore with verification:**
```bash
# Restore and verify
restic restore latest --target /tmp/restore --verify

# Compare with current filesystem
diff -r /var/www /tmp/restore/var/www
```

**Restore to different server:**
```bash
# On source server: Get snapshot info
restic snapshots --tag database

# On target server: Restore using same repository
export RESTIC_REPOSITORY="s3:..."
export RESTIC_PASSWORD_FILE="<path-to-password-file>"
restic restore <snapshot-id> --target /var/lib/mysql
```

**Mount snapshot as filesystem (read-only):**
```bash
# Create mount point
mkdir /mnt/restic-mount

# Mount repository
restic mount /mnt/restic-mount

# Browse backups
ls /mnt/restic-mount/snapshots/
cd /mnt/restic-mount/snapshots/latest/var/www

# Copy files as needed
cp -a /mnt/restic-mount/snapshots/latest/etc/nginx/nginx.conf /tmp/

# Unmount when done
fusermount -u /mnt/restic-mount
```

### Disaster Recovery

**Complete system restore:**
```bash
# 1. Boot from live USB/rescue system
# 2. Mount target filesystem
mount /dev/sda1 /mnt

# 3. Install restic
apt-get install restic  # or download binary

# 4. Set environment
export RESTIC_REPOSITORY="s3:..."
export RESTIC_PASSWORD_FILE="<path-to-password>"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

# 5. List available snapshots
restic snapshots

# 6. Restore system
restic restore latest --target /mnt

# 7. Restore bootloader (if needed)
# 8. Reboot
```

**Emergency password recovery:**
```bash
# If password file is lost but you know the password:
echo "your-repository-password" > /tmp/temp-password.key
export RESTIC_PASSWORD_FILE="/tmp/temp-password.key"

# Test access
restic snapshots

# If successful, redeploy with ansible
ansible-playbook playbook.yml --ask-vault-pass
```

### Restore Troubleshooting

**Problem: "wrong password or no key found"**
```bash
# Verify password file exists and is readable
ls -l /etc/restic/passwords/repository.key
cat /etc/restic/passwords/repository.key  # WARNING: Shows password!

# Try with password directly (testing)
restic -r s3:bucket/path snapshots --password-file <(echo "your-password")

# Check repository exists
aws s3 ls s3://your-bucket/restic/  # For S3
```

**Problem: "repository does not exist"**
```bash
# Verify repository URL
echo $RESTIC_REPOSITORY

# Check S3 access
aws s3 ls s3://your-bucket/restic/config

# Verify credentials
aws sts get-caller-identity
```

**Problem: "restore is slow"**
```bash
# Use parallel downloads
restic restore latest --target /tmp/restore --parallel 8

# Limit bandwidth if needed
restic restore latest --target /tmp/restore --limit-download 10240  # 10 MB/s

# Resume interrupted restore
restic restore latest --target /tmp/restore  # Automatically resumes
```

## Troubleshooting

### Lock Issues

See comprehensive lock troubleshooting in **Lock Management** section above.

### Service Won't Start

**Check for errors:**
```bash
systemctl status restic-backup@var-www.service
journalctl -u restic-backup@var-www.service -n 50 --no-pager
```

**Common issues:**
```bash
# Missing password file
ls -l /etc/restic/passwords/repository.key

# Wrong permissions
chmod 600 /etc/restic/passwords/repository.key

# Systemd syntax error
systemctl daemon-reload
systemctl status restic-backup@var-www.service

# Missing environment variables
systemctl show restic-backup@var-www.service -p Environment
```

### Timer Not Triggering

```bash
# Check timer is enabled
systemctl is-enabled restic-backup@var-www.timer

# Enable if needed
systemctl enable restic-backup@var-www.timer
systemctl start restic-backup@var-www.timer

# Check timer configuration
systemctl cat restic-backup@var-www.timer

# See when next trigger is scheduled
systemctl list-timers restic-backup@var-www.timer
```

### High Resource Usage

```bash
# Check current resource usage
systemctl status restic-backup@var-www.service

# Adjust limits in group_vars/all/vars.yml:
restic_cpu_quota: 50          # Lower CPU usage
restic_upload_limit_kbps: 5120  # Limit to 5 MB/s
restic_nice_level: 19         # Lowest priority

# Apply changes
ansible-playbook playbook.yml --ask-vault-pass
```

### Direct Restic Access

```bash
export RESTIC_REPOSITORY="s3:s3.eu-central-1.amazonaws.com/bucket/prefix"
export RESTIC_PASSWORD_FILE="/etc/restic/passwords/repository.key"
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

restic snapshots
restic stats
```

## License

MIT
