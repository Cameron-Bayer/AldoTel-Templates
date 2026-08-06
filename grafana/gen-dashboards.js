#!/usr/bin/env node
/*
 * Generates the shippable ClickStack Grafana dashboards into grafana/dashboards/.
 *
 * Design goals (so a customer can "download -> import -> it just works"):
 *  - Every panel targets a dashboard datasource VARIABLE (${clickhouseDatasource}) of
 *    type grafana-clickhouse-datasource. On import Grafana asks the user to pick their
 *    ClickHouse connection; nothing is hard-coded to our dev environment.
 *  - The schema is a ${database} constant variable (defaults to `default`), so a customer
 *    on a non-default ClickHouse database changes one value instead of find/replacing JSON.
 *  - Queries use only the ClickStack/OpenTelemetry default schema (otel_traces,
 *    otel_logs, otel_metrics_gauge) and stable ClickHouse-plugin macros
 *    ($__timeFilter, $__timeInterval, $__fromTime, $__toTime).
 *
 * Re-run:  node grafana/gen-dashboards.js
 */
const fs = require('fs');
const path = require('path');

const OUT = path.join(__dirname, 'dashboards');
const DB = '${database}';   // schema is referenced in SQL via a dashboard variable (portable)
const DB_META = 'default';  // ClickStack default database (builder metadata; raw-SQL mode ignores it)
const CH = 'grafana-clickhouse-datasource';
const DS = { type: CH, uid: '${clickhouseDatasource}' };

let uidSeq = 0;
const puid = () => `p${++uidSeq}`;

// ---- builders -------------------------------------------------------------
function target(rawSql, { format = 0, refId = 'A' } = {}) {
  // format: 0 = time series (wide multi-series), 1 = table
  return {
    refId,
    datasource: DS,
    editorType: 'sql',
    rawSql,
    queryType: format === 0 ? 'timeseries' : 'table',
    format,
    meta: { builderOptions: { database: DB_META, mode: 'trend' } },
  };
}

function base(type, title, gridPos, targets, extra = {}) {
  return Object.assign(
    {
      id: null,
      type,
      title,
      datasource: DS,
      gridPos,
      targets,
      fieldConfig: { defaults: {}, overrides: [] },
      options: {},
    },
    extra
  );
}

function stat(title, gridPos, sql, { unit = 'short', decimals = 2, thresholds, desc, colorMode } = {}) {
  const p = base('stat', title, gridPos, [target(sql, { format: 1 })]);
  if (desc) p.description = desc;
  p.fieldConfig.defaults = {
    unit,
    decimals,
    color: thresholds ? { mode: 'thresholds' } : { mode: 'fixed', fixedColor: 'text' },
    thresholds: thresholds || { mode: 'absolute', steps: [{ color: 'text', value: null }] },
    mappings: [],
  };
  p.options = {
    reduceOptions: { calcs: ['lastNotNull'], fields: '', values: false },
    orientation: 'auto',
    textMode: 'auto',
    colorMode: colorMode || (thresholds ? 'value' : 'none'),
    graphMode: 'area',
    justifyMode: 'auto',
  };
  return p;
}

function timeseries(title, gridPos, sql, { unit = 'short', decimals = 2, stacking = 'none', fillOpacity = 10, legend = true, interval = '1m', desc, overrides } = {}) {
  const p = base('timeseries', title, gridPos, [target(sql, { format: 0 })]);
  if (desc) p.description = desc;
  p.interval = interval;
  p.fieldConfig.defaults = {
    unit,
    decimals,
    custom: {
      drawStyle: 'line',
      lineInterpolation: 'smooth',
      lineWidth: 1,
      fillOpacity,
      gradientMode: 'opacity',
      spanNulls: true,
      showPoints: 'never',
      stacking: { mode: stacking, group: 'A' },
      axisPlacement: 'auto',
    },
    color: { mode: 'palette-classic' },
  };
  if (overrides) p.fieldConfig.overrides = overrides;
  p.options = {
    legend: { showLegend: legend, displayMode: 'table', placement: 'bottom', calcs: legend ? ['mean', 'max', 'lastNotNull'] : [] },
    tooltip: { mode: 'multi', sort: 'desc' },
  };
  return p;
}

function table(title, gridPos, sql, overrides = [], desc) {
  const p = base('table', title, gridPos, [target(sql, { format: 1 })]);
  if (desc) p.description = desc;
  p.fieldConfig.defaults = { custom: { align: 'auto', cellOptions: { type: 'auto' }, filterable: true } };
  p.fieldConfig.overrides = overrides;
  p.options = { showHeader: true, cellHeight: 'sm', footer: { show: false } };
  return p;
}

// Full-width markdown intro panel pinned to the top of a dashboard (y = 0).
function intro(content, h) {
  return { id: null, type: 'text', title: '', gridPos: { h, w: 24, x: 0, y: 0 }, options: { mode: 'markdown', content }, transparent: false };
}

function unitOverride(field, unit, decimals) {
  const props = [{ id: 'unit', value: unit }];
  if (decimals != null) props.push({ id: 'decimals', value: decimals });
  return { matcher: { id: 'byName', options: field }, properties: props };
}

function dsVar() {
  return {
    current: {},
    hide: 0,
    includeAll: false,
    label: 'ClickHouse datasource',
    multi: false,
    name: 'clickhouseDatasource',
    options: [],
    query: CH,
    refresh: 1,
    regex: '',
    skipUrlSync: false,
    type: 'datasource',
  };
}

// Hidden constant so panels reference ${database} instead of hard-coding `default`.
// Customers on a non-default ClickHouse database change the value here (one place) —
// no repo-wide find/replace needed.
function databaseVar() {
  return {
    name: 'database',
    label: 'ClickHouse database',
    type: 'constant',
    query: DB_META,
    current: { value: DB_META, text: DB_META, selected: false },
    options: [{ value: DB_META, text: DB_META, selected: false }],
    hide: 2,
    skipUrlSync: false,
  };
}

function dashboard(uid, title, description, panels, extraVars = []) {
  return {
    uid,
    title,
    description,
    tags: ['clickstack', 'opentelemetry'],
    schemaVersion: 39,
    version: 1,
    editable: true,
    graphTooltip: 1,
    time: { from: 'now-1h', to: 'now' },
    timepicker: {},
    refresh: '30s',
    templating: { list: [dsVar(), databaseVar(), ...extraVars] },
    annotations: { list: [] },
    panels,
  };
}

function write(name, dash) {
  const file = path.join(OUT, name);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(dash, null, 2) + '\n');
  console.log('wrote', path.relative(process.cwd(), file), `(${dash.panels.length} panels)`);
}

// A query-driven, multi-value template variable (drop-down filter). Uses the
// dashboard's ${clickhouseDatasource} datasource so it stays portable. "Include All" + no custom
// all-value means selecting All expands to every listed value via :sqlstring.
function queryVar(name, label, sql) {
  return {
    name,
    label,
    type: 'query',
    datasource: DS,
    definition: sql,
    query: { refId: `${name}-var`, rawSql: sql, meta: { builderOptions: { database: DB_META } } },
    refresh: 2, // re-run on time-range change (also on load)
    includeAll: true,
    multi: true,
    allValue: null,
    current: { text: ['All'], value: ['$__all'], selected: false },
    options: [],
    hide: 0,
    sort: 1,
    regex: '',
    skipUrlSync: false,
  };
}

function row(title, y) {
  return { id: null, type: 'row', title, collapsed: false, gridPos: { h: 1, w: 24, x: 0, y }, panels: [] };
}

// Convenience: server-side spans = inbound requests
const SERVER = "SpanKind = 'Server'";
const TF = '$__timeFilter(Timestamp)';
const TI = '$__timeInterval(Timestamp)';
const WINDOW_S = "dateDiff('second', $__fromTime, $__toTime)";

// Reusable filter fragments driven by template variables.
const SVC = 'AND ServiceName IN (${service:sqlstring})';           // traces / logs
const NS = "AND ResourceAttributes['k8s.namespace.name'] IN (${namespace:sqlstring})"; // metrics

// --- shared metric/log helpers --------------------------------------------
const WINDOW_S_SAFE = `greatest(${WINDOW_S}, 1)`;
const MFU = '$__timeFilter(TimeUnix)';
const MIU = '$__timeInterval(TimeUnix)';
const INST = "ResourceAttributes['service.instance.id']";

// Windowed, per-instance delta of a CUMULATIVE counter (otel_metrics_sum,
// AggregationTemporality=2 / monotonic). Summing (max-min) per service.instance.id
// makes counter resets and multiple collector/ClickHouse instances safe — never sum(Value).
const sumDelta = (m) =>
  `(SELECT sum(d) FROM (SELECT max(Value) - min(Value) AS d FROM ${DB}.otel_metrics_sum ` +
  `WHERE MetricName = '${m}' AND ${MFU} GROUP BY ${INST}))`;

// Latest-per-instance sum of a GAUGE (otel_metrics_gauge) as a scalar subquery.
const gaugeLatest = (m) =>
  `(SELECT sum(v) FROM (SELECT argMax(Value, TimeUnix) AS v FROM ${DB}.otel_metrics_gauge ` +
  `WHERE MetricName = '${m}' AND ${MFU} GROUP BY ${INST}))`;

// Canonical error/fatal log predicates. SeverityNumber is the robust signal
// (17=error, 21=fatal); the lowercase text is a fallback for pipelines that only set text.
const LOG_ERR = "(SeverityNumber >= 17 OR lower(SeverityText) IN ('error', 'fatal'))";
const LOG_FATAL = "(SeverityNumber >= 21 OR lower(SeverityText) = 'fatal')";
// Normalize mixed severity text (info vs information, upper vs lower) into canonical buckets.
const SEV_NORM =
  "multiIf(SeverityNumber >= 21, 'fatal', SeverityNumber >= 17, 'error', " +
  "SeverityNumber >= 13, 'warn', SeverityNumber >= 9, 'info', SeverityNumber >= 5, 'debug', " +
  "SeverityNumber >= 1, 'trace', SeverityText != '', lower(SeverityText), 'unspecified')";

