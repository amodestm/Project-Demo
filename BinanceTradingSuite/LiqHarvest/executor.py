"""
============================
executor.py — 执行器层
============================
职责: Binance 统一账户 Portfolio Margin API 订单执行
  - 底层: 自建 aiohttp REST 客户端，不走外部 SDK
  - API 端点: https://papi.binance.com (统一账户专用)
  - 签名: HMAC SHA256 + recvWindow=5000
  - 代理: SOCKS5 → 127.0.0.1:7897 (Clash)
  - 精度: 启动时从 fapi.binance.com/exchangeInfo 拉取全币种精度

注意:
  Hedge Mode (双向持仓) — 所有订单带 positionSide 参数
  最小名义价值保护 — 自动调整到 ≥$5（BTC/ETH ≥$20）
  无API Key 时自动进入模拟交易模式

可使用 python-binance AsyncClient 替换，减少~200行维护代码。

方法列表:
  set_leverage()      — 设置单币种杠杆 (20x)
  place_limit_order()  — 限价单 (GTC)
  place_market_order() — 市价单
  cancel_order()       — 撤单
  get_balance()        — USDC 余额（统一账户钱包 + 跨保证金）
  get_position_info()  — 查询某币种持仓
"""

import asyncio
import hashlib
import hmac
import logging
import math
import os
import time
from typing import Optional
from urllib.parse import urlencode

import aiohttp
from aiohttp_socks import ProxyConnector

from . import config

logger = logging.getLogger(__name__)


