#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# CONFIGURATION
# ============================================================
BACKUP_DIR="/var/backups/vscode-server"
BASE="/opt/vscode-server"
TS=$(date +%Y%m%d-%H%M%S)
TMP="$BACKUP_DIR/.vscode-$TS.tmp.tar.gz"
OUT="$BACKUP_DIR/vscode-$TS.tar.gz"
LOG_FILE="$BACKUP_DIR/backup.log"
RETENTION_DAYS=7
COMPRESSION_LEVEL="${COMPRESSION_LEVEL:-6}"

# ============================================================
# LOGGING
# ============================================================
log() {
  echo "[$(date '+%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

# ============================================================
# PRE-FLIGHT CHECKS
# ============================================================
mkdir -p "$BACKUP_DIR"

if [[ ! -d "$BASE/data" || ! -f "$BASE/docker-compose.yml" ]]; then
  log "❌ Backup source paths missing — aborting"
  exit 1
fi

AVAILABLE_KB=$(df -kP "$BACKUP_DIR" | awk 'NR==2 {print $4}')
ESTIMATED_KB=$(du -sk "$BASE" 2>/dev/null | awk '{print $1}' || echo 1048576)

if [[ "$AVAILABLE_KB" -lt $((ESTIMATED_KB * 2)) ]]; then
  log "❌ Insufficient disk space: ${AVAILABLE_KB}KB available, ~${ESTIMATED_KB}KB needed"
  exit 1
fi

# ============================================================
# CREATE BACKUP
# ============================================================
log "📦 Creating backup $OUT..."
if ! GZIP=-"$COMPRESSION_LEVEL" tar -czf "$TMP" \
  --warning=no-file-changed \
  --exclude="*.tmp" \
  --exclude="*.log" \
  --exclude="*.pid" \
  "$BASE/data" \
  "$BASE/docker-compose.yml" 2>>"$LOG_FILE"; then

  rm -f "$TMP"
  log "❌ Backup creation failed"
  exit 1
fi

if ! tar -tzf "$TMP" >/dev/null 2>&1; then
  rm -f "$TMP"
  log "❌ Backup file is corrupt"
  exit 1
fi

mv "$TMP" "$OUT"
chmod 600 "$OUT"

SIZE=$(stat -c%s "$OUT")
log "✅ Backup completed: $OUT (${SIZE} bytes)"

# ============================================================
# PRUNE OLD BACKUPS
# ============================================================
log "🧹 Pruning backups older than $RETENTION_DAYS days..."
OLD=$(find "$BACKUP_DIR" -name "vscode-*.tar.gz" -mtime +"$RETENTION_DAYS" 2>/dev/null || true)

if [[ -n "$OLD" ]]; then
  echo "$OLD" | xargs rm -f
  log "   Removed $(echo "$OLD" | wc -l) old backup(s)"
fi

# ============================================================
# CLEANUP LOGS
# ============================================================
find "$BACKUP_DIR" -name "*.log" -mtime +30 -delete

log "🎉 Backup cycle completed successfully"
