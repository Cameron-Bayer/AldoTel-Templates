#!/usr/bin/env node
/*
 * gen-docs.js
 *
 * Generates a human-readable reference (docs/<slug>.md) for every dashboard
 * template in dashboards/. Each file breaks down, per visual, the ClickHouse
 * tables and columns the tile reads. Re-run after editing any template:
 *
 *   node gen-docs.js
 */
const fs = require('fs');
const path = require('path');

const srcDir = path.join(__dirname, 'dashboards');
const outDir = path.join(__dirname, 'docs');
fs.mkdirSync(outDir, { recursive: true });

// Optional per-dashboard "receivers" blurbs from requirements.json.
let reqByFile = {};
try {
  const req = JSON.parse(fs.readFileSync(path.join(__dirname, 'requirements.json'), 'utf8'));
  for (const d of req.dashboards || []) reqByFile[d.file] = d;
} catch { /* optional */ }

// Standard ClickStack default source names / tables (what tokens resolve to).
const SOURCE = {
  '{{LOGS_SOURCE_ID}}': { name: 'Logs', table: 'default.otel_logs' },
  '{{TRACES_SOURCE_ID}}': { name: 'Traces', table: 'default.otel_traces' },
  '{{METRICS_SOURCE_ID}}': { name: 'Metrics', table: 'default.otel_metrics_{gauge|sum|histogram}' },
};
const METRIC_TABLE = { gauge: 'default.otel_metrics_gauge', sum: 'default.otel_metrics_sum', histogram: 'default.otel_metrics_histogram' };

// Resolve schema/table tokens in raw SQL so the docs show real names.
function resolveSql(sql) {
  return (sql || '')
    .split('{{LOGS_SCHEMA}}.{{LOGS_TABLE}}').join('default.otel_logs')
    .split('{{TRACES_SCHEMA}}.{{TRACES_TABLE}}').join('default.otel_traces')
    .split('{{METRICS_SCHEMA}}').join('default')
    .split('{{LOGS_SCHEMA}}').join('default')
    .split('{{TRACES_SCHEMA}}').join('default');
}

// Known OTel columns (for builder tiles) — attribute maps kept whole.
const KNOWN_COLS = ['ServiceName', 'SeverityText', 'Body', 'Timestamp', 'TimeUnix', 'Value', 'MetricName',
  'Duration', 'StatusCode', 'StatusMessage', 'SpanName', 'SpanKind', 'TraceId', 'SpanId', 'ParentSpanId'];
