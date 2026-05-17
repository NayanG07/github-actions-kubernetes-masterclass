#!/usr/bin/env bash
# =============================================================================
# restore-mysql.sh
# Restores a skillpulse MySQL backup into the running Kubernetes StatefulSet.
#
# USAGE:
#   ./scripts/backup/restore-mysql.sh <backup-file.sql.gz>
#   ./scripts/backup/restore-mysql.sh /var/backups/skillpulse/mysql/skillpulse_20260515_020000.sql.gz
#
# SAFETY:
#   Asks for confirmation before overwriting the live database.
#   Shows a diff of table counts before/after to confirm restore worked.
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-skillpulse}"
DB_NAME="${DB_NAME:-skillpulse}"
MYSQL_SECRET="${MYSQL_SECRET:-mysql-secret}"
MYSQL_SECRET_KEY="${MYSQL_SECRET_KEY:-root-password}"
LOG_FILE="${LOG_FILE:-/var/log/skillpulse/restore.log}"

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
die()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
ok()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }

BACKUP_FILE="${1:-}"
[[ -z "$BACKUP_FILE" ]] && die "Usage: $0 <backup-file.sql.gz>"
[[ -f "$BACKUP_FILE" ]] || die "Backup file not found: $BACKUP_FILE"

get_mysql_pod() {
  kubectl get pod -n "$NAMESPACE" -l app=mysql \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null \
    || die "No running MySQL pod found in namespace '$NAMESPACE'."
}

get_db_password() {
  kubectl get secret "$MYSQL_SECRET" -n "$NAMESPACE" \
    -o jsonpath="{.data.${MYSQL_SECRET_KEY}}" | base64 --decode
}

table_count() {
  local pod="$1" pass="$2"
  kubectl exec -n "$NAMESPACE" "$pod" -- \
    mysql -h 127.0.0.1 -u root -p"${pass}" -s -N \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='${DB_NAME}';" \
    2>/dev/null
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  log "=========================================="
  log " SkillPulse MySQL Restore"
  log "=========================================="
  log "File:      $BACKUP_FILE"
  log "Namespace: $NAMESPACE"
  log "Database:  $DB_NAME"

  local pod db_pass
  pod=$(get_mysql_pod)
  db_pass=$(get_db_password)

  # ── Confirm ────────────────────────────────────────────────────────────────
  warn "This will DROP and recreate the '$DB_NAME' database in namespace '$NAMESPACE'."
  warn "Pod: $pod"
  echo -e "${RED}Type 'yes' to continue or anything else to abort:${NC} \c"
  read -r confirm
  [[ "$confirm" == "yes" ]] || { log "Restore aborted by user."; exit 0; }

  # ── Table count before ─────────────────────────────────────────────────────
  local before_count
  before_count=$(table_count "$pod" "$db_pass")
  log "Tables before restore: $before_count"

  # ── Restore ────────────────────────────────────────────────────────────────
  log "Streaming backup into pod..."
  gzip -dc "$BACKUP_FILE" | kubectl exec -i -n "$NAMESPACE" "$pod" -- \
    mysql -h 127.0.0.1 -u root -p"${db_pass}" "$DB_NAME" \
    && ok "SQL import complete." \
    || die "Restore failed. Database may be in an inconsistent state. Check pod logs."

  # ── Table count after ──────────────────────────────────────────────────────
  local after_count
  after_count=$(table_count "$pod" "$db_pass")
  log "Tables after restore:  $after_count"

  [[ "$after_count" -gt 0 ]] && ok "Restore verified: $after_count table(s) present." \
    || warn "No tables found after restore — check the backup file."

  ok "Restore finished."
}

main "$@"
