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
└── excludes.txt

/usr/local/bin/restic/
├── backup-<source>.sh
├── scan-<source>.sh
├── pre-backup-<source>.sh
├── post-backup-<source>.sh
└── checkmk-status.sh

/var/run/restic/
└── <source>.lock
```

## 2-Key Encryption

- **Generic Key**: Shared across multiple environments
- **Playbook Key**: Environment-specific (default)

Use `restic_use_playbook_key: false` to switch to generic key.

## Lock Management

Automatically handles stale locks:
- Locks older than `restic_lock_max_age_hours` (default: 12h) are removed
- `restic unlock` is called automatically
- Fresh locks abort the job to prevent conflicts

## Pre/Post-Backup Hooks

Uses Restic's **native hook system** (`RESTIC_PRE_SCRIPT`, `RESTIC_POST_SCRIPT`). Restic automatically calls these scripts before/after backup.

### Option 1: Inline Configuration (Default Templates)

```yaml
restic_backup_sources:
  - name: "database"
    path: "/var/lib/postgresql"
    enabled: true

    pre_backup_commands:
      - "pg_dumpall > /var/backups/db.sql"

    post_backup_commands:
      - "rm -f /var/backups/db.sql"

    stop_services:
      - postgresql

    start_services:
      - postgresql
```

Role generates hook scripts in `/etc/restic/hooks/` from templates.

### Option 2: Custom Hook Scripts from Playbook

Create custom hooks in your playbook directory:

```bash
playbook_dir/
  hooks/
    pre-backup-database.sh
    post-backup-database.sh
    pre-backup-files.sh
    post-backup-files.sh
```

Configure role to copy them:

```yaml
restic_custom_hooks_dir: "{{ playbook_dir }}/hooks"
```

### Option 3: Manual Hook Management

Disable automatic deployment and manually create hooks:

```yaml
restic_deploy_default_hooks: false
```

Then manually create hooks in `/etc/restic/hooks/`:
- `pre-backup-<source>.sh`
- `post-backup-<source>.sh`

### Hook Script Requirements

- **Pre-hook**: Exit code 0 = continue, non-zero = abort backup
- **Post-hook**: Receives backup exit status as `$1`
- **Executable**: Scripts must have execute permission
- **Naming**: `pre-backup-<source-name>.sh`, `post-backup-<source-name>.sh`

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
  - name: "identifier"          # Required: alphanumeric + hyphens
    path: "/path/to/backup"     # Required
    tags: ["tag1", "tag2"]      # Optional
    enabled: true               # Optional
    pre_backup_commands: []     # Optional
    post_backup_commands: []    # Optional
    stop_services: []           # Optional
    start_services: []          # Optional
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
