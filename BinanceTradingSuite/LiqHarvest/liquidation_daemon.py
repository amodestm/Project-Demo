#!/usr/bin/env python3
"""
强平瀑布 + 价格跌幅 守护进程
后台运行，持续监听两路 WS，写入状态文件供菜单栏读取。

启动: nohup python3 liquidation_daemon.py > /tmp/liq_daemon.log 2>&1 &
停止: kill $(pgrep -f liquidation_daemon)
"""
import asyncio
import json
import os
import sys
import time
from collections import defaultdict, deque

import aiohttp
from aiohttp_socks import ProxyConnector

# ── 路径（自动降级） ──
for _data_dir in [
    os.path.join(os.path.expanduser("~"), ".liq_harvest"),
    "/tmp",
    os.environ.get("TMPDIR", "/tmp"),
]:
    try:
        os.makedirs(_data_dir, exist_ok=True)
        testf = os.path.join(_data_dir, ".liq_write_test")
        with open(testf, "w") as _f:
            _f.write("1")
        os.remove(testf)
        DATA_DIR = _data_dir
        break
    except OSError:
        continue
else:
    DATA_DIR = "/tmp"  # last resort, will crash later
STATUS_FILE = os.path.join(DATA_DIR, "liquidation_bar.json")
PID_FILE = os.path.join(DATA_DIR, "liquidation_daemon.pid")

# ── WS ── 代理自动探测：优先环境变量，否则探测本地常见代理端口
_CANDIDATE_PROXIES = [
    "socks5://127.0.0.1:7890",  # 系统 SOCKS (当前生效)
    "socks5://127.0.0.1:7897",  # 旧 Clash
    "socks5://127.0.0.1:7688",  # VPN 07
]


def _detect_proxy() -> str:
    env = os.environ.get("ALL_PROXY") or os.environ.get("all_proxy")
    if env:
        return env.replace("socks5h://", "socks5://")
    import socket
    for cand in _CANDIDATE_PROXIES:
        host = cand.split("://")[1].split(":")[0]
        port = int(cand.rsplit(":", 1)[1])
        try:
            s = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
            s.settimeout(0.5)
            s.connect((host, port))
            s.close()
            return cand
        except Exception:
            continue
    return _CANDIDATE_PROXIES[0]


raw_proxy = _detect_proxy()
proxy_url = raw_proxy.replace("socks5h://", "socks5://")
LIQ_WS = "wss://fstream.binance.com/market/stream?streams=!forceOrder@arr"
PRICE_WS = "wss://fstream.binance.com/market/stream?streams=!miniTicker@arr"

# ── 强平状态 ──
recent_events = deque(maxlen=100)
cumulative = defaultdict(lambda: {"buy": 0, "sell": 0, "count": 0})
peak_60s = 0
waterfall_alerts = deque(maxlen=10)

# ── 价格跌幅状态 ──
DROP_LEVELS = [1.5, 2.0, 3.0]  # 多档位跌幅阈值
WINDOW_SEC = 60                 # 对比窗口（秒）
COOLDOWN_SEC = 30               # 同币种重复提醒冷却
_prices = {}                    # symbol -> {"price", "snap", "snap_ts", "high", "low", "alert_ts"}
price_drop_alerts = deque(maxlen=30)  # 最近 30 条跌幅告警
price_rise_alerts = deque(maxlen=30)  # 最近 30 条涨幅告警


# ============================================================
#  强平 WS
# ============================================================

