# ClickStack Dashboards — Customer Catalog & Field Guide

A plain-language guide to every dashboard in this pack: **what it's for, why you'd use it,
exactly what telemetry it needs, and how to read it.** Use this to decide *which* dashboards to
import for *your* setup — so nothing lands empty and nothing confuses your team.

> **TL;DR** — There are **8 dashboards** covering your telemetry domains (your apps, your hosts, your
> Kubernetes cluster, the OpenTelemetry Collector, and ClickHouse itself). The **7 default** dashboards
> live in `hyperdx/dashboards/`; the single **advanced** deep dive lives in
> `hyperdx/dashboards/advanced/`. `./import.ps1` recurses into `advanced/`, so it still imports all
> 8 unless you choose a subset. SLO lives as a compact strip inside **Traces**.

---

## How to use this catalog

1. **Run the pre-flight check first.** `./preflight.ps1` (Windows) or `./preflight.sh` (macOS/Linux)
   queries your live install and rates each dashboard **OK / DEGRADED / FAIL**, then prints an
   `--only` command listing the ones whose **OTel source data** is present today. This catalog
   explains the *why* behind those ratings. (Pre-flight checks telemetry flow only — the Raw-SQL
   tiles on **Observability Platform Health** also need `SELECT` on ClickHouse `system.*` tables.)
2. **Find your setup tier** in the table below to see what will work out-of-the-box.
3. **Read the per-dashboard section** for the ones you care about — purpose, value, and gotchas.
4. **Import** with `./import.ps1` (or `-Only <files>` to import a subset). The importer recurses into
   `hyperdx/dashboards/advanced/`, so a bare import includes the optional advanced deep dive too.

Every dashboard also has a deep per-tile reference in [`docs/<name>.md`](docs/) with a live
screenshot. This catalog is the *"which and why"*; those docs are the *"every tile explained."*
Imported display names are prefixed **`ClickStack ·`**; filenames and stable tags stay as listed.

---

## Dashboard locations

- **`hyperdx/dashboards/`** — the **7 default** dashboards every customer should import; they
  populate on a standard appliance deploy: `overview`, `infrastructure`, `kubernetes`,
  `metrics`, `traces`, `logs`, and `supportability`.
- **`hyperdx/dashboards/advanced/`** — **1 opt-in** dashboard (import with `--advanced`),
  `observability-platform-health`, which needs data a standard deploy doesn't ingest by default:
  the collector's own `:8888` self-telemetry, ClickHouse server metrics, and `SELECT` on ClickHouse
  `system.*` tables.

---

## The telemetry domains

A "Kubernetes cluster running on ClickHouse" is really several **independent telemetry pipelines**.
Each dashboard reads from one (or, for the roll-ups, all) of them:

| Domain | What produces the data | Dashboards |
|--------|------------------------|------------|
| **Your applications** | Your services emit OTLP **traces** and **logs** | `traces` (RED + SLO strip), `logs` |
| **Your hosts / OS** | Collector `hostmetrics` receiver (`system.*`) | `infrastructure`, `metrics` |
| **Kubernetes infrastructure** | Collector `kubeletstats` + `k8s_cluster` + `k8sobjects` receivers | `infrastructure`, `kubernetes`, `metrics` |
| **The OTel Collector itself** | Collector self-telemetry (`:8888`) scraped back in | `observability-platform-health` |
| **ClickHouse (the database)** | `system.*` tables (Raw SQL) and/or scraped CH metrics | `overview`, `observability-platform-health` |
| **Everything (roll-up)** | All of the above; degrades gracefully | `overview`, `supportability` |

---

## Setup tiers — what works with how much effort

Dashboards are grouped by **how much configuration they need before they show data.** Start at the
top; each tier down needs one more pipeline wired up.

### 🟢 Tier 1 — Works on *any* ClickHouse, zero extra setup
Reads ClickHouse's own `system.*` tables directly over your existing HyperDX ClickHouse connection.
No metrics pipeline, no collector receivers, no app instrumentation.

