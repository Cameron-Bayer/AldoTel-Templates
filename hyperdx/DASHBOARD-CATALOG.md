# ClickStack Dashboards — Customer Catalog & Field Guide

A plain-language guide to every dashboard in this pack: **what it's for, why you'd use it,
exactly what telemetry it needs, and how to read it.** Use this to decide *which* dashboards to
import for *your* setup — so nothing lands empty and nothing confuses your team.

> **TL;DR** — There are **11 dashboards** across your telemetry domains (your apps, your hosts, your
> Kubernetes cluster, the OpenTelemetry Collector, and ClickHouse itself). The **8 default** dashboards
> live in `hyperdx/dashboards/`; the **3 advanced ClickHouse deep dives** live in
> `hyperdx/dashboards/advanced/`. `./import.ps1` recurses into `advanced/`, so it still imports all
> 11 unless you choose a subset. SLO now lives as a compact strip inside **Services — RED**.

---

## How to use this catalog

1. **Run the pre-flight check first.** `./preflight.ps1` (Windows) or `./preflight.sh` (macOS/Linux)
   queries your live install and rates each dashboard **OK / DEGRADED / FAIL**, then prints an
   `--only` command listing the ones whose **OTel source data** is present today. This catalog
   explains the *why* behind those ratings. (Pre-flight checks telemetry flow only — the Raw-SQL
   dashboards also need `SELECT` on ClickHouse `system.*` tables, noted per dashboard below.)
2. **Find your setup tier** in the table below to see what will work out-of-the-box.
3. **Read the per-dashboard section** for the ones you care about — purpose, value, and gotchas.
4. **Import** with `./import.ps1` (or `-Only <files>` to import a subset). The importer recurses into
   `hyperdx/dashboards/advanced/`, so a bare import includes the optional advanced deep dives too.

Every dashboard also has a deep per-tile reference in [`docs/<name>.md`](docs/) with a live
screenshot. This catalog is the *"which and why"*; those docs are the *"every tile explained."*
Imported display names are prefixed **`ClickStack ·`**; filenames and stable tags stay as listed.

---

## Dashboard locations

- **`hyperdx/dashboards/`** — the **5 default** dashboards every customer should import; they
  populate on a standard appliance deploy: `executive-overview`, `services-red`, `logs-overview`,
  `kubernetes-infrastructure`, and `host-os`.
- **`hyperdx/dashboards/advanced/`** — **6 opt-in** dashboards (import with `--advanced`), each
  needing an optional data source a standard deploy doesn't ingest by default: `collector-health`
  (collector `:8888`), `clickhouse-health` (ClickHouse `:9363` metrics), `metrics-histograms`
  (app OTLP histograms), and the ClickHouse deep dives `clickhouse-queryperf`,
  `clickhouse-storage-mergetree`, and `clickhouse-keeper-replication`.

---

## The telemetry domains

A "Kubernetes cluster running on ClickHouse" is really several **independent telemetry pipelines**.
Each dashboard reads from one (or, for the Executive Overview, all) of them:

| Domain | What produces the data | Dashboards |
|--------|------------------------|------------|
| **Your applications** | Your services emit OTLP **traces**, **logs**, and **histogram metrics** | `services-red` (RED + SLO strip), `logs-overview`, `metrics-histograms` |
| **Your hosts / OS** | Collector `hostmetrics` receiver (`system.*`) | `host-os` |
| **Kubernetes infrastructure** | Collector `kubeletstats` + `k8s_cluster` + `k8sobjects` receivers | `kubernetes-infrastructure` |
| **The OTel Collector itself** | Collector self-telemetry (`:8888`) scraped back in | `collector-health` |
| **ClickHouse (the database)** | `system.*` tables (Raw SQL) and/or scraped CH metrics | `clickhouse-health`; advanced: `clickhouse-queryperf`, `clickhouse-storage-mergetree`, `clickhouse-keeper-replication` |
| **Everything (roll-up)** | All of the above; degrades gracefully | `executive-overview` |

---

## Setup tiers — what works with how much effort

