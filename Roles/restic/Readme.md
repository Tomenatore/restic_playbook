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
restic_s3_access_key: "{{ vault_aws_access_key }}"
restic_s3_secret_key: "{{ vault_aws_secret_key }}"

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

Uses **Restic's native repository locks** with automatic stale lock cleanup:
- `restic unlock` is called before each operation to remove stale locks (>30 minutes)
- `--retry-lock 5m` (configurable) allows backup to wait if repository is temporarily locked
- No additional systemd-level lock files needed
- Lock behavior follows Restic's built-in 30-minute staleness threshold
- Per-source `retry_lock_duration` override available for custom wait times

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
