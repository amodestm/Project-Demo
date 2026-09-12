"""
=========================
data_feed.py — 数据源层
=========================
职责: WebSocket 数据源管理器
  - 3 路 WS 连接: public(深度) + market(K线) + forceOrder(清算)
  - 订阅 528 币种 depth20@500ms + kline_1m + 全市场 !forceOrder@arr
  - 维护: 深度快照、K线缓存、滚动 VWAP(30根)、清算窗口(120s)
  - 回调分发: on_liquidation / on_kline / on_depth
  - 自动重连: 断开 3 秒后自动重连

数据结构:
  DepthSnapshot  — 前20档买卖盘（快照模式，非增量）
  KlineSnapshot  — 1分钟K线 OHLCV
  LiquidationEvent — 强平事件（2026新格式: 每秒最大一笔）
  VWAPState      — 滚动30根K线的成交量加权均价

2026 新架构:
  public  → path 模式裸消息 (wss://.../public/ws/{stream})
  market  → stream 模式包裹消息 (wss://.../market/stream?streams=)

可选的 python-binance 集成:
  DepthCacheManager 可替代手工 depth20 快照，维护全量订单簿
"""

import asyncio
import json
import logging
import math
import time
from collections import deque
from dataclasses import dataclass, field
from typing import Any, Callable, Dict, List, Optional

import websockets

from . import config

logger = logging.getLogger(__name__)

# 每个连接最多流数
MAX_STREAMS_PER_CONN = 250

# ============================================================
# 数据结构
# ============================================================

@dataclass
class LiquidationEvent:
    symbol: str
    side: str
    price: float
    quantity: float
    usdt_value: float
    timestamp: float

@dataclass
class KlineSnapshot:
    symbol: str
    open: float
    high: float
    low: float
    close: float
    volume: float
    timestamp: float

@dataclass
class DepthSnapshot:
    symbol: str
    bids: List[List[float]]
    asks: List[List[float]]
    timestamp: float

@dataclass
class VWAPState:
    cum_pv: float = 0.0
    cum_vol: float = 0.0
    window: deque = field(default_factory=lambda: deque(maxlen=30))

    @property
    def value(self) -> float:
        return self.cum_pv / self.cum_vol if self.cum_vol > 0 else 0.0

    def update(self, kline: KlineSnapshot):
        typical = (kline.high + kline.low + kline.close) / 3
        pv = typical * kline.volume
        self.cum_pv += pv
        self.cum_vol += kline.volume
        self.window.append((pv, kline.volume))
        while len(self.window) > 30:
            old_pv, old_vol = self.window.popleft()
            self.cum_pv -= old_pv
            self.cum_vol -= old_vol


# ============================================================
# DataFeed 主类
# ============================================================

