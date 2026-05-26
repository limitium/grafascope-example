#!/usr/bin/env bash
# Smoke test: k3d + Java JMX target + grafascope-core + grafascope-jmx-exporter + vmagent (scrapeJmxExporter).
# Run from anywhere; uses paths relative to this repo.
#
# Prerequisites: k3d, kubectl, helm.
#
# Optional env:
#   CLUSTER_NAME   (default: grafascope-jmxtest)
#   NAMESPACE      (default: grafascope)
#   GRAFASCOPE_HELM_ROOT  Directory that contains ./grafascope/releases (submodule inner checkout or
#                         sibling grafascope monorepo root). Auto-detected if unset.
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SUBMODULE_ROOT="${REPO_ROOT}/grafascope"
CLUSTER_NAME="${CLUSTER_NAME:-grafascope-jmxtest}"
NAMESPACE="${NAMESPACE:-grafascope}"

GRAFASCOPE_HELM_ROOT="${GRAFASCOPE_HELM_ROOT:-}"
if [[ -z "${GRAFASCOPE_HELM_ROOT}" ]]; then
  if [[ -d "${SUBMODULE_ROOT}/grafascope/releases/jmx-exporter" ]]; then
    GRAFASCOPE_HELM_ROOT="${SUBMODULE_ROOT}"
  elif [[ -d "${REPO_ROOT}/../grafascope/grafascope/releases/jmx-exporter" ]]; then
    GRAFASCOPE_HELM_ROOT="$(cd "${REPO_ROOT}/../grafascope" && pwd)"
  fi
fi
if [[ -z "${GRAFASCOPE_HELM_ROOT}" || ! -d "${GRAFASCOPE_HELM_ROOT}/grafascope/releases/jmx-exporter" ]]; then
  echo "ERROR: grafascope Helm tree not found (need ./grafascope/releases/jmx-exporter)." >&2
  echo "Bump the grafascope submodule or set GRAFASCOPE_HELM_ROOT to a checkout that includes releases/jmx-exporter." >&2
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

echo "=== Deploy Java JMX target ==="
kubectl apply -n "${NAMESPACE}" -f - <<'EOF'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: test-jmx-java
spec:
  replicas: 1
  selector:
    matchLabels:
      app: test-jmx-java
  template:
    metadata:
      labels:
        app: test-jmx-java
    spec:
      containers:
        - name: jvm
          image: eclipse-temurin:17-jdk
          imagePullPolicy: IfNotPresent
          ports:
            - containerPort: 9999
              name: jmx
          command: ["/bin/sh", "-c"]
          args:
            - |
              cat >/tmp/Test.java <<'JAVA'
              public class Test {
                public static void main(String[] args) throws Exception {
                  while (true) { Thread.sleep(30000); }
                }
              }
              JAVA
              javac /tmp/Test.java
              exec java \
                -Dcom.sun.management.jmxremote=true \
                -Dcom.sun.management.jmxremote.local.only=false \
                -Dcom.sun.management.jmxremote.authenticate=false \
                -Dcom.sun.management.jmxremote.ssl=false \
                -Dcom.sun.management.jmxremote.port=9999 \
                -Dcom.sun.management.jmxremote.rmi.port=9999 \
                -Djava.rmi.server.hostname=test-jmx-java \
                -cp /tmp Test
---
apiVersion: v1
kind: Service
metadata:
  name: test-jmx-java
spec:
  selector:
    app: test-jmx-java
  ports:
    - name: jmx
      port: 9999
      targetPort: 9999
EOF
kubectl rollout status deployment/test-jmx-java -n "${NAMESPACE}" --timeout=6m

echo "=== Helm: grafascope-core + grafascope-jmx-exporter + vmagent ==="
cd "${GRAFASCOPE_HELM_ROOT}"
helm dependency update ./grafascope/releases/core >/dev/null
helm dependency update ./grafascope/releases/vmagent >/dev/null
helm dependency update ./grafascope/releases/jmx-exporter >/dev/null

helm upgrade --install grafascope-core ./grafascope/releases/core -n "${NAMESPACE}" \
  -f grafascope/values.yaml \
  -f "${REPO_ROOT}/values/grafascope-obs.yaml" \
  -f "${REPO_ROOT}/values/k3d-grafana-admin.yaml" \
  --wait --timeout 15m

helm upgrade --install grafascope-jmx-exporter ./grafascope/releases/jmx-exporter -n "${NAMESPACE}" \
  -f grafascope/values.yaml \
  -f "${REPO_ROOT}/values/k3d-jmx-exporter-umbrella.yaml" \
  --wait --timeout 8m

helm upgrade --install grafascope-vmagent ./grafascope/releases/vmagent -n "${NAMESPACE}" \
  -f grafascope/values.yaml \
  -f "${REPO_ROOT}/values/grafascope-obs.yaml" \
  -f "${REPO_ROOT}/values/vmagent-scrape-jmx-exporter.yaml" \
  --wait --timeout 8m

echo "=== Pods ==="
kubectl get pods -n "${NAMESPACE}"

echo "=== Assertions (port-forward) ==="
trap 'kill $PF1 $PF2 2>/dev/null || true' EXIT
kubectl port-forward -n "${NAMESPACE}" svc/jmx-exporter 19404:9404 >/tmp/pf-jmx.log 2>&1 &
PF1=$!
kubectl port-forward -n "${NAMESPACE}" svc/victoria-metrics 18428:8428 >/tmp/pf-vm.log 2>&1 &
PF2=$!
sleep 4

if ! curl -sf "http://127.0.0.1:19404/metrics" | grep -q 'jvm_memory_heap_used_bytes'; then
  echo "FAIL: jmx-exporter /metrics missing jvm_memory_heap_used_bytes" >&2
  exit 1
fi

ok=0
for i in $(seq 1 30); do
  if curl -sf "http://127.0.0.1:18428/grafascope/victoria-metrics/api/v1/query?query=jvm_memory_heap_used_bytes" | grep -q '"status":"success"'; then
    ok=1
    break
  fi
  sleep 2
done
if [[ "$ok" != "1" ]]; then
  echo "FAIL: VictoriaMetrics query for jvm_memory_heap_used_bytes" >&2
  exit 1
fi

echo "OK: jmx-exporter exposes JMX-derived metrics; vmagent remote_write path sees the series."
echo "Tip: kubectl port-forward -n ${NAMESPACE} svc/grafana 3000:3000  # explore in Grafana"
