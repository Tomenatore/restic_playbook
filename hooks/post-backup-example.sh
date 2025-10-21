#!/bin/bash
# Post-Backup Hook Example
# This script is called by Restic AFTER the backup completes
#
# Available variables from Restic:
# - RESTIC_REPOSITORY: Repository location
# - RESTIC_PASSWORD_FILE: Path to password file
# - (and all other RESTIC_* environment variables)
#
# Arguments:
# - $1: Exit status of the backup (0 = success, non-zero = failure)
#
# Exit codes:
# - Exit code is ignored by Restic (backup already completed)
# - Use for cleanup tasks that should run regardless of backup status
#
# Usage:
# 1. Copy this file to your playbook directory: hooks/post-backup-<source-name>.sh
# 2. Make it executable: chmod +x hooks/post-backup-<source-name>.sh
# 3. Customize for your needs
# 4. Configure in playbook: restic_custom_hooks_dir: "{{ playbook_dir }}/hooks"

# Backup exit status (passed as first argument)
BACKUP_EXIT_STATUS="${1:-0}"

# Logging helper
log() {
    logger -t "restic-post-backup" -p user.info "$1"
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $1"
}

log "Starting post-backup tasks (backup exit status: ${BACKUP_EXIT_STATUS})..."

# ========================================
# EXAMPLE 1: Cleanup Database Dumps (Always)
# ========================================
# log "Cleaning up database dumps..."
# rm -f /var/backups/mysql-all.sql
# rm -f /var/backups/postgres-all.sql
# log "Database dumps cleaned up"

# ========================================
# EXAMPLE 2: Start Services (Always)
# ========================================
# log "Starting application services..."
# systemctl start nginx
# systemctl start myapp
# log "Services started"

# ========================================
# EXAMPLE 3: Cleanup Application Dumps (Always)
# ========================================
# log "Removing application dump..."
# rm -f /var/backups/app-data.tar.gz
# log "Application dump removed"

# ========================================
# EXAMPLE 4: Unmount LVM Snapshot (Always)
# ========================================
# log "Unmounting and removing LVM snapshot..."
# umount /mnt/snapshot || true
# lvremove -f /dev/vg0/backup_snapshot || true
# log "LVM snapshot removed"

# ========================================
# EXAMPLE 5: Resume Docker Containers (Always)
# ========================================
# log "Resuming Docker containers..."
# docker unpause myapp-container || true
# docker unpause db-container || true
# log "Containers resumed"

# ========================================
# EXAMPLE 6: Disable Maintenance Mode (Only on Success)
# ========================================
# if [ "${BACKUP_EXIT_STATUS}" = "0" ]; then
#     log "Disabling maintenance mode (backup succeeded)..."
#     rm -f /var/www/html/maintenance.flag
#     log "Maintenance mode disabled"
# else
#     log "Keeping maintenance mode enabled (backup failed)"
# fi

# ========================================
# EXAMPLE 7: Send Notification (Based on Status)
# ========================================
# if [ "${BACKUP_EXIT_STATUS}" = "0" ]; then
#     log "Backup succeeded, sending success notification..."
#     # curl -X POST https://notification.service/success
# else
#     log "Backup failed, sending failure notification..."
#     # curl -X POST https://notification.service/failure
# fi

# ========================================
# EXAMPLE 8: Update Status File (Only on Success)
# ========================================
# if [ "${BACKUP_EXIT_STATUS}" = "0" ]; then
#     log "Updating last successful backup timestamp..."
#     date +%s > /var/backups/.last_successful_backup
#     log "Timestamp updated"
# fi

# ========================================
# EXAMPLE 9: Cleanup Old Temporary Files (Always)
# ========================================
# log "Cleaning up old temporary files..."
# find /var/backups -name "*.tmp" -mtime +1 -delete
# log "Temporary files cleaned up"

# ========================================
# EXAMPLE 10: Log Backup Statistics (Only on Success)
# ========================================
# if [ "${BACKUP_EXIT_STATUS}" = "0" ]; then
#     log "Retrieving backup statistics..."
#     # Stats are also available via CheckMK monitoring
#     log "Backup completed successfully"
# else
#     log "Backup failed with exit status: ${BACKUP_EXIT_STATUS}"
# fi

log "Post-backup tasks completed"
exit 0
