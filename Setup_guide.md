# Restic Backup Ansible Role - Complete Setup Guide

## ðŸ“¦ All Files Overview

Here are all the final, production-ready files you need:

### Required Files (Core)

| File | Location | Description | Status |
|------|----------|-------------|--------|
| `defaults/main.yml` | `roles/restic_backup/defaults/` | Default variables | âœ… |
| `tasks/main.yml` | `roles/restic_backup/tasks/` | Main backup logic | âœ… |
| `playbook.yml` | Project root | Main playbook | âœ… |
| `README.md` | Project root | Main documentation | âœ… |
| `requirements.yml` | Project root | Ansible collections | âœ… |

### Example Files (Optional)

| File | Location | Description | Status |
|------|----------|-------------|--------|
| `playbook_examples.yml` | Project root | Usage examples | âœ… |
| `pre_backup_tasks.yml` | `tasks/` | Pre-backup examples | âœ… |
| `post_backup_tasks.yml` | `tasks/` | Post-backup examples | âœ… |
| `.gitignore` | Project root | Git ignore rules | âœ… |

### Configuration Files (Create These)

| File | Location | Description |
|------|----------|-------------|
| `vars.yml` | `group_vars/all/` | Your backup config |
| `vault.yml` | `group_vars/all/` | Your encrypted secrets |
| `hosts.ini` | `inventory/` | Your server list |

## ðŸš€ Quick Setup (5 Steps)

### Step 1: Create Directory Structure

```bash
mkdir -p ansible-backup-project/{roles/restic_backup/{defaults,tasks},tasks,group_vars/all,inventory}
cd ansible-backup-project
```

### Step 2: Copy Core Files

Copy content from artifacts to these files:

```bash
# Core role files
roles/restic_backup/defaults/main.yml    # From artifact
roles/restic_backup/tasks/main.yml       # From artifact

# Main playbook
playbook.yml                             # From artifact

# Collections
requirements.yml                         # From artifact

# Documentation
README.md                                # From artifact

# Optional examples
tasks/pre_backup_tasks.yml               # From artifact (optional)
tasks/post_backup_tasks.yml              # From artifact (optional)
playbook_examples.yml                    # From artifact (optional)
.gitignore                               # From artifact (optional)
```

### Step 3: Install Collections

```bash
ansible-galaxy collection install -r requirements.yml
```

This installs:
- `community.general` (required for syslog)
- Optional: `community.mysql`, `community.postgresql`, `community.docker`

### Step 4: Create Configuration

**`group_vars/all/vars.yml`:**
```yaml
---
# Backup Target
backup_target_type: "s3"
s3_bucket: "my-company-backups"
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
checkmk_service_name: "Restic_Backup"

# External task files (optional)
pre_backup_tasks_file: "{{ playbook_dir }}/tasks/pre_backup_tasks.yml"
post_backup_tasks_file: "{{ playbook_dir }}/tasks/post_backup_tasks.yml"
```

### Step 5: Create Encrypted Vault

```bash
ansible-vault create group_vars/all/vault.yml
```

**Content:**
```yaml
---
# AWS S3 Credentials
vault_aws_access_key: "AKIAIOSFODNN7EXAMPLE"
vault_aws_secret_key: "wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY"

# Restic Password (NEVER LOSE THIS!)
vault_restic_password: "super-secret-backup-password"
```

### Step 6: Create Inventory

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

## ðŸŽ¯ Pre/Post Tasks - External Files Only

âš ï¸ **IMPORTANT:** Pre/Post tasks must be defined in **external files**, not inline in the playbook!

### Why External Files Only?

The playbook runs **every 5 minutes**, but backup is only due every 24 hours (or your configured interval).

