"""
=====================================
executor_client.py — 执行层 (纯 REST)
=====================================
职责: Binance 交易平台 API 执行层
  - 所有请求走 REST 直连（无 AsyncClient 依赖）
  - 签名: HMAC SHA256（参数排序确保一致性）
  - 代理: HTTP → 127.0.0.1:7897

数据流:
  get_balance() / get_positions() / get_all_prices()
    → _signed_get / _signed_post (REST 直连)

下单:
  place_order() / batch_orders()
    → _signed_post("/fapi/v1/order", params)
"""
import asyncio
import hashlib
import hmac
import logging
import os
import time
from urllib.parse import urlencode

import aiohttp
from aiohttp_socks import ProxyConnector

logger = logging.getLogger(__name__)

FAPI_REST = "https://fapi.binance.com"    # 公开数据 (价格/行情)
PAPI_REST = "https://fapi.binance.com"    # 签名请求 (统一用 fapi)


class PlatformExecutor:
    """低延迟平台执行器 — 纯 REST 直连"""

    def __init__(self):
        self._api_key = os.environ.get("BINANCE_API_KEY", "")
        self._api_secret = os.environ.get("BINANCE_API_SECRET", "")
        self._session: "aiohttp.ClientSession" = None
        self._tick_size: dict = {}
        self._step_size: dict = {}

    async def start(self):
        """启动 HTTP 会话 + 预热精度缓存（走 SOCKS5 代理）"""
        proxy_url = os.environ.get("ALL_PROXY") or "socks5://127.0.0.1:7897"
        try:
            connector = ProxyConnector.from_url(proxy_url)
            self._session = aiohttp.ClientSession(connector=connector)
            logger.info(f"REST 走代理: {proxy_url}")
        except Exception as e:
            logger.warning(f"代理创建失败({e})，回退直连")
            self._session = aiohttp.ClientSession()

        if not self._api_key or not self._api_secret:
            logger.warning("未设置 BINANCE_API_KEY/SECRET，仅模拟模式")
            await self._load_precisions()
            return

        await self._load_precisions()
        logger.info("PlatformExecutor 启动完成")

    async def stop(self):
        if self._session and not self._session.closed:
            await self._session.close()
        logger.info("PlatformExecutor 已关闭")

    # ---- 签名请求 ----

    async def _signed_get(self, path: str, params: dict = None) -> dict:
        return await self._signed_req("GET", path, params)

    async def _signed_post(self, path: str, params: dict = None) -> dict:
        return await self._signed_req("POST", path, params)

    async def _signed_req(self, method: str, path: str, params: dict = None) -> dict:
        """通用签名请求 — 确保排序与签名一致"""
        if not self._api_key or not self._session:
            return {}
        params = params or {}
        params["timestamp"] = int(time.time() * 1000)
        params["recvWindow"] = 5000
        sorted_params = dict(sorted(params.items()))
        query = urlencode(sorted_params)
        signature = self._sign_dict(sorted_params)
        headers = {"X-MBX-APIKEY": self._api_key}
        try:
            final_query = f"{query}&signature={signature}"
            url = f"{PAPI_REST}{path}?{final_query}"
            async with self._session.request(method, url, headers=headers, timeout=10) as resp:
                if resp.status == 200:
                    return await resp.json()
                text = await resp.text()
                logger.warning(f"PAPI {method} {path} 返回 {resp.status}: {text[:200]}")
                # 把错误码和消息带回去，调用方能看到真实失败原因
                try:
                    err_json = await resp.json() if False else None
                except Exception:
                    err_json = None
                # 尝试解析 text 成 JSON
                import json as _json
                try:
                    parsed = _json.loads(text)
                    if isinstance(parsed, dict):
                        return {"_error": True, "code": parsed.get("code"),
                                "msg": parsed.get("msg", text[:200]),
                                "http_status": resp.status}
                except Exception:
                    pass
                return {"_error": True, "code": -1, "msg": text[:200],
                        "http_status": resp.status}
        except Exception as e:
            logger.warning(f"PAPI {method} {path} 异常: {e}")
            return {"_error": True, "code": -1, "msg": str(e), "http_status": 0}

    def _sign_dict(self, params: dict) -> str:
        """HMAC SHA256 签名 — params 必须已排序"""
        return hmac.new(
            self._api_secret.encode("utf-8"),
            urlencode(params).encode("utf-8"),
            hashlib.sha256,
        ).hexdigest()

    # ---- 查询（纯 REST） ----

    async def get_balance(self) -> float:
        """获取可用余额 — 标准交易账户"""
        # 方法1: /fapi/v2/account
        acc = await self._signed_get("/fapi/v2/account")
        if isinstance(acc, dict):
            for field in ("availableBalance", "totalMarginBalance", "totalWalletBalance"):
                val = acc.get(field)
                if val and float(val) > 0:
                    logger.info(f"余额(account): {field} = {val}")
                    return float(val)
            logger.info(f"余额(account) 全字段: {str(acc)[:300]}")

        # 方法2: /fapi/v2/balance (多资产列表, 兜底)
        data = await self._signed_get("/fapi/v2/balance")
        if isinstance(data, list):
            for asset in data:
                a = asset.get("asset", "")
                if a in ("USDC", "USDT"):
                    for field in ("availableBalance", "walletBalance", "balance", "crossWalletBalance"):
                        val = asset.get(field)
                        if val and float(val) > 0:
                            logger.info(f"余额(bal): {a}({field}) = {val}")
                            return float(val)

        return 0.0

    async def get_total_equity(self) -> float:
        """获取总权益（含未实现盈亏），用于仓位计算"""
        acc = await self._signed_get("/fapi/v2/account")
        if isinstance(acc, dict):
            for field in ("totalWalletBalance", "totalMarginBalance", "availableBalance"):
                val = acc.get(field)
                if val and float(val) > 0:
                    return float(val)
        return await self.get_balance()

    async def get_all_balances(self) -> list:
        """获取全部币种余额"""
        data = await self._signed_get("/fapi/v2/balance")
        result = []
        if isinstance(data, list):
            for item in data:
                if not isinstance(item, dict):
                    continue
                asset = (item.get("asset") or item.get("a") or "?")
                wallet = float(item.get("walletBalance") or 0)
                cross = float(item.get("crossWalletBalance") or 0)
                bal = float(item.get("balance") or item.get("availableBalance") or 0)
                result.append({"asset": asset, "um": wallet, "cross": cross, "total": bal, "balance": bal})
        return result

    async def get_positions(self) -> list:
        """获取当前所有持仓"""
        data = await self._signed_get("/fapi/v2/positionRisk")
        if not isinstance(data, list):
            return []
        result = []
        for p in data:
            amt = float(p.get("positionAmt", 0))
            if abs(amt) < 0.0001:
                continue
            side = "LONG" if amt > 0 else "SHORT"
            result.append({
                "symbol": p["symbol"],
                "side": side,
                "quantity": abs(amt),
                "entry_price": float(p.get("entryPrice", 0)),
                "mark_price": float(p.get("markPrice", 0)),
                "pnl": float(p.get("unRealizedProfit", 0)),
                "leverage": int(p.get("leverage", 20)),
            })
        return result

    async def get_account_info(self) -> dict:
        """完整账户信息"""
        acc = await self._signed_get("/fapi/v2/account")
        available = float(acc.get("availableBalance", 0)) if isinstance(acc, dict) else 0
        equity = float(acc.get("totalWalletBalance") or acc.get("totalMarginBalance", 0)) \
                 if isinstance(acc, dict) else 0

        positions = await self.get_positions()
        total_upnl = sum(p.get("pnl", 0) for p in positions)
        return {
            "balance": available,
            "available": available,
            "equity": equity,
            "margin": 0,
            "margin_level": 0,
            "unrealized_pnl": round(total_upnl, 6),
            "positions": len(positions),
        }

    async def get_all_prices(self) -> dict:
        """获取全部币种价格"""
        if not self._session:
            return {}
        try:
            async with self._session.get(
                f"{FAPI_REST}/fapi/v1/ticker/price", timeout=10
            ) as resp:
                if resp.status == 200:
                    data = await resp.json()
                    return {t["symbol"]: float(t["price"]) for t in data}
        except Exception as e:
            logger.warning(f"获取价格失败: {e}")
        return {}

    async def get_symbol_price(self, symbol: str) -> float:
        """获取单个币种实时价格"""
        prices = await self.get_all_prices()
        return prices.get(symbol, 0.0)

    async def _rest_ticker(self, symbol: str) -> dict:
        """获取 24h 行情 + 买一/卖一"""
        if not self._session:
            return {}
        try:
            async def _fetch_24hr():
                async with self._session.get(
                    f"{FAPI_REST}/fapi/v1/ticker/24hr",
                    params={"symbol": symbol}, timeout=10
                ) as resp:
                    if resp.status == 200:
                        t = await resp.json()
                        return t
                    return {}

            async def _fetch_book():
                async with self._session.get(
                    f"{FAPI_REST}/fapi/v1/ticker/bookTicker",
                    params={"symbol": symbol}, timeout=10
                ) as resp:
                    if resp.status == 200:
                        b = await resp.json()
                        return b
                    return {}

            t24, book = await asyncio.gather(_fetch_24hr(), _fetch_book(), return_exceptions=True)
            t24 = t24 if isinstance(t24, dict) else {}
            book = book if isinstance(book, dict) else {}
            return {
                "price": float(t24.get("lastPrice", 0)),
                "change": float(t24.get("priceChange", 0)),
                "change_pct": float(t24.get("priceChangePercent", 0)),
                "high": float(t24.get("highPrice", 0)),
                "low": float(t24.get("lowPrice", 0)),
                "volume": float(t24.get("volume", 0)),
                "quote_volume": float(t24.get("quoteVolume", 0)),
                "bid1": float(book.get("bidPrice", 0)),
                "ask1": float(book.get("askPrice", 0)),
            }
        except Exception as e:
            logger.warning(f"获取行情失败: {e}")
        return {}

    async def _rest_depth(self, symbol: str, limit: int = 10) -> dict:
        """获取订单簿"""
        if not self._session:
            return {"bids": [], "asks": []}
        try:
            async with self._session.get(
                f"{FAPI_REST}/fapi/v1/depth",
                params={"symbol": symbol, "limit": limit}, timeout=10
            ) as resp:
                if resp.status == 200:
                    d = await resp.json()
                    return {
                        "bids": [[float(p), float(q)] for p, q in d.get("bids", [])],
                        "asks": [[float(p), float(q)] for p, q in d.get("asks", [])],
                    }
                text = await resp.text()
                logger.warning(f"深度查询返回 {resp.status}: {text[:200]}")
        except Exception as e:
            logger.warning(f"获取深度失败: {e}")
        return {"bids": [], "asks": []}

    async def _rest_open_orders(self, symbol: str = "") -> list:
        """获取当前挂单"""
        params = {}
        if symbol:
            params["symbol"] = symbol
        data = await self._signed_get("/fapi/v1/openOrders", params)
        if not isinstance(data, list):
            return []
        result = []
        for o in data:
            result.append({
                "symbol": o["symbol"],
                "side": o["side"],
                "position_side": o.get("positionSide", "BOTH"),
                "type": o.get("type", ""),
                "price": float(o.get("price", 0)),
                "orig_qty": float(o.get("origQty", 0)),
                "executed_qty": float(o.get("executedQty", 0)),
                "status": o.get("status", ""),
                "time": o.get("time", 0),
                "order_id": o.get("orderId", ""),
            })
        return result

    async def _rest_cancel_order(self, symbol: str, order_id: int) -> dict:
        """撤单"""
        params = {"symbol": symbol, "orderId": order_id}
        return await self._signed_req("DELETE", "/fapi/v1/order", params)

    async def _rest_open_conditional_orders(self, symbol: str = "") -> list:
        """获取当前挂着的 TP/SL 条件单"""
        params = {}
        if symbol:
            params["symbol"] = symbol
        data = await self._signed_get("/fapi/v1/openAlgoOrders", params)
        if not isinstance(data, list):
            logger.warning(f"条件单查询返回非列表: type={type(data).__name__} data={str(data)[:200]}")
            return []
        if data:
            logger.info(f"条件单查询: {len(data)} 条 — 首条字段示例: {list(data[0].keys())[:10]}")
        result = []
        for o in data:
            result.append({
                "symbol": o["symbol"],
                "side": o["side"],
                "position_side": o.get("positionSide", "BOTH"),
                "strategy_type": o.get("type", ""),
                "strategy_status": o.get("algoStatus", ""),
                "price": float(o.get("price", 0)),
                "stop_price": float(o.get("stopPrice", 0)),
                "orig_qty": float(o.get("origQty", 0)),
                "working_type": o.get("workingType", ""),
                "time": o.get("bookTime") or o.get("time", 0),
                "strategy_id": o.get("algoId", ""),
            })
        return result

    async def _rest_cancel_conditional_order(self, symbol: str, strategy_id) -> dict:
        """撤条件单 (TP/SL)"""
        params = {"symbol": symbol, "algoId": strategy_id}
        return await self._signed_req("DELETE", "/fapi/v1/algoOrder", params)

    # ---- 精度缓存 ----

    async def _load_precisions(self):
        """从 exchangeInfo 拉取全币种精度（最多重试 3 次）"""
        for attempt in range(1, 4):
            try:
                async with self._session.get(
                    "https://fapi.binance.com/fapi/v1/exchangeInfo", timeout=15
                ) as resp:
                    if resp.status != 200:
                        text = await resp.text()
                        logger.warning(
                            f"精度加载第{attempt}次 HTTP {resp.status}: {text[:200]}"
                        )
                        if attempt < 3:
                            await asyncio.sleep(2)
                            continue
                        return
                    info = await resp.json()
                    for s in info.get("symbols", []):
                        sym = s["symbol"]
                        filters = {f["filterType"]: f for f in s.get("filters", [])}
                        self._tick_size[sym] = float(filters.get("PRICE_FILTER", {}).get("tickSize", 0.01))
                        # stepSize 优先取 LOT_SIZE，再取 MARKET_LOT_SIZE，都没有则兜底 0.001
                        lot_step    = float(filters.get("LOT_SIZE",        {}).get("stepSize", 0) or 0)
                        mkt_step    = float(filters.get("MARKET_LOT_SIZE", {}).get("stepSize", 0) or 0)
                        self._step_size[sym] = lot_step or mkt_step or 0.001
                    logger.info(f"✓ 精度缓存: {len(self._tick_size)} 币种 (尝试 {attempt} 次)")
                    return
            except Exception as e:
                logger.warning(f"精度加载第{attempt}次异常: {e}")
                if attempt < 3:
                    await asyncio.sleep(2)
        logger.error("❌ 精度加载彻底失败 — 检查代理和 fapi.binance.com 可达性，"
                     "运行时可调 POST /api/reload_precisions 重试")

    def _round_price(self, symbol: str, price: float) -> str:
        """按 tickSize 向下截断，保留正确小数位"""
        tick = self._tick_size.get(symbol)
        if not tick or tick <= 0:
            # 缓存没命中 — 按价格量级智能猜一个保守的 tick
            if price >= 1000: tick = 0.1
            elif price >= 1: tick = 0.001
            elif price >= 0.01: tick = 0.0001
            elif price >= 0.0001: tick = 0.00001
            else: tick = 0.0000001
            logger.warning(f"_round_price: {symbol} 精度未缓存，估算 tick={tick}")
        import math
        # 按 tick 向下截断
        rounded = math.floor(price / tick) * tick
        decimals = max(0, -int(math.floor(math.log10(tick))))
        return f"{rounded:.{decimals}f}"

    def _round_qty(self, symbol: str, qty: float) -> str:
        import math
        step = self._step_size.get(symbol)
        if not step or step <= 0:
            step = 0.001
        decimals = max(0, -int(math.floor(math.log10(step))))
        # 按 step 向下截断
        rounded = math.floor(qty / step) * step
        return f"{rounded:.{decimals}f}"

    # ---- 核心下单（纯 REST） ----

    async def place_order(
        self, symbol: str, side: str, quantity: float,
        order_type: str = "MARKET", price: float = None,
        position_side: str = "LONG", leverage: int = None,
        stop_price: float = None,
    ) -> dict:
        """
        单笔下订单。

        参数:
          symbol: BTCUSDT
          side: BUY / SELL
          quantity: 数量（基础币种单位）
          order_type: MARKET / LIMIT / STOP_MARKET
          price: 限价单价格
          stop_price: 止损触发价 (STOP_MARKET)
          position_side: LONG / SHORT
          leverage: 杠杆倍数 (1-125)，None 表示不修改
        """
        if not self._api_key:
            return {"simulated": True, "orderId": f"sim_{int(__import__('time').time()*1000)}"}

        qty = self._round_qty(symbol, quantity)
        params = {
            "symbol": symbol,
            "side": side,
            "positionSide": position_side,
            "type": order_type,
            "quantity": qty,
        }
        if order_type == "LIMIT" and price:
            params["price"] = self._round_price(symbol, price)
            params["timeInForce"] = "GTC"
        if order_type == "STOP_MARKET" and stop_price:
            params["stopPrice"] = self._round_price(symbol, stop_price)
        if order_type == "STOP" and stop_price:
            # STOP LIMIT: 触发后以限价成交
            params["stopPrice"] = self._round_price(symbol, stop_price)
            if price:
                params["price"] = self._round_price(symbol, price)
            params["timeInForce"] = "GTC"

        # 设置杠杆
        if leverage is not None and 1 <= leverage <= 125:
            lev_params = {
                "symbol": symbol,
                "leverage": leverage,
            }
            await self._signed_post("/fapi/v1/leverage", lev_params)

        # 直接 REST POST
        result = await self._signed_post("/fapi/v1/order", params)
        if not result:
            # 获取真实错误
            err_msg = await self._try_get_error("/fapi/v1/order", params)
            return {"error": err_msg}
        if result.get("orderId"):
            logger.info(f"下单成功: {side} {qty} {symbol} pos={position_side} → {result['orderId']}")
            return result
        return {"error": f"下单返回异常: {str(result)[:200]}"}

    async def _try_get_error(self, path: str, params: dict) -> str:
        """重发请求获取真实错误信息"""
        try:
            if not self._api_key or not self._session:
                return "API Key未配置"
            p = dict(params)
            p["timestamp"] = int(time.time() * 1000)
            p["recvWindow"] = 5000
            p = dict(sorted(p.items()))
            query = urlencode(p)
            sig = self._sign_dict(p)
            url = f"{PAPI_REST}{path}?{query}&signature={sig}"
            headers = {"X-MBX-APIKEY": self._api_key}
            async with self._session.post(url, headers=headers, timeout=10) as resp:
                if resp.status != 200:
                    try:
                        err = await resp.json()
                        return f"code={err.get('code','?')} {err.get('msg',str(err)[:100])}"
                    except Exception:
                        return f"HTTP {resp.status}"
                return "未知错误"
        except Exception as e:
            return str(e)

    async def place_conditional_order(
        self,
        symbol: str,
        side: str,
        strategy_type: str,
        stop_price: float,
        quantity: float,
        position_side: str = "LONG",
        working_type: str = "MARK_PRICE",
        price: float = None,
    ) -> dict:
        """
        挂条件单 — POST /fapi/v1/algoOrder

        strategy_type:
          STOP_MARKET / TAKE_PROFIT_MARKET — 触发后市价成交
          STOP / TAKE_PROFIT              — 触发后挂限价单 (price 必填)
          TRAILING_STOP_MARKET            — 追踪止损（callbackRate 必填）

        working_type:  MARK_PRICE（默认）/ CONTRACT_PRICE
        """
        if not self._api_key:
            return {"simulated": True, "strategyId": f"sim_{int(time.time()*1000)}"}

        params = {
            "symbol": symbol,
            "side": side,
            "positionSide": position_side,
            "type": strategy_type,
            "algoType": "CONDITIONAL",
            "triggerPrice": self._round_price(symbol, stop_price),
            "quantity": self._round_qty(symbol, quantity),
            "workingType": working_type,
            "priceProtect": "false",
        }
        # 限价条件单 (STOP / TAKE_PROFIT) 必须带 price 和 timeInForce
        if strategy_type in ("STOP", "TAKE_PROFIT") and price is not None:
            params["price"] = self._round_price(symbol, price)
            params["timeInForce"] = "GTC"

        logger.info(f"挂条件单 → POST /fapi/v1/algoOrder params={params}")
        result = await self._signed_post("/fapi/v1/algoOrder", params)
        if isinstance(result, dict) and result.get("algoId"):
            logger.info(
                f"条件单已挂: {strategy_type} {side} {params['quantity']} {symbol} "
                f"pos={position_side} triggerPrice={params['triggerPrice']} "
                f"id={result['algoId']} type={result.get('orderType','?')}"
            )
            return result
        # 失败：组装清晰错误返回
        if isinstance(result, dict) and result.get("_error"):
            err = f"code={result.get('code')} {result.get('msg','')}"
        else:
            err = f"未知响应: {str(result)[:200]}"
        logger.error(
            f"条件单失败: {strategy_type} {side} {params['quantity']} {symbol} "
            f"triggerPrice={params['triggerPrice']} → {err}"
        )
        return {"error": err}

    async def batch_orders(self, orders: list) -> list:
        """批量并发下单"""
        tasks = []
        for o in orders:
            tasks.append(self.place_order(
                symbol=o["symbol"],
                side=o["side"],
                quantity=o["quantity"],
                order_type=o.get("order_type", "MARKET"),
                price=o.get("price"),
                position_side=o.get("position_side", "LONG"),
                leverage=o.get("leverage"),
                stop_price=o.get("stopPrice"),
            ))
        results = await asyncio.gather(*tasks, return_exceptions=True)
        return [r if isinstance(r, dict) else {"error": str(r)} for r in results]
