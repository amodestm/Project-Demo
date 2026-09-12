#!/usr/bin/env python3
"""
=========================================
triangle_crash_scanner.py — 箱体震荡砸盘反转扫描器
=========================================
模式: 箱体横盘震荡 → 暴力下杀 → V反拉升
数据: 1min K线 (全部检测)
范围: 全市场 USDT 交易对 (~604个)
=========================================
"""

import asyncio
import json
import os
import time
import logging
from collections import deque, defaultdict
from typing import Optional

import aiohttp
from aiohttp_socks import ProxyConnector

# ============================================================
# 参数
# ============================================================
RANGE_BOX_BARS = 120                # 箱体检测窗口 (1min * 120 = 2h)  
RANGE_MAX_PCT = 2.3                # 箱体震荡最大振幅 (%) — (高-低)/高

# 三浪下跌检测参数
THREE_WAVE_LOOKBACK = 100           # 检测尾部多少根 K 线
THREE_WAVE_MIN_DROP = 0.15          # 每浪最低跌幅 (%)
THREE_WAVE_MIN_WAVES = 2            # 最少浪数
THREE_WAVE_TAIL_BARS = 15           # 最后一浪必须在此K线内 (靠近当前时间)
RANGE_MIN_PCT = 1.0                 # 箱体最小振幅 (%)
RANGE_DURATION_BARS = 45            # 至少在此范围内震荡 45 根 1min K 线 (45min)
CRASH_DROP_PCT = 3.0                # 砸盘跌幅阈值 (%) 
CRASH_IDEAL_PCT = 5.0               # 理想砸盘幅度 (%)
CRASH_WINDOW_MINUTES = 10           # 砸盘检测窗口 (分钟)
VOL_SPIKE_MULT = 2.0                # 量能放大倍数
REVERSAL_RISE_PCT = 1.0             # 反转回升阈值 (%)
REVERSAL_NO_NEW_LOW_BARS = 2        # 不再创新低的K线数
BREAKOUT_THRESHOLD = 1.0            # 向上突破阈值 (%) — 超过箱体上沿即告警
QUICK_DROP_PCT = 5.0               # 独立暴跌检测: 20分钟内跌超 (%) 
QUICK_DROP_BARS = 20               # 暴跌检测窗口 (根 1min K线)

WS_URL = "wss://fstream.binance.com/stream"

# 代理候选：优先环境变量，否则探测本地常见代理端口
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
    return _CANDIDATE_PROXIES[0]  # 全失败仍返回第一个，报错由后续连接暴露


PROXY = _detect_proxy()

logging.basicConfig(level=logging.INFO, format="%(asctime)s [%(levelname)s] %(message)s",
                    datefmt="%H:%M:%S")
logger = logging.getLogger("crash-scanner")

# 状态输出文件
ALERT_FILE = "/tmp/triangle_crash.json"
ALERT_HISTORY = deque(maxlen=2000)  # 全部告警

# ============================================================
# 数据结构
# ============================================================

class CoinState:
    """单币种扫描状态"""
    def __init__(self, symbol: str):
        self.symbol = symbol
        # 1min K线 (横盘检测 + 砸盘/反转) — 存 (high, low, close, volume)
        self.k1: deque = deque(maxlen=RANGE_BOX_BARS)
        self.k1_open_time = 0
        self.k1_high = 0.0
        self.k1_low = float("inf")
        self.k1_close = 0.0
        self.k1_volume = 0.0
        # 箱体震荡状态
        self.range_detected = False
        self.range_high = 0.0
        self.range_low = 0.0
        self.range_bars = 0
        self.range_start_ts = 0.0
        self.range_bar_offset = 0
        self.has_three_wave = False     # 优秀判定：尾部三浪下跌
        # 砸盘状态
        self.crash_detected = False
        self.crash_high_price = 0.0
        self.crash_low_price = 0.0
        self.crash_bars_since = 0
        # 反转
        self.reversal_alerted = False
        self.breakout_alerted = False   # 向上突破告警
        self.quick_drop_alerted = False  # 十分钟暴跌告警

    def reset_detection(self):
        self.range_detected = False
        self.crash_detected = False
        self.reversal_alerted = False


