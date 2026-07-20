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

function stat(title, gridPos, sql, { unit = 'short', decimals = 2, thresholds } = {}) {
  const p = base('stat', title, gridPos, [target(sql, { format: 1 })]);
  p.fieldConfig.defaults = {
    unit,
    decimals,
    color: { mode: thresholds ? 'thresholds' : 'fixed', fixedColor: 'text' },
    thresholds: thresholds || { mode: 'absolute', steps: [{ color: 'text', value: null }] },
    mappings: [],
  };
  p.options = {
    reduceOptions: { calcs: ['lastNotNull'], fields: '', values: false },
    orientation: 'auto',
    textMode: 'auto',
    colorMode: thresholds ? 'value' : 'none',
    graphMode: 'area',
    justifyMode: 'auto',
  };
  return p;
}

function timeseries(title, gridPos, sql, { unit = 'short', stacking = 'none', fillOpacity = 10, legend = true, interval = '1m' } = {}) {
  const p = base('timeseries', title, gridPos, [target(sql, { format: 0 })]);
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
  p.options = {
    legend: { showLegend: legend, displayMode: 'table', placement: 'bottom', calcs: legend ? ['mean', 'max', 'lastNotNull'] : [] },
    tooltip: { mode: 'multi', sort: 'desc' },
  };
  return p;
}

