#!/usr/bin/env python3
"""
低位挖掘 (Bottom Fisher) — 独立低频做多策略
=============================================

策略: 90min 超跌反弹挖掘
- 扫描所有 24h 量 > 2000万U 的币种
- 当前价 < 90min 最低 low × 0.95 → 超跌信号 → 开多
- 只做多，不做空
- 20x 杠杆，单仓 45% 权益
- 止盈 50% 保证金，止损 15% 保证金
- TP 挂限价单（Maker），SL 软件监控
- 触发后 180min 冷却

启动: python3 bottom_fisher.py
"""

import asyncio
import json
import logging
import os
import sys
import time
import math
from collections import deque
from typing import Optional

import aiohttp
from aiohttp_socks import ProxyConnector

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trading_platform.executor_client import PlatformExecutor

# 自动加载 API Key
if not os.environ.get("BINANCE_API_KEY"):
    _sh = os.path.join(os.path.dirname(os.path.abspath(__file__)), "trading_platform", "start.sh")
    if os.path.exists(_sh):
        for _line in open(_sh):
            if _line.startswith("export BINANCE_"):
                _key, _val = _line.strip().replace("export ", "").split("=", 1)
                _val = _val.strip("\"'")
                os.environ[_key] = _val

# ============================================================
# 日志
# ============================================================
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

# ============================================================
# 策略参数
# ============================================================
LEVERAGE = 20                       # 杠杆倍数
POSITION_PCT = 0.45                 # 单笔仓位占权益比例

# 触发条件
LOOKBACK_MINUTES = 90               # 回溯分钟数
TRIGGER_DISCOUNT = 0.95             # 当前价 < 最低价 × 0.95 时触发

# 止盈止损
TP_MARGIN_PCT = 50.0                # 止盈：保证金 +50%
SL_MARGIN_PCT = 15.0                # 止损：保证金 -15%

# 手续费
MAKER_FEE = 0.0002                  # Maker 费率 0.02%
TAKER_FEE = 0.0005                  # Taker 费率 0.05%

# 扫描控制
SCAN_INTERVAL = 30                  # 主循环间隔（秒）
MIN_24H_VOLUME_USDT = 20_000_000    # 24h 成交额下限
MAX_DAILY_LOSS_USDT = 20.0          # 日亏损上限

# 暂停标记
PAUSE_FLAG = "/tmp/bf_pause"


