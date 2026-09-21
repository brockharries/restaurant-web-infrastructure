#!/usr/bin/env bash
#
# Sanitized nightly backup for the origin stack.
#
# The point of this script is NOT the dump. It's that the dump is part of a
# RECOVERY PATH that has actually been tested. See the restore-test note at the
# bottom. Until you've restored it, all you've proven is that the cron job runs.
#
# Intended to run from cron, e.g.:
#   15 3 * * *  /opt/ops/backup.sh >> /var/log/backup.log 2>&1
#
# All values are placeholders; real config lives in .env (gitignored).

set -euo pipefail

# shellcheck disable=SC1091
source "$(dirname "$0")/../.env"   # DB_*, BACKUP_REMOTE, BACKUP_RETENTION_DAYS

STAMP="$(date +%Y-%m-%d_%H%M%S)"
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

echo "[$(date -Is)] backup start: $STAMP"

# --- 1. Database dump (from the app's perspective, over the internal network) ---
docker exec db-primary \
  mariadb-dump --single-transaction --quick \
  -u"$DB_USER" -p"$DB_PASSWORD" "$DB_NAME" \
  | gzip -c > "$WORKDIR/db-$STAMP.sql.gz"

# --- 2. Asset archive (uploaded menu images, etc.) ---
#   Taken right after the database dump, not atomically with it. An image uploaded between the
#   two steps can be missing from the archive. For one consistent recovery point, pause writes first.
docker run --rm \
  -v restaurant-web-infrastructure_app-data:/data:ro \
  -v "$WORKDIR":/out alpine \
  tar czf "/out/assets-$STAMP.tar.gz" -C /data .

# --- 3. Push OFF-BOX to separate storage (never keep the only copy on the box) ---
#   BACKUP_REMOTE is e.g. an S3 bucket or a remote host over rsync/ssh.
#   This example ships no upload command, because the right one depends on your storage.
#   Until you replace upload() below, the script FAILS ON PURPOSE. A backup job that deletes its
#   archives on exit and still prints "done" is worse than no backup job.
upload() {
  echo "ERROR: upload() is not implemented. Nothing left this box; the archives in $WORKDIR are deleted on exit." >&2
  echo "       Wire upload() to your storage (aws s3 cp / rclone copy / rsync), then verify the remote copy." >&2
  return 1
}
echo "  -> shipping to ${BACKUP_REMOTE}"
upload "$WORKDIR/db-$STAMP.sql.gz"     "${BACKUP_REMOTE}/db/"
upload "$WORKDIR/assets-$STAMP.tar.gz" "${BACKUP_REMOTE}/assets/"

# --- 3b. Verify before reporting success ---
#   Confirm both objects exist off-box and are not empty (aws s3 ls / rclone lsl; compare sizes or
#   checksums). An exit code from the upload tool is not proof that the copy is there.

# --- 4. Retention: prune off-box copies older than N days ---
echo "  -> retention: keeping ${BACKUP_RETENTION_DAYS} days"
# (retention command is storage-specific; e.g. lifecycle policy or find -mtime)

echo "[$(date -Is)] backup done: $STAMP"

# -----------------------------------------------------------------------------
# RESTORE TEST (run on a schedule, NOT in this cron job). This is the real deliverable:
#
#   1. Spin up a throwaway db container.
#   2. gunzip -c db-<STAMP>.sql.gz | docker exec -i db-test mariadb -u root -p... <db>
#   3. Point a scratch app instance at it, load the storefront, place a test order.
#   4. TIME IT. That elapsed time is your measured recovery duration. Write it down and compare it
#      with the recovery time the business has agreed it can live with.
#
# If you have never done steps 1-4, you do not have a backup. You have a folder.
# -----------------------------------------------------------------------------
