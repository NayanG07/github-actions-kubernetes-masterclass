#!/usr/bin/env bash
# =============================================================================
# backup-mysql.sh
# Backs up the skillpulse MySQL database running in Kubernetes.
#
# HOW IT WORKS:
#   kubectl exec into the mysql StatefulSet pod → runs mysqldump inside
#   the pod → pipes the dump out to the host → compresses it → saves to
#   BACKUP_DIR with a timestamped filename → prunes backups older than
#   RETENTION_DAYS.
#
# RUN:
#   chmod +x scripts/backup/backup-mysql.sh
#   ./scripts/backup/backup-mysql.sh                    # uses defaults
#   NAMESPACE=skillpulse-prd ./scripts/backup/backup-mysql.sh  # override env
#
# SCHEDULE (via Kubernetes CronJob — see k8s-cronjobs/mysql-backup-cronjob.yaml):
#   Runs at 02:00 UTC every day in production.
# =============================================================================
set -euo pipefail

# ── Config — override with environment variables ──────────────────────────────
NAMESPACE="${NAMESPACE:-skillpulse}"
DB_NAME="${DB_NAME:-skillpulse}"
MYSQL_SECRET="${MYSQL_SECRET:-mysql-secret}"          # K8s secret name
MYSQL_SECRET_KEY="${MYSQL_SECRET_KEY:-root-password}" # key inside secret
BACKUP_DIR="${BACKUP_DIR:-/var/backups/skillpulse/mysql}"
RETENTION_DAYS="${RETENTION_DAYS:-7}"
LOG_FILE="${LOG_FILE:-/var/log/skillpulse/backup.log}"

# ── Colours ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

# ── Logging ───────────────────────────────────────────────────────────────────
log()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" | tee -a "$LOG_FILE"; }
warn() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
die()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${NC} $*" | tee -a "$LOG_FILE"; exit 1; }
ok()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[OK]${NC}    $*" | tee -a "$LOG_FILE"; }

# ── Preflight checks ──────────────────────────────────────────────────────────
check_deps() {
  for cmd in kubectl gzip; do
    command -v "$cmd" &>/dev/null || die "$cmd is required but not installed."
  done
}

# ── Get MySQL pod name from StatefulSet ───────────────────────────────────────
get_mysql_pod() {
  local pod
  pod=$(kubectl get pod \
    -n "$NAMESPACE" \
    -l app=mysql \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)

  [[ -z "$pod" ]] && die "No running MySQL pod found in namespace '$NAMESPACE'."
  echo "$pod"
}

# ── Fetch DB root password from K8s secret ────────────────────────────────────
get_db_password() {
  kubectl get secret "$MYSQL_SECRET" \
    -n "$NAMESPACE" \
    -o jsonpath="{.data.${MYSQL_SECRET_KEY}}" \
    | base64 --decode
}

# ── Run the backup ────────────────────────────────────────────────────────────
run_backup() {
  local pod="$1"
  local db_pass="$2"
  local timestamp
  timestamp=$(date '+%Y%m%d_%H%M%S')
  local filename="${DB_NAME}_${timestamp}.sql.gz"
  local filepath="${BACKUP_DIR}/${filename}"

  mkdir -p "$BACKUP_DIR"
  mkdir -p "$(dirname "$LOG_FILE")"

  log "Starting backup → namespace=$NAMESPACE pod=$pod db=$DB_NAME"
  log "Output: $filepath"

  # Stream mysqldump from inside the pod, compress on the way out.
  # -h 127.0.0.1 forces TCP (avoids socket file issues inside distroless-adjacent pods)
  # --single-transaction: consistent snapshot without locking tables (InnoDB safe)
  # --routines --triggers: include stored procedures and triggers
  # --no-tablespaces: avoids needing PROCESS privilege
  if kubectl exec -n "$NAMESPACE" "$pod" -- \
      mysqldump \
        -h 127.0.0.1 \
        -u root \
        -p"${db_pass}" \
        --single-transaction \
        --routines \
        --triggers \
        --no-tablespaces \
        "$DB_NAME" \
    | gzip > "$filepath"; then
    local size
    size=$(du -sh "$filepath" | cut -f1)
    ok "Backup complete: $filepath ($size)"
  else
    # Remove partial file so retention doesn't keep a corrupt backup
    rm -f "$filepath"
    die "mysqldump failed. Check pod logs: kubectl logs $pod -n $NAMESPACE"
  fi

  echo "$filepath"
}

# ── Verify the backup is non-empty and valid gzip ─────────────────────────────
verify_backup() {
  local filepath="$1"
  local size_bytes
  size_bytes=$(stat -c%s "$filepath" 2>/dev/null || stat -f%z "$filepath")

  [[ "$size_bytes" -lt 100 ]] && die "Backup file is suspiciously small ($size_bytes bytes) — possible empty dump."

  if gzip -t "$filepath" 2>/dev/null; then
    ok "Backup verified: gzip integrity check passed."
  else
    die "Backup file is corrupt (failed gzip -t). Deleting: $filepath"
    rm -f "$filepath"
  fi
}

# ── Prune old backups ─────────────────────────────────────────────────────────
prune_old_backups() {
  log "Pruning backups older than ${RETENTION_DAYS} days from $BACKUP_DIR"
  local count
  count=$(find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" | wc -l)

  if [[ "$count" -gt 0 ]]; then
    find "$BACKUP_DIR" -name "*.sql.gz" -mtime +"$RETENTION_DAYS" -delete
    ok "Pruned $count old backup(s)."
  else
    log "No old backups to prune."
  fi
}

# ── List current backups ──────────────────────────────────────────────────────
list_backups() {
  log "Current backups in $BACKUP_DIR:"
  find "$BACKUP_DIR" -name "*.sql.gz" -printf "  %TY-%Tm-%Td %TH:%TM  %f  (%s bytes)\n" \
    2>/dev/null | sort || \
  find "$BACKUP_DIR" -name "*.sql.gz" | sort  # macOS fallback
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  log "=========================================="
  log " SkillPulse MySQL Backup"
  log "=========================================="

  check_deps

  local pod db_pass filepath
  pod=$(get_mysql_pod)
  db_pass=$(get_db_password)
  filepath=$(run_backup "$pod" "$db_pass")
  verify_backup "$filepath"
  prune_old_backups
  list_backups

  ok "Backup job finished successfully."
}

main "$@"
