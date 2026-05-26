# Grafascope example deployment

Example consumer repo that uses [grafascope](../grafascope) as a Git submodule.

## Setup

```bash
git submodule update --init --recursive
```

## Deploy

Run commands from **`grafascope-example/grafascope`** (submodule root). The script loads `grafascope/values.yaml` plus `../values/<env>.yaml` (see `grafascope/scripts/update-and-upgrade.sh`).

### Single env (grafascope-dev)

```bash
./scripts/update-and-upgrade.sh grafascope-dev all
```

### Split envs: obs backend + demo apps

1. **Obs stack** (`gfs-user`, Grafana, Victoria*, fluent-bit, vmagent) in `grafascope` NS:

   ```bash
   ./scripts/update-and-upgrade.sh grafascope-obs obs
   ```

2. **Demo apps** (demo-apps + vmagent) in `grafascope-demo` NS, traces → Victoria Traces in grafascope:

   ```bash
   ./scripts/update-and-upgrade.sh grafascope-demo demo
   ```

Each env can set `namespace:` in its values file; the script uses it for `helm -n`. Other actions: `all`, `core`, `vmagent`, `sql-exporter`, `jmx-exporter`, `fluent-bit`, `demo-apps`, `delete-all`.

## SQL exporter (optional)

[sql_exporter](https://github.com/burningalchemist/sql_exporter) is deployed as **`grafascope-sql-exporter`** (separate Helm release from vmagent). **vmagent** scrapes its `/metrics` when **`vmagent.scrapeSqlExporter: true`** is set in merged values (same namespace, Service `sql-exporter`, port `global.ports.sql-exporter`).

Values:

- [`values/sql-exporter-standalone.yaml`](values/sql-exporter-standalone.yaml) — direct install of `grafascope/scrapers/sql-exporter` (Postgres-style example: jobs, collectors, passwords from Secrets). Alternatively enable **`sql-exporter.enabled`** in your env values and use `./scripts/update-and-upgrade.sh <env> sql-exporter` or `obs` / `all` (upstream installs `grafascope/releases/sql-exporter`).
- [`values/sql-exporter-oracle-example.yaml`](values/sql-exporter-oracle-example.yaml) — **Oracle (full config):** explicit `sql_exporter.yml` + collectors; password in Secret (`ORACLE_PASSWORD`); schema/table names via ConfigMap (`ORACLE_SCHEMA`). See file header for DSN shape, grants, and Helm commands.
- [`values/sql-exporter-oracle-minimal.yaml`](values/sql-exporter-oracle-minimal.yaml) — **Oracle (minimal):** entire `oracle://...` DSN in Secret (`ORACLE_DSN`); chart bootstrap generates a probe-only config (`oracle_sql_exporter_probe`). Best when passwords contain URL-hostile characters.
- [`values/k3d-sql-exporter-umbrella.yaml`](values/k3d-sql-exporter-umbrella.yaml) — nested values for **`grafascope-sql-exporter`** (used by the k3d smoke script; Postgres jobs).
- [`values/k3d-sql-exporter-umbrella-oracle-example.yaml`](values/k3d-sql-exporter-umbrella-oracle-example.yaml) — umbrella-shaped overlay matching **`sql-exporter-oracle-example.yaml`**.
- [`values/k3d-sql-exporter-umbrella-oracle-minimal.yaml`](values/k3d-sql-exporter-umbrella-oracle-minimal.yaml) — umbrella-shaped overlay matching **`sql-exporter-oracle-minimal.yaml`**.
- [`values/vmagent-scrape-sql-exporter.yaml`](values/vmagent-scrape-sql-exporter.yaml) — sets **`vmagent.scrapeSqlExporter: true`** (built-in scrape job; no manual `scrapeTargets` entry).

The **grafascope submodule includes first-class sql-exporter and jmx-exporter charts/releases**; this repo keeps only environment-specific value overlays and smoke scripts.

From the submodule root (`grafascope-example/grafascope`):

```bash
kubectl -n grafascope create secret generic sql-exporter-db-passwords \
  --from-literal=ledger-password='REPLACE_ME' \
  --from-literal=warehouse-password='REPLACE_ME'

# Option A — direct chart (example values are flat for this chart only):
helm upgrade --install sql-exporter ./grafascope/scrapers/sql-exporter -n grafascope \
  -f ../values/sql-exporter-standalone.yaml

# Option B — upstream umbrella release (values live under sql-exporter: in grafascope/values.yaml + overlays):
#   ./scripts/update-and-upgrade.sh grafascope-obs sql-exporter

# Enable vmagent’s sql-exporter scrape job (after sql-exporter Service exists):
helm dependency update ./grafascope/releases/vmagent
helm upgrade --install grafascope-vmagent ./grafascope/releases/vmagent -n grafascope \
  -f grafascope/values.yaml \
  -f ../values/grafascope-obs.yaml \
  -f ../values/vmagent-scrape-sql-exporter.yaml
```

For cross-namespace scrape, leave **`vmagent.scrapeSqlExporter`** false and add a **`vmagent.scrapeTargets`** job with an FQDN target instead.

## Java JMX exporter (optional)

[jmx_exporter](https://github.com/prometheus/jmx_exporter) is deployed as **`grafascope-jmx-exporter`** (separate Helm release from vmagent). It supports **multiple JMX endpoints in one release** via `jmx-exporter.targets[]` (each target has its own `jmxUrl` and rules). **vmagent** scrapes all matching exporter Services when **`vmagent.scrapeJmxExporter: true`** is set in merged values.

Values:

- [`values/jmx-exporter-standalone.yaml`](values/jmx-exporter-standalone.yaml) — direct install of `grafascope/scrapers/jmx-exporter` with **multi-target** examples (`targets[]`) and per-target JMX->metric rule mappings.
- [`values/k3d-jmx-exporter-umbrella.yaml`](values/k3d-jmx-exporter-umbrella.yaml) — nested values for **`grafascope-jmx-exporter`** (used by the JMX k3d smoke script).
- [`values/vmagent-scrape-jmx-exporter.yaml`](values/vmagent-scrape-jmx-exporter.yaml) — sets **`vmagent.scrapeJmxExporter: true`** (built-in scrape job; no manual `scrapeTargets` entry).
- [`values/jmx-exporter-config-example.yaml`](values/jmx-exporter-config-example.yaml) — standalone rules reference for Java agent/standalone usage.

From the submodule root (`grafascope-example/grafascope`):

```bash
# Option A — direct chart:
helm upgrade --install jmx-exporter ./grafascope/scrapers/jmx-exporter -n grafascope \
  -f ../values/jmx-exporter-standalone.yaml

# Option B — upstream umbrella release:
#   ./scripts/update-and-upgrade.sh grafascope-obs jmx-exporter

# Enable vmagent's jmx-exporter scrape job:
helm dependency update ./grafascope/releases/vmagent
helm upgrade --install grafascope-vmagent ./grafascope/releases/vmagent -n grafascope \
  -f grafascope/values.yaml \
  -f ../values/grafascope-obs.yaml \
  -f ../values/vmagent-scrape-jmx-exporter.yaml
```

### Oracle (reference values)

Two patterns live under `values/` (each has a matching `k3d-sql-exporter-umbrella-*.yaml` for **`grafascope-sql-exporter`**):

1. **Full** — [`sql-exporter-oracle-example.yaml`](values/sql-exporter-oracle-example.yaml): Git-versioned jobs/collectors; only secrets and non-secret names in Kubernetes.
2. **Minimal** — [`sql-exporter-oracle-minimal.yaml`](values/sql-exporter-oracle-minimal.yaml): one Secret holds the full DSN; the chart’s Oracle bootstrap supplies `sql_exporter.yml` and a `FROM DUAL` probe.

You still need an Oracle endpoint reachable from the cluster (often a `Service` pointing at an external DB or a sidecar). The k3d smoke script does not install Oracle.

### k3d smoke tests

From the example repo root (after `git submodule update --init --recursive` so `grafascope/grafascope/scrapers/sql-exporter` exists):

```bash
./scripts/k3d-test-sql-exporter.sh
./scripts/k3d-test-jmx-exporter.sh
```

The script installs **`grafascope-sql-exporter`** from the submodule when it includes `grafascope/releases/sql-exporter`; otherwise set **`GRAFASCOPE_HELM_ROOT`** to a grafascope checkout whose `grafascope/releases/sql-exporter` directory exists (for example the sibling `../grafascope` monorepo).

## Structure

```
grafascope-example/
├── grafascope/              # submodule → ../grafascope
├── scripts/
│   ├── k3d-test-sql-exporter.sh  # optional: k3d smoke test (Postgres + core + vmagent + sql_exporter)
│   └── k3d-test-jmx-exporter.sh  # optional: k3d smoke test (Java JMX target + jmx_exporter + vmagent)
├── values/
│   ├── grafascope-dev.yaml  # single env
│   ├── grafascope-obs.yaml  # obs backend (core + fluent + vmagent)
│   ├── grafascope-demo.yaml # demo apps + vmagent, OTEL → victoria-traces
│   ├── sql-exporter-standalone.yaml   # optional: sql_exporter (Postgres-style example)
│   ├── sql-exporter-oracle-example.yaml  # Oracle: full sql_exporter.yml + Secret password
│   ├── sql-exporter-oracle-minimal.yaml  # Oracle: full DSN in Secret + chart bootstrap
│   ├── k3d-sql-exporter-umbrella.yaml   # k3d: nested values for grafascope-sql-exporter (Postgres)
│   ├── k3d-sql-exporter-umbrella-oracle-example.yaml
│   ├── k3d-sql-exporter-umbrella-oracle-minimal.yaml
│   ├── jmx-exporter-standalone.yaml     # optional: jmx-exporter standalone values (target jmxUrl/rules)
│   ├── k3d-jmx-exporter-umbrella.yaml   # k3d: nested values for grafascope-jmx-exporter
│   ├── vmagent-scrape-sql-exporter.yaml  # optional: vmagent.scrapeSqlExporter: true
│   ├── vmagent-scrape-jmx-exporter.yaml  # optional: vmagent.scrapeJmxExporter: true
│   └── jmx-exporter-config-example.yaml  # reference jmx_exporter config.yaml (JMX -> metric mapping)
└── README.md
```

## Submodule URL

This example uses a local path (`../grafascope`) for development. To point at a
remote repo instead, edit `.gitmodules`:

```ini
[submodule "grafascope"]
    path = grafascope
    url = https://github.com/your-org/grafascope.git
```

Then run:

```bash
git submodule sync
git submodule update --init --recursive
```
