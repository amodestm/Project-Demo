# Project-Demo

一套 macOS 桌面 / 命令行个人工具集合，覆盖两条线：**AI 长任务执行**（Swift/SwiftUI）与**实时行情自动化交易**（Python）。

| 项目 | 定位 | 技术栈 |
|------|------|--------|
| [AIRunner](./AIRunner/) | **AI 长任务自动执行器**：拆成有序步骤逐步调 AI，额度/限流时**自动切换账号（零点击）**并自动续跑，每步落盘+检查点 | Swift 6 + SwiftUI + SwiftPM（零外部依赖） |
| [LiqHarvest](./LiqHarvest/) | **完整系统**：实时行情驱动的自动化交易引擎（数据 / 策略 / 执行 / 风控 / 可视化全链路） | Python + asyncio + WebSocket + SQLite |
| [LiquidationMonitor](./LiquidationMonitor/) | 子系统：全市场强平瀑布监控 + 箱体震荡/砸盘形态扫描 | Python + WebSocket + customtkinter |
| [QuickTrade](./QuickTrade/) | 子系统：一键多空对冲交易终端（快速下单） | Python + aiohttp + Flask + 桌面 GUI |

> `LiquidationMonitor` 与 `QuickTrade` 是从 `LiqHarvest` 中抽取出来的两个子系统，各自配有独立 README 便于单独阅读；`LiqHarvest/` 是自包含的全量代码，可独立运行。`AIRunner/` 为零依赖 SwiftPM 工程，详见其自带 README。

---

## 目录结构

```
Project-Demo/
├── AIRunner/                    # AI 长任务执行器（Swift 6 / SwiftUI）
│   ├── Package.swift            # SwiftPM 清单（macOS 14+，零外部依赖）
│   ├── Sources/AIRunnerCore/    # 零 UI 依赖核心：JobRunner / ModelRouter / RetryManager / Checkpoint / Persistence
│   ├── Sources/AIRunner/        # SwiftUI 壳
│   ├── Tests/AIRunnerCoreTests/ # 69 个测试
│   ├── Scripts/make_app.sh      # 组装可双击 .app
│   └── README.md                # 设计规则 / 架构 / 安全说明
├── LiqHarvest/                  # 完整交易系统（自包含）
│   ├── data_feed.py             # 数据层：3 路 WebSocket
│   ├── strategy.py              # 策略：清算瀑布收割
│   ├── mean_revert.py           # 策略：RSI 均值回归
│   ├── scalp_harvester.py       # 策略：高频顺势剥头皮
│   ├── three_wave_screener.py   # 策略：三浪下跌形态评分
│   ├── bottom_fisher.py         # 策略：超跌反弹
│   ├── scalp_move75x.py         # 策略：75x 双向剥头皮
│   ├── executor.py              # 执行层：签名 / 精度缓存 / 下单
│   ├── risk.py                  # 风控层：持仓 / 日亏损 / TP·SL
│   ├── trade_db.py              # 持久化：SQLite 逐笔 + 日报
│   ├── dashboard.py             # Web 控制面板
│   ├── monitor.py               # 终端监控
│   ├── notifier.py              # Telegram 通知
│   ├── liquidation_bar.5s.py    # SwiftBar 菜单栏挂件
│   ├── config.py                # 全系统参数
│   └── README.md
├── LiquidationMonitor/          # 子系统：行情形态监控
│   ├── liquidation_daemon.py    # 守护进程：强平流 + 价格跌幅
│   ├── triangle_crash_scanner.py# 形态扫描器：箱体/砸盘/突破/急跌
│   ├── liquidation_viewer.py    # 桌面 GUI 面板
│   └── README.md
├── QuickTrade/                  # 子系统：对冲交易终端
│   ├── trading_platform/        # 核心模块
│   ├── run.sh.example           # 启动脚本模板（需填自己的 API Key）
│   └── README.md
└── README.md
```

---

## 快速开始

```bash
git clone https://github.com/amodestm/Project-Demo.git
cd Project-Demo/LiqHarvest
pip install -r requirements.txt

export BINANCE_API_KEY="你的key"
export BINANCE_API_SECRET="你的secret"
PYTHONUNBUFFERED=1 python3 -u -m binance_liq_harvest.main
```

未配置密钥时程序进入**模拟模式**，只打印不下单，可安全验证流程。

---

## ⚠️ 安全说明（重要）

**本仓库不含任何真实的 API Key / Secret。**

- 所有交易脚本均通过**环境变量**读取密钥（`BINANCE_API_KEY` / `BINANCE_API_SECRET`），代码里没有硬编码。
- 启动脚本以 `.example` 或占位符形式提供（`YOUR_BINANCE_API_KEY`），使用前需自行填入。
- 使用前的建议配置方式（不要把密钥写进仓库）：

```bash
export BINANCE_API_KEY="你的key"
export BINANCE_API_SECRET="你的secret"
```

- `.gitignore` 已排除 `run.sh` / `run.shy` / `trading_platform/start.sh` / `.env` / `*.key` / `*.pem` / `*.sqlite3` / `*.log` / 本地工作区元数据。

> 若你曾把真实密钥提交进仓库，请立即到 Binance 后台吊销（revoke）并重新生成。

---

## 环境要求

- macOS（GUI 与菜单栏挂件部分依赖 macOS，核心逻辑跨平台）
- Python 3.9+
- 依赖：`aiohttp`、`aiohttp_socks`、`websockets`、`customtkinter`、`flask` 等
- 网络：需能访问 Binance 行情与交易接口（如处受限网络，脚本内置代理自动探测）

---

## 免责声明

本项目仅供学习与研究，**不构成任何投资建议**。加密货币交易具有高杠杆风险，使用本工具产生的任何盈亏由使用者自行承担。请在测试网或小额资金上充分验证后再实盘。