function table(title, gridPos, sql, overrides = []) {
  const p = base('table', title, gridPos, [target(sql, { format: 1 })]);
  p.fieldConfig.defaults = { custom: { align: 'auto', cellOptions: { type: 'auto' }, filterable: true } };
  p.fieldConfig.overrides = overrides;
  p.options = { showHeader: true, cellHeight: 'sm', footer: { show: false } };
  return p;
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

// ===========================================================================
// 1. Service Health — Golden Signals (traces / RED)
// ===========================================================================
function serviceHealth() {
  const p = [];
  const W = `${TF} AND ${SERVER} ${SVC}`;
  p.push(stat('Requests / sec', { h: 4, w: 6, x: 0, y: 0 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'reqps', decimals: 1 }));
  p.push(stat('Error rate', { h: 4, w: 6, x: 6, y: 0 },
    `SELECT 100 * countIf(StatusCode = 'Error') / count() AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] } }));
  p.push(stat('Latency p95', { h: 4, w: 6, x: 12, y: 0 },
    `SELECT quantile(0.95)(Duration) / 1e6 AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'ms', decimals: 1 }));
  p.push(stat('Latency p99', { h: 4, w: 6, x: 18, y: 0 },
    `SELECT quantile(0.99)(Duration) / 1e6 AS value FROM ${DB}.otel_traces WHERE ${W}`,
    { unit: 'ms', decimals: 1 }));

  p.push(timeseries('Request volume by service', { h: 8, w: 12, x: 0, y: 4 },
    `SELECT ${TI} AS time, ServiceName, count() AS requests\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time, ServiceName\nORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25 }));
  p.push(timeseries('Latency percentiles (ms)', { h: 8, w: 12, x: 12, y: 4 },
    `SELECT ${TI} AS time,\n       quantile(0.50)(Duration) / 1e6 AS p50,\n       quantile(0.95)(Duration) / 1e6 AS p95,\n       quantile(0.99)(Duration) / 1e6 AS p99\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time\nORDER BY time`,
    { unit: 'ms' }));

  p.push(timeseries('Overall error rate (%)', { h: 8, w: 12, x: 0, y: 12 },
    `SELECT ${TI} AS time, 100 * countIf(StatusCode = 'Error') / count() AS error_pct\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time\nORDER BY time`,
    { unit: 'percent', fillOpacity: 20 }));
  p.push(timeseries('Errors per interval by service', { h: 8, w: 12, x: 12, y: 12 },
    `SELECT ${TI} AS time, ServiceName, countIf(StatusCode = 'Error') AS errors\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY time, ServiceName\nHAVING errors > 0\nORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25 }));

  p.push(table('Service breakdown (RED)', { h: 10, w: 24, x: 0, y: 20 },
    `SELECT ServiceName AS "Service",\n       round(count() / ${WINDOW_S}, 2) AS "Req/s",\n       countIf(StatusCode = 'Error') AS "Errors",\n       round(100 * countIf(StatusCode = 'Error') / count(), 2) AS "Error %",\n       round(quantile(0.50)(Duration) / 1e6, 1) AS "p50 ms",\n       round(quantile(0.95)(Duration) / 1e6, 1) AS "p95 ms",\n       round(quantile(0.99)(Duration) / 1e6, 1) AS "p99 ms"\nFROM ${DB}.otel_traces\nWHERE ${W}\nGROUP BY ServiceName\nORDER BY count() DESC`,
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
    ]));
  const svcVar = queryVar('service', 'Service',
    `SELECT DISTINCT ServiceName FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER} AND ServiceName != '' ORDER BY ServiceName`);
  return dashboard('clickstack-service-health', 'ClickStack · Service Health (Golden Signals)',
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
  p.push(stat('Nodes Ready', { h: 4, w: 6, x: 0, y: 0 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.node.name')} AS n, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.node.condition_ready' AND ${MF}\n  GROUP BY n HAVING v = 1)`,
    { unit: 'short', decimals: 0 }));
  p.push(stat('Pods Running', { h: 4, w: 6, x: 6, y: 0 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.pod.uid')} AS u, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF} ${NS}\n  GROUP BY u HAVING v = 2)`,
    { unit: 'short', decimals: 0 }));
  p.push(stat('Pods Not Running', { h: 4, w: 6, x: 12, y: 0 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.pod.uid')} AS u, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF} ${NS}\n  GROUP BY u HAVING v != 2)`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] } }));
  p.push(stat('Container Restarts', { h: 4, w: 6, x: 18, y: 0 },
    `SELECT sum(v) AS value FROM (\n  SELECT concat(${RA('k8s.pod.uid')}, '/', ${RA('k8s.container.name')}) AS c, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.container.restarts' AND ${MF} ${NS}\n  GROUP BY c)`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 10 }] } }));

  p.push(timeseries('Node CPU usage (cores)', { h: 8, w: 12, x: 0, y: 4 },
    `SELECT ${MI} AS time, ${RA('k8s.node.name')} AS node, avg(Value) AS cpu_cores\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.node.cpu.usage' AND ${MF}\nGROUP BY time, node ORDER BY time`,
    { unit: 'short' }));
  p.push(timeseries('Node memory usage', { h: 8, w: 12, x: 12, y: 4 },
    `SELECT ${MI} AS time, ${RA('k8s.node.name')} AS node, avg(Value) AS mem_bytes\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.node.memory.usage' AND ${MF}\nGROUP BY time, node ORDER BY time`,
    { unit: 'bytes' }));

  p.push(timeseries('Pod CPU usage (cores)', { h: 8, w: 12, x: 0, y: 12 },
    `SELECT ${MI} AS time, ${RA('k8s.pod.name')} AS pod, avg(Value) AS cpu_cores\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.pod.cpu.usage' AND ${MF} ${NS}\nGROUP BY time, pod ORDER BY time`,
    { unit: 'short', legend: true }));
  p.push(timeseries('Deployment availability (available replicas)', { h: 8, w: 12, x: 12, y: 12 },
    `SELECT ${MI} AS time, ${RA('k8s.deployment.name')} AS deployment, avg(Value) AS available\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.deployment.available' AND ${MF} ${NS}\nGROUP BY time, deployment ORDER BY time`,
    { unit: 'short' }));

  p.push(table('Top pods by memory (working set)', { h: 9, w: 12, x: 0, y: 20 },
    `SELECT ${RA('k8s.namespace.name')} AS "Namespace",\n       ${RA('k8s.pod.name')} AS "Pod",\n       argMax(Value, TimeUnix) AS "Memory"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.pod.memory.working_set' AND ${MF} ${NS}\nGROUP BY 1, 2\nORDER BY "Memory" DESC\nLIMIT 20`,
    [unitOverride('Memory', 'bytes', 1)]));
  p.push(table('Container restarts (by pod)', { h: 9, w: 12, x: 12, y: 20 },
    `SELECT ${RA('k8s.namespace.name')} AS "Namespace",\n       ${RA('k8s.pod.name')} AS "Pod",\n       ${RA('k8s.container.name')} AS "Container",\n       toUInt64(argMax(Value, TimeUnix)) AS "Restarts"\nFROM ${DB}.otel_metrics_gauge\nWHERE MetricName = 'k8s.container.restarts' AND ${MF} ${NS}\nGROUP BY 1, 2, 3\nHAVING "Restarts" > 0\nORDER BY "Restarts" DESC\nLIMIT 20`,
    [{ matcher: { id: 'byName', options: 'Restarts' }, properties: [
      { id: 'custom.cellOptions', value: { type: 'color-background', mode: 'gradient' } },
      { id: 'thresholds', value: { mode: 'absolute', steps: [
        { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] } },
    ] }]));

  const nsVar = queryVar('namespace', 'Namespace',
    `SELECT DISTINCT ${RA('k8s.namespace.name')} FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF} ORDER BY 1`);
  return dashboard('clickstack-k8s-overview', 'ClickStack · Kubernetes Cluster Overview',
    'Cluster and workload health from the OpenTelemetry k8s cluster/kubelet receivers (otel_metrics_gauge): nodes, pods, CPU/memory, restarts.', p, [nsVar]);
}

