# Binance Liquidation Harvest Strategy — 项目文档

> 最后更新: 2026-05-13 09:17 CST

## 项目概述

Binance 统一账户自动交易系统。包含两个并行策略：

| 策略 | 触发条件 | 频率 | 持仓时间 |
|------|---------|------|---------|
| **清算瀑布收割** | 强制平仓事件 + 订单簿失衡 + VWAP 偏离 | 低频（一天几次） | 秒~分钟 |
| **RSI 均值回归** | RSI < 20 超卖 / RSI > 80 超买 + VWAP 确认 | 中频（一小时几次） | 分钟级 |

## 账户配置

- 账户类型: Binance **统一账户 (Portfolio Margin)**
- API 端点: `https://papi.binance.com` (不是 `fapi.binance.com`)
- 杠杆: **20x 全仓 (CROSSED)**
- 保证金模式: **Hedge Mode** (双向持仓)
- 账户余额: ~$2-3 USDC
- 单笔仓位: $5 名义价值 (保证金 ~$0.25)

## API 凭证

API Key 和 Secret 保存在 `run.sh` 中，启动时自动注入环境变量。

**API 权限要求**: Enable Futures（统一账户可能不显示此选项，无需勾选其他）
**IP 限制**: 必须设为「不限制」
**注意**: 统一账户用 `/papi/` 端点，不是 `/fapi/`

## 文件结构

```
binance_liq_harvest/
├── CLAUDE.md          ← 本文档
├── run.sh             # 一键启动脚本 (包含API Key)
├── requirements.txt   # websockets, aiohttp, aiohttp-socks
├── config.py          # 所有策略参数、交易对列表(528币种)、连接配置
├── main.py            # 异步主循环、心跳日志、优雅退出
├── data_feed.py       # WebSocket 数据源 (528币深度+K线+全市场清算)
├── executor.py        # PAPI REST 签名请求、下单/平仓/杠杆/精度缓存
├── strategy.py        # 清算瀑布策略: 信号检测 + 入场/出场逻辑
├── mean_revert.py     # RSI 均值回归策略: 超买超卖信号
├── risk.py            # 风控: 仓位管理/止盈止损/手续费/日亏损上限
├── trade_db.py        # SQLite 交易记录: 日报表/权益曲线
├── dashboard.py       # Web 仪表盘 (DASHBOARD=1 启用, port 8080)
├── notifier.py        # Telegram 通知 (需配置 TELEGRAM_BOT_TOKEN)
└── optimizer.py       # 待构建: 自适应参数优化
```

## 各文件详细说明

### config.py
全系统参数配置，修改后重启生效。
- `SYMBOLS`: 528 个 USDT 交易对
- `LEVERAGE`: 20, `MARGIN_MODE`: "CROSSED"
- 清算阈值: `LIQUIDATION_THRESHOLD=20_000`, `LIQUIDATION_WINDOW_SEC=120`
- 深度: `DEPTH_IMBALANCE_RATIO=1.1`, `MIN_DEPTH_USDT=2000`
- VWAP: `VWAP_DEVIATION=0.005`
- 出场: `TAKE_PROFIT_PCT=0.008`, `STOP_LOSS_PCT=0.010`
- 风控: `POSITION_SIZE_USDT=5`, `MAX_DAILY_LOSS_USDT=0.20`
- 费率: `MAKER_FEE=0.0002`, `TAKER_FEE=0.0004`
- 连接: 2026 新架构 `public` + `market` 双端点

### data_feed.py
WebSocket 数据源管理器。
- **3 个 WS 连接**: public(深度裸消息) + market(K线包裹消息) + forceOrder(全市场清算)
- 528 币种全量订阅深度 (@depth20@500ms) 和 K线 (@kline_1m)
- 数据结构: `DepthSnapshot`, `KlineSnapshot`, `LiquidationEvent`, `VWAPState`
- VWAP: 滚动 30 根 1m K 线计算
- 清算窗口: 120 秒滑动窗口，过滤 $100 以下事件
- 回调系统: on_liquidation / on_kline / on_depth
- 自动重连: 断开 3 秒后重连
- **关键**: 2026 年 Binance 新 WS 架构，public 用 path 模式裸消息，market 用 stream 模式包裹消息

### executor.py
Binance 统一账户 Portfolio Margin API 执行层。
- 基 URL: `https://papi.binance.com` (统一账户专用，不是 `/fapi/`)
- 端点: `/papi/v1/um/order`, `/papi/v1/um/leverage`, `/papi/v1/balance`
- SOCKS5 代理: 走 `127.0.0.1:7897` (Clash)
- 精度缓存: 启动时从 `fapi.binance.com/exchangeInfo` 拉取所有币种的 tickSize/stepSize
- **Hedge Mode 支持**: 所有订单传 `positionSide` 参数
- 最小名义价值保护: 自动调整数量到 ≥$5
- 签名: HMAC SHA256 + recvWindow=5000

### strategy.py (清算瀑布)
三条件入场逻辑：
1. 清算事件发生（任意额度）
2. 订单簿失衡 (asks/bids > 1.1 做多, < 0.91 做空)
3. VWAP 偏离 > 0.5%
出场: TP 0.8% / SL 1.0% / 超时 300s / VWAP 回归
- 诊断日志: 每币每 60s 输出条件不满足的原因

### mean_revert.py (均值回归)
RSI 超买超卖策略。
- 监控前 20 高流动性币种
- RSI 14 期, 超卖 < 20 (做多), 超买 > 80 (做空)
- VWAP 确认: 超卖+价格低于VWAP / 超买+价格高于VWAP
- 出场: TP 0.3% / SL 0.5% / RSI 回到 45-55 / 超时 120s
- 冷却: 同币种 30s 内不重复发信号
- 冷启动保护: 至少 5 根 K 线才入场

