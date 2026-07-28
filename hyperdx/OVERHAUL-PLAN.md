# HyperDX Dashboard Overhaul — Gap Analysis & Plan

**Status:** proposal for review. No templates have been changed.
**Author basis:** full tile inventory of all 11 current HyperDX dashboards + the
`requirements.json` support matrix, mapped against the customer requirements list
("Configure and Setup AldoTel").

---

## How to read this document

Each requested item is marked with one of:

| Mark | Meaning |
|------|---------|
| ✅ | **Have it** — a tile exists today (dashboard named). |
| 🟡 | **Partial / extend** — related tile exists or the signal is a proxy; needs work. |
| ➕ | **Addable** — the underlying metric already flows; just needs a new tile. |
| ⛔ | **Not possible today** — telemetry isn't collected, or it's an app/portal feature, not a dashboard. |

---

## Three realities that shape the whole overhaul

1. **Data source = OTel receivers only.** Every tile must be built from what already
   lands in ClickHouse: `hostmetrics`, `kubeletstats`, `k8s_cluster`, `k8sobjects`
   (events), application OTLP traces/logs, and — **advanced tier only** — ClickHouse
   and OTel-collector self-metrics. If a receiver isn't enabled, the tile is dark. The
   `default` vs `advanced` tier split in `requirements.json` already encodes this.