Dashboards are grouped by **how much configuration they need before they show data.** Start at the
top; each tier down needs one more pipeline wired up.

### 🟢 Tier 1 — Works on *any* ClickHouse, zero extra setup
Reads ClickHouse's own `system.*` tables directly over your existing HyperDX ClickHouse connection.
No metrics pipeline, no collector receivers, no app instrumentation. If HyperDX is running, these
work.

- **`clickhouse-storage-mergetree`** *(advanced)* — disk, compression, merges, parts. *(No required metrics at all.)*

> Requirement: the HyperDX ClickHouse connection user can `SELECT` from `system.parts` /
> `system.part_log` (on by default).

### 🟡 Tier 2 — Needs ClickHouse server metrics scraped into OTel
Add the `clickhouse` (or Prometheus) receiver so ClickHouse's `ProfileEvents`/`Metrics` land as OTel
metrics. Then these light up.

- **`clickhouse-health`** *(advanced)* — ClickHouse operations: disk free %, active merges, pending mutations,
  running queries, and memory tracking.
- **`clickhouse-queryperf`** *(advanced)* — *most* tiles are Raw SQL on `system.query_log`
  (Tier-1-style), but the summary number tiles need `ClickHouseMetrics_{Query,MemoryTracking}`.
- **`clickhouse-keeper-replication`** *(advanced)* — Keeper/ZooKeeper coordination metrics (and
  replication tables, which only fill on a **replicated/clustered** ClickHouse — empty on single-node
  by design).

### 🟠 Tier 3 — Needs specific collector receivers
Your OTel Collector must be deployed with the right receivers (and, for Kubernetes, RBAC).

- **`kubernetes-infrastructure`** — needs `kubeletstats` **and** `k8s_cluster` receivers (`k8s.*` metrics); the cluster-events tiles also need the `k8sobjects` receiver.
- **`host-os`** — needs the **`hostmetrics`** receiver (`system.*` CPU/memory/load/disk/network).
- **`collector-health`** *(advanced)* — needs the collector's **own** `:8888` self-telemetry scraped back into OTel.

### 🔵 Tier 4 — Needs your applications instrumented
Your services must send OpenTelemetry **traces** / **logs**. This is the core ClickStack use case,
but a bare cluster with un-instrumented apps won't populate these.

- **`services-red`** — needs OTLP **traces** with server spans (`SpanKind = 'Server'`) and
  `StatusCode`; includes the compact SLO strip.
- **`logs-overview`** — needs application/container **logs** (filelog or OTLP).
- **`metrics-histograms`** *(advanced)* — needs OTLP **histogram** metrics (`http.*.duration` / `rpc.*.duration`).

### ⭐ Always works (degrades gracefully)
- **`executive-overview`** — a cross-domain landing page. Every tile shows what it can and quietly hides
  what isn't flowing yet, so it's safe to import first and watch fill in as you add pipelines.

> **The easy path:** if you deploy the **standard ClickStack distribution** (its Helm chart / the
> reference OTel collector config), it wires up the k8s, collector-self, and ClickHouse receivers for
> you — so all **11 dashboards** can light up. The tiers above matter mainly for hand-rolled or partial setups.

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

### ⭐ Executive Overview — `executive-overview.json`
*Source: trace + log + metric · Tier: always works (degrades gracefully)*

**What it's for.** A single landing page that rolls up the health of everything — apps, ClickHouse,
Kubernetes, and the collector — into a few headline numbers and drill-down tables.

**Why use it / who it's for.** This is the **first dashboard to import** and the one to put on the
team's shared screen. Executives and on-call leads get a 5-second read on "is anything on fire?";
engineers use the click-through tables to jump straight into the offending Traces or Logs. Because
every tile degrades gracefully, it's also the safest way to *see your telemetry coverage grow* as
you wire up more pipelines.

**What you need.** Nothing hard-required — it shows whatever is flowing. Fills in fully once you have
server spans, logs, and k8s metrics.

**What you'll see.**
- **Service health — at a glance:** server-span error rate %, request volume, server-span latency p95,
  log error rate %.
