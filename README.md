# Grafascope example deployment

Example consumer repo that uses [grafascope](../grafascope) as a Git submodule.

## Setup

```bash
git submodule update --init --recursive
```

## Deploy

### Single env (grafascope-dev)

```bash
./grafascope/scripts/update-and-upgrade.sh grafascope-dev all
```

### Split envs: obs backend + demo apps

1. **Obs stack** (Grafana, Victoria*, fluent-bit, vmagent) in `grafascope` NS:

   ```bash
   ./grafascope/scripts/update-and-upgrade.sh grafascope-obs obs
   ```

2. **Demo apps** (demo-apps + vmagent) in `grafascope-demo` NS, traces → Victoria Traces in grafascope:

   ```bash
   ./grafascope/scripts/update-and-upgrade.sh grafascope-demo demo
   ```

Each env can set `namespace:` in its values file; the script uses it for `helm -n`.

## Structure

```
grafascope-example/
├── grafascope/              # submodule → ../grafascope
├── values/
│   ├── grafascope-dev.yaml  # single env
│   ├── grafascope-obs.yaml  # obs backend (core + fluent + vmagent)
│   └── grafascope-demo.yaml # demo apps + vmagent, OTEL → victoria-traces
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
