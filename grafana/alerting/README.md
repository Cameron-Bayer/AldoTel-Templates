# ClickStack Grafana Alerts

Grafana **unified alerting** rules that watch the same ClickHouse data your
ClickStack dashboards read (`otel_traces`, `otel_logs`, `otel_metrics_gauge`).
Where the HyperDX dashboards are for *investigation*, these alerts are for
*notification* — Grafana evaluates each rule on a schedule and pushes to your
on-call channel (any webhook — Slack, a Teams Workflow, PagerDuty, etc.) when
something breaks.

This pack **complements** the HyperDX alerts pack (`../../hyperdx/alerts`): both watch the
same ClickHouse data, but the two packs cover different signals (this Grafana pack: error
rate, p95 latency, trace-ingestion stall, pods-not-running, error-log rate, fatal logs;
the HyperDX pack: collector drops, error rate, replication lag, SLO fast-burn, too-many-parts).
Run either or both.

---

## What's in the box

| File | Purpose |
|------|---------|
| `alert-rules.yaml` | The 6 alert rules (queries + thresholds). |
| `contact-points.yaml` | The alert contact point — a generic webhook (add your URL). |
| `notification-policy.yaml` | Routes ClickStack alerts to that contact point (optional). |

### The 6 alerts

| Alert | Source table | Fires when | Default threshold | `for` | Severity |
|-------|--------------|-----------|-------------------|-------|----------|
| Service error rate high | `otel_traces` | a service's server-span error rate is high | > 5 % | 5m | warning |
| Service p95 latency high | `otel_traces` | a service's p95 latency is high | > 2000 ms | 10m | warning |
| Trace ingestion stalled | `otel_traces` | no spans arrive (pipeline down) | < 1 span / 10m | 10m | critical |
| Pods not Running | `otel_metrics_gauge` | pods stuck outside Running phase | > 0 pods | 5m | warning |
| Error log rate high | `otel_logs` | error+fatal logs surge | > 5 / s | 10m | warning |
| Fatal logs present | `otel_logs` | any fatal log line | > 0 | 5m | critical |

Each alert is multi-dimensional where it makes sense — the service error-rate
and latency rules fire **per service**, so you get one alert instance per
affected service with the service name in the notification.

---

## Install (customer)

These are **provisioning** files. Grafana loads them from disk at startup — you
do not import them through the UI.

### 1. Point the rules at your ClickHouse datasource

Every query references a datasource by UID: **`clickstack-ch`**. Either

- set your ClickHouse datasource's UID to `clickstack-ch`
  (*Connections → Data sources → your ClickHouse → UID*), **or**
- find/replace `clickstack-ch` in `alert-rules.yaml` with your datasource's UID.

If your ClickStack writes to a database other than `default`, also find/replace
`default.` in `alert-rules.yaml`.

### 2. Set your notification channel

Open `contact-points.yaml` and replace the placeholder `url` with a webhook URL
for the channel you want — a Slack incoming webhook, a Teams Workflow "Post to a
channel when a webhook request is received" URL, PagerDuty, Discord, or any HTTP
endpoint that accepts a POST. Prefer a native email/Slack/PagerDuty integration?
Comment out the `webhook` receiver and use one of the examples in that file (or
add any Grafana contact-point type), then update `notification-policy.yaml` to
reference the receiver name you kept.

### 3. Drop the files into Grafana's provisioning path

Copy this folder to `/etc/grafana/provisioning/alerting/` on your Grafana
server (or mount it there in Docker/Kubernetes), then restart Grafana:

```yaml
# docker-compose example
volumes:
  - ./alerting:/etc/grafana/provisioning/alerting
```

On restart you'll see **Alerting → Alert rules → "ClickStack Alerts"** folder
with the 6 rules, and the **ClickStack Alerts** contact point under
*Contact points*.

> **No filesystem access (Grafana Cloud)?** File provisioning needs write access
> to `/etc/grafana/provisioning/`, which Grafana Cloud and some managed setups
> don't allow. Use the Terraform equivalent in [`terraform/`](terraform/README.md)
> instead — it creates the same 6 rules, contact point, and policy via the
> Grafana API. Use one method or the other, not both.

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
curl -u admin:admin http://localhost:3005/api/v1/provisioning/alert-rules

# evaluation state / health of every rule
curl -u admin:admin http://localhost:3005/api/prometheus/grafana/api/v1/rules
```

`health=ok` means the ClickHouse query ran. `state` moves
`inactive → pending → firing` as a condition holds for its `for` duration.
Browse them in the UI at **http://localhost:3005 → Alerting → Alert rules**.