**If tasks were inline in playbook:**
```yaml
# âŒ WRONG - Tasks run EVERY 5 MINUTES:
- hosts: all
  tasks:
    - name: Stop nginx        # Stops nginx every 5 min!
      service: name=nginx state=stopped
    
    - include_role: restic_backup  # Only backs up every 24h
    
    - name: Start nginx       # Starts nginx every 5 min!
      service: name=nginx state=started
```

Result: Services are stopped/started **every 5 minutes**, even when no backup happens!

**With external files:**
```yaml
# âœ… CORRECT - Tasks only run when backup is due:
- hosts: all
  roles:
    - role: restic_backup
      vars:
        pre_backup_tasks_file: "{{ playbook_dir }}/tasks/pre_backup.yml"
        # Tasks only execute when backup_due=true (e.g., every 24h)
```

### Method 1: Single External File

**Best for:** Simple, straightforward scenarios

**Create `tasks/pre_backup_tasks.yml`:**
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

**Create `tasks/post_backup_tasks.yml`:**
```yaml
---
- name: Start nginx (only on success)
  ansible.builtin.service:
    name: nginx
    state: started
  when: backup_successful | default(false)

- name: Cleanup dump
  ansible.builtin.file:
    path: /var/backups/mysql.sql
    state: absent
```

**Configure in playbook or group_vars:**
```yaml
pre_backup_tasks_file: "{{ playbook_dir }}/tasks/pre_backup_tasks.yml"
post_backup_tasks_file: "{{ playbook_dir }}/tasks/post_backup_tasks.yml"
```

### Method 2: Multiple Tasks in One File

**Best for:** Complex, modular workflows

**Create `tasks/pre_backup_tasks.yml`:**
```yaml
---
- name: Include stop services tasks
  ansible.builtin.include_tasks: stop_services.yml

- name: Include database backup tasks
  ansible.builtin.include_tasks: db_backup.yml
```

## ðŸƒ Running the Playbook

### First Run (Test)

```bash
# Syntax check
ansible-playbook playbook.yml --syntax-check

# Dry run
ansible-playbook playbook.yml --check --ask-vault-pass

# Real execution
ansible-playbook playbook.yml --ask-vault-pass
```

### With Vault Password File

```bash
# Create vault password file
echo "my-vault-password" > ~/.vault_pass
chmod 600 ~/.vault_pass

# Run playbook
ansible-playbook playbook.yml --vault-password-file ~/.vault_pass
```

### Automatic Execution

**The playbook already runs automatically every 5 minutes!**

You do **NOT** need to set up cron or systemd. The role manages backup timing internally via `backup_interval_hours`.

**How it works:**
```
Every 5 minutes:
â”œâ”€ Playbook runs
â”œâ”€ Role checks: backup_due?
â”‚  â”œâ”€ NO (last backup 10h ago, interval 24h) â†’ Exit (~2 sec)
â”‚  â””â”€ YES (last backup 25h ago, interval 24h) â†’ Continue
â”‚      â”œâ”€ Execute pre_backup_tasks_file
â”‚      â”œâ”€ Run backup
â”‚      â”œâ”€ Execute post_backup_tasks_file
â”‚      â””â”€ Update timestamp
```

## ðŸ“Š Verification

### Check if Role Works

```bash
# Run once
ansible-playbook playbook.yml --ask-vault-pass

# Check logs
tail -f /var/log/restic/backup-$(date +%Y-%m-%d).log

# Check last backup
cat /root/.restic/last_backup_timestamp
date -d @$(cat /root/.restic/last_backup_timestamp)
```

### Check Backup Repository

```bash
# Set environment
export RESTIC_REPOSITORY="s3:s3.eu-central-1.amazonaws.com/my-backups"
export RESTIC_PASSWORD="your-password"
export AWS_ACCESS_KEY_ID="your-key"
export AWS_SECRET_ACCESS_KEY="your-secret"

# List snapshots
restic snapshots

# Repository statistics
restic stats
```

### Check Check_MK

