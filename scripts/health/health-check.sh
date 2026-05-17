#!/usr/bin/env bash
# =============================================================================
# health-check.sh
# Checks the health of every component of the SkillPulse 3-tier app.
#
# CHECKS:
#   1. K8s secrets exist
#   2. Cluster nodes are Ready
#   3. PVC is Bound (MySQL data volume)
#   4. MySQL StatefulSet ready + DB ping + table count
#   5. Backend Deployment ready + /health HTTP 200 + body "healthy"
#   6. Backend /api/dashboard HTTP 200
#   7. Frontend Deployment ready + / HTTP 200
#
# EXIT CODES:
#   0 — all checks passed
#   1 — one or more checks failed
#
# RUN:
#   ./scripts/health/health-check.sh
#   NAMESPACE=skillpulse-prd ALERT_WEBHOOK=https://... ./scripts/health/health-check.sh
# =============================================================================
set -euo pipefail

NAMESPACE="${NAMESPACE:-skillpulse}"
BACKEND_HOST="${BACKEND_HOST:-localhost}"
BACKEND_PORT="${BACKEND_PORT:-8888}"
FRONTEND_PORT="${FRONTEND_PORT:-8888}"
TIMEOUT="${TIMEOUT:-10}"
LOG_FILE="${LOG_FILE:-/var/log/skillpulse/health.log}"
ALERT_WEBHOOK="${ALERT_WEBHOOK:-}"
MYSQL_SECRET="${MYSQL_SECRET:-mysql-secret}"