// ===========================================================================
// 1. Service Health — Golden Signals (traces / RED)
// ===========================================================================
function serviceHealth() {
  const p = [];
  const W = `${TF} AND ${SERVER} ${SVC}`;
  p.push(intro(
    "## Service health (golden signals)\nBuilt from OpenTelemetry **incoming server spans** stored in ClickHouse. *Traffic* = average requests/sec; *errors* = spans with Error status; *latency* = span duration. **p50 / p95 / p99** mean 50%, 95%, or 99% of requests completed within that time. The final section compares observed errors against a fixed **99.9% availability target** — the *error budget* is how much failure that target still allows. No data usually means no server spans matched the filters.", 6));

  p.push(row('1. Service Overview', 6));
  p.push(stat('Average incoming requests/sec (selected range)', { h: 4, w: 6, x: 0, y: 7 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'reqps', decimals: 2, desc: 'Average incoming server requests per second across the selected time range. Traffic has no universal good/bad threshold.' }));
  p.push(stat('Request error percentage', { h: 4, w: 6, x: 6, y: 7 },
    `SELECT 100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] },
      desc: 'Percentage of incoming server spans marked Error. Green below 1%, yellow 1–4.99%, red 5% or higher.' }));
  p.push(stat('95th-percentile request latency', { h: 4, w: 6, x: 12, y: 7 },
    `SELECT quantile(0.95)(Duration) / 1e6 AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'ms', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 250 }, { color: 'red', value: 1000 }] },
      desc: '95% of matching incoming requests completed within this time. Default warning 250 ms, critical 1000 ms — tune to the service objective.' }));
  // Services burning error budget faster than the 99.9% SLO allows (error rate > 0.1%),
  // counting only services with enough traffic to be statistically meaningful.
  p.push(stat('Services below 99.9% availability', { h: 4, w: 6, x: 18, y: 7 },
    `SELECT count() AS value FROM (\n  SELECT ServiceName, countIf(StatusCode = 'Error') / nullIf(count(), 0) AS er\n  FROM ${DB}.otel_traces\n  WHERE ${W}\n  GROUP BY ServiceName\n  HAVING count() >= 20 AND er > 0.001)`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] },
      desc: 'Number of services with at least 20 requests whose observed error percentage exceeds 0.1% in the selected range. Red means one or more services are below target.' }));

  p.push(row('2. Request Health & Latency Trends', 11));
  p.push(timeseries('Request count per time bucket by service', { h: 8, w: 12, x: 0, y: 12 },
    `SELECT ${TI} AS time, ServiceName, count() AS requests\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time, ServiceName\nORDER BY time`,
    { unit: 'short', decimals: 0, stacking: 'normal', fillOpacity: 25, desc: 'Incoming request count in each Grafana time bucket, stacked by service.' }));
  p.push(timeseries('Request latency percentiles', { h: 8, w: 12, x: 12, y: 12 },
    `SELECT ${TI} AS time,\n       quantile(0.50)(Duration) / 1e6 AS p50,\n       quantile(0.95)(Duration) / 1e6 AS p95,\n       quantile(0.99)(Duration) / 1e6 AS p99\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time\nORDER BY time`,
    { unit: 'ms', desc: 'Latency across all selected services: p50 is the median, p95 covers 95% of requests, and p99 highlights the slowest 1%.' }));

  p.push(timeseries('Request error percentage over time', { h: 8, w: 12, x: 0, y: 20 },
    `SELECT ${TI} AS time, 100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS error_pct\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time\nORDER BY time`,
    { unit: 'percent', fillOpacity: 20, desc: 'Percentage of incoming requests marked Error in each time bucket, aggregated across all selected services.' }));
  p.push(timeseries('Error count per time bucket by service', { h: 8, w: 12, x: 12, y: 20 },
    `SELECT ${TI} AS time, ServiceName, countIf(StatusCode = 'Error') AS errors\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time, ServiceName\nHAVING errors > 0\nORDER BY time`,
    { unit: 'short', decimals: 0, stacking: 'normal', fillOpacity: 25, desc: 'Number of incoming requests marked Error in each Grafana time bucket for each service. This is a count, not errors per second.' }));

  p.push(row('3. Service Comparison', 28));
  p.push(table('Service traffic, errors, and latency', { h: 10, w: 24, x: 0, y: 29 },
    `SELECT ServiceName AS "Service",\n       count() / ${WINDOW_S} AS "Req/s",\n       countIf(StatusCode = 'Error') AS "Errors",\n       100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS "Error %",\n       quantile(0.50)(Duration) / 1e6 AS "p50 ms",\n       quantile(0.95)(Duration) / 1e6 AS "p95 ms",\n       quantile(0.99)(Duration) / 1e6 AS "p99 ms"\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY ServiceName\nORDER BY count() DESC`,
    [
      unitOverride('Req/s', 'reqps', 2),
      unitOverride('Error %', 'percent', 2),
      unitOverride('p50 ms', 'ms', 2),
      unitOverride('p95 ms', 'ms', 2),
      unitOverride('p99 ms', 'ms', 2),
      { matcher: { id: 'byName', options: 'Error %' }, properties: [
        { id: 'custom.cellOptions', value: { type: 'color-background', mode: 'gradient' } },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] } },
      ] },
      { matcher: { id: 'byName', options: 'p50 ms' }, properties: [{ id: 'displayName', value: 'Median latency' }] },
      { matcher: { id: 'byName', options: 'p95 ms' }, properties: [{ id: 'displayName', value: '95th-percentile latency' }] },
      { matcher: { id: 'byName', options: 'p99 ms' }, properties: [{ id: 'displayName', value: '99th-percentile latency' }] },
      unitOverride('Errors', 'short', 0),
    ],
    'Compares traffic, request errors, and latency by service. Percentiles show the latency within which 50%, 95%, or 99% of requests completed.'));

  // --- SLO / error budget (99.9% availability target) ---------------------
  // Availability = 1 - error rate. Burn rate = how fast the 0.1% error budget is
  // consumed in this window (>1 = over budget, >=14.4 = fast-burn / page-worthy).
  p.push(row('4. SLO & Error Budget', 39));
  p.push(table('99.9% availability and error-budget use by service', { h: 9, w: 24, x: 0, y: 40 },
    `SELECT ServiceName AS "Service",\n       count() AS "Requests",\n       countIf(StatusCode = 'Error') AS "Errors",\n       100 * (1 - countIf(StatusCode = 'Error') / nullIf(count(), 0)) AS "Availability %",\n       100 * (1 - (countIf(StatusCode = 'Error') / nullIf(count(), 0)) / 0.001) AS "Budget left %",\n       (countIf(StatusCode = 'Error') / nullIf(count(), 0)) / 0.001 AS "Burn rate"\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY ServiceName\nHAVING count() >= 20\nORDER BY (countIf(StatusCode = 'Error') / nullIf(count(), 0)) / 0.001 DESC`,
    [
      unitOverride('Availability %', 'percent', 2),
      unitOverride('Budget left %', 'percent', 2),
      { matcher: { id: 'byName', options: 'Burn rate' }, properties: [
        { id: 'custom.cellOptions', value: { type: 'color-background', mode: 'gradient' } },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 14.4 }] } },
      ] },
      { matcher: { id: 'byName', options: 'Budget left %' }, properties: [
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'red', value: null }, { color: 'yellow', value: 0 }, { color: 'green', value: 50 }] } },
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
      ] },
      unitOverride('Requests', 'short', 0),
      unitOverride('Errors', 'short', 0),
      { matcher: { id: 'byName', options: 'Burn rate' }, properties: [
        { id: 'displayName', value: 'Budget burn (x allowed rate)' }, { id: 'unit', value: 'none' },
        { id: 'decimals', value: 2 }] },
      { matcher: { id: 'byName', options: 'Availability %' }, properties: [
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'red', value: null }, { color: 'yellow', value: 99 }, { color: 'green', value: 99.9 }] } },
      ] },
    ],
    'Selected-range comparison against a fixed 99.9% availability target. Budget left estimates remaining allowed errors for this range and may be negative. A burn value of 1x consumes budget at the allowed rate; 14.4x or higher is critical. Services with fewer than 20 requests are omitted.'));
  const svcVar = queryVar('service', 'Service',
    `SELECT DISTINCT ServiceName FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER} AND ServiceName != '' ORDER BY ServiceName`);
  return dashboard('clickstack-service-health', 'ClickStack - Service Health',
    'RED metrics (Rate, Errors, Duration) for every service, derived from OpenTelemetry traces in ClickHouse (otel_traces).', p, [svcVar]);
}

