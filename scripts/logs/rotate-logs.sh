#!/usr/bin/env bash
# =============================================================================
# rotate-logs.sh
# Collects logs from all three SkillPulse tiers, rotates and compresses them.
#
# WHY THIS EXISTS:
#   Kubernetes pod logs are ephemeral — when a pod restarts, logs are gone.
#   This script snapshots current logs from every running pod to disk,
#   then compresses and prunes old snapshots.
#
#   It also rotates any local log files produced by the backup and health
#   check scripts themselves.
#
# RUN:
#   ./scripts/logs/rotate-logs.sh
#   NAMESPACE=skillpulse-stg ./scripts/logs/rotate-logs.sh
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-skillpulse}"
LOG_COLLECT_DIR="${LOG_COLLECT_DIR:-/var/log/skillpulse/pods}"
LOCAL_LOG_DIR="${LOCAL_LOG_DIR:-/var/log/skillpulse}"
RETENTION_DAYS="${RETENTION_DAYS:-14}"
MAX_LOCAL_LOG_SIZE_MB="${MAX_LOCAL_LOG_SIZE_MB:-50}"
SINCE="${SINCE:-24h}"          # collect last N hours of pod logs
TIMESTAMP=$(date '+%Y%m%d_%H%M%S')

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'

log()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*"; }
warn() { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${NC}  $*"; }
die()  { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[ERROR]${NC} $*"; exit 1; }
ok()   { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[OK]${NC}    $*"; }

command -v kubectl &>/dev/null || die "kubectl is required."

# ── Collect logs from all pods of a given label ───────────────────────────────
collect_pod_logs() {
  local tier="$1"    # frontend | backend | mysql
  local label="$2"   # app=frontend

  local tier_dir="${LOG_COLLECT_DIR}/${TIMESTAMP}/${tier}"
  mkdir -p "$tier_dir"

  # Get all pods for this tier (handles multiple replicas in stg/prd)
  local pods
  pods=$(kubectl get pods -n "$NAMESPACE" -l "$label" \
    -o jsonpath='{.items[*].metadata.name}' 2>/dev/null)

  if [[ -z "$pods" ]]; then
    warn "No pods found for label '$label' in namespace '$NAMESPACE' — skipping."
    return
  fi

  local collected=0
  for pod in $pods; do
    local logfile="${tier_dir}/${pod}.log"

    log "Collecting logs: $pod (last $SINCE)"

    # --previous: also collect logs from the previous container if it crashed
    kubectl logs "$pod" -n "$NAMESPACE" --since="$SINCE" \
      > "$logfile" 2>/dev/null || true

    # Try to grab previous container logs too (crash context)
    kubectl logs "$pod" -n "$NAMESPACE" --previous \
      > "${tier_dir}/${pod}.previous.log" 2>/dev/null || true

    # If the previous log is empty, remove it
    [[ -s "${tier_dir}/${pod}.previous.log" ]] || rm -f "${tier_dir}/${pod}.previous.log"

    ((collected++))
  done

  ok "Collected logs from $collected pod(s) for tier '$tier'."
}

# ── Compress the collected snapshot ───────────────────────────────────────────
compress_snapshot() {
  local snapshot_dir="${LOG_COLLECT_DIR}/${TIMESTAMP}"
  local archive="${LOG_COLLECT_DIR}/skillpulse-logs-${TIMESTAMP}.tar.gz"

  if [[ -d "$snapshot_dir" ]]; then
    tar -czf "$archive" -C "$LOG_COLLECT_DIR" "$TIMESTAMP"
    rm -rf "$snapshot_dir"
    local size
    size=$(du -sh "$archive" | cut -f1)
    ok "Compressed snapshot: $archive ($size)"
  fi
}

# ── Rotate a single local log file ────────────────────────────────────────────
# If the file exceeds MAX_LOCAL_LOG_SIZE_MB, rename it with a timestamp
# and start fresh. Keep last 5 rotated copies.
rotate_local_log() {
  local logfile="$1"
  [[ -f "$logfile" ]] || return

  local size_mb
  size_mb=$(du -m "$logfile" | cut -f1)

  if [[ "$size_mb" -ge "$MAX_LOCAL_LOG_SIZE_MB" ]]; then
    local rotated="${logfile}.${TIMESTAMP}"
    mv "$logfile" "$rotated"
    gzip "$rotated"
    touch "$logfile"  # create fresh empty log
    ok "Rotated: $logfile → ${rotated}.gz"

    # Keep only last 5 rotated copies of this log
    find "$(dirname "$logfile")" \
      -name "$(basename "$logfile").*.gz" \
      | sort -r | tail -n +6 | xargs rm -f 2>/dev/null || true
  else
    log "Log $logfile is ${size_mb}MB — no rotation needed."
  fi
}

# ── Prune old compressed pod-log archives ─────────────────────────────────────
prune_old_archives() {
  log "Pruning pod log archives older than ${RETENTION_DAYS} days..."
  local count
  count=$(find "$LOG_COLLECT_DIR" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" | wc -l)
  if [[ "$count" -gt 0 ]]; then
    find "$LOG_COLLECT_DIR" -name "*.tar.gz" -mtime +"$RETENTION_DAYS" -delete
    ok "Pruned $count old archive(s)."
  else
    log "No old archives to prune."
  fi
}

# ── Show disk usage summary ───────────────────────────────────────────────────
disk_summary() {
  log "Log storage summary:"
  du -sh "${LOG_COLLECT_DIR}" 2>/dev/null | awk '{print "  Pod logs:   " $1}'
  du -sh "${LOCAL_LOG_DIR}"   2>/dev/null | awk '{print "  Script logs:" $1}'
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  mkdir -p "$LOG_COLLECT_DIR" "$LOCAL_LOG_DIR"

  log "=========================================="
  log " SkillPulse Log Rotation"
  log " Namespace: $NAMESPACE | Since: $SINCE"
  log "=========================================="

  # 1. Collect pod logs — one per tier
  collect_pod_logs "mysql"    "app=mysql"
  collect_pod_logs "backend"  "app=backend"
  collect_pod_logs "frontend" "app=frontend"

  # 2. Compress the collected snapshot into a single archive
  compress_snapshot

  # 3. Rotate our own script logs if they've grown too large
  rotate_local_log "${LOCAL_LOG_DIR}/backup.log"
  rotate_local_log "${LOCAL_LOG_DIR}/restore.log"
  rotate_local_log "${LOCAL_LOG_DIR}/health.log"
  rotate_local_log "${LOCAL_LOG_DIR}/rotate-logs.log"

  # 4. Prune archives older than retention window
  prune_old_archives

  # 5. Summary
  disk_summary
  ok "Log rotation complete."
}

main "$@"
