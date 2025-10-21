#!/bin/bash
# Pre-Backup Hook Example
# This script is called by Restic BEFORE starting the backup
#
# Available variables from Restic:
# - RESTIC_REPOSITORY: Repository location
# - RESTIC_PASSWORD_FILE: Path to password file
# - (and all other RESTIC_* environment variables)
#
# Exit codes:
# - 0: Success, continue with backup
# - non-zero: Abort backup
#
# Usage:
# 1. Copy this file to your playbook directory: hooks/pre-backup-<source-name>.sh
# 2. Make it executable: chmod +x hooks/pre-backup-<source-name>.sh
# 3. Customize for your needs
# 4. Configure in playbook: restic_custom_hooks_dir: "{{ playbook_dir }}/hooks"

set -e  # Exit on error
# set -x  # Uncomment for debugging

# Logging helper
log() {
    logger -t "restic-pre-backup" -p user.info "$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting pre-backup tasks..."

# ========================================
# EXAMPLE 1: Database Dump
# ========================================
# log "Creating MySQL database dump..."
# mysqldump --all-databases --single-transaction > /var/backups/mysql-all.sql
# log "MySQL dump created successfully"

# ========================================
# EXAMPLE 2: Stop Services
# ========================================
# log "Stopping application services..."
# systemctl stop myapp
# systemctl stop nginx
# log "Services stopped"

# ========================================
# EXAMPLE 3: Create Application Dump
# ========================================
# log "Creating application data dump..."
# tar czf /var/backups/app-data.tar.gz /var/lib/myapp/data/
# log "Application dump created"

# ========================================
# EXAMPLE 4: Check Disk Space
# ========================================
# REQUIRED_SPACE_GB=10
# AVAILABLE_SPACE_GB=$(df /var/backups | awk 'NR==2 {print int($4/1024/1024)}')
# if [ $AVAILABLE_SPACE_GB -lt $REQUIRED_SPACE_GB ]; then
#     log "ERROR: Insufficient disk space (required: ${REQUIRED_SPACE_GB}GB, available: ${AVAILABLE_SPACE_GB}GB)"
#     exit 1
# fi
# log "Disk space check passed (available: ${AVAILABLE_SPACE_GB}GB)"

# ========================================
# EXAMPLE 5: Snapshot LVM Volume
# ========================================
# log "Creating LVM snapshot..."
# lvcreate -L1G -s -n backup_snapshot /dev/vg0/data
# mkdir -p /mnt/snapshot
# mount /dev/vg0/backup_snapshot /mnt/snapshot
# log "LVM snapshot created and mounted"

# ========================================
# EXAMPLE 6: Docker Container Actions
# ========================================
# log "Pausing Docker containers..."
# docker pause myapp-container
# docker pause db-container
# log "Containers paused"

# ========================================
# EXAMPLE 7: Enable Maintenance Mode
# ========================================
# log "Enabling maintenance mode..."
# touch /var/www/html/maintenance.flag
# log "Maintenance mode enabled"

# ========================================
# EXAMPLE 8: Sync Files from Remote
# ========================================
# log "Syncing files from remote server..."
# rsync -avz user@remote:/data/ /var/backups/remote-data/
# log "Files synced"

log "Pre-backup tasks completed successfully"
exit 0
