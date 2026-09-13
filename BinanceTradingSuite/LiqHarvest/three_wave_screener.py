#!/usr/bin/env python3
"""
三浪下跌扫描器 (Three-Wave Decline Screener) — 开空优化版
===========================================================

扫描所有 USDT 交易对的 K 线数据，识别三浪下跌形态，专为开空单优化：

  浪1: H1(高点) → L1(低点)    — 第一波下跌
  浪2: L1 → H2(反弹高点)       — 反弹不过前高  (H2 < H1)
  浪3: H2 → L2(新低)           — 下跌破前低    (L2 < L1)

开空优化评分:
  趋势面  (35): MA20/MA50 空头排列、死叉
  动能面  (30): 跌幅幅度、浪3加速、放量下跌
  结构面  (25): 浅回撤(强势下跌)、形态新鲜度
  确认面  (10): RSI 无底背离(下跌动量未衰竭)
  拉升加分(15): 前期拉升(冲高回落更适合空)
  高点质量(15): H1 必须是近期最高点(刚从高点下来)

信号等级: S(>=80 强烈看空) / A(>=60 看空) / B(>=40 偏空) / C(<40 弱信号)

用法:
  python3 -m binance_liq_harvest.three_wave_screener
  python3 -m binance_liq_harvest.three_wave_screener --timeframe 15m --top 20
  python3 -m binance_liq_harvest.three_wave_screener --min-score 50 --no-proxy
"""

import argparse
import asyncio
import logging
import os
import sys
import time
from dataclasses import dataclass, field
from typing import Any, Dict, List, Optional, Tuple

import aiohttp
from aiohttp_socks import ProxyConnector

from . import config

# ── 日志 ──
logger = logging.getLogger(__name__)

# ── 常量 ──
BINANCE_KLINE_URL = "https://fapi.binance.com/fapi/v1/klines"
MAX_CONCURRENT = 15           # 并发请求数
RSI_PERIOD = 14               # RSI 周期
SMOOTH_PERIOD = 3             # SMA 平滑周期
PIVOT_WINDOW = 3              # 枢轴检测窗口
SURGE_WINDOW_BARS = 60        # 扫描拉升的窗口（K线数，5m=5h）
SURGE_THRESHOLD_PCT = 3.0     # 判定"明显拉升"的最小涨幅 (%)
MA_PERIODS = (20, 50)         # 均线周期


# ============================================================
# 数据结构
# ============================================================

