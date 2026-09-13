# Scalp Harvester v2 — 全仓顺趋势高频追进

独立测试脚本 `scalp_harvester.py`

## 策略

**全仓顺趋势高频追进** — 监控 Top 30 成交量币种的实时价格推送，检测到价格变动超过 0.3% 时直接全仓市价顺势追进。

## 架构

```
WS bookTicker ──→ bid1/ask1 ──→ mid-price ──→ 滚动窗口(15笔去极值均值)
      ↓                                        ↓
  实时推送 (~50ms)                      每200ms扫描变动率
                                               ↓
                            变动 > 0.3% → 顺向市价开全仓
                            止盈 +3% ╱ 止损 -5% (含手续费)
                            软件层价格比较，市价平仓
```

## 参数

| 参数 | 值 | 说明 |
|------|-----|------|
| 杠杆 | 20x | 全仓 CROSSED |
| 入场 | 市价单 | 立即成交 |
| 出场 | 市价单 | 软件层监控后发出 |
| 入场触发 | 价格变动 > 0.3% | 涨做多，跌做空 |
| 仓位 | 全仓 | 余额 × 20x |
| 并发 | 最多 1 笔 | 全仓模式 |
| 窗口 | 15 笔 | ~3s (WS 推送) |
| 止盈 | +3% 保证金 | 含手续费 ≈0.22% 价格变动 |
| 止损 | -5% 保证金 | 含手续费 ≈0.18% 价格变动 |
| 监控 | Top 30 | 按 24h 成交量排序 |

## 手续费模型

- 入场限价 Maker: 0.02%
- 出场市价 Taker: 0.05%
- 总费率: 0.07%（名义价值）
- 对保证金影响: 0.07% × 20x = 1.4%
- TP/SL 价格已包含手续费

## 启动

```bash
cd /Users/<YOUR_USER>/WorkBuddy/binance_liq_harvest
python3 scalp_harvester.py
```

## 依赖

- 环境变量 `BINANCE_API_KEY` / `BINANCE_API_SECRET`（自动从 `trading_platform/start.sh` 读取）
- Python 3.9+
- `aiohttp`, `aiohttp_socks`

## 文件结构

```
binance_liq_harvest/
├── scalp_harvester.py         ← 主脚本 (v2 全仓顺趋势)
├── trading_platform/
│   ├── executor_client.py     ← 执行层（下单、精度、签名）
│   ├── start.sh               ← API Key 来源
│   └── app.py                 ← 桌面端后端
└── config.py                  ← 共享配置
```
