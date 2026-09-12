"""
==========================
main.py — 程序入口
==========================
职责: 策略主循环，装配所有模块

启动流程:
  1. 初始化: DataFeed → BinanceExecutor → RiskManager
  2. 绑定策略: LiquidationHarvestStrategy + MeanRevertStrategy
  3. 心跳: 每 15s 打印持仓/PnL/余额/清算概况
  4. 等待系统信号 (SIGINT/SIGTERM)

使用方式:
  export BINANCE_API_KEY="your_key"
  export BINANCE_API_SECRET="your_secret"
  python -m binance_liq_harvest.main

环境变量:
  DASHBOARD=1   — 启用 Web 仪表盘 (localhost:8080)
  DASHBOARD_PORT — 自定义端口

退出流程:
  收到 SIGINT → 平掉所有持仓 → 关闭 WS 连接 → 输出最终报告
"""

import asyncio
import logging
import os
import signal
import sys
import time

from . import config
from .dashboard import Dashboard
from .data_feed import DataFeed
from .executor import BinanceExecutor
from .mean_revert import MeanRevertStrategy
from .risk import RiskManager
from .strategy import LiquidationHarvestStrategy


def setup_logging():
    fmt = logging.Formatter(
        "%(asctime)s [%(levelname)s] %(name)s: %(message)s",
        datefmt="%H:%M:%S",
    )
    handler = logging.StreamHandler(sys.stderr)  # stderr 无缓冲
    handler.setFormatter(fmt)
    root = logging.getLogger()
    root.setLevel(getattr(logging, config.LOG_LEVEL))
    # 强制无缓冲
    sys.stderr.reconfigure(line_buffering=True) if hasattr(sys.stderr, 'reconfigure') else None
    root.handlers.clear()
    root.addHandler(handler)


async def heartbeat(feed, risk, mr_strat, executor):
    """定期打印状态摘要"""
    while True:
        await asyncio.sleep(config.HEARTBEAT_INTERVAL_SEC)
        if mr_strat:
            mr_strat.check_exits()

        positions = list(risk.positions.values())
        if positions:
            pos_str = ", ".join(
                f"{p.symbol} {p.side}@{p.entry_price:.4f}({p.holding_seconds:.0f}s)"
                for p in positions
            )
        else:
            pos_str = "无"

        balance = await executor.get_balance()
        active_syms = set()
        for _, _, _, sym in feed.liquidation_window:
            active_syms.add(sym)
        liq_info = f" 清算:{len(active_syms)}币" if active_syms else ""

        logging.getLogger("heartbeat").info(
            f"持仓 [{pos_str}] | PnL {risk.daily_pnl:+.3f}U | 交易 {risk.daily_trades}笔 | "
            f"余额 {balance:.4f}U | {len(config.SYMBOLS)}币{liq_info}"
        )


async def main():
    setup_logging()
    logger = logging.getLogger("main")

    logger.info("=" * 50)
    logger.info("清算瀑布收割策略 — 小账户模式")
    logger.info(f"模式: {'测试网' if config.USE_TESTNET else '🔥 实盘 🔥'}")
    logger.info(f"杠杆: {config.LEVERAGE}x | 保证金模式: {config.MARGIN_MODE}")
    logger.info(f"监控: {config.SYMBOLS}")
    logger.info(f"清算阈值: {config.LIQUIDATION_THRESHOLD:,}U")
    logger.info(f"仓位: {config.POSITION_SIZE_USDT}U/笔 (保证金 ~{config.POSITION_SIZE_USDT/config.LEVERAGE:.2f}U)")
    logger.info(f"止盈: {config.TAKE_PROFIT_PCT:.1%} | 止损: {config.STOP_LOSS_PCT:.1%}")
    logger.info(f"日亏损上限: {config.MAX_DAILY_LOSS_USDT}U")
    logger.info("=" * 50)

    # 初始化
    feed = DataFeed()
    executor = BinanceExecutor()
    risk = RiskManager()

    await executor.start()

    balance = await executor.get_balance()
    logger.info(f"账户余额: {balance:.4f} USDT")
    logger.info(f"最大名义价值: {balance * config.LEVERAGE:.2f} USDT")
    logger.info(f"SOL 最小名义: $5, 步长 0.01 SOL ≈ $0.95")

    # 清算瀑布策略
    strategy = LiquidationHarvestStrategy(feed, executor, risk)
    strategy.bind()

    # 均值回归策略（共享风控，总敞口统一控制）
    mr_strategy = MeanRevertStrategy(feed, executor, risk)
    mr_strategy.bind()
    logger.info(f"均值回归: 监控 20 币, RSI 超卖<25/超买>75, 5U/笔 (共享仓位:{config.MAX_POSITIONS})")

    # Dashboard (可选，通过 DASHBOARD=1 环境变量启用)
    dashboard = None
    if os.environ.get("DASHBOARD") == "1":
        dashboard = Dashboard(feed, risk, executor)
        await dashboard.start(port=int(os.environ.get("DASHBOARD_PORT", "8080")))
        logger.info("Dashboard 模式已启用")

    # 启动
    logger.info("创建后台任务...")
    feed_task = asyncio.create_task(feed.start())
    hb_task = asyncio.create_task(heartbeat(feed, risk, mr_strategy, executor))
    # 确保未捕获的异常打印出来（排除 CancelledError，那是正常关闭）
    for t in [feed_task, hb_task]:
        t.add_done_callback(lambda t: (logger.error(f"Task crashed: {t.exception()}") if t.exception() and not isinstance(t.exception(), asyncio.CancelledError) else None))
    logger.info("进入等待循环")

    # 信号退出
    loop = asyncio.get_running_loop()
    shutdown_event = asyncio.Event()

    def on_signal(sig):
        logger.info(f"收到信号 {sig.name}，正在退出...")
        shutdown_event.set()

    for sig in (signal.SIGINT, signal.SIGTERM):
        try:
            loop.add_signal_handler(sig, on_signal, sig)
        except NotImplementedError:
            signal.signal(sig, lambda s, _: shutdown_event.set())

    await shutdown_event.wait()

    # 平仓
    logger.info("正在平掉所有持仓...")
    for symbol, pos in list(risk.positions.items()):
        exit_side = "SELL" if pos.side == "LONG" else "BUY"
        try:
            px = await executor.place_market_order(symbol, exit_side, pos.quantity)
            if px:
                risk.close_position(symbol, px, "SHUTDOWN")
        except Exception:
            logger.exception(f"平仓失败 {symbol}")

    logger.info("正在关闭连接...")
    await feed.stop()
    feed_task.cancel()
    hb_task.cancel()
    if dashboard:
        await dashboard.stop()
    await executor.stop()

    logger.info(f"最终: PnL {risk.daily_pnl:+.4f}U | 交易 {risk.daily_trades}笔")
    logger.info("策略已停止")


if __name__ == "__main__":
    asyncio.run(main())