// ===========================================================================
// 3. Logs & Errors Overview (logs)
// ===========================================================================
function logsOverview() {
  const p = [];
  const ERR = "lower(SeverityText) IN ('error', 'fatal')";
  const W = `${TF} ${SVC}`;
  p.push(stat('Logs / sec', { h: 4, w: 6, x: 0, y: 0 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${W}`,
    { unit: 'short', decimals: 1 }));
  p.push(stat('Error+ logs / sec', { h: 4, w: 6, x: 6, y: 0 },
    `SELECT countIf(${ERR}) / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${W}`,
    { unit: 'short', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] } }));
  p.push(stat('Error log %', { h: 4, w: 6, x: 12, y: 0 },
    `SELECT 100 * countIf(${ERR}) / count() AS value FROM ${DB}.otel_logs WHERE ${W}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 2 }, { color: 'red', value: 10 }] } }));
  p.push(stat('Fatal logs', { h: 4, w: 6, x: 18, y: 0 },
    `SELECT countIf(lower(SeverityText) = 'fatal') AS value FROM ${DB}.otel_logs WHERE ${W}`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] } }));

  p.push(timeseries('Log volume by severity', { h: 8, w: 12, x: 0, y: 4 },
    `SELECT ${TI} AS time, SeverityText AS severity, count() AS logs\nFROM ${DB}.otel_logs\nWHERE ${W} AND SeverityText != ''\nGROUP BY time, severity ORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25 }));
  p.push(timeseries('Error+ logs by service', { h: 8, w: 12, x: 12, y: 4 },
    `SELECT ${TI} AS time, ServiceName AS service, count() AS errors\nFROM ${DB}.otel_logs\nWHERE ${W} AND ${ERR}\nGROUP BY time, service HAVING errors > 0 ORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25 }));

  p.push(table('Top services by error+ logs', { h: 9, w: 8, x: 0, y: 12 },
    `SELECT ServiceName AS "Service",\n       count() AS "Error logs",\n       round(100 * count() / (SELECT count() FROM ${DB}.otel_logs WHERE ${W} AND ${ERR}), 1) AS "% of errors"\nFROM ${DB}.otel_logs\nWHERE ${W} AND ${ERR}\nGROUP BY 1 ORDER BY 2 DESC LIMIT 15`,
    [unitOverride('% of errors', 'percent', 1)]));
  p.push(table('Recent errors', { h: 9, w: 16, x: 8, y: 12 },
    `SELECT Timestamp AS "Time",\n       ServiceName AS "Service",\n       SeverityText AS "Severity",\n       substring(Body, 1, 200) AS "Message"\nFROM ${DB}.otel_logs\nWHERE ${W} AND ${ERR}\nORDER BY Timestamp DESC LIMIT 100`,
    [{ matcher: { id: 'byName', options: 'Time' }, properties: [{ id: 'custom.width', value: 180 }] },
     { matcher: { id: 'byName', options: 'Severity' }, properties: [{ id: 'custom.width', value: 90 }] }]));

  const svcVar = queryVar('service', 'Service',
    `SELECT DISTINCT ServiceName FROM ${DB}.otel_logs WHERE ${TF} AND ServiceName != '' ORDER BY ServiceName`);
  return dashboard('clickstack-logs-overview', 'ClickStack · Logs & Errors Overview',
    'Log throughput and error analysis from OpenTelemetry logs in ClickHouse (otel_logs): volume by severity, error rate, and recent errors.', p, [svcVar]);
}

