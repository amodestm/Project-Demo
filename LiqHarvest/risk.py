"""
==========================
risk.py — 风控层
==========================
职责: 全局风控管理，两个策略共享同一个 RiskManager 实例

核心控制:
  MAX_POSITIONS=1    — 同一时间最多一个持仓
  MAX_DAILY_LOSS=0.20U — 日亏损超限自动停盘
  MAX_DAILY_TRADES=30  — 日交易笔数上限

数据结构:
  Position — 单个持仓对象，自动计算 TP/SL 价格和未实现盈亏

方法:
  can_open(symbol)          — 检查能否开仓（持仓数/日亏损/日交易）
  open_position(pos)        — 记录开仓，递增日交易计数
  close_position(sym,px,reason) — 平仓结算（扣手续费），写入 SQLite
  check_exit_conditions(sym,px) — 检查 TP/SL/超时，返回退出原因
  record_signal(info)       — 记录信号供 Dashboard 读取 (最近50条)
  reset_daily()             — 日风控计数器重置

手续费模型:
  入场 Maker 0.02% + 出场 Taker 0.04%
"""

import logging
import time
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from . import config
from . import trade_db

logger = logging.getLogger(__name__)


@dataclass
class Position:
    symbol: str
    side: str                    # "LONG" | "SHORT"
    entry_price: float
    quantity: float
    entry_time: float
    entry_order_id: Optional[str] = None
    tp_price: float = 0.0
    sl_price: float = 0.0

    def __post_init__(self):
        if self.side == "LONG":
            self.tp_price = self.entry_price * (1 + config.TAKE_PROFIT_PCT)
            self.sl_price = self.entry_price * (1 - config.STOP_LOSS_PCT)
        else:
            self.tp_price = self.entry_price * (1 - config.TAKE_PROFIT_PCT)
            self.sl_price = self.entry_price * (1 + config.STOP_LOSS_PCT)

    @property
    def holding_seconds(self) -> float:
        import time
        return time.time() - self.entry_time

    def unrealized_pnl(self, current_price: float) -> float:
        if self.side == "LONG":
            return (current_price - self.entry_price) * self.quantity
        else:
            return (self.entry_price - current_price) * self.quantity


class RiskManager:
    """风控管理器 — 单例模式，全局风控状态"""

    def __init__(self):
        self.positions: Dict[str, Position] = {}  # symbol -> Position
        self.daily_pnl: float = 0.0
        self.daily_trades: int = 0
        self._day_start_pnl: float = 0.0
        self.signal_history: list = []  # 最近信号记录

    # ---- 仓位检查 ----

    def can_open(self, symbol: str) -> bool:
        """检查是否可以开仓"""
        if symbol in self.positions:
            logger.debug(f"{symbol} 已有持仓，跳过")
            return False
        if len(self.positions) >= config.MAX_POSITIONS:
            logger.debug(f"持仓数已达上限 {config.MAX_POSITIONS}")
            return False
        if self.daily_trades >= config.MAX_DAILY_TRADES:
            logger.warning(f"日交易笔数已达上限 {config.MAX_DAILY_TRADES}")
            return False
        if self.daily_pnl <= -config.MAX_DAILY_LOSS_USDT:
            logger.warning(f"日亏损已达上限 {config.MAX_DAILY_LOSS_USDT}U，停止交易")
            # NOTIFIER: import asyncio
            # NOTIFIER: asyncio.create_task(self.notifier.on_error(
            # NOTIFIER:     f"日亏损已达上限 {config.MAX_DAILY_LOSS_USDT}U，停止交易。累计亏损 {self.daily_pnl:+.4f}U"))
            return False
        return True

    def open_position(self, pos: Position):
        self.positions[pos.symbol] = pos
        self.daily_trades += 1

    def close_position(self, symbol: str, exit_price: float, exit_reason: str) -> Optional[float]:
        """平仓，返回净盈亏（已扣手续费）"""
        pos = self.positions.pop(symbol, None)
        if not pos:
            return None
        gross_pnl = pos.unrealized_pnl(exit_price)
        # 手续费: 入场 Maker + 出场 Taker
        entry_fee = pos.entry_price * pos.quantity * config.MAKER_FEE
        exit_fee = exit_price * pos.quantity * config.TAKER_FEE
        total_fee = entry_fee + exit_fee
        net_pnl = gross_pnl - total_fee
        self.daily_pnl += net_pnl
        # 持久化到 SQLite
        trade_db.insert_trade(config.TRADE_DB_PATH, {
            "symbol": pos.symbol,
            "side": pos.side,
            "entry_price": pos.entry_price,
            "exit_price": exit_price,
            "quantity": pos.quantity,
            "gross_pnl": gross_pnl,
            "fees": total_fee,
            "net_pnl": net_pnl,
            "entry_time": pos.entry_time,
            "exit_time": time.time(),
            "exit_reason": exit_reason,
        })
        logger.info(
            f"平仓 {symbol} {pos.side} | "
            f"入场 {pos.entry_price:.4f} → 出场 {exit_price:.4f} | "
            f"毛利 {gross_pnl:+.4f}U 手续费 {total_fee:.4f}U 净利 {net_pnl:+.4f}U | "
            f"原因: {exit_reason} | 累计日盈亏 {self.daily_pnl:+.4f}U"
        )
        # NOTIFIER: import asyncio
        # NOTIFIER: asyncio.create_task(self.notifier.on_exit(
        # NOTIFIER:     symbol=symbol, side=pos.side, entry_price=pos.entry_price,
        # NOTIFIER:     exit_price=exit_price, gross_pnl=gross_pnl, fees=total_fee,
        # NOTIFIER:     net_pnl=net_pnl, reason=exit_reason))
        return net_pnl

    def check_exit_conditions(self, symbol: str, current_price: float) -> Optional[str]:
        """检查是否需要平仓，返回平仓原因或 None"""
        pos = self.positions.get(symbol)
        if not pos:
            return None

        # 止盈
        if pos.side == "LONG" and current_price >= pos.tp_price:
            return "TP"
        if pos.side == "SHORT" and current_price <= pos.tp_price:
            return "TP"

        # 止损
        if pos.side == "LONG" and current_price <= pos.sl_price:
            return "SL"
        if pos.side == "SHORT" and current_price >= pos.sl_price:
            return "SL"

        # 超时
        if pos.holding_seconds >= config.MAX_HOLDING_SEC:
            return "TIMEOUT"

        return None

    def get_exposure(self) -> float:
        """当前总敞口 (USDT)"""
        return len(self.positions) * config.POSITION_SIZE_USDT

    # ---- 日重置 ----
    def record_signal(self, info: dict):
        """记录信号到历史（供 Dashboard 读取）"""
        import time as _time
        self.signal_history.append({"time": _time.time(), **info})
        if len(self.signal_history) > 50:
            self.signal_history = self.signal_history[-50:]

    def reset_daily(self):
        self.daily_pnl = 0.0
        self.daily_trades = 0
        logger.info("日风控计数器已重置")