@dataclass
class ThreeWaveResult:
    """三浪下跌检测结果"""
    symbol: str
    timeframe: str
    h1: float            # 浪1高点
    l1: float            # 浪1低点
    h2: float            # 浪2反弹高点 (H2 < H1)
    l2: float            # 浪3新低 (L2 < L1)
    current_price: float
    h1_idx: int          # 浪1在数据中的位置
    l2_idx: int          # 浪3完成位置
    total_bars: int      # 总 K 线数

    # 开空辅助字段
    ma20: float = 0.0    # 当前 MA20
    ma50: float = 0.0    # 当前 MA50
    vol_ratio: float = 1.0  # 浪3平均量 / 全周期平均量
    short_grade: str = "C"  # S/A/B/C 信号等级
    h1_rank_pct: float = 100.0  # H1 在数据窗口中的分位 (越高越接近最高点)

    # 前期拉升
    pre_surge_pct: float = 0.0
    surge_peak_idx: int = 0

    @property
    def total_decline_pct(self) -> float:
        return (self.h1 - self.l2) / self.h1 * 100 if self.h1 > 0 else 0

    @property
    def wave1_decline_pct(self) -> float:
        return (self.h1 - self.l1) / self.h1 * 100 if self.h1 > 0 else 0

    @property
    def wave2_bounce_pct(self) -> float:
        return (self.h2 - self.l1) / self.l1 * 100 if self.l1 > 0 else 0

    @property
    def wave3_decline_pct(self) -> float:
        return (self.h2 - self.l2) / self.h2 * 100 if self.h2 > 0 else 0

    @property
    def retrace_ratio(self) -> float:
        denom = self.h1 - self.l1
        return (self.h2 - self.l1) / denom if denom > 0 else 0

    @property
    def age_bars(self) -> int:
        return max(0, self.total_bars - 1 - self.l2_idx)

    @property
    def has_surge(self) -> bool:
        return self.pre_surge_pct >= SURGE_THRESHOLD_PCT

    @property
    def surge_age_bars(self) -> int:
        return max(0, self.h1_idx - self.surge_peak_idx)

    @property
    def wave3_accel(self) -> float:
        """浪3 / 浪1 跌幅比 (>1 = 加速下跌)"""
        w1 = abs(self.wave1_decline_pct)
        return abs(self.wave3_decline_pct) / w1 if w1 > 0 else 0

    @property
    def below_ma20(self) -> bool:
        return self.current_price < self.ma20 if self.ma20 > 0 else False

    @property
    def below_ma50(self) -> bool:
        return self.current_price < self.ma50 if self.ma50 > 0 else False

    @property
    def ma_death_cross(self) -> bool:
        """MA20 < MA50 = 死叉"""
        return self.ma20 < self.ma50 if self.ma20 > 0 and self.ma50 > 0 else False

    @property
    def h1_is_high(self) -> bool:
        """H1 是否在最高点 5% 以内"""
        return self.h1_rank_pct >= 95.0

    @property
    def grade_emoji(self) -> str:
        return {"S": "🔴S", "A": "🟠A", "B": "🟡B", "C": "⚪C"}.get(self.short_grade, "⚪C")


# ============================================================
# 数据获取
# ============================================================

async def fetch_klines(
    session: aiohttp.ClientSession,
    symbol: str,
    interval: str = "5m",
    limit: int = 200,
) -> Optional[List[List[Any]]]:
    """获取单币种 K 线 /fapi/v1/klines"""
    params = {"symbol": symbol, "interval": interval, "limit": limit}
    try:
        async with session.get(BINANCE_KLINE_URL, params=params, timeout=10) as resp:
            if resp.status == 429:
                logger.warning("⚠️ 触发限频 %s, 跳过", symbol)
                return None
            if resp.status != 200:
                return None
            data = await resp.json()
            if not isinstance(data, list) or len(data) < 50:
                return None
            return data
    except (asyncio.TimeoutError, aiohttp.ClientError) as e:
        logger.debug("获取 %s 失败: %s", symbol, e)
        return None


async def fetch_24h_volumes(
    session: aiohttp.ClientSession,
) -> Dict[str, float]:
    """获取所有币种 24h USDT 成交量 (quoteVolume)"""
    url = "https://fapi.binance.com/fapi/v1/ticker/24hr"
    try:
        async with session.get(url, timeout=15) as resp:
            if resp.status != 200:
                logger.warning("24h成交量 API 返回 %s", resp.status)
                return {}
            data = await resp.json()
            return {
                item["symbol"]: float(item["quoteVolume"])
                for item in data
                if "symbol" in item and "quoteVolume" in item
            }
    except asyncio.TimeoutError:
        logger.warning("24h成交量 API 超时 (代理可能不通)")
        return {}
    except Exception as e:
        logger.warning("获取 24h 成交量失败: %s %s", type(e).__name__, e)
        return {}


# ============================================================
# 技术指标计算
# ============================================================

def compute_sma(data: List[float], period: int = 3) -> List[float]:
    """简单移动平均（O(n) 实现）"""
    n = len(data)
    if n < period:
        return data[:]
    cum = sum(data[:period])
    result = [data[i] if i < period - 1 else cum / period for i in range(n)]
    for i in range(period, n):
        cum = cum - data[i - period] + data[i]
        result[i] = cum / period
    return result