async def ws_loop_liquidation():
    """!forceOrder@arr — 全市场强平事件"""
    global peak_60s
    connector = ProxyConnector.from_url(proxy_url)
    async with aiohttp.ClientSession(connector=connector) as session:
        while True:
            try:
                async with session.ws_connect(LIQ_WS, timeout=30,
                                              heartbeat=20.0) as ws:
                    print(f"[daemon] 强平 WS 已连接", flush=True)

                    async for msg in ws:
                        if msg.type != aiohttp.WSMsgType.TEXT:
                            break
                        data = json.loads(msg.data)
                        d = data.get("data", {})
                        o = d.get("o", {})
                        sym = o.get("s", "")
                        side = "BUY" if o.get("S") == "BUY" else "SELL"
                        qty = float(o.get("q", 0))
                        price = float(o.get("p", 0))
                        usdt = qty * price
                        ts = o.get("T", int(time.time() * 1000))

                        evt = {
                            "sym": sym, "side": side,
                            "qty": round(qty, 4), "price": round(price, 6),
                            "usdt": round(usdt, 1), "ts": ts,
                        }
                        recent_events.append(evt)
                        liq_side = "sell" if side == "SELL" else "buy"
                        cumulative[sym][liq_side] += usdt
                        cumulative[sym]["count"] += 1

                        if len(recent_events) % 5 == 0:
                            update_status_file()

            except Exception as e:
                print(f"[daemon] 强平 WS 断开 ({e}), 3s 后重连", flush=True)
                await asyncio.sleep(3)


# ============================================================
#  价格跌幅 WS
# ============================================================

