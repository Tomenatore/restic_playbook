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