### risk.py
全局风控管理器（两个策略共享）。
- 持仓限制: MAX_POSITIONS=1 (同一时间最多一个持仓)
- 日亏损上限: $0.20
- 日交易上限: 30 笔
- 手续费: 入场 Maker 0.02% + 出场 Taker 0.04%
- SQLite 持久化: 平仓自动写入交易记录
- 信号历史: 最近 50 条，供 Dashboard 读取

### main.py
异步主循环。
- 启动流程: 日志 → 数据源 → 执行器 → 策略绑定 → 心跳 → 等待信号
- 心跳 15s/次: 持仓、PnL、交易数、余额、清算币种数
- 优雅退出: SIGTERM → 平掉所有持仓 → 关闭连接
- 异常捕获: `add_done_callback` 确保 Task 崩溃可见
- **关键**: 日志写 stderr 保证无缓冲输出

### trade_db.py
SQLite 交易数据库。
- 表: `trades` (逐笔), `daily_summary` (日报)
- 函数: `init_db`, `insert_trade`, `get_daily_summary`, `get_all_trades`, `get_equity_curve`

## 已解决的问题

### 1. API 端点错误 (-2015)
**症状**: 调用 `/fapi/` 返回 401  
**原因**: 统一账户必须用 `/papi/` 端点  
**解决**: 改为 `https://papi.binance.com` + `/papi/v1/um/*`

### 2. WebSocket 2026 架构升级
**症状**: 旧 `wss://fstream.binance.com/stream` 退役  
**解决**: 分离为 `public`(path 模式) + `market`(stream 模式) 双端点

### 3. 事件循环阻塞
**症状**: 心跳日志完全不输出  
**原因**: 多个 bug 叠加 — (a) heartbeat 函数中 `mr_strategy` 未传入导致 NameError (b) 异常被 asyncio task 吞掉 (c) `asyncio.gather` 等待永不完成的任务  
**解决**: 修复参数传递 + 添加 `add_done_callback` 异常捕获 + 移除 gather 阻塞

### 4. 日志缓冲
**症状**: stdout 重定向到文件后无输出  
**解决**: logging 改为写 `sys.stderr`（行缓冲），加 `PYTHONUNBUFFERED=1`

### 5. Hedge Mode 下单失败 (-4061)
**症状**: `Order's position side does not match user's setting`  
**原因**: 账户是双向持仓模式，订单缺少 `positionSide` 参数  
**解决**: 所有下单/平仓加 `positionSide=LONG/SHORT`

### 6. 精度错误 (-1111)
**症状**: `Precision is over the maximum defined for this asset`  
**原因**: 部分币种的 tickSize/stepSize 硬编码错误  
**解决**: 启动时从 exchangeInfo API 动态拉取精度表

### 7. 名义价值不足 (-4164)
**症状**: `Order's notional must be greater than 5`  
**解决**: `place_limit_order` 自动检查并调整数量到 ≥$5

### 8. API Key 失效 (-2015)
**症状**: 新建的 Key 持续返回 401  
**原因**: (a) 用户是统一账户，API Key 权限页面没有单独的 "Enable Futures" 选项 (b) IP 白名单限制  
**解决**: 用户去 Binance API 管理设为 IP 无限制

## 待优化的问题

### 🔴 高优先级
1. **信号从未实际成交**: 均值回归信号频繁触发但订单全因精度/模式问题失败。修复后需要验证是否真实成交。
2. **清算信号诊断不足**: 只知道 VWAP 偏离不够，不知道每个被清算币种的完整条件状态。需要更全面的诊断。
3. **杠杆设置失败**: 部分币种返回 `-4028 Invalid leverage`，需要调查哪些币种不支持 20x。

### 🟡 中优先级
4. **自适应优化器未完成**: optimizer.py 尚未构建。需要根据交易记录自动调参。
5. **Telegram 通知未启用**: notifier.py 已有代码但集成注释未取消。
6. **Web Dashboard 未测试**: dashboard.py 存在但未验证。
7. **528 币种杠杆并发设置**: 并发设杠杆可能触发 API 限频。需要分批或加延迟。

### 🟢 低优先级
10. **精度缓存依赖 fapi 端点**: 统一账户应该用 papi 的 exchangeInfo（但 papi 没有公开的 exchangeInfo 端点，只能用 fapi 的）。
11. **日风控重置**: `reset_daily()` 方法存在但从未被调用，需要定时器或外部触发。
12. **单仓位限制过严**: MAX_POSITIONS=1 且两个策略共享风控，可能互相阻塞。
13. **USDC vs USDT 余额**: get_balance 查 USDC 但日志显示 "USDT"，标签不准确。

## 运行方式

```bash
cd /Users/<YOUR_USER>/WorkBuddy
./binance_liq_harvest/run.sh

# 或手动:
export BINANCE_API_KEY="..."
export BINANCE_API_SECRET="..."
export PYTHONUNBUFFERED=1
/Users/<YOUR_USER>/miniforge3/bin/python3 -u -m binance_liq_harvest.main

# 监控:
tail -f /tmp/liq_harvest.err   # 实时日志 (stderr)
ps aux | grep binance_liq      # 查看进程
kill <PID>                     # 停止
```

### 对冲交易平台（桌面端）

```bash
# 一键启动（后端 + 桌面端自动开）
cd /Users/<YOUR_USER>/WorkBuddy/binance_liq_harvest
bash trading_platform/start.sh
```

> 后端启动后访问 http://localhost:9090 也有 Web 版 UI。

## 依赖

- Python 3.12+ (miniforge3 环境)
- websockets (WebSocket 客户端)
- aiohttp + aiohttp-socks (HTTP + SOCKS5 代理)
- python-socks (WebSocket 代理支持)
