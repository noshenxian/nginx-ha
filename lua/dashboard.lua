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
body{font-family:-apple-system,BlinkMacSystemFont,'Segoe UI',Roboto,sans-serif;background:#0d1117;color:#c9d1d9;padding:16px 20px}
.header{display:flex;justify-content:space-between;align-items:baseline;margin-bottom:16px}
.header h1{font-size:18px;font-weight:600;color:#f0f6fc}
.header .meta{font-size:11px;color:#484f58}
.stats-row{display:grid;grid-template-columns:repeat(auto-fit,minmax(140px,1fr));gap:8px;margin-bottom:16px}
.stat-card{background:#161b22;border:1px solid #21262d;border-radius:6px;padding:12px 14px}
.stat-card .lbl{font-size:10px;color:#8b949e;text-transform:uppercase;letter-spacing:.5px;margin-bottom:4px}
.stat-card .val{font-size:26px;font-weight:700;font-variant-numeric:tabular-nums}
.stat-card .sub{font-size:11px;color:#484f58;margin-top:2px}
.chart-section{margin-bottom:20px}
.chart-section h2{font-size:13px;color:#8b949e;margin-bottom:8px;font-weight:500}
.chart-box{background:#161b22;border:1px solid #21262d;border-radius:8px;padding:12px 16px 8px;position:relative}
.chart-box svg{display:block;width:100%}
.chart-legend{display:flex;gap:16px;justify-content:center;margin-top:4px;font-size:10px;color:#8b949e}
.chart-legend span{display:flex;align-items:center;gap:4px}
.chart-legend .dot{width:8px;height:8px;border-radius:50%;display:inline-block}
.upstream-section h2{font-size:13px;color:#8b949e;margin-bottom:8px;font-weight:500}
.upstream-table{width:100%;border-collapse:collapse;font-size:13px}
.upstream-table th{text-align:left;padding:6px 10px;color:#8b949e;font-weight:500;font-size:11px;border-bottom:1px solid #21262d}
.upstream-table td{padding:8px 10px;border-bottom:1px solid #0d1117}
.upstream-table tr{background:#161b22}
.upstream-table tr:nth-child(even){background:#1c2128}
.upstream-table .status{display:inline-block;width:8px;height:8px;border-radius:50%;margin-right:6px}
.upstream-table .status.healthy{background:#3fb950;box-shadow:0 0 4px #3fb950}
.upstream-table .status.unhealthy{background:#f85149;box-shadow:0 0 4px #f85149}
.upstream-table .host{color:#58a6ff;font-weight:500}
.upstream-table .mono{font-variant-numeric:tabular-nums}
.upstream-table .err{color:#f85149}
.circuit{font-size:10px;padding:1px 6px;border-radius:8px}
.circuit.closed{background:#1a3a1a;color:#3fb950}
.circuit.open{background:#3a1a1a;color:#f85149}
.error-msg{text-align:center;padding:60px 20px;color:#f85149;font-size:14px}
.error-msg a{color:#58a6ff}
.footer{text-align:center;color:#21262d;font-size:10px;margin-top:16px}
@keyframes pulse{0%,100%{opacity:1}50%{opacity:.5}}
.loading{animation:pulse 1.5s infinite}
</style>
</head>
<body>
<div class="header">
  <h1>KP-HA Load Balancer</h1>
  <div class="meta"><span id="updated">-</span> · auto-refresh 5s</div>
</div>

<div class="stats-row">
  <div class="stat-card"><div class="lbl">Total Requests</div><div class="val loading" id="total-req">-</div></div>
  <div class="stat-card"><div class="lbl">Error Rate</div><div class="val loading" id="error-rate">-</div></div>
  <div class="stat-card"><div class="lbl">Est. QPS</div><div class="val loading" id="est-qps">-</div><div class="sub" id="qps-detail"></div></div>
  <div class="stat-card"><div class="lbl">Active Upstreams</div><div class="val loading" id="active-ups">-</div></div>
  <div class="stat-card"><div class="lbl">Circuit Trips</div><div class="val loading" id="circuit-trips">0</div></div>
  <div class="stat-card"><div class="lbl">Rate Limit Hits</div><div class="val loading" id="rl-hits">0</div></div>
</div>

<div class="chart-section">
  <h2>Request Trend (7 days · aggregated)</h2>
  <div class="chart-box"><svg id="global-chart" height="200"></svg></div>
</div>

<div class="upstream-section">
  <h2>Upstreams</h2>
  <table class="upstream-table">
    <thead><tr><th></th><th>Host</th><th>Weight</th><th>Requests</th><th>Inflight</th><th>P50</th><th>Error%</th><th>Circuit</th></tr></thead>
    <tbody id="upstream-tbody"></tbody>
  </table>
</div>

<div class="footer">KP-HA Dashboard · <span id="gateway-addr"></span></div>

<script>
var secret=(location.search.match(/secret=([^&]+)/)||[])[1]||'';
var base=location.protocol+'//'+location.host;

function fmt(n){return n!=null?Number(n).toLocaleString():'-'}
function fmtPct(a,b){return b>0?(a/b*100).toFixed(1)+'%':'0%'}
function fmtMs(n){return n!=null?Number(n).toFixed(1)+'ms':'-'}

function showError(msg){
  document.body.innerHTML='<div class="error-msg"><h2>'+msg+'</h2></div>';
}

async function fetchJSON(url){
  var r=await fetch(url);
  return r.json();
}

function renderGlobalChart(upstreams){
  var svg=document.getElementById('global-chart');
  var W=svg.clientWidth||800, H=190, pad={t:16,r:12,b:24,l:50};
  var colors=['#58a6ff','#3fb950','#d29922','#f85149','#bc8cff','#79c0ff'];

  // 聚合所有 upstream 历史数据
  Promise.all(upstreams.map(function(u){
    return fetchJSON(base+'/status/history?secret='+secret+'&upstream='+encodeURIComponent(u.host+':'+u.port)+'&range=604800');
  })).then(function(allSeries){
    // 合并 bucket → 总和
    var bucketMap={};
    allSeries.forEach(function(pts){
      (pts||[]).forEach(function(p){ bucketMap[p[0]]=(bucketMap[p[0]]||0)+p[1]; });
    });
    var keys=Object.keys(bucketMap).map(Number).sort(function(a,b){return a-b});
    if(keys.length<2){ svg.innerHTML='<text x="50%" y="50%" text-anchor="middle" fill="#484f58" font-size="12">数据收集中...</text>'; return; }

    var vals=keys.map(function(k){return bucketMap[k]});
    // 转为增量（每 5 分钟请求数），展示流量波峰波谷
    var deltas=[];
    var prev=0;
    for(var i=0;i<keys.length;i++){ var cur=bucketMap[keys[i]]; deltas.push(Math.max(0,cur-prev)); prev=cur; }
    keys.shift(); deltas.shift();  // 去掉第一个 baseline 点
    vals = deltas;

    var max=Math.max.apply(null,vals)||1;
    var xScale=function(i){return pad.l+(i/(keys.length-1))*(W-pad.l-pad.r)};
    var yScale=function(v){return H-pad.b-((v/max)*(H-pad.t-pad.b))};

    // Y轴刻度
    var yTicks=[0,max/2,max];
    var html='';
    yTicks.forEach(function(t){
      var y=yScale(t);
      html+='<line x1="'+pad.l+'" y1="'+y+'" x2="'+(W-pad.r)+'" y2="'+y+'" stroke="#21262d" stroke-width="1"/>';
      html+='<text x="'+(pad.l-6)+'" y="'+(y+4)+'" text-anchor="end" fill="#484f58" font-size="10">'+fmt(t)+'</text>';
    });

    // X轴时间标签
    var now=Date.now()/1000;
    for(var i=0;i<keys.length;i+=Math.max(1,Math.floor(keys.length/6))){
      var d=new Date(keys[i]*1000);
      var label=d.getHours()+':'+('0'+d.getMinutes()).slice(-2);
      html+='<text x="'+xScale(i)+'" y="'+(H-6)+'" text-anchor="middle" fill="#484f58" font-size="9">'+label+'</text>';
    }

    // 折线+面积
    var line='', area='';
    for(var i=0;i<keys.length;i++){
      var cx=xScale(i), cy=yScale(vals[i]);
      line+=(i?'L':'M')+cx.toFixed(1)+' '+cy.toFixed(1);
    }
    area=line+' L'+(xScale(keys.length-1)).toFixed(1)+' '+(H-pad.b)+' L'+pad.l+' '+(H-pad.b)+' Z';

    html+='<defs><linearGradient id="g-area" x1="0" y1="0" x2="0" y2="1"><stop offset="0%" stop-color="#58a6ff" stop-opacity="0.25"/><stop offset="100%" stop-color="#58a6ff" stop-opacity="0"/></linearGradient></defs>';
    html+='<path d="'+area+'" fill="url(#g-area)"/>';
    html+='<path d="'+line+'" fill="none" stroke="#58a6ff" stroke-width="2"/>';

    // 最新值标签
    var lastV=vals[vals.length-1], lastX=xScale(vals.length-1), lastY=yScale(lastV);
    html+='<circle cx="'+lastX.toFixed(1)+'" cy="'+lastY.toFixed(1)+'" r="3" fill="#58a6ff"/>';
    html+='<text x="'+(lastX-4)+'" y="'+(lastY-8)+'" text-anchor="end" fill="#f0f6fc" font-size="11" font-weight="600">'+fmt(lastV)+'</text>';

    svg.innerHTML=html;
  });
}

async function load(){
  if(!secret){showError('请添加 ?secret=xxx<br><br><a style="color:#58a6ff" href="'+base+'/dashboard?secret=change-me">'+base+'/dashboard?secret=change-me</a>');return}
  try{
    var s=await fetchJSON(base+'/status?secret='+secret);
    if(s.error){showError('鉴权失败，请检查 secret 参数');return}

    var allUpstreams=[];
    (s.groups||[{upstreams:s.upstreams||[]}]).forEach(function(g){
      (g.upstreams||[]).forEach(function(u){ allUpstreams.push(u); });
    });

    var totalReq=s.requests||0, totalErr=s.errors||0;
    var activeCount=allUpstreams.filter(function(u){return u.health==='healthy'}).length;

    document.getElementById('total-req').textContent=fmt(totalReq);
    document.getElementById('error-rate').textContent=fmtPct(totalErr,totalReq);
    document.getElementById('active-ups').textContent=activeCount+'/'+allUpstreams.length;
    document.getElementById('circuit-trips').textContent=fmt(s.circuit_trips||0);
    document.getElementById('rl-hits').textContent=fmt(s.rate_limit_hits||0);
    document.getElementById('gateway-addr').textContent=base;
    document.getElementById('updated').textContent=new Date().toLocaleTimeString();
    document.querySelectorAll('.loading').forEach(function(el){el.classList.remove('loading')});

    // QPS 估算（从全局趋势中取最近两个点计算 delta）
    var uniqueUpstreams=[];
    var seen={};
    allUpstreams.forEach(function(u){ var key=u.host+':'+u.port; if(!seen[key]){seen[key]=1;uniqueUpstreams.push(u);} });

    // 聚合趋势图
    renderGlobalChart(uniqueUpstreams);

    // 计算 QPS
    Promise.all(uniqueUpstreams.map(function(u){
      return fetchJSON(base+'/status/history?secret='+secret+'&upstream='+encodeURIComponent(u.host+':'+u.port)+'&range=604800');
    })).then(function(allSeries){
      var bucketMap={};
      allSeries.forEach(function(pts){
        (pts||[]).forEach(function(p){ bucketMap[p[0]]=(bucketMap[p[0]]||0)+p[1]; });
      });
      var keys=Object.keys(bucketMap).map(Number).sort(function(a,b){return a-b});
      if(keys.length>=2){
        var lastTotal=bucketMap[keys[keys.length-1]];
        var prevTotal=bucketMap[keys[keys.length-2]];
        var delta=lastTotal-prevTotal;
        var interval=keys[keys.length-1]-keys[keys.length-2];
        var qps=interval>0?Math.round(delta/interval):0;
        document.getElementById('est-qps').textContent=fmt(qps);
        document.getElementById('qps-detail').textContent='近5分钟均值';
      }
    });

    // 上游表格
    var tbody=document.getElementById('upstream-tbody');
    tbody.innerHTML='';
    allUpstreams.forEach(function(u){
      var hc=u.health==='healthy'?'healthy':'unhealthy';
      var cc=u.circuit||'closed';
      var tr=document.createElement('tr');
      tr.innerHTML=
        '<td><span class="status '+hc+'"></span></td>'+
        '<td><span class="host">'+u.host+':'+u.port+'</span></td>'+
        '<td class="mono">'+u.weight+'</td>'+
        '<td class="mono">'+fmt(u.requests)+'</td>'+
        '<td class="mono">'+(u.inflight||0)+'</td>'+
        '<td class="mono">'+fmtMs(u.p50_ms)+'</td>'+
        '<td class="mono"><span class="'+(u.errors>0?'err':'')+'">'+fmtPct(u.errors||0,u.requests)+'</span></td>'+
        '<td><span class="circuit '+cc+'">'+u.circuit+'</span></td>';
      tbody.appendChild(tr);
    });

  }catch(e){showError('加载失败: '+e.message)}
}

load();
setInterval(load,5000);
</script>
</body>
</html>
]=]

function _M.serve()
    ngx.header["Content-Type"] = "text/html; charset=utf-8"
    ngx.say(html)
end

return _M
