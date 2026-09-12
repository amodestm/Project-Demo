"""
===================================
strategy.py — 策略层：清算瀑布收割
===================================
职责: 清算瀑布收割策略的信号检测 + 入场/出场状态机

信号逻辑（三条件 AND）:
  1. 强平事件触发（任意金额）
  2. 订单簿失衡: 被清算侧深度不足 (imbalance > 1.1 做多 / < 0.91 做空)
  3. VWAP 偏离 > 0.5%: 价格显著偏离短期 VWAP，确认插针

入场:
  清算方向 (SELL→做多 / BUY→做空) → 反向限价单 (偏移 0.1%)

出场:
  TP 0.8% | SL 1.0% | 超时 300s | VWAP 回归 <0.1%

绑定回调:
  on_liquidation — 主信号入口
  on_kline       — K线更新触发出场检查
  on_depth       — 深度更新触发出场检查
"""

import asyncio
import logging
import time
from typing import Optional

from . import config
from .data_feed import DataFeed, KlineSnapshot, LiquidationEvent, DepthSnapshot
from .executor import BinanceExecutor
from .risk import Position, RiskManager

logger = logging.getLogger(__name__)


class LiquidationHarvestStrategy:
    """
    清算瀑布收割策略

    信号逻辑:
      1. 清算流 — 窗口内清算金额 > 阈值 且 清算方向一致
      2. 订单簿 — 被清算侧深度真空 (买卖比失衡)
      3. VWAP 偏离 — 价格显著偏离短期 VWAP

    入场: 三条件同时满足 → 反向限价单
    出场: TP/SL/超时/VWAP回归
    """

    def __init__(self, feed: DataFeed, executor: BinanceExecutor, risk: RiskManager):
        self.feed = feed
        self.executor = executor
        self.risk = risk
        self._entering: set = set()
        self._diag_cooldown: dict = {}  # symbol → timestamp, 诊断日志冷却

    # ---- 回调绑定 ----

    def bind(self):
        self.feed.on_liquidation(self._on_liquidation)
        self.feed.on_kline(self._on_kline)
        self.feed.on_depth(self._on_depth)

    # ---- 清算事件回调 — 主信号入口 ----

    def _on_liquidation(self, evt: LiquidationEvent):
        """每次清算事件触发，检查是否满足入场条件"""
        symbol = evt.symbol.upper()
        if symbol in self._entering or symbol in self.risk.positions:
            return
        if not self.risk.can_open(symbol):
            return

        # 确定清算方向和策略方向
        if evt.side == "SELL":
            # 多头被清算 → 卖压 → 价格插针下跌 → 做多
            strat_side = "LONG"
            liq_side = "SELL"
        else:
            # 空头被清算 → 买压 → 价格插针拉升 → 做空
            strat_side = "SHORT"
            liq_side = "BUY"

        # 条件 1: 有清算事件（任意额度都触发检查，靠深度+VWAP把关）
        liq_total = self.feed.get_liquidation_total(liq_side)
        sym_total = self.feed.get_symbol_liquidation_total(symbol, liq_side)
        sym_count = self.feed.get_symbol_liquidation_count(symbol, liq_side)

        # 条件 2: 订单簿失衡
        imbalance = self.feed.get_depth_imbalance(symbol)
        if strat_side == "LONG":
            if imbalance < config.DEPTH_IMBALANCE_RATIO:
                return
        else:
            if imbalance > 1.0 / config.DEPTH_IMBALANCE_RATIO:
                return

        # 诊断日志（每币每 60s 一次）
        def _diag(msg: str):
            now = time.time()
            if symbol not in self._diag_cooldown or now - self._diag_cooldown[symbol] > 60:
                self._diag_cooldown[symbol] = now
                logger.info(f"🔍 {symbol} {strat_side} | {msg}")

        # 条件 2b: 最低深度过滤
        thin_side = "bid" if strat_side == "LONG" else "ask"
        thin_depth = self.feed.get_depth_on_side(symbol, thin_side)
        if thin_depth < config.MIN_DEPTH_USDT:
            _diag(f"薄盘 thin={thin_depth:.0f}<{config.MIN_DEPTH_USDT}")
            return

        # 深度数据可用性检查
        if symbol not in self.feed.depths or self.feed.depths[symbol] is None:
            _diag("无深度数据(不在前200)")
            return

        # 条件 3: VWAP 偏离
        vwap = self.feed.vwaps.get(symbol)
        if not vwap or vwap.value == 0:
            _diag("VWAP未就绪")
            return
        depth = self.feed.depths.get(symbol)
        if not depth or not depth.asks or not depth.bids:
            return
        current_price = float(depth.asks[0][0])
        vwap_deviation = (current_price - vwap.value) / vwap.value
        if strat_side == "LONG" and vwap_deviation > -config.VWAP_DEVIATION:
            _diag(f"VWAP偏离不足 {vwap_deviation:.2%} > -{config.VWAP_DEVIATION:.1%}")
            return
        if strat_side == "SHORT" and vwap_deviation < config.VWAP_DEVIATION:
            _diag(f"VWAP偏离不足 {vwap_deviation:.2%} < {config.VWAP_DEVIATION:.1%}")
            return

        # 三条件满足 → 触发入场
        logger.info(
            f"🎯 信号触发 {symbol} {strat_side} | "
            f"清算额 {liq_total:,.0f}U | 笔数 {sym_count} | "
            f"失衡比 {imbalance:.2f} | VWAP偏离 {vwap_deviation:.2%} | "
            f"当前价 {current_price:.4f} VWAP {vwap.value:.4f}"
        )
        self.risk.record_signal({
            "symbol": symbol, "side": strat_side,
            "liq_total": liq_total, "liq_count": sym_count,
            "imbalance": round(imbalance, 2),
            "vwap_deviation": round(vwap_deviation * 100, 2),
            "price": current_price, "vwap": vwap.value,
        })
        # NOTIFIER: asyncio.create_task(self.notifier.on_signal(
        # NOTIFIER:     symbol=symbol, side=strat_side, price=current_price,
        # NOTIFIER:     liq_total=liq_total, imbalance=imbalance, vwap_dev=vwap_deviation))
        asyncio.create_task(self._enter(symbol, strat_side, current_price))

    # ---- 入场执行 ----

    async def _enter(self, symbol: str, side: str, current_price: float):
        self._entering.add(symbol)
        try:
            # 计算限价（比当前价挂更好一点，接插针）
            if side == "LONG":
                limit_price = current_price * (1 - config.ENTRY_OFFSET_PCT)
            else:
                limit_price = current_price * (1 + config.ENTRY_OFFSET_PCT)

            # 计算数量
            qty = config.POSITION_SIZE_USDT / current_price
            order_side = "BUY" if side == "LONG" else "SELL"

            # 保证金检查
            required_margin = config.POSITION_SIZE_USDT / config.LEVERAGE
            balance = await self.executor.get_balance()
            if 0 < balance < required_margin * 1.5:
                logger.warning(
                    f"余额不足 {symbol}: 需要保证金 {required_margin:.4f}U, 余额 {balance:.4f}U"
                )
                return

            order_id = await self.executor.place_limit_order(symbol, order_side, qty, limit_price, position_side=side)
            if not order_id:
                logger.warning(f"入场失败 {symbol}")
                return

            # 等待成交或超时
            filled_price = await self._wait_fill(symbol, order_id)

            if filled_price is None:
                await self.executor.cancel_order(symbol, order_id)
                logger.info(f"入场超时取消 {symbol}")
                return

            # 入场成功
            pos = Position(
                symbol=symbol,
                side=side,
                entry_price=filled_price,
                quantity=qty,
                entry_time=time.time(),
                entry_order_id=order_id,
            )
            self.risk.open_position(pos)
            logger.info(f"✅ 入场成功 {symbol} {side} @ {filled_price:.4f} Qty={qty:.4f}")
            # NOTIFIER: asyncio.create_task(self.notifier.on_entry(
            # NOTIFIER:     symbol=symbol, side=side, entry_price=filled_price, qty=qty))

        except Exception as e:
            logger.exception(f"入场异常 {symbol}: {e}")
        finally:
            self._entering.discard(symbol)

    async def _wait_fill(self, symbol: str, order_id: str) -> Optional[float]:
        """轮询订单状态，返回成交均价或 None（超时）"""
        deadline = time.time() + config.ENTRY_TIMEOUT_SEC
        while time.time() < deadline:
            result = await self.executor._signed_request("GET", "/papi/v1/um/order", {
                "symbol": symbol,
                "orderId": order_id,
            })
            if result.get("status") == "FILLED":
                return float(result.get("avgPrice", 0))
            if result.get("simulated"):
                # 模拟模式直接返回当前价
                depth = self.feed.depths.get(symbol)
                if depth and depth.asks:
                    return float(depth.asks[0][0])
                return 0.0
            await asyncio.sleep(0.3)
        return None

    # ---- K线回调 — 检查出场条件 ----

    def _on_kline(self, kline: KlineSnapshot):
        symbol = kline.symbol
        if symbol not in self.risk.positions:
            return
        self._check_exit(symbol, kline.close)

    # ---- 订单簿回调 — 检查出场条件 ----

    def _on_depth(self, depth: DepthSnapshot):
        symbol = depth.symbol
        if symbol not in self.risk.positions:
            return
        # 用中间价作为当前价
        if depth.bids and depth.asks:
            mid = (depth.bids[0][0] + depth.asks[0][0]) / 2
            self._check_exit(symbol, mid)

    # ---- 出场检查 ----

    def _check_exit(self, symbol: str, current_price: float):
        """检查是否需要平仓，单次检查"""
        # 1. TP/SL/超时
        reason = self.risk.check_exit_conditions(symbol, current_price)
        if reason:
            asyncio.create_task(self._exit(symbol, current_price, reason))
            return

        # 2. VWAP 回归
        vwap = self.feed.vwaps.get(symbol)
        pos = self.risk.positions.get(symbol)
        if vwap and pos and vwap.value > 0:
            deviation = abs(current_price - vwap.value) / vwap.value
            if deviation < config.VWAP_REVERSION_PCT:
                asyncio.create_task(self._exit(symbol, current_price, "VWAP_REVERSION"))

    async def _exit(self, symbol: str, price: float, reason: str):
        """执行平仓"""
        pos = self.risk.positions.get(symbol)
        if not pos:
            return
        exit_side = "SELL" if pos.side == "LONG" else "BUY"
        try:
            actual_price = await self.executor.place_market_order(symbol, exit_side, pos.quantity, position_side=pos.side)
            if actual_price and actual_price > 0:
                price = actual_price
            self.risk.close_position(symbol, price, reason)
            # NOTIFIER: exit notification is handled inside RiskManager.close_position()
            # NOTIFIER: which has access to gross_pnl, total_fee, net_pnl after computation
        except Exception as e:
            logger.exception(f"平仓异常 {symbol}: {e}")
            # 紧急平仓 — 仍记录
            self.risk.close_position(symbol, price, f"{reason} (紧急)")
