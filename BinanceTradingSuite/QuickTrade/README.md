# QuickTrade — Binance 一键多空对冲交易平台

快速下单 + 多空对冲的桌面交易终端。后端提供 REST 服务，桌面 GUI 负责交互，执行层直接对接 Binance 交易 API。

---

## 模块结构

```
QuickTrade/
├── trading_platform/
│   ├── app.py              # Flask 后端（默认端口 9090），REST 接口
│   ├── desktop_app.py      # macOS 桌面客户端 GUI
│   ├── executor_client.py  # Binance 执行客户端：签名请求 / 余额 / 持仓 / 下单
│   ├── hedge_manager.py    # 对冲组合管理：预设组合、批量并发下单
│   ├── __init__.py
│   ├── launch.sh           # 一键启动（自动从环境/配置读取 API Key）
│   └── start.sh            # 启动脚本（需填入自己的 API Key）
└── run.sh.example          # 启动脚本模板（复制为 run.sh 后填 Key）
```

---

## 各模块职责

### `executor_client.py` — `PlatformExecutor`

Binance 交易 API 封装，核心能力：

- HMAC-SHA256 签名（`_sign_dict`），支持签名 GET / POST 请求
- `get_balance()` / `get_total_equity()` / `get_all_balances()` — 账户权益查询
- `get_positions()` — 当前持仓
- 下单与批量执行

**密钥读取方式（安全）**：

```python
self._api_key = os.environ.get("BINANCE_API_KEY", "")
self._api_secret = os.environ.get("BINANCE_API_SECRET", "")
```

未设置时自动降级为**模拟模式**（仅打印不下单），方便无密钥调试。

### `hedge_manager.py` — 对冲组合管理器

- 预设对冲组合模板（如 `ETH-BTC 对冲`）
- 自定义组合
- **批量下单引擎**：并发执行多腿，保证多空同时开仓

组合格式示例：

```json
{
  "name": "ETH-BTC 对冲",
  "legs": [
    {"symbol": "ETHUSDT", "side": "BUY",  "qty": 0.5},
    {"symbol": "BTCUSDT", "side": "SELL", "qty": 0.02}
  ]
}
```

### `app.py` — 后端服务

Flask 服务，默认监听 `127.0.0.1:9090`，提供余额、持仓、下单等 REST 接口供 GUI 调用。

### `desktop_app.py` — 桌面 GUI

原生 macOS 窗口（PyObjC / tkinter 系），提供行情、下单、对冲组合执行等交互。

---

## 安装与运行

```bash
# 依赖
pip install aiohttp flask requests

# 方式一：用 launch.sh（自动读取 API Key 并启动后端 + GUI）
cd trading_platform
bash launch.sh

# 方式二：手动设置环境变量后启动
export BINANCE_API_KEY="你的key"
export BINANCE_API_SECRET="你的secret"
cd trading_platform && bash start.sh
```

### 首次配置

1. 复制 `run.sh.example` 为 `run.sh`：

```bash
cp run.sh.example run.sh
```

2. 编辑 `run.sh`，把 `YOUR_BINANCE_API_KEY` / `YOUR_BINANCE_API_SECRET` 换成你自己的：

```bash
export BINANCE_API_KEY="YOUR_BINANCE_API_KEY"      # ← 替换为真实 key
export BINANCE_API_SECRET="YOUR_BINANCE_API_SECRET" # ← 替换为真实 secret
```

3. 同时把脚本里的 Python 路径 `/Users/<YOUR_USER>/miniforge3/bin/python3` 改为本机实际路径。

---

## ⚠️ 安全须知

**绝对不要把真实 API Key 提交到仓库。**

- `run.sh`、`trading_platform/start.sh` 属于本地私密文件，含真实密钥，**不要 `git add`**。仓库中提供的是脱敏模板（`run.sh.example`、占位符版 `start.sh`）。
- 建议把含密钥的文件加入 `.gitignore`：

```
run.sh
trading_platform/start.sh
.env
*.key
```

- Binance API 建议：只开交易权限，**关闭提现权限**，并绑定 IP 白名单。
- 若密钥曾泄露，立即到 Binance 后台 **revoke（吊销）** 重新生成。

---

## 注意事项

- `start.sh` 中会 `unset ALL_PROXY http_proxy https_proxy`，防止本地代理把 `127.0.0.1` 请求也走 SOCKS5 导致后端连不上。
- 后端端口 `9090` 被占用时，脚本会先 `kill` 占用进程再启动。
- 未配置密钥时程序以**模拟模式**运行，不会真实下单，可用于验证流程。

---

## 免责声明

高杠杆交易风险极高。本项目仅供学习研究，不构成投资建议。请在测试网或小额资金充分验证后再实盘，盈亏自负。
