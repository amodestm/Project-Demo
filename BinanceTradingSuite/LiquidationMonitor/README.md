# LiquidationMonitor — Binance 强平瀑布 & 箱体形态监控

全市场（700+ USDT 交易对）实时监控系统。两路独立数据源：**强平事件流** + **价格/K线形态扫描**，结果汇总到一个 macOS 桌面面板。

```
┌──────────────────────────────────────────┐
│  🔺 箱体砸盘扫描                          │
│  📐 箱体震荡: 321个触发  💥 砸盘: 0个      │
│  🔥 反转进场: 0个        🚀 突破: 3个      │
│  ⚡ 二十分钟急跌: 2个                      │
│  ── 最近动态 ──                           │
│  ⭐ BTCUSDT 箱体震荡 1h5m 振幅2.1% ...     │
│  💥 爆仓统计  60s: 12.4万U  瀑布: 无       │
│  ⏱ 最近爆仓                               │
│  🕐 爆仓:21:15 扫描:21:15 刷新:21:15       │
└──────────────────────────────────────────┘
```

---

## 三个组件

| 文件 | 角色 | 说明 |
|------|------|------|
| `liquidation_daemon.py` | 守护进程 | 监听强平流 + 全市场价格流，检测爆仓瀑布与急跌档位 |
| `triangle_crash_scanner.py` | 形态扫描器 | 700+ 币种的箱体震荡 / 砸盘 / 突破 / 反转 / 急跌 / 三浪检测 |
| `liquidation_viewer.py` | 桌面 GUI | customtkinter 面板，1s 刷新，按钮查看各类告警 |

---

## 1. liquidation_daemon.py — 爆仓与跌幅监控

监听两路 Binance WebSocket：

- **强平流** `!forceOrder@arr` — 捕捉每一笔强制平仓（爆仓）事件
- **价格流** `!miniTicker@arr` — 全市场标记价格，用于跌幅检测

产出（写入 `~/.liq_harvest/liquidation_bar.json`）：

- 累计/60s 峰值爆仓金额（区分多单爆仓 🔴 / 空单爆仓 🟢）
- **瀑布告警**：短时间内爆仓量激增
- **价格跌幅档位**：`[1.5%, 2.0%, 3.0%]` / 60s 窗口（`DROP_LEVELS`、`WINDOW_SEC`）
- 最近 10 笔爆仓明细（时间、方向、币名、金额、数量、价格）
- 累计 TOP5 爆仓币种

---

## 2. triangle_crash_scanner.py — 形态扫描（核心）

对全市场币种做 1min K 线形态识别，共 6 类信号。

### 📐 箱体震荡（基础池）

从**当前 K 线往前逐根回看**，累进计算最高/最低价，振幅超阈值即停止。满足条件的币种进入「箱体池」，后续信号只在该池内检测。

| 参数 | 值 | 公式 |
|------|-----|------|
| `RANGE_MIN_PCT` | 1.0% | `(高-低)/高` ≥ 1.0%（过滤僵尸币） |
| `RANGE_MAX_PCT` | 2.3% | `(高-低)/高` ≤ 2.3% |
| `RANGE_DURATION_BARS` | 45 | 至少持续 45 根 1min K 线 |
| `RANGE_BOX_BARS` | 120 | 最大回看窗口（2h） |
| 趋势过滤 | — | 非单边趋势 + 中线上下来回穿越 ≥ 2 次 |

> 箱体确认后**持续更新时长**（只要价格还在区间内，分钟数一直累积）。

### 💥 砸盘确认

**实时价格 + 1min K 线双确认**（秒级触发，不等 K 线闭合）：

| 条件 | 值 |
|------|-----|
| 跌幅（相对箱体上沿最高价） | ≥ 3.0%（`CRASH_DROP_PCT`） |
| 理想爆多标记 | ≥ 5.0%（`CRASH_IDEAL_PCT`） |
| 量能放大 | 最近 2 根 K 线量 ≥ 箱体均量 × 2.0（`VOL_SPIKE_MULT`） |

### 🚀 向上突破

箱体确认后实时检测，价格超过箱体上沿 **1.0%**（`BREAKOUT_THRESHOLD`）即告警。

### 🔥 反转进场

必须在「箱体 → 砸盘」都确认后才检查：

- 连续 **2** 根 K 线不再创新低（`REVERSAL_NO_NEW_LOW_BARS`）
- 从砸盘最低价回升 **1.0%**（`REVERSAL_RISE_PCT`）

### ⚡ 二十分钟急跌（独立，不依赖箱体）

最近 **20** 根 1min K 线（`QUICK_DROP_BARS`），跌幅 ≥ **5.0%**（`QUICK_DROP_PCT`）即告警。全市场独立扫描，与箱体无关。

```
跌幅 = (20分钟前收盘 - 当前收盘) / 20分钟前收盘 × 100%
```

### ⭐ 三浪（优秀判定，标记在箱体上）

箱体尾部出现逐步降低的低点，且**最后一浪必须靠近当前时间**（≤ 15 根 K 线，`THREE_WAVE_TAIL_BARS`），避免标记早已过时的形态。

| 参数 | 值 |
|------|-----|
| `THREE_WAVE_LOOKBACK` | 100（回看窗口） |
| `THREE_WAVE_MIN_WAVES` | 2（最少浪数） |
| `THREE_WAVE_MIN_DROP` | 0.15%（每浪最低跌幅） |
| `THREE_WAVE_TAIL_BARS` | 15（最后一浪须在此窗口内） |

---

## 3. liquidation_viewer.py — 桌面面板

- 顶部 5 个按钮：`📐箱体` `💥砸盘` `🔥反转` `🚀突破` `⚡急跌`，点开为独立弹窗
- **箱体弹窗排序**：30–90 分钟的箱体优先，其次按 24h 交易量降序
- 币名青色高亮，**点击即复制**
- 涨跌配色：🔴 跌 / 爆仓，🟢 涨（符合中国习惯）
- 内容仅在变化时刷新，不打断文字选中
- 底部三重时间戳（爆仓 / 扫描 / 刷新），便于判断哪个数据源卡住

---

## 运行

```bash
# 依赖
pip install aiohttp aiohttp_socks websocket-client customtkinter

# 启动守护进程（爆仓 + 价格）
python3 liquidation_daemon.py &

# 启动形态扫描器
python3 triangle_crash_scanner.py &

# 启动 GUI 面板
python3 liquidation_viewer.py
```

数据文件：

- 爆仓状态：`~/.liq_harvest/liquidation_bar.json`（daemon 写，viewer 读）
- 形态告警：`/tmp/triangle_crash.json`（scanner 写，viewer 读）

---

## 网络与代理

脚本内置代理自动探测：优先读环境变量 `ALL_PROXY` / `all_proxy`，否则依次探测本地常见端口（`7890` 系统 SOCKS → `7897` → `7688`），选第一个可连通的。**不要硬编码代理端口**——端口会随网络环境变化，硬编码会导致连接失败。

```python
PROXY = _detect_proxy()   # 自动探测，非硬编码
```

---

## 调参

所有阈值集中在 `triangle_crash_scanner.py` 顶部常量区、`liquidation_daemon.py` 的 `DROP_LEVELS` / `WINDOW_SEC`，按需修改后重启对应进程即可生效。
