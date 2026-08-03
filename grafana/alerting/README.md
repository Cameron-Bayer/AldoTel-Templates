# ClickStack Grafana Alerts

Grafana **unified alerting** rules that watch the same ClickHouse data your
ClickStack dashboards read (`otel_traces`, `otel_logs`, `otel_metrics_gauge`).
Where the HyperDX dashboards are for *investigation*, these alerts are for
*notification* — Grafana evaluates each rule on a schedule and pushes to your
on-call channel (any webhook — Slack, a Teams Workflow, PagerDuty, etc.) when
something breaks.

This pack **complements** the HyperDX alerts pack (`../../hyperdx/alerts`): both watch the
same ClickHouse data, but the two packs cover different signals. This Grafana pack: service
error rate, p95 latency, SLO fast-burn, trace-ingestion stall, pods-not-running, container
restarts, error-log rate, and fatal logs.
The HyperDX pack: collector drops, error rate, SLO fast-burn, ClickHouse disk low.
Run either or both.

---

## What's in the box

| File | Purpose |
|------|---------|
| `alert-rules.yaml` | The 8 platform alert rules (queries + thresholds). |
| `appliance-alert-rules.yaml` | 8 **Azure Local appliance** health rules (see below). |
| `contact-points.yaml` | The alert contact point — a generic webhook (add your URL). |
| `notification-policy.yaml` | Routes ClickStack alerts to that contact point (optional). |

Both rule files load into the same **ClickStack Alerts** folder and route through the
same contact point, so running both gives you 15 rules. They are independent —
delete either file if you only want one set.

### The 8 alerts

| Alert | Source table | Fires when | Default threshold | `for` | Severity |
|-------|--------------|-----------|-------------------|-------|----------|
| Service error rate high | `otel_traces` | a service's server-span error rate is high | > 5 % | 5m | warning |
| Service p95 latency high | `otel_traces` | a service's p95 latency is high | > 2000 ms | 10m | warning |
| SLO error budget fast burn | `otel_traces` | a service burns its 99.9 % budget fast | > 14.4× (1h) | 5m | critical |
| Trace ingestion stalled | `otel_traces` | no spans arrive (pipeline down) | < 1 span / 10m | 10m | critical |
| Pods not Running | `otel_metrics_gauge` | pods stuck outside Running (excludes `Succeeded`) | > 0 pods | 5m | warning |
| Container restarts detected | `otel_metrics_gauge` | containers restart within the window | > 0 restarts / 15m | 5m | warning |
| Error log rate high | `otel_logs` | error+fatal logs surge | > 5 / s | 10m | warning |
| Fatal logs present | `otel_logs` | any fatal log line | > 0 | 5m | critical |

Each alert is multi-dimensional where it makes sense — the service error-rate,
latency, and SLO fast-burn rules fire **per service**, so you get one alert
instance per affected service with the service name in the notification.

The error/fatal-log rules match on `SeverityNumber` (17 = error, 21 = fatal) with a
lowercase-text fallback. The Kubernetes rules chart cumulative counters as
per-series windowed deltas (never `sum(Value)`).

---

## The 7 appliance alerts (`appliance-alert-rules.yaml`)

