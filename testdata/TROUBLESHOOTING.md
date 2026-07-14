# Troubleshooting: "the demo is running but my dashboards are still empty"

Your install banner warns:

> *OTLP receivers (4317/4318) may need pipeline binding via HyperDX UI.*

In practice, on a default OSS ClickStack the bundled collector (`clickstack-otel-collector`)
already writes OTLP traces/logs/metrics into ClickHouse, and HyperDX ships **4 pre-created
sources** — `Logs` → `otel_logs`, `Traces` → `otel_traces`, `Metrics` → `otel_metrics_*`,
`Sessions`. So most installs need **no** manual binding. This checklist is for the case where
the demo pods are `Running` but tiles stay blank.

---

## Step 0 — The one query that settles it

Ask ClickHouse directly (bypasses HyperDX entirely):

```powershell
kubectl exec -n clickstack clickstack-clickhouse-clickhouse-0-0-0 -- `
  clickhouse-client -q "SELECT ServiceName, count() FROM otel_traces WHERE Timestamp >= now()-INTERVAL 10 MINUTE GROUP BY ServiceName ORDER BY 2 DESC FORMAT TabSeparated"
```

- **Rows come back** (`frontend`, `cart`, …) → traces ARE landing. Skip to **Branch A**.
- **No rows** → traces are NOT reaching ClickHouse. Go to **Branch B**.

---

## Branch A — data is in ClickHouse, but a dashboard tile is blank

The ingest path is fine. It's a HyperDX-side display issue.

1. **Widen the time range.** The demo needs a couple of minutes of history; set the picker to
   *Last 15 minutes* or *Last 1 hour* and refresh.
2. **Confirm the Traces source is present and enabled.** In HyperDX: **gear / Team Settings →
   Sources**. You should see a source named **Traces**, `kind: trace`, table `otel_traces`,
   `disabled: false`. If it's missing, create it (see *Recreate the Traces source* below).
3. **Confirm the dashboard tile points at the Traces source.** Open the empty tile → its source
   dropdown should be the `Traces` source; its filters (e.g. `SpanKind:Server`) should match your
   data. The demo emits `SpanKind = Server/Client/Internal` and `StatusCode = Ok/Error/Unset`.
4. **Re-run preflight** to confirm the trace checks now PASS:
   ```powershell
   cd ..\hyperdx ; .\preflight.ps1
   ```

## Branch B — no traces in ClickHouse

The demo isn't successfully exporting to the collector, or the collector isn't ingesting.

1. **Are the demo pods actually up?**
   ```powershell
   kubectl get pods -n otel-demo
   ```
   All should be `Running`. `load-generator` and `frontend` are the key traffic sources.

2. **Is the demo's collector exporting without error?**
   ```powershell
   kubectl logs -n otel-demo -l app.kubernetes.io/name=opentelemetry-collector --tail=50 | Select-String -Pattern "error|refused|connection|4318"
   ```
   `connection refused` / DNS errors here mean the exporter endpoint is wrong — it must be
   `http://clickstack-otel-collector.clickstack.svc.cluster.local:4318` (your ClickStack app
   release must be named `clickstack`; if not, fix the host in `otel-demo.values.yaml` and
   `helm upgrade`).

3. **Is the ClickStack collector receiving spans?**
   ```powershell
   kubectl logs -n clickstack deploy/clickstack-otel-collector --tail=80 | Select-String -Pattern "Traces|error|refused"
   ```

4. **Is the OTLP receiver reachable at all?** From inside the cluster:
   ```powershell
   kubectl run otlp-test --rm -it --image=curlimages/curl -n clickstack --restart=Never -- `
     curl -s -o /dev/null -w "%{http_code}" -X POST -H "content-type: application/json" `
     --data "{}" http://clickstack-otel-collector:4318/v1/traces
   ```
   A `400`/`415` means the port is open and listening (good — it rejected the empty body). A
   `connection refused`/timeout means the receiver isn't bound.

5. **If the receiver truly isn't bound — bind it in the HyperDX UI:** open HyperDX → **Team
   Settings → Sources / Connections**, verify the ClickHouse **Connection** is healthy, and that
   a **Traces** source exists pointing at `default.otel_traces`. Save, then re-run **Step 0**.

---

## Recreate the Traces source (only if it's genuinely missing)

A correct Traces source on a default ClickStack looks like this (key fields):

| Field | Value |
|-------|-------|
| name | `Traces` |
| kind | `trace` |
| database / table | `default` / `otel_traces` |
| timestamp expression | `Timestamp` |
| duration expression / precision | `Duration` / `9` |
| trace / span / parent id | `TraceId` / `SpanId` / `ParentSpanId` |
| span name / kind | `SpanName` / `SpanKind` |
| status code / message | `StatusCode` / `StatusMessage` |
| service name | `ServiceName` |
| resource / event attributes | `ResourceAttributes` / `SpanAttributes` |

Create it under **Team Settings → Sources → Add Source → Trace**, then correlate it to the
`Logs` and `Metrics` sources so drill-downs work.

---

## Still stuck?

Re-run the inventory and share it — it shows exactly what (if anything) reached ClickHouse:

```powershell
cd ..\hyperdx ; .\inventory.ps1
```
