# Test-data generator

Your ClickStack machine ships with **infrastructure telemetry only** — the DaemonSet +
Deployment OTel collectors populate Kubernetes and ClickHouse metrics (and raw container
logs) out of the box. It does **not** generate any **application** telemetry, so the
trace- and error-driven dashboards start out empty:

| Dashboard | Needs |
|-----------|-------|
| Services — RED (Rate / Errors / Duration) | application **traces** (server spans) |
| Services — SLO / Error Budget | application **traces** (server spans + `StatusCode`) |
| Executive Overview (trace + error tiles) | traces + severity-tagged logs |
| Logs — Overview (error tiles) | logs with `SeverityText` / `SeverityNumber` set |

This folder deploys the **[OpenTelemetry Demo](https://opentelemetry.io/docs/demo/)** — a
realistic microservice storefront (`frontend`, `cart`, `checkout`, `product-catalog`, …) —
and points its OTLP exporter at the ClickStack collector already running in your cluster.
It produces server/client **spans**, **Error** statuses, and **error/warn logs**, which is
exactly what those dashboards render.

## Deploy

```powershell
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm repo update
helm install otel-demo open-telemetry/opentelemetry-demo `
  --namespace otel-demo --create-namespace `
  --version 0.40.9 -f otel-demo.values.yaml
```

## Verify (wait ~2–3 min for pods to start emitting)

```powershell
kubectl exec -n clickstack clickstack-clickhouse-clickhouse-0-0-0 -- `
  clickhouse-client -q "SELECT ServiceName, count() FROM otel_traces WHERE Timestamp >= now()-INTERVAL 10 MINUTE GROUP BY ServiceName ORDER BY 2 DESC FORMAT TabSeparated"
```

Rows like `frontend`, `cart`, `checkout` mean traces are landing — refresh the dashboards
in HyperDX and the trace tiles will populate.

> **No rows even though the demo pods are `Running`?** Your install banner warns that
> *"OTLP receivers (4317/4318) may need pipeline binding via HyperDX UI."* That means the
> collector is receiving OTLP but not routing it to ClickHouse yet. See
> [`TROUBLESHOOTING.md`](TROUBLESHOOTING.md) for a step-by-step decision tree (it starts with
> the one ClickHouse query that tells you whether the problem is ingest-side or display-side).

## Tear down

```powershell
helm uninstall otel-demo -n otel-demo
kubectl delete namespace otel-demo
```

## Notes

- The exporter targets `clickstack-otel-collector.clickstack.svc.cluster.local:4318`, which
  assumes your ClickStack **app** Helm release is named `clickstack`. If it isn't, edit the
  `endpoint` host in [`otel-demo.values.yaml`](otel-demo.values.yaml).
- In-cluster OTLP needs no auth on a default OSS ClickStack install. If your collector
  requires an ingestion key, add a `headers.authorization` entry to the exporter (see the
  comment in the values file).
- This is a **test-data** helper for populating the dashboards during development — it is not
  part of the dashboard templates themselves.