Appliance-health signals answerable from telemetry the appliance **already collects**
(hostmetrics, kubeletstats, k8s_cluster, container logs). Every rule below was
validated against the metric inventory of a real appliance — see
[What these rules deliberately do NOT cover](#what-these-rules-deliberately-do-not-cover)
for the signals that were intentionally left out rather than shipped inert.

| Alert | Source metric (table) | Fires when | Default threshold | `for` | Severity |
|-------|----------------------|-----------|-------------------|-------|----------|
| Appliance volume critically low | `system.filesystem.usage` (`sum`) | a mounted volume is nearly full | < 5 % free | 5m | critical |
| Appliance volume low | `system.filesystem.usage` (`sum`) | a mounted volume is filling up | < 15 % free | 15m | warning |
| Appliance CPU sustained high | `system.cpu.utilization` (`gauge`) | 15m average non-idle CPU | > 90 % | 1m | warning |
| Appliance memory pressure | `system.memory.utilization` (`gauge`) | 15m average used memory | > 85 % | 1m | warning |
| Appliance VM restarted | `k8s.node.uptime` (`sum`) | uptime counter reset | < 900 s uptime | 1m | warning |
| Service recovered after failure | `k8s.container.restarts` + `k8s.pod.phase` (`gauge`) | pod restarted in window, now Running | > 0 restarts | 0s | info |
| Key Vault service unavailable | `k8s.pod.phase` (`gauge`) | KMS pod outside Running phase | > 0 pods | 5m | critical |

CPU and memory use `for: 1m` because the 15-minute sustain is already applied
**inside the query** — the `for` clause only debounces evaluation jitter.

All rules except *Key Vault* are **multi-dimensional** — one alert instance per
volume or host, with the name in the notification.

### Volume alerts are per-volume, not per-node

`system.filesystem.usage` is split by a `state` attribute (`used` / `free` /
`reserved`), so a volume's capacity is the **sum of all its states**. The rules group
by `host.name` + `mountpoint`, which means a full `/var/lib/containerd` fires on its
own instead of being averaged away by an empty root filesystem. The alert label is
`volume`, not `node`.

### One rule needs your workload name first

`Key Vault service unavailable` identifies its workload by name substring, defaulting
to `moc-kms` — the KMS pod on an Azure Local appliance. If your key-management pod is
named differently, grep `EDIT-ME-WORKLOAD` in `appliance-alert-rules.yaml` and change
it, otherwise the rule will never fire. Matching is case-insensitive
(`positionCaseInsensitive`).

### What these rules deliberately do NOT cover

The observability stack runs **inside** the appliance VM, so it can only see the
appliance. Signals originating on the Azure Local **hosts** — node down, cluster
quorum, S2D storage pool, physical disk / SMART, NIC link and RDMA, time-sync drift,
host-OS login attempts — are out of scope. Those require an OTel collector running on
each node (enrolled via `enroll-emitter.ps1` in the appliance repo) with the
`windowsperfcounters` and `windowseventlog` receivers.

Corollary worth stating plainly: **"appliance VM down" can never be raised from
here.** A stack running inside the VM cannot report that the VM stopped. That alert
has to come from the host cluster or an external watchdog.

Also not covered by these 7: local portal / ARM endpoint probes (need an `httpcheck`
receiver), certificate expiry (needs a `prometheus` receiver scraping cert-manager on
`:9402`), and volume growth trend (needs a derived/rate query).

**Policy engine sync failing** was drafted and then deliberately removed. The
appliance runs no policy pod, service, or deployment, and no log stream carries a
matching `ServiceName` — so the rule was structurally incapable of firing. Shipping
it would have told operators that policy sync was monitored when it was not. If your
deployment does run a policy workload, re-add it as a log-count rule over `otel_logs`
filtered on that workload's `ServiceName`.

---

## Install (customer)

These are **provisioning** files. Grafana loads them from disk at startup — you
do not import them through the UI.

### 1. Point the rules at your ClickHouse datasource

Every query references a datasource by UID: **`clickstack-ch`**. Either

- set your ClickHouse datasource's UID to `clickstack-ch`
  (*Connections → Data sources → your ClickHouse → UID*), **or**
- find/replace `clickstack-ch` in `alert-rules.yaml` **and
  `appliance-alert-rules.yaml`** with your datasource's UID.

If your ClickStack writes to a database other than `default`, also find/replace
`default.` in both rule files.

### 2. Set your notification channel

Open `contact-points.yaml` and replace the placeholder `url` with a webhook URL
for the channel you want — a Slack incoming webhook, PagerDuty, Discord, or any
HTTP endpoint that accepts a POST. Prefer a native email/Slack integration?
Comment out the `webhook` receiver and use one of the examples in that file (or
add any Grafana contact-point type), then update `notification-policy.yaml` to
reference the receiver name you kept.

#### Sending to Microsoft Teams

1. In Teams, **right-click the target channel → Workflows**.
2. Choose the template **"Post to a channel when a webhook request is received"**,
   click *Next*, confirm the Team and Channel, then **Add workflow**.
3. Copy the generated URL — it looks like
   `https://prod-NN.LOCATION.logic.azure.com:443/workflows/.../triggers/manual/paths/invoke?...&sig=...`
4. In `contact-points.yaml`, delete the `webhook` receiver and uncomment the
   **MICROSOFT TEAMS** block, pasting your URL. Keep the contact point name
   `ClickStack Alerts` so the routing in `notification-policy.yaml` still matches.

> **Do not use a classic "Incoming Webhook" connector** (`outlook.office.com/webhook/...`).
> Microsoft blocked creation of new Office 365 connectors in 2024 and is retiring
> existing ones in 2026. Power Automate **Workflows** is the supported replacement,
> and Grafana's `teams` integration works with it.

> The Workflows URL is a **secret** — the `sig=` query parameter authorizes anyone
> who has it to post into your channel. Don't commit a real one.

### 3. Drop the files into Grafana's provisioning path

Copy this folder to `/etc/grafana/provisioning/alerting/` on your Grafana
server (or mount it there in Docker/Kubernetes), then restart Grafana:

```yaml
# docker-compose example
volumes:
  - ./alerting:/etc/grafana/provisioning/alerting
```

On restart you'll see **Alerting → Alert rules → "ClickStack Alerts"** folder
with all 15 rules (8 platform + 7 appliance), and the **ClickStack Alerts**
contact point under *Contact points*.

> **No filesystem access (Grafana Cloud)?** File provisioning needs write access
> to `/etc/grafana/provisioning/`, which Grafana Cloud and some managed setups
> don't allow. Use the Terraform equivalent in [`terraform/`](terraform/README.md)
> instead — it creates the contact point, policy, and **all 15 rules** (8 platform
> + 7 appliance) via the Grafana API, with byte-identical SQL to these YAML files.
> Use one method or the other, not both.

> **Heads-up on `notification-policy.yaml`:** Grafana provisioning replaces the
> **entire** root notification policy tree. This file keeps the root receiver as
> Grafana's built-in default email and adds a nested route sending
> `stack=clickstack` alerts to the ClickStack contact point. If you already
> manage your own policy and don't want it overwritten, **delete this file** and
> instead add one nested route by hand: *Alerting → Notification policies → New
> nested policy*, match `stack = clickstack`, contact point **ClickStack Alerts**.

---

## Tuning thresholds

Each rule follows a three-node pattern: **A** (ClickHouse SQL) → **B** (reduce
to one number) → **C** (threshold). To change a threshold, edit the number in
that rule's `C` block:

```yaml
- refId: C
  ...
  model:
    type: threshold
    expression: B
    conditions:
      - evaluator: { type: gt, params: [5] }   # <-- change 5
```

- `type: gt` / `lt` — greater/less than.
- `for:` on the rule — how long the condition must hold before it fires
  (raise it to reduce flapping, lower it for faster paging).
- `interval:` on the group — how often the rule is evaluated (default 1m).

The defaults are intentionally opinionated for a busy demo/staging cluster.
Quiet production services may want stricter numbers; noisy ones, looser.

---

## Dev harness (this repo)

The local Grafana in `../docker-compose.yml` already mounts this folder to
`/etc/grafana/provisioning/alerting`, so the rules load automatically against
the dev ClickHouse (datasource UID `clickstack-ch`). Verify after
`docker compose up -d`:

```powershell
# list loaded rules
curl.exe -u admin:admin http://localhost:3005/api/v1/provisioning/alert-rules

# evaluation state / health of every rule
curl.exe -u admin:admin http://localhost:3005/api/prometheus/grafana/api/v1/rules
```

`health=ok` means the ClickHouse query ran. `state` moves
`inactive → pending → firing` as a condition holds for its `for` duration.
Browse them in the UI at **http://localhost:3005 → Alerting → Alert rules**.
