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
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0f1117;color:#e1e4e8;padding:16px}
.header{display:flex;justify-content:space-between;align-items:center;margin-bottom:16px}
.header h1{font-size:20px;font-weight:600}
.header .meta{font-size:12px;color:#8b949e}
.stats-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px;margin-bottom:16px}
.stat-card{background:#161b22;border:1px solid #21262d;border-radius:6px;padding:12px}
.stat-card .label{font-size:11px;color:#8b949e;margin-bottom:2px}
.stat-card .value{font-size:24px;font-weight:700;font-variant-numeric:tabular-nums}
.upstreams h2{font-size:14px;margin-bottom:8px;color:#8b949e}
.upstream-grid{display:grid;grid-template-columns:repeat(auto-fit,minmax(240px,1fr));gap:8px}
.upstream-card{background:#161b22;border:1px solid #21262d;border-radius:6px;padding:10px 14px}
.upstream-card .name{font-size:13px;font-weight:600;margin-bottom:8px;display:flex;align-items:center;gap:6px;flex-wrap:wrap}
.upstream-card .name .host{color:#58a6ff}
.upstream-card .name .weight{font-size:11px;color:#8b949e;background:#21262d;padding:1px 6px;border-radius:8px}
.badge{display:inline-block;width:8px;height:8px;border-radius:50%}
.badge.healthy{background:#3fb950;box-shadow:0 0 4px #3fb950}
.badge.unhealthy{background:#f85149;box-shadow:0 0 4px #f85149}
.badge.circuit-open{background:#d29922;box-shadow:0 0 4px #d29922}
.metrics-row{display:grid;grid-template-columns:repeat(3,1fr);gap:4px;margin-top:8px}
.metric-item{text-align:center}
.metric-item .val{font-size:18px;font-weight:700;font-variant-numeric:tabular-nums}
.metric-item .lbl{font-size:10px;color:#8b949e;margin-top:1px}
.metric-item .err{color:#f85149}
.circuit-badge{font-size:10px;padding:1px 6px;border-radius:8px}
.circuit-badge.closed{background:#1a3a1a;color:#3fb950}
.circuit-badge.open{background:#3a1a1a;color:#f85149}
.circuit-badge.half_open{background:#3a2e0e;color:#d29922}
.group-label{grid-column:1/-1;font-size:12px;color:#58a6ff;margin-top:8px;padding:4px 0;border-bottom:1px solid #21262d;cursor:pointer;user-select:none}
.group-label:hover{color:#79c0ff}
.group-label::before{content:'▼ ';font-size:10px}
.group-label.collapsed::before{content:'▶ ';font-size:10px}
.upstream-card.hidden{display:none}
.error-msg{grid-column:1/-1;text-align:center;padding:40px;color:#f85149;font-size:14px}
.error-msg a{color:#58a6ff}
.footer{text-align:center;color:#484f58;font-size:11px;margin-top:16px}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.5}}
.loading{animation:pulse 1.5s infinite}
</style>
</head>
<body>
<div class="header">
  <h1>KP-HA Load Balancer</h1>
  <div class="meta"><span id="updated">-</span> · auto-refresh 5s</div>
</div>

<div class="stats-grid">
  <div class="stat-card"><div class="label">Total Requests</div><div class="value loading" id="total-req">-</div></div>
  <div class="stat-card"><div class="label">Error Rate</div><div class="value loading" id="error-rate">-</div></div>
  <div class="stat-card"><div class="label">Circuit Trips</div><div class="value loading" id="circuit-trips">0</div></div>
  <div class="stat-card"><div class="label">Rate Limit Hits</div><div class="value loading" id="rl-hits">0</div></div>
</div>

<div class="upstreams">
  <h2>Upstreams</h2>
  <div class="upstream-grid" id="upstream-list">
    <div class="error-msg loading">Loading...</div>
  </div>
</div>

<div class="footer">KP-HA Dashboard · <span id="gateway-addr"></span></div>

<script>
var secret = (location.search.match(/secret=([^&]+)/)||[])[1]||'';
var base = location.protocol + '//' + location.host;

function fmt(n){return n!=null ? Number(n).toLocaleString() : '-'}
function fmtMs(n){return n!=null ? Number(n).toFixed(1)+'ms' : '-'}
function fmtPct(a,b){return b>0 ? (a/b*100).toFixed(1)+'%' : '0%'}

function showError(msg){
  document.getElementById('upstream-list').innerHTML = '<div class="error-msg">'+msg+'</div>';
}

function renderCard(u, list, groupName){
  var hc = u.health==='healthy'?'healthy':'unhealthy';
  if(u.circuit==='open') hc='circuit-open';
  var cc = u.circuit||'closed';
  var inflight = u.inflight||0;
  var errRate = u.requests>0 ? fmtPct(u.errors||0, u.requests) : '0%';
  var p50 = u.p50_ms ? Number(u.p50_ms).toFixed(1)+'ms' : '-';
  var cid = (groupName||'default')+'_'+u.id.replace(/[.:]/g,'_');

  var card = document.createElement('div');
  card.className = 'upstream-card';
  card.innerHTML =
    '<div class="name">'+
      '<span class="badge '+hc+'"></span>'+
      '<span class="host">'+u.host+':'+u.port+'</span>'+
      '<span class="weight">weight:'+u.weight+'</span>'+
      '<span class="circuit-badge '+cc+'">'+u.circuit+'</span>'+
    '</div>'+
    '<div class="metrics-row">'+
      '<div class="metric-item"><div class="val">'+fmt(u.requests)+'</div><div class="lbl">Requests</div></div>'+
      '<div class="metric-item"><div class="val">'+inflight+'</div><div class="lbl">Inflight</div></div>'+
      '<div class="metric-item"><div class="val">'+p50+'</div><div class="lbl">P50 Latency</div></div>'+
      '<div class="metric-item"><div class="val err">'+errRate+'</div><div class="lbl">Error Rate</div></div>'+
      '<div class="metric-item"><div class="val">'+u.health+'</div><div class="lbl">Health</div></div>'+
      '<div class="metric-item"><div class="val">'+u.weight+'</div><div class="lbl">Weight</div></div>'+
    '</div>'+
    '<svg class="chart" id="chart-'+cid+'" width="100%" height="80" style="margin-top:6px;border-radius:4px;background:#0d1117"></svg>';
  list.appendChild(card);

  loadChart(cid, u.host+':'+u.port);
}

async function loadChart(cid, upstreamId){
  var svg = document.getElementById('chart-'+cid);
  if(!svg) return;
  try{
    var r = await fetch(base+'/status/history?secret='+secret+'&upstream='+encodeURIComponent(upstreamId)+'&range=3600');
    var pts = await r.json();
    if(!pts||pts.length<2){ svg.innerHTML='<text x="50%" y="50%" text-anchor="middle" fill="#484f58" font-size="10">等待数据...</text>'; return; }

    var vals = pts.map(function(p){return p[1]});
    var max = Math.max.apply(null,vals)||1;
    var min = Math.min.apply(null,vals);
    var w = svg.clientWidth||240;
    var h = 78;
    var pad = 2;
    var xs = pts.map(function(_,i){return (i/(pts.length-1))*(w-pad*2)+pad});
    var ys = vals.map(function(v){return h-pad-((v-min)/(max-min||1))*(h-pad*2)});

    var points = '';
    for(var i=0;i<xs.length;i++) points += xs[i].toFixed(1)+','+ys[i].toFixed(1)+' ';

    var d='';
    for(var i=0;i<xs.length;i++) d += (i===0?'M':'L')+xs[i].toFixed(1)+' '+ys[i].toFixed(1);

    svg.innerHTML =
      '<defs><linearGradient id="g-'+cid+'" x1="0" y1="0" x2="0" y2="1">'+
        '<stop offset="0%" stop-color="#58a6ff" stop-opacity="0.3"/>'+
        '<stop offset="100%" stop-color="#58a6ff" stop-opacity="0"/>'+
      '</linearGradient></defs>'+
      '<polyline points="'+points+'" fill="none" stroke="#58a6ff" stroke-width="1.5" vector-effect="non-scaling-stroke"/>'+
      '<path d="'+d+' L'+(w-pad)+' '+(h-pad)+' L'+pad+' '+(h-pad)+' Z" fill="url(#g-'+cid+')"/>'+
      '<text x="'+(w-pad)+'" y="10" text-anchor="end" fill="#8b949e" font-size="9">'+fmt(vals[vals.length-1])+'</text>';
  }catch(e){}
}

async function load(){
  if(!secret){
    showError('请添加 ?secret=xxx 参数<br><br>示例: <a style="color:#58a6ff" href="'+base+'/dashboard?secret=change-me">'+base+'/dashboard?secret=change-me</a>');
    return;
  }
  try{
    var sRes = await fetch(base+'/status?secret='+secret);
    var s = await sRes.json();
    if(s.error){showError('鉴权失败，请检查 secret 参数');return;}

    document.getElementById('total-req').textContent = fmt(s.requests);
    document.getElementById('error-rate').textContent = fmtPct(s.errors, s.requests);
    document.getElementById('circuit-trips').textContent = fmt(s.circuit_trips||0);
    document.getElementById('rl-hits').textContent = fmt(s.rate_limit_hits||0);
    document.getElementById('gateway-addr').textContent = base;
    document.getElementById('updated').textContent = new Date().toLocaleTimeString();
    var els = document.querySelectorAll('.loading');
    for(var i=0;i<els.length;i++) els[i].classList.remove('loading');

    var list = document.getElementById('upstream-list');
    list.innerHTML = '';

    if(s.groups){
      for(var gi=0;gi<s.groups.length;gi++){
        var g = s.groups[gi];
        var label = document.createElement('div');
        label.className = 'group-label';
        label.textContent = ' ' + (g.name||'default') + ' (' + (g.upstreams||[]).length + ')';
        label.onclick = function(){
          this.classList.toggle('collapsed');
          var nxt = this.nextElementSibling;
          while(nxt && !nxt.classList.contains('group-label')){
            nxt.classList.toggle('hidden');
            nxt = nxt.nextElementSibling;
          }
        };
        list.appendChild(label);
        var ups = g.upstreams||[];
        for(var ui=0;ui<ups.length;ui++) renderCard(ups[ui], list, g.name||'default');
      }
    } else if(s.upstreams){
      var ups = s.upstreams||[];
      for(var ui=0;ui<ups.length;ui++) renderCard(ups[ui], list, '');
    }

    if(list.children.length === 0){
      showError('没有上游数据');
    }
  }catch(e){
    showError('加载失败: '+e.message);
  }
}

load();
setInterval(load, 5000);
</script>
</body>
</html>
]=]

function _M.serve()
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.say(html)
end

return _M
