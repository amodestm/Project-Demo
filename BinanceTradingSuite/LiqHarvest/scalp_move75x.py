#!/usr/bin/env python3
"""
MOVEUSDT 75x 剥头皮 — 多空双开

策略:
  每侧无持仓时立即市价开 (1u 保证金 × 75x = $75 名义)
  开仓成交后秒挂限价止盈单 (Maker 返佣, 省手续费)
  无止损
  全速循环，由 REST 响应时间自然控频

下单方式: 走 PlatformExecutor（标准 fapi，与快速下单程序一致）
"""
import asyncio
import json
import logging
import os
import sys
import time

import aiohttp
from aiohttp_socks import ProxyConnector

# 自动从 run.sh 加载 API Key（跟 scalp_harvester.py 一致）
if not os.environ.get("BINANCE_API_KEY"):
    _sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "run.sh")
    if os.path.exists(_sh):
        for _line in open(_sh):
            if _line.startswith("export BINANCE_"):
                _key, _val = _line.strip().replace("export ", "").split("=", 1)
                _val = _val.strip("\"'")
                os.environ[_key] = _val

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trading_platform.executor_client import PlatformExecutor

# ── 参数 ──
SYMBOL = "MOVEUSDT"
LEVERAGE = 75
MARGIN_PER_ORDER = 1.0      # 每次开仓保证金 USDT
ORDER_NOTIONAL = MARGIN_PER_ORDER * LEVERAGE  # 名义价值 = 75 USDT
TP_MARGIN_PCT = 10          # 保证金止盈 %

# 日志
logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(name)s] %(message)s", datefmt="%H:%M:%S")
logger = logging.getLogger("scalp75")


