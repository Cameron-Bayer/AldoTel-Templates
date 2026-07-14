# AldoTel ClickStack Dashboards — Customer Catalog & Field Guide

A plain-language guide to every dashboard in this pack: **what it's for, why you'd use it,
exactly what telemetry it needs, and how to read it.** Use this to decide *which* dashboards to
import for *your* setup — so nothing lands empty and nothing confuses your team.

> **TL;DR** — There are **10 dashboards** across four telemetry domains (your apps, your Kubernetes
> cluster, the OpenTelemetry Collector, and ClickHouse itself). They are **not** all-or-nothing:
> each one lights up only when the matching data pipeline is configured. This guide tells you which
> ones work with **zero setup**, which need a **collector receiver**, and which need your **apps
> instrumented** — so you can import exactly the ones that will show data today.

---

## How to use this catalog

1. **Run the pre-flight check first.** `./preflight.ps1` (Windows) or `./preflight.sh` (macOS/Linux)
   queries your live install and rates each dashboard **OK / DEGRADED / FAIL**, then prints an
   `--only` command listing the ones that are safe to import today. This catalog explains the
   *why* behind those ratings. If a metric comes back MISS, run `./list-metrics.ps1` /
   `./list-metrics.sh` to check whether it's genuinely absent or just named differently by your
   collector (it prints the closest real names).
2. **Find your setup tier** in the table below to see what will work out-of-the-box.
3. **Read the per-dashboard section** for the ones you care about — purpose, value, and gotchas.
4. **Import** with `./import.ps1` (or `-Only <files>` to import a subset).

Every dashboard also has a deep per-tile reference in [`docs/<name>.md`](docs/) with a live
screenshot. This catalog is the *"which and why"*; those docs are the *"every tile explained."*

---

## The four telemetry domains

A "Kubernetes cluster running on ClickHouse" is really **four independent telemetry pipelines**.
Each dashboard reads from one (or, for the Executive Overview, all) of them:

| Domain | What produces the data | Dashboards |
|--------|------------------------|------------|
| **Your applications** | Your services emit OTLP **traces** and **logs** | `services-red`, `slo-errorbudget`, `logs-overview` |
| **Kubernetes infrastructure** | Collector `kubeletstats` + `k8s_cluster` receivers | `k8s-infrastructure` |
| **The OTel Collector itself** | Collector self-telemetry (`:8888`) scraped back in | `collector-health` |
| **ClickHouse (the database)** | `system.*` tables (Raw SQL) and/or scraped CH metrics | `clickhouse-health`, `clickhouse-queryperf`, `ch-storage`, `ch-keeper` |
| **Everything (roll-up)** | All of the above; degrades gracefully | `exec-overview` |

---

## Setup tiers — what works with how much effort

Dashboards are grouped by **how much configuration they need before they show data.** Start at the
top; each tier down needs one more pipeline wired up.

### 🟢 Tier 1 — Works on *any* ClickHouse, zero extra setup
Reads ClickHouse's own `system.*` tables directly over your existing HyperDX ClickHouse connection.
No metrics pipeline, no collector receivers, no app instrumentation. If HyperDX is running, these
work.

- **`ch-storage`** — disk, compression, merges, parts. *(No required metrics at all.)*

> Requirement: the HyperDX ClickHouse connection user can `SELECT` from `system.parts` /
> `system.part_log` (on by default).

### 🟡 Tier 2 — Needs ClickHouse server metrics scraped into OTel
Add the `clickhouse` (or Prometheus) receiver so ClickHouse's `ProfileEvents`/`Metrics` land as OTel
metrics. Then these light up.

- **`clickhouse-health`** — cluster-wide query/insert/merge/replication health.
- **`clickhouse-queryperf`** — *most* tiles are Raw SQL on `system.query_log` (Tier-1-style), but the
  three summary number tiles need `ClickHouseMetrics_{Query,MemoryTracking}`.
- **`ch-keeper`** — Keeper/ZooKeeper coordination metrics (and replication tables, which only fill on
  a **replicated/clustered** ClickHouse — empty on single-node by design).

### 🟠 Tier 3 — Needs specific collector receivers
Your OTel Collector must be deployed with the right receivers (and, for Kubernetes, RBAC).

- **`k8s-infrastructure`** — needs `kubeletstats` **and** `k8s_cluster` receivers (`k8s.*` metrics).
- **`collector-health`** — needs the collector's **own** `:8888` self-telemetry scraped back into OTel.