def compute_ma(closes: List[float], period: int) -> List[float]:
    """计算移动平均，返回与 closes 等长的数组"""
    return compute_sma(closes, period)


def compute_rsi(closes: List[float], period: int = RSI_PERIOD) -> List[float]:
    """RSI (Wilder 平滑法)"""
    n = len(closes)
    if n < period + 1:
        return [50.0] * n

    deltas = [closes[i] - closes[i - 1] for i in range(1, n)]
    gains = [max(d, 0.0) for d in deltas]
    losses = [max(-d, 0.0) for d in deltas]

    avg_gain = sum(gains[:period]) / period
    avg_loss = sum(losses[:period]) / period

    rsi = [50.0] * period
    if avg_loss < 1e-10:
        rsi.append(100.0)
    else:
        rsi.append(100.0 - 100.0 / (1.0 + avg_gain / avg_loss))

    for i in range(period, n - 1):
        avg_gain = (avg_gain * (period - 1) + gains[i]) / period
        avg_loss = (avg_loss * (period - 1) + losses[i]) / period
        if avg_loss < 1e-10:
            rsi.append(100.0)
        else:
            rs = avg_gain / avg_loss
            rsi.append(100.0 - 100.0 / (1.0 + rs))

    return rsi


# ============================================================
# 枢轴点检测
# ============================================================

def find_pivots(
    ohlc4: List[float],
    highs: List[float],
    lows: List[float],
    window: int = PIVOT_WINDOW,
    min_change_pct: float = 0.005,
) -> List[Tuple[int, float, str]]:
    """
    寻找枢轴高/低点

    检测: 用平滑后的 OHLC4 判断位置
    取值: H1/H2 取实际 high, L1/L2 取实际 low
    保证: 高低交替 (high → low → high → low ...)

    返回: [(index, price, type), ...]
    """
    n = len(ohlc4)
    pivots: List[Tuple[int, float, str]] = []

    for i in range(window, n - window):
        left = ohlc4[i - window:i]
        right = ohlc4[i + 1:i + window + 1]

        is_high = all(ohlc4[i] >= x for x in left) and all(ohlc4[i] >= x for x in right)
        is_low = all(ohlc4[i] <= x for x in left) and all(ohlc4[i] <= x for x in right)

        if not (is_high or is_low):
            continue

        if pivots:
            last_idx, last_price, last_type = pivots[-1]

            if i - last_idx < window:
                continue

            change = abs(ohlc4[i] - last_price) / max(last_price, 1e-8)
            if change < min_change_pct:
                continue

            if is_high and last_type == "high":
                if ohlc4[i] > last_price:
                    pivots[-1] = (i, highs[i], "high")
                continue
            if is_low and last_type == "low":
                if ohlc4[i] < last_price:
                    pivots[-1] = (i, lows[i], "low")
                continue

        if is_high:
            pivots.append((i, highs[i], "high"))
        elif is_low:
            pivots.append((i, lows[i], "low"))

    return pivots


# ============================================================
# 拉升检测
# ============================================================

def calc_pre_surge(
    highs: List[float], lows: List[float],
    h1_idx: int, window_bars: int = SURGE_WINDOW_BARS,
) -> Tuple[float, int]:
    """
    在整个数据范围内搜索最大拉升幅度。
    对 H1 之前的每一个 K 线作为潜在顶点，
    看它之前 window_bars 根 K 线的最低点，计算涨幅。
    返回 (最大拉升%, 峰值位置)
    """
    n = min(h1_idx + 1, len(highs))
    if n < window_bars:
        window_bars = n // 2

    best_surge = 0.0
    best_peak = 0

    for peak_idx in range(window_bars, n):
        window_start = peak_idx - window_bars
        lowest = min(lows[window_start:peak_idx])
        if lowest > 0:
            surge = (highs[peak_idx] - lowest) / lowest * 100
            if surge > best_surge:
                best_surge = surge
                best_peak = peak_idx

    return best_surge, best_peak


