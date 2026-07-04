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

# --- 2. Asset snapshot (uploaded menu images, etc.) ---
docker run --rm \
  -v restaurant-web-infrastructure_app-data:/data:ro \
  -v "$WORKDIR":/out alpine \
  tar czf "/out/assets-$STAMP.tar.gz" -C /data .

# --- 3. Push OFF-BOX to separate storage (never keep the only copy on the box) ---
#   BACKUP_REMOTE is e.g. an S3 bucket or a remote host over rsync/ssh.
#   Using a placeholder command here; wire to your real tool (aws s3 / rclone / rsync).
echo "  -> shipping to ${BACKUP_REMOTE}"
# aws s3 cp "$WORKDIR/db-$STAMP.sql.gz"     "${BACKUP_REMOTE}/db/"
# aws s3 cp "$WORKDIR/assets-$STAMP.tar.gz" "${BACKUP_REMOTE}/assets/"

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
#   4. TIME IT. That elapsed time is your real RTO. Write it down.
#
# If you have never done steps 1-4, you do not have a backup. You have a folder.
# -----------------------------------------------------------------------------
