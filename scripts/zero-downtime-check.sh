#!/usr/bin/env bash
#
# Proves the rolling update is genuinely zero-downtime.
#
# Fires continuous requests at the service while restarting the Deployment,
# and reports how many were dropped. Expected result: zero.
#
# This is the demonstration that separates "I configured maxUnavailable: 0"
# from "I verified it works" - the two are not the same, because endpoint
# removal and SIGTERM race unless the application drains deliberately.
#
# Usage:
#   ./zero-downtime-check.sh [-n namespace] [-r release] [-d duration] [-i interval]

set -euo pipefail

NAMESPACE="${NAMESPACE:-orders-api}"
RELEASE="${RELEASE:-orders-api}"
DURATION=180
INTERVAL=0.2
TARGET=""

while getopts "n:r:d:i:u:h" opt; do
  case "$opt" in
    n) NAMESPACE="$OPTARG" ;;
    r) RELEASE="$OPTARG" ;;
    d) DURATION="$OPTARG" ;;
    i) INTERVAL="$OPTARG" ;;
    u) TARGET="$OPTARG" ;;
    h) sed -n '2,14p' "$0"; exit 0 ;;
    *) exit 1 ;;
  esac
done

command -v kubectl >/dev/null || { echo "kubectl not found" >&2; exit 1; }
command -v curl    >/dev/null || { echo "curl not found" >&2; exit 1; }

# ---------------------------------------------------------------------------
# Resolve an externally reachable address
# ---------------------------------------------------------------------------
if [[ -z "$TARGET" ]]; then
  echo "Looking up the LoadBalancer address for svc/${RELEASE}..."
  IP=$(kubectl -n "$NAMESPACE" get svc "$RELEASE" \
        -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)

  if [[ -z "$IP" ]]; then
    echo "No LoadBalancer IP on svc/${RELEASE}; trying the ingress controller..."
    IP=$(kubectl -n ingress-nginx get svc ingress-nginx-controller \
          -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
  fi

  [[ -n "$IP" ]] || {
    echo "ERROR: could not resolve an external address. Pass one with -u http://host" >&2
    exit 1
  }
  TARGET="http://${IP}"
fi

# /healthz/ready is the right target: it is the endpoint that flips to 503
# during drain, so a dropped request here is unambiguous.
URL="${TARGET%/}/healthz/ready"

echo
echo "Target      : ${URL}"
echo "Namespace   : ${NAMESPACE}"
echo "Deployment  : ${RELEASE}"
echo "Duration    : ${DURATION}s at ${INTERVAL}s intervals"
echo

# ---------------------------------------------------------------------------
# Baseline
# ---------------------------------------------------------------------------
echo "Checking the endpoint is healthy before starting..."
curl -fsS --max-time 10 "$URL" >/dev/null || {
  echo "ERROR: endpoint is not healthy to begin with. Fix that first." >&2
  exit 1
}
echo "OK."
echo

RESULTS=$(mktemp)
trap 'rm -f "$RESULTS"' EXIT

# ---------------------------------------------------------------------------
# Load generator
# ---------------------------------------------------------------------------
generate_load() {
  local deadline=$(( $(date +%s) + DURATION ))
  while [[ $(date +%s) -lt $deadline ]]; do
    # --max-time bounds a hung connection so one stall cannot skew the run.
    code=$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "$URL" 2>/dev/null || echo "000")
    printf '%s\n' "$code" >> "$RESULTS"
    sleep "$INTERVAL"
  done
}

echo "Starting load generator..."
generate_load &
LOAD_PID=$!

sleep 5

# ---------------------------------------------------------------------------
# Trigger the rollout
# ---------------------------------------------------------------------------
echo "Triggering a rolling restart..."
kubectl -n "$NAMESPACE" rollout restart "deploy/${RELEASE}"

echo "Watching the rollout..."
kubectl -n "$NAMESPACE" rollout status "deploy/${RELEASE}" --timeout=10m

echo
echo "Rollout complete. Letting the load generator finish..."
wait "$LOAD_PID" 2>/dev/null || true

# ---------------------------------------------------------------------------
# Report
# ---------------------------------------------------------------------------
TOTAL=$(wc -l < "$RESULTS" | tr -d ' ')
OK=$(grep -c '^200$' "$RESULTS" || true)
FAILED=$(( TOTAL - OK ))

echo
echo "======================================"
echo "  Requests sent : ${TOTAL}"
echo "  HTTP 200      : ${OK}"
echo "  Failed        : ${FAILED}"
echo "======================================"

if [[ "$FAILED" -gt 0 ]]; then
  echo
  echo "Breakdown of non-200 responses:"
  grep -v '^200$' "$RESULTS" | sort | uniq -c | sort -rn | while read -r count code; do
    case "$code" in
      000) label="connection failed / timed out" ;;
      502) label="bad gateway - proxy reached a pod that had stopped listening" ;;
      503) label="service unavailable - no ready endpoints" ;;
      504) label="gateway timeout" ;;
      *)   label="" ;;
    esac
    printf '  %6s  %s  %s\n' "$count" "$code" "$label"
  done
  echo
  echo "RESULT: FAIL - the rollout dropped requests."
  echo
  echo "Usual causes:"
  echo "  * SHUTDOWN_DRAIN_MS too short for endpoint propagation to complete"
  echo "  * terminationGracePeriodSeconds shorter than the drain window"
  echo "  * maxUnavailable > 0"
  echo "  * keepAliveTimeout below the load balancer idle timeout (produces 502s)"
  exit 1
fi

echo
echo "RESULT: PASS - no requests dropped during the rolling update."