- **`observability-platform-health`** *(advanced — the ClickHouse storage/retention and query-performance
  tiles)* — the *Data retention & size by table*, *Query duration p95/p99*, and *Top errors* tiles read
  `system.parts` / `system.query_log` directly.

> Requirement: the HyperDX ClickHouse connection user can `SELECT` from `system.parts` /
> `system.query_log` (on by default).

### 🟡 Tier 2 — Needs ClickHouse server metrics scraped into OTel
Add the `clickhouse` (or Prometheus) receiver so ClickHouse's `ProfileEvents`/`Metrics` land as OTel
metrics. Then these light up.

- **`observability-platform-health`** *(advanced — the ClickHouse availability tiles: running queries,
  failed queries, disk free %, tracked memory)*.

### 🟠 Tier 3 — Needs specific collector receivers
Your OTel Collector must be deployed with the right receivers (and, for Kubernetes, RBAC).

- **`infrastructure`** — needs the **`hostmetrics`** receiver (`system.*` CPU/memory/load/swap/disk/network)
  **and** the `kubeletstats` + `k8s_cluster` receivers (`k8s.node.*` for node/cluster health and filesystem).
- **`kubernetes`** — needs `kubeletstats` **and** `k8s_cluster` receivers (`k8s.*` metrics); the
  cluster-events tiles also need the `k8sobjects` receiver.
- **`metrics`** — the unified infrastructure/Kubernetes experience; needs the combined
  `hostmetrics`, `kubeletstats`, and `k8s_cluster` signals, with `k8sobjects` for events.
- **`observability-platform-health`** *(advanced — the ingestion & pipeline sections)* — needs the
  collector's **own** `:8888` self-telemetry scraped back into OTel.

### 🔵 Tier 4 — Needs your applications instrumented
Your services must send OpenTelemetry **traces** / **logs**. This is the core ClickStack use case,
but a bare cluster with un-instrumented apps won't populate these.

- **`traces`** — needs OTLP **traces** with server spans (`SpanKind = 'Server'`) and `StatusCode`;
  includes the compact SLO strip.
- **`logs`** — needs application/container **logs** (filelog or OTLP).

### ⭐ Always works (degrades gracefully)
- **`overview`** — the primary cross-domain landing page. Signal tiles fill as telemetry arrives;
  its ClickHouse workload section reads `system.*` tables directly through the existing connection.
- **`supportability`** — an incident-triage roll-up over logs, traces, and k8s events; each section
  degrades gracefully to whatever signal is present.

> **The easy path:** if you deploy the **standard ClickStack distribution** (its Helm chart / the
> reference OTel collector config), it wires up the host, k8s, collector-self, and ClickHouse receivers
> for you — so all **8 dashboards** can light up. The tiers above matter mainly for hand-rolled or
> partial setups.

---

## Baseline requirements (all dashboards)

Regardless of tier, every dashboard assumes:

1. **HyperDX ≥ 2.27** (the v2 dashboard API).
2. The **three default sources** created in HyperDX: a **Logs** (`log`), **Traces** (`trace`), and
   **Metrics** (`metric`) source.
3. Data landed in the **standard ClickStack OTel schema** — `otel_logs`, `otel_traces`,
   `otel_metrics_{gauge,sum,histogram}`. This is exactly what the default ClickStack collector
   produces; it's the "contract" that keeps these templates portable.
4. A **Personal API Access Key** (HyperDX → *Team Settings → API Keys*) to run the importer.

> **Metric names can vary by collector config.** The names in this guide are the defaults verified
> against a live OSS ClickStack. If `preflight` reports a required metric missing, your exporter
> probably emits it under a different name — adjust `metricName` in the tile and in
> [`requirements.json`](requirements.json).

---

## Dashboard-by-dashboard