// ===========================================================================
// 2. Kubernetes Cluster Overview (metrics)
// ===========================================================================
function k8sOverview() {
  const p = [];
  const MF = '$__timeFilter(TimeUnix)';
  const MI = '$__timeInterval(TimeUnix)';
  const RA = (k) => `ResourceAttributes['${k}']`;

  // Node-level panels are NOT namespace-scoped; pod/deployment/container panels are.
  p.push(intro(
    "## Kubernetes cluster overview\nKubernetes metrics and events collected by the OpenTelemetry Collector and stored in ClickHouse. The **Namespace** filter affects workload panels; node and event panels are cluster-wide. Status uses the **latest sample** in the selected range, while restart and event totals cover the **entire range**. Limit-utilization panels only show containers with configured resource limits. No data usually means the relevant Collector receiver is disabled or no matching telemetry was received.", 6));

  p.push(row('1. Cluster & Workload Health', 6));
  p.push(stat('Ready nodes (latest in range)', { h: 4, w: 6, x: 0, y: 7 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.node.name')} AS n, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.node.condition_ready' AND ${MF}\n  GROUP BY n HAVING v = 1)`,
    { unit: 'short', decimals: 0, desc: 'Nodes whose latest Ready condition in the selected range is true. Compare with the expected cluster node count; any decrease requires investigation.' }));
  p.push(stat('Running pods (latest in range)', { h: 4, w: 6, x: 6, y: 7 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.pod.uid')} AS u, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF} ${NS}\n  GROUP BY u HAVING v = 2)`,
    { unit: 'short', decimals: 0, desc: 'Pods in the selected namespaces whose latest phase is Running. Successfully completed pods are excluded.' }));
  p.push(stat('Pods pending, failed, or unknown', { h: 4, w: 6, x: 12, y: 7 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.pod.uid')} AS u, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF} ${NS}\n  GROUP BY u HAVING v NOT IN (2, 3))`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] },
      desc: 'Pods whose latest phase is neither Running nor Succeeded. Any non-zero value should be investigated.' }));
  // Restarts that happened INSIDE the selected window (per-container max-min of the
  // cumulative restart counter), not the lifetime total — see grafana/README.md.
  p.push(stat('Container restarts during selected range', { h: 4, w: 6, x: 18, y: 7 },
    `SELECT sum(d) AS value FROM (\n  SELECT concat(${RA('k8s.pod.uid')}, '/', ${RA('k8s.container.name')}) AS c, max(Value) - min(Value) AS d\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.container.restarts' AND ${MF} ${NS}\n  GROUP BY c)`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 10 }] },
      desc: 'Increase in restart counters across containers in the selected namespaces during the selected time range. Longer ranges may produce larger totals.' }));

  p.push(row('2. Host & Workload Resource Usage', 11));
  p.push(timeseries('Host CPU utilization', { h: 8, w: 12, x: 0, y: 12 },
    `SELECT time, host, 100 * avg(busy) AS "cpu %" FROM (\n  SELECT ${MI} AS time, ${RA('host.name')} AS host, Attributes['cpu'] AS cpu, TimeUnix,\n         sumIf(Value, Attributes['state'] != 'idle') AS busy\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName = 'system.cpu.utilization' AND ${MF}\n  GROUP BY time, host, cpu, TimeUnix)\nGROUP BY time, host ORDER BY time`,
    { unit: 'percent', desc: 'Non-idle CPU percentage for each host backing the cluster. Sustained values above 75% warrant attention; above 90% pods will start competing for CPU and latency rises even though nothing has failed.' }));
  p.push(timeseries('Host memory utilization', { h: 8, w: 12, x: 12, y: 12 },
    `SELECT ${MI} AS time, ${RA('host.name')} AS host, 100 * avgIf(Value, Attributes['state'] = 'used') AS "mem %"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'system.memory.utilization' AND ${MF}\nGROUP BY time, host ORDER BY time`,
    { unit: 'percent', desc: 'Used-memory percentage for each host backing the cluster. Memory has no throttling safety net — once a host is exhausted the kernel OOM-kills containers, so treat sustained values above 92% as urgent.' }));

  // Top 10 pods by CPU only — pod-level series are high cardinality, so a full
  // breakdown is unreadable at a glance. Series are keyed by namespace/pod.
  p.push(timeseries('Top 10 pods by CPU usage', { h: 8, w: 12, x: 0, y: 20 },
    `SELECT ${MI} AS time, concat(${RA('k8s.namespace.name')}, '/', ${RA('k8s.pod.name')}) AS pod, avg(Value) AS cpu_cores\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.pod.cpu.usage' AND ${MF} ${NS}\n  AND concat(${RA('k8s.namespace.name')}, '/', ${RA('k8s.pod.name')}) IN (\n    SELECT concat(${RA('k8s.namespace.name')}, '/', ${RA('k8s.pod.name')}) AS pk\n    FROM ${DB}.otel_metrics_gauge\n    WHERE MetricName = 'k8s.pod.cpu.usage' AND ${MF} ${NS}\n    GROUP BY pk ORDER BY avg(Value) DESC LIMIT 10)\nGROUP BY time, pod ORDER BY time`,
    { unit: 'cores', legend: true, desc: 'CPU cores used by the ten pods with the highest average CPU usage over the selected time range.' }));
  // Available / desired replicas as a percentage (100% = fully rolled out).
  p.push(timeseries('Deployment replica availability', { h: 8, w: 12, x: 12, y: 20 },
    `SELECT time, deployment, 100 * available / greatest(desired, 1) AS "availability %"\nFROM (\n  SELECT ${MI} AS time,\n         concat(${RA('k8s.namespace.name')}, '/', ${RA('k8s.deployment.name')}) AS deployment,\n         avgIf(Value, MetricName = 'k8s.deployment.available') AS available,\n         avgIf(Value, MetricName = 'k8s.deployment.desired') AS desired\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName IN ('k8s.deployment.available', 'k8s.deployment.desired') AND ${MF} ${NS}\n  GROUP BY time, deployment)\nORDER BY time`,
    { unit: 'percent', desc: 'Available replicas divided by desired replicas for each deployment. 100% means all desired replicas are available; below 100% indicates unavailable replicas.' }));

  p.push(row('3. Workload Details', 28));
  p.push(table('Top 20 pods by active memory', { h: 9, w: 12, x: 0, y: 29 },
    `SELECT ${RA('k8s.namespace.name')} AS "Namespace",\n       ${RA('k8s.pod.name')} AS "Pod",\n       argMax(Value, TimeUnix) AS "Memory"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.pod.memory.working_set' AND ${MF} ${NS}\nGROUP BY 1, 2\nORDER BY "Memory" DESC\nLIMIT 20`,
    [unitOverride('Memory', 'bytes_iec', 2)],
    'Latest memory working-set sample in the selected range for the 20 highest-usage pods. Working set approximates actively used, non-easily-reclaimable memory.'));
  p.push(table('Containers with restarts during selected range', { h: 9, w: 12, x: 12, y: 29 },
    `SELECT ${RA('k8s.namespace.name')} AS "Namespace",\n       ${RA('k8s.pod.name')} AS "Pod",\n       ${RA('k8s.container.name')} AS "Container",\n       toUInt64(max(Value) - min(Value)) AS "Restarts"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.container.restarts' AND ${MF} ${NS}\nGROUP BY 1, 2, 3\nHAVING "Restarts" > 0\nORDER BY "Restarts" DESC\nLIMIT 20`,
    [{ matcher: { id: 'byName', options: 'Restarts' }, properties: [
      { id: 'custom.cellOptions', value: { type: 'color-background', mode: 'gradient' } },
      { id: 'thresholds', value: { mode: 'absolute', steps: [
        { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] } },
    ] },
     unitOverride('Restarts', 'short', 0)],
    'Top 20 containers with one or more restart-counter increases during the selected time range.'));

  // --- Container utilization vs limits ------------------------------------
  p.push(row('4. Container Resource Use Versus Configured Limits', 38));
  const cKey = `concat(${RA('k8s.namespace.name')}, '/', ${RA('k8s.pod.name')}, '/', ${RA('k8s.container.name')})`;
  const topContainers = (metric) =>
    `${cKey} IN (\n    SELECT ${cKey} AS ck FROM ${DB}.otel_metrics_gauge\n    WHERE MetricName = '${metric}' AND ${MF} ${NS}\n    GROUP BY ck ORDER BY avg(Value) DESC LIMIT 10)`;
  p.push(timeseries('Top 10 containers by CPU limit utilization', { h: 8, w: 12, x: 0, y: 39 },
    `SELECT ${MI} AS time, ${cKey} AS container, 100 * avg(Value) AS "cpu vs limit %"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.container.cpu_limit_utilization' AND ${MF} ${NS}\n  AND ${topContainers('k8s.container.cpu_limit_utilization')}\nGROUP BY time, container ORDER BY time`,
    { unit: 'percent', desc: "CPU usage as a percentage of each container's configured CPU limit. Sustained values near or above 100% indicate throttling risk. Containers without limits do not appear." }));
  p.push(timeseries('Top 10 containers by memory limit utilization', { h: 8, w: 12, x: 12, y: 39 },
    `SELECT ${MI} AS time, ${cKey} AS container, 100 * avg(Value) AS "mem vs limit %"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.container.memory_limit_utilization' AND ${MF} ${NS}\n  AND ${topContainers('k8s.container.memory_limit_utilization')}\nGROUP BY time, container ORDER BY time`,
    { unit: 'percent', desc: "Memory usage as a percentage of each container's configured memory limit. Values approaching 100% indicate out-of-memory termination risk." }));
  // argMaxIf returns 0 (not null) for a container that never reports a limit-utilization
  // series, so containers without limits show 0% rather than dropping out of the table.
  p.push(table('Latest container resource-limit utilization', { h: 9, w: 24, x: 0, y: 47 },
    `SELECT ${RA('k8s.namespace.name')} AS "Namespace",\n       ${RA('k8s.pod.name')} AS "Pod",\n       ${RA('k8s.container.name')} AS "Container",\n       100 * argMaxIf(Value, TimeUnix, MetricName = 'k8s.container.cpu_limit_utilization') AS "CPU vs limit %",\n       100 * argMaxIf(Value, TimeUnix, MetricName = 'k8s.container.memory_limit_utilization') AS "Mem vs limit %"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName IN ('k8s.container.cpu_limit_utilization', 'k8s.container.memory_limit_utilization') AND ${MF} ${NS}\nGROUP BY 1, 2, 3\nORDER BY argMaxIf(Value, TimeUnix, MetricName = 'k8s.container.cpu_limit_utilization') DESC\nLIMIT 25`,
    [
      unitOverride('CPU vs limit %', 'percent', 2),
      unitOverride('Mem vs limit %', 'percent', 2),
      { matcher: { id: 'byName', options: 'CPU vs limit %' }, properties: [
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 80 }, { color: 'red', value: 100 }] } },
      ] },
      { matcher: { id: 'byName', options: 'Mem vs limit %' }, properties: [
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 80 }, { color: 'red', value: 95 }] } },
      ] },
    ],
    'Latest CPU- and memory-limit utilization samples in the selected range, sorted by CPU utilization. Containers without limits may be absent.'));

  // --- Cluster events (k8sobjects receiver -> otel_logs) ------------------
  // Event metadata lives in the event JSON Body (regarding.namespace, not a resource
  // attribute), so these tiles are cluster-wide and intentionally ignore the namespace filter.
  p.push(row('5. Kubernetes Events', 56));
  const EVT = `ScopeName LIKE '%k8sobjectsreceiver%' AND ${TF}`;
  const EJ = (p2) => `JSONExtractString(Body, 'object', ${p2})`;
  p.push(stat('Warning events during selected range', { h: 8, w: 6, x: 0, y: 57 },
    `SELECT countIf(${EJ("'type'")} = 'Warning') AS value FROM ${DB}.otel_logs WHERE ${EVT}`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 10 }] },
      desc: 'Number of Kubernetes events classified as Warning during the selected time range. Repeated warnings usually indicate scheduling, image, storage, or health-check problems.' }));
  p.push(table('Most frequent Kubernetes event reasons', { h: 8, w: 18, x: 6, y: 57 },
    `SELECT ${EJ("'reason'")} AS "Reason",\n       ${EJ("'type'")} AS "Type",\n       ${EJ("'regarding', 'kind'")} AS "Object kind",\n       count() AS "Count"\nFROM ${DB}.otel_logs\nWHERE ${EVT}\nGROUP BY 1, 2, 3\nORDER BY "Count" DESC\nLIMIT 15`,
    [{ matcher: { id: 'byName', options: 'Type' }, properties: [
      { id: 'mappings', value: [{ type: 'value', options: { Warning: { color: 'red', index: 0 }, Normal: { color: 'green', index: 1 } } }] },
      { id: 'custom.cellOptions', value: { type: 'color-text' } },
    ] },
     unitOverride('Count', 'short', 0)],
    'The 15 most frequent Kubernetes event reasons during the selected time range, grouped by event type and affected object kind.'));
  p.push(table('Most recent Kubernetes events', { h: 10, w: 24, x: 0, y: 65 },
    `SELECT Timestamp AS "Time",\n       ${EJ("'type'")} AS "Type",\n       ${EJ("'reason'")} AS "Reason",\n       concat(${EJ("'regarding', 'kind'")}, ' ', ${EJ("'regarding', 'namespace'")}, '/', ${EJ("'regarding', 'name'")}) AS "Object",\n       ${EJ("'note'")} AS "Message"\nFROM ${DB}.otel_logs\nWHERE ${EVT}\nORDER BY Timestamp DESC\nLIMIT 100`,
    [
      { matcher: { id: 'byName', options: 'Time' }, properties: [{ id: 'custom.width', value: 180 }] },
      { matcher: { id: 'byName', options: 'Type' }, properties: [{ id: 'custom.width', value: 90 },
        { id: 'mappings', value: [{ type: 'value', options: { Warning: { color: 'red', index: 0 }, Normal: { color: 'green', index: 1 } } }] },
        { id: 'custom.cellOptions', value: { type: 'color-text' } }] },
    ],
    'The 100 newest Kubernetes events in the selected time range. Warning events are shown in red and Normal events in green.'));

  const nsVar = queryVar('namespace', 'Namespace',
    `SELECT DISTINCT ${RA('k8s.namespace.name')} FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF} ORDER BY 1`);
  return dashboard('clickstack-k8s-overview', 'ClickStack - Kubernetes Cluster Overview',
    'Cluster and workload health from the OpenTelemetry k8s cluster/kubelet/k8sobjects receivers (otel_metrics_gauge + otel_logs): nodes, pods, CPU/memory, restarts, container-vs-limit utilization, and cluster events.', p, [nsVar]);
}

