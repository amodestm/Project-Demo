# LiqHarvest — 实时行情驱动的自动化交易系统

> 完整源码目录。**LiquidationMonitor**（行情形态监控）与 **QuickTrade**（下单终端）是本系统抽取出去的两个子系统，在仓库顶层有独立 README；本目录是自包含的全量代码。

---

## 一、这个工具是干什么的

一句话：**实时监听全市场 Binance 交易对的行情与强平事件，用多套信号策略自动生成交易信号，自动下单、自动风控、自动记录，并把整个过程可视化。**

### 要解决的问题

手动交易盯不住 600+ 个交易对，而剧烈波动（强平瀑布、砸盘、急跌）往往在几十秒内结束。这个系统把「**看盘 → 判断 → 下单 → 止损 → 复盘**」整条链路自动化：

| 环节 | 人工痛点 | 系统做法 |
|------|---------|---------|
| 看盘 | 盯不过来 600+ 标的 | WebSocket 全市场订阅，毫秒级事件驱动 |
| 判断 | 情绪化、不一致 | 6 套策略，阈值写死在配置里，信号可复现 |
| 下单 | 手速跟不上 | REST 直连下单，含精度/名义价值自动校正 |
| 风控 | 亏了舍不得割 | 硬性止损、日亏损上限、最大持仓数，代码强制执行 |
| 复盘 | 凭记忆 | SQLite 逐笔落库，日报自动统计胜率与净利 |

### 设计目的

1. **工程链路优先** —— 目标是打通「低延迟数据 → 信号 → 执行 → 风控 → 可视化」闭环，参数目前以人工调为主。
2. **故障可诊断** —— 每个模块都有明确职责边界，下单失败按错误码分类处理（见下文"已解决的坑"）。
3. **可审计** —— 每笔交易入库，权益曲线可回溯。

---

## 二、系统架构

```
┌─────────────────────────────────────────────────────────┐
│  数据层  data_feed.py                                    │
│  3 路 WebSocket：深度流 / K线流 / 全市场强平流            │
│  维护：订单簿快照 · K线缓存 · 滚动 VWAP(30根) · 清算窗口  │
└──────────────────────┬──────────────────────────────────┘
                       │ 回调分发 on_depth / on_kline / on_liquidation
┌──────────────────────▼──────────────────────────────────┐
│  策略层  strategy.py · mean_revert.py · scalp_harvester.py│
│          three_wave_screener.py · bottom_fisher.py        │
│          scalp_move75x.py                                 │
└──────────────────────┬──────────────────────────────────┘
                       │ 信号
┌──────────────────────▼──────────────────────────────────┐
│  风控层  risk.py        持仓数 / 日亏损 / 日笔数 / TP·SL  │
├─────────────────────────────────────────────────────────┤
│  执行层  executor.py    HMAC-SHA256 签名 · 动态精度缓存   │
├─────────────────────────────────────────────────────────┤
│  持久化  trade_db.py    SQLite 逐笔 + 日报 + 权益曲线     │
├─────────────────────────────────────────────────────────┤
│  展示层  dashboard.py(Flask) · monitor.py(终端) ·        │
│          notifier.py(Telegram) · liquidation_bar.5s.py    │
│          (SwiftBar 菜单栏挂件)                            │
└─────────────────────────────────────────────────────────┘
```

---

## 三、模块功能一览

### 数据层

| 文件 | 功能 |
|------|------|
| `data_feed.py` | 3 路 WebSocket 管理器。订阅全市场 `!forceOrder@arr`（强平）、`!miniTicker@arr`（价格）、深度与 1min K线；维护滚动 VWAP（30 根 K线）、120s 清算滑动窗口；断线 3 秒自动重连 |
| `price_drop_monitor.py` | 独立轻量脚本：当前价低于 1 分钟前快照 3% 时触发终端 + macOS 系统通知 |

### 策略层（6 套）

| 文件 | 类型 | 核心逻辑 | 出场 |
|------|------|---------|------|
| `strategy.py` | 事件驱动 | **清算瀑布收割**：强平事件 + 订单簿失衡（>1.1 做多 / <0.91 做空）+ VWAP 偏离 >0.5%，三条件 AND | TP 0.8% / SL 1.0% / 超时 300s / VWAP 回归 |
| `mean_revert.py` | 均值回归 | RSI(14) <20 超卖且价低于 VWAP → 做多；>80 超买且价高于 VWAP → 做空 | TP 0.3% / SL 0.5% / RSI 回 45–55 / 超时 120s |
| `scalp_harvester.py` | 高频顺势 | Top30 成交量标的，价格变动超阈值顺势追进，全仓 20x，市价入场，软件层 200ms 扫描 | TP 3% / SL 5%（按保证金计） |
| `three_wave_screener.py` | 形态识别 | 三浪下跌（H1→L1→H2→L2，H2<H1 且 L2<L1），四维加权评分：趋势 35 / 动能 30 / 结构 25 / 确认 10，另加拉升 15、高点质量 15 | 分 S(≥80) / A(≥60) / B(≥40) / C 四级 |
| `bottom_fisher.py` | 超跌反弹 | 当前价 < 90min 最低价 × 0.95 → 做多（只做多）；触发后 180min 冷却 | TP 50% / SL 15%（按保证金计） |
| `scalp_move75x.py` | 剥头皮 | 单标的 75x 多空双开，开仓后秒挂限价止盈（Maker 返佣） | 仅止盈 |