Each section: **what it's for**, **why use it / who it's for**, **what you need**, **what you'll
see**, and **how to read it**.

---

### ⭐ Environment Summary / Overview — `overview.json`
*Source: metric + trace + log · Tier: always works (degrades gracefully)*

**What it's for.** A single landing page that rolls up the health of everything — environment and
platform state, resource utilization, service health, ClickHouse workload/storage, impacted clusters,
and recent activity — into headline numbers, trends, and drill-down tables.

**Why use it / who it's for.** This is the **first dashboard to import** and the one to put on the
team's shared screen. On-call leads get a 5-second read on "is anything on fire?"; engineers use the
trends and event tables to jump into the offending domain. Because every tile degrades gracefully,
it's also the safest way to *see your telemetry coverage grow* as you wire up more pipelines.

**What you need.** Nothing hard-required — it shows whatever is flowing. Fills in fully once you have
k8s metrics, host metrics, server spans, and logs.

**What you'll see.**
- **Environment summary:** total clusters/nodes/running workloads, platform health score, an impacted
  node table with alert count and CPU/memory/storage/network consumption, and an inventory row that
  explicitly identifies fields the current telemetry does not emit (appliance version, physical-node
  count, and VM count).
- **Platform health:** overall and cluster health scores, active conditions, nodes-ready %, healthy
  vs. unhealthy node counts, pods not Running, and container restarts.
- **Resource utilization:** cluster CPU busy %, memory used %, and disk used %, each as a current
  number plus a short-term CPU and memory trend line.
- **Service health:** request volume, server error rate, p95 latency, log error rate, services ranked
  by trace/log errors, and a request-vs-error trend.
- **ClickHouse workload & storage:** running/failed queries, free disk, tracked memory, query/failure
  trends, inserts, query mix, merges, mutations, page-cache reads, and async inserts.
- **Recent activity:** Warning-event count, top event reasons, and a recent-events table (from
  `k8sobjects` events in `otel_logs`).
- **Pre-built views:** an in-dashboard map from the requested control-plane/data-plane experiences to
  the Infrastructure, Kubernetes, and Traces dashboards and their filters.

**How to read it.** Start top-left and scan right; anything red/non-zero in the health and status rows
is your cue to open the matching domain dashboard and drill down. Empty tiles = that signal isn't
flowing yet (see the setup tiers), not an error.

---

### 🟠 Infrastructure — `infrastructure.json`
*Source: metric · Tier 3 (needs hostmetrics + kubeletstats + k8s_cluster receivers)*

**What it's for.** The physical/virtual foundation under the appliance: cluster & node health, per-host
CPU / load / memory, storage (per-volume filesystem, inodes, IOPS, latency, throughput), network (throughput,
drops, errors), and capacity headroom.

**Why use it / who it's for.** For **infrastructure and platform engineers**. When Kubernetes shows
node pressure, this is the layer below it — is the box itself CPU-saturated, low on memory, paging,
maxing out a disk or NIC, or running out of filesystem? It answers "is this a host / storage / network
problem?" independent of the k8s scheduler view.

**What you need.** A collector with the **`hostmetrics`** receiver (`system.*` cpu, memory, load,
filesystem, paging, disk, network) **and** the **`kubeletstats`** + **`k8s_cluster`** receivers
(`k8s.node.condition_ready` and `k8s.node.uptime`). Node CPU, memory and disk come from `hostmetrics`,
not from `k8s.node.*` — see the note below.

> **Why node CPU/memory/disk come from `hostmetrics`.** The `kubeletstats` receiver as deployed on the
> appliance does not emit `k8s.node.cpu.usage`, `k8s.node.memory.usage`, or `k8s.node.filesystem.*`.
> These tiles therefore read `system.cpu.utilization`, `system.memory.utilization` and
> `system.filesystem.usage` instead. On a single-node-per-host appliance one host *is* one node, so the
> answer is the same — and the filesystem metric is strictly better, because it breaks down **per mounted
> volume** rather than collapsing every mount into one per-node number.

