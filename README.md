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

Each env can set `namespace:` in its values file; the script uses it for `helm -n`. Other actions: `all`, `core`, `vmagent`, `fluent-bit`, `demo-apps`, `delete-all`.

## SQL exporter (optional)

[sql_exporter](https://github.com/burningalchemist/sql_exporter) runs as its **own Helm release**: it executes SQL and serves `/metrics` only. **vmagent** (separate release) scrapes that URL over the cluster network—typically the in-cluster Service hostname, for example `sql-exporter:9399` in the same namespace, or `sql-exporter.<namespace>.svc.cluster.local:9399` from elsewhere.

Values:

- [`values/sql-exporter-standalone.yaml`](values/sql-exporter-standalone.yaml) — install the chart at `grafascope/scrapers/sql-exporter`. The file documents how **jobs** (DSN targets) map to **collectors** (queries), with two example jobs and two different collector files.
- [`values/vmagent-scrape-sql-exporter.yaml`](values/vmagent-scrape-sql-exporter.yaml) — merge into the **grafascope-vmagent** upgrade so vmagent gets an extra `scrapeTargets` job (keeps `sql-exporter.enabled: false` on the umbrella chart so sql_exporter is not deployed twice).

The **grafascope submodule is not modified from this repo**; `sql-exporter-standalone.yaml` includes a minimal `global.image.registry` entry where the vendored chart expects it so standalone Helm renders without chart edits.

From the submodule root (`grafascope-example/grafascope`):

```bash
kubectl -n grafascope create secret generic sql-exporter-dsns \
  --from-literal=ledger='postgresql://user:pass@host:5432/ledger?sslmode=disable' \
  --from-literal=warehouse='postgresql://user:pass@host:5432/warehouse?sslmode=disable'

helm upgrade --install sql-exporter ./grafascope/scrapers/sql-exporter -n grafascope \
  -f ../values/sql-exporter-standalone.yaml

helm dependency update ./grafascope/releases/vmagent
helm upgrade --install grafascope-vmagent ./grafascope/releases/vmagent -n grafascope \
  -f grafascope/values.yaml \
  -f ../values/grafascope-obs.yaml \
  -f ../values/vmagent-scrape-sql-exporter.yaml
```

Edit the scrape target in `vmagent-scrape-sql-exporter.yaml` if sql-exporter uses another namespace, port, or release-derived Service name.

### k3d smoke test

From the example repo root (after `git submodule update --init --recursive` so `grafascope/grafascope/scrapers/sql-exporter` exists):

```bash
./scripts/k3d-test-sql-exporter.sh
```

The script installs the sql-exporter chart from the submodule (`grafascope/grafascope/scrapers/sql-exporter`). If that path is missing, set `GRAFASCOPE_CHART_ROOT` to a checkout whose `scrapers/sql-exporter` directory contains the chart.

## Structure

```
grafascope-example/
├── grafascope/              # submodule → ../grafascope
├── scripts/
│   └── k3d-test-sql-exporter.sh  # optional: k3d smoke test (Postgres + core + vmagent + sql_exporter)
├── values/
│   ├── grafascope-dev.yaml  # single env
│   ├── grafascope-obs.yaml  # obs backend (core + fluent + vmagent)
│   ├── grafascope-demo.yaml # demo apps + vmagent, OTEL → victoria-traces
│   ├── sql-exporter-standalone.yaml   # optional: sql_exporter chart only
│   └── vmagent-scrape-sql-exporter.yaml  # optional: vmagent scrape job via k8s DNS
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
