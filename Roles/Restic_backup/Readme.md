# Restic Backup Ansible Role

Production-ready Ansible role for automated Restic backups with Check_MK monitoring.

## 🎯 Features

- ✅ **Flexible Backup Targets**: S3 (AWS, MinIO, Wasabi) or local folders (NFS, USB)
- ✅ **Intelligent Time Control**: Configurable intervals and time windows
- ✅ **Check_MK Integration**: Automatic monitoring via spool directory
- ✅ **Custom Pre/Post Actions**: Via external task files
- ✅ **Idempotent**: Can be executed repeatedly without side effects
- ✅ **Robust Error Handling**: Backup errors don't prevent post-tasks
- ✅ **Repository Checks**: Automatic integrity verification
- ✅ **Encrypted**: End-to-end encryption with AES-256
- ✅ **Syslog Integration**: Comprehensive logging
- ✅ **Production Ready**: Handles partial failures gracefully

## 📦 Prerequisites

### Ansible Collections

```bash
ansible-galaxy collection install -r requirements.yml
```

Required:
- `community.general` (for syslog logging)

Optional (for pre/post tasks):
- `community.mysql` (for MySQL dumps)
- `community.postgresql` (for PostgreSQL dumps)
- `community.docker` (for Docker management)

### Restic Binary

The role installs Restic automatically:
- **RHEL/Rocky/Alma**: Via EPEL + DNF
- **Debian/Ubuntu**: Via APT

## 📁 Directory Structure

```
ansible-backup-project/
├── roles/
│   └── restic_backup/
│       ├── defaults/
│       │   └── main.yml          # Default variables
│       └── tasks/
│           └── main.yml          # Backup tasks
├── tasks/                         # External pre/post tasks
│   ├── pre_backup_tasks.yml
│   └── post_backup_tasks.yml
├── group_vars/
│   └── all/
│       ├── vars.yml               # Backup configuration
│       └── vault.yml              # Encrypted secrets
├── inventory/
│   └── hosts.ini                  # Server list
└── playbook.yml                   # Main playbook
```

## 🚀 Quick Start

### 1. Create Vault File

```bash
ansible-vault create group_vars/all/vault.yml
```

**Content:**
```yaml
# AWS S3 Credentials
vault_aws_access_key: "AKIAIOSFODNN7EXAMPLE"
vault_aws_secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

# Restic Password (NEVER LOSE THIS!)
vault_restic_password: "super-secret-backup-password"
```

### 2. Create Configuration

**`group_vars/all/vars.yml`:**
```yaml
---
# Backup Target
backup_target_type: "s3"
s3_bucket: "my-backups"
s3_region: "eu-central-1"

# Backup Sources
backup_sources:
  - path: "/var/www"
    tags: ["web"]
    enabled: true
  - path: "/etc"
    tags: ["config"]
    enabled: true

# Backup Interval
backup_interval_hours: 24

# Monitoring
enable_checkmk: true

# External task files (optional)
pre_backup_tasks_file: "{{ playbook_dir }}/tasks/pre_backup_tasks.yml"
post_backup_tasks_file: "{{ playbook_dir }}/tasks/post_backup_tasks.yml"
```

### 3. Create Inventory

**`inventory/hosts.ini`:**
```ini
[webservers]
web01.example.com ansible_host=192.168.1.10

[dbservers]
db01.example.com ansible_host=192.168.1.20

[all:vars]
ansible_user=root
ansible_python_interpreter=/usr/bin/python3
```

### 4. Execute

```bash
ansible-playbook playbook.yml --ask-vault-pass
```

## ⏱️ Scheduling (REQUIRED)

**IMPORTANT:** This role does NOT run automatically! You must set up a scheduler.

### Option 1: Cron (Recommended)

Create cron job that runs the playbook frequently. The role checks `backup_interval_hours` internally and exits immediately if backup is not due.

```bash
# Create vault password file
echo "your-vault-password" > /root/.vault_pass
chmod 600 /root/.vault_pass

# Add to crontab (run every 5 minutes)
crontab -e
```

Add this line:
```cron
*/5 * * * * /usr/bin/ansible-playbook /path/to/playbook.yml --vault-password-file /root/.vault_pass >> /var/log/ansible-backup.log 2>&1
```

**How it works:**
```
Every 5 minutes:
├─ Playbook runs
├─ Role checks: backup_due?
│  ├─ NO (last backup 10h ago, interval 24h) → Exit (~2 sec)
│  └─ YES (last backup 25h ago, interval 24h) → Continue
│      ├─ Execute pre_backup_tasks_file
│      ├─ Run backup
│      ├─ Execute post_backup_tasks_file
│      └─ Update timestamp
```

### Option 2: Systemd Timer

**Create `/etc/systemd/system/restic-backup.service`:**
```ini
[Unit]
Description=Restic Backup Service
After=network.target

[Service]
Type=oneshot
ExecStart=/usr/bin/ansible-playbook /path/to/playbook.yml --vault-password-file /root/.vault_pass
User=root
StandardOutput=journal
StandardError=journal
```

**Create `/etc/systemd/system/restic-backup.timer`:**
```ini
[Unit]
Description=Restic Backup Timer

[Timer]
OnCalendar=*:0/5
Persistent=true

[Install]
WantedBy=timers.target
```

**Enable and start:**
```bash
systemctl daemon-reload
systemctl enable restic-backup.timer
systemctl start restic-backup.timer

# Check status
systemctl status restic-backup.timer
systemctl list-timers restic-backup.timer
```