**What you'll see.**
- **Cluster health:** nodes-ready %, healthy vs. NotReady counts, and a per-node status / uptime table.
- **Node health (hosts):** host CPU busy %, 1-minute load average (vs core count), memory used %,
  inode used % per volume, and a per-host CPU/memory/load table.
- **Storage health:** filesystem used % per volume, free capacity per volume (GB), disk IOPS (read/write from
  `system.disk.operations`), disk latency (ms, from `operation_time ÷ operations`), and disk I/O bytes/sec.
- **Network health:** network I/O bytes/sec, packets dropped/sec, and interface errors/sec — per host and direction.
- **Capacity planning:** CPU headroom %, memory headroom %, free memory per host (GB), and disk
  free % per volume over time, top CPU/memory/storage/network consumers, a capacity-risk table with
  scale recommendations, and a storage growth/exhaustion estimate.

**How to read it.** Watch CPU busy % and load together — a load average well above the core count with
high CPU % means the host is saturated. Rising inode usage warns of write failures long before the
volume looks full on bytes. In Storage, a filesystem
creeping toward 100% or disk latency spiking flags an I/O problem; the capacity section is your runway
before saturation.

---

### 🟠 Kubernetes — `kubernetes.json`
*Source: metric + log (events) · Tier 3 (needs kubeletstats + k8s_cluster; k8sobjects for events)*

**What it's for.** The health of the **cluster orchestration layer**: nodes, namespaces, workloads
(deployments, pods, containers) — CPU, memory, restarts, availability — and utilization against
configured limits and requests.

**Why use it / who it's for.** For **platform / infrastructure engineers and cluster admins**. When a
service is unhealthy, this tells you whether the cause is the *platform* (node out of memory, pods
crash-looping, a deployment under-replicated, or a container pinned at its CPU/memory limit) rather
than the app code.

**What you need.** A collector with the **`kubeletstats`** and **`k8s_cluster`** receivers (plus RBAC).
Primary metrics: `system.cpu.utilization`, `system.memory.utilization`, `system.filesystem.usage`,
`k8s.deployment.{available,desired}`, `k8s.pod.{phase,cpu,memory}`, `k8s.container.restarts`, and
container limit/request utilization. Kubernetes events use the `k8sobjects` log stream.

**What you'll see.**
- **Cluster overview:** nodes-ready %, node CPU usage (cores vs allocatable), node memory used vs
  allocatable, node filesystem usage %, and a node status/uptime table.
- **Namespace overview:** per-namespace CPU and memory usage, and a namespace phase/CPU/memory table.
- **Workload health:** deployment availability (ready/desired), pods by phase (count), pods not Running,
  container restarts, a pod status & resources table, and top pods by restarts.
- **Cluster utilization (vs limits):** pod and container CPU/memory vs limit %, node memory saturation %,
  and a per-container utilization-vs-limit/request table.
- **Inventory and events:** namespace/pod/container/deployment counts, recent Warning events, top
  reasons, and impacted-resource counts.

**How to read it.** Top-down: nodes healthy? → deployments at desired replica count? → any pods stuck
in a bad phase or near their CPU/memory limits? The utilization-vs-limits section is your early warning
for OOMKills, throttling, and crash loops (containers without a limit set show 0%).

---

### 🟠 Metrics — `metrics.json`
*Source: metric + log (events) · Tier 3 (needs hostmetrics + Kubernetes receivers)*

**What it's for.** A single, comprehensive workspace for infrastructure health, compute and process
consumption, storage, networking, Kubernetes nodes/namespaces/workloads/containers, events,
cross-resource utilization, and capacity planning.

**Why use it / who it's for.** For platform, infrastructure, Kubernetes, and capacity engineers who
want real-time status and historical trends in one ordered page instead of switching between the
specialized Infrastructure and Kubernetes dashboards.