- **Platform — at a glance:** K8s nodes ready.
- **Top services:** *Services by error rate* → click a row to open **Traces**; *Services by log
  errors* → click a row to open **Logs**.
- **Request traffic:** request rate & errors from server spans.

**How to read it.** Start top-left and scan right; anything red/non-zero in the "at a glance" rows is
your cue to click into the matching table below and drill down. Empty tiles = that signal isn't
flowing yet (see the setup tiers), not an error. Counter-based metric tiles show per-instance
rates/deltas over the selected time range, not raw cumulative totals.

---

### 🔵 Services — RED (Rate / Errors / Duration) — `services-red.json`
*Source: trace · Tier 4 (needs app traces)*

**What it's for.** The classic **RED method** view of your services: how much traffic (Rate), how
many failures (Errors), and how slow (Duration/latency) — per service and per route — plus a compact
SLO strip at the bottom.

**Why use it / who it's for.** The everyday dashboard for **service owners and SREs**. It answers
"which service is slow or erroring right now, and on which endpoint?" The slow-routes table links
straight into Traces so you go from symptom to root-cause exemplar in one click, while the SLO strip
shows whether the same failures are burning reliability budget.

**What you need.** OTLP **traces** with server spans (`SpanKind = 'Server'`) and `StatusCode`. *(HTTP-
route tiles read `SpanAttributes['http.route']`; pure gRPC/messaging services that don't set it show
empty rows there while rate/error/latency and the SLO strip still work.)*

**What you'll see.**
- **Rate & errors:** request rate by service; error rate %.
- **Latency & error breakdown:** p50/p95/p99 latency; errors by status message (pie).
- **Slow routes & distribution:** slowest routes by p95 (→ Traces); a **latency-anomaly** control
  chart; a server-latency **heatmap**.
- **SLO strip:** availability (SLI), error-budget remaining, a multi-window burn-rate table
  (1h / 6h / 24h / 3d), and availability over time against the 99.9% target.

**How to read it.** Watch the error-rate % and p95 lines for spikes; use *Slowest routes* to see
which endpoint is responsible, then click through to the actual traces. The anomaly tile flags spikes
relative to each service's own recent baseline. In the SLO strip, burn rate > 1 means you are spending
budget faster than the objective allows; a short-window fast burn is page-worthy.

---

### 🔵 Logs — Overview — `logs-overview.json`
*Source: log · Tier 4 (needs app/container logs)*

**What it's for.** Volume, severity mix, top errors, normalized error signatures, top error sources,
and — the standout feature — **newly appeared error patterns**, plus a live error stream.

**Why use it / who it's for.** For **anyone triaging an incident or a deploy**. Beyond the usual
"errors are up" volume chart, its *new patterns* tile answers the far more useful question: *"what
started happening in the last 24h that wasn't happening before?"* — a cheap, deploy-aware anomaly
detector.

**What you need.** Application/container **logs** (filelog or OTLP) — any log volume. Error tiles match
`SeverityNumber >= 17` and lowercase severity text for error/fatal records, so they catch both
numeric and textual severity.

**What you'll see.**
- **Volume & error rate:** log volume by severity; error/fatal rate by service.
- **Top errors & patterns:** top error messages (→ Logs); normalized error signatures; top error
  sources by namespace/pod; **new log patterns in the last 24h vs the prior 7 days**.
- **Live stream:** a live error stream you can watch during a rollout.

**How to read it.** During normal ops, watch the severity mix. After a deploy, go straight to *new
log patterns* — anything listed there is new noise (or a new bug) introduced recently. Use top
namespace/pod sources to find where that noise is coming from, then click into the full logs.

---

### 🟠 Kubernetes — Infrastructure — `kubernetes-infrastructure.json`
*Source: metric + log · Tier 3 (needs kubeletstats + k8s_cluster receivers; k8sobjects for events)*

**What it's for.** The health of the **cluster underneath your apps**: nodes, pods, deployments, and
namespaces — CPU, memory, restarts, availability, and filesystem pressure — plus per-container usage
against its limits and a live feed of Kubernetes cluster events.