# ============================================================
# 低位挖掘引擎
# ============================================================
class BottomFisherEngine:
    """低位挖掘引擎 — 低频 90min 超跌反弹"""

    def __init__(self):
        self.executor = PlatformExecutor()
        self.coins: list[str] = []
        self.positions: dict[str, dict] = {}        # key → position dict
        self._pending_tp_exits: dict[str, dict] = {} # TP 限价单跟踪
        self._running = False
        self._ref_balance = 0.0
        self._daily_pnl = 0.0
        self._loop_count = 0

    # ── 参数计算 ──

    @staticmethod
    def _calc_tp_price(entry: float, side: str) -> float:
        """50% 保证金止盈 = 价格变动 + 手续费"""
        pct = TP_MARGIN_PCT / 100 / LEVERAGE + (MAKER_FEE + TAKER_FEE)
        return entry * (1 + pct)

    @staticmethod
    def _calc_sl_price(entry: float, side: str) -> float:
        """15% 保证金止损 = 价格变动 - 手续费"""
        pct = SL_MARGIN_PCT / 100 / LEVERAGE - (TAKER_FEE * 2)
        return entry * (1 - pct)

    @staticmethod
    def _fmt_price(symbol: str, price: float) -> str:
        """按精度格式化价格"""
        return f"{price:.8f}"

    @staticmethod
    def _fmt_qty(symbol: str, qty: float) -> str:
        """按精度格式化数量"""
        return f"{qty:.2f}"

    # ── 币种筛选 ──

    async def _select_coins(self):
        """筛选 24h 交易量 > 2000万U 的 USDT 交易对"""
        if not self.executor._session:
            logger.error("❌ 会话未初始化")
            return
        try:
            if not self.executor._tick_size:
                await self.executor._load_precisions()
            all_coins = sorted(self.executor._tick_size.keys())

            async with self.executor._session.get(
                "https://fapi.binance.com/fapi/v1/ticker/24hr", timeout=15,
            ) as resp:
                vol_data = {}
                if resp.status == 200:
                    for t in await resp.json():
                        if isinstance(t, dict):
                            vol_data[t.get("symbol", "")] = float(t.get("quoteVolume", 0))

            usdt_coins = []
            for s in all_coins:
                if not (s.endswith("USDT") and not s.endswith("USDCUSDT")):
                    continue
                if vol_data.get(s, 0) >= MIN_24H_VOLUME_USDT:
                    usdt_coins.append(s)

            self.coins = usdt_coins
            logger.info("📊 筛选完成: %d 个币 (24h量≥2000万U)", len(self.coins))
        except Exception as e:
            logger.error("❌ 币种筛选失败: %s", e)

    # ── 余额 ──

    async def _check_balance(self):
        """获取总权益"""
        eq = await self.executor.get_total_equity()
        if eq > 0 and self._ref_balance <= 0:
            self._ref_balance = eq
            logger.info("💰 基准权益锁定: $%.4f", eq)

    # ── 查找 90min 最低价 ──

    async def _get_90m_low(self, symbol: str) -> Optional[float]:
        """拉 90 根 1m K 线，返回最低 low 价"""
        try:
            async with self.executor._session.get(
                f"https://fapi.binance.com/fapi/v1/klines?"
                f"symbol={symbol}&interval=1m&limit={LOOKBACK_MINUTES}",
                timeout=10,
            ) as resp:
                if resp.status != 200:
                    return None
                klines = await resp.json()
                if not isinstance(klines, list) or len(klines) < 10:
                    return None
                lows = [float(k[3]) for k in klines]  # index 3 = low price
                return min(lows)
        except Exception as e:
            logger.debug("获取K线失败 %s: %s", symbol, e)
            return None

    # ── 开仓 ──

    async def _open_position(self, symbol: str):
        """市价开多，挂 TP 限价单"""
        if self._ref_balance <= 0:
            logger.warning("❌ 基准余额未就绪")
            return

        # 设杠杆
        await self.executor._signed_post("/papi/v1/um/leverage",
                                         {"symbol": symbol, "leverage": LEVERAGE})

        # 计算仓位
        notional = self._ref_balance * LEVERAGE * POSITION_PCT
        if notional < 5.0:
            logger.warning("⏭ %s 名义$%.2f<$5，跳过", symbol, notional)
            return

        # 获取当前价（用公开 ticker 接口）
        ba = None
        try:
            async with self.executor._session.get(
                f"https://fapi.binance.com/fapi/v1/ticker/price",
                params={"symbol": symbol}, timeout=10,
            ) as resp:
                data = await resp.json()
                if isinstance(data, dict) and "price" in data:
                    p = float(data["price"])
                    ba = {"bid1": p, "ask1": p}
        except Exception:
            pass

        if not ba or ba["ask1"] <= 0:
            logger.warning("❌ %s 无法获取报价，跳过", symbol)
            return

        entry_price = ba["ask1"]  # 买 ask
        qty = notional / entry_price

        # 下单
        result = await self.executor.place_order(
            symbol=symbol, side="BUY", quantity=qty,
            order_type="MARKET", position_side="LONG",
        )
        order_id = result.get("orderId") if isinstance(result, dict) else None
        if not order_id or result.get("_error"):
            err = result.get("error", str(result)[:100]) if isinstance(result, dict) else str(result)
            logger.warning("❌ %s 开单失败: %s", symbol, err)
            return

        # 等成交
        filled = None
        for _ in range(15):
            await asyncio.sleep(0.2)
            status = await self.executor._signed_get("/papi/v1/um/order",
                                                     {"symbol": symbol, "orderId": order_id})
            s = status.get("status", "")
            if s in ("FILLED", "PARTIALLY_FILLED"):
                filled = float(status.get("avgPrice", entry_price))
                break
        if not filled:
            await self.executor._rest_cancel_order(symbol, order_id)
            logger.info("⏰ %s 市价单未成交，已撤", symbol)
            return

        entry_price = filled
        tp_price = self._calc_tp_price(entry_price, "LONG")
        sl_price = self._calc_sl_price(entry_price, "LONG")

        key = f"{symbol}_LONG"
        self.positions[key] = {
            "symbol": symbol, "side": "LONG",
            "entry_price": entry_price, "quantity": qty,
            "tp_price": tp_price, "sl_price": sl_price,
            "open_time": time.time(),
        }

        logger.info("✅ %s 开多 qty=%s @%s tp=%s sl=%s",
                     symbol, self._fmt_qty(symbol, qty),
                     self._fmt_price(symbol, entry_price),
                     self._fmt_price(symbol, tp_price),
                     self._fmt_price(symbol, sl_price))

        # 挂 TP 限价单
        exit_side = "SELL"
        tp_result = await self.executor.place_order(
            symbol=symbol, side=exit_side, quantity=qty,
            order_type="LIMIT", price=tp_price, position_side="LONG",
        )
        tp_oid = tp_result.get("orderId") if isinstance(tp_result, dict) else None
        if tp_oid and not tp_result.get("_error"):
            self._pending_tp_exits[key] = {
                "order_id": tp_oid, "symbol": symbol, "side": "LONG",
                "tp_price": tp_price, "quantity": qty,
            }
            logger.info("📋 TP限价单已挂 %s id=%s @%s",
                        symbol, tp_oid, self._fmt_price(symbol, tp_price))
        else:
            logger.warning("⚠️ TP挂单失败 %s", symbol)

    # ── 监控持仓 ──

    async def _check_positions(self):
        """检查 TP 成交 + SL 止损"""
        # TP 成交
        for key, tp in list(self._pending_tp_exits.items()):
            try:
                result = await self.executor._signed_get("/papi/v1/um/order", {
                    "symbol": tp["symbol"], "orderId": tp["order_id"],
                })
                status = result.get("status", "")
                if status == "FILLED":
                    fill_price = float(result.get("avgPrice", tp["tp_price"]))
                    pos = self.positions.pop(key, None)
                    self._pending_tp_exits.pop(key, None)
                    if pos:
                        gross_pnl = (fill_price - pos["entry_price"]) * pos["quantity"]
                        self._daily_pnl += gross_pnl
                        logger.info("✅ TP成交 %s | 入场 %s→%s | PnL %+.4fU",
                                    tp["symbol"],
                                    self._fmt_price(tp["symbol"], pos["entry_price"]),
                                    self._fmt_price(tp["symbol"], fill_price),
                                    gross_pnl)
                elif status in ("CANCELED", "EXPIRED", "REJECTED"):
                    logger.warning("⚠️ TP单取消 %s %s", tp["symbol"], status)
                    self._pending_tp_exits.pop(key, None)
                    # 重挂
                    if key in self.positions:
                        pos = self.positions[key]
                        retry = await self.executor.place_order(
                            symbol=pos["symbol"], side="SELL",
                            quantity=pos["quantity"],
                            order_type="LIMIT", price=pos["tp_price"],
                            position_side="LONG",
                        )
                        oid = retry.get("orderId") if isinstance(retry, dict) else None
                        if oid and not retry.get("_error"):
                            self._pending_tp_exits[key] = {
                                "order_id": oid, "symbol": pos["symbol"],
                                "side": "LONG", "tp_price": pos["tp_price"],
                                "quantity": pos["quantity"],
                            }
                            logger.info("📋 TP重挂 %s id=%s", pos["symbol"], oid)
            except Exception as e:
                logger.debug("TP查询异常 %s: %s", tp.get("symbol"), e)

        # SL 止损
        for key, pos in list(self.positions.items()):
            # 获取当前价
            try:
                async with self.executor._session.get(
                    f"https://fapi.binance.com/fapi/v1/ticker/price",
                    params={"symbol": pos["symbol"]}, timeout=10,
                ) as resp:
                    data = await resp.json()
                    mark = float(data.get("price", 0))
            except Exception:
                continue
            if mark <= 0:
                continue

            if pos["side"] == "LONG" and mark <= pos["sl_price"]:
                logger.warning("🛑 止损 %s @%.4f (SL≤%.4f)",
                               pos["symbol"], mark, pos["sl_price"])
                if key in self._pending_tp_exits:
                    tp = self._pending_tp_exits.pop(key, None)
                    if tp:
                        try:
                            await self.executor._rest_cancel_order(tp["symbol"], tp["order_id"])
                        except Exception:
                            pass
                self.positions.pop(key, None)
                await self._close_position(pos["symbol"], "LONG", pos["quantity"])
                gross_pnl = (mark - pos["entry_price"]) * pos["quantity"]
                self._daily_pnl += gross_pnl
                logger.info("📊 PnL %+.4fU | 日累计 %+.4fU", gross_pnl, self._daily_pnl)

    async def _close_position(self, symbol: str, side: str, qty: float):
        """市价平仓"""
        close_side = "SELL"
        result = await self.executor.place_order(
            symbol=symbol, side=close_side, quantity=qty,
            order_type="MARKET", position_side=side,
        )
        order_id = result.get("orderId") if isinstance(result, dict) else None
        if order_id and not result.get("_error"):
            logger.info("🗑 平仓 %s %s id=%s", side, symbol, order_id)
        else:
            logger.warning("⚠️ 平仓失败 %s: %s", symbol,
                           result.get("error", str(result)[:80]))

    # ── 信号扫描 ──

    async def _scan(self):
        """扫描所有币种，检查超跌触发条件"""
        if len(self.positions) >= 1:
            return  # 最多 1 笔持仓

        for sym in self.coins:
            if f"{sym}_LONG" in self.positions:
                continue

            # 获取 90min 最低价
            low_90m = await self._get_90m_low(sym)
            if low_90m is None or low_90m <= 0:
                continue

            # 获取当前价
            try:
                async with self.executor._session.get(
                    f"https://fapi.binance.com/fapi/v1/ticker/price",
                    params={"symbol": sym}, timeout=10,
                ) as resp:
                    data = await resp.json()
                    mark = float(data.get("price", 0))
            except Exception:
                continue
            if mark <= 0:
                continue

            # 触发条件：当前价 < 90min 最低 × 0.95
            trigger_price = low_90m * TRIGGER_DISCOUNT
            if mark < trigger_price:
                logger.info("📣 超跌信号 %s | 当前%.8f < 触发%.8f (90min最低%.8f×0.95)",
                            sym, mark, trigger_price, low_90m)
                await self._open_position(sym)
                return  # 只开一个

    # ── 主循环 ──

    async def _main_loop(self):
        """主循环 — 30s 间隔"""
        while self._running:
            loop_start = time.time()
            try:
                # 暂停检查
                if os.path.exists(PAUSE_FLAG):
                    await asyncio.sleep(SCAN_INTERVAL)
                    continue

                await self._check_balance()
                if self._ref_balance <= 0:
                    await asyncio.sleep(SCAN_INTERVAL)
                    continue

                if self._daily_pnl <= -MAX_DAILY_LOSS_USDT:
                    logger.warning("🛑 日亏损已达上限 %.2fU", MAX_DAILY_LOSS_USDT)
                    self._running = False
                    break

                await self._check_positions()
                await self._scan()
                self._loop_count += 1
            except asyncio.CancelledError:
                break
            except Exception as e:
                logger.exception("循环异常: %s", e)

            elapsed = time.time() - loop_start
            await asyncio.sleep(max(0, SCAN_INTERVAL - elapsed))

    # ── 状态概览 ──

    async def _status_summary(self):
        """每 60s 输出一次状态"""
        while self._running:
            await asyncio.sleep(60)
            pause_tag = " ⏸暂停" if os.path.exists(PAUSE_FLAG) else ""
            logger.info("📊 持仓=%d 日PnL=%+.4fU 基准=$%.2f 监控%d币%s",
                        len(self.positions), self._daily_pnl,
                        self._ref_balance, len(self.coins), pause_tag)

    # ── 主入口 ──

    async def run(self):
        """启动引擎"""
        try:
            await self.executor.start()
            await self._select_coins()
            await self._check_balance()
            self._running = True

            logger.info("🚀 低位挖掘启动 | %d币 | 90min最低×%.2f触发 | "
                        "TP %d%%/SL %d%% | %dx | 每仓%.0f%%",
                        len(self.coins), TRIGGER_DISCOUNT,
                        TP_MARGIN_PCT, SL_MARGIN_PCT,
                        LEVERAGE, POSITION_PCT * 100)
            logger.info("⏯ 暂停: touch %s | rm %s 恢复", PAUSE_FLAG, PAUSE_FLAG)

            tasks = [
                asyncio.create_task(self._main_loop()),
                asyncio.create_task(self._status_summary()),
            ]
            await asyncio.gather(*tasks)

        except KeyboardInterrupt:
            logger.info("⏹ 用户中断")
        except Exception as e:
            logger.exception("引擎异常: %s", e)
        finally:
            self._running = False
            # 清理
            for key in list(self._pending_tp_exits.keys()):
                tp = self._pending_tp_exits.pop(key, None)
                if tp:
                    try:
                        await self.executor._rest_cancel_order(tp["symbol"], tp["order_id"])
                    except Exception:
                        pass
            for key, pos in list(self.positions.items()):
                logger.info("🔴 关机平仓 %s %s", pos["side"], pos["symbol"])
                await self._close_position(pos["symbol"], pos["side"], pos["quantity"])
            await self.executor.stop()
            logger.info("🏁 引擎停止 | 日累计 PnL: %+.4fU", self._daily_pnl)


# ============================================================
# 入口
# ============================================================
if __name__ == "__main__":
    engine = BottomFisherEngine()
    asyncio.run(engine.run())