**What you need.** `hostmetrics`, `kubeletstats`, and `k8s_cluster`; `k8sobjects` adds warning and
critical event context. Process/runtime, swap, and direct node-capacity panels degrade when their
optional metrics are not emitted.

**What you'll see.**
- **Infrastructure overview:** health score, node readiness, current issue count, host health, utilization,
  and capacity risks.
- **Compute, storage, and networking:** CPU/load/processes, memory/swap, filesystems, IOPS,
  throughput, latency, packet loss, errors, health, and top consumers.
- **Kubernetes:** nodes, namespaces, deployments, pods, containers, limits/requests, restarts,
  saturation, inventory, and events.
- **Utilization and capacity:** cross-resource hotspots, headroom trends, storage forecasting,
  exhaustion risks, and scale recommendations.

**How to read it.** Start with the overview score and issue count, follow the unhealthy domain into
its section, then use the final utilization and capacity sections to distinguish an active hotspot
from a longer-term scaling risk.

---

### 🔵 Traces — `traces.json`
*Source: trace · Tier 4 (needs app traces)*

**What it's for.** A complete trace-based service experience: service health, **RED** request metrics,
server/client/RPC latency, slow and failed trace searches, dependency analysis, error propagation,
SLO compliance, and optional ClickHouse/collector platform health.

**Why use it / who it's for.** The everyday dashboard for **service owners and SREs**. It answers
"which service is slow or erroring right now, and on which endpoint?" The slow-routes table links
straight into Traces so you go from symptom to root-cause exemplar in one click, while the SLO section
shows whether the same failures are burning reliability budget.

**What you need.** OTLP **traces** with server spans (`SpanKind = 'Server'`) and `StatusCode`. *(HTTP-
route tiles read `SpanAttributes['http.route']`; pure gRPC/messaging services that don't set it show
empty rows there while rate/error/latency and the SLO strip still work.)*

**What you'll see.**
- **Service overview and RED:** request rate, request volume, error rate, average latency, success
  rate, health score, and top impacted services.
- **Latency analysis:** separate HTTP server, HTTP client, and RPC server latency tables; p50/p95/p99;
  service/operation trends; slow routes; anomaly detection; and the latency heatmap.
- **Slow routes & distribution:** slowest routes by p95 (→ Traces); a **latency-anomaly** chart (last
  24h vs an 8-day ±3σ baseline); a server-latency **heatmap**.
- **SLO & error budget:** availability (SLI), error-budget remaining, a multi-window burn-rate table,
  budget-consumption trend, availability over time against the 99.9% target, and per-service
  compliance/violation status.
- **Trace investigation:** distributed, slow, and failed request searches; native waterfall/request
  journey drill-down; trace sampling; critical-path candidates; dependency edges; impacted
  dependencies; exceptions; error anomalies; and root-cause candidate traces.
- **Platform performance:** ClickHouse workload/storage, collector queue utilization, and refused
  spans. Keeper latency is explicitly marked unavailable until Keeper metrics scraping is enabled.

**How to read it.** Watch the error-rate % and p95 lines for spikes; use *Slowest routes* to see which
endpoint is responsible, then click through to the actual traces. The anomaly tile flags spikes
relative to each service's own recent baseline. In the SLO strip, burn rate > 1 means you are spending
budget faster than the objective allows; a short-window fast burn is page-worthy.

---

### 🔵 Log Overview, Search & Live Streaming — `logs.json`
*Source: log · Tier 4 (needs app/container logs)*

**What it's for.** A three-part log workflow: overview, full-text search/exploration, and live
streaming, with service/resource/cluster/host/namespace/pod/severity filters.

**Why use it / who it's for.** For **anyone triaging an incident or a deploy**. Beyond the usual
"errors are up" volume chart, its normalized-signature and per-service tiles answer *which* component
is generating error noise and *what* the recurring messages are — then link straight into the raw logs.

