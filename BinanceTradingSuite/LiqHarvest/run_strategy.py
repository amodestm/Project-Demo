#!/usr/bin/env python3
"""
策略运行器 — 读取 config JSON 覆盖常量后启动引擎，持续写入状态文件
用法:
  python3 run_strategy.py --strategy scalp --config strategy_config.json
  python3 run_strategy.py --strategy bottom --config strategy_config.json
"""
import argparse
import json
import os
import signal
import sys
import time

# 解析参数
parser = argparse.ArgumentParser()
parser.add_argument("--strategy", required=True, choices=["scalp", "bottom"])
parser.add_argument("--config", default="strategy_config.json")
args = parser.parse_args()

# 读取配置
with open(args.config) as f:
    config = json.load(f)[args.strategy]

STATUS_FILE = f"/tmp/bf_status_{args.strategy}.json"

# ── 通过 globals() 覆盖常量 ──
def _override(module_name: str, overrides: dict):
    mod = sys.modules.get(module_name)
    if mod is None:
        mod = __import__(module_name)
        mod = sys.modules[module_name]
    for k, v in overrides.items():
        setattr(mod, k, v)
        print(f"  {k} = {v}")

# 先导入策略文件，立即覆盖常量
from collections import deque
import logging

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s.%(msecs)03d [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
logger = logging.getLogger(__name__)

if args.strategy == "scalp":
    import scalp_harvester as mod
    _override("scalp_harvester", {
        "LEVERAGE": config.get("LEVERAGE", 20),
        "ENTRY_THRESHOLD_PCT": config.get("ENTRY_THRESHOLD_PCT", 0.13),
        "TP_MARGIN_PCT": config.get("TP_MARGIN_PCT", 2.35),
        "SL_MARGIN_PCT": config.get("SL_MARGIN_PCT", 10.0),
        "POSITION_PCT": config.get("POSITION_PCT", 0.45),
        "MAX_POSITIONS": config.get("MAX_POSITIONS", 2),
        "MAX_DAILY_LOSS_USDT": config.get("MAX_DAILY_LOSS_USDT", 20.0),
        "MIN_24H_VOLUME_USDT": config.get("MIN_24H_VOLUME_USDT", 20000000),
        "USE_TREND_FILTER": config.get("USE_TREND_FILTER", True),
        "TREND_WINDOW_TICKS": config.get("TREND_WINDOW_TICKS", 2400),
        "MEAN_REVERSION_PCT": config.get("MEAN_REVERSION_PCT", 0.35),
        "USE_KLINE_FILTER": config.get("USE_KLINE_FILTER", True),
        "USE_MA7_FILTER": config.get("USE_MA7_FILTER", True),
        "MAX_6M_CHANGE_PCT": config.get("MAX_6M_CHANGE_PCT", 3.0),
    })
    engine = mod.ScalpEngine()
elif args.strategy == "bottom":
    import bottom_fisher as mod
    _override("bottom_fisher", {
        "LEVERAGE": config.get("LEVERAGE", 20),
        "TP_MARGIN_PCT": config.get("TP_MARGIN_PCT", 50.0),
        "SL_MARGIN_PCT": config.get("SL_MARGIN_PCT", 15.0),
        "POSITION_PCT": config.get("POSITION_PCT", 0.45),
        "LOOKBACK_MINUTES": config.get("LOOKBACK_MINUTES", 90),
        "TRIGGER_DISCOUNT": config.get("TRIGGER_DISCOUNT", 0.95),
        "SCAN_INTERVAL": config.get("SCAN_INTERVAL", 30),
        "MAX_DAILY_LOSS_USDT": config.get("MAX_DAILY_LOSS_USDT", 20.0),
        "MIN_24H_VOLUME_USDT": config.get("MIN_24H_VOLUME_USDT", 20000000),
    })
    engine = mod.BottomFisherEngine()

# ── 写入启动状态 ──
_start_time = time.time()

def _write_status():
    try:
        data = {
            "running": getattr(engine, "_running", False),
            "pid": os.getpid(),
            "started_at": _start_time,
            "positions": len(getattr(engine, "positions", {})),
            "daily_pnl": round(getattr(engine, "_daily_pnl", 0.0), 4),
            "balance": round(getattr(engine, "_ref_balance", 0.0), 4),
            "coins": len(getattr(engine, "coins", [])),
        }
        with open(STATUS_FILE, "w") as f:
            json.dump(data, f)
    except Exception:
        pass

# ── 启动后挂状态写入到主循环（利用 engine 已有的循环） ──
# 如果 engine 已有 _main_loop，我们在外部再开一个协程写状态
import asyncio

async def _status_writer():
    while getattr(engine, "_running", False):
        _write_status()
        await asyncio.sleep(2)

# 修改 engine.run() 使其也启动状态写入
_orig_run = engine.run
async def _patched_run():
    # 写初始状态
    _write_status()
    # 并行启动原 run + 状态写入
    await asyncio.gather(
        _orig_run(),
        _status_writer(),
    )
engine.run = _patched_run

# 注册信号处理（在 stop 时写最终状态）
def _finalize(signum, frame):
    _write_status()
    sys.exit(0)
signal.signal(signal.SIGTERM, _finalize)
signal.signal(signal.SIGINT, _finalize)

logger.info("🚀 启动 %s (PID=%d)", args.strategy, os.getpid())
logger.info("📋 配置: %s", json.dumps(config, ensure_ascii=False))

# 启动
asyncio.run(engine.run())

# 退出时写最终状态
_write_status()
