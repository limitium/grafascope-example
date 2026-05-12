#!/usr/bin/env bash
# Smoke test: k3d + PostgreSQL + grafascope-core + vmagent (with sql scrape) + standalone sql-exporter.
# Run from anywhere; uses paths relative to this repo.
#
# Prerequisites: k3d, kubectl, helm; Bitnami chart repo (script adds it).
#
# Optional env:
#   CLUSTER_NAME   (default: grafascope-sqltest)
#   NAMESPACE      (default: grafascope)
#   GRAFASCOPE_CHART_ROOT  Directory that contains scrapers/sql-exporter (default: submodule inner tree
#                          <repo>/grafascope/grafascope). Override if you use a different checkout.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUBMODULE_ROOT="${REPO_ROOT}/grafascope"
CLUSTER_NAME="${CLUSTER_NAME:-grafascope-sqltest}"
NAMESPACE="${NAMESPACE:-grafascope}"

GRAFASCOPE_CHART_ROOT="${GRAFASCOPE_CHART_ROOT:-}"
if [[ -z "${GRAFASCOPE_CHART_ROOT}" ]]; then
  if [[ -d "${SUBMODULE_ROOT}/grafascope/scrapers/sql-exporter" ]]; then
    GRAFASCOPE_CHART_ROOT="${SUBMODULE_ROOT}/grafascope"
  else
    GRAFASCOPE_CHART_ROOT="$(cd "${REPO_ROOT}/../grafascope/grafascope" 2>/dev/null && pwd || true)"
  fi
fi
if [[ ! -d "${GRAFASCOPE_CHART_ROOT}/scrapers/sql-exporter" ]]; then
  echo "ERROR: sql-exporter chart not found under GRAFASCOPE_CHART_ROOT=${GRAFASCOPE_CHART_ROOT:-<empty>}" >&2
  echo "Set GRAFASCOPE_CHART_ROOT to your grafascope monorepo root (directory that contains scrapers/sql-exporter)." >&2
  exit 1
fi

echo "=== k3d cluster: ${CLUSTER_NAME} ==="
if ! k3d cluster list 2>/dev/null | awk '{print $1}' | grep -qx "${CLUSTER_NAME}"; then
  k3d cluster create "${CLUSTER_NAME}" --wait --timeout 300s
fi
kubectl config use-context "k3d-${CLUSTER_NAME}"

echo "=== Namespace ${NAMESPACE} ==="
kubectl create namespace "${NAMESPACE}" --dry-run=client -o yaml | kubectl apply -f -

echo "=== Bitnami PostgreSQL (ephemeral disk) ==="
helm repo add bitnami https://charts.bitnami.com/bitnami 2>/dev/null || true
helm repo update bitnami >/dev/null
helm upgrade --install test-pg bitnami/postgresql -n "${NAMESPACE}" \
  --set auth.postgresPassword=testpass \
  --set primary.persistence.enabled=false \
  --wait --timeout 8m

echo "=== Secret sql-exporter-dsns (ledger + warehouse DSNs; same DB for smoke test) ==="
kubectl create secret generic sql-exporter-dsns -n "${NAMESPACE}" \
  --from-literal=ledger='postgresql://postgres:testpass@test-pg-postgresql:5432/postgres?sslmode=disable' \
  --from-literal=warehouse='postgresql://postgres:testpass@test-pg-postgresql:5432/postgres?sslmode=disable' \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Helm: grafascope-core + vmagent (submodule) ==="
cd "${SUBMODULE_ROOT}"
helm dependency update ./grafascope/releases/core >/dev/null
helm dependency update ./grafascope/releases/vmagent >/dev/null
helm upgrade --install grafascope-core ./grafascope/releases/core -n "${NAMESPACE}" \
  -f grafascope/values.yaml \
  -f "${REPO_ROOT}/values/grafascope-obs.yaml" \
  --wait --timeout 15m
helm upgrade --install grafascope-vmagent ./grafascope/releases/vmagent -n "${NAMESPACE}" \
  -f grafascope/values.yaml \
  -f "${REPO_ROOT}/values/grafascope-obs.yaml" \
  -f "${REPO_ROOT}/values/vmagent-scrape-sql-exporter.yaml" \
  --wait --timeout 8m

echo "=== Helm: sql-exporter (standalone chart from GRAFASCOPE_CHART_ROOT) ==="
helm upgrade --install sql-exporter "${GRAFASCOPE_CHART_ROOT}/scrapers/sql-exporter" -n "${NAMESPACE}" \
  -f "${REPO_ROOT}/values/sql-exporter-standalone.yaml" \
  --wait --timeout 5m

echo "=== Pods ==="
kubectl get pods -n "${NAMESPACE}"

echo "=== Assertions (port-forward) ==="
trap 'kill $PF1 $PF2 2>/dev/null || true' EXIT
kubectl port-forward -n "${NAMESPACE}" svc/sql-exporter 19399:9399 >/tmp/pf-sql.log 2>&1 &
PF1=$!
kubectl port-forward -n "${NAMESPACE}" svc/victoria-metrics 18428:8428 >/tmp/pf-vm.log 2>&1 &
PF2=$!
sleep 2

if ! curl -sf "http://127.0.0.1:19399/metrics" | grep -q 'ledger_db_transactions_committed_total'; then
  echo "FAIL: sql-exporter /metrics missing ledger_db_transactions_committed_total" >&2
  exit 1
fi
if ! curl -sf "http://127.0.0.1:18428/grafascope/victoria-metrics/api/v1/query?query=ledger_db_transactions_committed_total" | grep -q '"status":"success"'; then
  echo "FAIL: VictoriaMetrics query for ledger_db_transactions_committed_total" >&2
  exit 1
fi

echo "OK: sql-exporter exposes DB counters; vmagent remote_write path sees the series."
echo "Tip: kubectl port-forward -n ${NAMESPACE} svc/grafana 3000:3000  # explore in Grafana"
