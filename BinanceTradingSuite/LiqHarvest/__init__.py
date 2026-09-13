"""
binance_liq_harvest — Binance 清算瀑布收割 + RSI 均值回归策略

依赖:
  - python-binance (AsyncClient + DepthCacheManager)
  - websockets, aiohttp, aiohttp-socks

用法:
  export BINANCE_API_KEY="your_key"
  export BINANCE_API_SECRET="your_secret"
  python -m binance_liq_harvest.main
"""