// ===========================================================================
// 4. Executive Summary — one pane combining top signals from all three
// ===========================================================================
function execSummary() {
  const p = [];
  const MF = '$__timeFilter(TimeUnix)';
  const RA = (k) => `ResourceAttributes['${k}']`;
  const ERR = "lower(SeverityText) IN ('error', 'fatal')";

  // --- Services -----------------------------------------------------------
  p.push(row('Services (traces)', 0));
  p.push(stat('Requests / sec', { h: 5, w: 6, x: 0, y: 1 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'reqps', decimals: 1 }));
  p.push(stat('Error rate', { h: 5, w: 6, x: 6, y: 1 },
    `SELECT 100 * countIf(StatusCode = 'Error') / count() AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] } }));
  p.push(stat('Latency p95', { h: 5, w: 6, x: 12, y: 1 },
    `SELECT quantile(0.95)(Duration) / 1e6 AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'ms', decimals: 1 }));
  p.push(stat('Active services', { h: 5, w: 6, x: 18, y: 1 },
    `SELECT count(DISTINCT ServiceName) AS value FROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}`,
    { unit: 'short', decimals: 0 }));
  p.push(timeseries('Request volume', { h: 6, w: 12, x: 0, y: 6 },
    `SELECT ${TI} AS time, count() AS requests\nFROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}\nGROUP BY time ORDER BY time`,
    { unit: 'short', fillOpacity: 20, legend: false, interval: '5m' }));
  p.push(timeseries('Overall error rate (%)', { h: 6, w: 12, x: 12, y: 6 },
    `SELECT ${TI} AS time, 100 * countIf(StatusCode = 'Error') / count() AS error_pct\nFROM ${DB}.otel_traces WHERE ${TF} AND ${SERVER}\nGROUP BY time ORDER BY time`,
    { unit: 'percent', fillOpacity: 20, legend: false, interval: '5m' }));

  // --- Kubernetes ---------------------------------------------------------
  p.push(row('Kubernetes (metrics)', 12));
  p.push(stat('Nodes Ready', { h: 5, w: 6, x: 0, y: 13 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.node.name')} AS n, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.node.condition_ready' AND ${MF}\n  GROUP BY n HAVING v = 1)`,
    { unit: 'short', decimals: 0 }));
  p.push(stat('Pods Running', { h: 5, w: 6, x: 6, y: 13 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.pod.uid')} AS u, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF}\n  GROUP BY u HAVING v = 2)`,
    { unit: 'short', decimals: 0 }));
  p.push(stat('Pods Not Running', { h: 5, w: 6, x: 12, y: 13 },
    `SELECT count() AS value FROM (\n  SELECT ${RA('k8s.pod.uid')} AS u, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase' AND ${MF}\n  GROUP BY u HAVING v != 2)`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] } }));
  p.push(stat('Container Restarts', { h: 5, w: 6, x: 18, y: 13 },
    `SELECT sum(v) AS value FROM (\n  SELECT concat(${RA('k8s.pod.uid')}, '/', ${RA('k8s.container.name')}) AS c, argMax(Value, TimeUnix) AS v\n  FROM ${DB}.otel_metrics_gauge WHERE MetricName = 'k8s.container.restarts' AND ${MF}\n  GROUP BY c)`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 10 }] } }));

  // --- Logs ---------------------------------------------------------------
  p.push(row('Logs', 18));
  p.push(stat('Logs / sec', { h: 5, w: 6, x: 0, y: 19 },
    `SELECT count() / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'short', decimals: 1 }));
  p.push(stat('Error+ logs / sec', { h: 5, w: 6, x: 6, y: 19 },
    `SELECT countIf(${ERR}) / ${WINDOW_S} AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'short', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] } }));
  p.push(stat('Error log %', { h: 5, w: 6, x: 12, y: 19 },
    `SELECT 100 * countIf(${ERR}) / count() AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'percent', decimals: 2, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'yellow', value: 2 }, { color: 'red', value: 10 }] } }));
  p.push(stat('Fatal logs', { h: 5, w: 6, x: 18, y: 19 },
    `SELECT countIf(lower(SeverityText) = 'fatal') AS value FROM ${DB}.otel_logs WHERE ${TF}`,
    { unit: 'short', decimals: 0, thresholds: { mode: 'absolute', steps: [
      { color: 'green', value: null }, { color: 'red', value: 1 }] } }));
  p.push(timeseries('Log volume by severity', { h: 6, w: 12, x: 0, y: 24 },
    `SELECT ${TI} AS time, SeverityText AS severity, count() AS logs\nFROM ${DB}.otel_logs WHERE ${TF} AND SeverityText != ''\nGROUP BY time, severity ORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25, interval: '5m' }));
  p.push(timeseries('Error+ logs by service', { h: 6, w: 12, x: 12, y: 24 },
    `SELECT ${TI} AS time, ServiceName AS service, count() AS errors\nFROM ${DB}.otel_logs WHERE ${TF} AND ${ERR}\nGROUP BY time, service HAVING errors > 0 ORDER BY time`,
    { unit: 'short', stacking: 'normal', fillOpacity: 25, interval: '5m' }));

  // --- Attention table ----------------------------------------------------
  p.push(row('Needs attention', 30));
  p.push(table('Services by error rate', { h: 9, w: 24, x: 0, y: 31 },
    `SELECT ServiceName AS "Service",\n       round(count() / ${WINDOW_S}, 2) AS "Req/s",\n       countIf(StatusCode = 'Error') AS "Errors",\n       round(100 * countIf(StatusCode = 'Error') / count(), 2) AS "Error %",\n       round(quantile(0.95)(Duration) / 1e6, 1) AS "p95 ms"\nFROM ${DB}.otel_traces\nWHERE ${TF} AND ${SERVER}\nGROUP BY ServiceName\nORDER BY "Error %" DESC, "Req/s" DESC`,
    [
      unitOverride('Req/s', 'reqps', 2),
      unitOverride('Error %', 'percent', 2),
      unitOverride('p95 ms', 'ms', 1),
      { matcher: { id: 'byName', options: 'Error %' }, properties: [
        { id: 'custom.cellOptions', value: { type: 'color-background', mode: 'gradient' } },
        { id: 'thresholds', value: { mode: 'absolute', steps: [
          { color: 'green', value: null }, { color: 'yellow', value: 1 }, { color: 'red', value: 5 }] } },
      ] },
    ]));

  return dashboard('clickstack-exec-summary', 'ClickStack · Executive Summary',
    'One-pane health overview across services, Kubernetes, and logs — top signals from all three ClickStack Grafana dashboards.', p);
}

// ---- main -----------------------------------------------------------------
if (!fs.existsSync(OUT)) fs.mkdirSync(OUT, { recursive: true });
write('executive-summary.json', execSummary());
write('service-health-golden-signals.json', serviceHealth());
write('kubernetes-cluster-overview.json', k8sOverview());
write('logs-errors-overview.json', logsOverview());
console.log('done.');