class ScalpMove75x:
    """75x 剥头皮引擎"""

    def __init__(self):
        self.executor = PlatformExecutor()
        self._running = False
        self.mid_price = 0.0
        self._last_open = 0.0
        self._auth_failed = False
        self._pos_open_time = {}   # side -> open_timestamp

    # ── 运行入口 ──

    async def run(self):
        proxy_url = os.environ.get("ALL_PROXY") or "socks5://127.0.0.1:7897"
        try:
            connector = ProxyConnector.from_url(proxy_url)
            self.executor._session = aiohttp.ClientSession(connector=connector)
            logger.info(f"✅ REST 走代理: {proxy_url}")
        except Exception:
            self.executor._session = aiohttp.ClientSession()
            logger.info("✅ REST 直连")

        await self.executor._load_precisions()
        logger.info(f"📐 精度已加载: {len(self.executor._tick_size)} 币种")

        # 设杠杆 75x
        result = await self.executor._signed_post("/fapi/v1/leverage", {
            "symbol": SYMBOL, "leverage": LEVERAGE,
        })
        if result.get("leverage") == LEVERAGE:
            logger.info("🔧 杠杆: %dx", LEVERAGE)
        else:
            logger.warning("⚠️ 杠杆设置可能失败: %s", str(result)[:100])

        self._running = True
        ws_task = asyncio.create_task(self._ws_bookticker())
        logger.info("🚀 开始全速循环 | %s %dx 多空双开 止盈%s%%",
                    SYMBOL, LEVERAGE, TP_MARGIN_PCT)

        try:
            await self._main_loop()
        except KeyboardInterrupt:
            logger.info("⏹ 用户中断")
        except Exception as e:
            logger.exception("❌ 异常: %s", e)
        finally:
            self._running = False
            ws_task.cancel()
            try:
                await ws_task
            except Exception:
                pass
            await self._cancel_all_orders()
            await self.executor.stop()
            logger.info("🏁 已停止 (挂单已撤)")

    # ── WS 实时价格 ──

    async def _ws_bookticker(self):
        ws_url = "wss://fstream.binance.com/stream?streams=!bookTicker"
        while self._running:
            try:
                connector = ProxyConnector.from_url(
                    os.environ.get("ALL_PROXY") or "socks5://127.0.0.1:7897"
                )
                async with aiohttp.ClientSession(connector=connector) as session:
                    async with session.ws_connect(ws_url, timeout=30, heartbeat=20.0) as ws:
                        logger.info("✅ WS 已连接 (!bookTicker)")
                        async for msg in ws:
                            if msg.type != aiohttp.WSMsgType.TEXT:
                                break
                            data = json.loads(msg.data)
                            d = data.get("data", {})
                            if d.get("s") == SYMBOL:
                                bid = float(d.get("b", 0))
                                ask = float(d.get("a", 0))
                                if bid > 0 and ask > 0:
                                    self.mid_price = (bid + ask) / 2
            except asyncio.CancelledError:
                break
            except Exception as e:
                if self._running:
                    logger.warning("⚠️ WS 断开 (%s), 3s 重连", str(e)[:60])
                    await asyncio.sleep(3)

    # ── 撤所有挂单 ──

    async def _cancel_all_orders(self):
        # 撤普通挂单
        orders = await self.executor._rest_open_orders(SYMBOL)
        for o in orders:
            oid = o.get("order_id")
            if oid:
                await self.executor._rest_cancel_order(SYMBOL, oid)
                logger.info("🗑️ 撤单: %s #%s", o.get("side"), oid)
        # 撤条件单（止盈 TP）
        algo = await self.executor._rest_open_conditional_orders(SYMBOL)
        for a in algo:
            sid = a.get("strategy_id")
            if sid:
                await self.executor._rest_cancel_conditional_order(SYMBOL, sid)
                logger.info("🗑️ 撤条件单: %s #%s", a.get("side"), sid)

    # ── 挂限价止盈单 ──

    async def _place_tp_limit(self, side: str, qty: float, entry_price: float):
        """开仓后直接挂限价止盈单"""
        if side == "LONG":
            tp_px = entry_price * (1 + TP_MARGIN_PCT / 100 / LEVERAGE)
            tp_side = "SELL"
        else:
            tp_px = entry_price * (1 - TP_MARGIN_PCT / 100 / LEVERAGE)
            tp_side = "BUY"
        result = await self.executor.place_order(
            SYMBOL, tp_side, qty, "LIMIT",
            price=tp_px, position_side=side,
        )
        oid = result.get("orderId")
        if oid:
            logger.info("🎯 止盈限价单已挂: %s %s @ %.6f (#%s)",
                        tp_side, self.executor._round_qty(SYMBOL, qty), tp_px, oid)
        else:
            error = result.get("error", str(result)[:200])
            logger.error("❌ 止盈限价单失败: %s", error)
        return oid

    # ── 主循环 ──

    async def _main_loop(self):
        while self._running:
            try:
                # 1. 获取持仓 → 标准 endpoint
                result = await self.executor._signed_get("/fapi/v2/positionRisk")
                if isinstance(result, dict) and result.get("code") == -2015:
                    if not self._auth_failed:
                        logger.error("❌ API Key 鉴权失败 (IP 白名单)")
                        self._auth_failed = True
                    await asyncio.sleep(10)
                    continue

                positions = {}
                if isinstance(result, list):
                    for p in result:
                        amt = float(p.get("positionAmt", 0))
                        if abs(amt) < 0.001:
                            continue
                        side = p.get("positionSide", "BOTH")
                        positions[side] = {
                            "amt": abs(amt),
                            "entry": float(p.get("entryPrice", 0)),
                            "upnl": float(p.get("unRealizedProfit", 0)),
                        }
                        # 已存在的仓位，本地没记录开仓时间 → 设为当前时间避免立即超时
                        if side not in self._pos_open_time:
                            self._pos_open_time[side] = time.time()

                now = time.time()

                # 2. 30s 超时：挂了 30s 没止盈 → 市价平
                for pside, pos in list(positions.items()):
                    ot = self._pos_open_time.get(pside)
                    if ot and now - ot > 30:
                        logger.info("⏰ 超时30s %s | 市价平 %.6f @ %.6f",
                                    pside, pos["amt"], self.mid_price)
                        close_side = "SELL" if pside == "LONG" else "BUY"
                        r = await self.executor.place_order(
                            SYMBOL, close_side, pos["amt"], "MARKET",
                            position_side=pside,
                        )
                        if r.get("orderId"):
                            logger.info("✅ 超时平仓成功 %s", pside)
                        else:
                            logger.warning("⚠️ 超时平仓失败: %s", str(r)[:80])
                        self._pos_open_time.pop(pside, None)

                # 3. 防抖
                if now - self._last_open < 0.5:
                    await asyncio.sleep(0.05)
                    continue

                # 4. 开仓（市场单返回可能 status=NEW，用 origQty + WS 价挂止盈）
                need_open = False

                if "LONG" not in positions and self.mid_price > 0:
                    need_open = True
                    qty = ORDER_NOTIONAL / self.mid_price
                    logger.info("📈 开多 %.6f MOVE @ %.6f", qty, self.mid_price)
                    r = await self.executor.place_order(
                        SYMBOL, "BUY", qty, "MARKET",
                        position_side="LONG", leverage=LEVERAGE,
                    )
                    oid = r.get("orderId")
                    if oid:
                        filled = float(r.get("origQty", qty))
                        self._pos_open_time["LONG"] = now
                        logger.info("✅ 开多订单已提交 %s @ ~%.6f", r.get("origQty"), self.mid_price)
                        await self._place_tp_limit("LONG", filled, self.mid_price)
                    else:
                        logger.warning("⚠️ 开多失败: %s", str(r)[:200])

                if "SHORT" not in positions and self.mid_price > 0:
                    need_open = True
                    qty = ORDER_NOTIONAL / self.mid_price
                    logger.info("📉 开空 %.6f MOVE @ %.6f", qty, self.mid_price)
                    r = await self.executor.place_order(
                        SYMBOL, "SELL", qty, "MARKET",
                        position_side="SHORT", leverage=LEVERAGE,
                    )
                    oid = r.get("orderId")
                    if oid:
                        filled = float(r.get("origQty", qty))
                        self._pos_open_time["SHORT"] = now
                        logger.info("✅ 开空订单已提交 %s @ ~%.6f", r.get("origQty"), self.mid_price)
                        await self._place_tp_limit("SHORT", filled, self.mid_price)
                    else:
                        logger.warning("⚠️ 开空失败: %s", str(r)[:200])

                if need_open:
                    self._last_open = now

            except Exception as e:
                logger.warning("⚠️ 循环异常: %s", str(e)[:100])
                await asyncio.sleep(0.5)


if __name__ == "__main__":
    engine = ScalpMove75x()
    try:
        asyncio.run(engine.run())
    except KeyboardInterrupt:
        logger.info("⏹ 退出")