# ============================================================
# 模式匹配
# ============================================================

def detect_three_wave(
    highs: List[float],
    lows: List[float],
    closes: List[float],
    volumes: List[float],
    ohlc4: List[float],
    min_decline: float = 0.02,
    timeframe: str = "5m",
) -> Optional[Tuple[ThreeWaveResult, float, float]]:
    """
    检测三浪下跌形态

    在枢轴序列中寻找 H1→L1→H2→L2:
      - H2 < H1 (反弹不过前高)
      - L2 < L1 (跌破前低)
      - 总跌幅 >= min_decline

    返回: (ThreeWaveResult, L1_RSI, L2_RSI) 或 None
    """
    if len(highs) < 60:
        return None

    # 平滑 + 枢轴
    smooth = compute_sma(ohlc4, SMOOTH_PERIOD)
    pivots = find_pivots(smooth, highs, lows)
    if len(pivots) < 4:
        return None

    # 技术指标
    rsi = compute_rsi(closes)
    ma20_arr = compute_ma(closes, 20)
    ma50_arr = compute_ma(closes, 50)

    # 全周期平均成交量
    avg_vol_all = sum(volumes) / len(volumes) if volumes else 1

    best: Optional[Tuple[ThreeWaveResult, float, float]] = None
    best_score = -1.0

    for i in range(len(pivots) - 3):
        p1, p2, p3, p4 = pivots[i], pivots[i + 1], pivots[i + 2], pivots[i + 3]

        if not (p1[2] == "high" and p2[2] == "low" and p3[2] == "high" and p4[2] == "low"):
            continue

        h1, l1_val, h2, l2 = p1[1], p2[1], p3[1], p4[1]

        if not (h2 < h1 and l2 < l1_val):
            continue
        if l1_val >= h2:
            continue

        total_decline = (h1 - l2) / h1
        if total_decline < min_decline:
            continue

        # 前期拉升
        pre_surge, surge_peak = calc_pre_surge(highs, lows, p1[0])

        # H1 在数据窗口中的分位 (越高 = 越接近最高点 = 刚从高点下来)
        highest_high = max(highs)
        h1_rank_pct = h1 / highest_high * 100 if highest_high > 0 else 100

        # MA 值
        last_idx = len(closes) - 1
        cur_ma20 = ma20_arr[last_idx] if last_idx < len(ma20_arr) else 0
        cur_ma50 = ma50_arr[last_idx] if last_idx < len(ma50_arr) else 0

        # 成交量比（浪3期间 / 全周期平均）
        w3_start = p3[0]  # H2 位置
        w3_end = p4[0]    # L2 位置
        w3_vols = volumes[w3_start:w3_end + 1] if w3_end < len(volumes) else [0]
        w3_avg_vol = sum(w3_vols) / len(w3_vols) if w3_vols else 1
        vol_ratio = w3_avg_vol / avg_vol_all if avg_vol_all > 0 else 1.0

        result = ThreeWaveResult(
            symbol="",
            timeframe=timeframe,
            h1=h1, l1=l1_val, h2=h2, l2=l2,
            current_price=closes[-1],
            h1_idx=p1[0], l2_idx=p4[0],
            total_bars=len(highs),
            pre_surge_pct=pre_surge,
            surge_peak_idx=surge_peak,
            ma20=cur_ma20,
            ma50=cur_ma50,
            vol_ratio=vol_ratio,
            h1_rank_pct=h1_rank_pct,
        )

        l1_rsi = rsi[p2[0]] if p2[0] < len(rsi) else 50.0
        l2_rsi = rsi[p4[0]] if p4[0] < len(rsi) else 50.0

        sc = compute_short_score(result, l1_rsi, l2_rsi)
        result.short_grade = grade_score(sc)

        if sc > best_score:
            best_score = sc
            best = (result, l1_rsi, l2_rsi)

    return best


# ============================================================
# 开空评分体系 (0-100)
# ============================================================

