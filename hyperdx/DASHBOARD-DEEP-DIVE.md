# ClickStack Dashboards — Deep-Dive & Q&A Guide

A visual-by-visual reference for every dashboard in this pack. For each chart you will find **what data it reads**, **how it is calculated**, and a short **question-and-answer** that explains how to interpret it — including what healthy and unhealthy look like, and what to do next.

> **How this guide fits with the others**
> - **`DASHBOARD-CATALOG.md`** helps you decide *which* dashboards to import for your setup.
> - **This guide** helps you *understand and act on* each dashboard once it is showing data.
>
> New to the pack? Read the **[Core Concepts](#core-concepts)** section first — it explains the handful of ideas that every dashboard builds on.

Imported dashboard display names are prefixed **`ClickStack -`**; this guide uses the shorter names below. Six dashboards are default-tier. The single advanced dashboard, **Observability Platform Health**, lives under `hyperdx/dashboards/advanced/` and is optional, but the importer recurses into that subfolder when you import the full pack.

---

## Contents

- [Core Concepts](#core-concepts)
- [1. Operations Center](#1-operations-center)
- [2. Infrastructure](#2-infrastructure)
- [3. Kubernetes](#3-kubernetes)
- [4. Services (RED)](#4-services-red)
- [5. Logs](#5-logs)
- [6. Supportability](#6-supportability)
- [7. Observability Platform Health](#7-observability-platform-health)
- [Quick-Reference Playbook](#quick-reference-playbook)

---

## Core Concepts

A few ideas underpin every dashboard. Understanding them once makes all seven easy to read.

### The three data sources

Each chart reads from one of three primary sources. A source is a table in ClickHouse together with the rules for interpreting it. The import script connects these automatically, so no manual configuration is required.

| Source | Contains | Produced by |
| --- | --- | --- |
| **Traces** | One record per *span* (a single timed operation within a request) | Application instrumentation sent over OTLP |
| **Logs** | One record per log line or Kubernetes event | Application logs (OTLP), container output (filelog collector), and `k8sobjects` events |
| **Metrics** | One record per metric datapoint | OpenTelemetry collectors: Kubernetes, hostmetrics, collector self-telemetry, and ClickHouse metrics |

A few advanced tiles also read ClickHouse **system tables** directly, such as `system.disks`, `system.parts`, and `system.query_log`.

### How a chart queries its data

Charts use one of two query styles. You will see both throughout the pack.

- **Standard charts** aggregate a source with a function such as `count`, `average`, `quantile`, `sum`, `max`, or `last_value`, filtered by a simple expression (for example, *server spans that are errors*). These are fully portable and require only the data source.
- **SQL charts** run a purpose-built ClickHouse query. These are used when the data lives in a ClickHouse system table or when the calculation needs capabilities the standard builder does not provide, such as rolling baselines, counter deltas, fixed burn-rate windows, JSON event parsing, or custom joins.

Both styles respect the dashboard filters described below when their underlying columns support those filters.

### Units and conventions

- **Span durations are recorded in nanoseconds.** Latency charts convert this to seconds or milliseconds for display.
- **Server spans** represent the point at which a service received a request. Rate, error, latency, and SLO charts count only these, so a single request is not counted multiple times as it passes through the system.
- **Percentiles (p50 / p95 / p99)** describe the distribution of a value. A p95 latency of 500 ms means 95% of requests completed within 500 ms. Monitoring p95 and p99 reveals the slow "tail" of requests that a simple average would hide.
- **Metric types.** A *gauge* is a point-in-time reading. A *sum* is a continuously increasing counter; these dashboards show cumulative OTel counters as per-instance rates or deltas over the selected time picker, not raw cumulative totals.
- **Kubernetes phase values** are numeric in the metrics stream. These dashboards translate common pod phases as Pending = 1, Running = 2, Succeeded = 3, Failed = 4; namespaces map Active = 1 and Terminating = 2.
- **Dashboard filters.** The dropdown selectors at the top of a dashboard (such as *Service*, *Namespace*, *Host*, *Collector*, or *Severity*) apply to every compatible chart on that dashboard at once.

---

## 1. Operations Center

**Data source:** Traces, Logs, Kubernetes metrics, Host metrics  ·  **Filters:** Service, Namespace  ·  **Tier:** Default
**Purpose:** The cross-domain landing page for a status check. It rolls node readiness, pod health, resource saturation, service errors, log errors, and recent Kubernetes events into one screen. It is for operators, CSS, and anyone who needs to answer "is the appliance healthy right now?" before drilling into a specialist dashboard.

> Every tile degrades independently. If traces are absent, the service tiles are empty; if `k8sobjects` events are absent, the recent-activity tiles are empty; the remaining signals still work.

### Cluster health

**Cluster health score** — a 0-100 roll-up of node readiness and pod phase health.
- **What it reads:** `default.otel_metrics_gauge`, specifically `k8s.node.condition_ready` and `k8s.pod.phase`.
- **How it is calculated:** For each node and pod, the SQL takes the latest value in the selected time range with `argMax(Value, TimeUnix)`. `nodes_ready` is ready nodes divided by total nodes. `pods_ok` is pods whose latest phase is Running or Succeeded (`phase IN (2, 3)`) divided by total pods. The score is `round(100 * (nodes_ready + pods_ok) / 2, 0)`.
- **Q: How should I read it?** Near 100 means the cluster is broadly healthy. A drop means either nodes are NotReady or pods are stuck outside Running/Succeeded; use the next four tiles to identify which.

**Kubernetes nodes ready %**, **Healthy nodes**, and **Unhealthy nodes (NotReady)** — readiness from the latest node condition.
- **What they read:** `k8s.node.condition_ready` in `default.otel_metrics_gauge`.
- **How they are calculated:** The query groups by `ResourceAttributes['k8s.node.name']`, takes the latest readiness value, then reports ready/total, `countIf(ready = 1)`, and `countIf(ready != 1)`.
- **Q: What is healthy?** Nodes ready should be 100%, healthy nodes should equal total nodes, and unhealthy nodes should be zero. If any node is NotReady, move to **Infrastructure** or **Kubernetes** for the node table and per-node CPU, memory, disk, and uptime.

**Pods not Running** — pods whose latest phase is not Running or Succeeded.
- **What it reads:** `k8s.pod.phase` in `default.otel_metrics_gauge`, filtered by Namespace when selected.
- **How it is calculated:** The latest phase per `ResourceAttributes['k8s.pod.name']` is counted when it is not in `(2, 3)`.
- **Q: How should I read it?** Zero is ideal. Pending pods usually indicate scheduling or capacity problems; Failed or Unknown pods point to workload failures. Drill into **Kubernetes** for phase counts, pod details, and restarts.

**Container restarts (selected range)** — new restarts during the dashboard time picker.
- **What it reads:** `k8s.container.restarts` in `default.otel_metrics_gauge`.
- **How it is calculated:** For each pod, the tile computes `max(Value) - min(Value)` over the selected range, then sums those deltas.
- **Q: Why use a delta?** The metric is cumulative. The delta answers "what restarted during this window?" instead of showing all historical restarts. Any non-zero value deserves a look at **Top pods by restarts** in Kubernetes or Supportability.

### Resource utilization

**Cluster CPU busy % (avg of hosts)** and **Cluster CPU busy % over time** — current and trended host CPU saturation.
- **What they read:** `system.cpu.utilization` in `default.otel_metrics_gauge`, using `ResourceAttributes['host.name']`, `Attributes['cpu']`, and `Attributes['state']`.
- **How they are calculated:** For each host/core/scrape, all non-idle states are summed with `sumIf(Value, Attributes['state'] != 'idle')`; the result is averaged across hosts and cores. The line chart adds `toStartOfInterval(TimeUnix, interval)` for the x-axis.
- **Q: How should I read it?** CPU near 100% means the hosts are saturated. A short spike can be normal; a sustained plateau belongs in **Infrastructure** next to load average to see whether processes are waiting for CPU.

**Cluster memory used % (avg of hosts)** and **Cluster memory used % over time** — current and trended host RAM usage.
- **What they read:** `system.memory.utilization` in `default.otel_metrics_gauge`.
- **How they are calculated:** Both use `avgIf(Value, Attributes['state'] = 'used')`; the line chart groups by time interval.
- **Q: What is unhealthy?** A steady climb toward full usage suggests the next symptom will be eviction or OOM. Use **Infrastructure** for per-host free memory, then **Kubernetes** for pod/container limit utilization.

**Cluster disk used % (volumes)** — disk usage aggregated across all mounted volumes.
- **What it reads:** `system.filesystem.usage` in `default.otel_metrics_sum`.
- **How it is calculated:** `system.filesystem.usage` is split by a `state` attribute (`used` / `free` / `reserved`), so a volume's capacity is the **sum of all its states**. The tile takes the latest value per volume and state, then returns `sum(used) / sum(all states)`.
- **Q: How should I read it?** Rising disk usage is urgent because full disks break image pulls, log writes, and ClickHouse ingest. Go to **Infrastructure** for per-volume free capacity and disk I/O.

### Service & platform status

**Server error rate (%)** — failed server spans as a percentage of all server spans.
- **What it reads:** Traces in `default.otel_traces`, using `SpanKind` and `StatusCode`.
- **How it is calculated:** `avg(if(StatusCode = 'Error', 1, 0))` where `SpanKind = 'Server'`.
- **Q: Why a percentage?** It accounts for traffic volume. One hundred errors in a million requests is very different from one hundred errors in two hundred requests. Drill into **Services (RED)** for per-service trends and SLO burn.

**95th-percentile server latency (p95)** — slow-tail request latency.
- **What it reads:** `Duration` from server spans in `default.otel_traces`.
- **How it is calculated:** `quantile(Duration / 1000000000)` where `SpanKind = 'Server'`, converting nanoseconds to seconds.
- **Q: What should I do if it rises?** Check **Services (RED)** for p50/p95/p99 separation, slow routes, and the anomaly band. A p95 spike with flat p50 usually means a subset of routes or dependencies is slow.

**Log error rate (%)** — the share of log records that are errors or fatals.
- **What it reads:** Logs in `default.otel_logs`, using `SeverityNumber` and `SeverityText`.
- **How it is calculated:** `avg(if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0))`.
- **Q: How is this different from trace errors?** Logs catch failures even when a service is not traced. If trace errors are quiet but log error rate is high, start in **Logs**.

**Request & error counts over time (traces)** — volume and failures in one trend.
- **What it reads:** `default.otel_traces` server spans.
- **How it is calculated:** Each interval counts `SpanKind = 'Server'` requests and sums rows where `StatusCode = 'Error'`.
- **Q: How should I read it?** Error spikes during traffic spikes can indicate overload or retry storms. Errors with flat traffic usually point to a deployment, dependency, or configuration issue.

### Recent activity

**Warning events (in range)** — Kubernetes warning event count.
- **What it reads:** Kubernetes events stored as log records in `default.otel_logs` where `ScopeName LIKE '%k8sobjectsreceiver%'`.
- **How it is calculated:** The SQL counts rows whose JSON body has `object.type = 'Warning'`.
- **Q: What is healthy?** Zero or low, explainable warnings. A sudden increase usually explains bad pod phases or restarts.

**Top event reasons** — recurring Kubernetes event reasons.
- **What it reads:** `Body` JSON in k8sobjectsreceiver log rows.
- **How it is calculated:** It extracts `object.reason` and `object.type`, groups by both, counts rows, and orders by count.
- **Q: How should I use it?** Reasons such as `BackOff`, `Unhealthy`, `FailedScheduling`, `FailedMount`, or `Evicted` tell you the class of failure before you open individual events.

**Recent events** — chronological event detail.
- **What it reads:** `Timestamp` and event `Body` JSON in `default.otel_logs`.
- **How it is calculated:** It extracts type, reason, regarding object kind/namespace/name, and the first 160 characters of `object.note`, ordered newest first.
- **Q: What is it for?** This is the timeline. Use it to correlate failures with rollouts, node changes, scheduling failures, or resource pressure.

---
## 2. Infrastructure

**Data source:** Host metrics and Kubernetes node metrics  ·  **Filters:** Host  ·  **Tier:** Default
**Purpose:** The foundation view: hosts, Kubernetes nodes, filesystems, disks, network interfaces, and remaining capacity. Use it when the Operations Center shows saturation, NotReady nodes, disk growth, or unexplained application latency.

> This dashboard needs the collector `hostmetrics` receiver (`system.*` scrapers: CPU, memory, load, filesystem, paging, disk, network) plus Kubernetes node metrics from `kubeletstats` and `k8s_cluster`.

### Cluster health

**Kubernetes nodes ready %**, **Healthy nodes**, and **Unhealthy nodes (NotReady)** — the same readiness roll-up shown in Operations Center.
- **What they read:** `k8s.node.condition_ready` in `default.otel_metrics_gauge`.
- **How they are calculated:** Latest readiness per `ResourceAttributes['k8s.node.name']`, then ready/total and ready/not-ready counts.
- **Q: How should I read it?** Anything below 100% nodes ready is an infrastructure incident until proven otherwise. Start with the per-node table below.

**Nodes - status & uptime** — latest node roster.
- **What it reads:** `k8s.node.condition_ready` from `default.otel_metrics_gauge`; `k8s.node.uptime` from `default.otel_metrics_sum`.
- **How it is calculated:** Over the last hour, the SQL takes latest readiness and uptime per node, formats status as Ready/Not Ready and uptime as a readable duration.
- **Q: What should I look for?** Not Ready first, then suspiciously short uptime. Short uptime often explains recent pod churn. For per-node CPU and memory, use the **Hosts - CPU, memory, load** table below — the appliance reports those as host metrics, not node metrics.

### Node health (hosts)

**Host CPU busy %** — per-host non-idle CPU over time.
- **What it reads:** `system.cpu.utilization` with `Attributes['state']` and `Attributes['cpu']`.
- **How it is calculated:** Non-idle CPU states are summed per core and scrape, then averaged by host and interval.
- **Q: What is unhealthy?** Sustained high busy means the host has little CPU headroom. Confirm with load average before assuming CPU is the bottleneck.

**1-minute load average (vs CPU cores)** — run-queue pressure per host.
- **What it reads:** `system.cpu.load_average.1m` in `default.otel_metrics_gauge`.
- **How it is calculated:** The tile averages `Value` by host and interval.
- **Q: Why pair this with CPU busy?** Load above the core count means work is waiting for CPU or uninterruptible I/O. High load with moderate CPU can indicate disk stalls.

**Host memory used %** — RAM utilization per host.
- **What it reads:** `system.memory.utilization` in `default.otel_metrics_gauge`.
- **How it is calculated:** `avgIf(Value, Attributes['state'] = 'used')` by host and interval.
- **Q: What is unhealthy?** Sustained usage above ~85% leaves no room for burst allocations, and the kernel starts reclaiming aggressively. Pair it with **Free memory per host (GB)** in Capacity headroom.

**Inode used % per volume** — inode exhaustion per mounted volume.
- **What it reads:** `system.filesystem.inodes.usage` in `default.otel_metrics_sum`.
- **How it is calculated:** Split by `state`, so `sumIf(Value, state = 'used') / sum(Value)` per host+mountpoint and interval.
- **Q: Why watch inodes separately from disk space?** A volume can be nowhere near full on bytes and still fail every write because it has run out of inodes. This is a real ClickHouse failure mode — a table with many small parts creates millions of tiny files.

**Hosts - CPU, memory, load** — hottest hosts in a table.
- **What it reads:** The same CPU, memory, and load metrics as the charts above.
- **How it is calculated:** Separate CPU, memory, and load subqueries are joined by host, formatted as percentages/load, and ordered by CPU busy descending.
- **Q: What is it for?** A fleet scan. Pick the hottest host, then check disk and network on that same host.

### Storage health

**Filesystem used % per volume** and **Free filesystem capacity per volume (GB)** — disk space by mounted volume.
- **What they read:** `system.filesystem.usage` in `default.otel_metrics_sum`.
- **How they are calculated:** The metric is split by `state` (`used` / `free` / `reserved`), so total capacity is the sum of all states. Used percent is `sumIf(Value, state='used') / sum(Value)` per host+mountpoint. Free GB uses `avgIf(Value, state='free') / 1e9` — an average, not a sum, because it is an absolute byte value rather than a ratio.
- **Q: What is unhealthy?** High usage with low free GB is urgent. Full volumes stop logging, image pulls, and database writes. Because this is **per volume**, a full `/var/lib/containerd` shows up on its own instead of being averaged away by an empty root filesystem.

**Disk IOPS (read / write, per host)** — disk operations per second.
- **What it reads:** `system.disk.operations` in `default.otel_metrics_sum`, grouped by `host.name`, `Attributes['device']`, and `Attributes['direction']`.
- **How it is calculated:** Per-device cumulative counters are converted to deltas with `Value - lagInFrame(Value)`, clamped at zero, summed, and divided by `{intervalSeconds}`.
- **Q: How should I read it?** High IOPS is not bad by itself; it is context for latency. High IOPS with rising disk latency means the storage layer is saturated.

**Disk latency (ms, per host · direction)** — average time per read/write operation.
- **What it reads:** `system.disk.operation_time` and `system.disk.operations` from `default.otel_metrics_sum`.
- **How it is calculated:** The dashboard computes deltas for operation time and operation count, then returns `operation_time_delta / operations_delta * 1000`.
- **Q: What is unhealthy?** A rising read or write latency line explains slow applications even when CPU is fine. Pair it with Disk I/O and Network I/O to separate local storage from network storage effects.

**Disk I/O (bytes/sec)** — disk throughput per host and direction.
- **What it reads:** `system.disk.io` in `default.otel_metrics_sum`.
- **How it is calculated:** Counter deltas are grouped by host and direction, summed, and divided by the interval length.
- **Q: How should I use it?** Throughput at a sustained ceiling indicates a bandwidth-bound disk. Throughput low but latency high points to device contention or errors.

### Network health

**Network I/O (bytes/sec)** — receive/transmit throughput.
- **What it reads:** `system.network.io` in `default.otel_metrics_sum` by host, device, and direction.
- **How it is calculated:** The tile converts cumulative byte counters to per-second deltas, grouped as `host · direction`.
- **Q: What is healthy?** Traffic should follow expected load. A sudden drop to zero on one host can indicate an interface or routing issue.

**Network packets dropped / sec (per host)** and **Network interface errors / sec (per host)** — packet loss and interface-level failures.
- **What they read:** `system.network.dropped` and `system.network.errors` in `default.otel_metrics_sum`.
- **How they are calculated:** Both use the same counter-delta pattern as Network I/O, grouped by host and direction.
- **Q: What is unhealthy?** Dropped packets or interface errors above zero during an incident are strong evidence of network trouble. Correlate with application latency and Kubernetes events.

### Capacity planning

**CPU headroom % (100 - cluster busy)** and **Memory headroom % (100 - used)** — remaining cluster-level compute capacity.
- **What they read:** `system.cpu.utilization` and `system.memory.utilization` in `default.otel_metrics_gauge`.
- **How they are calculated:** CPU headroom is `1 - avg(non_idle_cpu)`. Memory headroom is `1 - avgIf(Value, Attributes['state'] = 'used')`.
- **Q: How should I read it?** Headroom trending toward zero means the cluster is out of safe capacity. If headroom is low, check which hosts and namespaces are consuming it before adding load.

**Free memory per host (GB)** — absolute free RAM per host.
- **What it reads:** `system.memory.usage` in `default.otel_metrics_sum`.
- **How it is calculated:** `avgIf(Value, Attributes['state'] = 'free') / 1e9` per host and interval.
- **Q: Why not only use memory used %?** A percentage hides scale — 10% free is comfortable on 128 GB and fatal on 4 GB. Absolute free memory is what predicts eviction and OOM behavior.

**Disk free % per volume over time** — remaining filesystem capacity ratio.
- **What it reads:** `system.filesystem.usage` in `default.otel_metrics_sum`.
- **How it is calculated:** Per host+mountpoint and interval, `sumIf(Value, state='free') / sum(Value)`.
- **Q: What should I watch?** A steady downward slope is the planning signal. A cliff means a workload or ClickHouse table started writing much faster than expected.

---
## 3. Kubernetes

**Data source:** Kubernetes metrics  ·  **Filters:** Namespace  ·  **Tier:** Default
**Purpose:** Cluster, namespace, workload, and limit-utilization health. Use it when pods are unhealthy, restarts are rising, a namespace is noisy, or containers are close to CPU/memory limits.

> This dashboard needs `kubeletstats` and `k8s_cluster` metrics. The Namespace filter applies to compatible pod, namespace, and container tiles.

### Cluster overview

**Kubernetes nodes ready %** — percentage of nodes reporting Ready.
- **What it reads:** `k8s.node.condition_ready` in `default.otel_metrics_gauge`.
- **How it is calculated:** Latest readiness per node, then `ready / total`.
- **Q: What is healthy?** 100%. Anything lower means pods may be rescheduled, evicted, or unable to run on the affected node.

**Host CPU utilization %** and **Host memory utilization %** — node resource usage over time.
- **What they read:** `system.cpu.utilization` and `system.memory.utilization` in `default.otel_metrics_gauge`.
- **How they are calculated:** CPU sums non-idle states per core and scrape, then averages by host and interval. Memory uses `avgIf(Value, Attributes['state'] = 'used')`.
- **Q: Why host metrics on a Kubernetes dashboard?** The appliance's collector reports node-level CPU and memory through the `hostmetrics` receiver, not `kubeletstats`. One host maps to one node here, so these are the node's CPU and memory — just sourced from the receiver that actually emits them.

**Filesystem used % per volume** — per-volume filesystem utilization.
- **What it reads:** `system.filesystem.usage` in `default.otel_metrics_sum`.
- **How it is calculated:** Per host+mountpoint and interval, `sumIf(Value, state='used') / sum(Value)`.
- **Q: Why monitor it here?** Pods fail in surprising ways when node disks fill: image pulls fail, logs cannot be written, and local storage can disappear.

**Nodes - status & uptime** — current node table.
- **What it reads:** `k8s.node.condition_ready` and `k8s.node.uptime`.
- **How it is calculated:** Latest values from the last hour are grouped by node and formatted.
- **Q: What should I do next?** Investigate Not Ready nodes first, then nodes with very short uptime.

### Namespace overview

**Namespace CPU usage (cores)** and **Namespace memory usage** — aggregate pod resources by namespace.
- **What they read:** `k8s.pod.cpu.usage` and `k8s.pod.memory.usage` in `default.otel_metrics_gauge`.
- **How they are calculated:** Each query averages usage per pod and interval, then sums pod usage by `ResourceAttributes['k8s.namespace.name']`.
- **Q: What is it for?** Identifying which tenant, application, or system namespace is consuming capacity. A namespace jump often explains cluster-level saturation.

**Namespaces - phase, CPU, memory** — current namespace roster.
- **What it reads:** Pod CPU/memory usage plus `k8s.namespace.phase`.
- **How it is calculated:** Pod CPU and memory are summed by namespace over the last hour; namespace phase is the latest `k8s.namespace.phase` value and is displayed as Active, Terminating, or Unknown.
- **Q: How should I read it?** Terminating namespaces that still consume CPU or memory can indicate stuck resources. The CPU ordering shows where to start capacity investigations.

### Workload health

**Deployment availability (ready / desired)** — ready replicas versus desired replicas.
- **What it reads:** `k8s.deployment.available` and `k8s.deployment.desired` in `default.otel_metrics_gauge`.
- **How it is calculated:** The standard chart takes the latest `Value` for available and desired, grouped by `namespace/deployment`.
- **Q: What is healthy?** Available should match desired. A gap means rollout, scheduling, image pull, readiness probe, or crash-loop trouble.

**Pods by phase (count)** and **Pods not Running** — pod lifecycle summary.
- **What they read:** `k8s.pod.phase` in `default.otel_metrics_gauge`.
- **How they are calculated:** Latest pod phase is mapped to Pending, Running, Succeeded, Failed, or Unknown. The count table groups by phase; the number tile counts phases not in Running/Succeeded `(2, 3)`.
- **Q: How should I read it?** Running should dominate. Pending means unscheduled; Failed means terminated unsuccessfully; Unknown can indicate node communication problems.

**Container restarts (selected range)** and **Top pods by restarts** — crash-loop indicators.
- **What they read:** `k8s.container.restarts` in `default.otel_metrics_gauge`.
- **How they are calculated:** The number tile sums `max(Value) - min(Value)` per pod over the selected range. The table takes latest restarts per namespace/pod, filters `restarts > 0`, and orders descending.
- **Q: Which should I use first?** The number tells you whether restarts happened in the window; the table tells you which pod to inspect.

**Pods - status & resources** — detailed pod triage table.
- **What it reads:** `k8s.pod.phase`, `k8s.pod.cpu_limit_utilization`, `k8s.pod.memory_limit_utilization`, `k8s.pod.memory.usage`, `k8s.container.restarts`, and `k8s.pod.uptime`.
- **How it is calculated:** Latest values from the last hour are grouped by pod, phase is translated to text, CPU/memory limit utilization are formatted as percentages, memory is formatted as bytes, uptime as age, and rows are ordered by restarts then CPU/limit.
- **Q: Which columns matter most?** Restarts, then CPU/limit and Mem/limit. High restarts plus short age confirms a crash loop; memory near 100% predicts an OOM kill.

### Cluster utilization (vs limits)

**Pod CPU vs limit %** and **Pod memory vs limit %** — pod-level pressure against configured limits.
- **What they read:** `k8s.pod.cpu_limit_utilization` and `k8s.pod.memory_limit_utilization`.
- **How they are calculated:** The standard charts take `max(Value)` grouped by pod.
- **Q: What is unhealthy?** CPU near 100% means Kubernetes may throttle the pod. Memory near 100% means the pod is close to termination if usage grows.

**Container CPU vs limit %** and **Container memory vs limit %** — container-level pressure.
- **What they read:** `k8s.container.cpu_limit_utilization` and `k8s.container.memory_limit_utilization`.
- **How they are calculated:** The SQL averages `Value` per interval for each `namespace/pod/container` series.
- **Q: How is this different from pod utilization?** It pinpoints the hot container inside a multi-container pod. This is the right chart when the pod is unhealthy but only one sidecar or worker is responsible.

**Host memory saturation %** — worst host memory saturation.
- **What it reads:** `system.memory.utilization` in `default.otel_metrics_gauge`.
- **How it is calculated:** Latest `avgIf(Value, Attributes['state'] = 'used')` per host, then the maximum across hosts.
- **Q: How should I read it?** A high value means the cluster's weakest node is memory pressured. If this is high while one namespace is using most memory, that namespace is the first capacity target.

**Containers - utilization vs limit / request** — per-container table of limit/request pressure.
- **What it reads:** `k8s.container.cpu_limit_utilization`, `k8s.container.cpu_request_utilization`, `k8s.container.memory_limit_utilization`, `k8s.container.memory_request_utilization`, and `container.uptime`.
- **How it is calculated:** Latest values from the last hour are grouped by namespace/pod/container, joined to latest uptime, formatted as percentages, and ordered by CPU/limit.
- **Q: What should I do next?** Containers near 100% of limit need tuning or more capacity. Containers far above request but below limit may be noisy neighbors and should have requests adjusted.

---
## 4. Services (RED)

**Data source:** Traces  ·  **Filters:** Service  ·  **Tier:** Default
**Purpose:** The application reliability and performance view. RED stands for **Rate**, **Errors**, and **Duration**; the SLO section translates those failures into a 99.9% availability target and error-budget burn.

> This dashboard requires application traces with OpenTelemetry server spans in `default.otel_traces`.

### Rate & errors

**Server request count over time, by service** — request throughput.
- **What it reads:** `default.otel_traces`, using `SpanKind` and `ServiceName`.
- **How it is calculated:** The standard chart counts spans where `SpanKind:Server`, grouped by `ServiceName` over time.
- **Q: How should I read it?** A service line falling to zero means it stopped receiving requests. A sudden spike may be demand, a retry storm, or a load balancer change.

**Error rate %** — failed server requests by service.
- **What it reads:** Server spans in `default.otel_traces`, using `StatusCode` and `ServiceName`.
- **How it is calculated:** It counts errors where `SpanKind:Server AND StatusCode:Error` and total requests where `SpanKind:Server`, grouped by service, then displays errors/total.
- **Q: What is healthy?** Usually low and stable. Rising error percentage is more important than raw count because it normalizes for traffic.

### Latency & error breakdown

**Server latency percentiles (p50 / p95 / p99)** — typical, slow, and worst-tail latency.
- **What it reads:** `Duration` from server spans in `default.otel_traces`.
- **How it is calculated:** The chart computes percentiles over `Duration / 1000000000`, converting nanoseconds to seconds.
- **Q: Why three percentiles?** p50 is the typical request; p95 and p99 expose the slow tail. If p50 is flat and p99 rises, only a subset of requests is slow.

**Errors by status message** — error categories.
- **What it reads:** Error server spans in `default.otel_traces`, grouped by `StatusMessage`.
- **How it is calculated:** It counts spans matching `SpanKind:Server AND StatusCode:Error` by status message.
- **Q: How should I use it?** A dominant segment points to one failure mode to investigate first. Many small segments suggest broad instability.

### Slow routes & distribution

**Slowest routes (p95) - min 20 requests** — worst HTTP routes by p95.
- **What it reads:** `default.otel_traces`, using `ServiceName`, `SpanAttributes['http.route']`, `Duration`, and `SpanKind`.
- **How it is calculated:** For server spans with a non-empty route, it groups by service and route, computes p95 and p50 in milliseconds, counts requests, keeps only routes with at least 20 requests, and orders by p95 descending.
- **Q: How should I use it?** Start with the top route, then open traces for that service/route. The p50 column tells you whether all requests are slow or only the tail.

**P95 latency anomaly — last 24h vs 8-day baseline (±3σ band)** — self-calibrating latency detector.
- **What it reads:** Server-span `Duration` from the last 8 days in `default.otel_traces`.
- **How it is calculated:** It creates 5-minute p95 points, computes a rolling baseline and population standard deviation over earlier rows, then displays the last 24 hours with `baseline_ms`, `upper_ms = baseline + 3*sigma`, and `lower_ms` clamped at zero. This tile intentionally ignores the dashboard time picker.
- **Q: What is the shaded band?** Normal behavior for that service/route mix. Points above the upper band are unusually slow relative to recent history, even if the absolute latency is not huge.

**Server latency distribution (heatmap, seconds)** — the full latency shape.
- **What it reads:** `Duration` from server spans.
- **How it is calculated:** It buckets `Duration / 1000000000` and counts spans per bucket.
- **Q: What does this add?** It reveals multiple populations of requests, such as cached versus uncached paths, that averages and single percentiles can hide.

### SLO & error budget

**Availability (SLI = success rate)** — successful server requests divided by total server requests.
- **What it reads:** `StatusCode` from server spans.
- **How it is calculated:** `avg(if(StatusCode = 'Error', 0, 1))` where `SpanKind:Server`.
- **Q: What is healthy?** At or above the 99.9% target. Dips below target consume error budget.

**Error budget remaining (window, SLO 99.9%)** — remaining 0.1% budget for the selected range.
- **What it reads:** `default.otel_traces` server spans.
- **How it is calculated:** The SQL computes `error_ratio = errors / total` and returns `1 - error_ratio / 0.001`.
- **Q: How should I read it?** 1 means no errors in the window; 0 means the selected window has spent its 99.9% budget; negative means it exceeded the budget.

**Multi-window burn rate (SLO 99.9%)** — fixed-window budget burn.
- **What it reads:** `default.otel_traces` server spans over fixed 1h, 6h, 24h, and 3d windows.
- **How it is calculated:** Each row computes `error_ratio / 0.001`, ignoring the dashboard time picker by design.
- **Q: What is bad?** Burn rate above 1 means the service is spending budget faster than sustainable. High 1h burn is an acute incident; high 3d burn is a slower reliability regression.

**Availability over time (target 99.9%)** — success ratio trend.
- **What it reads:** Server spans and `StatusCode`.
- **How it is calculated:** The standard chart counts good spans where `SpanKind:Server AND NOT StatusCode:Error` and total server spans, then plots good/total.
- **Q: What should I correlate it with?** Deployments, dependency incidents, error-rate spikes, and latency anomalies.

---

## 5. Logs

**Data source:** Logs  ·  **Filters:** Service, Severity  ·  **Tier:** Default
**Purpose:** Log triage: volume, error/fatal concentration, recurring signatures, Kubernetes error sources, and a live stream for active investigations. It works even when an application has no tracing.

> This dashboard reads application/container logs from `default.otel_logs`. Kubernetes namespace and pod columns are populated when those resource attributes are present.

### Volume & error rate

**Log volume by severity** — log throughput split by severity.
- **What it reads:** `default.otel_logs`, using `SeverityText`.
- **How it is calculated:** The standard chart counts log rows and groups by severity text.
- **Q: How should I read it?** Overall height is logging volume; the error and fatal portions are the first concern. A sudden volume increase can also be a runaway logger.

**Error & fatal log count over time, by service** — error/fatal trend.
- **What it reads:** `default.otel_logs`, using `SeverityNumber`, `SeverityText`, and `ServiceName`.
- **How it is calculated:** It counts logs matching `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal`, grouped by service over time.
- **Q: What is it for?** Identifying which service began producing errors and when. Use the service filter or click through to narrow the investigation.

### Top errors & patterns

**Top error signatures (normalized) - click a row to open Logs** — recurring error patterns.
- **What it reads:** Error/fatal rows from `default.otel_logs`, using `Body`, `ServiceName`, `SeverityNumber`, and `SeverityText`.
- **How it is calculated:** The SQL replaces long IDs with `<id>` and numbers with `<n>` using `replaceRegexpAll`, groups by service and normalized pattern, counts rows, and orders by count.
- **Q: Why normalize?** It collapses noisy messages like changing IDs, ports, or counts into one stable signature, so the real recurring failure floats to the top.

**Errors & fatals by service (last 24h) - click a row to open Logs** — recent service-level error concentration.
- **What it reads:** `default.otel_logs` error/fatal rows from the fixed last 24 hours.
- **How it is calculated:** It groups by `ServiceName`, separately counts errors (`SeverityNumber = 17` or text `error`) and fatals (`SeverityNumber = 21` or text `fatal`), records `max(Timestamp)` as last seen, and orders by total errors plus fatals.
- **Q: How should I use it?** This is the fastest way to find the noisiest service now. Click a row to open the matching logs.

### Live stream

**Live error stream - click a row for full log detail** — recent matching log rows.
- **What it reads:** `Timestamp`, `SeverityText`, `ServiceName`, `ResourceAttributes['k8s.namespace.name']`, `ResourceAttributes['k8s.pod.name']`, and `Body` from `default.otel_logs`.
- **How it is calculated:** It is a log search filtered by `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal`.
- **Q: What is it for?** Following an active incident in real time. Use it after a top signature or service has identified the failing component.

**Top Kubernetes error sources (namespace / pod) - click a row to open Logs** — where error logs originate.
- **What it reads:** Error/fatal rows in `default.otel_logs`, using Kubernetes namespace and pod resource attributes plus `ServiceName`.
- **How it is calculated:** It groups by namespace, pod, and service, counts matching errors/fatals, and orders by count.
- **Q: What is healthy?** No dominant noisy pod. If one pod is responsible for most errors, switch to **Kubernetes** for restarts, resource limits, and phase.

**Log error rate %**, **Total logs (selected range)**, and **Error + fatal logs (selected range)** — summary counters.
- **What they read:** `default.otel_logs`, using severity number/text.
- **How they are calculated:** Total logs is `count(*)`. Error + fatal logs is `sum(if(SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal'), 1, 0))`. Log error rate is the same condition averaged across all log rows.
- **Q: Why show all three?** Rate shows severity normalized by volume; total logs shows ingestion volume; error+fatal count shows absolute blast radius.

---

## 6. Supportability

**Data source:** Traces, Logs, Kubernetes metrics/events  ·  **Filters:** Service, Namespace, Severity  ·  **Tier:** Default
**Purpose:** A support and CSS triage board. It recomputes alert-like conditions live, then lines up the likely causes: restarts, warning events, top signatures, affected services, Kubernetes error sources, and live logs.

> There is no separate alert-state store. The alert-condition tiles are live calculations over the selected range, not a historical alert console.

### Alert conditions (recomputed live)

**Server error rate (%)** — trace-based request failure ratio.
- **What it reads:** `StatusCode` and `SpanKind` from `default.otel_traces`.
- **How it is calculated:** `avg(if(StatusCode = 'Error', 1, 0))` where `SpanKind = 'Server'`.
- **Q: What should I do if it is high?** Open **Services (RED)** for the affected service's error rate, latency, slow routes, and SLO burn.

**Log error rate (%)** — log-based failure ratio.
- **What it reads:** `SeverityNumber` and `SeverityText` from `default.otel_logs`.
- **How it is calculated:** It averages the condition `SeverityNumber >= 17 OR lower(SeverityText) IN ('error','fatal')`.
- **Q: Why keep it next to trace errors?** Some failures only appear in logs. If log rate is high and trace rate is low, the problem may be startup, background worker, or infrastructure noise rather than request handling.

**Pods not Running** — unhealthy pod phase count.
- **What it reads:** `k8s.pod.phase` in `default.otel_metrics_gauge`.
- **How it is calculated:** Latest phase per pod is counted when not Running or Succeeded (`NOT IN (2, 3)`).
- **Q: What is healthy?** Zero. Non-zero means move immediately to the failure-tracking section and Kubernetes workload tables.

**Container restarts (selected range)** — new restarts during the selected window.
- **What it reads:** `k8s.container.restarts` in `default.otel_metrics_gauge`.
- **How it is calculated:** Sum of `max(Value) - min(Value)` per pod over the selected range.
- **Q: Why is this an alert condition?** Restarts are often the clearest symptom of crashes, OOMKills, failed probes, or dependency failures.

### Failure tracking

**Top pods by restarts** — restart leaders.
- **What it reads:** Latest `k8s.container.restarts` by namespace and pod.
- **How it is calculated:** It takes `argMax(Value, TimeUnix)` per namespace/pod, filters rows with restarts above zero, and orders descending.
- **Q: How should I use it?** Start with the top pod. Then check its logs, pod resource limits, and Kubernetes events.

**Warning events (in range)** and **Top event reasons** — Kubernetes warning context.
- **What they read:** k8sobjectsreceiver event records in `default.otel_logs`, parsing `Body` JSON.
- **How they are calculated:** Warning events counts `object.type = 'Warning'`. Top event reasons groups by `object.reason` and `object.type`, counts, and orders by count.
- **Q: What is this for?** Events explain why Kubernetes acted: `BackOff`, `Unhealthy`, `FailedScheduling`, `FailedMount`, and `Evicted` are often the root-cause breadcrumbs behind restarts and non-running pods.

### Troubleshooting

**Top error signatures (normalized) - click a row to open Logs** — recurring error patterns.
- **What it reads:** Error/fatal log rows from `default.otel_logs`.
- **How it is calculated:** The SQL normalizes `Body` by replacing IDs and numbers, groups by `ServiceName` and normalized signature, and counts rows.
- **Q: What should I do next?** Click the top signature to inspect examples, then correlate timestamp and service with trace errors or pod restarts.

**Errors & fatals by service (last 24h) - click a row to open Logs** — recent service concentration.
- **What it reads:** Error/fatal logs from the fixed last 24 hours.
- **How it is calculated:** It counts errors and fatals separately by service and records the most recent timestamp.
- **Q: Why fixed 24h?** It gives support a stable "what is noisy now" table independent of an accidentally narrow dashboard time picker.

**Top Kubernetes error sources (namespace / pod) - click a row to open Logs** — noisy pods/namespaces.
- **What it reads:** Error/fatal logs grouped by Kubernetes namespace, pod, and service.
- **How it is calculated:** It counts matching rows in the selected range and orders by count.
- **Q: What is the next move?** If one pod dominates, open **Kubernetes** for status/resources and **Logs** for its live stream.

**Live error stream - click a row for full log detail** — raw investigation feed.
- **What it reads:** Recent error/fatal rows from `default.otel_logs`, including timestamp, severity, service, namespace, pod, and body.
- **How it is calculated:** It is a log search filtered to `SeverityNumber:>=17 OR SeverityText:error OR SeverityText:fatal`.
- **Q: When should I use it?** During an active call or bridge, after the summary tiles have narrowed the affected service or pod.

---
## 7. Observability Platform Health

**Data source:** Collector self-metrics, ClickHouse metrics, ClickHouse system tables  ·  **Filters:** Collector  ·  **Tier:** Advanced
**Purpose:** The health of the observability stack itself: OpenTelemetry Collector ingestion and queues, ClickHouse storage/availability, and dashboard query performance. Use it when other dashboards are unexpectedly empty, delayed, or slow.

> This is the only advanced-tier dashboard. It requires the metrics-scraper add-on: collector self-telemetry scraped from the collector `:8888` endpoint, ClickHouse server metrics scraped into OTel, and permission for the HyperDX ClickHouse user to read `system.query_log` when query-performance tiles are used. If this dashboard is empty, that optional scraping is probably not enabled.

### Telemetry ingestion

**Refused spans (window)**, **Refused log records (window)**, and **Refused metric points (window)** — data the collector rejected.
- **What they read:** `otelcol_receiver_refused_spans_total`, `otelcol_receiver_refused_log_records_total`, and `otelcol_receiver_refused_metric_points_total` in `default.otel_metrics_sum`.
- **How they are calculated:** For each collector `service.instance.id`, the SQL computes `max(Value) - min(Value)` over the selected range and sums the deltas.
- **Q: What is healthy?** Zero. Refused telemetry means data was dropped before it entered the pipeline, usually from overload or receiver pressure.

**Spans: accepted vs refused vs failed (per interval)** — trace ingest health.
- **What it reads:** `otelcol_receiver_accepted_spans_total`, `otelcol_receiver_refused_spans_total`, and `otelcol_receiver_failed_spans_total`.
- **How it is calculated:** Cumulative counters are bucketed by interval and collector instance, converted to non-negative deltas with `lagInFrame`, then summed by kind: accepted, refused, failed.
- **Q: How should I read it?** Accepted should dominate. Refused or failed above zero means trace data is missing from service dashboards.

**Logs: accepted vs refused vs send-failed (per interval)** — log ingest and export health.
- **What it reads:** `otelcol_receiver_accepted_log_records_total`, `otelcol_receiver_refused_log_records_total`, and `otelcol_exporter_send_failed_log_records_total`.
- **How it is calculated:** Same counter-delta pattern, with kinds accepted, refused, and send-failed.
- **Q: What is the difference?** Refused means the collector rejected logs. Send-failed means it accepted logs but could not deliver them to the backend.

**Metric points: accepted vs refused (per interval)** — metrics ingest health.
- **What it reads:** `otelcol_receiver_accepted_metric_points_total` and `otelcol_receiver_refused_metric_points_total`.
- **How it is calculated:** Per-instance cumulative counters are converted to interval deltas and summed by accepted/refused.
- **Q: Why watch this?** If metric points are refused, Infrastructure and Kubernetes charts can look healthy only because data is missing.

### Pipeline health

**Exporter queue utilization %** — fullest collector exporter queue.
- **What it reads:** `otelcol_exporter_queue_size` and `otelcol_exporter_queue_capacity` in `default.otel_metrics_gauge`.
- **How it is calculated:** For each collector instance, latest queue size is divided by latest capacity; the tile returns the maximum utilization.
- **Q: What is unhealthy?** A queue approaching 100% means the collector is receiving data faster than it can export it. If it fills, refusals and send failures follow.

**Exporter queue size vs capacity** — queue depth trend.
- **What it reads:** The same queue size and capacity gauge metrics.
- **How it is calculated:** The standard chart plots max queue size and max capacity over time.
- **Q: How should I read it?** The gap between size and capacity is your buffer. A closing gap is backpressure.

**Exporter sent spans (per interval)** — trace export throughput.
- **What it reads:** `otelcol_exporter_sent_spans_total` in `default.otel_metrics_sum`.
- **How it is calculated:** The cumulative counter is converted to interval deltas per collector instance and summed.
- **Q: What is healthy?** Sent spans should track accepted spans. If accepted rises but sent stays flat, the collector is backed up or cannot export.

**Collector CPU (cores)** — collector CPU usage.
- **What it reads:** `otelcol_process_cpu_seconds_total` in `default.otel_metrics_sum`.
- **How it is calculated:** The SQL computes counter deltas per interval and divides by `{intervalSeconds}` to express CPU cores.
- **Q: Why monitor it?** A CPU-starved collector falls behind, fills queues, and starts refusing data.

**Collector memory (RSS / heap)** — collector process memory.
- **What it reads:** `otelcol_process_memory_rss_bytes` and `otelcol_process_runtime_heap_alloc_bytes` in `default.otel_metrics_gauge`.
- **How it is calculated:** The standard chart plots max RSS and heap allocation values over time.
- **Q: What is unhealthy?** Memory trending toward the collector limit predicts OOM restarts and telemetry gaps.

### ClickHouse storage & availability

**Running queries** — current active query count.
- **What it reads:** `ClickHouseMetrics_Query` in `default.otel_metrics_gauge`.
- **How it is calculated:** Latest values are taken per ClickHouse `service.instance.id` and summed.
- **Q: How should I read it?** Some running queries are normal. A sustained high count with rising query duration means dashboards or ingest are competing for database resources.

**Failed queries (window)** — ClickHouse query failures over the selected range.
- **What it reads:** `ClickHouseProfileEvents_FailedQuery` in `default.otel_metrics_sum`.
- **How it is calculated:** Per-instance `max(Value) - min(Value)` deltas are summed.
- **Q: What is healthy?** Zero or explainable failures. If it rises, check **Top errors (from query_log)** in the Dashboard query performance section.

**Disk free %** — lowest ClickHouse disk free ratio.
- **What it reads:** ClickHouse `system.disks`.
- **How it is calculated:** `min(free_space / total_space)` for disks with `total_space > 0`.
- **Q: Why minimum?** The fullest disk is the limiting disk. Low free space threatens inserts and merges even if other disks have room.

**Current tracked memory** — ClickHouse memory tracking.
- **What it reads:** `ClickHouseMetrics_MemoryTracking` in `default.otel_metrics_gauge`.
- **How it is calculated:** Latest values per ClickHouse instance are summed.
- **Q: What should I watch?** A rising value near server limits predicts memory-limit query failures.

**Queries (per interval)** — ClickHouse query volume.
- **What it reads:** `ClickHouseProfileEvents_Query` in `default.otel_metrics_sum`.
- **How it is calculated:** Per-instance cumulative counters are converted to interval deltas and summed.
- **Q: What is it for?** Distinguishing real database load from query slowness. High p99 during normal query volume points to expensive queries or storage pressure.

**Data retention & size by table (system.parts)** — storage footprint and retention span.
- **What it reads:** ClickHouse `system.parts` for active parts where `database = 'default'` and table name matches `otel_%`.
- **How it is calculated:** It groups by table, sums `bytes_on_disk` and rows, reports oldest/newest data from `min_time`/`max_time`, and calculates `dateDiff('day', min(min_time), max(max_time))`.
- **Q: How should I read it?** The top table by disk is your biggest retention/cost driver. Short or unexpected retention span can indicate TTL, ingest gaps, or table growth patterns to review.

### Dashboard query performance

**Query duration - p95 / p99** — dashboard/backend query latency.
- **What it reads:** ClickHouse `system.query_log` rows with `type = 'QueryFinish'`.
- **How it is calculated:** It groups `event_time` by interval and computes `quantile(0.95)(query_duration_ms) / 1000` and `quantile(0.99)(query_duration_ms) / 1000`.
- **Q: What is unhealthy?** Rising p99 means some dashboard queries are slow even if most are fine. Correlate with query volume, running queries, and disk free.

**Failed queries (selected window)** — query failures from ClickHouse metrics.
- **What it reads:** `ClickHouseProfileEvents_FailedQuery` in `default.otel_metrics_sum`.
- **How it is calculated:** It sums non-negative selected-window deltas per ClickHouse instance.
- **Q: Why repeat this tile?** It anchors the query-performance section: first see whether failures happened, then use query_log errors to identify why.

**Top errors (from query_log)** — most frequent database exceptions.
- **What it reads:** `system.query_log` rows with `type >= 2` and non-zero `exception_code`.
- **How it is calculated:** It groups by `exception_code`, counts errors, and shows a recent sample exception via `substring(argMax(exception, event_time), 1, 500)`.
- **Q: How should I use it?** The error code tells you whether the problem is memory, timeout, syntax, permissions, or storage. Use the sample exception to find the failing dashboard query.

---

## Quick-Reference Playbook

| Situation | Start here | Then |
| --- | --- | --- |
| Is anything wrong right now? | Operations Center | Follow the unhealthy roll-up to Services, Logs, Kubernetes, or Infrastructure |
| The application feels slow | Services (RED) | Slowest routes → latency anomaly → traces |
| Are we meeting our reliability target? | Services (RED) | Availability, error budget remaining, then multi-window burn rate |
| Errors started after a deployment | Logs | Top error signatures → live error stream |
| A pod is unhealthy or restarting | Kubernetes | Pods by phase → Pods status/resources → Top pods by restarts |
| A namespace is consuming too much capacity | Kubernetes | Namespace CPU/memory → Containers utilization vs limit/request |
| A node or host looks saturated | Infrastructure | Nodes/hosts tables → CPU/load → memory → disk/network |
| Disk is filling or I/O is slow | Infrastructure | Filesystem usage/free capacity → disk IOPS/latency/I/O |
| Network symptoms appear | Infrastructure | Network I/O → dropped packets → interface errors |
| Support needs an incident triage page | Supportability | Alert conditions → failure tracking → troubleshooting rows |
| A dashboard is unexpectedly empty | Observability Platform Health | Collector refused/failed metrics → queue utilization → scraper/export health |
| Dashboard queries or ClickHouse are slow | Observability Platform Health | Query duration p95/p99 → failed queries → top query_log errors |

> **A useful rule of thumb:** if a chart is empty, first determine whether the dashboard is at fault or whether that data pipeline is simply not yet enabled. Running `preflight.ps1` answers this immediately.