**What you need.** Application/container **logs** (filelog or OTLP) — any log volume. Error tiles match
`SeverityNumber >= 17` and lowercase severity text for error/fatal records, so they catch both numeric
and textual severity.

**What you'll see.**
- **Volume & error rate:** log volume by severity (stacked bar); error/fatal log count over time, by service.
- **Top errors & patterns:** top error signatures (normalized, → Logs); errors & fatals by service in
  the last 24h (→ Logs).
- **Live stream:** a live error stream (→ full log detail); top Kubernetes error sources by
  namespace/pod (→ Logs); an unfiltered live stream; log error rate %; total logs; logs/sec;
  error/fatal logs and rate; fatal count; and error/fatal share.
- **Search & patterns:** a full log search workspace, normalized signatures, and patterns first seen
  in the last 24 hours. Native HyperDX provides saved searches, bookmarks/favorites, exports, and
  log/trace correlation.

**How to read it.** During normal ops, watch the severity mix. During/after a deploy, use *errors &
fatals by service* and *top error signatures* to see which service regressed and what the recurring
message is, then click a row to open the matching logs. *(The previous "new log patterns" regex tile
was replaced — see the note in the memory-limit troubleshooting below.)*

---

### ⭐ Active Alerts & Guided Troubleshooting — `supportability.json`
*Source: log + trace + metric · Tier: always works (degrades gracefully)*

**What it's for.** An **active-condition and incident-triage** roll-up: threshold status across
traces/logs/CPU/memory/filesystems/pods, failure tracking, guided ALM/ALRS/resource-provider/
Kubernetes/network/storage workflows, and a recurring-signature known-issues view.

**Why use it / who it's for.** For **on-call engineers and support**. It's the "something's wrong —
where do I start?" board. There is no separate alert-state store on the appliance, so the alert tiles
**recompute the conditions live** (error rates, unready pods, restarts) as a proxy for an alert console.

**What you need.** Whatever you have flowing — logs, traces, and Kubernetes metrics + events. It
degrades gracefully: each section shows what its signal supports.

**What you'll see.**
- **Alert conditions (recomputed live):** the original selected-range server/log/pod/restart tiles,
  plus a global fixed-window table covering server/log errors, pods, CPU, memory, and filesystems.
- **Failure tracking:** top pods by restarts, Warning-event count, and top event reasons.
- **Troubleshooting:** top error signatures (→ Logs), errors & fatals by service (→ Logs), top
  Kubernetes error sources (→ Logs), and a live error stream (→ full detail).
- **Guided workflows:** domain-specific investigation order plus a live, normalized known-issues table.

**How to read it.** Scan the alert-condition row first — any non-zero/red value points you at the
failure-tracking and troubleshooting sections below, which name the specific pods, event reasons, and
error messages to chase. Click a troubleshooting row to open the underlying logs.

---

### 🟡 Observability Platform Health — `advanced/observability-platform-health.json`
*Advanced · Source: metric + SQL · Tier 1–3 (collector self-telemetry + ClickHouse metrics + `system.*` SQL)*

**What it's for.** The health of the **observability stack itself** — the consolidation of the old
collector-health and ClickHouse deep-dive boards into one. Telemetry ingestion, pipeline back-pressure,
ClickHouse storage/availability, and the dashboards' own query performance.

**Why use it / who it's for.** For whoever **owns the observability pipeline** and for **ClickHouse
operators**. It's the meta-monitor: if this board shows refused/failed telemetry, a full exporter
queue, low ClickHouse disk, or failing queries, then *every other dashboard's data is suspect* because
telemetry is being dropped or the store is unhealthy.

**What you need.** Three optional sources, each lighting up its own section:
- Collector `:8888` self-telemetry scraped into OTel (ingestion + pipeline sections).
- ClickHouse server metrics scraped into OTel (availability tiles).
- `SELECT` on `system.query_log`, `system.parts`, `system.merges`, and `system.mutations` (workload,
  retention, merge/mutation, cache/insert, and query-performance tiles).

