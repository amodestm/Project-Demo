"""
=====================================
hedge_manager.py — 对冲组合管理器
=====================================
职责: 对冲组合的定义、管理、一键执行
  - 预设组合模板 (预设对冲对)
  - 自定义组合
  - 批量下单引擎 (并发执行多腿)

组合格式:
  {
    "name": "ETH-BTC 对冲",
    "legs": [
      {"symbol": "ETHUSDT", "side": "BUY",  "qty": 0.01, "pos": "LONG"},
      {"symbol": "BTCUSDT", "side": "SELL", "qty": 0.001, "pos": "SHORT"}
    ]
  }

三种一键操作:
  - 做多:  所有腿 side=BUY, pos=LONG
  - 做空:  所有腿 side=SELL, pos=SHORT
  - 对冲:  legs 自己定义的混合方向
"""
import logging
from dataclasses import dataclass, field
from typing import Dict, List, Optional

from .executor_client import PlatformExecutor

logger = logging.getLogger(__name__)


@dataclass
class HedgeLeg:
    """对冲组合的一条腿"""
    symbol: str           # e.g. ETHUSDT
    side: str             # BUY / SELL
    quantity: float       # 数量
    position_side: str    # LONG / SHORT


@dataclass
class HedgeCombo:
    """对冲组合"""
    name: str
    legs: List[HedgeLeg] = field(default_factory=list)
    is_active: bool = True


# ============================================================
# 预设对冲组合模板
# ============================================================
PRESET_COMBOS = {
    "eth_btc": HedgeCombo(
        name="ETH-BTC 主流对冲",
        legs=[
            HedgeLeg("ETHUSDT", "BUY", 0.01, "LONG"),
            HedgeLeg("BTCUSDT", "SELL", 0.001, "SHORT"),
        ],
    ),
    "eth_sol": HedgeCombo(
        name="ETH-SOL 山寨对冲",
        legs=[
            HedgeLeg("ETHUSDT", "BUY", 0.01, "LONG"),
            HedgeLeg("SOLUSDT", "SELL", 0.5, "SHORT"),
        ],
    ),
    "btc_sol": HedgeCombo(
        name="BTC-SOL 大币对小币",
        legs=[
            HedgeLeg("BTCUSDT", "BUY", 0.001, "LONG"),
            HedgeLeg("SOLUSDT", "SELL", 0.5, "SHORT"),
        ],
    ),
}


class HedgeManager:
    """对冲组合管理器"""

    def __init__(self, executor: PlatformExecutor):
        self.executor = executor
        self.custom_combos: Dict[str, HedgeCombo] = {}
        self._combo_counter = 0

    # ---- 组合管理 ----

    def list_combos(self) -> dict:
        """返回所有可用组合（预设+自定义）"""
        result = {}
        for name, combo in PRESET_COMBOS.items():
            result[name] = {
                "name": combo.name,
                "legs": [{"symbol": l.symbol, "side": l.side,
                          "quantity": l.quantity, "position_side": l.position_side}
                         for l in combo.legs],
                "preset": True,
            }
        for name, combo in self.custom_combos.items():
            result[name] = {
                "name": combo.name,
                "legs": [{"symbol": l.symbol, "side": l.side,
                          "quantity": l.quantity, "position_side": l.position_side}
                         for l in combo.legs],
                "preset": False,
            }
        return result

    def save_combo(self, name: str, legs: list) -> str:
        """
        保存自定义组合。
        legs: [{"symbol":"ETHUSDT","side":"BUY","quantity":0.01,"position_side":"LONG"}, ...]
        """
        key = f"custom_{self._combo_counter}"
        self._combo_counter += 1
        self.custom_combos[key] = HedgeCombo(
            name=name,
            legs=[HedgeLeg(**l) for l in legs],
        )
        return key

    def delete_combo(self, key: str):
        if key in self.custom_combos:
            del self.custom_combos[key]

    # ---- 执行 ----

    async def execute_combo(self, combo_key: str, mode: str = "hedge") -> dict:
        """
        执行组合。

        mode:
          - "hedge":  按组合定义的原方向执行
          - "long":   所有腿改为做多
          - "short":  所有腿改为做空
        """
        combo = PRESET_COMBOS.get(combo_key) or self.custom_combos.get(combo_key)
        if not combo:
            return {"error": f"组合 '{combo_key}' 不存在"}

        orders = []
        for leg in combo.legs:
            if mode == "long":
                orders.append({
                    "symbol": leg.symbol,
                    "side": "BUY",
                    "quantity": leg.quantity,
                    "position_side": "LONG",
                })
            elif mode == "short":
                orders.append({
                    "symbol": leg.symbol,
                    "side": "SELL",
                    "quantity": leg.quantity,
                    "position_side": "SHORT",
                })
            else:  # hedge
                orders.append({
                    "symbol": leg.symbol,
                    "side": leg.side,
                    "quantity": leg.quantity,
                    "position_side": leg.position_side,
                })

        # 批量并发执行
        results = await self.executor.batch_orders(orders)

        # 统计
        success = sum(1 for r in results if "error" not in r and "simulated" not in r)
        failed = sum(1 for r in results if "error" in r)
        simulated = sum(1 for r in results if "simulated" in r)

        return {
            "mode": mode,
            "combo": combo.name,
            "total_legs": len(orders),
            "success": success,
            "failed": failed,
            "simulated": simulated,
            "details": [
                {"symbol": o["symbol"], "side": o["side"],
                 "quantity": o["quantity"], "position_side": o["position_side"],
                 "result": r.get("orderId", r.get("error", "simulated"))}
                for o, r in zip(orders, results)
            ],
        }

    async def execute_custom(self, legs: list, mode: str = "hedge") -> dict:
        """
        执行自定义下单（不保存组合）。
        legs: [{"symbol":"ETHUSDT","side":"BUY","quantity":0.01,"position_side":"LONG"}, ...]
        mode: "hedge" / "long" / "short"
        """
        orders = []
        for leg in legs:
            base = {"symbol": leg["symbol"], "quantity": leg["quantity"]}
            if mode == "long":
                base.update({"side": "BUY", "position_side": "LONG"})
            elif mode == "short":
                base.update({"side": "SELL", "position_side": "SHORT"})
            else:
                base.update({"side": leg["side"],
                             "position_side": leg.get("position_side", "LONG")})
            # 透传 order_type、price、stopPrice、leverage
            if "order_type" in leg:
                base["order_type"] = leg["order_type"]
            if "price" in leg and leg["price"] is not None:
                base["price"] = leg["price"]
            if "stopPrice" in leg and leg["stopPrice"] is not None:
                base["stopPrice"] = leg["stopPrice"]
            if "leverage" in leg:
                base["leverage"] = leg["leverage"]
            orders.append(base)

        results = await self.executor.batch_orders(orders)
        success = sum(1 for r in results if "error" not in r and "simulated" not in r)
        failed = sum(1 for r in results if "error" in r)

        return {
            "mode": mode,
            "total_legs": len(orders),
            "success": success,
            "failed": failed,
            "details": [
                {"symbol": o["symbol"], "side": o["side"],
                 "quantity": o["quantity"], "position_side": o["position_side"],
                 "result": r.get("orderId", r.get("error", "simulated"))}
                for o, r in zip(orders, results)
            ],
        }
