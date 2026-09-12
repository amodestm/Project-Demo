"""
========================================
trading_platform — 一键对冲交易平台
========================================
Binance 一键多空对冲交易系统。
支持同时开多/开空、预设对冲组合、实时行情监控。

文件结构:
  app.py              — aiohttp Web 服务 + WS 实时推送
  hedge_manager.py    — 对冲组合定义 + 批量下单引擎
  executor_client.py  — 基于 python-binance 的低延迟执行层

依赖: python-binance, aiohttp, websockets

用法:
  cd binance_liq_harvest
  python -m trading_platform.app
"""