class DataFeed:
    """多连接 WebSocket 数据源（自动分块）"""

    def __init__(self):
        self._running = False
        self._ws_tasks: List[asyncio.Task] = []
        self._callbacks: Dict[str, List[Callable]] = {
            "liquidation": [],
            "kline": [],
            "depth": [],
        }

        self.klines: Dict[str, deque] = {s: deque(maxlen=60) for s in config.SYMBOLS}
        self.depths: Dict[str, Optional[DepthSnapshot]] = {s: None for s in config.SYMBOLS}
        self.vwaps: Dict[str, VWAPState] = {s: VWAPState() for s in config.SYMBOLS}
        self.liquidation_window: deque = deque()

    # ---- 回调注册 ----

    def on_liquidation(self, cb: Callable):      self._callbacks["liquidation"].append(cb)
    def on_kline(self, cb: Callable):            self._callbacks["kline"].append(cb)
    def on_depth(self, cb: Callable):            self._callbacks["depth"].append(cb)

    # ---- 启动 / 停止 ----

    async def start(self):
        self._running = True
        # 全量监控
        active_syms = config.SYMBOLS
        base_pub = config.BINANCE_TESTNET_PUBLIC_WS if config.USE_TESTNET else config.BINANCE_PUBLIC_WS
        base_mkt = config.BINANCE_TESTNET_MARKET_WS if config.USE_TESTNET else config.BINANCE_MARKET_WS

        # Public (depth) — 1 连接
        pub_streams = "/".join(f"{s.lower()}@depth20@500ms" for s in active_syms)
        self._ws_tasks.append(asyncio.create_task(self._run_ws(f"{base_pub}/ws/{pub_streams}", "public")))

        # Market (kline) — 1 连接
        mkt_streams = "/".join(f"{s.lower()}@kline_1m" for s in active_syms)
        self._ws_tasks.append(asyncio.create_task(self._run_ws(f"{base_mkt}/stream?streams={mkt_streams}", "market")))

        # forceOrder 单独一个连接（全市场）
        fo_url = f"{base_mkt}/stream?streams=!forceOrder@arr"
        self._ws_tasks.append(asyncio.create_task(self._run_ws(fo_url, "forceOrder")))

        logger.info(f"共 {len(active_syms)} 币种, {len(self._ws_tasks)} 个 WS 连接")
        # 任务已在后台运行，不阻塞等待

    async def stop(self):
        self._running = False
        for t in self._ws_tasks:
            t.cancel()

    async def _run_ws(self, url: str, ws_type: str):
        """单个 WebSocket 连接循环（自动重连）"""
        while self._running:
            try:
                async with websockets.connect(url, ping_interval=20, ping_timeout=10) as ws:
                    logger.info(f"WS {ws_type} 已连接")
                    async for raw in ws:
                        msg = json.loads(raw)
                        if ws_type == "public":
                            self._dispatch_public(msg)
                        elif ws_type == "market":
                            self._dispatch_market(msg)
                        elif ws_type == "forceOrder":
                            self._dispatch_fo(msg)
            except asyncio.CancelledError:
                break
            except Exception as e:
                if self._running:
                    logger.error(f"WS {ws_type} 断开: {e}, 3秒后重连")
                    await asyncio.sleep(3)

    # ---- 消息分发 ----

    def _dispatch_public(self, msg: dict):
        """Public 裸格式: {e, s, b, a, ...}"""
        event_type = msg.get("e", "")
        symbol = msg.get("s", "").upper()
        if symbol not in config.SYMBOLS:
            return
        if event_type == "depthUpdate":
            bids = msg.get("bids") or msg.get("b", [])
            asks = msg.get("asks") or msg.get("a", [])
            depth = DepthSnapshot(
                symbol=symbol,
                bids=[[float(x[0]), float(x[1])] for x in bids],
                asks=[[float(x[0]), float(x[1])] for x in asks],
                timestamp=time.time(),
            )
            self.depths[symbol] = depth
            for cb in self._callbacks["depth"]:
                try: cb(depth)
                except Exception: pass

    def _dispatch_market(self, msg: dict):
        """Market 包裹格式: {stream, data} — kline"""
        stream = msg.get("stream", "")
        data = msg.get("data", msg)
        if "@kline_1m" in stream:
            k = data.get("k", data)
            symbol = k.get("s", "").upper()
            if symbol not in config.SYMBOLS:
                return
            kline = KlineSnapshot(
                symbol=symbol,
                open=float(k["o"]), high=float(k["h"]), low=float(k["l"]),
                close=float(k["c"]), volume=float(k["v"]),
                timestamp=k["t"] / 1000,
            )
            self.klines[symbol].append(kline)
            self.vwaps[symbol].update(kline)
            for cb in self._callbacks["kline"]:
                try: cb(kline)
                except Exception: pass

    def _dispatch_fo(self, msg: dict):
        """forceOrder 包裹格式: {stream, data}"""
        data = msg.get("data", msg)
        o = data.get("o", data)
        symbol = o.get("s", "").upper()
        if symbol not in config.SYMBOLS:
            return
        side = o.get("S", "")
        price = float(o.get("ap", 0))
        qty = float(o.get("q", 0))
        usdt = price * qty
        if usdt < 100:
            return
        evt = LiquidationEvent(
            symbol=symbol, side=side, price=price,
            quantity=qty, usdt_value=usdt, timestamp=time.time(),
        )
        self.liquidation_window.append((evt.timestamp, usdt, side, symbol))
        self._clean_liquidation_window()
        for cb in self._callbacks["liquidation"]:
            try: cb(evt)
            except Exception: pass

    # ---- 清算窗口 ----

    def _clean_liquidation_window(self):
        cutoff = time.time() - config.LIQUIDATION_WINDOW_SEC
        while self.liquidation_window and self.liquidation_window[0][0] < cutoff:
            self.liquidation_window.popleft()

    def get_liquidation_total(self, side: Optional[str] = None) -> float:
        self._clean_liquidation_window()
        return sum(val for _, val, s, _ in self.liquidation_window if side is None or s == side)

    def get_liquidation_count(self, side: Optional[str] = None) -> int:
        self._clean_liquidation_window()
        if side is None:
            return len(self.liquidation_window)
        return sum(1 for _, _, s, _ in self.liquidation_window if s == side)

    def get_symbol_liquidation_total(self, symbol: str, side: Optional[str] = None) -> float:
        """单个币种的清算总额"""
        self._clean_liquidation_window()
        return sum(val for _, val, s, sym in self.liquidation_window
                   if sym == symbol and (side is None or s == side))

    def get_symbol_liquidation_count(self, symbol: str, side: Optional[str] = None) -> int:
        """单个币种的清算笔数"""
        self._clean_liquidation_window()
        return sum(1 for _, _, s, sym in self.liquidation_window
                   if sym == symbol and (side is None or s == side))

    # ---- 订单簿分析 ----

    def get_depth_imbalance(self, symbol: str) -> float:
        d = self.depths.get(symbol)
        if not d or not d.bids or not d.asks:
            return 1.0
        n = config.DEPTH_CHECK_LEVELS
        bid = sum(b[1] for b in d.bids[:n])
        ask = sum(a[1] for a in d.asks[:n])
        return ask / bid if bid > 0 else 999.0

    def get_depth_on_side(self, symbol: str, side: str) -> float:
        d = self.depths.get(symbol)
        if not d:
            return 0.0
        entries = d.bids if side == "bid" else d.asks
        return sum(e[0] * e[1] for e in entries[:config.DEPTH_CHECK_LEVELS])
