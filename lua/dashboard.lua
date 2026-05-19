local _M = {}

local html = [=[
<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>KP-HA Dashboard</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f1117;color:#e1e4e8;padding:20px}
.header{display:flex;justify-content:space-between;align-items:center;margin-bottom:24px}
.header h1{font-size:22px;font-weight:600}
.header .meta{font-size:13px;color:#8b949e}
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(160px,1fr));gap:12px;margin-bottom:24px}
.stat-card{background:#161b22;border:1px solid #21262d;border-radius:8px;padding:16px}
.stat-card .label{font-size:12px;color:#8b949e;margin-bottom:4px}
.stat-card .value{font-size:28px;font-weight:700;font-variant-numeric:tabular-nums}
.stat-card .unit{font-size:13px;color:#8b949e;margin-left:4px}
.upstreams h2{font-size:16px;margin-bottom:12px;color:#8b949e}
.upstream-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(320px,1fr));gap:12px}
.upstream-card{background:#161b22;border:1px solid #21262d;border-radius:8px;padding:20px}
.upstream-card .name{font-size:16px;font-weight:600;margin-bottom:12px;display:flex;align-items:center;gap:8px}
.upstream-card .name .host{color:#58a6ff}
.upstream-card .name .weight{font-size:12px;color:#8b949e;background:#21262d;padding:2px 8px;border-radius:10px}
.badge{display:inline-block;width:10px;height:10px;border-radius:50%}
.badge.healthy{background:#3fb950;box-shadow:0 0 6px #3fb950}
.badge.unhealthy{background:#f85149;box-shadow:0 0 6px #f85149}
.badge.circuit-open{background:#d29922;box-shadow:0 0 6px #d29922}
.metrics-row{display:grid;grid-template-columns:repeat(3,1fr);gap:8px;margin-top:12px}
.metric-item{text-align:center}
.metric-item .val{font-size:22px;font-weight:700;font-variant-numeric:tabular-nums}
.metric-item .lbl{font-size:11px;color:#8b949e;margin-top:2px}
.metric-item .err{color:#f85149}
.circuit-badge{font-size:11px;padding:2px 8px;border-radius:10px}
.circuit-badge.closed{background:#1a3a1a;color:#3fb950}
.circuit-badge.open{background:#3a1a1a;color:#f85149}
.circuit-badge.half_open{background:#3a2e0e;color:#d29922}
.error-msg{text-align:center;padding:40px;color:#f85149;font-size:14px}
.footer{text-align:center;color:#484f58;font-size:11px;margin-top:24px}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.5}}
.loading{animation:pulse 1.5s infinite}
</style>
</head>
<body>
<div class="header">
  <h1>KP-HA Load Balancer</h1>
  <div class="meta"><span id="updated">-</span> · auto-refresh 5s</div>
</div>

<div class="stats-grid" id="global-stats">
  <div class="stat-card"><div class="label">Total Requests</div><div class="value loading" id="total-req">-</div></div>
  <div class="stat-card"><div class="label">Error Rate</div><div class="value loading" id="error-rate">-</div></div>
  <div class="stat-card"><div class="label">Circuit Trips</div><div class="value loading" id="circuit-trips">0</div></div>
  <div class="stat-card"><div class="label">Rate Limit Hits</div><div class="value loading" id="rl-hits">0</div></div>
</div>

<div class="upstreams">
  <h2>Upstreams</h2>
  <div class="upstream-grid" id="upstream-list"></div>
</div>

<div class="footer">KP-HA Dashboard · <span id="gateway-addr"></span></div>

<script>
(function(){
  var secret = location.search.match(/secret=([^&]+)/);
  secret = secret ? secret[1] : '';
  var base = location.protocol + '//' + location.host;

  function fmt(n){return n != null ? Number(n).toLocaleString() : '-'}
  function fmtMs(n){return n != null ? Number(n).toFixed(1) + 'ms' : '-'}
  function fmtPct(a,b){return b>0 ? (a/b*100).toFixed(1)+'%' : '0%'}

  async function load(){
    try{
      var sRes = await fetch(base + '/status?secret=' + secret);
      var s = await sRes.json();
      if(s.error){showError(s.error);return}

      var mRes = await fetch(base + '/metrics?secret=' + secret);
      var m = await mRes.text();

      document.getElementById('total-req').textContent = fmt(s.requests);
      document.getElementById('error-rate').textContent = fmtPct(s.errors, s.requests);
      document.getElementById('circuit-trips').textContent = fmt(s.circuit_trips||0);
      document.getElementById('rl-hits').textContent = fmt(s.rate_limit_hits||0);
      document.getElementById('gateway-addr').textContent = base;
      document.getElementById('updated').textContent = new Date().toLocaleTimeString();
      document.querySelectorAll('.loading').forEach(function(el){el.classList.remove('loading')});

      var list = document.getElementById('upstream-list');
      list.innerHTML = '';
      (s.upstreams||[]).forEach(function(u){
        var healthClass = u.health==='healthy'?'healthy':'unhealthy';
        if(u.circuit==='open') healthClass='circuit-open';
        var circuitClass = u.circuit||'closed';
        var inflight = u.inflight||0;
        var errRate = u.requests>0 ? fmtPct(u.errors||0, u.requests) : '0%';
        var p50 = u.p50_ms ? Number(u.p50_ms).toFixed(1)+'ms' : '-';

        var card = document.createElement('div');
        card.className = 'upstream-card';
        card.innerHTML =
          '<div class="name">' +
            '<span class="badge '+healthClass+'"></span>' +
            '<span class="host">'+u.host+':'+u.port+'</span>' +
            '<span class="weight">weight:'+u.weight+'</span>' +
            '<span class="circuit-badge '+circuitClass+'">'+u.circuit+'</span>' +
          '</div>' +
          '<div class="metrics-row">' +
            '<div class="metric-item"><div class="val">'+fmt(u.requests)+'</div><div class="lbl">Requests</div></div>' +
            '<div class="metric-item"><div class="val">'+inflight+'</div><div class="lbl">Inflight</div></div>' +
            '<div class="metric-item"><div class="val">'+p50+'</div><div class="lbl">P50 Latency</div></div>' +
            '<div class="metric-item"><div class="val err">'+errRate+'</div><div class="lbl">Error Rate</div></div>' +
            '<div class="metric-item"><div class="val">'+u.health+'</div><div class="lbl">Health</div></div>' +
            '<div class="metric-item"><div class="val">'+u.weight+'</div><div class="lbl">Weight</div></div>' +
          '</div>';
        list.appendChild(card);
      });

    } catch(e){ showError(e.message) }
  }

  function showError(msg){
    document.getElementById('upstream-list').innerHTML = '<div class="error-msg">'+msg+'</div>';
  }

  load();
  setInterval(load, 5000);
})();
</script>
</body>
</html>
]=]

function _M.serve()
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.say(html)
end

return _M