```bash
# Check spool files
ls -la /var/lib/check_mk_agent/spool/

# View content
cat /var/lib/check_mk_agent/spool/*Restic*

# Test agent
check_mk_agent | grep Restic
```

## ðŸŽ¯ Complete Example

Here's a complete working example:

**Directory structure:**
```
my-backup-project/
â”œâ”€â”€ .gitignore
â”œâ”€â”€ README.md
â”œâ”€â”€ playbook.yml
â”œâ”€â”€ playbook_examples.yml
â”œâ”€â”€ requirements.yml
â”œâ”€â”€ roles/
â”‚   â””â”€â”€ restic_backup/
â”‚       â”œâ”€â”€ defaults/
â”‚       â”‚   â””â”€â”€ main.yml
â”‚       â””â”€â”€ tasks/
â”‚           â””â”€â”€ main.yml
â”œâ”€â”€ tasks/
â”‚   â”œâ”€â”€ pre_backup_tasks.yml
â”‚   â””â”€â”€ post_backup_tasks.yml
â”œâ”€â”€ group_vars/
â”‚   â””â”€â”€ all/
â”‚       â”œâ”€â”€ vars.yml
â”‚       â””â”€â”€ vault.yml (encrypted)
â””â”€â”€ inventory/
    â””â”€â”€ hosts.ini
```

**Run it:**
```bash
cd my-backup-project
ansible-galaxy collection install -r requirements.yml
ansible-playbook playbook.yml --vault-password-file ~/.vault_pass
```

## âœ… Final Checklist

After setup, verify:

- [ ] All core files copied from artifacts
- [ ] Collections installed (`ansible-galaxy collection install -r requirements.yml`)
- [ ] `group_vars/all/vars.yml` configured
- [ ] `group_vars/all/vault.yml` created and encrypted
- [ ] `inventory/hosts.ini` with your servers
- [ ] Pre/Post task files created (if using them)
- [ ] Syntax check passes
- [ ] Dry-run successful
- [ ] First backup completed
- [ ] Logs in `/var/log/restic/` exist
- [ ] Check_MK agent installed (if using)
- [ ] Vault password backed up securely ðŸ”’

## ðŸ†˜ Troubleshooting

### Backup not running

```bash
# Check timestamp
cat /root/.restic/last_backup_timestamp
date -d @$(cat /root/.restic/last_backup_timestamp)

# Check interval in vars.yml
grep backup_interval_hours group_vars/all/vars.yml
```

### Pre/Post tasks not executing

```bash
# Check if file exists
ls -la tasks/pre_backup_tasks.yml

# Check path in configuration
grep "pre_backup_tasks_file" group_vars/all/vars.yml

# Check file content
cat tasks/pre_backup_tasks.yml
```

### Repository connection issues

```bash
# Test manually
export RESTIC_REPOSITORY="s3:..."
export RESTIC_PASSWORD="..."
export AWS_ACCESS_KEY_ID="..."
export AWS_SECRET_ACCESS_KEY="..."

restic snapshots
```

### Services stopping every 5 minutes

**Symptom:** Your services (nginx, MySQL, etc.) stop and start every 5 minutes.

**Cause:** You defined tasks inline in the playbook instead of external files.

**Solution:** Move tasks to external files and configure:
```yaml
pre_backup_tasks_file: "{{ playbook_dir }}/tasks/pre_backup_tasks.yml"
post_backup_tasks_file: "{{ playbook_dir }}/tasks/post_backup_tasks.yml"
```

## ðŸŽ‰ Done!

Your automated Restic backup system is now ready for production. 

**Key Points:**
- âœ… Runs automatically every 5 minutes (self-managed)
- âœ… No cron/systemd setup needed
- âœ… Pre/Post tasks via external files only
- âœ… Production-ready with error handling
- âœ… Check_MK monitoring integrated

For detailed usage examples, see `playbook_examples.yml`.
For full documentation, see `README.md`.

**Never lose your Restic password - all backups depend on it!** ðŸ”’