class BinanceExecutor:
    """Binance 统一账户 Portfolio Margin REST 订单执行"""

    def __init__(self):
        self._api_key = os.environ.get("BINANCE_API_KEY", "")
        self._api_secret = os.environ.get("BINANCE_API_SECRET", "")
        self._base_url = "https://papi.binance.com"
        self._session: Optional[aiohttp.ClientSession] = None

        if not self._api_key or not self._api_secret:
            logger.warning("未设置 BINANCE_API_KEY / BINANCE_API_SECRET 环境变量，仅模拟交易")

    async def start(self):
        proxy_url = os.environ.get("ALL_PROXY") or "socks5://127.0.0.1:7897"
        try:
            connector = ProxyConnector.from_url(proxy_url)
            self._session = aiohttp.ClientSession(connector=connector)
            logger.info(f"REST 走代理: {proxy_url}")
        except Exception:
            self._session = aiohttp.ClientSession()
        # 拉取精度表
        await self._load_precisions()
        # 设置杠杆（全部币种，并发）
        tasks = [self.set_leverage(sym) for sym in config.SYMBOLS]
        await asyncio.gather(*tasks, return_exceptions=True)

    async def stop(self):
        if self._session:
            await self._session.close()

    # ---- 签名 ----

    def _sign(self, params: dict) -> str:
        return hmac.new(
            self._api_secret.encode("utf-8"),
            urlencode(params).encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

    async def _signed_request(self, method: str, path: str, params: dict) -> dict:
        if not self._api_key:
            return {"simulated": True, "orderId": f"sim_{int(time.time()*1000)}"}

        params["timestamp"] = int(time.time() * 1000)
        params["recvWindow"] = 5000
        params["signature"] = self._sign(params)
        headers = {"X-MBX-APIKEY": self._api_key}
        url = f"{self._base_url}{path}"

        try:
            async with self._session.request(method, url, params=params, headers=headers) as resp:
                data = await resp.json()
                if resp.status >= 400:
                    logger.error(f"API 错误 [{resp.status}] {path}: {data}")
                return data
        except Exception as e:
            logger.error(f"请求异常 {path}: {e}")
            return {"error": str(e)}

    # ---- 杠杆设置 ----

    async def set_leverage(self, symbol: str) -> bool:
        result = await self._signed_request("POST", "/papi/v1/um/leverage", {
            "symbol": symbol,
            "leverage": config.LEVERAGE,
        })
        if result.get("leverage") == config.LEVERAGE or result.get("simulated"):
            logger.info(f"{symbol} 杠杆已设置: {config.LEVERAGE}x")
            return True
        return False

    # ---- 订单操作 ----

    async def place_limit_order(
        self, symbol: str, side: str, quantity: float, price: float, position_side: str = "LONG"
    ) -> Optional[str]:
        qty = self._round_qty(symbol, quantity)
        px = self._round_price(symbol, price)
        # 确保满足最小名义价值
        notional = float(qty) * float(px)
        min_notional = 20 if symbol in ("BTCUSDT", "ETHUSDT") else 5
        if notional < min_notional:
            qty = self._round_qty(symbol, min_notional / float(px))
            logger.info(f"限价单(调整): {side} {qty} {symbol} @ {px} (名义{notional:.1f}<{min_notional})")
        else:
            logger.info(f"限价单: {side} {qty} {symbol} @ {px}")
        result = await self._signed_request("POST", "/papi/v1/um/order", {
            "symbol": symbol,
            "side": side,
            "positionSide": position_side,
            "type": "LIMIT",
            "quantity": qty,
            "price": px,
            "timeInForce": "GTC",
        })
        order_id = result.get("orderId")
        if order_id:
            logger.info(f"订单已提交: {order_id}")
            return str(order_id)
        return None

    async def cancel_order(self, symbol: str, order_id: str):
        logger.info(f"取消订单: {order_id}")
        await self._signed_request("DELETE", "/papi/v1/um/order", {
            "symbol": symbol,
            "orderId": order_id,
        })

    async def place_market_order(
        self, symbol: str, side: str, quantity: float, position_side: str = "LONG"
    ) -> Optional[float]:
        qty = self._round_qty(symbol, quantity)
        logger.info(f"市价单: {side} {qty} {symbol}")
        result = await self._signed_request("POST", "/papi/v1/um/order", {
            "symbol": symbol,
            "side": side,
            "positionSide": position_side,
            "type": "MARKET",
            "quantity": qty,
        })
        if "avgPrice" in result:
            return float(result["avgPrice"])
        if result.get("simulated"):
            return 0.0
        return None

    async def get_balance(self) -> float:
        """获取 USDC 可用余额（统一账户 UM 钱包）"""
        result = await self._signed_request("GET", "/papi/v1/balance", {})
        if isinstance(result, dict) and (result.get("simulated") or result.get("error")):
            return 0.0
        if isinstance(result, list):
            for asset in result:
                if isinstance(asset, dict) and asset.get("asset") == "USDC":
                    bal = float(asset.get("umWalletBalance", 0))
                    cross_bal = float(asset.get("crossMarginFree", 0) or 0)
                    return max(0.0, bal + cross_bal)
        return 0.0

    async def get_position_info(self, symbol: str) -> Optional[dict]:
        result = await self._signed_request("GET", "/papi/v1/um/positionRisk", {
            "symbol": symbol,
        })
        if result.get("simulated") or result.get("error"):
            return None
        if isinstance(result, list):
            for pos in result:
                if pos.get("symbol") == symbol:
                    return pos
        return None

    # ---- 精度缓存 ----

    async def _load_precisions(self):
        """从 exchangeInfo 拉取所有币种的精度"""
        self._tick_size = {}
        self._step_size = {}
        try:
            async with self._session.get("https://fapi.binance.com/fapi/v1/exchangeInfo") as resp:
                if resp.status == 200:
                    info = await resp.json()
                    for si in info.get("symbols", []):
                        sym = si["symbol"]
                        if sym not in config.SYMBOLS:
                            continue
                        filters = {f["filterType"]: f for f in si.get("filters", [])}
                        self._tick_size[sym] = float(filters.get("PRICE_FILTER", {}).get("tickSize", 0.01))
                        self._step_size[sym] = float(filters.get("MARKET_LOT_SIZE", {}).get("stepSize", 0.1))
            logger.info(f"精度缓存: {len(self._tick_size)} 个币种")
        except Exception as e:
            logger.warning(f"精度加载失败: {e}")

    def _round_price(self, symbol: str, price: float) -> str:
        tick = getattr(self, '_tick_size', {}).get(symbol, 0.01)
        decimals = max(0, int(round(-math.log10(tick) + 0.5)))
        return f"{price:.{decimals}f}"

    def _round_qty(self, symbol: str, qty: float) -> str:
        step = getattr(self, '_step_size', {}).get(symbol, 0.1)
        decimals = max(0, int(round(-math.log10(step) + 0.5)))
        return f"{qty:.{decimals}f}"