**Why use it / who it's for.** For **platform / infrastructure engineers and cluster admins**. When a
service is unhealthy, this tells you whether the cause is the *platform* (node out of memory, pods
crash-looping, deployment under-replicated, a container pinned at its CPU/memory limit, or a Warning
event like `BackOff`/`Unhealthy`) rather than the app code.

**What you need.** A collector with the **`kubeletstats`** and **`k8s_cluster`** receivers (plus the
RBAC to read them). Required metrics: `k8s.node.{cpu,memory}.usage`, `k8s.deployment.{available,
desired}`, `k8s.pod.{phase,memory.usage}`, `k8s.container.restarts`. Filesystem, container-vs-limit
(`k8s.container.{cpu,memory}_limit_utilization`, `container.uptime`) and event tiles are optional; the
**cluster-events** tiles additionally need the **`k8sobjects`** receiver (watching `events.k8s.io`),
which lands events in `otel_logs`.

**What you'll see.**
- **Nodes:** CPU (cores) and memory usage; a node status/uptime table; nodes-ready count; filesystem usage %.
- **Pods:** deployment availability (ready/desired); pods by phase as a true count by phase; a pod
  status & resources table; pod CPU and memory vs their limits (%).
- **Saturation & restarts:** pods not Running; container restarts; node memory saturation; top pods by restarts.
- **Container utilization:** top containers by CPU-vs-limit and memory-vs-limit %, and a per-container
  utilization table with uptime (containers without a limit set show 0%).
- **Cluster events:** Warning-event count, top event reasons, and a recent-events stream (Normal vs
  Warning) — cluster-wide, since event scope lives in the event body, not resource attributes.
- **Namespaces:** per-namespace CPU and memory; a namespace summary table.

**How to read it.** Top-down: nodes healthy? → deployments at desired replica count? → any pods stuck
in a bad phase or near their CPU/memory limits? The saturation/restarts and container-utilization
sections are your early warning for OOMKills, crash loops, and node pressure; the events feed explains
*why* (image pull backoff, failed probes, evictions). Note the event tiles ignore the Namespace filter.

---

### 🟠 OTel Collector — Pipeline Health — `collector-health.json`
*Source: metric · Tier 3 (needs collector self-telemetry scraped)*

**What it's for.** Is your **telemetry pipeline itself** healthy? Accepted vs refused vs failed spans,
logs, and metric points; exporter queue utilization; processor drops; scraper errors; and collector
CPU/memory.

**Why use it / who it's for.** For whoever **owns the observability pipeline**. It's the meta-monitor:
if this dashboard shows refused/failed telemetry or a full exporter queue, then *every other
dashboard's data is suspect* because telemetry is being dropped before it lands. This is where you
catch "why is my data incomplete?"

**What you need.** The collector's own internal telemetry (Prometheus on the collector's `:8888`)
scraped back into OTel. Required: receiver accepted/refused counters for spans/logs/metric points and
exporter sent, send-failed, queue-size, and queue-capacity metrics.

**What you'll see.**
- **Pipeline — at a glance:** refused spans/logs/metric points (should be 0), failed sends (should be 0),
  exporter queue utilization %, and exporter in-flight requests.
- **Traces pipeline:** accepted vs refused vs failed spans; exporter sent spans; queue size vs
  capacity; send-failure lines; processor incoming vs outgoing (**a gap = dropped data**).
- **Logs & metrics pipeline:** accepted vs refused log records and metric points; scraper scraped vs errored.
- **Collector resources:** memory (RSS/heap); CPU (rate).

**How to read it.** The "should be 0" tiles are your headline health. If exporter queue utilization
is climbing toward 100%, or incoming > outgoing in the processor tile, the collector can't keep up
(back-pressure) and is dropping telemetry — scale it or investigate the export destination. The
bundled **collector-drops alert** watches refused spans.

---

### 🟠 Host / OS Metrics — `host-os.json`
*Source: metric · Tier 3 (needs the hostmetrics receiver)*

