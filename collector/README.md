# ClickHouse + Collector metrics scraper (advanced-tier enabler)

An **optional** OpenTelemetry Collector that makes the **advanced** platform-health
dashboards light up on the
[AzureLocal-Observability-Appliance](https://msazure.visualstudio.com/One/_git/AzureLocal-Observability-Appliance)
(and any ClickStack deploy that uses its mTLS ingest model).

## Why you need it

The appliance's central collector is an **OTLP-only ingest gateway** — it receives
traces/metrics/logs but does **not** scrape anything. The default-tier dashboards
(Operations Center, Infrastructure, Kubernetes, Services, Logs, Supportability) light up from app OTLP + the
appliance's kube-telemetry collectors. But these **advanced** boards need metrics
that nothing on a stock appliance collects:

| Advanced dashboard | Needs | Source with no scraper on the appliance |
|--------------------|-------|-----------------------------------------|
| HyperDX — Observability Platform Health (`dashboards/advanced/observability-platform-health.json`) | `ClickHouseProfileEvents_*`, `ClickHouseMetrics_*`, `otelcol_*_total`, `otelcol_exporter_queue_*` | ClickHouse `:9363` Prometheus endpoint **and** central collector `:8888` self-telemetry |

This collector scrapes both endpoints and forwards the metrics into the **same**
`default.otel_metrics_{gauge,sum}` tables the dashboards already read.

> It does **not** help that dashboard's Raw-SQL tiles — the MergeTree/parts and
> query-log sections read ClickHouse's own `system.*` tables directly and only need
> the HyperDX ClickHouse connection user to have `SELECT` on them. Nor does it help
> the latency-histogram board, which needs your **apps** to emit OTLP histograms.

## How it works (no appliance edits, no ClickHouse credentials)

```
 ClickHouse :9363 ─┐
                   ├─▶  this collector  ──OTLP/gRPC mTLS :4317──▶  clickstack-otel-collector  ──▶  ClickHouse
 collector  :8888 ─┘   (prometheus recv)   (enrolled emitter leaf)      (central ingest)          default.otel_metrics_*
```

It reuses the appliance's **exact ingest path**: it exports OTLP over mutual TLS to
`clickstack-otel-collector:4317`, presenting an **enrolled internal-emitter leaf**
that is leaf-pinned in the trust-manager allow-list bundle — the same mechanism the
appliance's own kube-telemetry collectors use. So it needs **no** ClickHouse
username/password and writes nothing to ClickHouse directly.

The emitter identity is either:
- **(default)** an existing enrolled secret you already have, e.g.
  `clickstack-emitter-app-secret` — zero new certs, guaranteed accepted; or
- **(`-CreateDedicatedCert`)** a dedicated cert-manager identity minted from
  [`emitter-cert.yaml`](emitter-cert.yaml) (labeled `aldotel.io/internal-emitter=true`
  so trust-manager auto-enrolls it into the allow-list).

## Where it fits in the flow

```
1. Deploy the appliance fully (Deploy-ALDOTel.ps1 — NOT -DevBox, so kube-telemetry runs)
2. ▶ collector/install-collector.ps1   ← this add-on (adds ClickHouse + collector metrics)
3. wait ~1-2 min for metrics to flow
4. hyperdx/preflight.ps1                ← should now show the advanced boards satisfied
5. hyperdx/import.ps1 -Advanced         ← import HyperDX advanced dashboards
   grafana/kubernetes/install-k8s.ps1 -Advanced   ← + Grafana advanced dashboards
```

## Usage

Requires `kubectl` + `helm` configured against the appliance cluster. Match
`-Namespace` to your deploy (the ALDOTel appliance installs into `aldotel`, the
default; a bare open-source ClickStack tier is often `clickstack`). Default: `aldotel`.

**PowerShell**
```powershell
# default: reuse an existing enrolled emitter secret
./collector/install-collector.ps1 -Namespace aldotel

# or mint a dedicated mTLS identity for the scraper
./collector/install-collector.ps1 -Namespace aldotel -CreateDedicatedCert

# only ClickHouse :9363 (skip collector :8888 if its Service doesn't expose 8888)
./collector/install-collector.ps1 -Namespace aldotel -SkipCollectorMetrics

# remove it
./collector/install-collector.ps1 -Namespace aldotel -Uninstall
```

**Bash**
```bash
./collector/install-collector.sh --namespace aldotel
./collector/install-collector.sh --namespace aldotel --create-dedicated-cert
./collector/install-collector.sh --namespace aldotel --skip-collector-metrics
./collector/install-collector.sh --namespace aldotel --uninstall
```

### Key options

| PowerShell | Bash | Default | Purpose |
|-----------|------|---------|---------|
| `-Namespace` | `--namespace` | `aldotel` | Namespace where ClickStack/appliance is installed |
| `-EmitterSecret` | `--emitter-secret` | `clickstack-emitter-app-secret` | Existing enrolled emitter TLS secret to present over mTLS |
| `-CreateDedicatedCert` | `--create-dedicated-cert` | off | Mint a dedicated cert-manager emitter identity instead |
| `-ChService` | `--ch-service` | `clickstack-clickhouse-clickhouse-headless` | ClickHouse headless Service fronting `:9363` |
| `-ChMetricsPort` | `--ch-metrics-port` | `9363` | ClickHouse Prometheus port |
| `-ChScheme` | `--ch-scheme` | `http` | Scheme for the ClickHouse metrics endpoint |
| `-CollectorService` | `--collector-service` | `clickstack-otel-collector` | Central OTel Collector Service |
| `-SkipCollectorMetrics` | `--skip-collector-metrics` | off | Scrape only ClickHouse `:9363` |
| `-Uninstall` | `--uninstall` | off | Remove the release (+ dedicated cert) |

## Verify

```bash
# scraper pod is Running
kubectl get pods -n <ns> -l app.kubernetes.io/instance=clickstack-metrics-collector

# scraper logs — look for successful scrapes / OTLP exports (no TLS handshake errors)
kubectl logs -n <ns> -l app.kubernetes.io/instance=clickstack-metrics-collector --tail=50
```

Then run `hyperdx/preflight.ps1` — the `[advanced]` ClickHouse and collector-health
rows should flip from `FAIL`/`DEGRADED` to `OK` once metrics have flowed (~1-2 min).

## Bonus: host CPU / memory utilization

The default-tier **Infrastructure** board needs `system.cpu.utilization` and
`system.memory.utilization`. The appliance's kube-telemetry **DaemonSet** already
runs the hostmetrics receiver, but leaves those two *ratio* metrics at
OpenTelemetry's opt-in default of **disabled** — so preflight reports them as
`MISS [required]` even though the DaemonSet is healthy (`cpu.load_average`,
`disk.io`, `network.io` all report fine). `enable-host-metrics.ps1` / `.sh` flips
them on by patching the DaemonSet release **in place**
(`helm upgrade --reuse-values`, which preserves the injected mTLS OTLP endpoint;
it also auto-pins the already-installed chart version so nothing else changes):

**PowerShell**
```powershell
./collector/enable-host-metrics.ps1 -Namespace aldotel
./collector/enable-host-metrics.ps1 -Namespace aldotel -Disable   # revert
```

**Bash**
```bash
./collector/enable-host-metrics.sh --namespace aldotel
./collector/enable-host-metrics.sh --namespace aldotel --disable
```

> Unlike the scraper above, this patches an **appliance** release
> (`clickstack-kube-daemonset`), not a release of its own. If the appliance later
> re-runs its own `install-kube-telemetry.ps1`, the packaged DaemonSet values
> (which lack these two metrics) revert it — just re-run this script, or bake the
> same `cpu`/`memory` `metrics:` blocks into the appliance's
> `configs/kube-otel-daemonset-values.yaml` to make it permanent.

## Files

| File | Purpose |
|------|---------|
| [`otel-metrics-collector-values.yaml`](otel-metrics-collector-values.yaml) | Helm values for the upstream `opentelemetry-collector` chart (prometheus receiver → OTLP/mTLS exporter). `__PLACEHOLDER__` tokens are substituted by the installer. |
| [`emitter-cert.yaml`](emitter-cert.yaml) | Optional dedicated cert-manager emitter identity (applied only with `-CreateDedicatedCert`). |
| [`install-collector.ps1`](install-collector.ps1) / [`install-collector.sh`](install-collector.sh) | Idempotent `helm upgrade --install` wrapper (+ uninstall). |
| [`enable-host-metrics.ps1`](enable-host-metrics.ps1) / [`enable-host-metrics.sh`](enable-host-metrics.sh) | Enable `system.cpu.utilization` / `system.memory.utilization` on the appliance's kube-telemetry DaemonSet (opt-in hostmetrics ratios) so **Infrastructure** goes green. Idempotent; `-Disable` reverts. |

## Notes & caveats

- **`-DevBox` appliance deploys** skip the kube-telemetry collectors entirely, so the
  K8s/Host default boards are dark there too — but this scraper still works for the
  ClickHouse/collector metrics (it doesn't depend on kube-telemetry).
- **ClickHouse `:9363` is plaintext** even on the TLS-hardened appliance (the
  `<prometheus>` port is separate from the native/HTTP protocols governed by
  `tls.required`). If your build serves it over TLS, pass `-ChScheme https`.
- **Shared vs dedicated emitter cert:** reusing an existing emitter secret is a shared
  client identity — fine for an internal metrics scraper. Use `-CreateDedicatedCert`
  if you want the scraper to have its own identity in audit/logs.
- The scraper is a single lightweight Deployment (50m CPU / 128Mi requests) that only
  scrapes two endpoints every 30s.
