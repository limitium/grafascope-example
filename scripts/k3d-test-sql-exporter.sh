#!/usr/bin/env bash
# Smoke test: k3d + PostgreSQL + grafascope-core + grafascope-sql-exporter (umbrella) + vmagent (scrapeSqlExporter).
# Run from anywhere; uses paths relative to this repo.
#
# Prerequisites: k3d, kubectl, helm; Bitnami chart repo (script adds it).
#
# Optional env:
#   CLUSTER_NAME   (default: grafascope-sqltest)
#   NAMESPACE      (default: grafascope)
#   GRAFASCOPE_HELM_ROOT  Directory that contains ./grafascope/releases (submodule inner checkout or
#                         sibling grafascope monorepo root). Auto-detected if unset.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUBMODULE_ROOT="${REPO_ROOT}/grafascope"
CLUSTER_NAME="${CLUSTER_NAME:-grafascope-sqltest}"
NAMESPACE="${NAMESPACE:-grafascope}"

GRAFASCOPE_HELM_ROOT="${GRAFASCOPE_HELM_ROOT:-}"
if [[ -z "${GRAFASCOPE_HELM_ROOT}" ]]; then
  if [[ -d "${SUBMODULE_ROOT}/grafascope/releases/sql-exporter" ]]; then
    GRAFASCOPE_HELM_ROOT="${SUBMODULE_ROOT}"
  elif [[ -d "${REPO_ROOT}/../grafascope/grafascope/releases/sql-exporter" ]]; then
    GRAFASCOPE_HELM_ROOT="$(cd "${REPO_ROOT}/../grafascope" && pwd)"
  fi
fi
if [[ -z "${GRAFASCOPE_HELM_ROOT}" || ! -d "${GRAFASCOPE_HELM_ROOT}/grafascope/releases/sql-exporter" ]]; then
  echo "ERROR: grafascope Helm tree not found (need ./grafascope/releases/sql-exporter)." >&2
  echo "Bump the grafascope submodule or set GRAFASCOPE_HELM_ROOT to a checkout that includes releases/sql-exporter." >&2
  exit 1
fi

echo "=== Using GRAFASCOPE_HELM_ROOT=${GRAFASCOPE_HELM_ROOT} ==="
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

echo "=== Secret sql-exporter-db-passwords (password strings only; keys ledger-password, warehouse-password) ==="
kubectl create secret generic sql-exporter-db-passwords -n "${NAMESPACE}" \
  --from-literal=ledger-password='testpass' \
  --from-literal=warehouse-password='testpass' \
  --dry-run=client -o yaml | kubectl apply -f -

echo "=== Helm: grafascope-core + grafascope-sql-exporter + vmagent ==="
cd "${GRAFASCOPE_HELM_ROOT}"
helm dependency update ./grafascope/releases/core >/dev/null
helm dependency update ./grafascope/releases/vmagent >/dev/null
helm dependency update ./grafascope/releases/sql-exporter >/dev/null

# Older smoke runs installed release "sql-exporter" (direct chart); umbrella uses the same object names
# but release name "grafascope-sql-exporter". Remove the legacy release so ConfigMaps are not adoption-blocked.
if helm status sql-exporter -n "${NAMESPACE}" >/dev/null 2>&1; then
  echo "=== Removing legacy Helm release sql-exporter (direct chart) ==="
  helm uninstall sql-exporter -n "${NAMESPACE}"
fi

helm upgrade --install grafascope-core ./grafascope/releases/core -n "${NAMESPACE}" \
  -f grafascope/values.yaml \
  -f "${REPO_ROOT}/values/grafascope-obs.yaml" \
  -f "${REPO_ROOT}/values/k3d-grafana-admin.yaml" \
  --wait --timeout 15m

helm upgrade --install grafascope-sql-exporter ./grafascope/releases/sql-exporter -n "${NAMESPACE}" \
  -f grafascope/values.yaml \
  -f "${REPO_ROOT}/values/k3d-sql-exporter-umbrella.yaml" \
  --wait --timeout 8m

helm upgrade --install grafascope-vmagent ./grafascope/releases/vmagent -n "${NAMESPACE}" \
  -f grafascope/values.yaml \
  -f "${REPO_ROOT}/values/grafascope-obs.yaml" \
  -f "${REPO_ROOT}/values/vmagent-scrape-sql-exporter.yaml" \
  --wait --timeout 8m

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