def compute_short_score(r: ThreeWaveResult, l1_rsi: float, l2_rsi: float) -> float:
    """
    开空优化评分 (0-100)

    趋势面  (max 35): MA 空头排列
    动能面  (max 30): 跌幅 + 浪3加速 + 放量
    结构面  (max 25): 浅回撤 + 新鲜度
    确认面  (max 10): RSI 无底背离
    拉升加分(max 15): 前期拉升
    高点质量(max 15): H1 必须是近期高点(刚从高点下来)
    """
    score = 0.0

    # ── 趋势面 (max 35) ──
    if r.below_ma20:
        score += 10.0                              # 价格 < MA20
    if r.below_ma50:
        score += 10.0                              # 价格 < MA50
    if r.ma_death_cross:
        score += 10.0                              # MA20 < MA50 (死叉)
    if r.below_ma20 and r.below_ma50:
        score += 5.0                               # 双重确认

    # ── 动能面 (max 30) ──
    decline = r.total_decline_pct / 100.0
    score += min(decline * 120, 12.0)              # 跌幅幅度 (max 12)

    if r.wave3_accel >= 1.0:
        accel_bonus = min((r.wave3_accel - 1.0) * 20, 10.0)
        score += accel_bonus                       # 浪3加速 (max 10)

    if r.vol_ratio > 1.0:
        vol_bonus = min((r.vol_ratio - 1.0) * 15, 8.0)
        score += vol_bonus                         # 放量下跌 (max 8)

    # ── 结构面 (max 25) ──
    rt = r.retrace_ratio
    if rt < 0.236:
        score += 15.0                              # 极浅回撤，极强势下跌
    elif rt < 0.382:
        score += 15.0                              # 浅回撤，强势下跌 (最佳)
    elif rt < 0.500:
        score += 10.0                              # 中回撤
    elif rt < 0.618:
        score += 5.0                               # 深回撤，偏弱
    # > 0.618: 不加分，反弹太强不适合空

    # 新鲜度 (max 10)
    freshness = 1.0 - (r.age_bars / max(r.total_bars, 1))
    score += freshness * 10.0

    # ── 确认面 (max 10): RSI 无底背离 ──
    if l2_rsi <= l1_rsi + 1.0:                    # 无底背离 = 下跌未衰竭
        score += 10.0

    # ── 拉升加分 (max 15): 前期拉升 ──
    if r.has_surge:
        score += min(r.pre_surge_pct * 2.0, 15.0)

    # ── 高点质量 (max 15): H1 必须是近期高点 ──
    if r.h1_rank_pct >= 99.0:
        score += 15.0                              # 最高点附近，刚见顶回落
    elif r.h1_rank_pct >= 97.0:
        score += 12.0                              # 接近最高点
    elif r.h1_rank_pct >= 95.0:
        score += 8.0                               # 离高点不远
    elif r.h1_rank_pct >= 90.0:
        score += 4.0                               # 勉强算近期高

    return min(score, 100.0)


def grade_score(score: float) -> str:
    """评分转信号等级"""
    if score >= 80:
        return "S"
    elif score >= 60:
        return "A"
    elif score >= 40:
        return "B"
    else:
        return "C"


# ============================================================
# 单币种扫描
# ============================================================

async def scan_one(
    symbol: str,
    session: aiohttp.ClientSession,
    timeframe: str,
    limit: int,
    min_decline: float,
) -> Optional[Tuple[ThreeWaveResult, float, float]]:
    """扫描单个币种"""
    klines = await fetch_klines(session, symbol, timeframe, limit)
    if not klines:
        return None

    opens = [float(k[1]) for k in klines]
    highs = [float(k[2]) for k in klines]
    lows = [float(k[3]) for k in klines]
    closes = [float(k[4]) for k in klines]
    volumes = [float(k[5]) for k in klines]
    ohlc4 = [(o + h + l + c) / 4 for o, h, l, c in zip(opens, highs, lows, closes)]

    result = detect_three_wave(highs, lows, closes, volumes, ohlc4,
                               min_decline, timeframe)
    if result is None:
        return None

    r, l1_rsi, l2_rsi = result
    r.symbol = symbol
    return r, l1_rsi, l2_rsi