2. **Several SQL snippets in the requirements list reference metrics that don't exist
   or are mislabeled.** They cannot be pasted as-is. See
   [Appendix A — SQL corrections](#appendix-a--sql-corrections-in-the-requirements-list).

3. **The "Landing Page (Operations Center)" is mostly an application shell, not a
   dashboard.** Action buttons (*Download Logs*, *Create Support Package*, *Run ADS
   Notebook*, *Send to Microsoft*) and the *Recent Activity* feed are AldoTel / Azure
   portal features. HyperDX dashboards render charts and tables, not action buttons.
   The **metrics** half of the landing page is buildable; the **actions** half is not.

---

## Current inventory (what exists today)

**Default tier (lights up on any full appliance deploy):**

- **Executive Overview** — cross-cutting roll-up: server error rate, request volume, p95,
  log error rate, nodes-ready %, services-by-error tables, request/error timeline.
- **Host / OS Metrics** — CPU busy %, load avg, memory %, swap %, disk I/O, network I/O,
  per-host table. (`hostmetrics`)
- **Kubernetes — Infrastructure** — nodes (CPU/mem/fs/ready), deployments, pods by phase,
  namespaces, container util vs limits, restarts, cluster events. (`kubeletstats` +
  `k8s_cluster` + `k8sobjects`)
- **Logs — Overview** — volume by severity, error/fatal over time, top signatures,
  new-pattern detection, top K8s error sources, live error stream.
- **Services — RED** — request rate, error %, latency percentiles, slow routes, anomaly
  band, latency heatmap, SLO/error-budget/burn-rate strip. (OTLP traces)

**Advanced tier (opt-in; needs the metrics-scraper add-on):**

- **ClickHouse — Operations** · **ClickHouse — Query Performance & Errors** ·
  **ClickHouse — Storage & MergeTree** · **ClickHouse — Keeper & Replication** ·
  **OTel Collector — Pipeline Health** · **Latency Histograms**.

---

## Section-by-section gap analysis

### 1. Landing Page (Operations Center)

| Requested | Status | Notes |
|---|---|---|
| Cluster health / healthy-unhealthy node count | 🟡 | `Kubernetes nodes ready %` exists; a healthy/unhealthy **count** is a quick add from `k8s.node.condition_ready`. |
| Active alerts | 🟡 / ⛔ | HyperDX has no live alert-state table to query. We ship alert *definitions*, not a fireable feed. Best we can do on a dashboard is a **condition-recompute proxy** (re-evaluate each alert rule as a tile). Not a true alert console. |
| Resource utilization (CPU / Mem / Storage) | ✅ | Covered across host-os + k8s; roll-up numbers addable to a landing tile. |
| Observability platform status | 🟡 | Derivable from collector-health + clickhouse-health (advanced tier). |
| Quick Actions (view/search/download logs, support package, ADS notebook, send to MS) | ⛔ | Portal/app features, not dashboard tiles. |
| Recent Activity (alerts generated, diagnostics collected, logs exported) | ⛔ | No telemetry backs these; portal-side. |

**Verdict:** build a new **Operations Center** overview dashboard = an upgraded Executive
Overview (health score + node counts + util roll-ups + platform status). The
actions/activity feed belongs to the AldoTel app.

### 2. Infrastructure Health

**Compute**

| Requested | Status | Notes |
|---|---|---|
| CPU per node | ✅ | k8s `Node CPU usage (cores; vs allocatable)` + host-os `Host CPU busy %`. |
| CPU cluster aggregate | ➕ | Addable (avg across nodes). Requirements SQL uses `k8s.container.cpu_limit_utilization` — wrong metric for a cluster figure. |
| CPU saturation | 🟡 | True saturation = runqueue/throttling. `load_average.1m` is a proxy; CPU throttle (`container.cpu.throttled`) isn't scraped. |
| Load average | ✅ | host-os `1-minute load average (vs CPU cores)`. |
| Available CPU capacity | ➕ | Derive `allocatable − usage`. Requirements SQL (`container.cpu.usage`, `1−avg`) is invalid. |

**Memory**

| Requested | Status | Notes |
|---|---|---|
| Memory util % per node | ✅ | k8s `Node memory used (vs allocatable)` + host-os `Host memory used %`. |
| Memory util cluster aggregate | ➕ | Addable. Requirements SQL uses pod-level `k8s.pod.memory_limit_utilization` — mislabeled. |
| Available memory (GB) | ✅ / ➕ | `Node memory saturation %` uses `k8s.node.memory.available`; a GB tile is trivial. |
| Memory pressure | 🟡 | `Node memory saturation %` is the real signal. |
| Swap usage (Linux) | ✅ | host-os `Host swap used %` (`system.swap.utilization`). |

**Storage**

| Requested | Status | Notes |
|---|---|---|
| Disk utilization % (node + cluster) | ✅ | k8s `Node filesystem usage %`. |
| Free capacity | ✅ / ➕ | Have usage %; free-GB tile addable from `k8s.node.filesystem.available/capacity`. |
| Disk IOPS (read/write/total) | ➕ | Possible from **`system.disk.operations`** (by direction). Requirements SQL maps `io_time`/`merged` to IOPS — semantically wrong. Needs hostmetrics disk scraper. |
| Read/write latency | 🟡 / ➕ | Derive from `system.disk.operation_time ÷ system.disk.operations`. `k8s.node.disk.read.latency` in the requirements SQL does not exist. |
| Storage health status | ⛔ | `k8s.node.disk.health` isn't emitted by any OTel receiver. Disk/SMART health comes from the storage subsystem (S2D/host), not the pipeline. |

**Network**

| Requested | Status | Notes |
|---|---|---|
| Network throughput | ✅ | host-os `Network I/O (bytes/sec)` (`system.network.io`). |
| Ingress / egress bandwidth | ➕ | Split `system.network.io` by `direction`. |
| Packet loss | ➕ | `system.network.dropped`. |
| Interface errors | ➕ | `system.network.errors`. |
| Network latency | ⛔ | No receiver emits it; needs synthetic probing (absent). |

### 3. ALDO Platform & Control-Plane Health

**Cluster Health:** node availability ✅ (`condition_ready`); failed nodes ➕ (count
NotReady); cluster availability ➕ (derived score); **quorum / etcd health ⛔** (etcd
metrics not scraped); degraded services 🟡 (deployments + events).

**Kubernetes Health:** Ready/NotReady ✅; pod health ✅ (`Pods by phase`, `Pods not
Running`); restart count ✅ (`Container restarts`, `Top pods by restarts`); container
failures 🟡 (restarts/OOM via events); **scheduling failures 🟡** (only via
`FailedScheduling` events — already surfaced by `Top event reasons`); **scheduling
latency ⛔** (scheduler metrics not scraped).

**Control-Plane Services (API latency / request rate / error rate / component status):**
⛔ **by default.** These are `apiserver_*` / `etcd_*` / scheduler metrics that require
scraping the control-plane `/metrics` endpoints via a Prometheus receiver — **not in the
appliance pipeline today.** Enabling them is a **collector-config change**, not just a
dashboard. This is the single biggest "we don't have the data yet" gap.

**Storage & Volume Operations (mount success/fail, provisioning latency, operation
failures):** 🟡 — no CSI / `storage_operation_*` metrics scraped; only inferable from
`FailedMount` / `FailedAttachVolume` **events** (already visible in `Recent events`). No
latency numbers.

### 4. Observability Platform Health — mostly ✅ (advanced tier)

| Requested | Status | Where |
|---|---|---|
| Metrics / logs / trace ingestion rate | ✅ | collector-health `accepted spans/logs/metric points`. |
| Collector health / status | ✅ | collector-health (CPU, memory, in-flight). |
| Queue depth / backpressure / failed exports | ✅ | `Exporter queue utilization %`, `refused`, `send-failed`. |
| ClickHouse availability / query latency / retention / capacity | ✅ | clickhouse-health + queryperf + storage-mergetree. |
| Dashboard query response times / failed dashboard queries | 🟡 / ➕ | Derivable from `system.query_log` (queryperf already reads it), filtered to the HyperDX user. |

This section is largely **already built** — it just lives in the advanced tier.

### 5. Supportability

| Requested | Status | Notes |
|---|---|---|
| Active / critical / warning alerts + trends | 🟡 / ⛔ | Same limit as landing page — no alert-state store. Condition-recompute proxy only. |
| Failed upgrades | ⛔ | Appliance-lifecycle event, not in telemetry. |
| Service crashes | ✅ | Restarts / OOM via k8s (`Top pods by restarts`) + events. |
| Resource exhaustion events | 🟡 | OOMKilled / Evicted from `k8sobjects` events. |
| Recent config changes | ⛔ | Needs an audit-log source (absent). |
| Top errors by frequency | ✅ | logs `Top error signatures`. |
| Log volume anomalies | ✅ | logs `New log patterns in last 24h`. |
| Top failing components | ✅ | logs `Top Kubernetes error sources`. |

### "Top 10" landing metrics

8 of 10 are ready today: Node availability ✅, CPU ✅, Memory ✅, Disk ✅, Pod/container
health ✅, Metrics-ingestion health ✅ (advanced), Cluster health score ➕ (derive), Network
throughput/errors 🟡 (throughput ✅, errors ➕). The two gaps: **API latency/error rate ⛔**
(needs apiserver scrape) and **Active critical alerts 🟡** (proxy only).

---

## Proposed dashboard breakdown

The requested catalog maps cleanly onto a re-organized set. Most of it is **recombining
existing tiles + a handful of new hostmetrics/derived tiles** — not net-new data.

| # | Dashboard | Build type | Source |
|---|-----------|-----------|--------|
| 1 | **Operations Center** (landing roll-up) | New | Upgrade of Executive Overview + derived health score/node counts. |
| 2 | **Infrastructure — Cluster Health** | New (recombine) | `k8s_cluster` node conditions + derived availability. |
| 3 | **Infrastructure — Node Health** | Rename/extend | host-os. |
| 4 | **Infrastructure — Storage Health** | New | hostmetrics disk (IOPS/latency) + k8s filesystem + CH storage. |
| 5 | **Infrastructure — Network Health** | New | hostmetrics network (throughput/errors/drops/direction). |
| 6 | **Infrastructure — Capacity Planning** | New | headroom trends (CPU/mem/disk vs allocatable). |
| 7 | **Kubernetes — Cluster Overview** | Split | top of current k8s-infrastructure. |
| 8 | **Kubernetes — Namespace Overview** | Split | per-namespace tiles from k8s-infrastructure. |
| 9 | **Kubernetes — Workload Health** | Split | deployments/pods/restarts. |
| 10 | **Kubernetes — Cluster Utilization** | Split | util vs allocatable/limits. |
| 11 | **Observability Platform Health** | Rebrand | advanced ClickHouse + collector dashboards. |
| 12 | **Supportability** | New | logs + events + alert-condition proxies. |
| — | **Services — RED, Logs, Latency Histograms** | Keep as-is | — |

---

## Two decisions needed before building

1. **Control-plane metrics (API server, etcd/quorum, scheduler, CSI volumes).**
   Not collected today. Do we **enable additional scrape targets** in the OTel collector
   config (unblocks API latency/rate/errors, quorum, scheduling latency, volume ops), or
   **scope them out** of this overhaul?

2. **"Active alerts" surface.** Do we want a **real alert console** (requires an
   alert-state store queried from a dashboard — outside current HyperDX capability), or
   is a **per-tile condition-recompute proxy** acceptable for now?

---

## Suggested sequencing (once decisions are made)

1. **Phase 1 — no new data:** Operations Center, K8s split (7–10), Network/Storage Health
   from existing hostmetrics, Supportability from logs/events. All buildable now.
2. **Phase 2 — corrected/derived tiles:** cluster aggregates, IOPS/latency, capacity
   headroom (using the corrected SQL in Appendix A).
3. **Phase 3 — needs pipeline change (pending decision 1):** control-plane, volume ops,
   quorum.
4. Regenerate `requirements.json` + `preflight` + docs to match the new dashboard set
   (per the repo's "edit the generator, then regenerate" contract).

---

## Appendix A — SQL corrections in the requirements list

The requirements list embeds SQL that won't work as written. Key issues:

| Requirement tile | Problem in provided SQL | Correct approach |
|---|---|---|
| CPU Utilization (%) Per Node | `avg(Value)*100` on `k8s.node.cpu.usage` returns *cores × 100*, not a %. | Divide usage by node **allocatable** cores, or plot cores vs allocatable (what we already do). |
| CPU Utilization (%) Cluster Aggregate | Uses `k8s.container.cpu_limit_utilization` (container-level) for a cluster figure. | Aggregate node usage ÷ node allocatable across all nodes. |
| CPU Saturation | Uses `system.cpu.load_average.1m` — identical to the Load Average tile. | Use load ÷ core count, or a throttle metric if scraped. |
| Available CPU Capacity | `(1 − avg(Value))*100` on `container.cpu.usage` — not a 0–1 ratio; invalid. | `allocatable − usage`. |
| Memory Util Cluster / Memory Pressure | Both use `k8s.pod.memory_limit_utilization` (pod-level), mislabeled as node/cluster. | Node memory usage ÷ allocatable; `k8s.node.memory.available` for pressure. |
| Disk IOPS (read/write/total) | Maps `system.disk.io_time` → write IOPS and `system.disk.merged` → total IOPS. Wrong metrics; `rate()` isn't a ClickHouse function. | Use `system.disk.operations` by `direction`; compute rate with `runningDifference`/window over the sum series. |
| Read/Write Latency | `k8s.node.disk.read.latency` / `write.latency` do not exist. | Derive `system.disk.operation_time ÷ system.disk.operations`. |
| Storage Health (`k8s.node.disk.health`) | Metric does not exist in any OTel receiver. | Out of scope unless the storage subsystem exports health. |
| `$__fromTime` / `$__toTime` / `$__timeFilter` | Grafana macros — not valid in HyperDX. | HyperDX tiles use `{startDateMilliseconds}` / `{endDateMilliseconds}` params (see existing `sqlTemplate`s). |

> Note: the requirements SQL is written in **Grafana** dialect (`$__timeFilter`,
> `default.otel_*`). The Grafana deliverable can use much of it after metric-name fixes;
> HyperDX tiles need the parameter/param-style rewrite shown above.

---

## Appendix B — metrics confirmed available vs missing

**Available now (default tier):** `k8s.node.cpu.usage`, `k8s.node.memory.usage/available`,
`k8s.node.filesystem.usage/capacity/available`, `k8s.node.condition_ready`,
`k8s.node.uptime`, `k8s.pod.phase`, `k8s.pod.cpu.usage`, `k8s.pod.memory.usage`,
`k8s.pod.{cpu,memory}_limit_utilization`, `k8s.container.restarts`,
`k8s.container.{cpu,memory}_limit_utilization`, `k8s.deployment.available/desired`,
`k8s.namespace.phase`, `container.uptime`; `system.cpu.utilization`,
`system.cpu.load_average.1m`, `system.memory.utilization`, `system.swap.utilization`,
`system.disk.io`, `system.network.io`; k8s events via `k8sobjects`.

**Available but not yet charted (default tier):** `system.disk.operations`,
`system.disk.operation_time`, `system.disk.merged`, `system.network.packets`,
`system.network.errors`, `system.network.dropped`, `system.network.connections`.

**Advanced tier (needs metrics-scraper add-on):** `ClickHouse*`, `otelcol_*`.

**Not collected — would need new scrape targets / sources:** `apiserver_*`, `etcd_*`,
scheduler metrics, CSI/`storage_operation_*`, disk SMART/health, synthetic network
latency, config-change audit log, live alert state.
