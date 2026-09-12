#!/usr/bin/env python3
"""
价格跌幅监控 — 监听 Binance WS !miniTicker@arr
当前价格低于 1 分钟前快照价格 3% 时触发终端 + macOS 通知
"""
import asyncio
import json
import os
import time

import aiohttp
from aiohttp_socks import ProxyConnector

proxy_url = os.environ.get("ALL_PROXY") or "socks5://127.0.0.1:7897"
WS_URL = "wss://fstream.binance.com/market/stream?streams=!miniTicker@arr"

DROP_PCT = 3.0          # 跌幅阈值 %
WINDOW_SEC = 60         # 对比窗口（秒）
COOLDOWN_SEC = 30       # 同币种重复提醒冷却
HEARTBEAT_INTERVAL = 30 # 心跳日志间隔

prices = {}  # symbol -> {"price": float, "snap": float, "snap_ts": float, "alert_ts": float}


def notify(sym: str, pct: float, price: float, snap: float):
    """终端打印 + macOS 通知"""
    msg = (f"\033[91m📉 {sym} 跌 {abs(pct):.1f}%!\033[0m"
           f"  当前={price:.6f}  1分钟前={snap:.6f}")
    print(f"[{time.strftime('%H:%M:%S')}] {msg}", flush=True)
    # macOS 通知中心
    os.system(
        f'osascript -e \'display notification "{sym} 跌 {abs(pct):.1f}% | 当前={price:.6f}" '
        f'with title "⚠️ 价格异动"\' 2>/dev/null'
    )


async def ws_loop():
    connector = ProxyConnector.from_url(proxy_url)
    async with aiohttp.ClientSession(connector=connector) as session:
        while True:
            try:
                async with session.ws_connect(WS_URL, timeout=30) as ws:
                    print(f"[monitor] WS 已连接 | 阈值={DROP_PCT}% / {WINDOW_SEC}s 窗口 | "
                          f"冷却={COOLDOWN_SEC}s", flush=True)
                    print(f"[monitor] 等待中（无跌幅时不输出，每 30s 有心跳）...", flush=True)

                    async def keepalive():
                        while True:
                            await asyncio.sleep(20)
                            try:
                                await ws.ping()
                            except:
                                break
                    ka = asyncio.create_task(keepalive())

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

                            if sym not in prices:
                                prices[sym] = {
                                    "price": price,
                                    "snap": price,
                                    "snap_ts": now,
                                    "alert_ts": 0,
                                }
                            else:
                                p = prices[sym]
                                p["price"] = price

                                # 每 WINDOW_SEC 秒更新一次快照
                                if now - p["snap_ts"] >= WINDOW_SEC:
                                    p["snap"] = price
                                    p["snap_ts"] = now

                                # 检查跌幅
                                if p["snap"] > 0:
                                    drop = (price - p["snap"]) / p["snap"] * 100
                                    if drop <= -DROP_PCT and now - p["alert_ts"] >= COOLDOWN_SEC:
                                        p["alert_ts"] = now
                                        notify(sym, drop, price, p["snap"])

                    ka.cancel()

            except Exception as e:
                print(f"[monitor] WS 断开 ({e}), 3s 后重连", flush=True)
                await asyncio.sleep(3)


async def main():
    async def heartbeat():
        while True:
            await asyncio.sleep(HEARTBEAT_INTERVAL)
            total = len(prices)
            alerted = sum(1 for v in prices.values() if v["alert_ts"] > 0)
            print(f"[monitor] 监控中 | {total} 币种 | 已触发提醒: {alerted}", flush=True)

    await asyncio.gather(ws_loop(), heartbeat())


if __name__ == "__main__":
    try:
        asyncio.run(main())
    except KeyboardInterrupt:
        print("[monitor] 停止", flush=True)