# ============================================================
# 终端输出
# ============================================================

def fmt_price(p: float) -> str:
    """智能格式化价格"""
    if p >= 1000:
        return f"{p:.2f}"
    elif p >= 1:
        return f"{p:.4f}"
    elif p >= 0.01:
        return f"{p:.6f}"
    else:
        return f"{p:.8f}"


def fmt_ma_line(val: float, below: bool) -> str:
    """MA 格式化: 24500↓ 表示价格在均线下方"""
    s = fmt_price(val)
    return f"{s}↓" if below else f"{s}↑"


def print_header(title: str):
    print()
    print(f"  {'=' * 58}")
    print(f"  {title}")
    print(f"  {'=' * 58}")


def print_results(scored: List[Tuple[ThreeWaveResult, float, float, float]], top: int):
    """打印结果表格"""
    if not scored:
        print("  ❌ 未找到匹配的三浪下跌形态")
        return

    print(f"  Top {min(len(scored), top)} 结果:\n")

    # 表头
    hdr = (f"  {'#':>3} {'信号':<6} {'币种':<16} {'当前价':<12} "
           f"{'拉升%':<8} {'跌幅%':<7} {'浪3/浪1':<9} {'回撤':<6} {'MA20':<11} {'MA50':<11} {'量比':<6} {'评分':<5}")
    print(hdr)
    print(f"  {'─' * len(hdr)}")

    for idx, (r, l1_rsi, l2_rsi, sc) in enumerate(scored[:top], 1):
        surge_tag = f"{r.pre_surge_pct:.1f}%🚀" if r.has_surge else f"{r.pre_surge_pct:.1f}%"
        ma20_s = fmt_ma_line(r.ma20, r.below_ma20)
        ma50_s = fmt_ma_line(r.ma50, r.below_ma50)
        accel_s = f"{r.wave3_accel:.2f}x{'🔥' if r.wave3_accel >= 1.0 else ''}"

        print(f"  {idx:>3} {r.grade_emoji:<6} {r.symbol:<16} {fmt_price(r.current_price):<12} "
              f"{surge_tag:<8} {r.total_decline_pct:<6.2f}% "
              f"{accel_s:<9} {r.retrace_ratio:<6.3f} "
              f"{ma20_s:<11} {ma50_s:<11} {r.vol_ratio:<6.2f}x {sc:<5.1f}")