async def ws_loop_price():
    """!miniTicker@arr — 全币种价格监控（3% 急跌检测）"""
    connector = ProxyConnector.from_url(proxy_url)
    async with aiohttp.ClientSession(connector=connector) as session:
        while True:
            try:
                async with session.ws_connect(PRICE_WS, timeout=30,
                                              heartbeat=20.0) as ws:
                    print(f"[daemon] 价格 WS 已连接 | 档位={DROP_LEVELS}", flush=True)

                    async for msg in ws:
                        if msg.type != aiohttp.WSMsgType.TEXT:
                            break
                        data = json.loads(msg.data)
                        tickers = data.get("data", [])
                        now = time.time()

                        for t in tickers:
                            sym = t.get("s", "")
                            price = float(t.get("c", 0))
                            if price == 0:
                                continue

                            if sym not in _prices:
                                _prices[sym] = {
                                    "price": price,
                                    "snap": price,    # 1 分钟前快照
                                    "snap_ts": now,
                                    "high": price,    # 当前分钟最高价
                                    "low": price,     # 当前分钟最低价
                                    "high_ts": now,
                                    "alert_ts": 0,
                                    "rise_alert_ts": 0,
                                }
                            else:
                                p = _prices[sym]
                                p["price"] = price
                                p["high"] = max(p["high"], price)
                                p["low"] = min(p["low"], price)

                                # 每 60s 更新快照 + 重置分钟最高/最低
                                if now - p["snap_ts"] >= WINDOW_SEC:
                                    p["snap"] = price
                                    p["high"] = price
                                    p["low"] = price
                                    p["snap_ts"] = now

                                # 检查跌幅（多档位）
                                if p["snap"] > 0 and now - p["alert_ts"] >= COOLDOWN_SEC:
                                    drop_snap = (price - p["snap"]) / p["snap"] * 100
                                    drop_high = (price - p["high"]) / p["high"] * 100 if p["high"] > 0 else 0

                                    alerts_this_tick = []

                                    # 检查是否从 1min 前快照急跌
                                    if drop_snap <= -DROP_LEVELS[0]:
                                        for dl in sorted(DROP_LEVELS, reverse=True):
                                            if drop_snap <= -dl:
                                                alerts_this_tick.append({
                                                    "source": "snap",
                                                    "drop_pct": round(drop_snap, 1),
                                                    "ref_price": round(p["snap"], 6),
                                                    "level": dl,
                                                })
                                                break

                                    # 检查是否从分钟最高点急跌（排除与 snap 重复）
                                    if drop_high <= -DROP_LEVELS[0] and not any(
                                        a["source"] == "snap" and abs(a["drop_pct"] - round(drop_high, 1)) < 0.5
                                        for a in alerts_this_tick
                                    ):
                                        for dl in sorted(DROP_LEVELS, reverse=True):
                                            if drop_high <= -dl:
                                                alerts_this_tick.append({
                                                    "source": "high",
                                                    "drop_pct": round(drop_high, 1),
                                                    "ref_price": round(p["high"], 6),
                                                    "level": dl,
                                                })
                                                break

                                    if alerts_this_tick:
                                        p["alert_ts"] = now
                                        for a in alerts_this_tick:
                                            alert = {
                                                "sym": sym,
                                                "drop_pct": a["drop_pct"],
                                                "price": round(price, 6),
                                                "ref_price": a["ref_price"],
                                                "time": time.strftime("%H:%M:%S"),
                                                "level": a["level"],
                                                "source": a["source"],
                                            }
                                            price_drop_alerts.append(alert)
                                            marker = "📉" if a["source"] == "snap" else "🔻"
                                            print(f"[daemon] {marker} {sym} 跌 {abs(a['drop_pct']):.1f}%≥{a['level']}%  "
                                                  f"{price} ← {'1min' if a['source'] == 'snap' else 'high'}={a['ref_price']}",
                                                  flush=True)

                                # ── 涨幅检测 ──
                                if now - p["rise_alert_ts"] >= COOLDOWN_SEC:
                                    rise_snap = (price - p["snap"]) / p["snap"] * 100
                                    rise_low = (price - p["low"]) / p["low"] * 100 if p["low"] > 0 else 0

                                    rise_alerts_this_tick = []

                                    # 检查是否从 1min 前快照急涨
                                    if rise_snap >= DROP_LEVELS[0]:
                                        for dl in sorted(DROP_LEVELS, reverse=True):
                                            if rise_snap >= dl:
                                                rise_alerts_this_tick.append({
                                                    "source": "snap",
                                                    "rise_pct": round(rise_snap, 1),
                                                    "ref_price": round(p["snap"], 6),
                                                    "level": dl,
                                                })
                                                break

                                    # 检查是否从分钟最低点急涨（排除与 snap 重复）
                                    if rise_low >= DROP_LEVELS[0] and not any(
                                        a["source"] == "snap" and abs(a["rise_pct"] - round(rise_low, 1)) < 0.5
                                        for a in rise_alerts_this_tick
                                    ):
                                        for dl in sorted(DROP_LEVELS, reverse=True):
                                            if rise_low >= dl:
                                                rise_alerts_this_tick.append({
                                                    "source": "low",
                                                    "rise_pct": round(rise_low, 1),
                                                    "ref_price": round(p["low"], 6),
                                                    "level": dl,
                                                })
                                                break

                                    if rise_alerts_this_tick:
                                        p["rise_alert_ts"] = now
                                        for a in rise_alerts_this_tick:
                                            alert = {
                                                "sym": sym,
                                                "rise_pct": a["rise_pct"],
                                                "price": round(price, 6),
                                                "ref_price": a["ref_price"],
                                                "time": time.strftime("%H:%M:%S"),
                                                "level": a["level"],
                                                "source": a["source"],
                                            }
                                            price_rise_alerts.append(alert)
                                            marker = "📈" if a["source"] == "snap" else "⬆️"
                                            print(f"[daemon] {marker} {sym} 涨 {a['rise_pct']:.1f}%≥{a['level']}%  "
                                                  f"{price} → {'1min' if a['source'] == 'snap' else 'low'}={a['ref_price']}",
                                                  flush=True)

            except Exception as e:
                print(f"[daemon] 价格 WS 断开 ({e}), 3s 后重连", flush=True)
                await asyncio.sleep(3)


# ============================================================
#  状态文件
# ============================================================