### 🔵 Tier 4 — Needs your applications instrumented
Your services must send OpenTelemetry **traces** / **logs**. This is the core ClickStack use case,
but a bare cluster with un-instrumented apps won't populate these.

- **`services-red`** — needs OTLP **traces** (server spans).
- **`slo-errorbudget`** — needs OTLP **traces** with `StatusCode`.
- **`logs-overview`** — needs application/container **logs** (filelog or OTLP).

### ⭐ Always works (degrades gracefully)
- **`exec-overview`** — a cross-domain landing page. Every tile shows what it can and quietly hides
  what isn't flowing yet, so it's safe to import first and watch fill in as you add pipelines.

> **The easy path:** if you deploy the **standard ClickStack distribution** (its Helm chart / the
> reference OTel collector config), it wires up the k8s, collector-self, and ClickHouse receivers for
> you — so **all 10 light up**. The tiers above matter mainly for hand-rolled or partial setups.

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

### ⭐ Executive Overview — `exec-overview.json`
*Source: trace + log + metric · Tier: always works (degrades gracefully)*

**What it's for.** A single landing page that rolls up the health of everything — apps, ClickHouse,
Kubernetes, and the collector — into a few headline numbers and drill-down tables.

**Why use it / who it's for.** This is the **first dashboard to import** and the one to put on the
team's shared screen. Executives and on-call leads get a 5-second read on "is anything on fire?";
engineers use the click-through tables to jump straight into the offending Traces or Logs. Because
every tile degrades gracefully, it's also the safest way to *see your telemetry coverage grow* as
you wire up more pipelines.

**What you need.** Nothing hard-required — it shows whatever is flowing. Fills in fully once you have
traces, logs, ClickHouse metrics, and k8s metrics.

**What you'll see.**
- **Service health — at a glance:** span error rate %, trace volume, span latency p95, log error rate %.
- **Platform — at a glance:** ClickHouse failed queries, ClickHouse running queries, K8s nodes ready,
  collector refused spans.
- **Top services:** *Services by error rate* → click a row to open **Traces**; *Services by log
  errors* → click a row to open **Logs**.
- **Traffic & ingest:** ingest throughput (spans accepted vs refused) and request rate & errors.

**How to read it.** Start top-left and scan right; anything red/non-zero in the "at a glance" rows is
your cue to click into the matching table below and drill down. Empty tiles = that signal isn't
flowing yet (see the setup tiers), not an error.

---

### 🔵 Services — RED (Rate / Errors / Duration) — `services-red.json`
*Source: trace · Tier 4 (needs app traces)*

**What it's for.** The classic **RED method** view of your services: how much traffic (Rate), how
many failures (Errors), and how slow (Duration/latency) — per service and per route.

**Why use it / who it's for.** The everyday dashboard for **service owners and SREs**. It answers
"which service is slow or erroring right now, and on which endpoint?" The slow-routes table links
straight into Traces so you go from symptom to root-cause exemplar in one click.

