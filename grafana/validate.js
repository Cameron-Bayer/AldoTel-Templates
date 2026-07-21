const fs = require('fs');
const path = require('path');
const dir = path.join(__dirname, 'dashboards');
const auth = 'Basic ' + Buffer.from('admin:admin').toString('base64');

async function run(sql, queryType, format) {
  // Template variables aren't interpolated when we POST raw SQL directly, so
  // substitute the filter placeholders with equivalent subqueries for validation.
  // The service list unions trace + log services so it is correct for BOTH the
  // trace dashboards and the logs dashboard (whose services live in otel_logs).
  sql = sql
    .replace(/\$\{database\}/g, 'default')
    .replace(/\$\{service:sqlstring\}/g,
      "SELECT DISTINCT ServiceName FROM default.otel_traces WHERE Timestamp > now() - INTERVAL 3 HOUR " +
      "UNION DISTINCT SELECT DISTINCT ServiceName FROM default.otel_logs WHERE Timestamp > now() - INTERVAL 3 HOUR")
    .replace(/\$\{namespace:sqlstring\}/g, "SELECT DISTINCT ResourceAttributes['k8s.namespace.name'] FROM default.otel_metrics_gauge WHERE MetricName = 'k8s.pod.phase'");
  const body = {
    from: 'now-3h', to: 'now',
    queries: [{ refId: 'A', datasource: { type: 'grafana-clickhouse-datasource', uid: 'clickstack-ch' },
      rawSql: sql, queryType, format, intervalMs: 60000, maxDataPoints: 100 }],
  };
  const r = await fetch('http://localhost:3005/api/ds/query', {
    method: 'POST', headers: { 'content-type': 'application/json', authorization: auth },
    body: JSON.stringify(body),
  });
  const j = await r.json();
  const res = j.results && j.results.A;
  if (!res) return { ok: false, err: JSON.stringify(j).slice(0, 300) };
  if (res.status >= 400 || res.error) return { ok: false, err: (res.error || 'status ' + res.status) };
  const frames = res.frames || [];
  let rows = 0;
  if (frames[0] && frames[0].data && frames[0].data.values[0]) rows = frames[0].data.values[0].length;
  return { ok: true, frames: frames.length, rows };
}

(async () => {
  let fail = 0;
  for (const f of fs.readdirSync(dir).filter((x) => x.endsWith('.json'))) {
    const dash = JSON.parse(fs.readFileSync(path.join(dir, f), 'utf8'));
    console.log('\n=== ' + f + ' ===');
    // Validate template variable queries
    for (const v of (dash.templating && dash.templating.list) || []) {
      if (v.type === 'query' && v.query && v.query.rawSql) {
        const res = await run(v.query.rawSql, 'table', 1);
        if (!res.ok) fail++;
        console.log(`  [${res.ok ? '✓' : '✗'}] ${'variable'.padEnd(10)} $${v.name.padEnd(39)} ${res.ok ? `OK rows=${res.rows}` : 'FAIL ' + res.err}`);
      }
    }
    for (const p of dash.panels) {
      if (p.type === 'row') continue;
      for (const t of p.targets) {
        const res = await run(t.rawSql, t.queryType, t.format);
        const tag = res.ok ? `OK  frames=${res.frames} rows=${res.rows}` : `FAIL ${res.err}`;
        if (!res.ok) fail++;
        console.log(`  [${res.ok ? '✓' : '✗'}] ${p.type.padEnd(10)} ${p.title.slice(0, 40).padEnd(40)} ${tag}`);
      }
    }
  }
  console.log('\n' + (fail ? fail + ' FAILURES' : 'ALL PANELS OK'));
  process.exit(fail ? 1 : 0);
})();