### 执行层

`executor.py` —— Binance 统一账户（Portfolio Margin）REST 执行：

- HMAC-SHA256 签名，`recvWindow=5000`
- **Hedge Mode**：所有订单带 `positionSide` 参数，支持双向持仓
- **动态精度缓存**：启动期从 `exchangeInfo` 拉取全标的 tickSize / stepSize
- **最小名义价值保护**：自动调整数量到 ≥$5（BTC/ETH ≥$20）

### 风控层

`risk.py` —— 两个策略共享同一实例：

| 限制 | 值 |
|------|-----|
| 同时最大持仓 | 1 |
| 日亏损上限 | 0.20 U（超限自动停盘） |
| 日交易笔数 | 30 |
| 手续费模型 | 入场 Maker 0.02% + 出场 Taker 0.04% |

### 持久化与展示

| 文件 | 功能 |
|------|------|
| `trade_db.py` | SQLite（`trades` 逐笔 + `daily_summary` 日报），`get_equity_curve()` 出权益曲线 |
| `dashboard.py` | Flask Web 控制面板，启停策略、改参数、看实时状态 |
| `strategy_manager.py` | 策略进程管理器，供 Dashboard 调用 |
| `monitor.py` | 终端监控，10s 刷新：进程状态 / 运行时长 / CPU / 内存 / 当日笔数与净盈亏 |
| `notifier.py` | Telegram 推送，10 条/分钟滑动窗口限流，未配环境变量时自动跳过 |
| `liquidation_bar.5s.py` | SwiftBar 菜单栏挂件，5s 读一次守护进程状态文件 |

### 辅助脚本

| 文件 | 功能 |
|------|------|
| `config.py` | 全系统参数集中配置（交易对列表、杠杆、各类阈值） |
| `strategy_config.json` | 运行时可覆盖的策略参数（供 `run_strategy.py` 读取，改完不用改代码） |
| `run_strategy.py` | 读 config JSON 覆盖常量后启动指定策略，持续写状态文件 |
| `build_liquidation_app.sh` | 打包 macOS .app |
| `stop_all.sh` / `restart_app.sh` | 一键停止 / 重启 |

---

## 四、安装与运行

```bash
pip install -r requirements.txt

# 1. 配置密钥（二选一）
export BINANCE_API_KEY="你的key"
export BINANCE_API_SECRET="你的secret"
# 或：cp run.sh.example run.sh && 编辑填入

# 2. 启动主引擎（清算瀑布 + 均值回归）
PYTHONUNBUFFERED=1 python3 -u -m binance_liq_harvest.main

# 3. 单独跑其他策略
python3 scalp_harvester.py
python3 three_wave_screener.py
python3 bottom_fisher.py

# 4. 可视化
python3 dashboard.py     # Web 面板
python3 monitor.py       # 终端监控
```

未配置密钥时程序进入**模拟模式**，只打印不下单，可安全验证流程。

### 代理

脚本内置代理自动探测：优先读 `ALL_PROXY` / `all_proxy` 环境变量，否则依次探测本地常见 SOCKS 端口（7890 → 7897 → 7688），取第一个可连通的。**不要硬编码端口** —— 端口会随网络环境变。

---

## 五、踩过的坑（错误码 → 解法）

这套系统在真实 API 上跑通过程中处理的典型问题，也是执行层的主要价值：

| 错误码 | 症状 | 根因 / 解法 |
|--------|------|------------|
| `-2015` | 调用 `/fapi/` 返回 401 | 统一账户必须用 `/papi/` 端点 |
| `-4061` | `position side does not match` | 账户是双向持仓模式，订单缺 `positionSide` |
| `-1111` | `Precision is over the maximum` | 精度硬编码错误 → 改为启动期动态拉取 |
| `-4164` | `notional must be greater than 5` | 下单前自动检查并调整数量 |
| `-4028` | `Invalid leverage` | 部分标的不支持 20x，需按标的判断 |

另外：2026 年 Binance WebSocket 架构升级后，`public`（path 模式裸消息）与 `market`（stream 模式包裹消息）需分离成两个连接，旧的单连接写法已失效。

---

## 六、安全说明

**本目录不含任何真实 API Key / Secret。**

- 所有代码通过 `os.environ.get("BINANCE_API_KEY" / "BINANCE_API_SECRET")` 读取密钥，无硬编码。
- `run.sh`、`run.shy`、`trading_platform/start.sh` 属本地私密文件（含真实密钥），已在 `.gitignore` 中排除；仓库只提供占位符模板 `run.sh.example` / `trading_platform/start.sh.example`。
- 建议 API 权限只开交易、**关闭提现**，并绑定 IP 白名单。

---

## 七、免责声明

本项目仅供学习研究，**不构成任何投资建议**。交易具有高风险，使用本工具产生的任何盈亏由使用者自行承担。请在测试网或小额资金上充分验证后再实盘。