// ===========================================================================
// 3. Logs & Errors Overview (logs)
// ===========================================================================
function logsOverview() {
  const p = [];
  const ERR = LOG_ERR;
  const W = `${TF} ${SVC}`;
  p.push(intro(
    "## Logs & errors\nOpenTelemetry logs stored in ClickHouse for the selected services and time range. **Error** counts include both *Error* and *Fatal* severities. The `/sec` cards are **averages over the selected range**; trend charts show **counts per time bucket**. If nothing appears, widen the time range and check the **Service** filter and datasource above.", 5));

  p.push(row('1. Log Overview', 5));
  p.push(stat('Average logs/sec (selected range)', { h: 4, w: 6, x: 0, y: 6 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${W}`,
    { unit: 'cps', decimals: 2, desc: 'Average log records ingested per second across the selected time range. High or low values are not inherently unhealthy; compare with the normal traffic baseline.' }));
  p.push(stat('Average error and fatal logs/sec', { h: 4, w: 6, x: 6, y: 6 },
    `SELECT countIf(${ERR}) / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${W}`,
    { unit: 'cps', decimals: 2, colorMode: 'none', thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] },
      desc: 'Average Error- and Fatal-severity log records per second across the selected time range.' }));
  p.push(stat('Error and fatal share of logs', { h: 4, w: 6, x: 12, y: 6 },
    `SELECT 100 * countIf(${ERR}) / nullIf(count(), 0) AS value FROM ${DB}.otel_logs WHERE ${W}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 2 }, { color: 'red', value: 10 }] },
      desc: 'Percentage of all matching logs classified as Error or Fatal. Green is below 2%, yellow 2–9.99%, red 10% or higher; tune these defaults to the workload.' }));
  p.push(stat('Fatal logs in selected range', { h: 4, w: 6, x: 18, y: 6 },
    `SELECT countIf(${LOG_FATAL}) AS value FROM ${DB}.otel_logs WHERE ${W}`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] },
      desc: 'Total Fatal-severity log records in the selected time range. Any value above zero is shown in red.' }));

  // Group by a NORMALIZED severity bucket (info vs information, ERROR vs error all
  // collapse to one series) derived from SeverityNumber, not the raw text.
  p.push(row('2. Log Trends', 10));
  p.push(timeseries('Log count per time bucket by severity', { h: 8, w: 12, x: 0, y: 11 },
    `SELECT ${TI} AS time, ${SEV_NORM} AS severity, count() AS logs\nFROM ${DB}.otel_logs\nWHERE ${W}\nGROUP BY time, severity ORDER BY time`,
    { unit: 'short', decimals: 0, stacking: 'normal', fillOpacity: 25, desc: 'Number of log records in each Grafana time bucket, stacked by severity.',
      overrides: [
        { matcher: { id: 'byName', options: 'fatal' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'red' } }] },
        { matcher: { id: 'byName', options: 'error' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'orange' } }] },
        { matcher: { id: 'byName', options: 'warn' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'yellow' } }] },
        { matcher: { id: 'byName', options: 'info' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'blue' } }] },
        { matcher: { id: 'byName', options: 'debug' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: 'purple' } }] },
        { matcher: { id: 'byName', options: 'trace' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: '#808080' } }] },
        { matcher: { id: 'byName', options: 'unspecified' }, properties: [{ id: 'color', value: { mode: 'fixed', fixedColor: '#808080' } }] },
      ] }));
  p.push(timeseries('Error and fatal logs per interval by service', { h: 8, w: 12, x: 12, y: 11 },
    `SELECT ${TI} AS time, ServiceName AS service, count() AS errors\nFROM ${DB}.otel_logs\nWHERE ${W} AND ${ERR}\nGROUP BY time, service HAVING errors > 0 ORDER BY time`,
    { unit: 'short', decimals: 0, stacking: 'normal', fillOpacity: 25, desc: 'Error- and Fatal-severity log records per time bucket for each selected service. Values are counts, not events per second.' }));

  p.push(row('3. Error Details', 19));
  p.push(table('Services generating the most error and fatal logs', { h: 9, w: 8, x: 0, y: 20 },
    `SELECT ServiceName AS "Service",\n       count() AS "Error logs",\n       100 * count() / nullIf((SELECT count() FROM ${DB}.otel_logs WHERE ${W} AND ${ERR}), 0) AS "% of errors"\nFROM ${DB}.otel_logs\nWHERE ${W} AND ${ERR}\nGROUP BY 1 ORDER BY 2 DESC LIMIT 15`,
    [
      { matcher: { id: 'byName', options: '% of errors' }, properties: [
        { id: 'unit', value: 'percent' }, { id: 'decimals', value: 2 }, { id: 'displayName', value: 'Share of all error logs' }] },
      unitOverride('Error logs', 'short', 0),
    ],
    "Ranks services by Error- and Fatal-severity log count. 'Share of all error logs' is the service's portion of matching error logs, not its request error rate."));
  p.push(table('100 most recent error and fatal logs', { h: 9, w: 16, x: 8, y: 20 },
    `SELECT Timestamp AS "Time",\n       ServiceName AS "Service",\n       ${SEV_NORM} AS "Severity",\n       substring(Body, 1, 200) AS "Message"\nFROM ${DB}.otel_logs\nWHERE ${W} AND ${ERR}\nORDER BY Timestamp DESC LIMIT 100`,
    [{ matcher: { id: 'byName', options: 'Time' }, properties: [{ id: 'custom.width', value: 180 }] },
     { matcher: { id: 'byName', options: 'Severity' }, properties: [{ id: 'custom.width', value: 90 }] },
     { matcher: { id: 'byName', options: 'Severity' }, properties: [
       { id: 'mappings', value: [{ type: 'value', options: { fatal: { color: 'red', index: 0 }, error: { color: 'orange', index: 1 } } }] },
       { id: 'custom.cellOptions', value: { type: 'color-text' } }] }],
    'The 100 newest Error- or Fatal-severity log records matching the current filters. Messages are truncated to 200 characters.'));

  const svcVar = queryVar('service', 'Service',
    `SELECT DISTINCT ServiceName FROM ${DB}.otel_logs WHERE ${TF} AND ServiceName != '' ORDER BY ServiceName`);
  return dashboard('clickstack-logs-overview', 'ClickStack - Logs & Errors Overview',
    'Log throughput and error analysis from OpenTelemetry logs in ClickHouse (otel_logs): volume by severity, error rate, and recent errors.', p, [svcVar]);
}

