"""
===================================
app.py — Web 服务主入口
===================================
职责: aiohttp HTTP + WebSocket 服务
  - HTTP: 单页 Web UI 交易界面
  - REST API: 下单、查询、管理
  - WebSocket: 实时价格推送

用法:
  cd binance_liq_harvest
  python -m trading_platform.app

访问:
  http://localhost:9090  → 交易终端 UI
  ws://localhost:9090/ws → 实时价格流
"""
import asyncio
import json
import logging
import os
import sys
import time

import aiohttp
from aiohttp import web

from .executor_client import PlatformExecutor, FAPI_REST
from .hedge_manager import HedgeManager

logger = logging.getLogger(__name__)

# ============================================================
# HTML 单页应用（内嵌，零外部依赖）
# ============================================================

HTML = r"""<!DOCTYPE html>
<html lang="zh">
<head>
<meta charset="UTF-8">
<meta name="viewport" content="width=device-width, initial-scale=1.0">
<title>Binance 交易终端</title>
<style>
  :root {
    --bg: #0a0e17; --card: #131926; --border: #1e293b;
    --text: #e2e8f0; --dim: #64748b; --accent: #3b82f6;
    --green: #22c55e; --red: #ef4444; --amber: #f59e0b;
  }
  * { margin: 0; padding: 0; box-sizing: border-box; }
  body {
    font-family: -apple-system, BlinkMacSystemFont, 'SF Mono', 'Menlo', monospace;
    background: var(--bg); color: var(--text); font-size: 13px;
    line-height: 1.5; padding: 12px;
  }
  .header {
    display: flex; justify-content: space-between; align-items: center;
    margin-bottom: 12px; padding-bottom: 10px;
    border-bottom: 1px solid var(--border);
  }
  .header h1 { font-size: 17px; font-weight: 600; }
  .status-bar { display: flex; gap: 16px; font-size: 11px; color: var(--dim); }
  .status-bar .dot { display: inline-block; width: 6px; height: 6px;
    border-radius: 50%; margin-right: 4px; }

  .grid { display: grid; gap: 10px; }
  .card {
    background: var(--card); border: 1px solid var(--border);
    border-radius: 8px; padding: 12px;
  }
  .card-title { font-size: 11px; text-transform: uppercase;
    letter-spacing: 0.5px; color: var(--dim); margin-bottom: 8px; }

  /* 交易表单 */
  .trade-form { display: flex; flex-direction: column; gap: 8px; }
  .form-row { display: flex; gap: 6px; align-items: center; }
  .form-row label { font-size: 11px; color: var(--dim); min-width: 40px; }
  input, select {
    background: #0f172a; border: 1px solid var(--border); border-radius: 4px;
    color: var(--text); padding: 5px 8px; font-size: 12px; font-family: inherit;
    width: 100%;
  }
  input:focus, select:focus { outline: none; border-color: var(--accent); }
  input.num { text-align: right; width: 100px; }
  select { cursor: pointer; }

  .btn-group { display: flex; gap: 6px; margin-top: 4px; }
  .btn {
    flex: 1; padding: 7px 12px; border: none; border-radius: 5px;
    font-size: 12px; font-weight: 600; cursor: pointer;
    transition: opacity .15s; font-family: inherit;
  }
  .btn:hover { opacity: .85; }
  .btn:active { transform: scale(.97); }
  .btn-long  { background: #16a34a; color: #fff; }
  .btn-short { background: #dc2626; color: #fff; }
  .btn-sm    { padding: 4px 10px; font-size: 11px; }
  .btn-outline { background: transparent; border: 1px solid var(--border); color: var(--text); }

  /* 持仓表 */
  table { width: 100%; border-collapse: collapse; font-size: 12px; }
  th { text-align: left; color: var(--dim); font-weight: 600;
    font-size: 11px; padding: 5px 6px; border-bottom: 1px solid var(--border); }
  td { padding: 4px 6px; border-bottom: 1px solid #ffffff08; }
  tr:hover { background: #ffffff05; }
  .green { color: var(--green); }
  .red   { color: var(--red); }
  .amber { color: var(--amber); }

  /* 结果弹窗 */
  .toast {
    position: fixed; top: 16px; right: 16px; z-index: 999;
    background: var(--card); border: 1px solid var(--green);
    border-radius: 8px; padding: 12px 16px; font-size: 12px;
    max-width: 360px; box-shadow: 0 4px 20px rgba(0,0,0,.4);
    animation: slideIn .2s ease-out;
  }
  .toast.error { border-color: var(--red); }
  @keyframes slideIn { from { transform: translateX(100%); opacity: 0; } to { transform: translateX(0); opacity: 1; } }

  .pair-search { display: flex; gap: 6px; }
  .pair-search input { flex: 1; }
  .pair-search select { width: 120px; }
</style>
</head>
<body>

<div class="header">
  <h1>Binance 交易终端</h1>
  <div class="status-bar">
    <span><span class="dot" id="ws-dot" style="background:var(--amber)"></span><span id="ws-status">连接中...</span></span>
    <span>余额: <strong id="balance-display">--</strong> USDC</span>
    <span>持仓: <strong id="pos-count">0</strong></span>
  </div>
</div>

<!-- 交易面板 -->
<div class="card">
  <div class="card-title">一键下单</div>
  <div class="trade-form">
    <div class="pair-search">
      <input type="text" id="pair-search" placeholder="搜索币种..." oninput="filterPairs()">
      <select id="pair-select" onchange="onPairChange()"></select>
    </div>
    <div style="display:grid;grid-template-columns:1fr 1fr;gap:8px;margin-top:4px">
      <div>
        <label style="font-size:11px;color:var(--dim)">做多数量</label>
        <input type="number" id="qty-long" class="num" value="0.01" step="0.001" min="0">
      </div>
      <div>
        <label style="font-size:11px;color:var(--dim)">做空数量</label>
        <input type="number" id="qty-short" class="num" value="0.01" step="0.001" min="0">
      </div>
    </div>
    <div style="font-size:11px;color:var(--dim);margin-top:2px">
      当前价: <strong id="current-price">--</strong>
    </div>
    <div class="btn-group">
      <button class="btn btn-long"  onclick="placeOrder('long')">做多</button>
      <button class="btn btn-short" onclick="placeOrder('short')">做空</button>
    </div>
  </div>
</div>

<!-- 持仓 -->
<div class="card" style="margin-top:10px">
  <div class="card-title" style="display:flex;justify-content:space-between;align-items:center">
    <span>当前持仓</span>
    <button class="btn btn-sm btn-outline" onclick="cancelAll()">一键全撤</button>
  </div>
  <div id="positions"><table>
    <thead><tr>
      <th>品种</th><th>方向</th><th>数量</th><th>入场价</th><th>标记价</th><th>未实现盈亏</th><th>杠杆</th><th>操作</th>
    </tr></thead>
    <tbody id="pos-body"></tbody>
  </table></div>
  <div id="pos-empty" style="text-align:center;padding:16px 0;color:var(--dim);font-size:12px">无持仓</div>
</div>

<!-- 挂单 (普通+条件单) -->
<div class="card" style="margin-top:10px">
  <div class="card-title">当前挂单</div>
  <div id="orders-wrap"><table>
    <thead><tr>
      <th>品种</th><th>类型</th><th>方向</th><th>数量</th><th>价格</th><th>触发价</th><th>状态</th><th>操作</th>
    </tr></thead>
    <tbody id="orders-body"></tbody>
  </table></div>
  <div id="orders-empty" style="text-align:center;padding:16px 0;color:var(--dim);font-size:12px">无挂单</div>
</div>

<!-- 执行结果 -->
<div id="toast-container"></div>

<script>
const WS_URL = (location.protocol === 'https:' ? 'wss://' : 'ws://') + location.host + '/ws';
let ws = null;
let allPairs = [];
let currentPair = 'ETHUSDT';
let currentPrice = 0;

// ---- WebSocket 实时行情 ----
function connectWS() {
  ws = new WebSocket(WS_URL);
  const dot = document.getElementById('ws-dot');
  const st = document.getElementById('ws-status');

  ws.onopen = () => { dot.style.background = '#22c55e'; st.textContent = '已连接'; };
  ws.onclose = () => { dot.style.background = '#ef4444'; st.textContent = '断开'; setTimeout(connectWS, 2000); };
  ws.onmessage = (e) => {
    try {
      const msg = JSON.parse(e.data);
      if (msg.type === 'prices') {
        updatePrices(msg.data);
      } else if (msg.type === 'positions') {
        updatePositions(msg.data);
      } else if (msg.type === 'balance') {
        document.getElementById('balance-display').textContent = msg.data.toFixed(4);
      }
    } catch(_) {}
  };
}

function updatePrices(prices) {
  allPairs = Object.keys(prices);
  const sel = document.getElementById('pair-select');
  if (sel.options.length === 0) {
    allPairs.forEach(p => { const o = document.createElement('option'); o.value = p; o.textContent = p; sel.appendChild(o); });
    sel.value = currentPair;
  }
  if (prices[currentPair]) {
    currentPrice = prices[currentPair];
    document.getElementById('current-price').textContent = currentPrice.toFixed(4);
  }
}

function updatePositions(positions) {
  const body = document.getElementById('pos-body');
  const empty = document.getElementById('pos-empty');
  document.getElementById('pos-count').textContent = positions.length;

  if (positions.length === 0) {
    body.innerHTML = ''; empty.style.display = 'block'; return;
  }
  empty.style.display = 'none';
  body.innerHTML = positions.map(p => {
    const pnlCls = p.pnl >= 0 ? 'green' : 'red';
    const sideCls = p.side === 'LONG' ? 'green' : 'red';
    return `<tr>
      <td>${p.symbol}</td>
      <td class="${sideCls}">${p.side}</td>
      <td>${p.quantity.toFixed(4)}</td>
      <td>${p.entry_price.toFixed(4)}</td>
      <td>${p.mark_price.toFixed(4)}</td>
      <td class="${pnlCls}">${p.pnl >= 0 ? '+' : ''}${p.pnl.toFixed(4)}</td>
      <td>${p.leverage}x</td>
      <td><button class="btn btn-sm btn-short" onclick="closePosition('${p.symbol}','${p.side}')">平仓</button></td>
    </tr>`;
  }).join('');
}

// ---- 下单 ----
async function placeOrder(mode) {
  const sym = document.getElementById('pair-select').value;
  const qL = parseFloat(document.getElementById('qty-long').value) || 0;
  const qS = parseFloat(document.getElementById('qty-short').value) || 0;

  if (mode === 'long' && qL <= 0) return toast('请输入做多数量', true);
  if (mode === 'short' && qS <= 0) return toast('请输入做空数量', true);

  let legs = [];
  if (mode === 'long') legs.push({symbol: sym, side: 'BUY', quantity: qL, position_side: 'LONG'});
  else if (mode === 'short') legs.push({symbol: sym, side: 'SELL', quantity: qS, position_side: 'SHORT'});

  const res = await fetch('/api/order', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({legs, mode}),
  });
  const data = await res.json();
  const ok = data.failed === 0;
  toast(data.details.map(d => `${d.symbol} ${d.side} ${d.quantity} → ${d.result}`).join('<br>'), !ok);
  refreshAll();
}

async function closePosition(symbol, side) {
  const exitSide = side === 'LONG' ? 'SELL' : 'BUY';
  const exitPos = side === 'LONG' ? 'SHORT' : 'LONG';
  const res = await fetch('/api/order', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify({legs: [{symbol, side: exitSide, quantity: 999, position_side: exitPos}], mode: 'close'}),
  });
  const data = await res.json();
  toast(`平仓 ${symbol} ${data.details?.[0]?.result || '完成'}`, data.failed > 0);
  refreshAll();
}

// ---- 撤单 ----
async function cancelOrder(symbol, orderId, isCond) {
  const url = isCond ? '/api/cancel_conditional_order' : '/api/cancel_order';
  const body = isCond ? {symbol, strategyId: orderId} : {symbol, orderId};
  const res = await fetch(url, {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: JSON.stringify(body),
  });
  const data = await res.json();
  toast(data.success ? `已撤 ${symbol} ${orderId}` : `撤单失败: ${data.error}`, !data.success);
  refreshOrders();
}

async function cancelAll() {
  if (!confirm('确认撤掉全部挂单(普通单+条件单)?')) return;
  const res = await fetch('/api/cancel_all', {
    method: 'POST',
    headers: {'Content-Type': 'application/json'},
    body: '{}',
  });
  const data = await res.json();
  toast(`已撤 普通${data.cancelled_normal}/${data.total_normal} 条件${data.cancelled_conditional}/${data.total_conditional}`,
        data.errors && data.errors.length > 0);
  refreshOrders();
}

async function refreshOrders() {
  try {
    const [n, c] = await Promise.all([
      fetch('/api/open_orders').then(r => r.json()),
      fetch('/api/conditional_orders').then(r => r.json()),
    ]);
    const all = [];
    (n.orders || []).forEach(o => all.push({...o, _is_cond: false, _id: o.order_id}));
    (c.orders || []).forEach(o => all.push({
      ...o, _is_cond: true, _id: o.strategy_id,
      type: o.strategy_type, orig_qty: o.orig_qty,
      status: o.strategy_status,
    }));
    const body = document.getElementById('orders-body');
    const empty = document.getElementById('orders-empty');
    if (all.length === 0) { body.innerHTML = ''; empty.style.display = 'block'; return; }
    empty.style.display = 'none';
    body.innerHTML = all.map(o => {
      const sideCls = o.side === 'BUY' ? 'green' : 'red';
      const stop = o.stop_price ? Number(o.stop_price).toFixed(4) : '-';
      const px   = o.price ? Number(o.price).toFixed(4) : '市价';
      return `<tr>
        <td>${o.symbol}</td>
        <td>${o.type || '-'}</td>
        <td class="${sideCls}">${o.side} ${o.position_side}</td>
        <td>${Number(o.orig_qty).toFixed(4)}</td>
        <td>${px}</td>
        <td>${stop}</td>
        <td>${o.status}</td>
        <td><button class="btn btn-sm btn-outline" onclick="cancelOrder('${o.symbol}','${o._id}',${o._is_cond})">撤</button></td>
      </tr>`;
    }).join('');
  } catch(e) { console.warn(e); }
}

// ---- 工具 ----
function filterPairs() {
  const q = document.getElementById('pair-search').value.toUpperCase();
  const sel = document.getElementById('pair-select');
  const filtered = allPairs.filter(p => p.includes(q));
  sel.innerHTML = filtered.map(p => `<option value="${p}">${p}</option>`).join('');
  if (filtered.length > 0) { sel.value = filtered[0]; currentPair = filtered[0]; }
  else if (filtered.length === 0) { sel.innerHTML = '<option>-- 无结果 --</option>'; }
}

function onPairChange() {
  const sel = document.getElementById('pair-select');
  if (sel.value) currentPair = sel.value;
}

function refreshAll() { ws && ws.send(JSON.stringify({type: 'refresh'})); refreshOrders(); }

function toast(msg, isError = false) {
  const c = document.getElementById('toast-container');
  const t = document.createElement('div');
  t.className = 'toast' + (isError ? ' error' : '');
  t.innerHTML = msg;
  c.appendChild(t);
  setTimeout(() => t.remove(), 4000);
}

// ---- 启动 ----
connectWS();
refreshOrders();
setInterval(refreshAll, 10000);
</script>
</body>
</html>"""

