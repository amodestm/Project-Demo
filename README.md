# Project-Demo

一套 macOS 桌面 / 命令行个人工具集合，覆盖三条线：**AI 长任务执行**、**多账号 AI 议事会**（Swift/SwiftUI）与**实时行情自动化交易**（Python）。

| 项目 | 定位 | 技术栈 |
|------|------|--------|
| [AIRunner](./AIRunner/) | **AI 长任务自动执行器**：拆成有序步骤逐步调 AI，额度/限流时**自动切换账号（零点击）**并自动续跑，每步落盘+检查点；另含**多账号 AI 讨论组**（多账号扮演互斥角色，论述 → 质询 → 收敛） | Swift 6 + SwiftUI + SwiftPM（零外部依赖） |
| [AIDiscussion](./AIDiscussion/) | **AI 议事会**：把讨论组独立外置成单独应用——多账号扮演立场互斥的角色，独立论述 → 交叉质询 → 收敛决策。**100% 静默后台运行**（不抢前台焦点、窗口可移出屏幕视野），支持「继续讨论」断点续跑；内置 **MCP 服务端**，可被 Codex 等外部 AI 调用 | Swift 5.9 + SwiftUI + SwiftPM（零外部依赖） |
| [BinanceTradingSuite](./BinanceTradingSuite/) | **实时行情自动化交易套件**（含 3 个子系统）：LiqHarvest 完整交易引擎 / LiquidationMonitor 强平监控 / QuickTrade 对冲终端 | Python + asyncio + WebSocket + SQLite |

> `BinanceTradingSuite/` 内含三个可单独运行的子项目：`LiqHarvest`（自包含全量系统）、`LiquidationMonitor`（强平瀑布 + 形态扫描）、`QuickTrade`（一键多空对冲终端）。详见 [BinanceTradingSuite/README.md](./BinanceTradingSuite/README.md)。
>
> `AIRunner/` 内含两条执行线：**长任务执行**（步骤化调用 + 零点击切号 + 崩溃续跑）与**多账号 AI 讨论组**（多个已登录账号扮演立场互斥的角色，按可配置议程独立论述 → 交叉质询 → 收敛决策）。讨论组详见 [AIRunner/docs/AI_DISCUSSION.md](./AIRunner/docs/AI_DISCUSSION.md)。
>
> `AIDiscussion/` 是讨论组的**独立外置版**：单独应用、单独数据库，额外支持静默后台运行（不抢前台焦点、窗口可移出屏幕视野）、自动切到高推理强度、「继续讨论」断点续跑与联网搜索过渡态识别。它自带 **MCP 服务端**，Codex 等外部 AI 可以直接组一场讨论拿到结论后继续工作——详见 [AIDiscussion/README.md](./AIDiscussion/README.md) 的「让 Codex 调用（MCP）」章节。

---

## 目录结构

