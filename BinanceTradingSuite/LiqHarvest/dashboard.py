#!/usr/bin/env python3
"""
策略控制面板 — Flask Web 桌面端
启动: python3 dashboard.py
"""
import json
import os
import sys
from pathlib import Path

from flask import Flask, jsonify, request

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import strategy_manager as sm

app = Flask(__name__)

# ── 页面 ──

HTML = """<!DOCTYPE html>
<html lang="zh-CN">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>策略控制面板</title>
<style>
*{margin:0;padding:0;box-sizing:border-box}
body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;background:#0d1117;color:#c9d1d9;padding:20px}
h1{font-size:22px;margin-bottom:16px;color:#58a6ff}
.grid{display:grid;grid-template-columns:1fr 1fr;gap:16px}
.card{background:#161b22;border:1px solid #30363d;border-radius:8px;padding:16px}
.card h2{font-size:16px;margin-bottom:12px;display:flex;align-items:center;gap:8px}
.dot{width:10px;height:10px;border-radius:50%;display:inline-block}.dot.on{background:#3fb950;box-shadow:0 0 6px #3fb950}.dot.off{background:#f85149}
.stat{display:flex;gap:12px;flex-wrap:wrap;font-size:13px;padding:8px;background:#0d1117;border-radius:6px;margin:8px 0}
.stat span{color:#8b949e}.stat b{color:#c9d1d9}
.section{font-size:14px;color:#8b949e;margin:12px 0 6px}
.row{display:flex;justify-content:space-between;align-items:center;margin:6px 0}
.row label{font-size:13px;color:#8b949e}
.row input{width:100px;text-align:right;background:#0d1117;border:1px solid #30363d;border-radius:4px;color:#c9d1d9;padding:2px 6px;font-size:13px}
.row .val{min-width:40px;text-align:right;font-size:13px;color:#58a6ff}
.btn{padding:6px 16px;border:none;border-radius:6px;font-size:13px;cursor:pointer}
.btn-start{background:#238636;color:#fff}.btn-stop{background:#da3633;color:#fff}.btn-save{background:#1f6feb;color:#fff}
.toggle{width:36px;height:20px;background:#21262d;border-radius:10px;cursor:pointer;display:inline-block;position:relative;transition:.2s}
.toggle.on{background:#238636}
.toggle::after{content:'';position:absolute;top:2px;left:2px;width:16px;height:16px;background:#fff;border-radius:50%;transition:.2s}
.toggle.on::after{left:18px}
.btn-group{display:flex;gap:8px;margin-top:12px;flex-wrap:wrap}
.log{background:#0d1117;border:1px solid #30363d;border-radius:4px;padding:8px;font-family:monospace;font-size:11px;height:120px;overflow-y:auto;margin-top:8px;color:#8b949e;white-space:pre-wrap}
@media(max-width:800px){.grid{grid-template-columns:1fr}}
</style>
</head>
<body>
<h1>🔧 策略控制面板</h1>
<div class="grid" id="app"></div>
<script>
const SCALP_FIELDS = [
  {k:'LEVERAGE',l:'杠杆倍数',s:'x'},
  {k:'ENTRY_THRESHOLD_PCT',l:'入场阈值',s:'%'},
  {k:'TP_MARGIN_PCT',l:'止盈',s:'%'},
  {k:'SL_MA7_DEVIATION_PCT',l:'止损偏离MA7',s:'%'},
  {k:'POSITION_PCT',l:'仓位比例',s:'%'},
  {k:'MAX_POSITIONS',l:'最大持仓',s:''},
  {k:'MAX_DAILY_LOSS_USDT',l:'日亏损上限',s:'U'},
  {k:'MIN_24H_VOLUME_USDT',l:'成交额下限',s:'U'},
  {k:'MAX_HOLD_SECONDS',l:'持仓超时',s:'s'},
];
const SCALP_TOGGLES = [
  {k:'USE_TREND_FILTER',l:'趋势过滤 (2min)'},
  {k:'USE_MEAN_REVERSION',l:'均值回归 (0.35%)'},
  {k:'USE_KLINE_FILTER',l:'K线方向 (5根1m)'},
  {k:'USE_MA7_FILTER',l:'MA7均线'},
];
const BOTTOM_FIELDS = [
  {k:'LEVERAGE',l:'杠杆倍数',s:'x'},
  {k:'POSITION_PCT',l:'仓位比例',s:'%'},
  {k:'TP_MARGIN_PCT',l:'止盈',s:'%'},
  {k:'SL_MARGIN_PCT',l:'止损',s:'%'},
  {k:'LOOKBACK_MINUTES',l:'回溯窗口',s:'min'},
  {k:'TRIGGER_DISCOUNT',l:'触发折扣',s:'x'},
  {k:'SCAN_INTERVAL',l:'扫描间隔',s:'s'},
  {k:'MIN_24H_VOLUME_USDT',l:'成交额下限',s:'U'},
  {k:'MAX_DAILY_LOSS_USDT',l:'日亏损上限',s:'U'},
];

let config = {scalp:{},bottom:{}};
let status = {scalp:{running:false,positions:0,daily_pnl:0,balance:0,coins:0},
              bottom:{running:false,positions:0,daily_pnl:0,balance:0,coins:0}};
let logs = {scalp:'',bottom:''};
let dirty = false;

function fieldHTML(cfg, f) {
  let v = cfg[f.k] ?? '';
  return `<div class="row"><label>${f.l}</label><input type="number" step="any" value="${v}" onchange="upd('${f.k}',this.value,'scalp')"><span class="val">${f.s}</span></div>`;
}

function toggleHTML(cfg, t, name) {
  let on = cfg[t.k] ? 'on' : '';
  return `<div class="row"><label>${t.l}</label><div style="display:flex;align-items:center;gap:6px;cursor:pointer" onclick="tog('${name}','${t.k}')"><span class="toggle ${on}"></span></div></div>`;
}

function statusHTML(s, name) {
  let cls = s.running ? 'on' : 'off';
  return `<h2><span class="dot ${cls}"></span> ${name}</h2>
    <div class="stat">
      <span>状态: <b>${s.running?'运行中':'已停止'}</b></span>
      <span>持仓: <b>${s.positions}</b></span>
      <span>日PnL: <b style="color:${s.daily_pnl>=0?'#3fb950':'#f85149'}">${s.daily_pnl.toFixed(4)}U</b></span>
      <span>权益: <b>$${s.balance.toFixed(4)}</b></span>
      <span>币种: <b>${s.coins}</b></span>
    </div>`;
}

function render() {
  let html = '';
  for (let name of ['scalp','bottom']) {
    let s = status[name];
    let cfg = config[name];
    let label = name === 'scalp' ? '高频剥头皮 (ScalpHarvester)' : '低位挖掘 (BottomFisher)';
    let fields = name === 'scalp' ? SCALP_FIELDS : BOTTOM_FIELDS;
    let toggles = name === 'scalp' ? SCALP_TOGGLES : [];

    html += `<div class="card">`;
    html += statusHTML(s, label);
    html += `<div class="section">入场参数</div>`;
    for (let f of fields) html += fieldHTML(cfg, f);
    if (toggles.length) {
      html += `<div class="section">过滤开关</div>`;
      for (let t of toggles) html += toggleHTML(cfg, t, 'scalp');
    }
    html += `<div class="btn-group">
      <button class="btn btn-start" onclick="ctrl('${name}','start')">▶ 启动</button>
      <button class="btn btn-stop" onclick="ctrl('${name}','stop')">⏹ 停止</button>
      <button class="btn btn-save" onclick="save()">💾 保存</button>
    </div>
    <div class="log" id="log_${name}">${logs[name]}</div>`;
    html += `</div>`;
  }
  document.getElementById('app').innerHTML = html;
}

let logTimer = 0;
function log(name, msg) {
  let t = new Date().toLocaleTimeString();
  logs[name] = `[${t}] ${msg}\\n` + logs[name];
  if (logs[name].length > 5000) logs[name] = logs[name].slice(0,5000);
  let el = document.getElementById('log_'+name);
  if (el) el.textContent = logs[name];
}

async function load() {
  let r = await fetch('/api/config');
  let d = await r.json();
  config.scalp = d.scalp || {};
  config.bottom = d.bottom || {};
  log('scalp','📋 配置已加载');
  log('bottom','📋 配置已加载');
}

async function poll() {
  for (let name of ['scalp','bottom']) {
    let r = await fetch('/api/'+name+'/status');
    let s = await r.json();
    status[name] = s;
    status[name].running = s.running;
  }
  logTimer++;
  if (logTimer%5===0) {
    if (status.scalp.running) log('scalp','📊 运行中...');
    if (status.bottom.running) log('bottom','📊 运行中...');
  }
  render();
}

async function ctrl(name, action) {
  let r = await fetch('/api/'+name+'/'+action, {method:'POST'});
  let d = await r.json();
  log(name, d.msg);
  if (action==='start') status[name].running = true;
  else status[name].running = false;
  render();
}

async function save() {
  let r = await fetch('/api/config',{method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(config)});
  let d = await r.json();
  log('scalp', d.ok?'✅ 配置已保存':'❌ 保存失败');
  log('bottom', d.ok?'✅ 配置已保存':'❌ 保存失败');
}

function upd(k, v, name) {
  config[name][k] = parseFloat(v);
}

function tog(name, k) {
  config[name][k] = !config[name][k];
  render();
  save();
}

load().then(poll);
setInterval(poll, 2000);
</script>
</body>
</html>"""

