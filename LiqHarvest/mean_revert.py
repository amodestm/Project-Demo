"""
=================================
mean_revert.py — 策略层：均值回归
=================================
职责: RSI 超买超卖 + VWAP 确认的均值回归策略
      高频小利润，与清算瀑布策略互补。

信号逻辑:
  超卖 (RSI < 20) + 价格低于 VWAP → 做多
  超买 (RSI > 80) + 价格高于 VWAP → 做空

出场条件（任意满足即平仓）:
  TP 0.3% | SL 0.5% | RSI 回到 45-55 | 超时 120s

参数:
  监控币种: 前 20 高流动性 (config.SYMBOLS[:20])
  RSI 周期: 14
  冷却时间: 同币种 30s 内不重复
  冷启动: 至少 5 根 1m K 线才入场

依赖:
  RSICalculator — 在线 RSI 计算（滚动均值法）
  MeanRevertStrategy — 主策略类，绑定 on_kline 回调
"""

import asyncio
import logging
import time
from collections import deque
from typing import Optional

from . import config
from .data_feed import DataFeed, KlineSnapshot
from .executor import BinanceExecutor
from .risk import Position, RiskManager

logger = logging.getLogger(__name__)

# 专注前 20 个高流动性币种
MR_SYMBOLS = config.SYMBOLS[:20]

# 策略参数
RSI_PERIOD = 14
RSI_OVERSOLD = 20          # RSI 低于此值做多（收紧，减少假信号）
RSI_OVERBOUGHT = 80        # RSI 高于此值做空（收紧，减少假信号）
MR_POSITION_USDT = 5       # 单笔仓位 5U（Binance 最小名义价值）
MR_TP_PCT = 0.003          # 止盈 0.3%
MR_SL_PCT = 0.005          # 止损 0.5%
MR_MAX_HOLD = 120          # 最长持仓 2 分钟
MIN_TRADES_BEFORE_ENTRY = 5   # 至少 5 根 K 线才入场
SIGNAL_COOLDOWN_SEC = 30       # 同币种信号冷却时间


class RSICalculator:
    """在线 RSI 计算"""

    def __init__(self, period: int = RSI_PERIOD):
        self.period = period
        self.prices: deque = deque(maxlen=period + 1)
        self.gains: deque = deque(maxlen=period)
        self.losses: deque = deque(maxlen=period)
        self._last_price = 0.0

    def update(self, price: float) -> Optional[float]:
        if self._last_price == 0:
            self._last_price = price
            self.prices.append(price)
            return None
        change = price - self._last_price
        self._last_price = price
        self.prices.append(price)
        self.gains.append(max(change, 0))
        self.losses.append(max(-change, 0))
        if len(self.gains) < self.period:
            return None
        avg_gain = sum(self.gains) / self.period
        avg_loss = sum(self.losses) / self.period
        if avg_loss == 0:
            return 100.0
        rs = avg_gain / avg_loss
        return 100.0 - (100.0 / (1.0 + rs))


