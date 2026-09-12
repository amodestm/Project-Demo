#!/usr/bin/env python3
"""
高频波动猎手 (Scalp Harvester) v2 — 独立测试脚本
=================================================

策略: 全仓顺趋势高频追进
- 监控 Top 30 成交量币种的实时 bid/ask 推送
- 价格变动超过 0.3% → 顺势追进（上涨做多，下跌做空）
- 全仓进入（余额 × 杠杆）
- 20x 杠杆，全仓模式 (CROSSED)
- 市价单入场（立即成交）
- 软件层 TP/SL 监控（每 200ms 扫描）
- 止盈 3%（保证金，含手续费）
- 止损 5%（保证金，含手续费）

手续费计算（含在 TP/SL 中）:
  入场 Maker 0.02% + 出场 Taker 0.05% = 0.07% 总费率（名义价值）
  对保证金的影响 = 0.07% × 杠杆 = 1.4%
  TP 目标 3%（保证金）→ 需要价格变动 3%/20 + 0.07% = 0.22%
  SL 目标 5%（保证金）→ 需要价格变动 -5%/20 + 0.07% = -0.18%

启动: python3 scalp_harvester.py
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

# 导入项目内的执行器
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from trading_platform.executor_client import PlatformExecutor

# 自动从 start.sh 加载 API Key（跟桌面端一致）
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
logger = logging.getLogger("scalp")

# ============================================================
# 策略参数
# ============================================================
LEVERAGE = 20                       # 杠杆倍数
ENTRY_THRESHOLD_PCT = 0.25          # 入场阈值：当前价相比上一分钟收盘价变动超过此值
TP_MARGIN_PCT = 1.0                 # 止盈：保证金 +1.0%（含手续费）
SL_MARGIN_LOSS_PCT = 2.0            # 止损：本金亏2% 市价出场（20x≈价格波动0.10%）
MAKER_FEE = 0.0002                  # 入场 Maker 费率 0.02%
TAKER_FEE = 0.0005                  # 出场 Taker 费率 0.05%（市价单）
TOTAL_FEE_PCT = (MAKER_FEE + TAKER_FEE) * 100  # 0.07% 入场Taker+出场Maker（TP限价）
TOTAL_FEE_SL_PCT = (TAKER_FEE * 2) * 100        # 0.10% 入场Taker+出场Taker（SL市价）
MAX_POSITIONS = 3                   # 最大并发持仓数（分3仓各1/3）
POSITION_PCT = 0.33                 # 单笔仓位占余额比例（1/3）
PRICE_LOOKBACK_TICKS = 15           # 价格变化检测回溯笔数（~3秒数据）
LOOP_INTERVAL = 0.2                 # 主循环间隔 (秒)
# COINS = ["BTCUSDT"]               # 取消注释锁定指定币种（默认全市场）

MIN_DATA_BEFORE_ENTRY = 1           # 最少需要 N 笔价格数据才入场（0.2s突变检测只需1笔）

# 风控
MAX_DAILY_LOSS_USDT = 20.0          # 日亏损上限 USDT

# 趋势过滤（信号方向必须与近期价格中位数方向一致，过滤逆势单）
USE_TREND_FILTER = False             # 关闭（只用0.25%标准）
TREND_WINDOW_TICKS = 2400           # 趋势窗口（~2min 数据，@50ms/tick）

# 均值回归过滤（价格偏离 5s 均值超 0.35% 时停止追入该方向）
MEAN_WINDOW_TICKS = 100              # 均值窗口（~5s 数据）
MEAN_REVERSION_PCT = 0.45           # 极端偏离阈值，超出则过滤

# K线趋势过滤（信号方向必须与近5根1m K线多数方向一致）
USE_KLINE_FILTER = False             # 关闭（只用0.25%标准）

# 7分钟均线 + 6分钟偏离过滤（一次REST拉7根K线）
USE_MA7_FILTER = False               # 关闭（只用0.25%标准）
MA7_CACHE_SEC = 20                   # 缓存时间

# 6分钟偏离过滤（价格从6分钟前涨超3%不做多，跌超3%不做空）
MAX_6M_CHANGE_PCT = 3.0

# 50分钟收盘价极值过滤：价格已接近近 50m 收盘价最低/最高时不开反向单
# 价 ≤ low_close50m×(1+EXTREME_NEAR_PCT/100) → 不开 SHORT（怕反弹）
# 价 ≥ high_close50m×(1-EXTREME_NEAR_PCT/100) → 不开 LONG（怕回落）
EXTREME_LOOKBACK_MIN = 50
EXTREME_NEAR_PCT = 0.23
EXTREME_10M_NEAR_PCT = 0.25           # 10分钟极值：价距 10m 收盘极值 ≤0.25% 拒绝反向单

# 持仓超时退出（持仓超过N秒仍未盈利则市价平仓）
MAX_HOLD_SECONDS = 180              # 3分钟

# 暂停标记文件路径（存在时暂停开新仓，不影响已有持仓和TP/SL）
PAUSE_FLAG = "/tmp/scalp_pause"

# 测试过滤
TOP_N_COINS = 50                     # 按24h成交量排名取前N（仅价格<2）


# ============================================================
# 引擎
# ============================================================
class ScalpEngine:
    """高频波动猎手引擎 v2 — 全仓顺趋势追进"""

    def __init__(self):
        self.executor = PlatformExecutor()

        # 选中币种列表
        self.coins: list[str] = []

        # 价格跟踪: symbol → deque[mid_price]
        self.price_history: dict[str, deque] = {}

        # 买卖价: symbol → {"bid1": float, "ask1": float}
        self.bid_ask: dict[str, dict] = {}

        # 持仓: f"{symbol}_{side}" → {
        #   "symbol", "side", "entry_price", "quantity",
        #   "tp_price", "sl_price", "open_time"
        # }
        self.positions: dict[str, dict] = {}

        # 上一分钟收盘价（信号检测基准）
        self._prev_close: dict[str, float] = {}
        # 实时信号队列（WS 回调填，主循环消费）
        self._signal_queue: list = []

        # 每个币的短周期价格趋势（最近 ~50 笔 tick ≈ 1-2s）
        self._trend_prices: dict[str, deque] = {}
        # 均值回归窗口（最近 ~100 笔 tick ≈ 5s，用于偏离检测）
        self._mean_prices: dict[str, deque] = {}

        self._running = False
        self._total_balance = 0.0     # 可用余额（每30秒API刷新）
        self._ref_balance = 0.0       # 基准余额（无持仓时锁定，两仓统一用这个算仓位）
        self._daily_pnl = 0.0         # 日盈亏追踪
        self._loop_count = 0
        # 待成交的 TP 限价单: key → {"order_id", "symbol", "side", "tp_price", "quantity"}
        self._pending_tp_exits: dict[str, dict] = {}
        # 同币同向冷却: key="{sym}_{side}" → last_close_timestamp
        self._cooldown: dict[str, float] = {}
        # 杠杆缓存（已确认支持20x的币，跳过REST）
        self._lev_cached: set[str] = set()
        COOLDOWN_SEC = 30
        # 过滤器拒绝计数器（诊断用，10s 输出一次）
        self._reject_counters = {
            "trend": 0, "mean_reversion": 0, "kline": 0,
            "ma7": 0, "change_6m": 0, "extreme_50m": 0,
            "signal_total": 0, "entry_total": 0,
            "position_exists": 0, "cooldown": 0, "pause": 0,
        }
        self._last_diag_time = 0.0

    # ── 主入口 ──

    async def run(self):
        """启动引擎"""
        try:
            await self.executor.start()
            if not self.executor._api_key:
                logger.warning("❌ 未设置 BINANCE_API_KEY / BINANCE_API_SECRET，仅模拟模式")
            else:
                logger.info("✅ PlatformExecutor 已启动")

            await self._select_all_coins()
            # 批量设杠杆（88币一次性全部设好，入场不重复REST）
            await self._batch_set_leverage()
            # 启动时诊断余额
            await self._diagnose_balance()

            await self._sync_positions()
            self._running = True

            # 价格推送走 WS
            ws_task = asyncio.create_task(self._ws_price_feed())
            # 每 60s 快照价格作为 _prev_close（零 REST）
            snap_task = asyncio.create_task(self._snapshot_prices())

            logger.info(f"🚀 策略: 价 vs 上一分钟收盘价 {ENTRY_THRESHOLD_PCT}%触发 | "
                        f"TP {TP_MARGIN_PCT}%/SL {SL_MARGIN_LOSS_PCT}%保证金 | "
                        f"{LEVERAGE}x | 每仓{POSITION_PCT*100:.0f}% | "
                        f"{len(self.coins)} 币 (成交量前{TOP_N_COINS})")
            logger.info(f"📊 手续费模型: 入场Maker {MAKER_FEE:.2%} + 出场Taker {TAKER_FEE:.2%}")
            logger.info(f"⏯ 暂停: touch {PAUSE_FLAG} 暂停开新仓 | rm {PAUSE_FLAG} 恢复")
            await self._main_loop()
        except KeyboardInterrupt:
            logger.info("⏹ 用户中断")
        except Exception as e:
            logger.exception("❌ 引擎异常: %s", e)
        finally:
            self._running = False
            # 清理 TP 限价单
            for key in list(self._pending_tp_exits.keys()):
                await self._cancel_pending_tp(key)
            # 平掉所有持仓
            for key, pos in list(self.positions.items()):
                logger.info("🔴 关机平仓 %s %s", pos["side"], pos["symbol"])
                await self._close_position(pos["symbol"], pos["side"], pos["quantity"])
            await self.executor.stop()
            logger.info(f"🏁 引擎停止 | 日累计 PnL: {self._daily_pnl:+.4f}U")

    # ── 批量设杠杆 ──

    async def _batch_set_leverage(self):
        """启动时把所有币的杠杆设好，入场时跳过 REST"""
        if not self.coins:
            return
        logger.info("🔧 批量设杠杆 %d 币 → %dx ...", len(self.coins), LEVERAGE)
        tasks = []
        for sym in self.coins:
            tasks.append(self.executor._signed_post("/papi/v1/um/leverage",
                                                     {"symbol": sym, "leverage": LEVERAGE}))
        results = await asyncio.gather(*tasks, return_exceptions=True)
        ok = 0
        for sym, res in zip(self.coins, results):
            if isinstance(res, dict) and not res.get("_error"):
                self._lev_cached.add(sym)
                ok += 1
        logger.info("✅ 杠杆设置完成: %d/%d 成功", ok, len(self.coins))

    # ── 初始化上一分钟收盘价（信号基准） ──

    async def _init_prev_close(self, symbol: str):
        """拉取上一根已收盘 1m K 线的收盘价作为信号基准"""
        try:
            async with self.executor._session.get(
                f"https://fapi.binance.com/fapi/v1/klines?"
                f"symbol={symbol}&interval=1m&limit=2",
                timeout=5,
            ) as resp:
                if resp.status == 200:
                    klines = await resp.json()
                    if isinstance(klines, list) and len(klines) >= 2:
                        close = float(klines[-2][4])  # 倒数第二根是已收盘的上一根
                        if close > 0:
                            self._prev_close[symbol] = close
        except Exception:
            pass

    async def _snapshot_prices(self):
        """每分钟第 1 秒快照（对齐 Binance K线收盘价），替代 REST K线查询"""
        while self._running:
            now = time.time()
            wait = 61 - (now % 60)   # 对齐到下一分钟第 1 秒
            await asyncio.sleep(wait)
            count = 0
            for sym in self.coins:
                prices = self.price_history.get(sym)
                if prices and len(prices) > 0:
                    self._prev_close[sym] = prices[-1]
                    count += 1
            logger.info("📸 价格快照完成 %d 币 → _prev_close 已更新", count)

    # ── 全市场币种加载 ──

    async def _select_all_coins(self):
        """从 exchangeInfo + 24h 成交量筛选活跃 USDT 交易对"""
        hardcoded = globals().get("COINS", [])
        if hardcoded:
            self.coins = hardcoded
            logger.info("📌 使用指定币种 (%d): %s", len(self.coins), self.coins)
            return

        if not self.executor._session:
            logger.error("❌ 会话未初始化")
            return

        try:
            # 1. 获取精度表（所有币种）
            if not self.executor._tick_size:
                await self.executor._load_precisions()
            all_coins = sorted(self.executor._tick_size.keys())

            # 2. 获取 24h 成交量 + 当前价格
            vol_data = {}
            price_data = {}
            try:
                async with self.executor._session.get(
                    "https://fapi.binance.com/fapi/v1/ticker/24hr",
                    timeout=15,
                ) as resp:
                    if resp.status == 200:
                        for t in await resp.json():
                            if isinstance(t, dict):
                                vol_data[t.get("symbol", "")] = float(t.get("quoteVolume", 0))
                                price_data[t.get("symbol", "")] = float(t.get("lastPrice", 0))
            except Exception as e:
                logger.warning("⚠️ 获取24h成交量失败: %s，跳过过滤", e)

            # 3. 获取杠杆倍数限制（排除最大杠杆 < 20x 的币种）
            max_lev_data = {}
            try:
                async with self.executor._session.get(
                    "https://fapi.binance.com/fapi/v1/leverageBracket",
                    timeout=15,
                ) as resp:
                    if resp.status == 200:
                        for bracket in await resp.json():
                            sym = bracket.get("symbol", "")
                            brackets = bracket.get("brackets", [])
                            if brackets:
                                max_lev_data[sym] = brackets[0].get("initialLeverage", 0)
            except Exception as e:
                logger.warning("⚠️ 获取杠杆限制失败: %s，跳过过滤", e)

            # 4. 筛选: USDT 交易对 + 杠杆 ≥ 20x + 价格 < 2 → 按成交量排名取前 N
            candidates = []
            skipped_lev = 0
            skipped_price = 0
            for s in all_coins:
                if not (s.endswith("USDT") and not s.endswith("USDCUSDT")):
                    continue
                max_lev = max_lev_data.get(s, 125)
                if max_lev < LEVERAGE:
                    skipped_lev += 1
                    continue
                price = price_data.get(s, 0)
                if price <= 0 or price >= 2:
                    skipped_price += 1
                    continue
                candidates.append((s, vol_data.get(s, 0)))
            # 按成交量降序，取前 TOP_N_COINS
            candidates.sort(key=lambda x: x[1], reverse=True)
            self.coins = [s for s, v in candidates[:TOP_N_COINS]]

            min_vol = candidates[TOP_N_COINS - 1][1] if len(candidates) >= TOP_N_COINS else 0
            logger.info(
                "📊 筛选完成: %d 个 (成交量前%d, 杠杆≥%dx, 价格<2, 最低≈%.0f万U) "
                "| 跳过 %d 低杠杆 %d 高价币",
                len(self.coins), TOP_N_COINS, LEVERAGE,
                min_vol / 10_000 if min_vol else 0,
                skipped_lev, skipped_price,
            )

        except Exception as e:
            logger.exception("❌ 全市场加载失败: %s", e)
            # 兜底: 用 config.py 中的列表
            try:
                from . import config
                self.coins = config.SYMBOLS
                logger.info("📊 兜底使用 config.SYMBOLS: %d 币种", len(self.coins))
            except ImportError:
                self.coins = ["BTCUSDT", "ETHUSDT", "SOLUSDT"]
                logger.info("📊 兜底使用硬编码: %s", self.coins)

    # ── 余额诊断 ──

    async def _diagnose_balance(self):
        """启动时诊断余额，打印所有资产详情"""
        try:
            # 方法1: /papi/v1/balance
            raw = await self.executor._signed_get("/papi/v1/balance")
            logger.info("📋 余额诊断 /papi/v1/balance: type=%s", type(raw).__name__)
            if isinstance(raw, list):
                for item in raw:
                    asset = item.get("asset", "?")
                    um = item.get("umWalletBalance", "0")
                    cross = item.get("crossMarginFree", "0")
                    total = item.get("totalWalletBalance", "0")
                    bal = item.get("balance", "0")
                    logger.info("  %s: um=%s cross=%s total=%s bal=%s",
                                asset, um, cross, total, bal)
                if not raw:
                    logger.info("  (空列表)")
            elif isinstance(raw, dict):
                logger.info("  dict: %s", str(raw)[:400])
            else:
                logger.info("  无法解析: %s", str(raw)[:200])

            # 方法2: /papi/v1/account
            acc = await self.executor._signed_get("/papi/v1/account")
            logger.info("📋 余额诊断 /papi/v1/account: type=%s", type(acc).__name__)
            if isinstance(acc, dict):
                for field in ("totalAvailableBalance", "accountEquity", "totalMarginBalance",
                              "um", "availableBalance"):
                    val = acc.get(field)
                    if val is not None:
                        logger.info("  %s = %s", field, val)
            else:
                logger.info("  %s", str(acc)[:200])
        except Exception as e:
            logger.warning("⚠️ 余额诊断失败: %s", e)

    # ── K线方向初始化 ──

    # ── WebSocket 价格推送（全市场单流） ──

    async def _ws_price_feed(self):
        """
        实时 bid/ask 推送 — 全市场 !bookTicker 单流（走 SOCKS5 代理）。
        不再按币种拼接 URL，一个流推送所有 USDT 交易对的 bid/ask。
        """
        ws_url = "wss://fstream.binance.com/stream?streams=!bookTicker"
        logger.info("🔌 WS 全市场 !bookTicker | 监控 %d 币种", len(self.coins))

        proxy_url = os.environ.get("ALL_PROXY") or "socks5://127.0.0.1:7897"
        while self._running:
            try:
                connector = ProxyConnector.from_url(proxy_url)
                async with aiohttp.ClientSession(connector=connector) as session:
                    logger.info("🔌 WS 全市场连接中 (代理:%s)...", proxy_url)
                    async with session.ws_connect(ws_url, timeout=30) as ws:
                        logger.info("✅ WS 全市场已连接")
                        async for msg in ws:
                            if msg.type == aiohttp.WSMsgType.TEXT:
                                data = json.loads(msg.data)
                                d = data.get("data", msg)  # !bookTicker 有时是包裹格式
                                sym = d.get("s", "")
                                if sym in self.coins:
                                    bid = float(d.get("b", 0))
                                    ask = float(d.get("a", 0))
                                    if bid > 0 and ask > 0:
                                        mid = (bid + ask) / 2
                                        self.bid_ask[sym] = {"bid1": bid, "ask1": ask}
                                        # 懒初始化价格历史
                                        if sym not in self.price_history:
                                            self.price_history[sym] = deque(maxlen=PRICE_LOOKBACK_TICKS)
                                        self.price_history[sym].append(mid)

                                        # ── 实时信号检测：价 vs 上一分钟收盘价 ──
                                        ref = self._prev_close.get(sym)
                                        if ref and ref > 0:
                                            change = (mid - ref) / ref * 100
                                            if abs(change) >= ENTRY_THRESHOLD_PCT:
                                                side = "LONG" if change > 0 else "SHORT"
                                                self._signal_queue.append((sym, side, mid, change))
                                                self._reject_counters["signal_total"] += 1
                                        elif sym not in self._prev_close:
                                            # 首次收到报价，用当前价初始化（diff=0%，等60s快照后才有信号）
                                            self._prev_close[sym] = mid

                                        # ── WS 级止损检查（比主循环快数倍） ──
                                        for k, p in list(self.positions.items()):
                                            if p["symbol"] != sym:
                                                continue
                                            factor = SL_MARGIN_LOSS_PCT / 100 / LEVERAGE
                                            if p["side"] == "LONG" and mid <= p["entry_price"] * (1 - factor):
                                                asyncio.create_task(self._close_and_clean(k, p))
                                            elif p["side"] == "SHORT" and mid >= p["entry_price"] * (1 + factor):
                                                asyncio.create_task(self._close_and_clean(k, p))
                                            break  # 每个 sym 最多一个仓位

                                        # ── 趋势跟踪 + 均值窗口 ──
                                        if sym not in self._trend_prices:
                                            self._trend_prices[sym] = deque(maxlen=TREND_WINDOW_TICKS)
                                        self._trend_prices[sym].append(mid)
                                        if sym not in self._mean_prices:
                                            self._mean_prices[sym] = deque(maxlen=MEAN_WINDOW_TICKS)
                                        self._mean_prices[sym].append(mid)
                            elif msg.type in (aiohttp.WSMsgType.ERROR, aiohttp.WSMsgType.CLOSED):
                                break
            except asyncio.CancelledError:
                break
            except Exception as e:
                if self._running:
                    logger.warning("⚠️ WS 全市场断开: %s，3秒后重连", str(e)[:80])
                    await asyncio.sleep(3)

    # ── 持仓同步 ──

    async def _sync_positions(self):
        """从交易所同步当前持仓"""
        try:
            pos_list = await self.executor.get_positions()
            new_positions = {}
            for p in pos_list:
                sym = p["symbol"]
                side = p["side"]
                key = f"{sym}_{side}"
                tp_price = self._calc_tp_price(p["entry_price"], side)
                sl_price = self._calc_sl_price(p["entry_price"], side)
                new_positions[key] = {
                    "symbol": sym,
                    "side": side,
                    "entry_price": p["entry_price"],
                    "quantity": p["quantity"],
                    "tp_price": tp_price,
                    "sl_price": sl_price,
                    "open_time": time.time(),
                }
            self.positions = new_positions
            if self.positions:
                logger.info("📋 持仓同步: %d 笔", len(self.positions))
        except Exception as e:
            logger.warning("⚠️ 持仓同步失败: %s", e)

    # ── TP/SL 价格计算（含手续费） ──

    def _calc_tp_price(self, entry: float, side: str) -> float:
        """
        计算止盈价（含手续费）。

        净收益率 = (价格变动率 × 杠杆) - 总费率(对保证金)
        目标净收益率 = TP_MARGIN_PCT / 100

        => 价格变动率 = TP_MARGIN_PCT/100/LEVERAGE + (MAKER_FEE + TAKER_FEE)
        """
        price_factor = (TP_MARGIN_PCT / 100 / LEVERAGE) + (MAKER_FEE + TAKER_FEE)
        if side == "LONG":
            return entry * (1 + price_factor)
        else:  # SHORT
            return entry * (1 - price_factor)

    def _calc_sl_price(self, entry: float, side: str) -> float:
        """止损价 = 开仓价 × (1 ∓ 保证金亏损%/杠杆)"""
        factor = SL_MARGIN_LOSS_PCT / 100 / LEVERAGE
        if side == "LONG":
            return entry * (1 - factor)
        else:
            return entry * (1 + factor)

    # ── 止损检查 ──

    async def _check_sl(self):
        """
        止损检查 — 本金亏 SL_MARGIN_LOSS_PCT% 则市价平仓。
        多仓：当前价 ≤ 开仓价 × (1 - 保证金亏损%/杠杆)
        空仓：当前价 ≥ 开仓价 × (1 + 保证金亏损%/杠杆)
        """
        for key, pos in list(self.positions.items()):
            prices = self.price_history.get(pos["symbol"], deque())
            if not prices:
                continue
            mark = prices[-1]
            sym = pos["symbol"]
            side = pos["side"]
            entry = pos["entry_price"]

            is_sl = False
            sl_line = 0.0
            factor = SL_MARGIN_LOSS_PCT / 100 / LEVERAGE
            if side == "LONG":
                sl_line = entry * (1 - factor)
                if mark <= sl_line:
                    is_sl = True
            elif side == "SHORT":
                sl_line = entry * (1 + factor)
                if mark >= sl_line:
                    is_sl = True

            if not is_sl:
                continue

            # 防重复：WS可能已触发止损
            closing_set = getattr(self, '_closing', set())
            if key in closing_set:
                continue

            logger.warning("🛑 止损 %s %s @%.4f (开仓%.4f SL线=%.4f)",
                           side, sym, mark, entry, sl_line)

            # 先平仓（不等待撤TP，省 ~100ms）
            await self._close_position(pos["symbol"], pos["side"], pos["quantity"])
            self._report_pnl(pos)
            # 平仓后后台撤 TP 单
            if key in self._pending_tp_exits:
                asyncio.create_task(self._cancel_pending_tp(key))

    async def _get_ma7(self, symbol: str) -> float:
        """获取 MA7 均线值（复用 _check_medium_filters 的缓存）"""
        key = f"_med_{symbol}"
        cached = getattr(self, key, None)
        if cached:
            ma7 = cached[0]
            if ma7 > 0:
                return ma7
        # 缓存过期或不存在，拉一次K线
        try:
            async with self.executor._session.get(
                f"https://fapi.binance.com/fapi/v1/klines?"
                f"symbol={symbol}&interval=1m&limit={EXTREME_LOOKBACK_MIN}",
                timeout=5,
            ) as resp:
                if resp.status != 200:
                    return 0.0
                klines = await resp.json()
                if isinstance(klines, list) and len(klines) >= 3:
                    closes = [float(k[4]) for k in klines]
                    ma7 = sum(closes[-7:]) / min(7, len(closes))
                    price_6m_ago = closes[-7] if len(closes) >= 7 else closes[0]
                    high_close50m = max(closes)
                    low_close50m = min(closes)
                    closes_10m = closes[-10:] if len(closes) >= 10 else closes
                    high_close10m = max(closes_10m)
                    low_close10m = min(closes_10m)
                    now = time.time()
                    setattr(self, key, (ma7, price_6m_ago, high_close50m, low_close50m, high_close10m, low_close10m))
                    setattr(self, f"{key}_t", now)
                    return ma7
        except Exception:
            pass
        return 0.0

    # ── 持仓超时退出 ──

    async def _check_hold_timeout(self):
        """持仓超过 3 分钟：盈利→续命重置计时，亏损→市价平仓"""
        now = time.time()
        for key, pos in list(self.positions.items()):
            hold_time = now - pos.get("open_time", now)
            if hold_time < MAX_HOLD_SECONDS:
                continue

            prices = self.price_history.get(pos["symbol"], deque())
            mark = prices[-1] if prices else pos["entry_price"]
            sym = pos["symbol"]
            side = pos["side"]

            is_profit = (side == "LONG" and mark > pos["entry_price"]) or \
                        (side == "SHORT" and mark < pos["entry_price"])

            if is_profit:
                # 盈利续命：重置开仓时间，再给 3 分钟
                pos["open_time"] = now
                logger.info("⏳ %s %s 盈利续命 +3min (入%.4f 现%.4f)",
                            side, sym, pos["entry_price"], mark)
                continue

            logger.warning("⏰ 超时退出 %s %s | 持仓%.0fs 亏损 (入%.4f 现%.4f)",
                           side, sym, hold_time, pos["entry_price"], mark)

            # 先撤 TP 限价单
            if key in self._pending_tp_exits:
                await self._cancel_pending_tp(key)

            await self._close_position(pos["symbol"], pos["side"], pos["quantity"])
            self._report_pnl(pos)

    async def _verify_position(self, key: str, symbol: str, side: str) -> tuple:
        """验证持仓是否存在，返回 (exists, actual_qty, actual_entry)"""
        try:
            positions = await self.executor.get_positions()
            for p in positions:
                if p["symbol"] == symbol and p["side"] == side:
                    return (True, p["quantity"], p["entry_price"])
        except Exception:
            pass
        # 持仓不存在 → 清理所有相关状态
        self.positions.pop(key, None)
        self._pending_tp_exits.pop(key, None)
        logger.warning("🧹 持仓 %s %s 已不存在，清理状态", side, symbol)
        return (False, 0, 0)

    async def _check_tp_health(self):
        """巡检每个持仓的 TP 限价单是否存在，丢了就重挂"""
        for key, pos in list(self.positions.items()):
            if key in self._pending_tp_exits:
                continue  # TP 单在跟踪中，正常
            # TP 丢了！从交易所查有无订单
            try:
                orders = await self.executor._signed_get("/papi/v1/um/openOrders", {
                    "symbol": pos["symbol"],
                })
                has_tp = False
                if isinstance(orders, list):
                    for o in orders:
                        if (o.get("side") == ("SELL" if pos["side"] == "LONG" else "BUY")
                                and o.get("positionSide") == pos["side"]
                                and o.get("type") == "LIMIT"):
                            has_tp = True
                            self._pending_tp_exits[key] = {
                                "order_id": o["orderId"], "symbol": pos["symbol"],
                                "side": pos["side"], "tp_price": float(o["price"]),
                                "quantity": float(o["origQty"]), "type": "TP",
                            }
                            logger.info("🔍 找回TP单 %s %s id=%s", pos["side"], pos["symbol"], o["orderId"])
                            break
                if not has_tp:
                    # 真丢了，重挂前先验证仓位还在不在
                    exists, actual_qty, actual_entry = await self._verify_position(key, pos["symbol"], pos["side"])
                    if not exists:
                        continue
                    # 用实际持仓量更新
                    pos["quantity"] = actual_qty
                    pos["entry_price"] = actual_entry
                    pos["tp_price"] = self._calc_tp_price(actual_entry, pos["side"])

                    exit_side = "SELL" if pos["side"] == "LONG" else "BUY"
                    retry = await self.executor.place_order(
                        symbol=pos["symbol"], side=exit_side,
                        quantity=pos["quantity"],
                        order_type="LIMIT", price=pos["tp_price"],
                        position_side=pos["side"],
                    )
                    oid = retry.get("orderId") if isinstance(retry, dict) else None
                    if oid and not retry.get("_error"):
                        self._pending_tp_exits[key] = {
                            "order_id": oid, "symbol": pos["symbol"],
                            "side": pos["side"], "tp_price": pos["tp_price"],
                            "quantity": pos["quantity"], "type": "TP",
                        }
                        logger.info("⚠️ TP丢失重挂 %s %s id=%s", pos["side"], pos["symbol"], oid)
                    else:
                        logger.warning("❌ TP重挂失败 %s %s: %s", pos["side"], pos["symbol"],
                                       retry.get("error", str(retry)[:80]))
            except Exception as e:
                logger.debug("TP巡检异常 %s: %s", pos["symbol"], e)

    async def _check_pending_tp(self):
        """检查 TP 限价单是否成交"""
        for key, tp in list(self._pending_tp_exits.items()):
            try:
                result = await self.executor._signed_get("/papi/v1/um/order", {
                    "symbol": tp["symbol"],
                    "orderId": tp["order_id"],
                })
                status = result.get("status", "")
                if status == "FILLED":
                    fill_price = float(result.get("avgPrice", tp["tp_price"]))
                    pos = self.positions.pop(key, None)
                    self._pending_tp_exits.pop(key, None)
                    self._cooldown[key] = time.time()  # 30s 冷却
                    if pos:
                        if tp["side"] == "LONG":
                            gross_pnl = (fill_price - pos["entry_price"]) * pos["quantity"]
                        else:
                            gross_pnl = (pos["entry_price"] - fill_price) * pos["quantity"]
                        self._daily_pnl += gross_pnl
                        logger.info(
                            "✅ TP限价单成交 %s %s | 入场 %s → 出场 %s | PnL %+.4fU",
                            tp["side"], tp["symbol"],
                            self._fmt_price(tp["symbol"], pos["entry_price"]),
                            self._fmt_price(tp["symbol"], fill_price),
                            gross_pnl,
                        )
                elif status in ("CANCELED", "EXPIRED", "REJECTED"):
                    logger.warning("⚠️ TP限价单被取消 %s %s (status=%s) 准备重挂",
                                   tp["side"], tp["symbol"], status)
                    self._pending_tp_exits.pop(key, None)
                    # 仓位还在吗？重挂前验证
                    if key in self.positions:
                        pos = self.positions[key]
                        exists, actual_qty, actual_entry = await self._verify_position(key, pos["symbol"], pos["side"])
                        if not exists:
                            continue
                        # 用实际数量更新
                        pos["quantity"] = actual_qty
                        pos["entry_price"] = actual_entry
                        pos["tp_price"] = self._calc_tp_price(actual_entry, pos["side"])

                        exit_side = "SELL" if pos["side"] == "LONG" else "BUY"
                        if pos["quantity"] > 0 and pos["tp_price"] > 0:
                            retry = await self.executor.place_order(
                                symbol=pos["symbol"], side=exit_side,
                                quantity=pos["quantity"],
                                order_type="LIMIT", price=pos["tp_price"],
                                position_side=pos["side"],
                            )
                            oid = retry.get("orderId") if isinstance(retry, dict) else None
                            if oid and not retry.get("_error"):
                                self._pending_tp_exits[key] = {
                                    "order_id": oid, "symbol": pos["symbol"],
                                    "side": pos["side"], "tp_price": pos["tp_price"],
                                    "quantity": pos["quantity"], "type": "TP",
                                }
                                logger.info("📋 TP重挂成功 %s %s id=%s @%s",
                                            pos["side"], pos["symbol"], oid,
                                            self._fmt_price(pos["symbol"], pos["tp_price"]))
            except Exception as e:
                logger.debug("限价单查询异常 %s: %s", tp.get("symbol"), e)

    async def _cancel_pending_tp(self, key: str):
        """撤销 TP 限价单"""
        tp = self._pending_tp_exits.pop(key, None)
        if not tp:
            return
        try:
            await self.executor._rest_cancel_order(tp["symbol"], tp["order_id"])
            logger.info("🗑 TP限价单已撤 %s %s id=%s", tp["side"], tp["symbol"], tp["order_id"])
        except Exception as e:
            logger.warning("⚠️ 撤TP单失败 %s: %s", tp["symbol"], e)

    async def _check_kline_trend(self, symbol: str, signal_side: str) -> bool:
        """K线方向过滤。
        规则1：前一根涨>0.25% → 只看前一根方向
        规则2：两根平均变动>0.25% → 拒绝
        规则3：两根必须同向
        """
        if not USE_KLINE_FILTER:
            return True

        # 20s 缓存
        key = f"_kl_{symbol}"
        now = time.time()
        cached = getattr(self, key, None)
        cache_time = getattr(self, f"{key}_t", 0)
        if cached and now - cache_time < 20:
            dirs, last_change_pct, last_h, last_l, last_c, prev_change_pct = cached
        else:
            try:
                # 拉 3 根，最后一根是当前未收盘 K 线，丢掉只用前 2 根
                async with self.executor._session.get(
                    f"https://fapi.binance.com/fapi/v1/klines?"
                    f"symbol={symbol}&interval=1m&limit=3",
                    timeout=5,
                ) as resp:
                    if resp.status != 200:
                        return False
                    klines = await resp.json()
                    if not isinstance(klines, list) or len(klines) < 3:
                        return False
                    closed = klines[:-1]  # [T-2, T-1] 已收盘
                    dirs = [1 if float(k[4]) > float(k[1]) else -1 for k in closed]
                    last_o = float(closed[-1][1])
                    last_c = float(closed[-1][4])
                    last_h = float(closed[-1][2])
                    last_l = float(closed[-1][3])
                    last_change_pct = abs(last_c - last_o) / last_o * 100 if last_o > 0 else 0
                    prev_o = float(closed[-2][1])
                    prev_c = float(closed[-2][4])
                    prev_change_pct = abs(prev_c - prev_o) / prev_o * 100 if prev_o > 0 else 0
                    cached = (dirs, last_change_pct, last_h, last_l, last_c, prev_change_pct)
                    setattr(self, key, cached)
                    setattr(self, f"{key}_t", now)
            except Exception:
                return True

        last_dir = dirs[-1]  # 前一根方向: 1 阳 / -1 阴
        _trace = f"[{dirs[0]},{dirs[1]}] chg={last_change_pct:.2f}%"

        # 规则1：前一根波动大 → 只看前一根方向
        if last_change_pct > 0.25:
            if signal_side == "LONG" and last_dir > 0:
                return True
            if signal_side == "SHORT" and last_dir < 0:
                return True
            logger.info("🔍 %s %s kline=❌(r1_dir) %s", symbol, signal_side, _trace)
            return False

        # 规则2：两根平均变动 > 0.25% → 拒绝追入（已涨/跌太多不追）
        avg_change_pct = (last_change_pct + prev_change_pct) / 2
        if avg_change_pct > 0.25:
            logger.info("🔍 %s %s kline=❌(r3_avg=%.2f%%) %s", symbol, signal_side, avg_change_pct, _trace)
            return False

        # 规则4：两根必须同向
        bullish = sum(1 for d in dirs if d > 0)
        bearish = len(dirs) - bullish
        if signal_side == "LONG" and bullish < 2:
            logger.info("🔍 %s %s kline=❌(r4_bear) %s", symbol, signal_side, _trace)
            return False
        if signal_side == "SHORT" and bearish < 2:
            logger.info("🔍 %s %s kline=❌(r4_bull) %s", symbol, signal_side, _trace)
            return False
        logger.info("🔍 %s %s kline=✅ %s", symbol, signal_side, _trace)
        return True

    async def _check_medium_filters(self, symbol: str, signal_side: str, current_price: float) -> bool:
        """7分钟均线 + 6分钟偏离 + 50分钟/10分钟收盘价极值检查（一次REST拉50根K线，20s缓存）"""
        if not USE_MA7_FILTER:
            return True
        if current_price <= 0:
            return True

        key = f"_med_{symbol}"
        now = time.time()
        cached = getattr(self, key, None)
        cache_time = getattr(self, f"{key}_t", 0)
        if cached and now - cache_time < MA7_CACHE_SEC:
            ma7, price_6m_ago, high_close50m, low_close50m, high_close10m, low_close10m = cached
        else:
            try:
                async with self.executor._session.get(
                    f"https://fapi.binance.com/fapi/v1/klines?"
                    f"symbol={symbol}&interval=1m&limit={EXTREME_LOOKBACK_MIN}",
                    timeout=5,
                ) as resp:
                    if resp.status != 200:
                        return True
                    klines = await resp.json()
                    if not isinstance(klines, list) or len(klines) < 3:
                        return True
                    closes = [float(k[4]) for k in klines]
                    ma7 = sum(closes[-7:]) / min(7, len(closes))
                    price_6m_ago = closes[-7] if len(closes) >= 7 else closes[0]
                    high_close50m = max(closes)
                    low_close50m = min(closes)
                    # 10分钟极值（最后10根）
                    closes_10m = closes[-10:] if len(closes) >= 10 else closes
                    high_close10m = max(closes_10m)
                    low_close10m = min(closes_10m)
                    setattr(self, key, (ma7, price_6m_ago, high_close50m, low_close50m, high_close10m, low_close10m))
                    setattr(self, f"{key}_t", now)
            except Exception:
                return True

        # MA7 过滤
        if signal_side == "LONG" and current_price <= ma7:
            self._reject_counters["ma7"] += 1
            logger.info("🔍 %s %s med=❌(ma7) price=%.4f <= ma7=%.4f",
                        symbol, signal_side, current_price, ma7)
            return False
        if signal_side == "SHORT" and current_price >= ma7:
            self._reject_counters["ma7"] += 1
            logger.info("🔍 %s %s med=❌(ma7) price=%.4f >= ma7=%.4f",
                        symbol, signal_side, current_price, ma7)
            return False

        # 6分钟偏离过滤
        change_6m = (current_price - price_6m_ago) / price_6m_ago * 100
        if signal_side == "LONG" and change_6m > MAX_6M_CHANGE_PCT:
            self._reject_counters["change_6m"] += 1
            logger.info("🔍 %s %s med=❌(6m=%.2f%%>%.0f%%)",
                        symbol, signal_side, change_6m, MAX_6M_CHANGE_PCT)
            return False
        if signal_side == "SHORT" and change_6m < -MAX_6M_CHANGE_PCT:
            self._reject_counters["change_6m"] += 1
            logger.info("🔍 %s %s med=❌(6m=%.2f%%<%.0f%%)",
                        symbol, signal_side, change_6m, -MAX_6M_CHANGE_PCT)
            return False

        # 10分钟收盘价极值过滤
        if low_close10m > 0 and signal_side == "SHORT":
            if current_price <= low_close10m * (1 + EXTREME_10M_NEAR_PCT / 100):
                self._reject_counters["extreme_50m"] += 1
                logger.info("🔍 %s %s med=❌(10m) price<=10m_low*%.4f",
                            symbol, signal_side, 1 + EXTREME_10M_NEAR_PCT / 100)
                return False
        if high_close10m > 0 and signal_side == "LONG":
            if current_price >= high_close10m * (1 - EXTREME_10M_NEAR_PCT / 100):
                self._reject_counters["extreme_50m"] += 1
                logger.info("🔍 %s %s med=❌(10m) price>=10m_high*%.4f",
                            symbol, signal_side, 1 - EXTREME_10M_NEAR_PCT / 100)
                return False

        # 50分钟收盘价极值过滤
        if low_close50m > 0 and signal_side == "SHORT":
            if current_price <= low_close50m * (1 + EXTREME_NEAR_PCT / 100):
                self._reject_counters["extreme_50m"] += 1
                logger.info("🔍 %s %s med=❌(50m) price<=50m_low*%.4f",
                            symbol, signal_side, 1 + EXTREME_NEAR_PCT / 100)
                return False
        if high_close50m > 0 and signal_side == "LONG":
            if current_price >= high_close50m * (1 - EXTREME_NEAR_PCT / 100):
                self._reject_counters["extreme_50m"] += 1
                logger.info("🔍 %s %s med=❌(50m) price>=50m_high*%.4f",
                            symbol, signal_side, 1 - EXTREME_NEAR_PCT / 100)
                return False

        logger.info("🔍 %s %s med=✅ ma7=%.4f 6m=%.2f%%",
                    symbol, signal_side, ma7, change_6m)
        return True

    def _report_pnl(self, pos: dict):
        """估算并记录该笔交易的盈亏（用于日内风控）"""
        prices = self.price_history.get(pos["symbol"], deque())
        mark = prices[-1] if prices else 0
        if mark <= 0:
            return
        if pos["side"] == "LONG":
            gross_pnl = (mark - pos["entry_price"]) * pos["quantity"]
        else:
            gross_pnl = (pos["entry_price"] - mark) * pos["quantity"]
        self._daily_pnl += gross_pnl
        logger.info("📊 PnL 估算: %+.4f U | 日累计: %+.4f U", gross_pnl, self._daily_pnl)
        # 全部平仓后下次用新余额
        if len(self.positions) == 0:
            pass

    # ── 信号扫描 ──

    async def _scan_signals(self):
        """
        扫描所有币种的入场信号。

        信号逻辑:
          1. 价格变动超过 ENTRY_THRESHOLD_PCT (0.3%)
          2. 上涨 → 做多，下跌 → 做空
          3. 使用 mid-price 比较: 最新价 vs 回溯窗口内的基准价
          4. 基准价 = 窗口内的中间价格（去极值后均值），排除瞬时毛刺
        """
        if len(self.positions) >= MAX_POSITIONS:
            return

        # 定时刷新余额
        await self._check_balance()
        if self._total_balance <= 0:
            return

        # 暂停标记（touch /tmp/scalp_pause 暂停新开仓，rm 恢复）
        if os.path.exists(PAUSE_FLAG):
            self._reject_counters["pause"] += self._reject_counters["signal_total"]
            self._reject_counters["signal_total"] = 0
            return

        # 日亏损检查
        if self._daily_pnl <= -MAX_DAILY_LOSS_USDT:
            logger.warning("🛑 日亏损已达上限 %.2fU，停止交易", MAX_DAILY_LOSS_USDT)
            self._running = False
            return

        # ── 从 WS 推送的实时信号队列消费 ──
        signals = list(self._signal_queue)
        self._signal_queue.clear()

        if not signals:
            return

        # 持仓检查（允许同币多空双向；同向已存在则跳过避免覆盖）
        valid = []
        for sym, side, price, change in signals:
            key = f"{sym}_{side}"
            if key in self.positions:
                self._reject_counters["position_exists"] += 1
                continue
            # 同币同向 30s 冷却
            if self._cooldown.get(key, 0) + 30 > time.time():
                self._reject_counters["cooldown"] += 1
                continue

            valid.append((sym, side, price, change))

        # 按偏离幅度排序，取第一个直接入场（无其他过滤条件）
        valid.sort(key=lambda s: abs(s[3]), reverse=True)
        for sym, side, price, change in valid[:1]:
            # 入场前重新验证：当前价位仍满足阈值（WS检测到信号到消费有延迟）
            ba = self.bid_ask.get(sym, {})
            cur_mid = (ba.get("bid1", 0) + ba.get("ask1", 0)) / 2
            ref = self._prev_close.get(sym)
            if cur_mid > 0 and ref and ref > 0:
                cur_change = (cur_mid - ref) / ref * 100
                if abs(cur_change) < ENTRY_THRESHOLD_PCT:
                    logger.info("⏭ %s %s 信号已过期 Δ%+.3f%% (当前Δ%+.3f%%) 跳过",
                                sym, side, change, cur_change)
                    continue
            else:
                cur_change = change  # 无参考价时用原值
            logger.info("🔥 入场 %s %s Δ%+.3f%% (vs prev_close %.4f)",
                        sym, side, cur_change, ref or 0)
            self._reject_counters["entry_total"] += 1
            await self._open_position(sym, side, price)

    # ── 余额检查（每 30 秒刷新一次） ──

    async def _check_balance(self):
        now = time.time()
        if getattr(self, '_last_bal_check', 0) + 30 > now:
            return
        self._last_bal_check = now
        try:
            fresh_balance = await self.executor.get_balance()
            if fresh_balance > 0:
                self._total_balance = fresh_balance
                notional = self._total_balance * LEVERAGE
                logger.info("💰 可用: $%.4f | 全仓名义: $%.2f (20x) | 持仓: %d 笔",
                            self._total_balance, notional, len(self.positions))

            # 锁定基准权益（仅一次，全程不刷新）
            if self._ref_balance <= 0:
                equity = await self.executor.get_total_equity()
                if equity > 0:
                    self._ref_balance = equity
                    logger.info("💰 基准锁定: $%.4f（后续所有仓位都用这个）", equity)
        except Exception:
            pass

    # ── 开单（全仓市价入场） ──

    async def _open_position(self, symbol: str, side: str, price: float):
        """开单 — 限价单入场，用 30s 刷新的动态余额"""
        if symbol not in self.coins:
            return

        if self._total_balance <= 0:
            logger.warning("❌ 余额未就绪，跳过")
            return

        # 设杠杆（已缓存的跳过 REST，节省 ~300ms）
        if symbol not in self._lev_cached:
            lev_result = await self.executor._signed_post("/papi/v1/um/leverage",
                                                           {"symbol": symbol, "leverage": LEVERAGE})
            if isinstance(lev_result, dict) and lev_result.get("_error"):
                logger.warning("⏭ %s 不支持 %dx 杠杆 (%s)，跳过", symbol, LEVERAGE, lev_result.get("msg", ""))
                return
            self._lev_cached.add(symbol)

        # 单仓用当前余额的 90%（动态读取）
        base = self._total_balance
        notional = base * LEVERAGE * POSITION_PCT
        entry_price = price

        qty = notional / entry_price

        # 计算含手续费的 TP/SL
        tp_price = self._calc_tp_price(entry_price, side)
        sl_price = self._calc_sl_price(entry_price, side)

        logger.info(
            "📈 开%s %s 仓%d/%d | 基准=$%.4f 名义=$%.2f(%d%%) qty=%s "
            "tp=%s sl=%s",
            side, symbol, len(self.positions) + 1, MAX_POSITIONS,
            base, notional, int(POSITION_PCT * 100),
            self._fmt_qty(symbol, qty),
            self._fmt_price(symbol, tp_price), self._fmt_price(symbol, sl_price),
        )

        # 最小名义价值检查（Binance 要求 ≥$5）
        if notional < 5.0:
            logger.warning("⏭ %s %s 名义$%.2f<$5，跳过开仓", side, symbol, notional)
            return

        # 限价单入场（吃到同向价1，0.5s 未成交撤单）
        ba = self.bid_ask.get(symbol, {})
        if side == "LONG":
            limit_price = ba.get("ask1", entry_price)  # 买 ask1
        else:
            limit_price = ba.get("bid1", entry_price)  # 卖 bid1

        order_side = "BUY" if side == "LONG" else "SELL"
        exit_side = "SELL" if side == "LONG" else "BUY"
        # 用 limit_price 预估 TP，和真实成交价 ask1/bid1 偏差 < 1 tick，多数情况无需重挂
        preliminary_tp = self._calc_tp_price(limit_price, side)

        # 先入场 → 延时 50ms → 再挂 TP（并行挂 TP 常因仓位未确认被拒）
        entry_task = self.executor.place_order(
            symbol=symbol, side=order_side, quantity=qty,
            order_type="LIMIT", price=limit_price, position_side=side,
        )
        result = await entry_task

        order_id = result.get("orderId") if isinstance(result, dict) else None
        tp_order_id = None
        tp_failed = True

        if order_id and not result.get("_error"):
            # 入场成功，延时 50ms 等仓位确认再挂 TP
            await asyncio.sleep(0.05)
            tp_result = await self.executor.place_order(
                symbol=symbol, side=exit_side, quantity=qty,
                order_type="LIMIT", price=preliminary_tp, position_side=side,
            )
            tp_order_id = tp_result.get("orderId") if isinstance(tp_result, dict) else None
            tp_failed = (not tp_order_id) or (isinstance(tp_result, dict) and tp_result.get("_error"))
            if tp_failed:
                err = tp_result.get("error", str(tp_result)[:100]) if isinstance(tp_result, dict) else str(tp_result)
                logger.warning("⚠️ TP限价单延时挂单失败 %s: %s（入场后会重挂）", symbol, err)

        if order_id and not result.get("_error"):
            # 先检查下单返回是否已直接成交
            filled_price = None
            status = result.get("status", "")
            if status in ("FILLED", "PARTIALLY_FILLED"):
                filled_price = float(result.get("avgPrice", 0))
                logger.info("⚡ %s %s 限价单立即%s @%s", side, symbol,
                            "全部成交" if status == "FILLED" else "部分成交",
                            self._fmt_price(symbol, filled_price))
                # 部分成交时更新实际数量
                if status == "PARTIALLY_FILLED":
                    exec_qty = float(result.get("executedQty", result.get("cumQty", 0)))
                    if exec_qty > 0:
                        qty = exec_qty
            else:
                # 未立即成交，轮询等 1s
                filled_price = await self._wait_fill(symbol, order_id, timeout=1.0)
            if filled_price is None or filled_price <= 0:
                # 入场未成交：撤入场 + 撤 TP
                await self.executor._rest_cancel_order(symbol, order_id)
                if tp_order_id:
                    await self.executor._rest_cancel_order(symbol, tp_order_id)
                logger.info("⏰ %s %s 限价单未成交，已撤入场+TP", side, symbol)
                return

            # ── 撤掉未成交部分，从交易所查真实仓位 ──
            await self.executor._rest_cancel_order(symbol, order_id)

            # 查交易所实际持仓
            actual_qty = 0.0
            actual_entry = filled_price
            try:
                pos_list = await self.executor.get_positions()
                for p in pos_list:
                    if p["symbol"] == symbol and p["side"] == side:
                        actual_qty = p["quantity"]
                        actual_entry = p["entry_price"]
                        break
            except Exception as e:
                logger.warning("⚠️ 查持仓失败 %s: %s，用估算数据", symbol, e)

            if actual_qty <= 0:
                # 查仓位失败？用成交数据兜底
                actual_qty = qty
                actual_entry = filled_price
                logger.warning("⚠️ %s %s 未查到仓位，用成交数据 qty=%s @%s",
                               side, symbol,
                               self._fmt_qty(symbol, qty),
                               self._fmt_price(symbol, filled_price))
                # 再等 0.3s 重试一次
                await asyncio.sleep(0.3)
                try:
                    pos_list = await self.executor.get_positions()
                    for p in pos_list:
                        if p["symbol"] == symbol and p["side"] == side:
                            actual_qty = p["quantity"]
                            actual_entry = p["entry_price"]
                            break
                except Exception:
                    pass

            # 用实际仓位数据重算 TP/SL
            entry_price = actual_entry
            qty = actual_qty
            tp_price = self._calc_tp_price(entry_price, side)
            sl_price = self._calc_sl_price(entry_price, side)

            key = f"{symbol}_{side}"
            self.positions[key] = {
                "symbol": symbol, "side": side,
                "entry_price": entry_price, "quantity": qty,
                "tp_price": tp_price, "sl_price": sl_price,
                "open_time": time.time(),
            }
            logger.info(
                "✅ %s %s 实际仓位 qty=%s @%s tp=%s sl=%s",
                side, symbol, self._fmt_qty(symbol, qty),
                self._fmt_price(symbol, entry_price),
                self._fmt_price(symbol, tp_price),
                self._fmt_price(symbol, sl_price),
            )

            # ── TP 单核对：偏差大或数量不一致就撤掉重挂 ──
            tick = self.executor.precision_cache.get(symbol, {}).get("tickSize", 0) if hasattr(self.executor, "precision_cache") else 0
            price_drift = abs(tp_price - preliminary_tp)
            qty_drift = abs(qty - notional / entry_price)
            need_replace = (
                tp_failed
                or (tick > 0 and price_drift > tick)
                or (tick == 0 and price_drift / tp_price > 0.0001)  # 0.01% 兜底
                or qty_drift / max(qty, 1e-9) > 0.001
            )

            if need_replace:
                if tp_order_id:
                    await self.executor._rest_cancel_order(symbol, tp_order_id)
                tp_result = await self.executor.place_order(
                    symbol=symbol, side=exit_side, quantity=qty,
                    order_type="LIMIT", price=tp_price, position_side=side,
                )
                tp_order_id = tp_result.get("orderId") if isinstance(tp_result, dict) else None

            if tp_order_id and not (isinstance(tp_result, dict) and tp_result.get("_error")):
                self._pending_tp_exits[key] = {
                    "order_id": tp_order_id, "symbol": symbol, "side": side,
                    "tp_price": tp_price, "quantity": qty, "type": "TP",
                }
                logger.info("📋 TP限价单%s %s %s id=%s @%s",
                            "已重挂" if need_replace else "已挂(50ms延时)",
                            side, symbol, tp_order_id,
                            self._fmt_price(symbol, tp_price))
            else:
                err = tp_result.get("error", str(tp_result)[:100]) if isinstance(tp_result, dict) else str(tp_result)
                logger.warning("⚠️ TP限价单挂单失败 %s: %s", symbol, err)
        else:
            # 入场单挂单失败（TP 未挂，无需清理）
            err = result.get("error", result.get("msg", str(result)[:100]))
            logger.warning("❌ %s %s 开单失败: %s", side, symbol, err)

    # ── 等待成交 ──

    async def _wait_fill(self, symbol: str, order_id: str, timeout: float = 0.5) -> float | None:
        """轮询订单状态，返回成交均价或 None（超时取消）
        接受 FILLED 和 PARTIALLY_FILLED（深度不够时部分成交也算）"""
        deadline = time.time() + timeout
        while time.time() < deadline:
            try:
                result = await self.executor._signed_get("/papi/v1/um/order", {
                    "symbol": symbol, "orderId": order_id,
                })
                status = result.get("status", "")
                if status in ("FILLED", "PARTIALLY_FILLED"):
                    return float(result.get("avgPrice", 0))
                if result.get("simulated"):
                    return 0.0
            except Exception:
                pass
            await asyncio.sleep(0.1)
        return None

    # ── 平仓 ──

    async def _close_and_clean(self, key: str, pos: dict):
        """WS触发止损：立即平仓（不等待撤TP），完成后后台清理TP单"""
        if key in getattr(self, '_closing', set()):
            return
        if not hasattr(self, '_closing'):
            self._closing = set()
        self._closing.add(key)
        try:
            if key not in self.positions:
                return
            # 立即平仓（不先撤TP，省 ~100ms REST 往返）
            await self._close_position(pos["symbol"], pos["side"], pos["quantity"])
            self._report_pnl(pos)
            # 平仓后再撤 TP（后台任务，不阻塞）
            if key in self._pending_tp_exits:
                asyncio.create_task(self._cancel_pending_tp(key))
        finally:
            self._closing.discard(key)

    async def _close_position(self, symbol: str, side: str, qty: float):
        """市价平仓"""
        close_side = "SELL" if side == "LONG" else "BUY"
        key = f"{symbol}_{side}"
        logger.info("🔴 平%s %s qty=%s", side, symbol, self._fmt_qty(symbol, qty))

        result = await self.executor.place_order(
            symbol=symbol,
            side=close_side,
            quantity=qty,
            order_type="MARKET",
            position_side=side,
        )

        order_id = result.get("orderId") if isinstance(result, dict) else None
        self._cooldown[key] = time.time()  # 无论成败都设 30s 冷却
        if order_id and not result.get("_error"):
            pos = self.positions.pop(key, None)
            if pos:
                # 从成交价算盈亏
                avg_price = float(result.get("avgPrice", 0))
                if avg_price > 0:
                    if side == "LONG":
                        gross_pnl = (avg_price - pos["entry_price"]) * pos["quantity"]
                    else:
                        gross_pnl = (pos["entry_price"] - avg_price) * pos["quantity"]
                    self._daily_pnl += gross_pnl
                    logger.info(
                        "✅ 平%s %s 成功 | 入场 %s → 出场 %s | PnL %+.4fU | 日累计 %+.4fU",
                        side, symbol,
                        self._fmt_price(symbol, pos["entry_price"]),
                        self._fmt_price(symbol, avg_price),
                        gross_pnl, self._daily_pnl,
                    )
                else:
                    logger.info("✅ 平%s %s 成功 id=%s", side, symbol, order_id)
        else:
            err = result.get("error", result.get("msg", str(result)[:100]))
            logger.warning("❌ 平%s %s 失败: %s", side, symbol, err)

    # ── 工具函数 ──

    def _fmt_price(self, symbol: str, price: float) -> str:
        """按精度格式化价格"""
        tick = self.executor._tick_size.get(symbol, 0.01)
        decimals = max(0, int(round(-math.log10(tick) + 0.5)))
        return f"{price:.{decimals}f}"

    def _fmt_qty(self, symbol: str, qty: float) -> str:
        """按精度格式化数量"""
        step = self.executor._step_size.get(symbol, 0.001)
        decimals = max(0, int(round(-math.log10(step) + 0.5)))
        return f"{qty:.{decimals}f}"

    def _log_filter_diagnostic(self):
        """每 10s 输出过滤器拒绝详情"""
        c = self._reject_counters
        total = c["signal_total"]
        if total == 0:
            logger.info("🔍 过滤诊断 [10s] 信号=0 (无波动触发)")
            return
        entry = c["entry_total"]

        # 过滤器归因（按挡掉数量降序）
        items = [
            ("趋势(短期Tick)", c["trend"]),
            ("均值回归(>0.35%)", c["mean_reversion"]),
            ("K线方向", c["kline"]),
            ("MA7方向", c["ma7"]),
            ("6min偏离(>3%)", c["change_6m"]),
            ("10m/50m极值", c["extreme_50m"]),
            ("已有持仓", c["position_exists"]),
            ("冷却中(30s)", c["cooldown"]),
            ("暂停(/tmp/scalp_pause)", c["pause"]),
        ]
        items.sort(key=lambda x: x[1], reverse=True)

        rejected = total - entry
        pass_rate = entry / total * 100 if total > 0 else 0

        lines = [f"🔍 过滤诊断 [10s]"]
        lines.append(f"   信号={total}  入场={entry}  拒绝={rejected}  通过率={pass_rate:.1f}%")
        for name, n in items:
            if n > 0:
                pct = n / total * 100
                bar = "█" * max(1, int(pct / 2))
                lines.append(f"   {name:22s} {bar} {n:>4} ({pct:5.1f}%)")

        logger.info("\n".join(lines))

        # 归零
        for k in c:
            c[k] = 0

    # ── 主循环 ──

    async def _main_loop(self):
        """高频主循环 — 200ms 间隔"""
        while self._running:
            loop_start = time.time()

            try:
                await self._check_pending_tp()
                await self._check_sl()
                await self._check_hold_timeout()
                await self._scan_signals()
                self._loop_count += 1
                # 每 10 个循环 (~2s) 巡检 TP 限价单是否丢了
                if self._loop_count % 10 == 0:
                    await self._check_tp_health()
                # 每 150 个循环 (~30s) 同步一次持仓
                if self._loop_count % 150 == 0:
                    await self._sync_positions()
                # 每 50 个循环 (~10s) 输出过滤器诊断
                if self._loop_count % 50 == 0:
                    self._log_filter_diagnostic()
            except Exception as e:
                logger.exception("循环异常: %s", e)

            elapsed = time.time() - loop_start
            await asyncio.sleep(max(0, LOOP_INTERVAL - elapsed))

    # ── 状态概览 (每 10 秒) ──

    async def _status_summary(self):
        """定期输出状态概览"""
        while self._running:
            await asyncio.sleep(10)
            if self.positions:
                lines = [f"📊 持仓 {len(self.positions)} 笔:"]
                for key, pos in sorted(self.positions.items()):
                    prices = self.price_history.get(pos["symbol"], deque())
                    mark = prices[-1] if prices else 0
                    if mark > 0:
                        if pos["side"] == "LONG":
                            pnl = (mark - pos["entry_price"]) / pos["entry_price"] * 100 * LEVERAGE
                        else:
                            pnl = (pos["entry_price"] - mark) / pos["entry_price"] * 100 * LEVERAGE
                        lines.append(
                            f"  {pos['symbol']} {pos['side']} "
                            f"@ {self._fmt_price(pos['symbol'], pos['entry_price'])} "
                            f"→ {self._fmt_price(pos['symbol'], mark)} "
                            f"({pnl:+.1f}%保) | "
                            f"TP@{self._fmt_price(pos['symbol'], pos['tp_price'])} "
                            f"SL@{self._fmt_price(pos['symbol'], pos['sl_price'])}"
                        )
                    else:
                        lines.append(f"  {pos['symbol']} {pos['side']} (待价)")
                logger.info("\n" + "\n".join(lines))
            else:
                pause_tag = " ⏸暂停" if os.path.exists(PAUSE_FLAG) else ""
                logger.info(
                    "📊 无持仓 | 余额≈$%.2f | 日PnL %+.4fU | %d 币监控中%s",
                    self._total_balance, self._daily_pnl, len(self.coins), pause_tag,
                )


# ============================================================
# 启动
# ============================================================
async def main():
    engine = ScalpEngine()
    # 同时跑状态监控
    status_task = asyncio.create_task(engine._status_summary())
    try:
        await engine.run()
    finally:
        status_task.cancel()


if __name__ == "__main__":
    asyncio.run(main())