## 🎨 Pre/Post Backup Tasks

Pre/Post tasks are executed via **external task files**.

### Example Pre-Backup Tasks

**`tasks/pre_backup_tasks.yml`:**
```yaml
---
- name: Stop nginx
  ansible.builtin.service:
    name: nginx
    state: stopped

- name: Create MySQL dump
  community.mysql.mysql_db:
    name: all
    state: dump
    target: /var/backups/mysql.sql
```

### Example Post-Backup Tasks

**`tasks/post_backup_tasks.yml`:**
```yaml
---
# Always execute (even on backup failure)
- name: Cleanup MySQL dump
  ansible.builtin.file:
    path: /var/backups/mysql.sql
    state: absent

# Only on success
- name: Start nginx (only on success)
  ansible.builtin.service:
    name: nginx
    state: started
  when: backup_successful | default(false)

# Only on failure
- name: Send alert (only on failure)
  ansible.builtin.debug:
    msg: "⚠️ Backup failed!"
  when: not backup_successful | default(true)
```

**Configure in `group_vars/all/vars.yml`:**
```yaml
pre_backup_tasks_file: "{{ playbook_dir }}/tasks/pre_backup_tasks.yml"
post_backup_tasks_file: "{{ playbook_dir }}/tasks/post_backup_tasks.yml"
```

### The `backup_successful` Variable

Post-backup tasks have access to `backup_successful` for conditional execution:
- `true`: All backups completed successfully
- `false`: At least one backup failed (rc != 0 and rc != 3)

Note: Restic rc=3 (incomplete snapshot) is logged as WARNING but doesn't mark backup as failed.

## 📦 Backup Targets

### S3-Compatible Storage

```yaml
backup_target_type: "s3"

# AWS S3
s3_bucket: "my-backups"
s3_region: "eu-central-1"
s3_endpoint: ""  # Empty for AWS

# MinIO
s3_bucket: "backups"
s3_region: "us-east-1"
s3_endpoint: "https://minio.example.com"

# Wasabi
s3_endpoint: "https://s3.eu-central-1.wasabisys.com"
```

### Local Storage

```yaml
backup_target_type: "local"
local_backup_path: "/mnt/backup/restic"
```

## 📊 Important Variables

```yaml
# Backup Strategy
backup_interval_hours: 24

# Time Window (optional)
backup_time_window:
  enabled: true
  start_hour: 2
  end_hour: 5

# Retention Policy
retention_policy:
  keep_last: 7
  keep_daily: 14
  keep_monthly: 12
  keep_yearly: 5

# Performance Tuning
restic_read_concurrency: 2          # Parallel file reading (1-8)
restic_upload_limit_kbps: 0         # 0 = unlimited, 1024 = 1 MiB/s
restic_download_limit_kbps: 0       # 0 = unlimited

# Excludes
backup_excludes:
  - "*.tmp"
  - "*.cache"
  - "*.log"
  - "*/cache/*"
  - "*/node_modules/*"

# Debug Mode (⚠️ TESTING ONLY!)
debug_mode: false  # Shows sensitive data in output - NEVER in production!
```

## 📁 Monitoring & Logs

```bash
# Backup logs
tail -f /var/log/restic/backup-$(date +%Y-%m-%d).log

# Last backup timestamp
cat /root/.restic/last_backup_timestamp
date -d @$(cat /root/.restic/last_backup_timestamp)

# Check_MK spool files
ls -la /var/lib/check_mk_agent/spool/

# Repository statistics
export RESTIC_REPOSITORY="s3:..."
export RESTIC_PASSWORD="..."
restic snapshots
restic stats
```

## 📋 Error Handling

The role uses robust error handling:

- **Backup errors don't abort playbook**: Post-tasks always run
- **Partial failures handled**: Some paths can fail while others succeed
- **Restic rc=3 (incomplete snapshot)**: Logged as WARNING, not failure
- **Check_MK notifications**: Shows exact failed paths
- **Timestamp update**: Only on full success

## ⚠️ Important Notes

### NEVER Lose Your Password!

**Without the password, ALL backups are lost!** 🚨

Store the Restic password securely in:
- Password manager
- Encrypted USB drive
- Physical safe

### Scheduling is Required

This playbook does NOT run automatically. You must set up cron or systemd timer.

### Pre/Post Tasks Timing

Pre/Post tasks execute **only when backup is due**, not on every playbook run.

## 🛠 Troubleshooting

### Check if backup is due

```bash
cat /root/.restic/last_backup_timestamp
date -d @$(cat /root/.restic/last_backup_timestamp)
```

### Test repository connection

```bash
export RESTIC_REPOSITORY="s3:..."
export RESTIC_PASSWORD="..."
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

restic snapshots
```

### Check logs

```bash
# Latest backup log
tail -100 /var/log/restic/backup-$(date +%Y-%m-%d).log

# Watch live
tail -f /var/log/restic/backup-$(date +%Y-%m-%d).log
```

### Verify Check_MK integration

```bash
# Check spool directory
ls -la /var/lib/check_mk_agent/spool/

# View latest status
cat /var/lib/check_mk_agent/spool/*Restic*
```

## 📚 Additional Resources

- [Restic Documentation](https://restic.readthedocs.io/)
- [Ansible Documentation](https://docs.ansible.com/)
- [Check_MK Documentation](https://docs.checkmk.com/)

## 📄 License

This project can be freely used and modified.

## 🤝 Contributing

Contributions are welcome! Please feel free to submit issues or pull requests.