class MeanRevertStrategy:
    """RSI 均值回归 — 超卖做多、超买做空"""

    def __init__(self, feed: DataFeed, executor: BinanceExecutor, risk: RiskManager):
        self.feed = feed
        self.executor = executor
        self.risk = risk
        self.rsi_calcs = {s: RSICalculator() for s in MR_SYMBOLS}
        self._entering: set = set()
        self._kline_counts = {s: 0 for s in MR_SYMBOLS}
        self._last_signal: dict = {}  # symbol -> timestamp, 冷却用

    def bind(self):
        self.feed.on_kline(self._on_kline)

    def _on_kline(self, kline: KlineSnapshot):
        sym = kline.symbol
        if sym not in MR_SYMBOLS:
            return
        self._kline_counts[sym] += 1
        rsi = self.rsi_calcs[sym].update(kline.close)
        if rsi is None or self._kline_counts[sym] < MIN_TRADES_BEFORE_ENTRY:
            return
        if sym in self._entering or sym in self.risk.positions:
            return
        if not self.risk.can_open(sym):
            return

        vwap = self.feed.vwaps.get(sym)
        if not vwap or vwap.value == 0:
            return

        side = None
        # 超卖 + 价格低于 VWAP → 做多
        if rsi < RSI_OVERSOLD and kline.close < vwap.value:
            side = "LONG"
        # 超买 + 价格高于 VWAP → 做空
        elif rsi > RSI_OVERBOUGHT and kline.close > vwap.value:
            side = "SHORT"

        if side:
            # 冷却检查
            now = time.time()
            if sym in self._last_signal and now - self._last_signal[sym] < SIGNAL_COOLDOWN_SEC:
                return
            self._last_signal[sym] = now
            price = kline.close
            logger.info(
                f"📊 均值回归信号 {sym} {side} | "
                f"RSI={rsi:.1f} | 价格={price:.4f} | VWAP={vwap.value:.4f}"
            )
            asyncio.create_task(self._enter(sym, side, price))

    async def _enter(self, symbol: str, side: str, price: float):
        self._entering.add(symbol)
        try:
            qty = MR_POSITION_USDT / price
            # 确保满足最小名义价值 $5
            if qty * price < 5.0:
                qty = 5.0 / price
            order_side = "BUY" if side == "LONG" else "SELL"
            order_id = await self.executor.place_limit_order(symbol, order_side, qty, price, position_side=side)
            if not order_id:
                self._entering.discard(symbol)
                return

            filled_price = await self._wait_fill(symbol, order_id)
            if filled_price is None:
                await self.executor.cancel_order(symbol, order_id)
                self._entering.discard(symbol)
                return

            pos = Position(
                symbol=symbol, side=side, entry_price=filled_price,
                quantity=qty, entry_time=time.time(), entry_order_id=order_id,
            )
            # 覆盖默认 TP/SL
            if side == "LONG":
                pos.tp_price = filled_price * (1 + MR_TP_PCT)
                pos.sl_price = filled_price * (1 - MR_SL_PCT)
            else:
                pos.tp_price = filled_price * (1 - MR_TP_PCT)
                pos.sl_price = filled_price * (1 + MR_SL_PCT)
            self.risk.open_position(pos)
            logger.info(f"✅ 均值入场 {symbol} {side} @ {filled_price:.4f}")
        except Exception as e:
            logger.exception(f"均值入场异常 {symbol}: {e}")
        finally:
            self._entering.discard(symbol)

    async def _wait_fill(self, symbol: str, order_id: str) -> Optional[float]:
        deadline = time.time() + 5
        while time.time() < deadline:
            result = await self.executor._signed_request("GET", "/papi/v1/um/order", {
                "symbol": symbol, "orderId": order_id,
            })
            if result.get("status") == "FILLED":
                return float(result.get("avgPrice", 0))
            if result.get("simulated"):
                from .data_feed import DataFeed
                d = self.feed.depths.get(symbol)
                if d and d.asks:
                    return float(d.asks[0][0])
                return 0.0
            await asyncio.sleep(0.3)
        return None

    def check_exits(self):
        """遍历持仓检查出场（从主循环调用）"""
        for sym, pos in list(self.risk.positions.items()):
            d = self.feed.depths.get(sym)
            if not d or not d.asks:
                continue
            px = d.asks[0][0] if pos.side == "LONG" else d.bids[0][0]

            # 超时
            if pos.holding_seconds > MR_MAX_HOLD:
                asyncio.create_task(self._exit(sym, px, "TIMEOUT"))
                continue

            # RSI 回归
            rsi_calc = self.rsi_calcs.get(sym)
            if rsi_calc:
                rsi = rsi_calc.update(px)
                if rsi and 45 < rsi < 55:  # RSI 回到中性
                    asyncio.create_task(self._exit(sym, px, "RSI_REVERSION"))
                    continue

            # TP/SL
            if pos.side == "LONG":
                if px >= pos.tp_price:
                    asyncio.create_task(self._exit(sym, px, "TP"))
                elif px <= pos.sl_price:
                    asyncio.create_task(self._exit(sym, px, "SL"))
            else:
                if px <= pos.tp_price:
                    asyncio.create_task(self._exit(sym, px, "TP"))
                elif px >= pos.sl_price:
                    asyncio.create_task(self._exit(sym, px, "SL"))

    async def _exit(self, symbol: str, price: float, reason: str):
        pos = self.risk.positions.get(symbol)
        if not pos:
            return
        exit_side = "SELL" if pos.side == "LONG" else "BUY"
        try:
            actual = await self.executor.place_market_order(symbol, exit_side, pos.quantity, position_side=pos.side)
            if actual and actual > 0:
                price = actual
            self.risk.close_position(symbol, price, reason)
        except Exception as e:
            logger.exception(f"均值平仓异常 {symbol}: {e}")
            self.risk.close_position(symbol, price, reason)
