# ClickStack Dashboards — Deep-Dive & Q&A Guide

A visual-by-visual reference for every dashboard in this pack. For each chart you will find **what data it reads**, **how it is calculated**, and a short **question-and-answer** that explains how to interpret it — including what healthy and unhealthy look like, and what to do next.

> **How this guide fits with the others**
> - **`DASHBOARD-CATALOG.md`** helps you decide *which* dashboards to import for your setup.
> - **This guide** helps you *understand and act on* each dashboard once it is showing data.
>
> New to the pack? Read the **[Core Concepts](#core-concepts)** section first — it explains the handful of ideas that every dashboard builds on.

Imported dashboard display names are prefixed **`ClickStack ·`**; this guide uses the shorter names below.
The three ClickHouse deep dives live under `hyperdx/dashboards/advanced/` and are optional, but the
importer recurses into that subfolder when you import the full pack.

---

## Contents

- [Core Concepts](#core-concepts)
- [1. Services — RED](#1-services--red)
- [2. Logs — Overview](#2-logs--overview)
- [3. Kubernetes — Infrastructure](#3-kubernetes--infrastructure)
- [4. OpenTelemetry Collector — Pipeline Health](#4-opentelemetry-collector--pipeline-health)
- [5. ClickHouse — Operations](#5-clickhouse--operations)
- [6. ClickHouse — Query Performance & Errors](#6-clickhouse--query-performance--errors)
- [7. ClickHouse — Storage & MergeTree](#7-clickhouse--storage--mergetree)
- [8. ClickHouse — Keeper & Replication](#8-clickhouse--keeper--replication)
- [9. Executive Overview](#9-executive-overview)
- [10. Host / OS Metrics](#10-host--os-metrics)
- [11. Latency Histograms](#11-latency-histograms)
- [Quick-Reference Playbook](#quick-reference-playbook)

---

## Core Concepts

A few ideas underpin every dashboard. Understanding them once makes all eleven easy to read.

### The three data sources

Each chart reads from one of three data sources. A source is a table in ClickHouse together with the rules for interpreting it. The import script connects these automatically, so no manual configuration is required.

| Source | Contains | Produced by |
| --- | --- | --- |
| **Traces** | One record per *span* (a single timed operation within a request) | Application instrumentation sent over OTLP |
| **Logs** | One record per log line | Application logs (OTLP) and container output (filelog collector) |
| **Metrics** | One record per metric datapoint | OpenTelemetry collectors (Kubernetes, ClickHouse, and collector self-metrics) |

### How a chart queries its data

Charts use one of two query styles. You will see both throughout the pack.

- **Standard charts** aggregate a source with a function such as `count`, `average`, `quantile`, or `sum`, filtered by a simple expression (for example, *server spans that are errors*). These are fully portable and require only the data source.
- **SQL charts** run a purpose-built ClickHouse query. These are used when the data lives in a ClickHouse system table (such as `system.query_log` or `system.parts`) or when the calculation needs capabilities the standard builder does not provide, such as rolling baselines or custom time windows.

Both styles respect the dashboard filters described below.

### Units and conventions

- **Span durations are recorded in nanoseconds.** Latency charts convert this to seconds or milliseconds for display.
- **Server spans** represent the point at which a service received a request. Rate, error, and latency charts count only these, so a single request is not counted multiple times as it passes through the system.
- **Percentiles (p50 / p95 / p99)** describe the distribution of a value. A p95 latency of 500 ms means 95% of requests completed within 500 ms. Monitoring p95 and p99 reveals the slow "tail" of requests that a simple average would hide.
- **Metric types.** A *gauge* is a point-in-time reading (for example, queries running right now). A *sum* is a continuously increasing counter (for example, total queries ever run); these dashboards show cumulative OTel counters as per-instance rates or deltas over the selected time picker, not raw cumulative totals.
- **Dashboard filters.** The dropdown selectors at the top of a dashboard (such as *Service*, *Namespace*, or *Severity*) apply to every chart on that dashboard at once.

---

## 1. Services — RED

**Data source:** Traces  ·  **Filters:** Service
**Purpose:** The primary starting point for application performance and reliability. RED stands for **Rate**, **Errors**, and **Duration** — the three signals that best summarise the health of any service — and the bottom SLO strip shows whether those errors are burning budget.

### Rate & errors

**Request rate by service** — server request volume per service over time.
- **Q: What does this show?** The number of server spans each service handles in each time interval, so a request is counted where it is actually handled.
- **Q: How should I read it?** This is the overall shape of your traffic. A line falling to zero indicates a service has stopped receiving requests. A sudden spike may indicate a surge in demand or a retry loop upstream.

**Error rate %** — the proportion of server requests that failed.
- **Q: Why a percentage rather than a count?** A percentage accounts for traffic volume. One hundred errors out of a million requests is negligible; one hundred out of two hundred is an outage.
- **Q: What is healthy?** For most services this is below 1%. A steadily rising line is often the earliest indication of a developing problem.

### Latency & error breakdown

**Latency p50 / p95 / p99** — response time at three percentiles.
- **Q: Why three lines?** The p50 line reflects the typical user experience, while p95 and p99 reflect the slowest requests. If p50 is stable but p99 climbs, a specific subset of requests is affected while most users are unaffected.

**Errors by status message** — a breakdown of failures by their reported reason.
- **Q: How should I use it?** A single dominant segment points to one primary failure mode to address first. Many small segments suggest broad instability.

### Slow routes & distribution

**Slowest routes (p95)** — a ranked table of the slowest endpoints. Selecting a row opens the underlying traces for that route.
- **Q: How should I use it?** Identify the endpoint with the worst p95 latency, then select it to inspect the individual slow traces and see where the time is being spent.

**Latency anomaly — p95 vs rolling baseline** — live p95 latency plotted against a self-calibrating expected range.
- **Q: What is the shaded band?** The chart calculates an expected baseline from roughly the previous 24 hours of data and surrounds it with a statistical range (three standard deviations). The band represents "normal" for this service.
- **Q: How should I read it?** When the live line rises above the upper edge of the band, latency is unusually high relative to its own recent history. Because the band adapts automatically, the same chart works for both fast and slow services without manual thresholds.

**Server latency distribution (heatmap)** — the full distribution of response times over time.
- **Q: What does this add?** It reveals the shape of latency. A single band indicates consistent performance. Two distinct bands indicate two populations of requests (for example, cached versus uncached responses) that an average would obscure.

### SLO strip

**Availability (SLI)** — the measured proportion of successful server requests, color-coded against the 99.9% objective.
- **Q: What is an SLI?** A Service Level Indicator is the measured "good request" ratio. Dips below the objective consume error budget.

**Error budget remaining** — how much of the 0.1% monthly budget is still available.
- **Q: Why show this next to RED?** It translates the same failures into business reliability language, so you can see whether today's errors threaten the target.

**Multi-window burn rate** — a table showing how fast the error budget is being spent over 1 hour, 6 hours, 24 hours, and 3 days.
- **Q: How should I read it?** A value of 1.0 is exactly on budget. A high short window indicates an acute incident; a high long window indicates a slower issue that will breach the objective if it continues.

**Availability over time (target 99.9%)** — the success ratio across the selected period.
- **Q: What should I watch for?** Dips below the objective line are the moments that consume budget. Correlate them with deployments or known incidents.

---

## 2. Logs — Overview

**Data source:** Logs  ·  **Filters:** Service, Severity
**Purpose:** Cluster-wide log triage — identifying what is failing, whether it is new, where it is coming from, and providing a live view of errors as they occur.

> This source combines Kubernetes container output (captured from every pod) with structured application logs. It contains data even when applications are not instrumented for tracing.

### Volume & error rate

**Log volume by severity** — total log throughput, segmented by severity level.
- **Q: How should I read it?** The overall height reflects logging volume; the error and fatal segments are the focus. Error filters use `SeverityNumber >= 17` and lowercase severity text, so numeric and textual severities both match.

**Error / fatal rate by service** — the rate of error and fatal logs per service.
- **Q: What is it for?** Identifying which service began reporting errors, and when.

### Top errors & patterns

**Top error messages** — the most frequent error and fatal messages. Selecting a row opens those log entries.
- **Q: How should I use it?** A small number of messages usually accounts for most of the volume. Addressing those has the greatest impact.

**Normalized error signatures** and **top error sources by namespace/pod** — grouped errors with their most likely origin.
- **Q: Why is this useful?** Signatures collapse noisy variable text into stable groups, while source tables tell you which namespace or pod is producing them.

**New log patterns in last 24h (vs prior 7d)** — error patterns that have appeared in the last day but not in the preceding week.
- **Q: How does it identify a "pattern"?** It normalises each message by replacing variable elements such as numbers and identifiers with placeholders, so that otherwise identical messages are grouped together. It then reports only those patterns that are genuinely new relative to the prior week.
- **Q: Why is this valuable?** New error signatures are a strong early indicator that a recent deployment or configuration change has introduced a problem. This chart highlights issues that have only just begun.

### Live stream

**Live error stream** — a continuously updating view of error and fatal logs, showing timestamp, severity, service, namespace/pod, and message.
- **Q: What is it for?** Following errors in real time during an active investigation.

---

## 3. Kubernetes — Infrastructure

**Data source:** Metrics (Kubernetes) + Logs (events)  ·  **Filters:** Namespace
**Purpose:** The health of the cluster that hosts your applications — its nodes, pods, namespaces, container-vs-limit utilization, and cluster events.

> This dashboard requires the Kubernetes infrastructure collectors (the `kubeletstats` and `k8s_cluster` receivers). The **cluster-events** section additionally needs the `k8sobjects` receiver, which watches `events.k8s.io` and lands events in the Logs source.

### Nodes

**Node CPU usage (cores)** and **Node memory usage** — resource consumption per node over time.
- **Q: How should I read it?** These indicate your physical headroom. Memory approaching a node's capacity risks pod eviction or termination.

**Nodes — status, CPU, memory, uptime** — a per-node summary table.
- **Q: What is it for?** A single-glance roster of node health. A status of *Not Ready* requires immediate attention.

**Nodes ready** — the count of nodes in a ready state.
- **Q: How should I read it?** This should equal your total node count. A lower number means a node has dropped out of the cluster.

**Node filesystem usage %** — disk utilisation per node.
- **Q: Why monitor it?** A full node disk disrupts image pulls, logging, and database writes. This should be addressed well before it reaches capacity.

### Pods

**Deployment availability (ready ÷ desired)** — the proportion of desired replicas that are running.
- **Q: How should I read it?** 100% means every replica is available. A lower value indicates a stalled rollout or crashing pods.

**Pods by phase** — the true count of pods in each lifecycle phase, by namespace.
- **Q: How should I read it?** A predominance of *Running* is healthy. A growing *Pending* count indicates pods that cannot be scheduled; *Failed* indicates crashes.

**Pods — status & resources** — a detailed table including phase, CPU and memory usage against limits, age, and restart count, ordered by restarts.
- **Q: Which column matters most?** Restarts. A pod with a rising restart count is crash-looping. A memory usage near its limit predicts an imminent termination.

**Pod CPU vs limit %** and **Pod memory vs limit %** — resource usage as a percentage of each pod's configured limit.
- **Q: Why measure against the limit?** Kubernetes throttles CPU and terminates containers for memory at the limit. CPU near 100% of its limit indicates throttling (and slowness); memory near 100% indicates the pod is about to be terminated.

### Saturation & restarts

**Pods not Running**, **container restarts**, **node memory saturation**, and **top pods by restarts** — the fast path to crash loops and pressure.
- **Q: How should I read it?** Start with pods not Running and restart leaders, then check node memory saturation to decide whether the failure is app-specific or resource pressure on the node.

### Container utilization

**Container CPU vs limit %** and **Container memory vs limit %** — the top containers by usage against their configured limits, over time.
- **Q: How is this different from the pod tiles above?** These are per **container** (a pod can run several), so they pinpoint exactly which container in a multi-container pod is hot. A container without a configured limit reports 0%.

**Container utilization vs limits** — a per-container table of CPU %, memory %, and uptime.
- **Q: Which column matters most?** A container pinned near 100% CPU-vs-limit is being throttled; one near 100% memory-vs-limit is close to an OOMKill. Short uptime next to high restarts elsewhere confirms a crash loop.

### Cluster events

**Warning events (in range)**, **Top event reasons**, and **Recent events** — the Kubernetes event stream (from the `k8sobjects` receiver), split into Normal and Warning.
- **Q: How should I read it?** Warning events (`BackOff`, `Unhealthy`, `FailedScheduling`, evictions) explain *why* a pod is unhealthy — the cause behind a bad phase or restart. Top reasons show recurring problems at a glance; the recent stream is the chronological detail.
- **Q: Why do these ignore the Namespace filter?** An event's namespace lives inside the event body, not as a resource attribute, so these tiles are intentionally cluster-wide.

### Namespaces

**Namespace CPU usage** and **Namespace memory usage** — aggregate consumption per namespace.
- **Q: What is it for?** Understanding which application or team is consuming cluster resources — useful for capacity planning and identifying resource contention.

**Namespaces — phase, CPU, memory** — a per-namespace summary table.

---

## 4. OpenTelemetry Collector — Pipeline Health

**Data source:** Metrics (collector self-telemetry)  ·  **Filters:** Collector instance
**Purpose:** Confirms that the telemetry pipeline itself is healthy. If this dashboard shows problems, other dashboards may be missing data — check here first.

### Pipeline — at a glance

**Refused spans**, **refused log records**, **refused metric points**, and **failed sends** — data the pipeline could not accept or could not deliver. All are flagged red above zero.
- **Q: What is the difference?** *Refused* means the collector rejected incoming data, typically because it is overloaded. *Failed sends* means the collector accepted the data but could not deliver it to ClickHouse, typically due to a connectivity or authentication issue. Either represents lost telemetry.

**Exporter queue utilization %** and **Exporter in-flight requests** — the backlog of data awaiting delivery.
- **Q: How should I read it?** A utilization line climbing toward 100% means the collector is receiving data faster than it can deliver it. If unaddressed, the queue fills and the collector begins refusing data.

### Traces pipeline

**Spans: accepted vs refused vs failed** — accepted spans should dominate; refused and failed should remain near zero.
**Exporter sent spans** and **send failures** — sent should track accepted volume; failures should remain at zero.
**Exporter queue size vs capacity** — the gap between the two is your safety margin; a queue approaching capacity is a warning.
**Processor incoming vs outgoing items** — the two lines should overlap. A gap indicates data was dropped within the pipeline.

### Logs & metrics pipeline

**Accepted vs refused log records** and **accepted vs refused metric points** — the ingest and rejection rates for logs and metrics.
**Scraper: scraped vs errored metric points** — for metrics gathered by scraping. Errors above zero indicate the collector cannot reach a target it is configured to scrape.

### Collector resources

**Collector memory (RSS / heap)** and **Collector CPU seconds** — the collector's own resource usage.
- **Q: Why monitor this?** Memory approaching the collector's limit is a common root cause of the refusals described above. This is where to look when the pipeline is dropping data.

---

## 5. ClickHouse — Operations

**Data source:** Metrics (ClickHouse) and ClickHouse system tables (SQL)  ·  no filters
**Purpose:** The operational vital signs of the ClickHouse database that stores your observability data.

### Operations — at a glance

**Disk free %**, **Running queries**, **Active merges**, **Pending mutations**, and **Memory tracking**.
- **Q: What indicates a problem?** Low disk free %, rising active merges, or growing pending mutations means ClickHouse is struggling to keep up with writes or background work. Memory tracking approaching the server limit means queries will begin to fail.

### Query activity

**Query rate** — current query volume as per-instance deltas/rates over the selected time picker, not raw cumulative counters.
- **Q: What is it for?** Distinguishing normal variation from unusual load while respecting the dashboard time range.

**Failed queries**, **Inserted rows rate**, and **SELECT vs INSERT queries** — the read/write balance and confirmation that writes (your telemetry ingest) are flowing.

### Merges & mutations

**Active merges** from `system.merges` and **Pending mutations** from `system.mutations`.
- **Q: What are these?** ClickHouse continuously merges small data segments into larger ones in the background; this is normal and expected. A persistently high merge count can indicate the database is struggling to keep pace with the insert rate. Pending mutations are heavier operations waiting to finish, and many in progress can slow the system.

### Disk & memory

**Disk free %** from `system.disks` and **Memory tracking** from ClickHouse metrics.
- **Q: How should I read it?** Disk trending toward full is urgent because it blocks writes; memory tracking near the server limit predicts query failures.

---

## 6. ClickHouse — Query Performance & Errors

**Data source:** ClickHouse `system.query_log` (SQL) and ClickHouse metrics  ·  no filters
**Purpose:** The database administrator's view — which queries are slow, resource-intensive, or failing.

> Most charts read the `system.query_log` table, which requires the ClickHouse connection to permit reading it (the default in ClickStack).

### Query performance — at a glance

**Failed queries**, **Running queries (now)**, and **Memory tracking** — a summary of current query health.

### Query trends

**Query rate by kind** — query volume segmented into selects, inserts, and other operations.
**Query duration — p95 / p99** — the slow tail of query latency.
- **Q: How should I read it?** A rising p99 indicates some queries are becoming more expensive, often a sign of data growth or a query that would benefit from optimisation.

**Peak memory per query — p95 / max** — memory consumption per query.
- **Q: Why monitor it?** The maximum line approaching the server's per-query memory limit is what causes "memory limit exceeded" failures. This provides early warning.

**Query exceptions** — the count of queries that ended in an error.

### Slowest queries & errors

**Slowest queries (last 6h)** — a table of the slowest queries, including the user, duration, memory, rows read, and query text.
- **Q: How should I use it?** This is the most actionable chart for a slow database — it names the specific queries responsible so they can be optimised or rate-limited.

**Top ClickHouse error codes (last 24h)** — the most frequent categories of database error.
- **Q: How should I read it?** This shows the dominant classes of failure (such as memory or timeout errors), indicating the type of problem before you examine individual queries.

---

## 7. ClickHouse — Storage & MergeTree

**Data source:** ClickHouse `system.parts` and `system.part_log` (SQL)  ·  no filters
**Purpose:** Disk usage, compression, and the health of ClickHouse's background storage engine.

### Storage — at a glance

**Disk used (active parts)**, **Compression ratio**, **Active parts (total)**, and **Rows stored (active)**.
- **Q: What is a good compression ratio?** ClickHouse commonly achieves between 5× and 15×. A declining ratio can indicate high-entropy data or a schema whose ordering is not compressing well.

### Throughput & merges

**Part events / 5 min** — the rate of inserts, merges, and mutations.
- **Q: How should I read it?** Each insert creates a new data segment, and merges compact them. Healthy operation shows merges keeping pace with inserts.

**Merge duration — p95 / max** — how long merges take; increasing durations indicate merge pressure.
**Bytes written — inserted vs merged** and **Rows processed — inserted vs merged** — the additional work created by merging, which rewrites data. A large ratio of merged to inserted indicates significant rewrite activity.

### Tables & parts

**Largest tables by disk** — disk usage, row count, part count, and compression per table, answering where storage is being consumed.
**Active parts per table** — tables ordered by their number of data segments.
- **Q: Why does this matter?** ClickHouse rejects inserts with a "too many parts" error when a table accumulates too many unmerged segments, usually caused by very frequent small inserts. A table with a rapidly rising part count is the warning sign.

**Recent merges (last 6h)** — a table of individual merge operations and their outcomes.

---

## 8. ClickHouse — Keeper & Replication

**Data source:** ClickHouse Keeper metrics and replication system tables (SQL)  ·  no filters
**Purpose:** The coordination layer (ClickHouse Keeper) that enables replication and distributed operations.

> The replication tables at the bottom of this dashboard are empty on a single-node installation. This is expected and healthy — they populate only on replicated or clustered deployments.

### Keeper — at a glance

**Active sessions**, **Watches**, **Outstanding requests**, and **Alive connections**.
- **Q: How should I read it?** Sessions and connections should remain stable. A growing outstanding-requests backlog means Keeper cannot keep pace, which can stall merges and inserts across the cluster.

### Throughput & latency

**Keeper request rate by type**, **Commits vs failed commits**, **Packets received / sent**, **In-flight requests & watches**, and **Keeper commit-wait & process time**.
- **Q: What is the key warning sign?** Failed commits above zero, or a rising commit-wait time, indicates the consensus layer is unhealthy — typically due to slow disk or network issues between Keeper nodes.

**Keeper / ZooKeeper errors (last 24h)** — a table of coordination-related error counts.

### Replication (replicated deployments only)

**Replica status** — per-table replication state, including leader status, read-only status, and lag.
- **Q: How should I read it?** A read-only replica or a growing delay indicates a replica falling behind or disconnected from the coordination layer.

**Replication queue (stuck tasks)** — replication tasks ordered by retry count.
- **Q: How should I read it?** Tasks with a high retry count and a recorded exception are stuck in a retry loop, which is the direct cause of replicas diverging.

---

## 9. Executive Overview

**Data source:** Traces, Logs, and Metrics  ·  **Filters:** Service, Namespace
**Purpose:** A single-page summary of application health, platform health, the most affected services, and data ingest. Suitable for a status check or a shared status display. Charts degrade gracefully — any signal that is not configured simply appears empty while the rest continue to work.

### Service health — at a glance

**Server-span error rate (%)**, **request volume (server spans)**, **server-span latency p95**, and **Log error rate (%)**.
- **Q: What is this for?** Four figures that answer whether the applications are healthy right now. The color rules present them as a simple status indicator.

### Platform — at a glance

**K8s nodes ready.**
- **Q: What is this for?** A quick view of the underlying cluster — how many Kubernetes nodes are reporting ready. ClickHouse and collector-pipeline internals live in the **advanced** dashboards (opt-in), since those metrics are not collected by default.

### Top services

**Services by error rate** and **Services by log errors** — each ranked worst-first, with rows that link directly to the underlying traces or logs.
- **Q: What is this for?** Identifying which services are affected and moving in a single step from "there is a problem" to the specific traces or logs behind it.

### Request traffic

**Request rate & errors (server spans)** — overall application request volume with the error count overlaid.

---

## 10. Host / OS Metrics

**Data source:** Metrics (Host)  ·  **Filters:** Host
**Purpose:** The health of the physical or virtual hosts beneath the cluster — CPU, load, memory, swap, and I/O.

> This dashboard requires the collector's `hostmetrics` receiver (the `system.*` scrapers). It reads the same OTel metrics schema as the other metric dashboards.

### CPU & load

**CPU busy %** — the percentage of time the CPU spent doing work (all non-idle states), per host.
- **Q: How is it computed?** Per CPU core per scrape, the non-idle fractions are summed, then averaged across cores and the interval — so it is not inflated by core count.

**Load average (1m)** — the run-queue length averaged over one minute.
- **Q: How should I read it?** Compare against the core count: a load well above the number of cores means processes are waiting for CPU even if busy % looks moderate.

### Memory & swap

**Memory used %** and **Swap used %** — utilization of RAM and swap per host.
- **Q: Why watch swap?** Rising swap usage on a memory-pressured host is an early warning of impending OOM and of I/O slowdown as the kernel pages to disk.

### Disk & network

**Disk I/O** and **Network I/O** — read/write and receive/transmit throughput per host.
- **Q: How should I read it?** These identify an I/O-bound host. A sustained ceiling on a device or interface often explains latency that CPU and memory tiles don't.

### Hosts summary

**Hosts summary** — a per-host table of CPU %, memory %, load, and swap for a quick fleet scan, hottest first.

---

## 11. Latency Histograms

**Data source:** Metrics (histograms)  ·  **Filters:** Service
**Purpose:** Request latency percentiles derived from OpenTelemetry explicit-bucket histogram metrics — an always-on, aggregated complement to the trace-based latency in *Services — RED*.

> This dashboard requires applications that emit OTLP **histogram** metrics (`http.server.duration`, and optionally `http.client.duration` / `rpc.server.duration`). The ClickHouse Keeper tile uses `ClickHouseHistogramMetrics_keeper_*`.

### Latency percentiles

**HTTP server / client & RPC server latency** — per-operation p50 / p95 / p99 / average latency tables (ms).
- **Q: How are percentiles computed from a histogram?** The dashboard takes the delta of each cumulative bucket over the selected range (keyed by the full series identity so counter resets and multiple instances are safe), then interpolates the target quantile within the bucket that crosses it.
- **Q: How should I read it?** A p99 far above the p50 means a slow tail — some requests are slow even when the median is fine. Compare server vs client latency to separate your own service's time from a downstream dependency's.

### Trends

**Average latency by service** and **Request rate by service** — latency and traffic over time.
- **Q: Why show request rate alongside latency?** A latency change is only meaningful with traffic context — a p99 spike at very low volume is often a single slow request, not a systemic regression.

### ClickHouse Keeper latency

**Keeper request latency** — percentiles of ClickHouse Keeper request-processing time from the CH histogram metrics.
- **Q: Why is it here?** Keeper coordinates ClickHouse replication; rising Keeper latency can slow inserts and replication cluster-wide.

---

## Quick-Reference Playbook

| Situation | Start here | Then |
| --- | --- | --- |
| Is anything wrong right now? | Executive Overview | Follow the linked service tables |
| The application feels slow | Services — RED | Slowest routes → open the traces |
| Latency without trace coverage | Latency Histograms | Compare server vs client percentiles |
| Are we meeting our reliability target? | Services — RED | Review the SLO strip and multi-window burn rate |
| Errors started after a deployment | Logs — Overview | *New log patterns* chart |
| A pod or node looks unhealthy | Kubernetes — Infrastructure | Pods table (restarts, memory vs limit), then cluster events |
| A container is throttled or OOMing | Kubernetes — Infrastructure | Container utilization vs limits |
| The host itself looks saturated | Host / OS Metrics | CPU busy % + load, then swap and I/O |
| A dashboard is unexpectedly empty | Collector — Pipeline Health | Refused/failed spans, scraper errors |
| Queries or the database are slow | ClickHouse — Query Performance | Slowest queries table |
| Inserts are failing or disk is filling | ClickHouse — Storage | Active parts per table |

> **A useful rule of thumb:** if a chart is empty, first determine whether the dashboard is at fault or whether that data pipeline is simply not yet enabled. Running `preflight.ps1` answers this immediately.