**What you need.** OTLP **traces** with server spans (`SpanKind:Server`). Error breakdown tiles also
use `StatusCode:Error`. *(HTTP-route tiles read `SpanAttributes['http.route']`; pure gRPC/messaging
services that don't set it show empty rows there while rate/error/latency still work.)*

**What you'll see.**
- **Rate & errors:** request rate by service; error rate %.
- **Latency & error breakdown:** p50/p95/p99 latency; errors by status message (pie).
- **Slow routes & distribution:** slowest routes by p95 (→ Traces); a **latency-anomaly** control
  chart; a server-latency **heatmap**.

**How to read it.** Watch the error-rate % and p95 lines for spikes; use *Slowest routes* to see
which endpoint is responsible, then click through to the actual traces. The anomaly tile (below)
flags spikes relative to each service's own recent baseline, so you don't need to eyeball a raw line.

---

### 🔵 Services — SLO / Error Budget — `slo-errorbudget.json`
*Source: trace · Tier 4 (needs app traces)*

**What it's for.** Turns raw success/failure counts into **SLO language**: availability (SLI), how
much **error budget** you've burned, and **multi-window burn-rate** alerting math.

**Why use it / who it's for.** For teams that run to **Service Level Objectives** — SREs, platform
teams, and anyone reporting reliability to the business. It reframes "0.06% errors" as "you're inside
your 99.9% budget" and shows *how fast* you're spending it, which is what actually predicts a breach.

**What you need.** OTLP **traces** with server spans and `StatusCode`. Burn-rate tiles read the traces
table directly via SQL.

**What you'll see.**
- **SLO — at a glance:** availability (SLI), error rate (1 − SLI), total server requests.
- **Availability & traffic:** availability over time vs a 99.9% target; good vs bad requests by service.
- **Burn rate:** multi-window burn-rate table (1h / 6h / 24h / 3d), a burn-rate trend line
  (**> 1 = spending budget faster than the SLO allows**), and errors by service (→ Traces).

**How to read it.** If availability is above target and burn-rate is < 1 across windows, you're
healthy. A **fast-burn** (short-window burn-rate ≫ 1) means a page-worthy incident; a slow steady
burn > 1 means you'll breach the monthly budget if nothing changes. The bundled **SLO fast-burn
alert** watches exactly this.

---

### 🔵 Logs — Overview — `logs-overview.json`
*Source: log · Tier 4 (needs app/container logs)*

**What it's for.** Volume, severity mix, top errors, and — the standout feature — **newly appeared
error patterns**, plus a live error stream.

**Why use it / who it's for.** For **anyone triaging an incident or a deploy**. Beyond the usual
"errors are up" volume chart, its *new patterns* tile answers the far more useful question: *"what
started happening in the last 24h that wasn't happening before?"* — a cheap, deploy-aware anomaly
detector.

**What you need.** Application/container **logs** (filelog or OTLP) — any log volume. Error tiles match
`SeverityNumber >= 17` **or** `SeverityText` ERROR/FATAL, so they catch errors whether your pipeline
sets the numeric severity, the text one, or both (any casing).

**What you'll see.**
- **Volume & error rate:** log volume by severity; error/fatal rate by service.
- **Top errors & patterns:** top error messages (→ Logs); **new log patterns in the last 24h vs the
  prior 7 days**.
- **Live stream:** a live error stream you can watch during a rollout.

**How to read it.** During normal ops, watch the severity mix. After a deploy, go straight to *new
log patterns* — anything listed there is new noise (or a new bug) introduced recently. Click a top
error to open the full logs, pre-filtered.

---

### 🟠 Kubernetes — Infrastructure — `k8s-infrastructure.json`
*Source: metric · Tier 3 (needs kubeletstats + k8s_cluster receivers)*

**What it's for.** The health of the **cluster underneath your apps**: nodes, pods, deployments, and
namespaces — CPU, memory, restarts, availability, and filesystem pressure.

**Why use it / who it's for.** For **platform / infrastructure engineers and cluster admins**. When a
service is unhealthy, this tells you whether the cause is the *platform* (node out of memory, pods
crash-looping, deployment under-replicated) rather than the app code.

**What you need.** A collector with the **`kubeletstats`** and **`k8s_cluster`** receivers (plus the
RBAC to read them). Required metrics: `k8s.node.{cpu,memory}.usage`, `k8s.deployment.{available,
desired}`, `k8s.pod.{phase,memory.usage}`, `k8s.container.restarts`. Filesystem tiles are optional.

**What you'll see.**
- **Nodes:** CPU (cores) and memory usage; a node status/uptime table; nodes-ready count; filesystem usage %.
- **Pods:** deployment availability (ready/desired); pods by phase; a pod status & resources table;
  pod CPU and memory vs their limits (%).
- **Namespaces:** per-namespace CPU and memory; a namespace summary table.

**How to read it.** Top-down: nodes healthy? → deployments at desired replica count? → any pods stuck
in a bad phase or near their CPU/memory limits? The *vs limit %* tiles are your early warning for
OOMKills and throttling.

---

### 🟠 OTel Collector — Pipeline Health — `collector-health.json`
*Source: metric · Tier 3 (needs collector self-telemetry scraped)*

**What it's for.** Is your **telemetry pipeline itself** healthy? Accepted vs refused vs failed spans,
exporter queue depth, processor drops, scraper errors, and collector CPU/memory.

**Why use it / who it's for.** For whoever **owns the observability pipeline**. It's the meta-monitor:
if this dashboard shows refused/failed spans or a full exporter queue, then *every other dashboard's
data is suspect* because telemetry is being dropped before it lands. This is where you catch "why is
my data incomplete?"

**What you need.** The collector's own internal telemetry (Prometheus on the collector's `:8888`)
scraped back into OTel. Required: `otelcol_receiver_accepted_spans_total`,
`otelcol_exporter_{sent_spans_total, queue_size, queue_capacity}`.

**What you'll see.**
- **Pipeline — at a glance:** refused spans (should be 0), failed spans (should be 0), exporter queue
  size, exporter in-flight requests.
- **Traces pipeline:** accepted vs refused vs failed spans; exporter sent spans; queue size vs
  capacity; processor incoming vs outgoing (**a gap = dropped data**).