**What it's for.** The health of the **physical / virtual hosts** underneath the cluster: CPU busy %,
load average, memory and swap usage, and disk / network throughput — per host.

**Why use it / who it's for.** For **infrastructure and platform engineers**. When Kubernetes shows
node pressure, this is the layer below it — is the box itself CPU-saturated, out of memory, swapping,
or maxing out a disk/NIC? It answers "is this a host problem?" independent of the k8s scheduler view.

**What you need.** A collector with the **`hostmetrics`** receiver enabled (`system.*` scrapers).
Required: `system.cpu.utilization`, `system.memory.utilization`. Optional: `system.cpu.load_average.1m`,
`system.swap.utilization`, `system.disk.io`, `system.network.io`.

**What you'll see.**
- **CPU & load:** CPU busy % (all non-idle states, per host) and load average (1m).
- **Memory & swap:** memory used % and swap used %.
- **Disk & network:** read/write and receive/transmit throughput (bytes/sec) per host.
- **Hosts summary:** a per-host table of CPU %, memory %, load, and swap for a quick fleet scan.

**How to read it.** Watch CPU busy % and load together — a load average well above the core count with
high CPU % means the host is saturated. Rising swap % on a memory-heavy host warns of impending OOM.
Use the disk/network lines to spot an I/O-bound host. The summary table sorts the fleet so the hottest
hosts surface first.

---

### 🔵 Latency Histograms — `metrics-histograms.json`
*Source: metric · Tier 4 (needs app OTLP histogram metrics)*

**What it's for.** True **latency percentiles** (p50 / p95 / p99 / avg) computed from OpenTelemetry
**explicit-bucket histogram** metrics — for HTTP server and client calls and RPC server calls — plus
ClickHouse Keeper request latency.

**Why use it / who it's for.** For **service owners, SREs, and performance engineers** who want
latency straight from the metrics pipeline (aggregated, cheap, always-on) rather than sampled traces.
It complements **Services — RED**: RED derives latency from trace spans, this derives it from
histogram buckets, so you get latency even for services that only emit metrics.

**What you need.** Applications emitting OTLP **histogram** metrics — required: `http.server.duration`.
Optional: `http.client.duration`, `rpc.server.duration`, and (for the Keeper tile)
`ClickHouseHistogramMetrics_keeper_response_time_ms`. Percentiles are interpolated from the cumulative
bucket counts (delta over the selected range), so counter resets and multiple instances are handled.

**What you'll see.**
- **HTTP server / client & RPC server latency:** per-operation p50/p95/p99/avg tables (ms).
- **Trends:** average latency and request rate over time, by service.
- **ClickHouse Keeper latency:** Keeper request-time percentiles from the CH histogram metrics.

**How to read it.** p99 far above p50 means a long tail — a subset of requests is slow even if the
median looks fine. Compare server vs client latency to place blame (your service vs a downstream
dependency). The request-rate trend gives the traffic context behind a latency change. All values are
milliseconds.

---


*Source: metric + SQL · Tier 2 (needs ClickHouse metrics scraped; SQL KPIs use `system.*` tables)*

**What it's for.** The operational health of the **ClickHouse server** backing your stack: disk
headroom, query activity, failed queries, active merges, pending mutations, and memory tracking.