def update_status_file():
    """生成状态 JSON → 菜单栏读取"""
    try:
        now = time.time()
        cutoff_60s = now * 1000 - 60_000
        cutoff_10s = now * 1000 - 10_000

        # ── 强平 60s 统计 ──
        events_60s = [e for e in recent_events if e["ts"] > cutoff_60s]
        total_60s = sum(e["usdt"] for e in events_60s)
        sell_60s = sum(e["usdt"] for e in events_60s if e["side"] == "SELL")
        buy_60s = sum(e["usdt"] for e in events_60s if e["side"] == "BUY")
        count_60s = len(events_60s)

        # ── 10s 瀑布检测 ──
        last_10s = sum(e["usdt"] for e in recent_events if e["ts"] > cutoff_10s)
        prev_10s = sum(e["usdt"] for e in recent_events
                       if now * 1000 - 20_000 < e["ts"] <= now * 1000 - 10_000)
        waterfall = prev_10s > 0 and last_10s > prev_10s * 2

        if waterfall:
            top_coin = ""
            top_val = 0
            coin_totals = defaultdict(float)
            for e in recent_events:
                if e["ts"] > cutoff_10s:
                    coin_totals[e["sym"]] += e["usdt"]
            for sym, val in coin_totals.items():
                if val > top_val:
                    top_val = val
                    top_coin = sym.replace("USDT", "")

            waterfall_alerts.append({
                "time": time.strftime("%H:%M:%S"),
                "last_10s": round(last_10s),
                "prev_10s": round(prev_10s),
                "ratio": round(last_10s / prev_10s, 1),
                "top_sym": top_coin,
                "top_val": round(top_val, 1),
            })

        # ── TOP 10 强平币种 ──
        top = sorted(cumulative.items(),
                     key=lambda x: x[1]["sell"] + x[1]["buy"],
                     reverse=True)[:10]
        top_list = [{"sym": s, **d} for s, d in top]

        # ── 最新 30 笔强平 ──
        latest = list(recent_events)[-30:]

        status = {
            "total_60s": round(total_60s, 1),
            "sell_60s": round(sell_60s, 1),
            "buy_60s": round(buy_60s, 1),
            "count_60s": count_60s,
            "waterfall": waterfall,
            "waterfall_alerts": list(waterfall_alerts),
            "top": top_list,
            "latest": latest,
            "price_drops": list(price_drop_alerts),
            "price_rises": list(price_rise_alerts),
            "updated": time.strftime("%H:%M:%S"),
        }

        with open(STATUS_FILE, "w") as f:
            json.dump(status, f)
        # 验证文件真的写入了
        if os.path.exists(STATUS_FILE):
            sz = os.path.getsize(STATUS_FILE)
            if sz == 0:
                print(f"[daemon] ⚠️ 状态文件是空文件!", flush=True)
        else:
            print(f"[daemon] ⚠️ 刚写完但文件不存在! path={STATUS_FILE}", flush=True)
    except Exception as e:
        print(f"[daemon] status file write error: {e}", flush=True)


# ============================================================
#  主循环
# ============================================================

async def main():
    while True:
        try:
            # 每次循环重写 PID
            with open(PID_FILE, "w") as f:
                f.write(str(os.getpid()))
            print(f"[daemon] PID={os.getpid()} | 状态文件={STATUS_FILE}", flush=True)

            # 启动时立即写入一次空状态（确保菜单栏能读取）
            update_status_file()
            # 校验
            _es = os.path.exists(STATUS_FILE)
            _sz = os.path.getsize(STATUS_FILE) if _es else 0
            print(f"[daemon] 首次写入: exists={_es} size={_sz} path={STATUS_FILE}", flush=True)

            async def periodic_flush():
                while True:
                    await asyncio.sleep(0.5)
                    update_status_file()

            # 独立创建任务，某个挂了不影响其他
            tasks = [
                asyncio.create_task(ws_loop_liquidation()),
                asyncio.create_task(ws_loop_price()),
                asyncio.create_task(periodic_flush()),
            ]
            print(f"[daemon] 3个任务已创建，开始运行", flush=True)

            done, pending = await asyncio.wait(tasks, return_when=asyncio.FIRST_EXCEPTION)
            for t in done:
                try:
                    e = t.exception()
                    if e:
                        print(f"[daemon] 任务异常: {e}", flush=True)
                except asyncio.CancelledError:
                    pass
            print(f"[daemon] 有任务退出，3s 后重启", flush=True)
            for t in pending:
                t.cancel()
        except Exception as e:
            print(f"[daemon] 主循环异常: {e}", flush=True)
        await asyncio.sleep(3)


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("[daemon] 停止", flush=True)
        for p in (PID_FILE, STATUS_FILE):
            if os.path.exists(p):
                os.remove(p)
        for p in (PID_FILE, STATUS_FILE):
            if os.path.exists(p):
                os.remove(p)