@app.route("/")
def index():
    return HTML, 200, {"Content-Type": "text/html; charset=utf-8"}


# ── REST API ──

@app.route("/api/config")
def api_get_config():
    return jsonify(sm.load_config())


@app.route("/api/config", methods=["POST"])
def api_set_config():
    data = request.get_json()
    sm.save_config(data)
    return jsonify({"ok": True})


@app.route("/api/scalp/status")
def api_scalp_status():
    return jsonify(sm.get_status("scalp"))


@app.route("/api/bottom/status")
def api_bottom_status():
    return jsonify(sm.get_status("bottom"))


@app.route("/api/scalp/start", methods=["POST"])
def api_scalp_start():
    return jsonify(sm.start_strategy("scalp"))


@app.route("/api/bottom/start", methods=["POST"])
def api_bottom_start():
    return jsonify(sm.start_strategy("bottom"))


@app.route("/api/scalp/stop", methods=["POST"])
def api_scalp_stop():
    return jsonify(sm.stop_strategy("scalp"))


@app.route("/api/bottom/stop", methods=["POST"])
def api_bottom_stop():
    return jsonify(sm.stop_strategy("bottom"))


# ── 启动 ──

if __name__ == "__main__":
    port = int(os.environ.get("PORT", 8899))
    print(f"🌐 控制面板启动: http://127.0.0.1:{port}")
    app.run(host="127.0.0.1", port=port, debug=False)