# ============================================================
# 工具函数
# ============================================================

def check_range_oscillation(state: CoinState) -> bool:
    """
    从当前K线往前数，有多少分钟连续在 1.5%~3% 振幅内震荡。
    ≥ RANGE_DURATION_BARS (45min) 即判定为箱体。
    """
    bar_count = min(len(state.k1), RANGE_BOX_BARS)
    if bar_count < RANGE_DURATION_BARS:
        return False

    bars = list(state.k1)[-bar_count:]

    # 从最后一根往前找连续在振幅范围内的K线
    count = 0
    range_high = 0.0
    range_low = float("inf")
    for i in range(bar_count - 1, -1, -1):  # 倒序：从现在开始
        h, l, c, _ = bars[i]
        range_high = max(range_high, h)
        range_low = min(range_low, l)
        if range_high <= 0:
            break
        amp = (range_high - range_low) / range_high * 100
        if amp <= RANGE_MAX_PCT:
            count += 1
        else:
            break  # 超出振幅上限，停止

    if count < RANGE_DURATION_BARS:
        return False

    # 最终振幅 ≥ RANGE_MIN_PCT (最高-最低)/最高 ≥ 1.5%
    if range_high <= 0:
        return False
    final_amp = (range_high - range_low) / range_high * 100
    if final_amp < RANGE_MIN_PCT:
        return False

    # 取这 count 根计算
    valid_bars = bars[bar_count - count:]
    highs = [c[0] for c in valid_bars]
    lows = [c[1] for c in valid_bars]
    closes = [c[2] for c in valid_bars]
    range_high = max(highs)
    range_low = min(lows)

    # 不是单边趋势
    if closes[0] > 0:
        trend_pct = abs(closes[-1] - closes[0]) / closes[0] * 100
        amp = (range_high - range_low) / range_high * 100
        if trend_pct > amp * 0.7:
            return False

    # 至少在中线上下穿越一次（确认不是单边或死市）
    mid = (range_high + range_low) / 2
    crosses = 0
    above = closes[0] > mid
    for c in closes[1:]:
        now = c > mid
        if now != above:
            crosses += 1
            above = now
    if crosses < 2:
        return False

    state.range_high = range_high
    state.range_low = range_low
    state.range_bars = count
    state.range_start_ts = time.time() - count * 60
    state.range_bar_offset = len(state.k1)
    state.has_three_wave = check_three_wave_drop(state)
    return True


def check_three_wave_drop(state: CoinState) -> bool:
    """检测箱体尾部是否出现三浪下跌 — 最后一浪必须靠近当前时间"""
    if len(state.k1) < 30:
        return False
    bars = list(state.k1)[-THREE_WAVE_LOOKBACK:]
    lows = [c[1] for c in bars]
    closes = [c[2] for c in bars]
    valleys = []  # (bar_index, low_price)
    in_drop = False
    drop_start = 0
    drop_low_idx = 0
    for i in range(1, len(bars)):
        if lows[i] < lows[i - 1] and not in_drop:
            in_drop = True
            drop_start = i - 1
            drop_low_idx = i
        elif lows[i] >= lows[i - 1] and in_drop:
            if closes[drop_start] > 0:
                drop_pct = (closes[drop_start] - lows[drop_low_idx]) / closes[drop_start] * 100
                if drop_pct >= THREE_WAVE_MIN_DROP:
                    valleys.append((drop_low_idx, lows[drop_low_idx]))
            in_drop = False
        elif lows[i] < lows[drop_low_idx] and in_drop:
            drop_low_idx = i
    if in_drop and closes[drop_start] > 0:
        drop_pct = (closes[drop_start] - lows[drop_low_idx]) / closes[drop_start] * 100
        if drop_pct >= THREE_WAVE_MIN_DROP:
            valleys.append((drop_low_idx, lows[drop_low_idx]))
    if len(valleys) < THREE_WAVE_MIN_WAVES:
        return False
    # 低点逐步下降
    for i in range(1, len(valleys)):
        if valleys[i][1] >= valleys[i-1][1]:
            return False
    # 最后一浪必须在最近 THREE_WAVE_TAIL_BARS 根K线内
    last_valley_idx = valleys[-1][0]
    if len(bars) - last_valley_idx > THREE_WAVE_TAIL_BARS:
        return False
    return True