def print_detail(scored: List[Tuple[ThreeWaveResult, float, float, float]], top_n: int = 5):
    """打印详细分析"""
    shown = 0
    for r, l1_rsi, l2_rsi, sc in scored:
        if shown >= top_n:
            break
        shown += 1

        # RSI 判定
        rsi_bearish = l2_rsi <= l1_rsi + 1.0  # 无底背离 = 下跌延续
        rsi_status = "✔ 下跌延续" if rsi_bearish else "⚠️ 底背离(反弹风险)"

        # 拉升判定
        if r.has_surge:
            surge_when = f"{r.surge_age_bars}根K线前" if r.surge_age_bars > 0 else "就在浪1起点"
            surge_status = f"🚀 前期拉升 {r.pre_surge_pct:.1f}% ({surge_when})"
        else:
            surge_status = "— 无明显前期拉升"

        # 均线状态
        ma_line = (f"MA20={fmt_price(r.ma20)} {'↓' if r.below_ma20 else '↑'}  "
                   f"MA50={fmt_price(r.ma50)} {'↓' if r.below_ma50 else '↑'}  "
                   f"{'死叉' if r.ma_death_cross else '金叉'}")

        # 动能
        accel_status = f"浪3加速 {r.wave3_accel:.2f}x {'🔥' if r.wave3_accel >= 1.0 else ''}"
        vol_status = f"成交量 {r.vol_ratio:.2f}x {'📊放量' if r.vol_ratio > 1.0 else '缩量'}"

        print()
        print(f"  ┌─ {r.symbol}  {r.grade_emoji} 评分 {sc:.1f}")
        print(f"  │")
        print(f"  ├─ 浪1: {fmt_price(r.h1)} → {fmt_price(r.l1)}  下跌 {r.wave1_decline_pct:.2f}%")
        print(f"  ├─ 浪2: {fmt_price(r.l1)} → {fmt_price(r.h2)}  反弹 {r.wave2_bounce_pct:.2f}%, "
              f"回撤率 {r.retrace_ratio:.3f}")
        print(f"  ├─ 浪3: {fmt_price(r.h2)} → {fmt_price(r.l2)}  下跌 {r.wave3_decline_pct:.2f}%")
        print(f"  ├─ 高点质量: H1 在最高点 {r.h1_rank_pct:.1f}% 位置 {'🆕' if r.h1_is_high else ''}")
        print(f"  │")
        print(f"  ├─ 均线: {ma_line}")
        print(f"  ├─ {accel_status}  |  {vol_status}")
        print(f"  ├─ RSI: L1={l1_rsi:.1f}  L2={l2_rsi:.1f}  {rsi_status}")
        print(f"  ├─ {surge_status}")
        print(f"  ├─ 总跌幅: {r.total_decline_pct:.2f}%  |  新鲜度: {r.age_bars}根K线前")
        print(f"  └─ 当前价: {fmt_price(r.current_price)}")
        print(f"     💡 开空参考: 止损 {fmt_price(r.h2*1.005)} (H2+0.5%)  "
              f"目标1 {fmt_price(r.l2*0.97)} 目标2 {fmt_price(r.l2*0.94)}")


# ============================================================
# 主入口
# ============================================================

