# Restic Backup Ansible Playbook (Systemd-Based)

Production-ready Ansible playbook for automated Restic backups using systemd units and timers.

## Overview

This playbook deploys a complete Restic backup solution that runs independently via systemd, not during Ansible execution. Backups are scheduled via systemd timers and can be monitored through CheckMK.

## Key Features

- **Systemd Integration**: Backups run via systemd timers (decoupled from Ansible)
- **Instance-Based Units**: Per-source systemd services using `@` instances
- **Intelligent Lock Management**: Automatic stale lock cleanup with retry logic
- **Restic Hooks**: Pre/post-backup shell scripts using Restic's native hook system
- **CheckMK Monitoring**: Per-unit status reporting
- **Multiple Job Types**: backup, prune, check, scan operations
- **Resource Control**: CPU, I/O, and Nice level limits per service
- **Flexible Configuration**: Per-source timeouts, retry-lock, and hooks
- **S3-Compatible**: Works with AWS S3, MinIO, Wasabi, Backblaze B2, and others

## Quick Start

### 1. Install Ansible Collections

```bash
ansible-galaxy collection install -r Requirements.yml
```

### 2. Configure Secrets

```bash
# Create encrypted vault
ansible-vault create Group_vars/All/Vault.yml
```

Add:
```yaml
---
vault_s3_access_key: "YOUR_S3_ACCESS_KEY"
vault_s3_secret_key: "YOUR_S3_SECRET_KEY"
vault_restic_password: "YOUR_REPOSITORY_PASSWORD"
```

### 3. Configure Backup Sources

Edit `Group_vars/All/Vars.yml`:

```yaml
restic_backend_type: "s3"
restic_s3_bucket: "my-backups"
restic_s3_region: "eu-central-1"

restic_backup_sources:
  - name: "var-www"
    path: "/var/www"
    tags: ["web", "production"]
    enabled: true

  - name: "etc"
    path: "/etc"
    tags: ["config", "system"]
    enabled: true
```

### 4. Deploy

```bash
ansible-playbook Playbook.yml --ask-vault-pass
```

### 5. Verify

```bash
# List timers
systemctl list-timers 'restic-*'

# Check status
systemctl status restic-backup@var-www.timer

# View logs
journalctl -u 'restic-backup@*' -f
```

## Architecture

### Systemd Units

- `restic-backup@<source>.service/.timer` - Backup per source
- `restic-prune@<source>.service/.timer` - Retention enforcement
- `restic-check@<source>.service/.timer` - Repository integrity check
- `restic-scan@<source>.service/.timer` - Statistics collection

### Directory Structure

```
/etc/restic/
├── passwords/
│   └── repository.key
├── hooks/
│   ├── pre-backup-<source>.sh
│   └── post-backup-<source>.sh
└── excludes.txt

/usr/local/bin/restic/
├── backup-<source>.sh
├── scan-<source>.sh
└── checkmk-status.sh
```

## Hook System

Uses Restic's **native hook system** (RESTIC_PRE_SCRIPT, RESTIC_POST_SCRIPT).

### Option 1: Global Hooks Directory

```yaml
restic_custom_hooks_dir: "{{ playbook_dir }}/hooks"
```

Create hooks as `hooks/pre-backup-<source>.sh` and `hooks/post-backup-<source>.sh`

### Option 2: Per-Source Hooks

```yaml
restic_backup_sources:
  - name: "database"
    path: "/var/lib/postgresql"
    hook_pre_script: "{{ playbook_dir }}/scripts/db-dump.sh"
    hook_post_script: "{{ playbook_dir }}/scripts/db-cleanup.sh"
```

### Option 3: Manual Management

Create hooks directly on target hosts in `/etc/restic/hooks/`

See `hooks/pre-backup-example.sh` and `hooks/post-backup-example.sh` for examples.

## Configuration

### Backend Types

- **S3**: AWS S3 or S3-compatible (MinIO, Wasabi, etc.)
- **Local**: Local filesystem path
- **SFTP**: Remote SFTP server
- **REST**: REST server

### Per-Source Options

```yaml
restic_backup_sources:
  - name: "important-data"
    path: "/data"
    tags: ["critical"]
    enabled: true
    timeout_seconds: 7200              # Backup timeout
    retry_lock_duration: "5m"          # Wait for lock
    hook_pre_script: "path/to/pre.sh"  # Pre-backup hook
    hook_post_script: "path/to/post.sh" # Post-backup hook
```

### Scheduling

Edit timer variables in `Group_vars/All/Vars.yml`:

```yaml
restic_timer_on_calendar: "02:00"         # Daily at 2am
restic_prune_timer_on_calendar: "weekly"  # Weekly
restic_check_timer_on_calendar: "weekly"  # Weekly
restic_scan_timer_on_calendar: "daily"    # Daily
```

## Monitoring

### CheckMK

Services automatically report to CheckMK spool directory:
- `Restic_backup_<source>`
- `Restic_prune_<source>`
- `Restic_check_<source>`
- `Restic_scan_<source>`

### Systemd Management

```bash
# Start backup manually
systemctl start restic-backup@var-www.service

# Enable/disable timer
systemctl enable restic-backup@var-www.timer
systemctl disable restic-backup@var-www.timer

# View logs
journalctl -u restic-backup@var-www.service -n 100
```

## Documentation

- **Role Documentation**: `Roles/restic/Readme.md` - Complete role documentation
- **Example Playbook**: `Playbook_examples.yml` - 19 usage examples
- **Example Hooks**: `hooks/` - Pre/post backup hook examples
- **Inventory**: `Inventory/hosts.ini.example` - Inventory example

## File Structure

```
restic_playbook/
├── Playbook.yml                    # Main playbook
├── Playbook_examples.yml           # Usage examples
├── Requirements.yml                # Ansible collections
├── Readme.md                       # This file
├── Roles/
│   └── restic/
│       ├── Defaults/Main.yml       # Default variables
│       ├── Tasks/                  # Modular task files
│       │   ├── Main.yml
│       │   ├── install.yml
│       │   ├── directories.yml
│       │   ├── encryption.yml
│       │   ├── backend.yml
│       │   ├── repository.yml
│       │   ├── scripts.yml
│       │   ├── hooks.yml
│       │   ├── systemd.yml
│       │   └── timers.yml
│       ├── templates/
│       │   ├── scripts/            # Backup scripts
│       │   └── systemd/            # Systemd units
│       ├── Handlers/Main.yml       # Systemd reload handler
│       └── Readme.md               # Role documentation
├── Group_vars/
│   └── All/
│       ├── Vars.yml                # Configuration
│       └── Vault.yml               # Encrypted secrets
├── Inventory/
│   └── hosts.ini                   # Server inventory
└── hooks/                          # Example hooks
    ├── pre-backup-example.sh
    └── post-backup-example.sh
```

## Requirements

- Ansible 2.9+
- systemd-based Linux (RHEL/Rocky/Alma/Debian/Ubuntu)
- Restic (installed by role)
- Python 3
- CheckMK agent (optional, for monitoring)

## Security

- All passwords encrypted with ansible-vault
- Restic repositories encrypted with strong keys
- No credentials in logs (no_log enabled)
- Systemd service hardening (PrivateTmp, ProtectSystem)
- Repository password file with restrictive permissions (600)

## License

MIT

## Support

For issues, questions, or contributions, see the role's README at `Roles/restic/Readme.md`

## Credits

Based on Restic (https://restic.net/) - Fast, secure, efficient backup program