def check_crash(state: CoinState) -> Optional[tuple]:
    """
    检查是否砸盘 — 仅分析箱体确认后的 K 线。
    从箱体上沿跌破 3%+ 且量能放大
    """
    if len(state.k1) < 5:
        return None

    bars = list(state.k1)
    # 只看箱体确认之后的 K 线
    start_idx = state.range_bar_offset
    if start_idx >= len(bars):
        return None
    post_range = bars[start_idx:]
    if len(post_range) < 3:
        return None

    # 箱体上沿作为参考高点
    peak_high = state.range_high
    valley_low = min(b[1] for b in post_range)

    if peak_high <= 0:
        return None

    drop_pct = (peak_high - valley_low) / peak_high * 100
    if drop_pct < CRASH_DROP_PCT:
        return None

    # 量能放大：最近2根 vs 箱体期间平均
    recent_vol = sum(b[3] for b in post_range[-2:])
    range_bars = bars[start_idx - state.range_bars:start_idx]
    avg_range_vol = sum(b[3] for b in range_bars) / max(len(range_bars), 1)
    if avg_range_vol > 0 and recent_vol / max(avg_range_vol * 4, 0.0001) < VOL_SPIKE_MULT:
        return None

    return (round(drop_pct, 2), valley_low, peak_high)


def check_reversal(state: CoinState, current_close: float) -> float:
    """检查反转：不再创新低 + 回升。返回回升%，<0 表示未触发"""
    if not state.crash_detected:
        return -1

    state.crash_bars_since += 1

    if current_close < state.crash_low_price:
        state.crash_low_price = current_close
        state.crash_bars_since = 0
        return -1

    if state.crash_bars_since < REVERSAL_NO_NEW_LOW_BARS:
        return -1

    rise = (current_close - state.crash_low_price) / state.crash_low_price * 100
    if rise >= REVERSAL_RISE_PCT:
        return round(rise, 2)
    return -1


# ============================================================
# 主扫描逻辑
# ============================================================