- **Logs & metrics pipeline:** accepted log records vs metric points; scraper scraped vs errored.
- **Collector resources:** memory (RSS/heap); CPU (rate).

**How to read it.** The two "should be 0" tiles are your headline health. If the exporter queue is
climbing toward capacity, or incoming > outgoing in the processor tile, the collector can't keep up
(back-pressure) and is dropping telemetry — scale it or investigate the export destination. The
bundled **collector-drops alert** watches refused spans.

---

### 🟡 ClickHouse — Cluster Health — `clickhouse-health.json`
*Source: metric · Tier 2 (needs ClickHouse metrics scraped)*

**What it's for.** The overall health of the **ClickHouse server** backing your stack: query/insert
throughput, failures, merges/mutations in progress, memory, and replication lag.

**Why use it / who it's for.** For **ClickHouse operators / DBAs and platform teams**. ClickHouse is
the engine under HyperDX (and often the customer's own analytics); this is the "is the database
healthy?" dashboard — throughput trending, failures rising, or replicas falling behind.

**What you need.** ClickHouse server metrics scraped into OTel (`clickhouse`/Prometheus receiver).
Required: `ClickHouseProfileEvents_{Query,FailedQuery,SelectQuery,InsertQuery}` (sum) and
`ClickHouseMetrics_{Query,MemoryTracking}` (gauge). Merge/mutation/replica tiles are optional.

**What you'll see.**
- **Cluster health — at a glance:** running queries; max replication lag (s); readonly replicas;
  memory tracking.
- **Query activity:** query rate (with week-over-week comparison); failed queries; inserted-rows rate;
  SELECT vs INSERT.
- **Merges & mutations:** merges in progress; mutations in progress.
- **I/O & cache:** page-cache reads (cache vs source bytes); async insert bytes.

**How to read it.** Watch failed queries and replication lag for anomalies; the week-over-week query
rate line tells you whether load is unusual. Rising readonly replicas or replication lag on a
clustered install is an early sign of coordination trouble (see `ch-keeper`).

---

### 🟡 ClickHouse — Query Performance & Errors — `clickhouse-queryperf.json`
*Source: metric + SQL · Tier 2 (SQL tiles need zero setup; summary tiles need CH metrics)*

**What it's for.** A deep look at **query behavior**: rate by kind, p95/p99 latency, peak memory per
query, exceptions, and the actual **slowest queries** and top error codes — read straight from
ClickHouse's own `system.query_log`.

**Why use it / who it's for.** For **DBAs and performance engineers** tuning ClickHouse. When queries
are slow or failing, this pinpoints *which* queries and *why* (duration, memory, exception codes),
using ClickHouse's own audit log rather than external metrics.

**What you need.** Most tiles are **Raw SQL** on `system.query_log` — they only need the HyperDX
ClickHouse user to `SELECT` from it (and `query_log` enabled, which is standard). The three summary
number tiles additionally need `ClickHouseMetrics_{Query,MemoryTracking}` scraped as metrics.

**What you'll see.**
- **Query performance — at a glance:** failed queries; running queries (now); memory tracking.
- **Query trends:** query rate by kind; **query duration — p95 / p99** (duration-formatted axis);
  **peak memory per query — p95 / max** (byte-formatted axis); query exceptions.
- **Slowest queries & errors:** slowest queries (last 6h) table; top ClickHouse error codes (last 24h).

**How to read it.** Spikes in the duration or exceptions lines point you at a time window; the
*slowest queries* table then names the specific SQL. Peak-memory-per-query rising toward your server
limit predicts OOM'd queries.

---

### 🟢 ClickHouse — Storage & MergeTree — `ch-storage.json`
*Source: SQL only · Tier 1 (works on any ClickHouse, zero setup)*

**What it's for.** The **storage layer**: disk usage, compression ratio, part counts, and the
MergeTree churn (inserts, merges, mutations) that governs ClickHouse's health over time.

**Why use it / who it's for.** For **DBAs and capacity planners** — and the easiest dashboard to
adopt because it needs **no metrics pipeline at all**. It answers "how much disk am I using, how well
is it compressing, and are parts/merges getting out of hand?" The **too-many-parts** watch table is
an early warning for the single most common ClickHouse operational failure.

**What you need.** Just `SELECT` on `system.parts` and `system.part_log` for the HyperDX ClickHouse
user (`part_log` is on by default). No receivers, no metrics, no instrumentation.

**What you'll see.**
- **Storage — at a glance:** disk used (active parts); compression ratio (uncompressed/compressed);
  active parts total; rows stored.
- **Throughput & merges:** part events / 5 min (inserts, merges, mutations); merge duration p95/max;
  bytes written (inserted vs merged); rows processed.
- **Tables & parts:** largest tables by disk; active parts per table (**too-many-parts watch**);
  recent merges (last 6h).

**How to read it.** Compression ratio tells you storage efficiency; a climbing *active parts per
table* (especially past a few thousand) means inserts are outpacing merges — throttle insert
frequency or investigate. The bundled **too-many-parts alert** watches this.

---

### 🟡 ClickHouse — Keeper & Replication — `ch-keeper.json`
*Source: metric + SQL · Tier 2 (Keeper metrics) / replication needs a cluster*

**What it's for.** The **coordination layer** of a replicated ClickHouse: Keeper/ZooKeeper sessions,
request throughput, commit latency, and the **replication status / queue** of your tables.

**Why use it / who it's for.** For operators of **replicated or clustered ClickHouse**. Keeper is the
consensus service that keeps replicas in sync; when replication stalls or lags, this is where you see
stuck queue tasks and unhealthy replicas.

**What you need.** Keeper tiles use `ClickHouseMetrics_ZooKeeper*/Keeper*` and
`ClickHouseProfileEvents_Keeper*` **if** scraped (all optional — nothing is hard-required). The
**replication tables** read `system.replicas` / `system.replication_queue` via SQL and **only populate
on a replicated/clustered install** — on single-node ClickHouse they are empty *by design*, and that
is expected, not a fault.

**What you'll see.**
- **Keeper — at a glance:** active sessions; watches; outstanding requests; alive connections.
- **Throughput & latency:** request rate by type; commits vs failed commits; packets received/sent;
  in-flight requests & watches; commit-wait & process time (µs); a Keeper/ZooKeeper errors table.
- **Replication:** replica status; replication queue (stuck tasks) — *replicated clusters only*.

**How to read it.** On a cluster, watch the replication queue for stuck tasks and any replica marked
unhealthy/readonly. On a single node, expect the throughput and replication sections to be quiet —
that's normal; the "at a glance" session/watch counts still confirm Keeper is alive.

---

## Which dashboards should *I* import?

Pick by role — but remember the **Executive Overview** is a safe first import for everyone.

| If you're a… | Start with |
|--------------|-----------|
| **Data scientist / analyst** (AldoTel core use case) | `exec-overview`, `services-red`, `logs-overview` — the app-signal dashboards you'll build analysis on |
| **Platform / Kubernetes admin** | `k8s-infrastructure`, `collector-health`, `exec-overview` |
| **SRE / reliability owner** | `slo-errorbudget`, `services-red`, `collector-health` |
| **ClickHouse operator / DBA** | `ch-storage` (zero-setup), `clickhouse-health`, `clickhouse-queryperf`, `ch-keeper` |
| **Just kicking the tires (any cluster)** | `ch-storage` + `exec-overview` — the two that show *something* with the least setup |

---

## "My dashboard is empty" — quick troubleshooting

Empty tiles almost always mean **the data isn't flowing yet**, not that the dashboard is broken.

1. **Run `preflight`** — it tells you exactly which required signal is missing per dashboard.
2. **Check the setup tier** above — do you have the receiver / instrumentation that dashboard needs?
3. **Check the time range** — the dashboard defaults to a recent window; widen it if your data is sparse.
4. **Check metric names** — if `preflight` says a required metric is missing but you *are* scraping it,
   your exporter may use a different name. Adjust `metricName` in the tile and `requirements.json`.
5. **`ch-keeper` replication empty?** — expected on single-node ClickHouse (see that section).
6. **Collector dropping data?** — check `collector-health`: refused/failed spans or a full exporter
   queue means telemetry is lost before it lands, which starves every other dashboard.

---

## Related docs

- **[DASHBOARD-DEEP-DIVE.md](DASHBOARD-DEEP-DIVE.md)** — tile-by-tile Q&A for every dashboard: what
  each visual shows, how to read it, and how to act on it.
- **[README.md](README.md)** — install steps, importer flags, filters, schema contract, customizing.
- **[requirements.json](requirements.json)** — the machine-readable source of truth behind `preflight`.
- **[docs/](docs/)** — per-dashboard, per-tile reference with screenshots.
- **[alerts/README.md](alerts/README.md)** — the optional alerts pack (error rate, SLO burn, collector
  drops, too-many-parts, replication lag), Teams by default.
