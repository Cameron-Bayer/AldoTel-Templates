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

function timeseries(title, gridPos, sql, { unit = 'short', stacking = 'none', fillOpacity = 10, legend = true, interval = '1m', desc, overrides } = {}) {
  const p = base('timeseries', title, gridPos, [target(sql, { format: 0 })]);
  if (desc) p.description = desc;
  p.interval = interval;
  p.fieldConfig.defaults = {
    unit,
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

  p.push(row('At a glance', 6));
  p.push(stat('Average incoming requests/sec (selected range)', { h: 4, w: 6, x: 0, y: 7 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'reqps', decimals: 1, desc: 'Average incoming server requests per second across the selected time range. Traffic has no universal good/bad threshold.' }));
  p.push(stat('Request error percentage', { h: 4, w: 6, x: 6, y: 7 },
    `SELECT 100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] },
      desc: 'Percentage of incoming server spans marked Error. Green below 1%, yellow 1–4.99%, red 5% or higher.' }));
  p.push(stat('95th-percentile request latency', { h: 4, w: 6, x: 12, y: 7 },
    `SELECT quantile(0.95)(Duration) / 1e6 AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'ms', decimals: 1, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 250 }, { color: 'red', value: 1000 }] },
      desc: '95% of matching incoming requests completed within this time. Default warning 250 ms, critical 1000 ms — tune to the service objective.' }));
  // Services burning error budget faster than the 99.9% SLO allows (error rate > 0.1%),
  // counting only services with enough traffic to be statistically meaningful.
  p.push(stat('Services below 99.9% availability', { h: 4, w: 6, x: 18, y: 7 },
    `SELECT count() AS value FROM (\n  SELECT ServiceName, countIf(StatusCode = 'Error') / nullIf(count(), 0) AS er\n  FROM ${DB}.otel_traces\n  WHERE ${W}\n  GROUP BY ServiceName\n  HAVING count() >= 20 AND er > 0.001)`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] },
      desc: 'Number of services with at least 20 requests whose observed error percentage exceeds 0.1% in the selected range. Red means one or more services are below target.' }));

  p.push(row('Traffic, errors & latency trends', 11));
  p.push(timeseries('Request count per time bucket by service', { h: 8, w: 12, x: 0, y: 12 },
    `SELECT ${TI} AS time, ServiceName, count() AS requests\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time, ServiceName\nORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25, desc: 'Incoming request count in each Grafana time bucket, stacked by service.' }));
  p.push(timeseries('Request latency percentiles', { h: 8, w: 12, x: 12, y: 12 },
    `SELECT ${TI} AS time,\n       quantile(0.50)(Duration) / 1e6 AS p50,\n       quantile(0.95)(Duration) / 1e6 AS p95,\n       quantile(0.99)(Duration) / 1e6 AS p99\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time\nORDER BY time`,
    { unit: 'ms', desc: 'Latency across all selected services: p50 is the median, p95 covers 95% of requests, and p99 highlights the slowest 1%.' }));

  p.push(timeseries('Request error percentage over time', { h: 8, w: 12, x: 0, y: 20 },
    `SELECT ${TI} AS time, 100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS error_pct\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time\nORDER BY time`,
    { unit: 'percent', fillOpacity: 20, desc: 'Percentage of incoming requests marked Error in each time bucket, aggregated across all selected services.' }));
  p.push(timeseries('Error count per time bucket by service', { h: 8, w: 12, x: 12, y: 20 },
    `SELECT ${TI} AS time, ServiceName, countIf(StatusCode = 'Error') AS errors\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time, ServiceName\nHAVING errors > 0\nORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25, desc: 'Number of incoming requests marked Error in each Grafana time bucket for each service. This is a count, not errors per second.' }));

  p.push(row('Service comparison', 28));
  p.push(table('Service traffic, errors, and latency', { h: 10, w: 24, x: 0, y: 29 },
    `SELECT ServiceName AS "Service",\n       round(count() / ${WINDOW_S}, 2) AS "Req/s",\n       countIf(StatusCode = 'Error') AS "Errors",\n       round(100 * countIf(StatusCode = 'Error') / nullIf(count(), 0), 2) AS "Error %",\n       round(quantile(0.50)(Duration) / 1e6, 1) AS "p50 ms",\n       round(quantile(0.95)(Duration) / 1e6, 1) AS "p95 ms",\n       round(quantile(0.99)(Duration) / 1e6, 1) AS "p99 ms"\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY ServiceName\nORDER BY count() DESC`,
    [
      unitOverride('Req/s', 'reqps', 2),
      unitOverride('Error %', 'percent', 2),
      unitOverride('p50 ms', 'ms', 1),
      unitOverride('p95 ms', 'ms', 1),
      unitOverride('p99 ms', 'ms', 1),
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
  p.push(row('99.9% availability target & error budget', 39));
  p.push(table('99.9% availability and error-budget use by service', { h: 9, w: 24, x: 0, y: 40 },
    `SELECT ServiceName AS "Service",\n       count() AS "Requests",\n       countIf(StatusCode = 'Error') AS "Errors",\n       round(100 * (1 - countIf(StatusCode = 'Error') / nullIf(count(), 0)), 3) AS "Availability %",\n       round(100 * (1 - (countIf(StatusCode = 'Error') / nullIf(count(), 0)) / 0.001), 1) AS "Budget left %",\n       round((countIf(StatusCode = 'Error') / nullIf(count(), 0)) / 0.001, 2) AS "Burn rate"\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY ServiceName\nHAVING count() >= 20\nORDER BY "Burn rate" DESC`,
    [
      unitOverride('Availability %', 'percent', 3),
      unitOverride('Budget left %', 'percent', 1),
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
        { id: 'displayName', value: 'Budget burn (x allowed rate)' }, { id: 'unit', value: 'none' }] },
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

  p.push(row('Cluster & workload health', 6));
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

  p.push(row('Node & workload resource usage', 11));
  p.push(timeseries('Node CPU usage', { h: 8, w: 12, x: 0, y: 12 },
    `SELECT ${MI} AS time, ${RA('k8s.node.name')} AS node, avg(Value) AS cpu_cores\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.node.cpu.usage' AND ${MF}\nGROUP BY time, node ORDER BY time`,
    { unit: 'cores', desc: "CPU cores used by each node over time. Compare with the node's allocatable CPU capacity." }));
  p.push(timeseries('Node memory usage', { h: 8, w: 12, x: 12, y: 12 },
    `SELECT ${MI} AS time, ${RA('k8s.node.name')} AS node, avg(Value) AS mem_bytes\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.node.memory.usage' AND ${MF}\nGROUP BY time, node ORDER BY time`,
    { unit: 'bytes_iec', desc: 'Memory used by each node over time. Compare with node capacity; this panel shows bytes, not utilization percentage.' }));

  // Top 10 pods by CPU only — pod-level series are high cardinality, so a full
  // breakdown is unreadable at a glance. Series are keyed by namespace/pod.
  p.push(timeseries('Top 10 pods by CPU usage', { h: 8, w: 12, x: 0, y: 20 },
    `SELECT ${MI} AS time, concat(${RA('k8s.namespace.name')}, '/', ${RA('k8s.pod.name')}) AS pod, avg(Value) AS cpu_cores\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.pod.cpu.usage' AND ${MF} ${NS}\n  AND concat(${RA('k8s.namespace.name')}, '/', ${RA('k8s.pod.name')}) IN (\n    SELECT concat(${RA('k8s.namespace.name')}, '/', ${RA('k8s.pod.name')}) AS pk\n    FROM ${DB}.otel_metrics_gauge\n    WHERE MetricName = 'k8s.pod.cpu.usage' AND ${MF} ${NS}\n    GROUP BY pk ORDER BY avg(Value) DESC LIMIT 10)\nGROUP BY time, pod ORDER BY time`,
    { unit: 'cores', legend: true, desc: 'CPU cores used by the ten pods with the highest average CPU usage over the selected time range.' }));
  // Available / desired replicas as a percentage (100% = fully rolled out).
  p.push(timeseries('Deployment replica availability', { h: 8, w: 12, x: 12, y: 20 },
    `SELECT time, deployment, 100 * available / greatest(desired, 1) AS "availability %"\nFROM (\n  SELECT ${MI} AS time,\n         concat(${RA('k8s.namespace.name')}, '/', ${RA('k8s.deployment.name')}) AS deployment,\n         avgIf(Value, MetricName = 'k8s.deployment.available') AS available,\n         avgIf(Value, MetricName = 'k8s.deployment.desired') AS desired\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName IN ('k8s.deployment.available', 'k8s.deployment.desired') AND ${MF} ${NS}\n  GROUP BY time, deployment)\nORDER BY time`,
    { unit: 'percent', desc: 'Available replicas divided by desired replicas for each deployment. 100% means all desired replicas are available; below 100% indicates unavailable replicas.' }));

  p.push(row('Workload details', 28));
  p.push(table('Top 20 pods by active memory', { h: 9, w: 12, x: 0, y: 29 },
    `SELECT ${RA('k8s.namespace.name')} AS "Namespace",\n       ${RA('k8s.pod.name')} AS "Pod",\n       argMax(Value, TimeUnix) AS "Memory"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.pod.memory.working_set' AND ${MF} ${NS}\nGROUP BY 1, 2\nORDER BY "Memory" DESC\nLIMIT 20`,
    [unitOverride('Memory', 'bytes_iec', 1)],
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
  p.push(row('Container resource use versus configured limits', 38));
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
    `SELECT ${RA('k8s.namespace.name')} AS "Namespace",\n       ${RA('k8s.pod.name')} AS "Pod",\n       ${RA('k8s.container.name')} AS "Container",\n       round(100 * argMaxIf(Value, TimeUnix, MetricName = 'k8s.container.cpu_limit_utilization'), 1) AS "CPU vs limit %",\n       round(100 * argMaxIf(Value, TimeUnix, MetricName = 'k8s.container.memory_limit_utilization'), 1) AS "Mem vs limit %"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName IN ('k8s.container.cpu_limit_utilization', 'k8s.container.memory_limit_utilization') AND ${MF} ${NS}\nGROUP BY 1, 2, 3\nORDER BY "CPU vs limit %" DESC\nLIMIT 25`,
    [
      unitOverride('CPU vs limit %', 'percent', 1),
      unitOverride('Mem vs limit %', 'percent', 1),
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
  p.push(row('Kubernetes events', 56));
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

  p.push(row('At a glance', 5));
  p.push(stat('Average logs/sec (selected range)', { h: 4, w: 6, x: 0, y: 6 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${W}`,
    { unit: 'cps', decimals: 1, desc: 'Average log records ingested per second across the selected time range. High or low values are not inherently unhealthy; compare with the normal traffic baseline.' }));
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
  p.push(row('Log trends', 10));
  p.push(timeseries('Log count per time bucket by severity', { h: 8, w: 12, x: 0, y: 11 },
    `SELECT ${TI} AS time, ${SEV_NORM} AS severity, count() AS logs\nFROM ${DB}.otel_logs\nWHERE ${W}\nGROUP BY time, severity ORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25, desc: 'Number of log records in each Grafana time bucket, stacked by severity.',
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
    { unit: 'short', stacking: 'normal', fillOpacity: 25, desc: 'Error- and Fatal-severity log records per time bucket for each selected service. Values are counts, not events per second.' }));

  p.push(row('Error details', 19));
  p.push(table('Services generating the most error and fatal logs', { h: 9, w: 8, x: 0, y: 20 },
    `SELECT ServiceName AS "Service",\n       count() AS "Error logs",\n       round(100 * count() / nullIf((SELECT count() FROM ${DB}.otel_logs WHERE ${W} AND ${ERR}), 0), 1) AS "% of errors"\nFROM ${DB}.otel_logs\nWHERE ${W} AND ${ERR}\nGROUP BY 1 ORDER BY 2 DESC LIMIT 15`,
    [
      { matcher: { id: 'byName', options: '% of errors' }, properties: [
        { id: 'unit', value: 'percent' }, { id: 'decimals', value: 1 }, { id: 'displayName', value: 'Share of all error logs' }] },
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
// 4. Executive Summary — one pane combining top signals from all three
// ===========================================================================
function execSummary() {
  const p = [];
  const MF = '$__timeFilter(TimeUnix)';
  const MI = '$__timeInterval(TimeUnix)';
  const RA = (k) => `ResourceAttributes['${k}']`;
  const ERR = LOG_ERR;

  p.push(intro(
    "## Executive summary\nTop signals for **application requests, Kubernetes health, and logs**, collected by the OpenTelemetry Collector and queried from ClickHouse. All panels honor the selected time range: **rates and percentiles cover the full range**, Kubernetes status uses the **latest sample**, and time-series counts are **per chart interval**. No data usually means telemetry isn't being collected — check the OTel Collector and the ClickHouse datasource.", 5));

  // --- Services -----------------------------------------------------------
  p.push(row('Application request health', 5));
  p.push(stat('Average server request rate', { h: 5, w: 6, x: 0, y: 6 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'reqps', decimals: 1, desc: 'Average server requests per second over the selected time range. Each OpenTelemetry server span is counted as one request.' }));
  p.push(stat('Server request error rate', { h: 5, w: 6, x: 6, y: 6 },
    `SELECT 100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] },
      desc: 'Percentage of server requests marked Error over the selected time range. Green below 1%, yellow 1–4.99%, red 5% or higher.' }));
  p.push(stat('95th-percentile server latency', { h: 5, w: 6, x: 12, y: 6 },
    `SELECT quantile(0.95)(Duration) / 1e6 AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'ms', decimals: 1, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 500 }, { color: 'red', value: 1000 }] },
      desc: '95% of server requests completed within this duration during the selected time range.' }));
  p.push(stat('Services receiving requests', { h: 5, w: 6, x: 18, y: 6 },
    `SELECT count(DISTINCT ServiceName) AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'short', decimals: 0, desc: 'Distinct service names that reported at least one server request during the selected time range.' }));
  p.push(timeseries('Server requests per chart interval', { h: 6, w: 12, x: 0, y: 11 },
    `SELECT ${TI} AS time, count() AS requests\nFROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}\nGROUP BY time ORDER BY time`,
    { unit: 'short', fillOpacity: 20, legend: false, interval: '5m', desc: 'Number of server requests in each automatic Grafana chart interval. Interval width changes when the time range changes.' }));
  p.push(timeseries('Server request error rate over time', { h: 6, w: 12, x: 12, y: 11 },
    `SELECT ${TI} AS time, 100 * countIf(StatusCode = 'Error') / nullIf(count(), 0) AS error_pct\nFROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}\nGROUP BY time ORDER BY time`,
    { unit: 'percent', fillOpacity: 20, legend: false, interval: '5m', desc: 'Percentage of server requests marked Error in each chart interval; lower is better.' }));

  // --- Kubernetes ---------------------------------------------------------
  p.push(row('Kubernetes workload health', 17));
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

  // --- Logs ---------------------------------------------------------------
  p.push(row('Application logs', 23));
  p.push(stat('Average log record rate', { h: 5, w: 6, x: 0, y: 24 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'cps', decimals: 1, desc: 'Average number of log records ingested per second over the selected time range.' }));
  p.push(stat('Average error and fatal log rate', { h: 5, w: 6, x: 6, y: 24 },
    `SELECT countIf(${ERR}) / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'cps', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] },
      desc: 'Average error-or-higher log records per second (OpenTelemetry severity 17+ or Error/Fatal severity text).' }));
  p.push(stat('Error and fatal share of logs', { h: 5, w: 6, x: 12, y: 24 },
    `SELECT 100 * countIf(${ERR}) / nullIf(count(), 0) AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 2 }, { color: 'red', value: 10 }] },
      desc: 'Percentage of all log records classified as Error or Fatal. Green below 2%, yellow 2–9.99%, red 10% or higher.' }));
  p.push(stat('Fatal logs in selected range', { h: 5, w: 6, x: 18, y: 24 },
    `SELECT countIf(${LOG_FATAL}) AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] },
      desc: 'Total Fatal log records during the selected time range. Any non-zero value is red.' }));
  p.push(timeseries('Log records per interval by severity', { h: 6, w: 12, x: 0, y: 29 },
    `SELECT ${TI} AS time, ${SEV_NORM} AS severity, count() AS logs\nFROM ${DB}.otel_logs WHERE ${TF}\nGROUP BY time, severity ORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25, interval: '5m', desc: 'Log record count in each chart interval, stacked by OpenTelemetry severity. Interval width changes with the selected time range.' }));
  p.push(timeseries('Error and fatal logs per interval by service', { h: 6, w: 12, x: 12, y: 29 },
    `SELECT ${TI} AS time, ServiceName AS service, count() AS errors\nFROM ${DB}.otel_logs WHERE ${TF} AND ${ERR}\nGROUP BY time, service HAVING errors > 0 ORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25, interval: '5m', desc: 'Error-or-higher log record count per chart interval, grouped by reporting service.' }));

  // --- Attention table ----------------------------------------------------
  p.push(row('Service health details', 35));
  p.push(table('Service request health', { h: 9, w: 24, x: 0, y: 36 },
    `SELECT ServiceName AS "Service",\n       round(count() / ${WINDOW_S}, 2) AS "Req/s",\n       countIf(StatusCode = 'Error') AS "Errors",\n       round(100 * countIf(StatusCode = 'Error') / nullIf(count(), 0), 2) AS "Error %",\n       round(quantile(0.95)(Duration) / 1e6, 1) AS "p95 ms"\nFROM ${DB}.otel_traces\nWHERE ${TF} AND ${SERVER}\nGROUP BY ServiceName\nORDER BY "Error %" DESC, "Req/s" DESC`,
    [
      unitOverride('Req/s', 'reqps', 2),
      unitOverride('Error %', 'percent', 2),
      unitOverride('p95 ms', 'ms', 1),
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

  return dashboard('clickstack-exec-summary', 'ClickStack - Executive Summary',
    'One-pane health overview across services, Kubernetes, and logs — top signals from all three ClickStack Grafana dashboards.', p);
}

// ===========================================================================
// 5. Host / OS Metrics (hostmetrics receiver) — summary view
// ===========================================================================
function hostOverview() {
  const p = [];
  const HN = "ResourceAttributes['host.name']";
  const HOST = "AND ResourceAttributes['host.name'] IN (${host:sqlstring})";
  const AT = (k) => `Attributes['${k}']`;
  // Per-(host, cpu, scrape) busy fraction = sum of non-idle states; averaging that avoids
  // double-counting cores and multiple state rows per scrape.
  const busyInner = (extra) =>
    `SELECT ${extra}${HN} AS host, ${AT('cpu')} AS cpu, TimeUnix,\n         sumIf(Value, ${AT('state')} != 'idle') AS busy\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName = 'system.cpu.utilization' AND ${MFU} ${HOST}\n  GROUP BY host, cpu, TimeUnix${extra ? ', time' : ''}`;

  p.push(intro(
    "## Host / OS metrics\nHost CPU, memory, load, disk, and network metrics collected by the OpenTelemetry Collector and stored in ClickHouse. **Summary cards are averages over the selected time range**; charts use automatic Grafana intervals. Use the **Host** filter to narrow the fleet. No data usually means the host-metrics receiver isn't reporting or the selected hosts had no samples.", 5));

  p.push(row('Fleet summary', 5));
  p.push(stat('Hosts reporting CPU metrics', { h: 4, w: 6, x: 0, y: 6 },
    `SELECT count(DISTINCT ${HN}) AS value FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.cpu.utilization' AND ${MFU} ${HOST}`,
    { unit: 'short', decimals: 0, desc: 'Distinct selected hosts that reported CPU utilization during the selected time range. Compare with the expected fleet size.' }));
  p.push(stat('Average CPU utilization (selected range)', { h: 4, w: 6, x: 6, y: 6 },
    `SELECT 100 * avg(busy) AS value FROM (\n  ${busyInner('')})`,
    { unit: 'percent', decimals: 1, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 75 }, { color: 'red', value: 90 }] },
      desc: 'Average non-idle CPU utilization across selected hosts and the full selected time range. Spikes may be hidden by this average.' }));
  p.push(stat('Average memory utilization (selected range)', { h: 4, w: 6, x: 12, y: 6 },
    `SELECT 100 * avgIf(Value, ${AT('state')} = 'used') AS value FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.memory.utilization' AND ${MFU} ${HOST}`,
    { unit: 'percent', decimals: 1, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 80 }, { color: 'red', value: 92 }] },
      desc: 'Average used-memory percentage across selected hosts and the full selected time range. Green below 80%, yellow 80–92%, red 92% or higher.' }));
  p.push(stat('Average 1-minute load (selected range)', { h: 4, w: 6, x: 18, y: 6 },
    `SELECT avg(Value) AS value FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.cpu.load_average.1m' AND ${MFU} ${HOST}`,
    { unit: 'none', decimals: 2, desc: "Average one-minute system load across selected hosts and the selected range. Compare each host's load with its CPU-core count; there is no universal fleet-wide threshold." }));

  p.push(row('CPU & memory trends', 10));
  p.push(timeseries('CPU utilization by host', { h: 8, w: 12, x: 0, y: 11 },
    `SELECT time, host, 100 * avg(busy) AS "cpu %" FROM (\n  ${busyInner(`${MIU} AS time, `)})\nGROUP BY time, host ORDER BY time`,
    { unit: 'percent', desc: 'Non-idle CPU percentage for each selected host over time. Sustained values above 75% warrant attention; above 90% are critical.' }));
  p.push(timeseries('Memory utilization by host', { h: 8, w: 12, x: 12, y: 11 },
    `SELECT ${MIU} AS time, ${HN} AS host, 100 * avgIf(Value, ${AT('state')} = 'used') AS "mem %"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'system.memory.utilization' AND ${MFU} ${HOST}\nGROUP BY time, host ORDER BY time`,
    { unit: 'percent', desc: 'Used-memory percentage for each selected host over time. Sustained values above 80% warrant attention; above 92% are critical.' }));

  // Disk / network I/O are cumulative counters (otel_metrics_sum); chart the per-interval
  // delta summed across devices + directions per host.
  p.push(row('Disk & network activity', 19));
  const ioSql = (metric) =>
    `SELECT time, host, sum(d) AS bytes FROM (\n  SELECT ${MIU} AS time, ${HN} AS host,\n         concat(${AT('device')}, '/', ${AT('direction')}) AS s,\n         max(Value) - min(Value) AS d\n  FROM ${DB}.otel_metrics_sum\n  WHERE MetricName = '${metric}' AND ${MFU} ${HOST}\n  GROUP BY time, host, s)\nGROUP BY time, host ORDER BY time`;
  p.push(timeseries('Disk I/O volume by host (per chart interval)', { h: 8, w: 12, x: 0, y: 20 },
    ioSql('system.disk.io'), { unit: 'decbytes', desc: 'Combined bytes read and written by each host during each chart interval. This is volume, not bytes per second.' }));
  p.push(timeseries('Network I/O volume by host (per chart interval)', { h: 8, w: 12, x: 12, y: 20 },
    ioSql('system.network.io'), { unit: 'decbytes', desc: 'Combined bytes received and transmitted by each host during each chart interval. This is volume, not bytes per second.' }));

  p.push(row('Per-host summary', 28));
  p.push(table('Host averages over selected time range', { h: 9, w: 24, x: 0, y: 29 },
    `SELECT c.host AS "Host",\n       round(c.cpu, 1) AS "CPU %",\n       round(m.mem, 1) AS "Mem %",\n       round(m.load, 2) AS "Load 1m",\n       round(m.swap, 1) AS "Swap %"\nFROM (\n  SELECT host, 100 * avg(busy) AS cpu FROM (\n    ${busyInner('')})\n  GROUP BY host) c\nLEFT JOIN (\n  SELECT ${HN} AS host,\n         100 * avgIf(Value, MetricName = 'system.memory.utilization' AND ${AT('state')} = 'used') AS mem,\n         avgIf(Value, MetricName = 'system.cpu.load_average.1m') AS load,\n         100 * avgIf(Value, MetricName = 'system.swap.utilization' AND ${AT('state')} = 'used') AS swap\n  FROM ${DB}.otel_metrics_gauge\n  WHERE MetricName IN ('system.memory.utilization', 'system.cpu.load_average.1m', 'system.swap.utilization') AND ${MFU} ${HOST}\n  GROUP BY host) m ON c.host = m.host\nORDER BY "CPU %" DESC`,
    [
      { matcher: { id: 'byName', options: 'CPU %' }, properties: [
        { id: 'unit', value: 'percent' }, { id: 'decimals', value: 1 },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 75 }, { color: 'red', value: 90 }] } },
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
      ] },
      { matcher: { id: 'byName', options: 'Mem %' }, properties: [
        { id: 'unit', value: 'percent' }, { id: 'decimals', value: 1 },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 80 }, { color: 'red', value: 92 }] } },
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
      ] },
      { matcher: { id: 'byName', options: 'Swap %' }, properties: [
        { id: 'unit', value: 'percent' }, { id: 'decimals', value: 1 },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 50 }, { color: 'red', value: 80 }] } },
        { id: 'custom.cellOptions', value: { type: 'color-text' } },
      ] },
      unitOverride('Load 1m', 'none', 2),
    ],
    'Per-host averages over the full selected time range, sorted by average CPU utilization. These are not the latest samples.'));

  const hostVar = queryVar('host', 'Host',
    `SELECT DISTINCT ${HN} FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'system.cpu.utilization' AND ${MFU} AND ${HN} != '' ORDER BY 1`);
  return dashboard('clickstack-host-os', 'ClickStack - Host / OS Metrics',
    'Host and OS health from the OpenTelemetry hostmetrics receiver (system.* in otel_metrics_gauge / otel_metrics_sum): CPU, memory, load, disk and network I/O per host.', p, [hostVar]);
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

  p.push(row('At a glance', 6));
  p.push(stat('Average incoming HTTP request latency', { h: 4, w: 8, x: 0, y: 7 },
    `SELECT sum(dsum) / nullIf(sum(dcount), 0) AS value FROM (\n  ${deltaInner("'http.server.duration'", '', '')})`,
    { unit: 'ms', decimals: 1, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 250 }, { color: 'red', value: 1000 }] },
      desc: 'Request-weighted average duration of incoming HTTP requests over the selected range. This is a mean, not p95 or worst-case latency.' }));
  p.push(stat('Average incoming HTTP requests/sec', { h: 4, w: 8, x: 8, y: 7 },
    `SELECT sum(dcount) / ${WINDOW_S_SAFE} AS value FROM (\n  ${deltaInner("'http.server.duration'", '', '')})`,
    { unit: 'reqps', decimals: 1, desc: 'Average incoming HTTP request rate derived from histogram count changes over the selected range. No universal health threshold applies.' }));
  p.push(stat('Average outgoing HTTP request latency', { h: 4, w: 8, x: 16, y: 7 },
    `SELECT sum(dsum) / nullIf(sum(dcount), 0) AS value FROM (\n  ${deltaInner("'http.client.duration'", '', '')})`,
    { unit: 'ms', decimals: 1, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 250 }, { color: 'red', value: 1000 }] },
      desc: 'Request-weighted average duration of outgoing HTTP calls made by the selected services. This is a mean and can hide slow tail requests.' }));

  p.push(row('Trends by service', 11));
  p.push(timeseries('Average incoming HTTP latency by service', { h: 8, w: 12, x: 0, y: 12 },
    `SELECT time, service, sum(dsum) / greatest(sum(dcount), 1) AS "avg ms" FROM (\n  ${deltaInner("'http.server.duration'", `${MIU} AS time, `, ', time')})\nGROUP BY time, service ORDER BY time`,
    { unit: 'ms', desc: 'Request-weighted mean incoming HTTP latency for each service and time bucket. Use tracing views to investigate tail latency.' }));
  p.push(timeseries('Incoming HTTP requests per time bucket by service', { h: 8, w: 12, x: 12, y: 12 },
    `SELECT time, service, sum(dcount) AS requests FROM (\n  ${deltaInner("'http.server.duration'", `${MIU} AS time, `, ', time')})\nGROUP BY time, service ORDER BY time`,
    { unit: 'short', desc: 'Incoming HTTP request count in each Grafana time bucket for each service. Bucket duration changes with the dashboard time range.' }));

  p.push(row('Service & request type', 20));
  p.push(table('Average latency by service and request type', { h: 10, w: 24, x: 0, y: 21 },
    `SELECT service AS "Service", metric AS "Metric",\n       round(sum(dsum) / greatest(sum(dcount), 1), 2) AS "Avg ms",\n       toUInt64(sum(dcount)) AS "Requests"\nFROM (\n  SELECT ServiceName AS service, MetricName AS metric,\n         max(Sum) - min(Sum) AS dsum, max(Count) - min(Count) AS dcount\n  FROM ${DB}.otel_metrics_histogram\n  WHERE MetricName IN ('http.server.duration', 'http.client.duration', 'rpc.server.duration') AND ${MFU} ${SVC}\n  GROUP BY service, metric, ${INSTID}, toString(Attributes))\nGROUP BY service, metric\nHAVING "Requests" > 0\nORDER BY "Requests" DESC\nLIMIT 30`,
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
  return dashboard('clickstack-latency-histograms', 'ClickStack - Request Latency & Volume',
    'Request latency from OpenTelemetry explicit-bucket histogram metrics (otel_metrics_histogram): average latency (delta Sum / delta Count) and request rate for HTTP server/client and RPC server calls.', p, [svcVar]);
}

// ---- main -----------------------------------------------------------------
if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });
write('executive-summary.json', execSummary());
write('service-health-golden-signals.json', serviceHealth());
write('kubernetes-cluster-overview.json', k8sOverview());
write('logs-errors-overview.json', logsOverview());
write('host-os-metrics.json', hostOverview());
write('advanced/latency-histograms.json', latencyHistograms());
console.log('done.');
