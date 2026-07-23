# ClickStack Observability Dashboard Templates

Download-and-go observability dashboards for teams running **Open Source ClickStack**
(HyperDX + ClickHouse + OpenTelemetry). This repo ships **two complementary deliverables**
that read the *same* ClickHouse / OTel data — no extra collectors or schema changes:

| Deliverable | Use it for | Start here |
|-------------|-----------|------------|
| 🔎 **[HyperDX](hyperdx/)** | Deep, interactive **investigation** — per-domain dashboards, drill-downs, log/trace search, advanced SQL / anomaly-detection tiles | [`hyperdx/README.md`](hyperdx/README.md) |
| 📊 **[Grafana](grafana/)** | At-a-glance **health**, executive views, and **alerting** (generic webhook) | [`grafana/README.md`](grafana/README.md) |

> **Which do I use?** Use **HyperDX to investigate** (rich, click-through, log/trace correlation)
> and **Grafana to watch & page** (high-level golden-signal boards + provisioned alert rules).
> They read the same data, so you can run either or both.

> **Status:** current release `1.0.0-rc1` (see [`VERSION`](VERSION)). The `main` branch may
> include unreleased changes, listed under *Unreleased* in [`CHANGELOG.md`](CHANGELOG.md).

---

## Choose your install path

| I want to… | Route | Start here |
|------------|-------|------------|
| Investigate with the **HyperDX dashboards** | HyperDX import | [`hyperdx/README.md`](hyperdx/README.md) |
| Get **paged from HyperDX** | HyperDX alerts | [`hyperdx/alerts/README.md`](hyperdx/alerts/README.md) |
| At-a-glance **Grafana boards** on any Grafana | Grafana UI import | [`grafana/README.md`](grafana/README.md) |
| **Durable install** on ClickStack's bundled Grafana (Kubernetes) | Grafana ConfigMap provisioning | [`grafana/kubernetes/README.md`](grafana/kubernetes/README.md) |
| Grafana **alerts without filesystem access** (Grafana Cloud) | Terraform | [`grafana/alerting/terraform/`](grafana/alerting/terraform/README.md) |

---

## Repository layout

```
.
├── hyperdx/                    🔎 HyperDX deliverable
│   ├── README.md                 Section guide: install, pre-flight, alerts
│   ├── DASHBOARD-CATALOG.md      Plain-language, per-dashboard field guide (setup tiers)
│   ├── DASHBOARD-DEEP-DIVE.md    Tile-by-tile Q&A for every dashboard
│   ├── dashboards/               11 dashboard templates (*.json) — 5 default + advanced/ (6 opt-in: ClickHouse & collector internals)
│   ├── alerts/                   Importable alert definitions + README
│   ├── docs/                     Auto-generated per-dashboard reference + images
│   ├── gen-docs.js               Regenerates docs/ from the templates
│   ├── import.ps1 / import.sh                Dashboard importer (upsert, idempotent)
│   ├── import-alerts.ps1 / import-alerts.sh  Alerts importer
│   ├── preflight.ps1 / preflight.sh          Compatibility check before import
│   └── requirements.json         Machine-readable support matrix (drives preflight)
│
├── grafana/                    📊 Grafana deliverable
│   ├── README.md                 Section guide: customer import + quick-start
│   ├── dashboards/               6 dashboard templates (*.json) — 5 default + advanced/latency-histograms
│   ├── alerting/                 Provisioned alert rules (YAML) + Terraform equivalent
│   ├── provisioning/             Dev-harness datasource + dashboard providers
│   ├── screenshots/              Live-preview images embedded in README.md
│   ├── gen-dashboards.js         Generates the dashboard JSON
│   ├── validate.js               Validates panel SQL against live ClickHouse
│   └── docker-compose.yml        Throwaway Grafana for authoring/preview
│
├── CONTRIBUTING.md              Maintainer guide (generators, validation, dev harness)
├── CHANGELOG.md · VERSION
└── README.md                   ← you are here
```

---

## 🔎 HyperDX section

Eleven per-domain HyperDX dashboards. **Five import by default** (executive overview, services RED
with a folded-in SLO strip, logs, Kubernetes, host / OS metrics) and light up on any ClickStack.
**Six more are opt-in** under `dashboards/advanced/` (collector health, ClickHouse operations,
ClickHouse query performance, storage / MergeTree, Keeper replication, latency histograms) — they
need telemetry that isn't collected by every deployment, so import them with `--advanced` once you
know that data is flowing. There's also an optional **alerts pack**.
Everything is portable: the importer resolves your source/connection IDs at install time.

- **Get started:** [`hyperdx/README.md`](hyperdx/README.md) — prerequisites, pre-flight check, install, and flags.
- **Decide what to import:** [`hyperdx/DASHBOARD-CATALOG.md`](hyperdx/DASHBOARD-CATALOG.md) — what each dashboard is for, what telemetry it needs, grouped by setup tier.
- **Go deep:** [`hyperdx/DASHBOARD-DEEP-DIVE.md`](hyperdx/DASHBOARD-DEEP-DIVE.md) — every tile, how to read it, what to do when it fires.

```bash
git clone https://github.com/Cameron-Bayer/AldoTel-Templates.git
cd AldoTel-Templates/hyperdx
# then follow hyperdx/README.md (preflight → import)
```

## 📊 Grafana section

Six high-level Grafana dashboards over the same ClickHouse data — **five import by default**, plus an
opt-in `advanced/latency-histograms` board — with a **provisioned alerting pack** (YAML **and**
Terraform) that notifies your on-call channel via a webhook.

- **Get started:** [`grafana/README.md`](grafana/README.md) — customer quick-start and import steps.
- **Alerts:** [`grafana/alerting/README.md`](grafana/alerting/README.md) — eight unified-alerting rules, channel setup, and tunable thresholds.

---

## The shared foundation

Both deliverables depend on the **standard ClickStack OTel schema** in ClickHouse
(`otel_logs`, `otel_traces`, `otel_metrics_{gauge,sum,histogram}`) — exactly what the
default ClickStack OpenTelemetry collector produces. Land your telemetry in that schema
and the templates just work.

**Per-install differences:**
- **HyperDX** resolves your source/connection IDs automatically at import time — nothing to edit.
- **Grafana** picks your ClickHouse connection via a datasource variable on import, and assumes
  the `default` database. If your ClickStack uses a different database name, set the dashboard's
  **`database`** variable (or find/replace `default.otel_` → `<your_db>.otel_` in the JSON) —
  see [`grafana/README.md`](grafana/README.md).

See [`CHANGELOG.md`](CHANGELOG.md) for release history.