CHECKS_PASSED=0
CHECKS_FAILED=0
FAILED_CHECKS=()

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()     { echo -e "$(date '+%Y-%m-%d %H:%M:%S') [INFO]  $*" | tee -a "$LOG_FILE"; }
pass()    { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${GREEN}[PASS]${NC}  $*" | tee -a "$LOG_FILE"; ((CHECKS_PASSED++)); }
fail()    { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${RED}[FAIL]${NC}  $*" | tee -a "$LOG_FILE"; ((CHECKS_FAILED++)); FAILED_CHECKS+=("$*"); }
warn()    { echo -e "$(date '+%Y-%m-%d %H:%M:%S') ${YELLOW}[WARN]${NC}  $*" | tee -a "$LOG_FILE"; }
section() { echo -e "\n${BLUE}${BOLD}── $* ──${NC}" | tee -a "$LOG_FILE"; }

send_alert() {
  [[ -z "$ALERT_WEBHOOK" ]] && return
  local msg="$1"
  curl -s -X POST -H 'Content-type: application/json' \
    --data "{\"text\": \":rotating_light: *SkillPulse Health Alert* [${NAMESPACE}]\n${msg}\"}" \
    "$ALERT_WEBHOOK" &>/dev/null && log "Alert sent to Slack." || warn "Slack alert failed."
}

check_k8s_ready() {
  local kind="$1" name="$2"
  section "K8s $kind/$name"

  local ready total
  if [[ "$kind" == "statefulset" ]]; then
    ready=$(kubectl get statefulset "$name" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    total=$(kubectl get statefulset "$name" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}'       2>/dev/null || echo "1")
  else
    ready=$(kubectl get deployment "$name" -n "$NAMESPACE" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || echo "0")
    total=$(kubectl get deployment "$name" -n "$NAMESPACE" -o jsonpath='{.spec.replicas}'        2>/dev/null || echo "1")
  fi

  ready="${ready:-0}"; total="${total:-1}"

  if [[ "$ready" -ge 1 ]]; then
    pass "$kind/$name — ${ready}/${total} replicas ready"
  else
    fail "$kind/$name — 0/${total} replicas ready"
  fi

  kubectl get pods -n "$NAMESPACE" -l "app=$name" --no-headers 2>/dev/null \
    | awk '{printf "  %-40s %-10s %s\n", $1, $3, $4}' | tee -a "$LOG_FILE" || true
}

check_http() {
  local name="$1" url="$2" expected_status="${3:-200}" expected_body="${4:-}"
  section "HTTP $name"
  log "GET $url"

  local http_status
  http_status=$(curl -s -o /tmp/sp_health_resp \
    -w "%{http_code}" --connect-timeout "$TIMEOUT" --max-time "$TIMEOUT" \
    "$url" 2>/dev/null) || { fail "$name — connection refused or timeout"; return; }

  if [[ "$http_status" == "$expected_status" ]]; then
    pass "$name — HTTP $http_status"
  else
    fail "$name — expected HTTP $expected_status, got HTTP $http_status"
    return
  fi

  if [[ -n "$expected_body" ]]; then
    if grep -q "$expected_body" /tmp/sp_health_resp 2>/dev/null; then
      pass "$name — body contains '$expected_body'"
    else
      fail "$name — body missing '$expected_body'. Got: $(cat /tmp/sp_health_resp)"
    fi
  fi
}

check_mysql_connectivity() {
  section "MySQL connectivity"

  local pod db_pass
  pod=$(kubectl get pod -n "$NAMESPACE" -l app=mysql \
    --field-selector=status.phase=Running \
    -o jsonpath='{.items[0].metadata.name}' 2>/dev/null || echo "")

  [[ -z "$pod" ]] && { fail "MySQL — no running pod found"; return; }

  db_pass=$(kubectl get secret "$MYSQL_SECRET" -n "$NAMESPACE" \
    -o jsonpath='{.data.root-password}' | base64 --decode 2>/dev/null || echo "")

  local ping_result
  ping_result=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
    mysqladmin ping -h 127.0.0.1 -u root -p"${db_pass}" --silent 2>/dev/null || echo "failed")

  if echo "$ping_result" | grep -qi "mysqld is alive"; then
    pass "MySQL — mysqladmin ping alive"
  else
    fail "MySQL — ping failed (pod=$pod)"
    return
  fi

  local table_count
  table_count=$(kubectl exec -n "$NAMESPACE" "$pod" -- \
    mysql -h 127.0.0.1 -u root -p"${db_pass}" -s -N \
    -e "SELECT COUNT(*) FROM information_schema.tables WHERE table_schema='skillpulse';" \
    2>/dev/null || echo "0")

  if [[ "${table_count:-0}" -gt 0 ]]; then
    pass "MySQL — skillpulse DB has ${table_count} table(s)"
  else
    warn "MySQL — skillpulse DB has 0 tables (may be uninitialised)"
  fi
}

check_pvc() {
  section "Persistent Volume Claims"
  local pvc_status
  pvc_status=$(kubectl get pvc -n "$NAMESPACE" \
    -o jsonpath='{range .items[*]}{.metadata.name}{" "}{.status.phase}{"\n"}{end}' 2>/dev/null || echo "")

  [[ -z "$pvc_status" ]] && { warn "No PVCs found in namespace '$NAMESPACE'."; return; }

  while IFS= read -r line; do
    local pvc_name pvc_phase
    pvc_name=$(echo "$line" | awk '{print $1}')
    pvc_phase=$(echo "$line" | awk '{print $2}')
    [[ "$pvc_phase" == "Bound" ]] && pass "PVC $pvc_name — Bound" || fail "PVC $pvc_name — $pvc_phase (expected Bound)"
  done <<< "$pvc_status"
}

check_secrets() {
  section "Kubernetes Secrets"
  if kubectl get secret "$MYSQL_SECRET" -n "$NAMESPACE" &>/dev/null; then
    pass "Secret '$MYSQL_SECRET' — exists"
  else
    fail "Secret '$MYSQL_SECRET' — NOT FOUND in namespace '$NAMESPACE'"
  fi
}

check_nodes() {
  section "Cluster Nodes"
  local nodes
  nodes=$(kubectl get nodes --no-headers 2>/dev/null || echo "")
  [[ -z "$nodes" ]] && { warn "Cannot reach cluster API server."; return; }

  while IFS= read -r line; do
    local name status
    name=$(echo "$line" | awk '{print $1}')
    status=$(echo "$line" | awk '{print $2}')
    [[ "$status" == "Ready" ]] && pass "Node $name — Ready" || fail "Node $name — $status"
  done <<< "$nodes"
}

print_summary() {
  local total=$((CHECKS_PASSED + CHECKS_FAILED))
  {
    echo ""
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
    echo -e "${BOLD} Health Check Summary — $(date '+%Y-%m-%d %H:%M:%S')${NC}"
    echo -e "${BOLD} Namespace: $NAMESPACE${NC}"
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
    echo -e " Total:  $total   ${GREEN}Passed: $CHECKS_PASSED${NC}   ${RED}Failed: $CHECKS_FAILED${NC}"
    if [[ "$CHECKS_FAILED" -gt 0 ]]; then
      echo -e "${RED}Failed checks:${NC}"
      for c in "${FAILED_CHECKS[@]}"; do echo -e "  ${RED}✗${NC} $c"; done
    fi
    echo -e "${BOLD}══════════════════════════════════════════${NC}"
  } | tee -a "$LOG_FILE"
}

main() {
  mkdir -p "$(dirname "$LOG_FILE")"
  log "Starting SkillPulse health check — namespace: $NAMESPACE"

  check_secrets
  check_nodes
  check_pvc
  check_k8s_ready "statefulset" "mysql"
  check_mysql_connectivity
  check_k8s_ready "deployment" "backend"
  check_http "Backend /health"        "http://${BACKEND_HOST}:${BACKEND_PORT}/health"        "200" "healthy"
  check_http "Backend /api/dashboard" "http://${BACKEND_HOST}:${BACKEND_PORT}/api/dashboard" "200"
  check_k8s_ready "deployment" "frontend"
  check_http "Frontend /"             "http://${BACKEND_HOST}:${FRONTEND_PORT}/"              "200"

  print_summary

  if [[ "$CHECKS_FAILED" -gt 0 ]]; then
    local msg="$CHECKS_FAILED check(s) failed:\n"
    for c in "${FAILED_CHECKS[@]}"; do msg+="• $c\n"; done
    send_alert "$msg"
    exit 1
  fi

  log "All health checks passed."
  exit 0
}

main "$@"
