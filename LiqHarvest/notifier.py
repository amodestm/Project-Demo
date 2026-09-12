"""
============================
notifier.py — 通知层
============================
职责: Telegram Bot 推送通知
  - 速率限制: 10条/分钟，滑动窗口
  - 环境变量未配置时自动跳过

事件类型:
  on_signal       — 🎯 信号触发
  on_entry        — ✅ 开仓
  on_exit         — 💰/❌ 平仓（含净利）
  on_daily_summary — 📊 日报
  on_error        — ⚠️ 错误告警

配置:
  export TELEGRAM_BOT_TOKEN="123456:ABC..."
  export TELEGRAM_CHAT_ID="-100123456..."

注意: 目前在集成中留有 # NOTIFIER: 注释，尚未启用。
      取消注释 strategy.py / risk.py 中的 NOTIFIER 代码块即可激活。
"""

import logging
import os
import time
from collections import deque
from typing import Optional

import aiohttp

logger = logging.getLogger(__name__)

TELEGRAM_API = "https://api.telegram.org/bot{token}/sendMessage"
MAX_MSG_PER_MINUTE = 10
RATE_WINDOW_SEC = 60


class TelegramNotifier:
    """Telegram 通知器 — 速率限制 10条/分钟，环境变量未配置时自动跳过"""

    def __init__(self):
        self.token = os.getenv("TELEGRAM_BOT_TOKEN")
        self.chat_id = os.getenv("TELEGRAM_CHAT_ID")
        self._enabled = bool(self.token and self.chat_id)
        self._send_times: deque[float] = deque()
        self._session: Optional[aiohttp.ClientSession] = None

        if not self._enabled:
            logger.info("Telegram 未配置 (TELEGRAM_BOT_TOKEN / TELEGRAM_CHAT_ID 为空)，通知已禁用")
        else:
            logger.info("Telegram 通知已启用")

    # ---- 生命周期 ----

    async def _ensure_session(self):
        if self._session is None:
            self._session = aiohttp.ClientSession()

    async def close(self):
        if self._session:
            await self._session.close()
            self._session = None

    # ---- 速率限制 ----

    def _rate_limited(self) -> bool:
        """滑动窗口检查，超过 10条/分钟 返回 True"""
        now = time.monotonic()
        while self._send_times and now - self._send_times[0] > RATE_WINDOW_SEC:
            self._send_times.popleft()
        if len(self._send_times) >= MAX_MSG_PER_MINUTE:
            return True
        self._send_times.append(now)
        return False

    # ---- 核心发送 ----

    async def send_message(self, text: str) -> bool:
        """异步发送 Telegram 消息，返回是否成功"""
        if not self._enabled:
            return False

        if self._rate_limited():
            logger.warning("Telegram 速率限制 (%d条/%ds)，跳过: %s", MAX_MSG_PER_MINUTE, RATE_WINDOW_SEC, text[:60])
            return False

        await self._ensure_session()
        assert self._session is not None

        url = TELEGRAM_API.format(token=self.token)
        payload = {
            "chat_id": self.chat_id,
            "text": text,
            "parse_mode": "HTML",
        }

        try:
            async with self._session.post(
                url, json=payload, timeout=aiohttp.ClientTimeout(total=10)
            ) as resp:
                if resp.status != 200:
                    body = await resp.text()
                    logger.error("Telegram 发送失败 HTTP %s: %s", resp.status, body[:200])
                    return False
                return True
        except Exception as e:
            logger.error("Telegram 发送异常: %s", type(e).__name__)
            return False

    # ---- 通知事件 ----

    async def on_signal(
        self, symbol: str, side: str, price: float,
        liq_total: float, imbalance: float, vwap_dev: float,
    ):
        """信号触发通知"""
        side_cn = "做多" if side == "LONG" else "做空"
        text = (
            f"🎯 信号 | {symbol} {side_cn} | "
            f"清算 {liq_total:,.0f}U | "
            f"失衡 {imbalance:.2f} | "
            f"VWAP偏离 {vwap_dev:+.2%}"
        )
        await self.send_message(text)

    async def on_entry(self, symbol: str, side: str, entry_price: float, qty: float):
        """开仓通知"""
        side_cn = "做多" if side == "LONG" else "做空"
        text = f"✅ 开仓 | {symbol} {side_cn} @ {entry_price:.4f}"
        await self.send_message(text)

    async def on_exit(
        self, symbol: str, side: str, entry_price: float, exit_price: float,
        gross_pnl: float, fees: float, net_pnl: float, reason: str,
    ):
        """平仓通知"""
        emoji = "💰" if net_pnl > 0 else "❌"
        text = (
            f"{emoji} 平仓 | {symbol} | "
            f"入场 {entry_price:.4f}→出场 {exit_price:.4f} | "
            f"净利 {net_pnl:+.4f}U | "
            f"{reason}"
        )
        await self.send_message(text)

    async def on_daily_summary(self, summary: dict):
        """日报通知"""
        text = (
            f"📊 日报 | {summary['date']} | "
            f"交易 {summary['trades']}笔 | "
            f"胜率 {summary['win_rate']:.0f}% | "
            f"净利 {summary['net_pnl']:+.4f}U"
        )
        await self.send_message(text)

    async def on_error(self, msg: str):
        """错误通知"""
        text = f"⚠️ 错误 | {msg}"
        await self.send_message(text)
