#!/usr/bin/env bash
# Test OTLP gRPC gateway route (external call to domain/grafascope/victoria-traces-grpc).
# Verifies the HTTPRoute forwards gRPC and returns a valid response.
#
# Usage: ./scripts/test-otlp-grpc-gateway.sh [HOST:PORT] [PATH_PREFIX]
# Default: HOST:PORT=localhost:80, PATH_PREFIX=/grafascope/victoria-traces-grpc

set -e

HOST_PORT="${1:-localhost:80}"
PATH_PREFIX="${2:-/grafascope/victoria-traces-grpc}"
GRPC_PATH="${PATH_PREFIX}/opentelemetry.proto.collector.trace.v1.TraceService/Export"
URL="http://${HOST_PORT}${GRPC_PATH}"

echo "Testing OTLP gRPC gateway route at $URL ..."

# Send a minimal gRPC-like POST; backend may return 200 (OK) or 400 (bad request for empty body)
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$URL" \
  -H "Content-Type: application/grpc" \
  -H "TE: trailers" \
  -H "Host: ${HOST_PORT%:*}" \
  -d '' 2>/dev/null || echo "000")

if [[ "$HTTP_CODE" == "200" || "$HTTP_CODE" == "400" ]]; then
  echo "OK: Gateway is routing (HTTP $HTTP_CODE). gRPC endpoint is reachable."
  echo "    Use endpoint URL: http://${HOST_PORT}${PATH_PREFIX} for OTLP gRPC clients that support path."
  exit 0
else
  echo "FAIL: Got HTTP $HTTP_CODE (expected 200 or 400). Check gateway HTTPRoute and namespace."
  exit 1
fi