# ============================================================
# aiohttp Web 应用
# ============================================================

class TradingPlatform:
    """Binance 交易终端 — Web 服务"""

    def __init__(self):
        self.executor = PlatformExecutor()
        self.hedge = HedgeManager(self.executor)
        self.app = web.Application()
        self._runner: web.AppRunner = None
        self._ws_clients: set = set()
        self._price_task: asyncio.Task = None
        self._setup_routes()

    def _setup_routes(self):
        self.app.router.add_get("/", self._handle_index)
        self.app.router.add_get("/ws", self._handle_ws)
        self.app.router.add_post("/api/order", self._handle_order)
        self.app.router.add_get("/api/combos", self._handle_list_combos)
        self.app.router.add_post("/api/combos", self._handle_save_combo)
        self.app.router.add_post("/api/combo/execute", self._handle_exec_combo)
        self.app.router.add_get("/api/positions", self._handle_positions)
        self.app.router.add_get("/api/balance", self._handle_balance)
        self.app.router.add_get("/api/prices", self._handle_prices)
        self.app.router.add_get("/api/pairs", self._handle_pairs)
        self.app.router.add_get("/api/all_pairs", self._handle_all_pairs)
        self.app.router.add_get("/api/account", self._handle_account)
        self.app.router.add_get("/api/open_orders", self._handle_open_orders)
        self.app.router.add_get("/api/ticker", self._handle_ticker)
        self.app.router.add_get("/api/depth", self._handle_depth)
        self.app.router.add_get("/api/recent_trades", self._handle_recent_trades)
        self.app.router.add_get("/api/balances", self._handle_balances)
        self.app.router.add_post("/api/cancel_order", self._handle_cancel_order)
        self.app.router.add_post("/api/conditional_orders", self._handle_conditional_orders)
        self.app.router.add_get("/api/conditional_orders", self._handle_list_conditional_orders)
        self.app.router.add_post("/api/cancel_conditional_order", self._handle_cancel_conditional_order)
        self.app.router.add_post("/api/cancel_all", self._handle_cancel_all)
        self.app.router.add_post("/api/reload_precisions", self._handle_reload_precisions)

    # ---- HTTP ----

    async def _handle_index(self, request):
        return web.Response(text=HTML, content_type="text/html", charset="utf-8")

    async def _handle_order(self, request):
        body = await request.json()
        legs = body.get("legs", [])
        mode = body.get("mode", "hedge")
        if mode == "close":
            # 平仓: quantity=999 表示全平
            for leg in legs:
                if leg["quantity"] == 999:
                    pos_list = await self.executor.get_positions()
                    for p in pos_list:
                        if p["symbol"] == leg["symbol"]:
                            leg["quantity"] = p["quantity"]
                            break
            result = await self.hedge.execute_custom(legs, "hedge")
        else:
            result = await self.hedge.execute_custom(legs, mode)
        await self._broadcast_positions()
        return web.json_response(result)

    async def _handle_list_combos(self, request):
        return web.json_response({"combos": self.hedge.list_combos()})

    async def _handle_save_combo(self, request):
        body = await request.json()
        key = self.hedge.save_combo(body["name"], body["legs"])
        return web.json_response({"key": key, "name": body["name"]})

    async def _handle_exec_combo(self, request):
        body = await request.json()
        result = await self.hedge.execute_combo(body["key"], body.get("mode", "hedge"))
        await self._broadcast_positions()
        return web.json_response(result)

    async def _handle_positions(self, request):
        positions = await self.executor.get_positions()
        return web.json_response({"positions": positions})

    async def _handle_balance(self, request):
        balance = await self.executor.get_balance()
        return web.json_response({"balance": balance})

    async def _handle_prices(self, request):
        """返回全部币种实时价格"""
        prices = {}
        try:
            prices = await self.executor.get_all_prices()
        except Exception:
            pass
        return web.json_response({"prices": prices})

    async def _handle_balances(self, request):
        """返回全部币种余额"""
        balances = await self.executor.get_all_balances()
        return web.json_response({"balances": balances})

    async def _handle_conditional_orders(self, request):
        """
        批量挂条件单 — POST /api/conditional_orders
        2025-12-09 起止盈止损必须走此接口，旧接口返回 -4120
        body: {"orders": [
          {"symbol":"ETHUSDT","side":"SELL","position_side":"LONG",
           "strategy_type":"TAKE_PROFIT_MARKET","stop_price":2500.0,
           "quantity":0.01,"working_type":"MARK_PRICE"}, ...
        ]}
        """
        body = await request.json()
        orders = body.get("orders", [])
        results = []
        for o in orders:
            r = await self.executor.place_conditional_order(
                symbol=o["symbol"],
                side=o["side"],
                strategy_type=o["strategy_type"],
                stop_price=float(o["stop_price"]),
                quantity=float(o["quantity"]),
                position_side=o.get("position_side", "LONG"),
                working_type=o.get("working_type", "MARK_PRICE"),
                price=float(o["price"]) if o.get("price") is not None else None,
            )
            # 严格判断: algoId 才算成功（新接口返回 algoId，旧接口返回 strategyId）
            if r.get("algoId"):
                result_field = r.get("algoId")
                ok = True
            elif r.get("simulated"):
                result_field = f"sim_{r.get('algoId','')}"
                ok = True
            else:
                result_field = f"error: {r.get('error', str(r)[:100])}"
                ok = False
            results.append({
                "symbol": o["symbol"],
                "strategy_type": o["strategy_type"],
                "stop_price": o["stop_price"],
                "side": o["side"],
                "position_side": o.get("position_side"),
                "result": result_field,
                "ok": ok,
            })
        success = sum(1 for r in results if r["ok"])
        return web.json_response({"success": success, "total": len(results), "details": results})

    async def _handle_cancel_order(self, request):
        """撤普通单"""
        body = await request.json()
        symbol = body.get("symbol", "")
        order_id = body.get("orderId", "")
        result = {"success": False, "error": "缺少参数"}
        if symbol and order_id:
            try:
                r = await self.executor._rest_cancel_order(symbol, order_id)
                # PAPI 撤单成功返回里带 orderId 字段；空 dict / 缺字段视为失败
                if isinstance(r, dict) and r.get("orderId"):
                    result = {"success": True, "orderId": r.get("orderId"), "raw": r}
                else:
                    result = {"success": False,
                              "error": r.get("msg", "撤单失败") if isinstance(r, dict) else "无响应",
                              "raw": r}
            except Exception as e:
                result = {"success": False, "error": str(e)}
        return web.json_response(result)

    async def _handle_list_conditional_orders(self, request):
        """列出当前条件单 (TP/SL)"""
        symbol = request.query.get("symbol", "")
        orders = await self.executor._rest_open_conditional_orders(symbol)
        return web.json_response({"orders": orders})

    async def _handle_cancel_conditional_order(self, request):
        """撤条件单"""
        body = await request.json()
        symbol = body.get("symbol", "")
        strategy_id = body.get("algoId", "") or body.get("strategyId", "")
        result = {"success": False, "error": "缺少参数"}
        if symbol and strategy_id:
            try:
                r = await self.executor._rest_cancel_conditional_order(symbol, strategy_id)
                if isinstance(r, dict) and r.get("algoId"):
                    result = {"success": True, "algoId": r.get("algoId"), "raw": r}
                else:
                    result = {"success": False,
                              "error": r.get("msg", "撤条件单失败") if isinstance(r, dict) else "无响应",
                              "raw": r}
            except Exception as e:
                result = {"success": False, "error": str(e)}
        return web.json_response(result)

    async def _handle_cancel_all(self, request):
        """一键全撤 — 普通单 + 条件单。可选 symbol 过滤"""
        body = await request.json() if request.body_exists else {}
        symbol = body.get("symbol", "")
        normal = await self.executor._rest_open_orders(symbol)
        cond = await self.executor._rest_open_conditional_orders(symbol)
        cancelled_normal, cancelled_cond, errors = 0, 0, []
        for o in normal:
            try:
                r = await self.executor._rest_cancel_order(o["symbol"], o["order_id"])
                if isinstance(r, dict) and r.get("orderId"):
                    cancelled_normal += 1
                else:
                    errors.append(f"普通 {o['symbol']}#{o['order_id']}: "
                                  f"{r.get('msg', '失败') if isinstance(r, dict) else '无响应'}")
            except Exception as e:
                errors.append(f"普通 {o['symbol']}#{o['order_id']}: {e}")
        for o in cond:
            try:
                r = await self.executor._rest_cancel_conditional_order(
                    o["symbol"], o["strategy_id"])
                if isinstance(r, dict) and r.get("strategyId"):
                    cancelled_cond += 1
                else:
                    errors.append(f"条件 {o['symbol']}#{o['strategy_id']}: "
                                  f"{r.get('msg', '失败') if isinstance(r, dict) else '无响应'}")
            except Exception as e:
                errors.append(f"条件 {o['symbol']}#{o['strategy_id']}: {e}")
        return web.json_response({
            "cancelled_normal": cancelled_normal,
            "cancelled_conditional": cancelled_cond,
            "total_normal": len(normal),
            "total_conditional": len(cond),
            "errors": errors,
        })

    async def _handle_reload_precisions(self, request):
        """运行时重新加载精度表"""
        before = len(self.executor._tick_size)
        await self.executor._load_precisions()
        after = len(self.executor._tick_size)
        return web.json_response({
            "before": before, "after": after, "ok": after > 0,
        })

    async def _handle_pairs(self, request):
        """返回可交易币种列表"""
        pairs = list(self.executor._tick_size.keys()) if self.executor._tick_size else []
        if not pairs:
            # fallback: 从 config 取
            try:
                from .. import config
                pairs = config.SYMBOLS
            except ImportError:
                pairs = ["BTCUSDT", "ETHUSDT", "SOLUSDT", "BNBUSDT"]
        return web.json_response({"pairs": pairs})

    async def _handle_all_pairs(self, request):
        """从 Binance 实时拉取全部 USDT 交易对"""
        try:
            session = self.executor._session
            if session is None or session.closed:
                session = aiohttp.ClientSession()

            async with session.get(
                "https://fapi.binance.com/fapi/v1/exchangeInfo", timeout=10
            ) as resp:
                if resp.status == 200:
                    info = await resp.json()
                    symbols = [
                        s["symbol"] for s in info.get("symbols", [])
                        if (s["symbol"].endswith("USDT") or s["symbol"].endswith("USDC"))
                           and s["status"] == "TRADING"
                           and s["contractType"] == "PERPETUAL"
                    ]
                    symbols.sort()
                    # 缓存精度
                    if hasattr(self.executor, '_tick_size'):
                        for s in info.get("symbols", []):
                            sym = s["symbol"]
                            filters = {f["filterType"]: f for f in s.get("filters", [])}
                            self.executor._tick_size[sym] = float(
                                filters.get("PRICE_FILTER", {}).get("tickSize", 0.01))
                            self.executor._step_size[sym] = float(
                                filters.get("MARKET_LOT_SIZE", {}).get("stepSize", 0.001))
                    return web.json_response({"pairs": symbols})
        except Exception as e:
            logger.warning(f"拉取全部币种失败: {e}")
        # fallback: 返回已有精度缓存中的 USDT/USDC 币种
        cached = [s for s in self.executor._tick_size.keys()
                  if s.endswith("USDT") or s.endswith("USDC")]
        return web.json_response({"pairs": sorted(cached)[:200]})

    async def _handle_account(self, request):
        """完整账户信息"""
        info = await self.executor.get_account_info()
        return web.json_response(info)

    async def _handle_open_orders(self, request):
        """当前未成交订单"""
        symbol = request.query.get("symbol", "")
        orders = await self.executor._rest_open_orders(symbol)
        return web.json_response({"orders": orders})

    async def _handle_ticker(self, request):
        """24h 行情数据"""
        symbol = request.query.get("symbol", "BTCUSDT")
        data = await self.executor._rest_ticker(symbol)
        return web.json_response(data)

    async def _handle_depth(self, request):
        """订单簿快照"""
        symbol = request.query.get("symbol", "BTCUSDT")
        limit = int(request.query.get("limit", "10"))
        data = await self.executor._rest_depth(symbol, limit)
        return web.json_response(data)

    async def _handle_recent_trades(self, request):
        """最近成交"""
        symbol = request.query.get("symbol", "BTCUSDT")
        limit = int(request.query.get("limit", "10"))
        trades = []
        try:
            if self.executor._session:
                async with self.executor._session.get(
                    f"{FAPI_REST}/fapi/v1/trades",
                    params={"symbol": symbol, "limit": limit}, timeout=10
                ) as resp:
                    if resp.status == 200:
                        raw = await resp.json()
                        trades = [{
                            "price": float(t["price"]),
                            "qty": float(t["qty"]),
                            "time": t["time"],
                            "is_buyer_maker": t.get("isBuyerMaker", True),
                        } for t in raw]
        except Exception as e:
            logger.warning(f"成交查询失败: {e}")
        return web.json_response({"trades": trades})

    # ---- WebSocket 实时推送 ----

    async def _handle_ws(self, request):
        ws = web.WebSocketResponse()
        await ws.prepare(request)
        self._ws_clients.add(ws)
        try:
            # 立即推送一次完整数据
            await self._send_full_state(ws)
            async for msg in ws:
                if msg.type == aiohttp.WSMsgType.TEXT:
                    try:
                        data = json.loads(msg.data)
                        if data.get("type") == "refresh":
                            await self._send_full_state(ws)
                    except: pass
                elif msg.type == aiohttp.WSMsgType.ERROR:
                    break
        finally:
            self._ws_clients.discard(ws)
        return ws

    async def _send_full_state(self, ws: web.WebSocketResponse):
        """向单个客户端推送全部状态"""
        try:
            prices = await self.executor.get_all_prices()
            await ws.send_json({"type": "prices", "data": prices})
            positions = await self.executor.get_positions()
            await ws.send_json({"type": "positions", "data": positions})
            balance = await self.executor.get_balance()
            await ws.send_json({"type": "balance", "data": balance})
        except: pass

    async def _broadcast(self, msg: dict):
        """向所有连接客户端广播"""
        dead = set()
        for ws in self._ws_clients:
            try:
                await ws.send_json(msg)
            except: dead.add(ws)
        self._ws_clients -= dead

    async def _broadcast_positions(self):
        positions = await self.executor.get_positions()
        await self._broadcast({"type": "positions", "data": positions})
        balance = await self.executor.get_balance()
        await self._broadcast({"type": "balance", "data": balance})

    async def _price_loop(self):
        """价格定时推送（无 WS 时不查询，省 API）"""
        while True:
            await asyncio.sleep(2)
            if not self._ws_clients:
                continue
            try:
                prices = await self.executor.get_all_prices()
                await self._broadcast({"type": "prices", "data": prices})
            except: pass

    # ---- 生命周期 ----

    async def start(self, host: str = "0.0.0.0", port: int = 9090):
        await self.executor.start()
        self._runner = web.AppRunner(self.app)
        await self._runner.setup()
        site = web.TCPSite(self._runner, host, port)
        await site.start()
        self._price_task = asyncio.create_task(self._price_loop())
        logger.info(f"Binance 交易终端: http://{host}:{port}")
        logger.info(f"余额: {await self.executor.get_balance():.4f} USDC")
        # 保持运行
        try:
            await asyncio.Event().wait()
        except asyncio.CancelledError:
            pass
        finally:
            await self.stop()

    async def stop(self):
        if self._price_task:
            self._price_task.cancel()
        await self.executor.stop()
        if self._runner:
            await self._runner.cleanup()


def main():
    import argparse
    parser = argparse.ArgumentParser(description="Binance 交易终端后端")
    parser.add_argument("--port", type=int, default=9090, help="监听端口")
    args = parser.parse_args()

    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%H:%M:%S",
        stream=sys.stderr,
    )
    logger.info("=" * 50)
    logger.info("Binance 交易终端 后端 v3")
    logger.info("=" * 50)

    platform = TradingPlatform()
    try:
        asyncio.run(platform.start(port=args.port))
    except KeyboardInterrupt:
        logger.info("用户中断")


if __name__ == "__main__":
    main()