```
Project-Demo/
├── AIRunner/                    # AI 长任务执行器（Swift 6 / SwiftUI）
│   ├── Package.swift            # SwiftPM 清单（macOS 14+，零外部依赖）
│   ├── Sources/AIRunnerCore/    # 零 UI 依赖核心：JobRunner / Checkpoint / 账号轮换 / 讨论组编排
│   ├── Sources/AIRunner/        # SwiftUI 壳（任务 · 设置 · 讨论组）
│   ├── Tests/AIRunnerCoreTests/ # 测试套件
│   ├── Scripts/make_app.sh      # 组装可双击 .app
│   ├── docs/AI_DISCUSSION.md    # 多账号 AI 讨论组说明
│   └── README.md                # 功能 / 架构 / 安全说明
├── AIDiscussion/                # AI 议事会：多账号讨论组独立应用 + MCP 服务端（Swift 5.9 / SwiftUI）
│   ├── Package.swift            # SwiftPM 清单（macOS 14+，零外部依赖）
│   ├── Sources/AIDiscussionCore/  # 零 UI 依赖核心：编排 / 会话驱动 / profile 扫描 / 持久化 / 本地桥接服务端
│   ├── Sources/AIDiscussionBridge/ # app 与 MCP 共用的线协议（Foundation-only）
│   ├── Sources/AIDiscussionMCPKit/ # MCP 协议 · 工具面 · 桥接客户端
│   ├── Sources/AIDiscussionMCP/  # stdio 服务端可执行文件（供 Codex 调用）
│   ├── Sources/AIDiscussion/    # SwiftUI 壳（讨论组列表 · 配置 · 运行 · 桥接面板）
│   ├── Tests/                   # 四个测试目标（线协议 / 规格校验 / MCP 会话 / 工具层）
│   ├── Scripts/make_discussion_app.sh  # 组装 .app + ad-hoc 签名 + 安装
│   ├── Scripts/install_mcp_config.sh   # 打印/写入 Codex 的 MCP 配置片段
│   ├── 启动 AI议事会.command     # 双击启动（未打包则自动编译）
│   └── README.md                # 功能 / 配置模型 / 议程 / 收敛规则 / MCP / 架构 / 安全
├── BinanceTradingSuite/         # 实时行情自动化交易套件（Python）
│   ├── LiqHarvest/              # 完整交易系统（自包含）
│   │   ├── data_feed.py         # 数据层：3 路 WebSocket
│   │   ├── strategy.py          # 策略：清算瀑布收割
│   │   ├── mean_revert.py       # 策略：RSI 均值回归
│   │   ├── scalp_harvester.py   # 策略：高频顺势剥头皮
│   │   ├── three_wave_screener.py # 策略：三浪下跌形态评分
│   │   ├── bottom_fisher.py     # 策略：超跌反弹
│   │   ├── scalp_move75x.py     # 策略：75x 双向剥头皮
│   │   ├── executor.py          # 执行层：签名 / 精度缓存 / 下单
│   │   ├── risk.py              # 风控层：持仓 / 日亏损 / TP·SL
│   │   ├── trade_db.py          # 持久化：SQLite 逐笔 + 日报
│   │   ├── dashboard.py         # Web 控制面板
│   │   ├── monitor.py           # 终端监控
│   │   ├── notifier.py          # Telegram 通知
│   │   ├── liquidation_bar.5s.py # SwiftBar 菜单栏挂件
│   │   ├── config.py            # 全系统参数
│   │   └── README.md
│   ├── LiquidationMonitor/      # 子系统：行情形态监控
│   │   ├── liquidation_daemon.py    # 守护进程：强平流 + 价格跌幅
│   │   ├── triangle_crash_scanner.py# 形态扫描器：箱体/砸盘/突破/急跌
│   │   ├── liquidation_viewer.py    # 桌面 GUI 面板
│   │   └── README.md
│   ├── QuickTrade/              # 子系统：对冲交易终端
│   │   ├── trading_platform/    # 核心模块
│   │   ├── run.sh.example       # 启动脚本模板（需填自己的 API Key）
│   │   └── README.md
│   └── README.md                # 套件总览 / 安全 / 免责声明
└── README.md
```

---

## 快速开始（BinanceTradingSuite · LiqHarvest 主系统）

```bash
git clone https://github.com/amodestm/Project-Demo.git
cd Project-Demo/BinanceTradingSuite/LiqHarvest
pip install -r requirements.txt

export BINANCE_API_KEY="你的key"
export BINANCE_API_SECRET="你的secret"
PYTHONUNBUFFERED=1 python3 -u -m binance_liq_harvest.main
```

未配置密钥时程序进入**模拟模式**，只打印不下单，可安全验证流程。其余两个子系统的启动方式见各自目录内的 README。

---

## 快速开始（AIRunner / AIDiscussion）

```bash
# AIRunner —— 长任务执行 + 讨论组
cd AIRunner
swift build && swift test
bash Scripts/make_app.sh release

# AIDiscussion —— 独立讨论组应用
cd ../AIDiscussion
swift build && swift test
bash Scripts/make_discussion_app.sh release   # 组装 .app、ad-hoc 签名并安装到 /Applications

# 让 Codex 能调用讨论组（可选，需要先 swift build -c release）
bash Scripts/install_mcp_config.sh            # 先打印配置片段，确认后加 --apply 落盘
```

两个 Swift 项目均为**零外部依赖**的 SwiftPM 工程，也可用 Xcode 直接打开 `Package.swift` 运行。首次使用需在系统设置中授予**辅助功能**权限（驱动网页 UI 所必需），并在 Chrome 中为每个待用账号建立独立的 Profile。

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

- 仓库级 `.gitignore` 已排除 `run.sh` / `run.shy` / `trading_platform/start.sh` / `.env` / `*.key` / `*.pem` / `*.sqlite3` / `*.log` / 本地工作区元数据。

> 若你曾把真实密钥提交进仓库，请立即到 Binance 后台吊销（revoke）并重新生成。

---

## 环境要求

- macOS（GUI 与菜单栏挂件部分依赖 macOS，核心逻辑跨平台）
- Python 3.9+（BinanceTradingSuite）；Xcode 15+ / Swift 6（AIRunner）；Swift 5.9+ / macOS 14+（AIDiscussion）
- Python 依赖：`aiohttp`、`aiohttp_socks`、`websockets`、`customtkinter`、`flask` 等
- 网络：需能访问 Binance 行情与交易接口（如处受限网络，脚本内置代理自动探测）

---

## 免责声明

本项目仅供学习与研究，**不构成任何投资建议**。加密货币交易具有高杠杆风险，使用本工具产生的任何盈亏由使用者自行承担。请在测试网或小额资金上充分验证后再实盘。