async def main() -> int:
    parser = argparse.ArgumentParser(
        description="三浪下跌扫描器 (开空优化版) — 扫描所有 USDT 交易对",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "示例:\n"
            "  %(prog)s                          # 5m 周期扫描\n"
            "  %(prog)s -t 15m --top 20          # 15m 周期，Top 20\n"
            "  %(prog)s -t 1h --min-score 50     # 1h 周期，仅高质量形态\n"
            "  %(prog)s --min-decline 0.05       # 仅 >=5%% 跌幅的形态\n"
        ),
    )
    parser.add_argument("-t", "--timeframe", default="5m",
                        help="K 线周期 (默认 5m)")
    parser.add_argument("-l", "--limit", type=int, default=200,
                        help="K 线数量 (默认 200)")
    parser.add_argument("--min-decline", type=float, default=0.02,
                        help="最小总跌幅 (默认 0.02 = 2%%)")
    parser.add_argument("--top", type=int, default=30,
                        help="显示前 N 个结果 (默认 30)")
    parser.add_argument("--min-score", type=float, default=30.0,
                        help="最低评分过滤 (默认 30)")
    parser.add_argument("--no-proxy", action="store_true",
                        help="不使用 SOCKS5 代理")
    parser.add_argument("--min-volume", type=float, default=500_000,
                        help="最低 24h USDT 成交量 (默认 500k, 设 0 关闭)")
    parser.add_argument("--min-h1-rank", type=float, default=90.0,
                        help="H1 最低分位 (默认 90%%, 低于此说明已跌很久, 设 0 关闭)")
    args = parser.parse_args()

    logging.basicConfig(level=logging.WARNING, format="%(message)s")

    # ── 代理 ──
    proxy_url = None
    if not args.no_proxy:
        proxy_url = os.environ.get("ALL_PROXY") or "socks5://127.0.0.1:7897"
    connector = ProxyConnector.from_url(proxy_url) if proxy_url else None

    async with aiohttp.ClientSession(connector=connector) as session:
        # ── 24h 成交量过滤 ──
        symbols = config.SYMBOLS
        start_t = time.time()

        print()
        print(f"  🔍 三浪下跌开空扫描")
        print(f"  ─────────────────────────────")
        print(f"  周期: {args.timeframe}  |  总币种: {len(symbols)}")
        print(f"  最低跌幅: {args.min_decline*100:.0f}%  |  最低评分: {args.min_score}")
        if args.min_volume > 0:
            print(f"  📊 获取 24h 成交量...", end="", flush=True)
            vol_map = await fetch_24h_volumes(session)
            if vol_map:
                before = len(symbols)
                symbols = [s for s in symbols if vol_map.get(s, 0) >= args.min_volume]
                skipped = before - len(symbols)
                print(f" 过滤掉 {skipped} 个僵尸币 (24h量 < {args.min_volume/1e6:.1f}M USDT), 剩余 {len(symbols)}")
            else:
                print("  ⚠️ 获取失败, 跳过成交量过滤 (可用 --no-proxy 重试)")
        if proxy_url:
            print(f"  代理: {proxy_url}")
        print()

        # ── 并发扫描 ──
        sem = asyncio.Semaphore(MAX_CONCURRENT)

        async def bounded_scan(symbol: str) -> Optional[Tuple]:
            async with sem:
                return await scan_one(symbol, session, args.timeframe,
                                      args.limit, args.min_decline)

        total = len(symbols)
        tasks = [bounded_scan(sym) for sym in symbols]
        raw_results: List[Tuple[ThreeWaveResult, float, float]] = []

        done = 0
        for coro in asyncio.as_completed(tasks):
            r = await coro
            done += 1
            if r is not None:
                raw_results.append(r)
            if done % 50 == 0 or done == total:
                pct = done * 100 // total if total > 0 else 100
                elapsed = time.time() - start_t
                print(f"  ⏳ 扫描中: {done}/{total} ({pct}%)  ({elapsed:.0f}s)",
                      end="\r" if done < total else "\n")

        elapsed = time.time() - start_t
        print(f"  ✨ 完成: {elapsed:.1f}s  |  匹配 {len(raw_results)}/{total} 个币种")
        print()

        # ── 评分 & 排序 ──
        scored: List[Tuple[ThreeWaveResult, float, float, float]] = []
        h1_rank_filtered = 0
        for r, l1_rsi, l2_rsi in raw_results:
            # 高点质量过滤
            if args.min_h1_rank > 0 and r.h1_rank_pct < args.min_h1_rank:
                h1_rank_filtered += 1
                continue
            sc = compute_short_score(r, l1_rsi, l2_rsi)
            if sc >= args.min_score:
                r.short_grade = grade_score(sc)
                scored.append((r, l1_rsi, l2_rsi, sc))

        scored.sort(key=lambda x: x[3], reverse=True)

        # ── 统计 ──
        if h1_rank_filtered > 0:
            print(f"  ⚠️  {h1_rank_filtered} 个匹配因 H1 不是近期高点被过滤 (--min-h1-rank {args.min_h1_rank}%)")
        s_count = sum(1 for r, _, _, sc in scored if sc >= 80)
        a_count = sum(1 for r, _, _, sc in scored if 60 <= sc < 80)

        # ── 输出 ──
        print_header(f"三浪下跌开空信号  ({args.timeframe}, {len(scored)} 匹配, "
                     f"S級{s_count} A級{a_count})")

        if scored:
            print_results(scored, args.top)
            print()
            print_detail(scored, min(5, len(scored)))
        else:
            print("  ❌ 未找到符合条件的三浪下跌形态")
            print(f"    建议降低 --min-score (当前 {args.min_score}) 或 --min-decline (当前 {args.min_decline})")

        print()
        print(f"  ══════════════════════════════════════════════════════")
        print()

    return 0


if __name__ == "__main__":
    sys.exit(asyncio.run(main()))