function extractCols(...exprs) {
  const text = exprs.filter(Boolean).join(' \u0000 ');
  const cols = new Set();
  for (const m of text.matchAll(/(?:ResourceAttributes|LogAttributes|SpanAttributes)\['[^']+'\]/g)) cols.add(m[0]);
  for (const c of KNOWN_COLS) if (new RegExp(`\\b${c}\\b`).test(text)) cols.add(c);
  return [...cols];
}

// Pull real (schema-qualified / system.*) tables out of a resolved SQL string,
// excluding CTE names and bare subquery aliases.
function sqlTables(sql) {
  const ctes = new Set();
  for (const m of sql.matchAll(/(?:with|,)\s+([A-Za-z_][A-Za-z0-9_]*)\s+as\s*\(/gi)) ctes.add(m[1].toLowerCase());
  const tables = new Set();
  for (const m of sql.matchAll(/\b(?:from|join)\s+([A-Za-z_][A-Za-z0-9_.]*)/gi)) {
    const t = m[1];
    if (ctes.has(t.toLowerCase())) continue;
    if (t.includes('.') || /^system\./i.test(t)) tables.add(t);
  }
  return [...tables];
}

const code = (s) => '`' + s + '`';
const strip = (s) => (s || '').replace(/^#+\s*/, '').trim();

function sourceLine(cfg) {
  const s = SOURCE[cfg.sourceId];
  if (!s) return null;
  // For metric builder tiles, narrow the metrics table by the select metricType(s).
  if (s.name === 'Metrics' && Array.isArray(cfg.select)) {
    const types = [...new Set(cfg.select.map((x) => x.metricType).filter(Boolean))];
    if (types.length) return { name: 'Metrics', table: types.map((t) => METRIC_TABLE[t] || t).join(', ') };
  }
  return s;
}

function measures(cfg) {
  if (!Array.isArray(cfg.select)) return [];
  return cfg.select.map((s) => {
    const val = s.valueExpression ? code(s.valueExpression) : (s.metricName ? code(s.metricName) : '');
    let expr;
    if (s.aggFn) expr = `${s.aggFn}(${val || '*'})`;
    else if (s.countExpression) expr = `${val || 'value'} bucketed, count ${code(s.countExpression)}`;
    else expr = val;
    const cond = (s.where && s.where.trim()) ? `  — where ${code(s.where)}${s.whereLanguage ? ` (${s.whereLanguage})` : ''}` : '';
    return `${expr}${s.alias ? ` as ${code(s.alias)}` : ''}${cond}`;
  });
}

function renderTile(t) {
  const c = t.config || {};
  const title = (t.name || c.name || '').trim() || '(untitled)';
  const isSql = c.configType === 'sql';
  const kind = isSql ? `${c.displayType} · Raw SQL` : c.displayType;
  const lines = [`### ${title} — ${kind}`, ''];

  if (isSql) {
    const sql = resolveSql(c.sqlTemplate);
    const tables = sqlTables(sql);
    lines.push(`- **Tables:** ${tables.length ? tables.map(code).join(', ') : '_derived in query_'}`);
    if (c.onClick) lines.push(`- **Drill-down:** click a row \u2192 opens ${c.onClick.type}`);
    lines.push('', '<details><summary>SQL query</summary>', '', '```sql', sql.trim(), '```', '', '</details>', '');
    return lines.join('\n');
  }

  const src = sourceLine(c);
  if (src) lines.push(`- **Source / table:** ${src.name} \u2192 ${code(src.table)}`);
  const selArr = Array.isArray(c.select) ? c.select : [];
  const metrics = [...new Set(selArr.map((s) => s.metricName).filter(Boolean))];
  if (metrics.length) lines.push(`- **Metric(s):** ${metrics.map(code).join(', ')}  (column ${code('MetricName')})`);
  const ms = measures(c);
  if (ms.length) lines.push(`- **Measure(s):** ${ms.map((m) => m).join('; ')}`);
  if (c.groupBy) lines.push(`- **Group by:** ${code(c.groupBy)}`);
  if (c.orderBy) lines.push(`- **Order by:** ${code(c.orderBy)}`);
  if (typeof c.select === 'string') lines.push(`- **Columns shown:** ${code(c.select)}`);
  if (c.where && c.where.trim()) lines.push(`- **Filter:** ${code(c.where)}${c.whereLanguage ? ` (${c.whereLanguage})` : ''}`);
  if (c.onClick) lines.push(`- **Drill-down:** click a row \u2192 opens ${c.onClick.type}`);

  const exprBits = [
    ...selArr.map((s) => `${s.valueExpression || ''} ${s.where || ''}`),
    typeof c.select === 'string' ? c.select : '',
    c.groupBy || '', c.where || '',
  ];
  let cols = extractCols(...exprBits);
  if (metrics.length) cols = [...new Set([...cols, 'MetricName', 'Value', 'TimeUnix'])];
  if (cols.length) lines.push(`- **Columns used:** ${cols.map(code).join(', ')}`);
  lines.push('');
  return lines.join('\n');
}

function renderDashboard(file, dash) {
  const req = reqByFile[file] || {};
  const slug = file.replace(/\.json$/, '');
  const tmpl = (dash.tags || []).find((t) => t.startsWith('tmpl:')) || '';
  const out = [`# ${dash.name}`, ''];
  out.push('> Auto-generated reference (do not edit by hand — run `node gen-docs.js`).', '',
    'This page lists the ClickHouse tables and columns behind every visual on the dashboard.', '');
  out.push('[← Reference index](README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · ' +
    '[Deep dive](../DASHBOARD-DEEP-DIVE.md) · [HyperDX install guide](../README.md)', '');
  out.push(`- **Template:** ${code('dashboards/' + file)}${tmpl ? ` · tag ${code(tmpl)}` : ''}`);
  if (req.receivers && req.receivers.length) out.push(`- **Data required:** ${req.receivers.join('; ')}`);
  out.push('');

  // Embed the live preview screenshot when one exists (docs/images/<slug>.png).
  if (fs.existsSync(path.join(outDir, 'images', slug + '.png'))) {
    out.push('## Preview', '',
      `![${dash.name}](images/${slug}.png)`, '',
      '_Live capture from a ClickStack install with the OpenTelemetry demo flowing._', '');
  }

  // Dashboard-level (global) filters.
  const filters = dash.filters || [];
  if (filters.length) {
    out.push('## Dashboard filters', '', 'These apply to every compatible tile on the dashboard.', '',
      '| Filter | Column / expression | Source |', '|---|---|---|');
    for (const f of filters) {
      const s = SOURCE[f.sourceId];
      out.push(`| ${f.name} | ${code(f.expression)} | ${s ? `${s.name} (${code(s.table)})` : (f.sourceId || '')} |`);
    }
    out.push('');
  }

  // Walk tiles in order; markdown tiles become section headings.
  let openSection = false;
  const emit = [];
  for (const t of dash.tiles) {
    const c = t.config || {};
    if (c.displayType === 'markdown') {
      emit.push(`## ${strip(c.markdown)}`, '');
      openSection = true;
      continue;
    }
    if (!openSection) { emit.push('## Visuals', ''); openSection = true; }
    emit.push(renderTile(t));
  }
  out.push(...emit);
  return out.join('\n').replace(/\n{3,}/g, '\n\n').trimEnd() + '\n';
}

const files = fs.readdirSync(srcDir).filter((f) => f.endsWith('.json')).sort();
const index = ['# Dashboard reference', '',
  '[← HyperDX install guide](../README.md) · [Dashboard catalog](../DASHBOARD-CATALOG.md) · ' +
  '[Deep dive](../DASHBOARD-DEEP-DIVE.md)', '',
  'Detailed table/column breakdown for each dashboard visual.', '', '| Dashboard | Reference |', '|---|---|'];
for (const file of files) {
  const dash = JSON.parse(fs.readFileSync(path.join(srcDir, file), 'utf8'));
  const slug = file.replace(/\.json$/, '');
  fs.writeFileSync(path.join(outDir, slug + '.md'), renderDashboard(file, dash), 'utf8');
  index.push(`| ${dash.name} | [${slug}.md](${slug}.md) |`);
  console.log(`docs/${slug}.md`);
}
fs.writeFileSync(path.join(outDir, 'README.md'), index.join('\n') + '\n', 'utf8');
console.log(`docs/README.md (index of ${files.length})`);