// ===========================================================================
// 4. Overview — one pane combining top signals from all three
// ===========================================================================
function execSummary() {
  const p = [];
  const MF = '$__timeFilter(TimeUnix)';
  const MI = '$__timeInterval(TimeUnix)';
  const RA = (k) => `ResourceAttributes['${k}']`;
  const AT = (k) => `Attributes['${k}']`;
  const ERR = LOG_ERR;

  p.push(intro(
    "## Overview\nThe single pane to open first: **is anything wrong right now, and where?** Top signals for application requests, Kubernetes health, resource utilization, logs, and recent cluster events — collected by the OpenTelemetry Collector and queried from ClickHouse. All panels honor the selected time range: **rates and percentiles cover the full range**, Kubernetes and utilization status use the **latest sample**, and time-series counts are **per chart interval**. Drill into **Infrastructure**, **Kubernetes**, **Service Health**, or **Logs** for detail. No data usually means telemetry isn't being collected — check the OTel Collector and the ClickHouse datasource.", 5));

  // --- Services -----------------------------------------------------------
  p.push(row('1. Application Request Health', 5));
  p.push(stat('Average server request rate', { h: 5, w: 6, x: 0, y: 6 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'reqps', decimals: 2, desc: 'Average server requests per second over the selected time range. Each OpenTelemetry server span is counted as one request.' }));
  p.push(stat('Server request error rate', { h: 5, w: 6, x: 6, y: 6 },
    `SELECT 100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] },
      desc: 'Percentage of server requests marked Error over the selected time range. Green below 1%, yellow 1–4.99%, red 5% or higher.' }));
  p.push(stat('95th-percentile server latency', { h: 5, w: 6, x: 12, y: 6 },
    `SELECT quantile(0.95)(Duration) / 1e6 AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'ms', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 500 }, { color: 'red', value: 1000 }] },
      desc: '95% of server requests completed within this duration during the selected time range.' }));
  p.push(stat('Services receiving requests', { h: 5, w: 6, x: 18, y: 6 },
    `SELECT count(DISTINCT ServiceName) AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'short', decimals: 0, desc: 'Distinct service names that reported at least one server request during the selected time range.' }));
  p.push(timeseries('Server requests per chart interval', { h: 6, w: 12, x: 0, y: 11 },
    `SELECT ${TI} AS time, count() AS requests\nFROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}\nGROUP BY time ORDER BY time`,
    { unit: 'short', decimals: 0, fillOpacity: 20, legend: false, interval: '5m', desc: 'Number of server requests in each automatic Grafana chart interval. Interval width changes when the time range changes.' }));
  p.push(timeseries('Server request error rate over time', { h: 6, w: 12, x: 12, y: 11 },
    `SELECT ${TI} AS time, 100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS error_pct\nFROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}\nGROUP BY time ORDER BY time`,
    { unit: 'percent', fillOpacity: 20, legend: false, interval: '5m', desc: 'Percentage of server requests marked Error in each chart interval; lower is better.' }));

  // --- Kubernetes ---------------------------------------------------------
  p.push(row('2. Kubernetes Workload Health', 17));
  p.push(stat('Ready nodes (latest in range)', { h: 5, w: 6, x: 0, y: 18 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.node.name')} AS n, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.node.condition_ready' AND ${MF}\n  GROUP BY n HAVING v = 1)`,
    { unit: 'short', decimals: 0, desc: 'Nodes whose latest Ready condition in the selected range is true. Compare with the expected cluster node count; any decrease requires investigation.' }));
  p.push(stat('Running pods (latest in range)', { h: 5, w: 6, x: 6, y: 18 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.pod.uid')} AS u, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF}\n  GROUP BY u HAVING v = 2)`,
    { unit: 'short', decimals: 0, desc: 'Pods whose latest phase in the selected range is Running. Successfully completed pods are not included.' }));
  p.push(stat('Pods pending, failed, or unknown', { h: 5, w: 6, x: 12, y: 18 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.pod.uid')} AS u, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF}\n  GROUP BY u HAVING v NOT IN (2, 3))`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] },
      desc: 'Pods whose latest phase is neither Running nor Succeeded. Any non-zero result should be investigated.' }));
  p.push(stat('Container restarts during selected range', { h: 5, w: 6, x: 18, y: 18 },
    `SELECT sum(d) AS value FROM (\n  SELECT concat(${RA('k8s.pod.uid')}, '/', ${RA('k8s.container.name')}) AS c, max(Value) - min(Value) AS d\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.container.restarts' AND ${MF}\n  GROUP BY c)`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 10 }] },
      desc: 'Increase in container restart counters during the selected time range, summed across the cluster. Longer ranges may naturally produce larger totals.' }));

  // --- Resource utilization ------------------------------------------------
  p.push(row('3. Resource Utilization', 23));
  p.push(stat('Cluster CPU utilization', { h: 5, w: 6, x: 0, y: 24 },
    `SELECT 100 * avg(busy) AS value FROM (\n  SELECT ${RA('host.name')} AS host, ${AT('cpu')} AS cpu, TimeUnix,\n         sumIf(Value, ${AT('state')} != 'idle') AS busy\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName = 'system.cpu.utilization' AND ${MF}\n  GROUP BY host, cpu, TimeUnix)`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 75 }, { color: 'red', value: 90 }] },
      desc: 'Average non-idle CPU across every reporting host over the selected range. Green below 75%, yellow 75–89%, red 90% or higher. Open Infrastructure to see which host is hot.' }));
  p.push(stat('Cluster memory utilization', { h: 5, w: 6, x: 6, y: 24 },
    `SELECT 100 * avgIf(Value, ${AT('state')} = 'used') AS value FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.memory.utilization' AND ${MF}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 80 }, { color: 'red', value: 92 }] },
      desc: 'Average used-memory percentage across every reporting host over the selected range. Unlike CPU there is no throttling safety net — exhaustion triggers the OOM killer.' }));
  p.push(stat('Lowest volume free %', { h: 5, w: 6, x: 12, y: 24 },
    `SELECT 100 * min(avail / nullIf(cap, 0)) AS value FROM (\n  SELECT host, mountpoint, sumIf(v, st = 'free') AS avail, sum(v) AS cap FROM (\n    SELECT ${RA('host.name')} AS host, ${AT('mountpoint')} AS mountpoint, ${AT('state')} AS st,\n           argMax(Value, TimeUnix) AS v\n    FROM ${DB}.otel_metrics_sum\n    WHERE MetricName = 'system.filesystem.usage' AND ${MF}\n    GROUP BY host, mountpoint, st)\n  GROUP BY host, mountpoint)`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'red', value: null }, { color: 'yellow', value: 15 }, { color: 'green', value: 25 }] },
      desc: 'Free-space percentage on the most constrained mounted volume. That volume runs out first, so it governs the whole cluster — and because it is measured per volume, one full data disk cannot be hidden by healthy volumes on the same host. Open Infrastructure to see which volume it is.' }));
  p.push(stat('Cluster health score', { h: 5, w: 6, x: 18, y: 24 },
    `SELECT 100 * n.ready * p.ok AS value\nFROM (\n  SELECT countIf(v = 1) / nullIf(count(), 0) AS ready FROM (\n    SELECT ${RA('k8s.node.name')} AS n, argMax(Value, TimeUnix) AS v\n    FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.node.condition_ready' AND ${MF}\n    GROUP BY n)) n\nCROSS JOIN (\n  SELECT countIf(v IN (2, 3)) / nullIf(count(), 0) AS ok FROM (\n    SELECT ${RA('k8s.pod.uid')} AS u, argMax(Value, TimeUnix) AS v\n    FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF}\n    GROUP BY u)) p`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'red', value: null }, { color: 'yellow', value: 95 }, { color: 'green', value: 100 }] },
      desc: 'Composite availability score: the share of nodes that are Ready multiplied by the share of pods that are Running or Succeeded, both from their latest sample. 100% means every node and every pod is where it should be; anything less means at least one is not.' }));

  // --- Logs ---------------------------------------------------------------
  p.push(row('4. Application Logs', 29));
  p.push(stat('Average log record rate', { h: 5, w: 6, x: 0, y: 30 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'cps', decimals: 2, desc: 'Average number of log records ingested per second over the selected time range.' }));
  p.push(stat('Average error and fatal log rate', { h: 5, w: 6, x: 6, y: 30 },
    `SELECT countIf(${ERR}) / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'cps', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] },
      desc: 'Average error-or-higher log records per second (OpenTelemetry severity 17+ or Error/Fatal severity text).' }));
  p.push(stat('Error and fatal share of logs', { h: 5, w: 6, x: 12, y: 30 },
    `SELECT 100 * countIf(${ERR}) / nullIf(count(), 0) AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 2 }, { color: 'red', value: 10 }] },
      desc: 'Percentage of all log records classified as Error or Fatal. Green below 2%, yellow 2–9.99%, red 10% or higher.' }));
  p.push(stat('Fatal logs in selected range', { h: 5, w: 6, x: 18, y: 30 },
    `SELECT countIf(${LOG_FATAL}) AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] },
      desc: 'Total Fatal log records during the selected time range. Any non-zero value is red.' }));
  p.push(timeseries('Log records per interval by severity', { h: 6, w: 12, x: 0, y: 35 },
    `SELECT ${TI} AS time, ${SEV_NORM} AS severity, count() AS logs\nFROM ${DB}.otel_logs WHERE ${TF}\nGROUP BY time, severity ORDER BY time`,
    { unit: 'short', decimals: 0, stacking: 'normal', fillOpacity: 25, interval: '5m', desc: 'Log record count in each chart interval, stacked by OpenTelemetry severity. Interval width changes with the selected time range.' }));
  p.push(timeseries('Error and fatal logs per interval by service', { h: 6, w: 12, x: 12, y: 35 },
    `SELECT ${TI} AS time, ServiceName AS service, count() AS errors\nFROM ${DB}.otel_logs WHERE ${TF} AND ${ERR}\nGROUP BY time, service HAVING errors > 0 ORDER BY time`,
    { unit: 'short', decimals: 0, stacking: 'normal', fillOpacity: 25, interval: '5m', desc: 'Error-or-higher log record count per chart interval, grouped by reporting service.' }));

  // --- Attention table ----------------------------------------------------
  p.push(row('5. Service Health Details', 41));
  p.push(table('Service request health', { h: 9, w: 24, x: 0, y: 42 },
    `SELECT ServiceName AS "Service",\n       count() / ${WINDOW_S} AS "Req/s",\n       countIf(StatusCode = 'Error') AS "Errors",\n       100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS "Error %",\n       quantile(0.95)(Duration) / 1e6 AS "p95 ms"\nFROM ${DB}.otel_traces\nWHERE ${TF} AND ${SERVER}\nGROUP BY ServiceName\nORDER BY countIf(StatusCode = 'Error') / nullIf(count(), 0) DESC, count() / ${WINDOW_S} DESC`,
    [
      unitOverride('Req/s', 'reqps', 2),
      unitOverride('Error %', 'percent', 2),
      unitOverride('p95 ms', 'ms', 2),
      { matcher: { id: 'byName', options: 'Error %' }, properties: [
        { id: 'custom.cellOptions', value: { type: 'color-background', mode: 'gradient' } },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] } },
      ] },
      unitOverride('Errors', 'short', 0),
      { matcher: { id: 'byName', options: 'p95 ms' }, properties: [
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 500 }, { color: 'red', value: 1000 }] } },
      ] },
    ],
    'Per-service request rate, error count, error percentage, and 95th-percentile latency over the selected time range, sorted by highest error percentage.'));

  // --- Recent cluster events (k8sobjects receiver -> otel_logs) -------------
  p.push(row('6. Recent Cluster Events', 51));
  const EVT = `ScopeName LIKE '%k8sobjectsreceiver%' AND ${TF}`;
  const EJ = (p2) => `JSONExtractString(Body, 'object', ${p2})`;
  p.push(table('Most recent Kubernetes events', { h: 10, w: 24, x: 0, y: 52 },
    `SELECT Timestamp AS "Time",\n       ${EJ("'type'")} AS "Type",\n       ${EJ("'reason'")} AS "Reason",\n       concat(${EJ("'regarding', 'kind'")}, ' ', ${EJ("'regarding', 'namespace'")}, '/', ${EJ("'regarding', 'name'")}) AS "Object",\n       ${EJ("'note'")} AS "Message"\nFROM ${DB}.otel_logs\nWHERE ${EVT}\nORDER BY Timestamp DESC\nLIMIT 50`,
    [
      { matcher: { id: 'byName', options: 'Time' }, properties: [{ id: 'custom.width', value: 180 }] },
      { matcher: { id: 'byName', options: 'Type' }, properties: [{ id: 'custom.width', value: 90 },
        { id: 'mappings', value: [{ type: 'value', options: { Warning: { color: 'red', index: 0 }, Normal: { color: 'green', index: 1 } } }] },
        { id: 'custom.cellOptions', value: { type: 'color-text' } }] },
      { matcher: { id: 'byName', options: 'Reason' }, properties: [{ id: 'custom.width', value: 190 }] },
    ],
    'The 50 most recent Kubernetes events, newest first. Events are the cluster narrating what it did — scheduling decisions, image pulls, probe failures, evictions — and they are usually the fastest way to explain a status change you just saw above. See the Kubernetes dashboard for aggregated event analysis.'));

  return dashboard('clickstack-exec-summary', 'ClickStack - Overview',
    'The single pane to open first: application request health, Kubernetes workload health, cluster resource utilization, log error signals, and recent cluster events — top signals from every ClickStack Grafana dashboard.', p);
}

// ===========================================================================
// 5. Infrastructure (hostmetrics + kubeletstats receivers)
// ===========================================================================
// Mirrors the section structure of the HyperDX "Infrastructure" dashboard:
// cluster health -> host health -> storage -> network -> resource headroom.
function hostOverview() {
  const p = [];
  const HN = "ResourceAttributes['host.name']";
  const NN = "ResourceAttributes['k8s.node.name']";
  const HOST = "AND ResourceAttributes['host.name'] IN (${host:sqlstring})";
  const AT = (k) => `Attributes['${k}']`;
  // Per-(host, cpu, scrape) busy fraction = sum of non-idle states; averaging that avoids
  // double-counting cores and multiple state rows per scrape.
  const busyInner = (extra) =>
    `SELECT ${extra}${HN} AS host, ${AT('cpu')} AS cpu, TimeUnix,\n         sumIf(Value, ${AT('state')} != 'idle') AS busy\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName = 'system.cpu.utilization' AND ${MFU} ${HOST}\n  GROUP BY host, cpu, TimeUnix${extra ? ', time' : ''}`;
  // Latest Ready condition per node in range. Node-scoped panels intentionally ignore the
  // Host filter — k8s.node.name and host.name are different dimensions.
  const nodeReady =
    `SELECT ${NN} AS n, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName = 'k8s.node.condition_ready' AND ${MFU}\n  GROUP BY n`;
  // Latest free/total bytes per mounted volume. `system.filesystem.usage` lives in the SUM
  // table and is split by a `state` attribute (used / free / reserved), so the volume total is
  // the sum of every state and free space is the `free` slice. Reporting per (host, mountpoint)
  // rather than per node is deliberate: a node can mount several volumes and it is always one
  // specific volume that fills up first.
  const volFs =
    `SELECT host, mountpoint, sumIf(v, st = 'free') AS avail, sum(v) AS cap FROM (\n    SELECT ${HN} AS host, ${AT('mountpoint')} AS mountpoint, ${AT('state')} AS st,\n           argMax(Value, TimeUnix) AS v\n    FROM ${DB}.otel_metrics_sum\n    WHERE MetricName = 'system.filesystem.usage' AND ${MFU} ${HOST}\n    GROUP BY host, mountpoint, st)\n  GROUP BY host, mountpoint`;
  // Same shape bucketed over time. Summing every state inside a bucket keeps the ratio correct
  // even when a bucket contains several scrapes, because both sides scale together.
  const volFsSeries =
    `SELECT ${MIU} AS time, concat(${HN}, ' ', ${AT('mountpoint')}) AS volume,\n         sumIf(Value, ${AT('state')} = 'free') AS avail, sum(Value) AS cap\n  FROM ${DB}.otel_metrics_sum\n  WHERE MetricName = 'system.filesystem.usage' AND ${MFU} ${HOST}\n  GROUP BY time, volume`;

  p.push(intro(
    "## Infrastructure\nThe physical and virtual foundation underneath ClickStack: **Kubernetes node health, host CPU/memory/load, per-volume storage, network, and capacity headroom**. Metrics come from the OpenTelemetry `hostmetrics` and `kubeletstats` receivers and are stored in ClickHouse. **Summary cards are averages or latest values over the selected time range**; charts use automatic Grafana intervals. The **Host** filter narrows host-level (`system.*`) panels, which includes every storage panel; the node status panels (`k8s.node.*`) always show the whole cluster. No data usually means the receiver isn't reporting.", 6));

  // --- Cluster health ------------------------------------------------------
  p.push(row('1. Cluster Health', 6));
  p.push(stat('Kubernetes nodes Ready %', { h: 5, w: 6, x: 0, y: 7 },
    `SELECT 100 * countIf(v = 1) / nullIf(count(), 0) AS value FROM (\n  ${nodeReady})`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'red', value: null }, { color: 'yellow', value: 90 }, { color: 'green', value: 100 }] },
      desc: 'Percentage of Kubernetes nodes whose latest Ready condition in the selected range is true. Anything below 100% means at least one node is not accepting workloads.' }));
  p.push(stat('Healthy nodes', { h: 5, w: 6, x: 6, y: 7 },
    `SELECT countIf(v = 1) AS value FROM (\n  ${nodeReady})`,
    { unit: 'short', decimals: 0, desc: 'Nodes reporting Ready = true on their most recent sample. Compare with the expected cluster size; a drop means capacity was lost.' }));
  p.push(stat('Unhealthy nodes (Not Ready)', { h: 5, w: 6, x: 12, y: 7 },
    `SELECT countIf(v != 1) AS value FROM (\n  ${nodeReady})`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] },
      desc: 'Nodes whose latest Ready condition is false or unknown. Any non-zero value is red and should be investigated immediately — pods on that node are not being scheduled.' }));
  p.push(stat('Hosts reporting metrics', { h: 5, w: 6, x: 18, y: 7 },
    `SELECT count(DISTINCT ${HN}) AS value FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.cpu.utilization' AND ${MFU} ${HOST}`,
    { unit: 'short', decimals: 0, desc: 'Distinct selected hosts that reported CPU utilization during the selected time range. Fewer hosts than expected means the host-metrics receiver stopped on one of them.' }));
  p.push(table('Node status & uptime', { h: 8, w: 24, x: 0, y: 12 },
    `SELECT g.node AS "Node",\n       if(g.ready = 1, 'Ready', 'Not Ready') AS "Status",\n       toUInt64(s.uptime) AS "Uptime"\nFROM (\n  SELECT ${NN} AS node,\n         argMax(Value, TimeUnix) AS ready\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName = 'k8s.node.condition_ready' AND ${MFU}\n  GROUP BY node) g\nLEFT JOIN (\n  SELECT ${NN} AS node, argMax(Value, TimeUnix) AS uptime\n  FROM ${DB}.otel_metrics_sum\n  WHERE MetricName = 'k8s.node.uptime' AND ${MFU}\n  GROUP BY node) s ON g.node = s.node\nORDER BY "Status" DESC, "Uptime" ASC`,
    [
      { matcher: { id: 'byName', options: 'Status' }, properties: [
        { id: 'mappings', value: [{ type: 'value', options: {
          'Ready': { text: 'Ready', color: 'green', index: 0 },
          'Not Ready': { text: 'Not Ready', color: 'red', index: 1 } } }] },
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
      ] },
      unitOverride('Uptime', 's', 0),
    ],
    'Latest sample per Kubernetes node: Ready status and how long the node has been up. A short uptime after an incident indicates the node rebooted. Per-host CPU and memory are in the Node health section below.'));

  // --- Node / host health --------------------------------------------------
  p.push(row('2. Host Health', 20));
  p.push(stat('Average CPU utilization', { h: 5, w: 6, x: 0, y: 21 },
    `SELECT 100 * avg(busy) AS value FROM (\n  ${busyInner('')})`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 75 }, { color: 'red', value: 90 }] },
      desc: 'Average non-idle CPU utilization across selected hosts and the full selected time range. Short spikes may be hidden by this average — check the CPU chart below.' }));
  p.push(stat('Average memory utilization', { h: 5, w: 6, x: 6, y: 21 },
    `SELECT 100 * avgIf(Value, ${AT('state')} = 'used') AS value FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.memory.utilization' AND ${MFU} ${HOST}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 80 }, { color: 'red', value: 92 }] },
      desc: 'Average used-memory percentage across selected hosts and the full selected time range. Green below 80%, yellow 80–92%, red 92% or higher.' }));
  p.push(stat('Average 1-minute load', { h: 5, w: 6, x: 12, y: 21 },
    `SELECT avg(Value) AS value FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.cpu.load_average.1m' AND ${MFU} ${HOST}`,
    { unit: 'none', decimals: 2, desc: "Average one-minute system load across selected hosts. Compare each host's load with its CPU-core count; load above the core count means processes are queuing for CPU." }));
  p.push(stat('Highest inode usage %', { h: 5, w: 6, x: 18, y: 21 },
    `SELECT 100 * max(used / nullIf(total, 0)) AS value FROM (\n  SELECT host, mountpoint, sumIf(v, st = 'used') AS used, sum(v) AS total FROM (\n    SELECT ${HN} AS host, ${AT('mountpoint')} AS mountpoint, ${AT('state')} AS st,\n           argMax(Value, TimeUnix) AS v\n    FROM ${DB}.otel_metrics_sum\n    WHERE MetricName = 'system.filesystem.inodes.usage' AND ${MFU} ${HOST}\n    GROUP BY host, mountpoint, st)\n  GROUP BY host, mountpoint)`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 75 }, { color: 'red', value: 90 }] },
      desc: 'Highest inode consumption of any mounted volume. A filesystem can refuse new files while still reporting free bytes, because it ran out of inodes rather than space — a workload creating very many small files (container layers, ClickHouse parts, log shards) hits this first.' }));
  p.push(timeseries('CPU utilization by host', { h: 8, w: 12, x: 0, y: 26 },
    `SELECT time, host, 100 * avg(busy) AS "cpu %" FROM (\n  ${busyInner(`${MIU} AS time, `)})\nGROUP BY time, host ORDER BY time`,
    { unit: 'percent', desc: 'Non-idle CPU percentage for each selected host over time. Sustained values above 75% warrant attention; above 90% are critical.' }));
  p.push(timeseries('Memory utilization by host', { h: 8, w: 12, x: 12, y: 26 },
    `SELECT ${MIU} AS time, ${HN} AS host, 100 * avgIf(Value, ${AT('state')} = 'used') AS "mem %"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'system.memory.utilization' AND ${MFU} ${HOST}\nGROUP BY time, host ORDER BY time`,
    { unit: 'percent', desc: 'Used-memory percentage for each selected host over time. Sustained values above 80% warrant attention; above 92% are critical.' }));
  p.push(timeseries('Load average (1m) by host', { h: 8, w: 12, x: 0, y: 34 },
    `SELECT ${MIU} AS time, ${HN} AS host, avg(Value) AS "load 1m"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'system.cpu.load_average.1m' AND ${MFU} ${HOST}\nGROUP BY time, host ORDER BY time`,
    { unit: 'none', desc: 'One-minute run-queue length per host. A load consistently above the host CPU-core count means work is waiting for CPU even if utilization looks acceptable.' }));
  p.push(timeseries('Paging activity by host (per chart interval)', { h: 8, w: 12, x: 12, y: 34 },
    `SELECT time, host, sum(d) AS "page operations" FROM (\n  SELECT ${MIU} AS time, ${HN} AS host,\n         concat(${AT('direction')}, '/', ${AT('type')}) AS s,\n         max(Value) - min(Value) AS d\n  FROM ${DB}.otel_metrics_sum\n  WHERE MetricName = 'system.paging.operations' AND ${MFU} ${HOST}\n  GROUP BY time, host, s)\nGROUP BY time, host ORDER BY time`,
    { unit: 'short', decimals: 0, desc: 'Pages moved between memory and disk by each host during each chart interval. This is the memory-pressure signal: a host with ample free memory pages almost never, so a rising line means the working set no longer fits in RAM and the system is trading latency for space. Correlate with the memory chart above.' }));

  p.push(table('Host averages over selected time range', { h: 9, w: 24, x: 0, y: 42 },
    `SELECT c.host AS "Host",\n       c.cpu AS "CPU %",\n       m.mem AS "Mem %",\n       m.load AS "Load 1m",\n       m.load15 AS "Load 15m"\nFROM (\n  SELECT host, 100 * avg(busy) AS cpu FROM (\n    ${busyInner('')})\n  GROUP BY host) c\nLEFT JOIN (\n  SELECT ${HN} AS host,\n         100 * avgIf(Value, MetricName = 'system.memory.utilization' AND ${AT('state')} = 'used') AS mem,\n         avgIf(Value, MetricName = 'system.cpu.load_average.1m') AS load,\n         avgIf(Value, MetricName = 'system.cpu.load_average.15m') AS load15\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName IN ('system.memory.utilization', 'system.cpu.load_average.1m', 'system.cpu.load_average.15m') AND ${MFU} ${HOST}\n  GROUP BY host) m ON c.host = m.host\nORDER BY c.cpu DESC`,
    [
      { matcher: { id: 'byName', options: 'CPU %' }, properties: [
        { id: 'unit', value: 'percent' }, { id: 'decimals', value: 2 },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 75 }, { color: 'red', value: 90 }] } },
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
      ] },
      { matcher: { id: 'byName', options: 'Mem %' }, properties: [
        { id: 'unit', value: 'percent' }, { id: 'decimals', value: 2 },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 80 }, { color: 'red', value: 92 }] } },
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
      ] },
      unitOverride('Load 1m', 'none', 2),
      unitOverride('Load 15m', 'none', 2),
    ],
    'Per-host averages over the full selected time range, sorted by average CPU utilization. These are not the latest samples.'));

  // Disk / network counters live in otel_metrics_sum; chart the per-interval delta.
  // --- Storage health ------------------------------------------------------
  p.push(row('3. Storage Health', 51));
  const ioSql = (metric) =>
    `SELECT time, host, sum(d) AS bytes FROM (\n  SELECT ${MIU} AS time, ${HN} AS host,\n         concat(${AT('device')}, '/', ${AT('direction')}) AS s,\n         max(Value) - min(Value) AS d\n  FROM ${DB}.otel_metrics_sum\n  WHERE MetricName = '${metric}' AND ${MFU} ${HOST}\n  GROUP BY time, host, s)\nGROUP BY time, host ORDER BY time`;
  // Per-(host, device) counter delta per bucket, summed per host.
  const diskDelta = (metric, alias) =>
    `SELECT time, host, sum(d) AS "${alias}" FROM (\n  SELECT ${MIU} AS time, ${HN} AS host,\n         concat(${AT('device')}, '/', ${AT('direction')}) AS s,\n         max(Value) - min(Value) AS d\n  FROM ${DB}.otel_metrics_sum\n  WHERE MetricName = '${metric}' AND ${MFU} ${HOST}\n  GROUP BY time, host, s)\nGROUP BY time, host ORDER BY time`;
  p.push(timeseries('Filesystem used % by volume', { h: 8, w: 12, x: 0, y: 52 },
    `SELECT time, volume, 100 * (cap - avail) / nullIf(cap, 0) AS "used %" FROM (\n  ${volFsSeries})\nWHERE cap > 0 ORDER BY time`,
    { unit: 'percent', desc: 'Percentage of each mounted volume in use, tracked separately per volume rather than rolled up per node — the volume backing container images and the one backing the database fill at completely different rates. Above 80% plan cleanup; above 90% the kubelet starts evicting pods and image pulls fail.' }));
  p.push(timeseries('Free filesystem capacity by volume', { h: 8, w: 12, x: 12, y: 52 },
    `SELECT ${MIU} AS time, concat(${HN}, ' ', ${AT('mountpoint')}) AS volume, avgIf(Value, ${AT('state')} = 'free') AS "free"\nFROM ${DB}.otel_metrics_sum\nWHERE MetricName = 'system.filesystem.usage' AND ${MFU} ${HOST}\nGROUP BY time, volume ORDER BY time`,
    { unit: 'decbytes', desc: 'Absolute free bytes on each mounted volume. A steadily falling line is the earliest reliable signal that you will run out of disk — extrapolate the slope to estimate when, and act before it reaches zero rather than after.' }));
  p.push(timeseries('Disk operations by host (per chart interval)', { h: 8, w: 12, x: 0, y: 60 },
    diskDelta('system.disk.operations', 'operations'),
    { unit: 'short', decimals: 0, desc: 'Read plus write operations completed by each host during each chart interval — the IOPS signal. This is a count per interval, not per second; interval width changes with the time range.' }));
  p.push(timeseries('Average disk latency by host', { h: 8, w: 12, x: 12, y: 60 },
    `SELECT t.time AS time, t.host AS host, 1000 * t.secs / nullIf(o.ops, 0) AS "ms/op"\nFROM (\n  SELECT time, host, sum(d) AS secs FROM (\n    SELECT ${MIU} AS time, ${HN} AS host,\n           concat(${AT('device')}, '/', ${AT('direction')}) AS s,\n           max(Value) - min(Value) AS d\n    FROM ${DB}.otel_metrics_sum\n    WHERE MetricName = 'system.disk.operation_time' AND ${MFU} ${HOST}\n    GROUP BY time, host, s)\n  GROUP BY time, host) t\nLEFT JOIN (\n  SELECT time, host, sum(d) AS ops FROM (\n    SELECT ${MIU} AS time, ${HN} AS host,\n           concat(${AT('device')}, '/', ${AT('direction')}) AS s,\n           max(Value) - min(Value) AS d\n    FROM ${DB}.otel_metrics_sum\n    WHERE MetricName = 'system.disk.operations' AND ${MFU} ${HOST}\n    GROUP BY time, host, s)\n  GROUP BY time, host) o ON t.time = o.time AND t.host = o.host\nORDER BY time`,
    { unit: 'ms', desc: 'Milliseconds of service time per disk operation (operation-time delta divided by operation delta). Unlike the volume charts this value is independent of the chart interval. Single-digit ms is healthy for SSD; a sustained climb means the disk is saturated.' }));
  p.push(timeseries('Disk I/O volume by host (per chart interval)', { h: 8, w: 24, x: 0, y: 68 },
    ioSql('system.disk.io'), { unit: 'decbytes', desc: 'Combined bytes read and written by each host during each chart interval. This is volume, not bytes per second — a wider time range means wider buckets and larger values.' }));

  // --- Network health ------------------------------------------------------
  p.push(row('4. Network Health', 76));
  p.push(timeseries('Network I/O volume by host (per chart interval)', { h: 8, w: 8, x: 0, y: 77 },
    ioSql('system.network.io'), { unit: 'decbytes', desc: 'Combined bytes received and transmitted by each host during each chart interval. Use it to spot traffic spikes and to correlate them with latency or error charts.' }));
  p.push(timeseries('Packets dropped by host (per chart interval)', { h: 8, w: 8, x: 8, y: 77 },
    diskDelta('system.network.dropped', 'dropped'),
    { unit: 'short', decimals: 0, desc: 'Network packets discarded by each host during each chart interval. Any sustained non-zero value points at buffer exhaustion, NIC saturation, or a misconfigured interface.' }));
  p.push(timeseries('Network interface errors by host (per chart interval)', { h: 8, w: 8, x: 16, y: 77 },
    diskDelta('system.network.errors', 'errors'),
    { unit: 'short', decimals: 0, desc: 'Interface-level receive and transmit errors per chart interval. Non-zero values usually indicate a physical problem — cabling, transceiver, or switch port — rather than an application fault.' }));

  // --- Capacity planning ---------------------------------------------------
  p.push(row('5. Resource Headroom', 85));
  p.push(stat('CPU headroom', { h: 5, w: 6, x: 0, y: 86 },
    `SELECT 100 - 100 * avg(busy) AS value FROM (\n  ${busyInner('')})`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'red', value: null }, { color: 'yellow', value: 10 }, { color: 'green', value: 25 }] },
      desc: 'Average unused CPU across selected hosts — how much compute you can still absorb. Below 25% is tight, below 10% means the next workload spike will cause contention.' }));
  p.push(stat('Memory headroom', { h: 5, w: 6, x: 6, y: 86 },
    `SELECT 100 - 100 * avgIf(Value, ${AT('state')} = 'used') AS value FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.memory.utilization' AND ${MFU} ${HOST}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'red', value: null }, { color: 'yellow', value: 10 }, { color: 'green', value: 20 }] },
      desc: 'Average unallocated memory across selected hosts. Memory has no equivalent of CPU throttling — running out triggers the OOM killer, so keep this above 20%.' }));
  p.push(stat('Lowest volume free %', { h: 5, w: 6, x: 12, y: 86 },
    `SELECT 100 * min(avail / nullIf(cap, 0)) AS value FROM (\n  ${volFs})`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'red', value: null }, { color: 'yellow', value: 15 }, { color: 'green', value: 25 }] },
      desc: 'Free-space percentage on the most constrained mounted volume anywhere in the fleet. This is the volume that runs out first, so it governs the whole cluster — and because it is measured per volume rather than per node, a single full data disk cannot be averaged away by healthy volumes on the same node.' }));
  p.push(stat('Total free memory', { h: 5, w: 6, x: 18, y: 86 },
    `SELECT sum(v) AS value FROM (\n  SELECT ${HN} AS host, argMaxIf(Value, TimeUnix, ${AT('state')} = 'free') AS v\n  FROM ${DB}.otel_metrics_sum\n  WHERE MetricName = 'system.memory.usage' AND ${MFU} ${HOST}\n  GROUP BY host)`,
    { unit: 'decbytes', decimals: 2, desc: 'Sum of the latest free-memory reading across selected hosts — the memory left for new workloads fleet-wide. Note this is a sum, so a large number can still hide one nearly-full host; check the per-host memory chart before relying on it.' }));
  p.push(timeseries('CPU & memory headroom over time', { h: 8, w: 12, x: 0, y: 91 },
    `SELECT c.time AS time, 100 - c.busy AS "CPU headroom %", 100 - m.used AS "Memory headroom %"\nFROM (\n  SELECT time, 100 * avg(busy) AS busy FROM (\n    ${busyInner(`${MIU} AS time, `)})\n  GROUP BY time) c\nLEFT JOIN (\n  SELECT ${MIU} AS time, 100 * avgIf(Value, ${AT('state')} = 'used') AS used\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName = 'system.memory.utilization' AND ${MFU} ${HOST}\n  GROUP BY time) m ON c.time = m.time\nORDER BY time`,
    { unit: 'percent', desc: 'Fleet-average spare CPU and spare memory over time. A steady downward slope over days or weeks is the capacity-planning signal — extrapolate it to decide when to add nodes.' }));
  p.push(timeseries('Free % by volume over time', { h: 8, w: 12, x: 12, y: 91 },
    `SELECT time, volume, 100 * avail / nullIf(cap, 0) AS "free %" FROM (\n  ${volFsSeries})\nWHERE cap > 0 ORDER BY time`,
    { unit: 'percent', desc: 'Free-space percentage per volume over time. Watch the slope, not the absolute value: a line falling a few percent per day tells you exactly how long you have before cleanup becomes urgent. This is the panel that turns a disk-full outage into a scheduled maintenance task.' }));

  const hostVar = queryVar('host', 'Host',
    `SELECT DISTINCT ${HN} FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.cpu.utilization' AND ${MFU} AND ${HN} != '' ORDER BY 1`);
  return dashboard('clickstack-infrastructure', 'ClickStack - Infrastructure',
    'The foundation underneath ClickStack: Kubernetes node health, host CPU/memory/load/paging, per-volume storage capacity and disk latency, network throughput and errors, and capacity headroom — from the OpenTelemetry hostmetrics and kubeletstats receivers.', p, [hostVar]);
}

// ===========================================================================
// 6. Latency Histograms (OTLP explicit-bucket histograms) — summary view
// ===========================================================================
// Higher-level than the HyperDX histogram dashboard: average latency (delta Sum / delta
// Count) + request rate rather than a full p50/p95/p99 bucket-interpolation breakdown.
function latencyHistograms() {
  const p = [];
  const INSTID = "ResourceAttributes['service.instance.id']";
  // Per-series (service, instance, attributes) delta of the cumulative Sum/Count columns.
  // Keying by the full series identity keeps counter resets and multi-instance safe.
  const deltaInner = (metrics, extraSelect, extraGroup) =>
    `SELECT ${extraSelect}ServiceName AS service,\n         max(Sum) - min(Sum) AS dsum, max(Count) - min(Count) AS dcount\n  FROM ${DB}.otel_metrics_histogram\n  WHERE MetricName IN (${metrics}) AND ${MFU} ${SVC}\n  GROUP BY service, ${INSTID}, toString(Attributes)${extraGroup}`;

  p.push(intro(
    "## Request latency & volume (metric-based)\nUses OpenTelemetry cumulative HTTP/RPC **histogram** metrics stored in ClickHouse. Cards show request-weighted **averages** computed from the change in histogram Sum and Count — they do **not** show the latency distribution or tail percentiles (p95/p99). *Server* = incoming requests; *client* = outgoing requests. Filter by **Service** above. No data usually means the application doesn't emit these histogram metrics — see **Service Health** for percentile latency from traces.", 6));

  p.push(row('1. At a Glance', 6));
  p.push(stat('Average incoming HTTP request latency', { h: 4, w: 8, x: 0, y: 7 },
    `SELECT sum(dsum) / nullIf(sum(dcount), 0) AS value FROM (\n  ${deltaInner("'http.server.duration'", '', '')})`,
    { unit: 'ms', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 250 }, { color: 'red', value: 1000 }] },
      desc: 'Request-weighted average duration of incoming HTTP requests over the selected range. This is a mean, not p95 or worst-case latency.' }));
  p.push(stat('Average incoming HTTP requests/sec', { h: 4, w: 8, x: 8, y: 7 },
    `SELECT sum(dcount) / ${WINDOW_S_SAFE} AS value FROM (\n  ${deltaInner("'http.server.duration'", '', '')})`,
    { unit: 'reqps', decimals: 2, desc: 'Average incoming HTTP request rate derived from histogram count changes over the selected range. No universal health threshold applies.' }));
  p.push(stat('Average outgoing HTTP request latency', { h: 4, w: 8, x: 16, y: 7 },
    `SELECT sum(dsum) / nullIf(sum(dcount), 0) AS value FROM (\n  ${deltaInner("'http.client.duration'", '', '')})`,
    { unit: 'ms', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 250 }, { color: 'red', value: 1000 }] },
      desc: 'Request-weighted average duration of outgoing HTTP calls made by the selected services. This is a mean and can hide slow tail requests.' }));

  p.push(row('2. Trends by Service', 11));
  p.push(timeseries('Average incoming HTTP latency by service', { h: 8, w: 12, x: 0, y: 12 },
    `SELECT time, service, sum(dsum) / greatest(sum(dcount), 1) AS "avg ms" FROM (\n  ${deltaInner("'http.server.duration'", `${MIU} AS time, `, ', time')})\nGROUP BY time, service ORDER BY time`,
    { unit: 'ms', desc: 'Request-weighted mean incoming HTTP latency for each service and time bucket. Use tracing views to investigate tail latency.' }));
  p.push(timeseries('Incoming HTTP requests per time bucket by service', { h: 8, w: 12, x: 12, y: 12 },
    `SELECT time, service, sum(dcount) AS requests FROM (\n  ${deltaInner("'http.server.duration'", `${MIU} AS time, `, ', time')})\nGROUP BY time, service ORDER BY time`,
    { unit: 'short', decimals: 0, desc: 'Incoming HTTP request count in each Grafana time bucket for each service. Bucket duration changes with the dashboard time range.' }));

  p.push(row('3. Service & Request Type', 20));
  p.push(table('Average latency by service and request type', { h: 10, w: 24, x: 0, y: 21 },
    `SELECT service AS "Service", metric AS "Metric",\n       sum(dsum) / greatest(sum(dcount), 1) AS "Avg ms",\n       toUInt64(sum(dcount)) AS "Requests"\nFROM (\n  SELECT ServiceName AS service, MetricName AS metric,\n         max(Sum) - min(Sum) AS dsum, max(Count) - min(Count) AS dcount\n  FROM ${DB}.otel_metrics_histogram\n  WHERE MetricName IN ('http.server.duration', 'http.client.duration', 'rpc.server.duration') AND ${MFU} ${SVC}\n  GROUP BY service, metric, ${INSTID}, toString(Attributes))\nGROUP BY service, metric\nHAVING "Requests" > 0\nORDER BY "Requests" DESC\nLIMIT 30`,
    [
      { matcher: { id: 'byName', options: 'Metric' }, properties: [
        { id: 'displayName', value: 'Request type' },
        { id: 'mappings', value: [{ type: 'value', options: {
          'http.server.duration': { text: 'Incoming HTTP', index: 0 },
          'http.client.duration': { text: 'Outgoing HTTP', index: 1 },
          'rpc.server.duration': { text: 'Incoming RPC', index: 2 } } }] },
      ] },
      { matcher: { id: 'byName', options: 'Avg ms' }, properties: [
        { id: 'unit', value: 'ms' }, { id: 'decimals', value: 2 },
        { id: 'displayName', value: 'Average latency' },
      ] },
      unitOverride('Requests', 'short', 0),
    ],
    'Request-weighted average latency and request count by service and request type. Only the 30 highest-volume combinations are shown.'));

  const svcVar = queryVar('service', 'Service',
    `SELECT DISTINCT ServiceName FROM ${DB}.otel_metrics_histogram WHERE ${MFU} AND ServiceName != '' ORDER BY ServiceName`);
  return dashboard('clickstack-latency-histograms', 'ClickStack - Services (Latency Histograms)',
    'Advanced companion to Service Health: request latency from OpenTelemetry explicit-bucket histogram metrics (otel_metrics_histogram) — average latency (delta Sum / delta Count) and request rate for HTTP server/client and RPC server calls. Only useful if your applications emit OTLP histogram metrics.', p, [svcVar]);
}

// ---- main -----------------------------------------------------------------
if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });
write('operations-center.json', execSummary());
write('service-health-golden-signals.json', serviceHealth());
write('kubernetes-cluster-overview.json', k8sOverview());
write('logs-errors-overview.json', logsOverview());
write('infrastructure.json', hostOverview());
write('advanced/latency-histograms.json', latencyHistograms());
console.log('done.');