**What you'll see.**
- **Telemetry ingestion:** refused spans/logs/metric points (should be 0); accepted vs refused vs
  failed spans, logs, and metric points per interval.
- **Pipeline health:** exporter queue utilization %, queue size vs capacity, exporter sent spans, and
  collector CPU / memory (RSS / heap).
- **ClickHouse storage & availability:** running queries, failed queries, disk free %, current tracked
  memory, queries per interval, data retention & size by table, select-vs-insert mix, inserted rows,
  active merges, pending mutations, merge detail, page-cache reads, and async-insert bytes.
- **Dashboard query performance:** query duration p95/p99, failed queries, and top errors from `query_log`.

**How to read it.** The "should be 0" ingestion tiles are your headline health. If exporter queue
utilization climbs toward 100%, the collector can't keep up (back-pressure) and is dropping telemetry.
Watch ClickHouse disk free % and failed queries; the query-performance section shows whether the
dashboards themselves are straining the store.

---

## Which dashboards should *I* import?

Pick by role — but remember the **7 default dashboards** are the safe first import for everyone.

| If you're a… | Start with |
|--------------|-----------|
| **Data scientist / analyst** | `overview`, `traces`, `logs` — the app-signal dashboards you'll build analysis on |
| **Platform / Kubernetes admin** | `metrics`, `infrastructure`, `kubernetes`, `overview`, and `observability-platform-health` |
| **SRE / reliability owner** | `traces` (RED + SLO strip), `logs`, `supportability`, `overview` |
| **On-call / support** | `supportability` and `overview` first, then the domain board the alert points at |
| **ClickHouse / pipeline operator** | `observability-platform-health` (advanced) |
| **Just kicking the tires (any cluster)** | the 7 defaults — they show what is flowing today and degrade gracefully as you add data |

---

## "My dashboard is empty" — quick troubleshooting

Empty tiles almost always mean **the data isn't flowing yet**, not that the dashboard is broken.

1. **Run `preflight`** — it tells you exactly which required signal is missing per dashboard.
2. **Check the setup tier** above — do you have the receiver / instrumentation that dashboard needs?
3. **Check the time range** — the dashboard defaults to a recent window; widen it if your data is sparse.
4. **Check metric names** — if `preflight` says a required metric is missing but you *are* scraping it,
   your exporter may use a different name. Adjust `metricName` in the tile and `requirements.json`.
5. **`observability-platform-health` ingestion/pipeline empty?** — you haven't scraped the collector's
   `:8888` self-telemetry yet; the ClickHouse availability tiles similarly need CH metrics scraped.
6. **`observability-platform-health` retention/query-perf empty?** — those are Raw SQL tiles that read
   `system.parts` / `system.query_log`. Verify the HyperDX ClickHouse user can `SELECT` from them
   (preflight only checks OTel telemetry, not this access).
7. **A ClickHouse memory-limit error on a Logs/Supportability tile?** — the heavy "new log patterns"
   regex tile was **replaced** with *Errors & fatals by service (last 24h)* precisely to avoid the
   server-wide `OvercommitTracker` limit on memory-constrained instances. If you still hit it, narrow
   the dashboard time range.

---

## Related docs

- **[DASHBOARD-DEEP-DIVE.md](DASHBOARD-DEEP-DIVE.md)** — tile-by-tile Q&A for every dashboard: what
  each visual shows, how to read it, and how to act on it.
- **[README.md](README.md)** — install steps, importer flags, filters, schema contract, customizing.
- **[requirements.json](requirements.json)** — the machine-readable source of truth behind `preflight`.
- **[docs/](docs/)** — per-dashboard, per-tile reference.
- **[alerts/README.md](alerts/README.md)** — the optional alerts pack (error rate, SLO burn, collector
  drops, ClickHouse disk low), a generic webhook by default.
