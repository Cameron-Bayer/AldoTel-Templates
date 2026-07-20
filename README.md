# AldoTel Observability Dashboard Templates

Download-and-go observability dashboards for teams running **Open Source ClickStack**
(HyperDX + ClickHouse + OpenTelemetry). This repo ships **two complementary deliverables**
that read the *same* ClickHouse / OTel data — no extra collectors or schema changes:

| Deliverable | Use it for | Start here |
|-------------|-----------|------------|
| 🔎 **[HyperDX](hyperdx/)** | Deep, interactive **investigation** — per-domain dashboards, drill-downs, log/trace search, data-science tiles | [`hyperdx/README.md`](hyperdx/README.md) |
| 📊 **[Grafana](grafana/)** | At-a-glance **health**, executive views, and **alerting** (generic webhook) | [`grafana/README.md`](grafana/README.md) |

> **Which do I use?** Use **HyperDX to investigate** (rich, click-through, log/trace correlation)
> and **Grafana to watch & page** (high-level golden-signal boards + provisioned alert rules).
> They read the same data, so you can run either or both.

> **"AldoTel" vs "ClickStack":** *AldoTel* is the author/brand of these templates; *ClickStack*
> is the open-source observability platform (HyperDX + ClickHouse + OpenTelemetry) they run on.
> You don't need anything called "AldoTel" installed — any ClickStack / HyperDX deployment works.

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
│   ├── dashboards/               10 dashboard templates (*.json)
│   ├── alerts/                   Importable alert definitions + README
│   ├── docs/                     Auto-generated per-dashboard reference + images
│   ├── gen-docs.js               Regenerates docs/ from the templates
│   ├── import.ps1 / import.sh                Dashboard importer (upsert, idempotent)
│   ├── import-alerts.ps1 / import-alerts.sh  Alerts importer
│   ├── preflight.ps1 / preflight.sh          Compatibility check before import
│   └── requirements.json         Machine-readable support matrix (drives preflight)
│
├── grafana/                    📊 Grafana deliverable
│   ├── README.md                 Section guide: import + local preview harness
│   ├── dashboards/               4 dashboard templates (*.json)
│   ├── alerting/                 Provisioned alert rules (YAML) + Terraform equivalent
│   ├── provisioning/             Dev-harness datasource + dashboard providers
│   ├── screenshots/              Live-preview images embedded in README.md
│   ├── gen-dashboards.js         Generates the dashboard JSON
│   ├── validate.js               Validates panel SQL against live ClickHouse
│   └── docker-compose.yml        Throwaway Grafana for authoring/preview
│
├── CHANGELOG.md · VERSION
└── README.md                   ← you are here
```

---

## 🔎 HyperDX section

Ten per-domain HyperDX dashboards (services RED, logs, Kubernetes, SLO/error-budget,
collector health, and the ClickHouse fleet) plus an optional **alerts pack**. Everything
is portable: the importer resolves your source/connection IDs at install time.

- **Get started:** [`hyperdx/README.md`](hyperdx/README.md) — prerequisites, pre-flight check, install, and flags.
- **Decide what to import:** [`hyperdx/DASHBOARD-CATALOG.md`](hyperdx/DASHBOARD-CATALOG.md) — what each dashboard is for, what telemetry it needs, grouped by setup tier.
- **Go deep:** [`hyperdx/DASHBOARD-DEEP-DIVE.md`](hyperdx/DASHBOARD-DEEP-DIVE.md) — every tile, how to read it, what to do when it fires.

```bash
git clone https://github.com/Cameron-Bayer/AldoTel-HyperDX-Templates.git
cd AldoTel-HyperDX-Templates/hyperdx
# then follow hyperdx/README.md (preflight → import)
```

## 📊 Grafana section

Four high-level Grafana dashboards over the same ClickHouse data, plus a **provisioned
alerting pack** (YAML **and** Terraform) that notifies your on-call channel via a webhook.

- **Get started:** [`grafana/README.md`](grafana/README.md) — customer quick-start, import steps, and a local preview harness.
- **Alerts:** [`grafana/alerting/README.md`](grafana/alerting/README.md) — six unified-alerting rules, channel setup, and tunable thresholds.

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
