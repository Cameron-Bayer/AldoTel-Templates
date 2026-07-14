# AldoTel Observability Dashboard Templates

Download-and-go observability dashboards for teams running **Open Source ClickStack**
(HyperDX + ClickHouse + OpenTelemetry). This repo ships **two complementary deliverables**
that read the *same* ClickHouse / OTel data — no extra collectors or schema changes:

| Deliverable | Use it for | Start here |
|-------------|-----------|------------|
| 🔎 **[HyperDX](hyperdx/)** | Deep, interactive **investigation** — per-domain dashboards, drill-downs, log/trace search, data-science tiles | [`hyperdx/README.md`](hyperdx/README.md) |
| 📊 **[Grafana](grafana/)** | At-a-glance **health**, executive views, and **alerting** (Microsoft Teams) | [`grafana/README.md`](grafana/README.md) |

> **Which do I use?** Use **HyperDX to investigate** (rich, click-through, log/trace correlation)
> and **Grafana to watch & page** (high-level golden-signal boards + provisioned alert rules).
> They read the same data, so you can run either or both.

---

## Repository layout

```
.
├── hyperdx/                    🔎 HyperDX deliverable
│   ├── README.md                 Section guide: install, pre-flight, alerts
│   ├── OVERVIEW.md               Manager-facing overview (screenshots + diagrams)
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
│   ├── OVERVIEW.md               Manager-facing overview (screenshots + diagrams)
│   ├── dashboards/               4 dashboard templates (*.json)
│   ├── alerting/                 Provisioned alert rules (YAML) + Terraform equivalent
│   ├── provisioning/             Dev-harness datasource + dashboard providers
│   ├── screenshots/              Live-preview images used in OVERVIEW.md
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
- **Present it:** [`hyperdx/OVERVIEW.md`](hyperdx/OVERVIEW.md) — manager-facing summary with screenshots and diagrams.

```bash
git clone https://github.com/Cameron-Bayer/AldoTel-HyperDX-Templates.git
cd AldoTel-HyperDX-Templates/hyperdx
# then follow hyperdx/README.md (preflight → import)
```

## 📊 Grafana section

Four high-level Grafana dashboards over the same ClickHouse data, plus a **provisioned
alerting pack** (YAML **and** Terraform) that notifies Microsoft Teams.

- **Get started:** [`grafana/README.md`](grafana/README.md) — customer quick-start, import steps, and a local preview harness.
- **Alerts:** [`grafana/alerting/README.md`](grafana/alerting/README.md) — six unified-alerting rules, Teams setup, and tunable thresholds.
- **Present it:** [`grafana/OVERVIEW.md`](grafana/OVERVIEW.md) — manager-facing summary with screenshots and diagrams.

---

## The shared foundation

Both deliverables depend on the **standard ClickStack OTel schema** in ClickHouse
(`otel_logs`, `otel_traces`, `otel_metrics_{gauge,sum,histogram}`) — exactly what the
default ClickStack OpenTelemetry collector produces. Land your telemetry in that schema
and the templates just work; the only per-install difference (source/connection IDs,
database name) is resolved at import time.

See [`CHANGELOG.md`](CHANGELOG.md) for release history.
