#!/usr/bin/env python3
"""
强平瀑布监控 — 实时观察全市场强平事件
WS: !forceOrder@arr (全流, 无需订阅单个币种)

输出: 表格化强平事件 + 累计统计
"""

import asyncio
import json
import os
import time
from collections import defaultdict, deque

import aiohttp
from aiohttp_socks import ProxyConnector

proxy = os.environ.get("ALL_PROXY") or "socks5://127.0.0.1:7897"
WS_URL = "wss://fstream.binance.com/stream?streams=!forceOrder@arr"

# 最近 N 笔强平
MAX_RECENT = 50
recent = deque(maxlen=MAX_RECENT)
# 按币种累计
cumulative = defaultdict(lambda: {"buy": 0, "sell": 0, "count": 0})
# 每秒清算量统计（瀑布检测）
per_second = deque(maxlen=60)

async def run():
    connector = ProxyConnector.from_url(proxy)
    async with aiohttp.ClientSession(connector=connector) as session:
        async with session.ws_connect(WS_URL, timeout=30) as ws:
            print(f"{'─'*90}")
            print(f"  🔥 强平瀑布监控 | {time.strftime('%Y-%m-%d %H:%M:%S')}")
            print(f"{'─'*90}")
            print(f"  {'时间':>12s} {'币种':>12s} {'方向':>6s} {'数量':>12s} {'价格':>14s} {'金额USDT':>12s}")
            print(f"{'─'*90}")
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
                t_str = time.strftime("%H:%M:%S", time.localtime(ts / 1000))

                # 记录
                evt = {"sym": sym, "side": side, "qty": qty, "price": price, "usdt": usdt, "ts": ts}
                recent.append(evt)
                liq_side = "sell" if side == "SELL" else "buy"
                cumulative[sym][liq_side] += usdt
                cumulative[sym]["count"] += 1
                per_second.append((ts, usdt))

                # 输出
                side_c = "\033[91mSELL\033[0m" if side == "SELL" else "\033[92mBUY \033[0m"
                print(f"  {t_str:>12s} {sym:>12s} {side_c} {qty:>12.2f} {price:>14.6f} {usdt:>12.0f}")

                # 每 10 笔输出一次汇总
                if len(recent) % 10 == 0:
                    await print_summary()

async def print_summary():
    """输出最近 60 秒汇总 + 前 10 热力图"""
    print(f"\n{'─'*90}")

    # 最近 60s 清算总量
    cutoff = time.time() * 1000 - 60_000
    recent_60s = [e for e in recent if e["ts"] > cutoff]
    total_60s = sum(e["usdt"] for e in recent_60s)
    sell_60s = sum(e["usdt"] for e in recent_60s if e["side"] == "SELL")
    buy_60s = sum(e["usdt"] for e in recent_60s if e["side"] == "BUY")

    print(f"  📊 最近60s: 总计 {total_60s:,.0f}U | SELL {sell_60s:,.0f}U | BUY {buy_60s:,.0f}U | {len(recent_60s)} 笔")

    # 瀑布检测：连续 10s 清算加速
    now = time.time() * 1000
    last_10s = sum(e["usdt"] for e in recent if e["ts"] > now - 10_000)
    prev_10s = sum(e["usdt"] for e in recent if now - 20_000 < e["ts"] <= now - 10_000)
    if prev_10s > 0 and last_10s > prev_10s * 2:
        print(f"  ⚠️ \033[93m瀑布信号！最近10s清算量 {last_10s:,.0f}U 是前10s {prev_10s:,.0f}U 的 {last_10s/prev_10s:.1f}x\033[0m")

    # 按币种累计 TOP 10
    top = sorted(cumulative.items(), key=lambda x: x[1]["sell"] + x[1]["buy"], reverse=True)[:10]
    print(f"  {'币种':>12s} {'SELL累计':>12s} {'BUY累计':>12s} {'总额':>14s} {'笔数':>6s}")
    print(f"  {'─'*56}")
    for sym, data in top:
        total = data["sell"] + data["buy"]
        print(f"  {sym:>12s} {data['sell']:>12,.0f} {data['buy']:>12,.0f} {total:>14,.0f} {data['count']:>6d}")
    print(f"{'─'*90}\n")

if __name__ == "__main__":
    try:
        asyncio.run(run())
    except KeyboardInterrupt:
        print("\n监控已停止")