**Why use it / who it's for.** For **ClickHouse operators / DBAs and platform teams**. ClickHouse is
the engine under HyperDX (and often the customer's own analytics); this is the "is the database
healthy?" dashboard — disk running low, throughput changing, failures rising, or background work
backing up.

**What you need.** ClickHouse server metrics scraped into OTel (`clickhouse`/Prometheus receiver) plus
`SELECT` on `system.disks`, `system.merges`, and `system.mutations` for the operational SQL KPIs.
Required metrics include `ClickHouseProfileEvents_{Query,FailedQuery,SelectQuery,InsertQuery}` (sum)
and `ClickHouseMetrics_{Query,MemoryTracking}` (gauge).

**What you'll see.**
- **Operations — at a glance:** disk free %, running queries, active merges, pending mutations, and
  memory tracking.
- **Query activity:** query rate as per-instance deltas/rates over the selected time range; failed
  queries; inserted-rows rate; SELECT vs INSERT.
- **Merges & mutations:** active merges from `system.merges`; pending mutations from `system.mutations`.
- **I/O & cache:** page-cache reads (cache vs source bytes); async insert bytes.

**How to read it.** Watch disk free %, failed queries, memory tracking, and background work for
anomalies. A rising active-merge or pending-mutation count means ClickHouse is struggling to keep up;
open the advanced Storage & MergeTree or Keeper & Replication dashboards when you need a deeper dive.

---

### 🟡 ClickHouse — Query Performance & Errors — `clickhouse-queryperf.json`
*Advanced ClickHouse deep dive · Source: metric + SQL · Tier 2 (SQL tiles need zero setup; summary tiles need CH metrics)*

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

### 🟢 ClickHouse — Storage & MergeTree — `clickhouse-storage-mergetree.json`
*Advanced ClickHouse deep dive · Source: SQL only · Tier 1 (works on any ClickHouse, zero setup)*

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

### 🟡 ClickHouse — Keeper & Replication — `clickhouse-keeper-replication.json`
*Advanced ClickHouse deep dive · Source: metric + SQL · Tier 2 (Keeper metrics) / replication needs a cluster*

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

Pick by role — but remember the **8 default dashboards** are the safe first import for everyone.

| If you're a… | Start with |
|--------------|-----------|
| **Data scientist / analyst** | `executive-overview`, `services-red`, `logs-overview`, `metrics-histograms` — the app-signal dashboards you'll build analysis on |
| **Platform / Kubernetes admin** | `kubernetes-infrastructure`, `host-os`, `collector-health`, `clickhouse-health`, `executive-overview` |
| **SRE / reliability owner** | `services-red` (RED + SLO strip), `metrics-histograms`, `logs-overview`, `collector-health`, `executive-overview` |
| **ClickHouse operator / DBA** | `clickhouse-health` first, then advanced deep dives: `clickhouse-storage-mergetree`, `clickhouse-queryperf`, `clickhouse-keeper-replication` |
| **Just kicking the tires (any cluster)** | the 8 defaults — they show what is flowing today and degrade gracefully as you add data |

---

## "My dashboard is empty" — quick troubleshooting

Empty tiles almost always mean **the data isn't flowing yet**, not that the dashboard is broken.

1. **Run `preflight`** — it tells you exactly which required signal is missing per dashboard.
2. **Check the setup tier** above — do you have the receiver / instrumentation that dashboard needs?
3. **Check the time range** — the dashboard defaults to a recent window; widen it if your data is sparse.
4. **Check metric names** — if `preflight` says a required metric is missing but you *are* scraping it,
   your exporter may use a different name. Adjust `metricName` in the tile and `requirements.json`.
5. **`clickhouse-keeper-replication` replication empty?** — expected on single-node ClickHouse (see that section).
6. **`clickhouse-storage-mergetree` / `clickhouse-queryperf` empty?** — these are Raw SQL dashboards that
   read `system.*` tables. Verify the HyperDX ClickHouse user can `SELECT` from `system.parts`,
   `system.part_log`, and/or `system.query_log` (preflight only checks OTel telemetry, not this access).
7. **Collector dropping data?** — check `collector-health`: refused/failed spans or a full exporter
   queue means telemetry is lost before it lands, which starves every other dashboard.

---

## Related docs

- **[DASHBOARD-DEEP-DIVE.md](DASHBOARD-DEEP-DIVE.md)** — tile-by-tile Q&A for every dashboard: what
  each visual shows, how to read it, and how to act on it.
- **[README.md](README.md)** — install steps, importer flags, filters, schema contract, customizing.
- **[requirements.json](requirements.json)** — the machine-readable source of truth behind `preflight`.
- **[docs/](docs/)** — per-dashboard, per-tile reference with screenshots.
- **[alerts/README.md](alerts/README.md)** — the optional alerts pack (error rate, SLO burn, collector
  drops, too-many-parts, replication lag), a generic webhook by default.
