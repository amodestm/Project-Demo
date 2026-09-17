# AIRunner MCP

让 Codex 在长任务执行期间主动参与账号管理：自己查额度、自己上报耗尽、自己请求切换账号
并自动续跑，而不是只能靠 AIRunner 去识别屏幕文本。

## 它解决什么

AIRunner 原本只能通过辅助功能读取 Codex 窗口，看到「额度用尽、请稍后重试」这类横幅之后
才被动地切换账号。这条路有两个固有弱点：一是识别依赖页面文案，Codex 改一次措辞就可能
漏判；二是 AIRunner 只能知道「用尽了」，不知道「还剩多少、几点恢复」。

接上这个 MCP 之后：

* **额度是实时值。** Codex 调一次工具就能拿到 5 小时窗口与每周窗口的真实剩余比例、
  恢复时间戳，以及各模型的可用时间。数据来自 OpenAI 官方用量接口，与 Codex 桌面端
  「剩余额度」面板同源。
* **信号由模型自己发出。** 模型读到了限额提示就直接上报，不需要任何屏幕识别。
* **切号有依据。** AIRunner 在每次切换前后采集快照，因此能按「额度未耗尽 → 恢复时间
  最早 → 尚无数据」的顺序挑账号，而不是盲目环形轮换。

## 前置条件

1. AIRunner 已启动（`AIRunner OAuth.app`）。控制类请求必须由运行中的应用执行 ——
   切号涉及 GUI 自动化与任务检查点，不能由第二个进程直接改状态。
2. AIRunner 已获得辅助功能权限（切号与续跑都依赖它）。
3. 设置里已开启「使用 Chrome Profile + Codex 浏览器授权切换」，并勾选了至少两个 Profile。
4. 本机 Codex 已登录（`~/.codex/auth.json` 存在）。额度查询用的是这份凭据。

## 配置

在 `~/.codex/config.toml` 里新增：

```toml
[mcp_servers.airunner]
command = "/usr/bin/python3"
args = ["<AIRunner 仓库路径>/Scripts/mcp/airunner_mcp.py"]
startup_timeout_sec = 20
```

可选环境变量（一般不需要）：

```toml
[mcp_servers.airunner.env]
# 需要显式代理才能访问 chatgpt.com 时才设置
AIRUNNER_MCP_PROXY = "http://127.0.0.1:8080"
# 非默认位置时覆盖
# AIRUNNER_SUPPORT_DIR = "<自定义的 AIRunner 数据目录>"
# CODEX_HOME = "<自定义的 Codex 目录>"
```

改完重启 Codex。用 `ChatGPT.app` 内的 Codex 会话验证：

> 你现在还剩多少额度？

模型应当调用 `quota_status` 并回报 5 小时/每周窗口的剩余比例与恢复时间。

> 列出账号轮换池，并告诉我下一个该用哪个。

模型应当调用 `list_rotation_accounts`。

## 工具

| 工具 | 作用 | 什么时候会用到 |
|---|---|---|
| `quota_status` | 查当前登录账号的实时额度：5 小时/每周窗口剩余比例、恢复时间、各模型可用时间、额外余额 | 长任务开始前评估容量；连续生成很久之后；页面出现限额提示时 |
| `list_rotation_accounts` | 列轮换池全部账号 + 各自最近一次额度快照 + 冷却状态，并给出建议的下一个账号 | 需要判断是否值得切号、切到哪个之前 |
| `task_status` | 查 AIRunner 任务状态、绑定的 Codex 线程、当前 Profile、轮换次数 | 拿 `task_id`；确认 AIRunner 是否在跟踪当前任务 |
| `quota_history` | 查历史额度快照，用于判断某账号的恢复规律 | 核对「模型恢复时间」、估算某账号何时可用 |
| `resume_task` | 请求 AIRunner 向绑定线程补发一次「继续」，**不**切号 | 额度充足但当前这轮生成停了 |
| `request_account_switch` | 完整账号交接：保存检查点 → 退出当前账号 → 用额度最先恢复的 Profile 重新 OAuth 登录 → 自动续跑 | 额度已耗尽、且当前线程已停止生成 |
| `capture_quota_snapshot` | 立即采集一次当前账号的实时额度并写入快照表 | 长任务开始前留额度基线；刚被切到新账号之后（此时探测到的就是新账号） |
| `report_quota_exhausted` | 把额度耗尽信号上报给 AIRunner（记录并计入冷却），不立即切号 | 想留痕但暂不切号时 |

### 切号的安全约束

`request_account_switch` 走的不是一条新链路，而是复用 AIRunner 额度监视器那条已经过验证的
路径，因此以下门控一个都不会被绕过：

* 检测到 Codex **仍在生成**时直接拒绝 —— 推理中途退出账号会中断本地聊天与计划任务；
* 只有在无法确认生成已停止时，也一律拒绝；
* 切号前会把任务置为「等待账号」，检查点与未提交步骤保留；
* 切换成功后自动启动恢复监视器，向原线程补发「继续」。

也就是说，模型可以主动发起，但不能绕过安全判断。

## 运行时结构

```text
Codex ──stdio JSON-RPC──▶ airunner_mcp.py ──┬─▶ ~/.codex/auth.json + 官方用量接口（只读额度）
                                            │
                                            └─▶ mcp-inbox/ 请求文件
                                                      │
                                            AIRunner 轮询处理
                                                      │
                                            mcp-inbox/<id>.result.json
```

控制类请求走文件队列而不是本地端口：写者始终只有一个（AIRunner 内部的请求路由器），
不需要开放监听面，也不需要共享密钥。请求用「写临时文件 + 原子改名」投递，结果文件
写完之后才删除请求，因此中断不会丢请求。

## 数据与隐私

* 额度查询使用本机 Codex 自己的 access token，只放在 HTTP 请求头里：**不写日志、不落库、
  不出现在错误信息中**。
* 落库的只有额度计量值（百分比、时间戳、plan 名称）与账号邮箱、Chrome Profile 目录名。
* MCP 请求/响应文件里只有任务 ID、Profile 目录名、邮箱与原因文本，**不含任何凭据**。
* 额度快照每个 Profile 只保留最近若干条，超出部分自动清理。

## 排障

| 现象 | 原因与处理 |
|---|---|
| 工具报「找不到 Codex 凭据文件」 | 本机 Codex 未登录，或 `CODEX_HOME` 指向了别处 |
| 工具报「额度接口不可达」 | 网络到不了 `chatgpt.com`；设置 `AIRUNNER_MCP_PROXY` 后用系统路由 |
| 报「额度接口返回 HTTP 401/403」 | Codex 登录态失效，重新登录 Codex 即可 |
| 请求长时间不返回 | AIRunner 未运行，或未升级到带 MCP 请求通道的版本 |
| 指定 profile 查额度只返回快照 | 正常现象：额度接口只能查当前登录账号，其他账号要靠切换时采集 |
| 切号被拒绝、提示仍在生成 | 安全门控生效，等本轮生成结束再试 |
