# grafascope-obs – UI and ingest endpoints

Observability backend (Grafana, VictoriaMetrics, Victoria Logs, Victoria Traces, fluent-bit, vmagent) in namespace `grafascope`. With default `domain: localhost`, use the base URL below; replace host/path if you override `global.domain` or paths.

**Base URL (local):** `http://localhost/grafascope`

---

## Available UI interfaces

| Service          | Path              | URL (local) |
|------------------|-------------------|-------------|
| Grafana          | `/grafana`        | http://localhost/grafascope/grafana |
| Victoria Metrics | `/victoria-metrics` | http://localhost/grafascope/victoria-metrics |
| Victoria Logs    | `/victoria-logs`  | http://localhost/grafascope/victoria-logs (vmui / select UI) |
| Victoria Traces  | `/victoria-traces`| http://localhost/grafascope/victoria-traces |
| vmagent          | `/vmagent`        | http://localhost/grafascope/vmagent |

---

## Ingest endpoints

### Metrics (Prometheus remote_write)

- **URL:** `http://localhost/grafascope/victoria-metrics/api/v1/write`
- **Method:** POST  
- **Body:** Prometheus remote_write (snappy-compressed protobuf or JSON).  
- **In-cluster (e.g. vmagent):** `http://victoria-metrics:8428/grafascope/victoria-metrics/api/v1/write`

### Logs (Victoria Logs)

- **JSON lines (e.g. fluent-bit):**  
  `http://localhost/grafascope/victoria-logs/insert/jsonline`  
  Use query params for stream fields, message field, time field (see fluent-bit `outputs` in `grafascope-obs.yaml`).
- **Native (e.g. vlagent):**  
  `http://localhost/grafascope/victoria-logs/insert/native`  
- **In-cluster:** `http://victoria-logs:9428/grafascope/victoria-logs/insert/jsonline` (or `/insert/native`).

### Traces (Victoria Traces, OTLP)

- **OTLP gRPC (in-cluster):** `http://victoria-traces.grafascope.svc.cluster.local:4317`  
  Used by apps (e.g. demo-apps) and collectors in other namespaces.
- **OTLP HTTP:**  
  `http://localhost/grafascope/victoria-traces/insert/opentelemetry/v1/traces`  
  POST with OTLP/HTTP protobuf or JSON.

---

Replace `localhost` and `/grafascope` with your `global.domain` and namespace path if you change them in `grafascope-obs.yaml`.