class TriangleCrashScanner:
    def __init__(self):
        self.session: aiohttp.ClientSession = None
        self.coins: list[str] = []
        self.states: dict[str, CoinState] = {}
        self.volumes: dict[str, float] = {}  # 24h 成交量
        self._ws = None
        self._running = False
        self._last_scan = 0.0

    async def start(self):
        """启动扫描器"""
        connector = ProxyConnector.from_url(PROXY)
        self.session = aiohttp.ClientSession(connector=connector)
        self._running = True

        # 1. 筛选币种
        await self._select_coins()
        if not self.coins:
            logger.error("❌ 没有符合条件的币种")
            return
        logger.info(f"📊 监控范围: {len(self.coins)} 币种")

        # 立即写入初始状态（让UI知道扫描器在运行）
        self._flush_alerts()

        # 2. 初始加载 15min K 线
        await self._load_initial_klines()
        self._flush_alerts()  # K线加载完后更新

        # 3. 启动 WebSocket + 主循环
        ws_task = asyncio.create_task(self._ws_listen())
        scan_task = asyncio.create_task(self._scan_loop())

        try:
            await asyncio.gather(ws_task, scan_task)
        except asyncio.CancelledError:
            pass
        finally:
            self._running = False
            if self.session:
                await self.session.close()

    async def _select_coins(self):
        """筛选全市场 USDT 交易对"""
        try:
            async with self.session.get(
                "https://fapi.binance.com/fapi/v1/ticker/24hr", timeout=15
            ) as resp:
                if resp.status == 200:
                    for t in await resp.json():
                        if not isinstance(t, dict):
                            continue
                        symb = t.get("symbol", "")
                        if symb.endswith("USDT"):
                            self.coins.append(symb)
                            self.states[symb] = CoinState(symb)
                            self.volumes[symb] = float(t.get("quoteVolume", 0))
        except Exception as e:
            logger.warning(f"获取币种列表失败: {e}")
            return

        logger.info(f"✓ 全市场监控: {len(self.coins)} 币")

    async def _load_initial_klines(self):
        """REST 加载初始 1min K 线数据 (最近6h)"""
        logger.info("⏳ 加载初始 1min K线...")
        tasks = []
        sem = asyncio.Semaphore(50)

        async def _load(sym):
            async with sem:
                try:
                    async with self.session.get(
                        f"https://fapi.binance.com/fapi/v1/klines",
                        params={"symbol": sym, "interval": "1m", "limit": RANGE_BOX_BARS},
                        timeout=10,
                    ) as resp:
                        if resp.status == 200:
                            data = await resp.json()
                            state = self.states[sym]
                            for k in data:
                                state.k1.append((
                                    float(k[2]),  # high
                                    float(k[3]),  # low
                                    float(k[4]),  # close
                                    float(k[5]),  # volume
                                ))
                except Exception:
                    pass

        for sym in self.coins:
            tasks.append(_load(sym))

        await asyncio.gather(*tasks)
        # 初始化 k1_close (REST 加载后 WS 可能还没数据)
        for sym, state in self.states.items():
            if len(state.k1) > 0 and state.k1_close == 0:
                state.k1_close = state.k1[-1][2]
        loaded = sum(1 for s in self.states.values() if len(s.k1) > 0)
        logger.info(f"✓ 初始K线加载: {loaded}/{len(self.coins)} 币")

    async def _ws_listen(self):
        """WebSocket 监听 1min K 线 (实时)"""
        # 构造组合流 (50 币/连接, 分批)
        batch_size = 50
        batches = [self.coins[i:i+batch_size] for i in range(0, len(self.coins), batch_size)]

        async def _connect(batch):
            streams = [f"{s.lower()}@kline_1m" for s in batch]
            url = f"{WS_URL}?streams={'/'.join(streams)}"
            while self._running:
                try:
                    async with self.session.ws_connect(url, timeout=30) as ws:
                        async for msg in ws:
                            if msg.type != aiohttp.WSMsgType.TEXT:
                                break
                            data = json.loads(msg.data)
                            stream = data.get("stream", "")
                            sym = stream.split("@")[0].upper()
                            k = data.get("data", {}).get("k", {})
                            if not sym or not k:
                                continue
                            self._on_1m_kline(sym, k)
                    logger.warning(f"WS 断开 ({len(batch)}币), 重连...")
                except Exception as e:
                    logger.warning(f"WS 异常: {e}, 5s后重连...")
                await asyncio.sleep(5)

        tasks = [asyncio.create_task(_connect(b)) for b in batches]
        await asyncio.gather(*tasks)

    def _on_1m_kline(self, sym: str, k: dict):
        """处理 1min K 线推送"""
        state = self.states.get(sym)
        if not state:
            return

        high = float(k.get("h", 0))
        low = float(k.get("l", 0))
        close = float(k.get("c", 0))
        volume = float(k.get("v", 0))
        is_closed = k.get("x", False)
        open_time = k.get("t", 0)

        # 更新 1min K 线
        if open_time != state.k1_open_time:
            if state.k1_open_time > 0:
                # 上一根闭合，存入
                state.k1.append((
                    state.k1_high, state.k1_low,
                    state.k1_close, state.k1_volume
                ))
            state.k1_open_time = open_time
            state.k1_high = high
            state.k1_low = low
            state.k1_close = close
            state.k1_volume = volume
        else:
            state.k1_high = max(state.k1_high, high)
            state.k1_low = min(state.k1_low, low)
            state.k1_close = close
            state.k1_volume += volume

    async def _scan_loop(self):
        """定期扫描箱体震荡 (每1秒)"""
        await asyncio.sleep(10)  # 等K线数据积累
        logger.info("🔍 开始扫描 1min 箱体震荡...")
        self._flush_alerts()
        while self._running:
            for sym, state in list(self.states.items()):
                if len(state.k1) < QUICK_DROP_BARS:
                    continue
                try:
                    self._scan_coin(state)
                except Exception:
                    pass
            self._flush_alerts()
            await asyncio.sleep(1)

    def _scan_coin(self, state: CoinState):
        """扫描单个币种 (1min 箱体检测)"""
        # ══════ 独立暴跌检测：20分钟内跌超5% (不依赖箱体) ══════
        if not state.quick_drop_alerted and len(state.k1) >= QUICK_DROP_BARS:
            bars = list(state.k1)[-QUICK_DROP_BARS:]
            start_price = bars[0][2]  # 10分钟前收盘价
            end_price = bars[-1][2]   # 当前收盘价
            if start_price > 0 and end_price > 0:
                drop_pct = (start_price - end_price) / start_price * 100
                if drop_pct >= QUICK_DROP_PCT:
                    lowest = min(b[1] for b in bars)
                    state.quick_drop_alerted = True
                    alert = {
                        "type": "quick_drop", "sym": state.symbol,
                        "msg": f"急跌 -{drop_pct:.1f}% 20min {start_price:.6f}→{end_price:.6f} 低{lowest:.6f}",
                        "time": time.strftime("%H:%M:%S"), "ts": time.time(),
                    }
                    ALERT_HISTORY.append(alert)
                    logger.warning(f"⚡急跌 {alert['msg']}")

        # 阶段1: 箱体震荡
        if not state.range_detected:
            if check_range_oscillation(state):
                state.range_detected = True
                dur_min = state.range_bars
                dur_str = f"{dur_min // 60}h{dur_min % 60}m" if dur_min >= 60 else f"{dur_min}m"
                amp = (state.range_high - state.range_low) / state.range_high * 100
                alert = {
                    "type": "range", "sym": state.symbol,
                    "duration": dur_min,
                    "dur_str": dur_str,
                    "quality": "⭐优秀" if state.has_three_wave else "",
                    "volume": self.volumes.get(state.symbol, 0),
                    "msg": f"箱体震荡 {dur_str} 振幅{amp:.1f}% [{('⭐三浪' if state.has_three_wave else '')}{state.range_low:.6f}~{state.range_high:.6f}]",
                    "time": time.strftime("%H:%M:%S"), "ts": time.time(),
                }
                ALERT_HISTORY.append(alert)
                logger.info(f"📐 箱体: {state.symbol} {alert['msg']}")
            return

        # 箱体确认后：持续更新时长（价格仍在区间内）
        if state.range_detected and not state.crash_detected and not state.breakout_alerted:
            current = state.k1_close if state.k1_close > 0 else state.k1[-1][2]
            if current > 0 and state.range_high > 0:
                # 价格是否仍在箱体内
                in_range = state.range_low * 0.99 <= current <= state.range_high * 1.01
                if in_range:
                    # 仍在箱体内，更新持续时长
                    bars_since = len(state.k1) - state.range_bar_offset
                    if bars_since > 0:
                        state.range_bars += bars_since  # 累积时长
                        state.range_bar_offset = len(state.k1)
                        dur_min = state.range_bars
                        dur_str = f"{dur_min // 60}h{dur_min % 60}m" if dur_min >= 60 else f"{dur_min}m"
                        # 更新最近一条 range 告警的时长
                        for a in reversed(ALERT_HISTORY):
                            if a["type"] == "range" and a["sym"] == state.symbol:
                                a["duration"] = dur_min
                                a["dur_str"] = dur_str
                                amp = (state.range_high - state.range_low) / state.range_high * 100
                                a["msg"] = f"箱体震荡 {dur_str} 振幅{amp:.1f}% [{('⭐三浪' if state.has_three_wave else '')}{state.range_low:.6f}~{state.range_high:.6f}]"
                                break
                # 如果跑出箱体超过2%且没触发突破，可能是下砸，等阶段2处理

        # 阶段2: 向上突破检测
        if not state.breakout_alerted:
            current = state.k1_close if state.k1_close > 0 else state.k1[-1][2]
            if current > 0 and state.range_high > 0:
                breakout_pct = (current - state.range_high) / state.range_high * 100
                if breakout_pct >= BREAKOUT_THRESHOLD:
                    state.breakout_alerted = True
                    alert = {
                        "type": "breakout", "sym": state.symbol,
                        "msg": f"向上突破箱体+{breakout_pct:.1f}% 上沿{state.range_high:.6f}→当前{current:.6f} 建议做多",
                        "time": time.strftime("%H:%M:%S"), "ts": time.time(),
                    }
                    ALERT_HISTORY.append(alert)
                    logger.warning(f"🚀 {alert['msg']}")

        # 阶段3: 砸盘 (实时价格 + K线双确认)
        if not state.crash_detected:
            crash_triggered = False
            drop = 0.0
            low = 0.0
            high = state.range_high

            # 方法1: 实时价格检测 (当前未闭合K线的close)
            current = state.k1_close if state.k1_close > 0 else state.k1[-1][2]
            if current > 0 and state.range_high > 0:
                rt_drop = (state.range_high - current) / state.range_high * 100
                if rt_drop >= CRASH_DROP_PCT:
                    crash_triggered = True
                    drop = rt_drop
                    low = current
                    logger.info(f"⚡实时砸盘 {state.symbol} -{drop:.1f}% 当前{current:.6f}")

            # 方法2: 已闭合K线检测
            if not crash_triggered:
                result = check_crash(state)
                if result:
                    drop, low, _ = result
                    crash_triggered = True

            if crash_triggered:
                state.crash_detected = True
                state.crash_high_price = high
                state.crash_low_price = low
                state.crash_bars_since = 0
                ideal = " ⚡理想爆多" if drop >= CRASH_IDEAL_PCT else ""
                alert = {
                    "type": "crash", "sym": state.symbol,
                    "msg": f"砸盘 -{drop:.1f}% 高{high:.6f}→低{low:.6f}{ideal}",
                    "time": time.strftime("%H:%M:%S"), "ts": time.time(),
                }
                ALERT_HISTORY.append(alert)
                logger.warning(f"💥 {alert['msg']}")
            return

        # 阶段3: 反转
        if not state.reversal_alerted:
            current = state.k1_close if state.k1_close > 0 else state.k1[-1][2]
            rise = check_reversal(state, current)
            if rise > 0:
                state.reversal_alerted = True
                alert = {
                    "type": "reversal", "sym": state.symbol,
                    "msg": f"砸盘后回升+{rise:.1f}% 当前{current:.6f} 建议做多(20x)",
                    "time": time.strftime("%H:%M:%S"), "ts": time.time(),
                }
                ALERT_HISTORY.append(alert)
                logger.warning(f"🔥 {alert['msg']}")
                state.reset_detection()

    def _flush_alerts(self):
        """写入告警JSON（含三阶段状态）"""
        try:
            range_count = sum(1 for s in self.states.values() if s.range_detected)
            crash_count = sum(1 for s in self.states.values() if s.crash_detected)
            rev_count = sum(1 for a in ALERT_HISTORY if a["type"] == "reversal")
            brk_count = sum(1 for s in self.states.values() if s.breakout_alerted)
            qd_count  = sum(1 for s in self.states.values() if s.quick_drop_alerted)

            # 告警列表
            alerts_out = list(ALERT_HISTORY)

            with open(ALERT_FILE, "w") as f:
                json.dump({
                    "monitored": len(self.coins),
                    "range_count": range_count,
                    "crash_count": crash_count,
                    "reversal_count": rev_count,
                    "breakout_count": brk_count,
                    "quick_drop_count": qd_count,
                    "alerts": alerts_out,
                    "updated": time.strftime("%H:%M:%S"),
                }, f)
        except Exception:
            pass


# ============================================================
# 入口
# ============================================================

async def main():
    scanner = TriangleCrashScanner()
    await scanner.start()


if __name__ == "__main__":
    asyncio.run(main())
