# AIRunner

macOS 上的 **AI 长任务自动执行器**。把一个跑几小时甚至几天的任务拆成有序步骤逐步调用 AI；当某账号触发额度 / 限流 / 卡死时，**无需任何人工点击即可自动切换到备用账号**，并在中断、切号、App 被强杀后**自动续跑**——每一步都落盘 + 存检查点，绝不从头重来。

## 核心功能

- **步骤化执行**：把长任务拆成有序步骤逐步调用 AI，每步产出结果 + 检查点。
- **自动续跑**：崩溃、中断、切号、App 被强杀后从检查点原地接上，绝不重复已完成步骤。
- **零点击账号切换**：某账号额度耗尽 / 限流 / 卡死时，自动切到下一个可用账号并继续，全程无需人工点击。
- **ChatGPT 网页端自动执行**：通过 macOS 辅助功能（AX）API 驱动网页端——生成自包含续跑 Prompt → 自动提交 → 自动读回 → 校验 → 原子推进检查点（无 AX 权限时可降级为剪贴板手工模式）。
- **多账号轮换**：在设置的多个 Chrome Profile 间循环，官方 OAuth 授权成功后才推进账号指针；失败不会提前推进检查点。
- **多账号 AI 讨论组**：把多个已登录账号组成讨论组，各自扮演**立场互斥**的角色，按可配置议程「独立论述 → 交叉质询 → 收敛决策」产出最终决策。身份校验 fail-closed，每条发言收到即落盘。详见 [docs/AI_DISCUSSION.md](./docs/AI_DISCUSSION.md)。
- **崩溃恢复 & 幂等**：同一任务同时只一个执行器；已完成的步骤在 SQL 层就查不到，重复启动不会重复跑；fallback 不会 A→B→A 循环。
- **原生驱动，不用网页自动化框架**：采用原生 macOS AX API 操作 UI（而非 Selenium / Playwright）。
- **零外部依赖**：纯 SwiftPM 工程，Xcode 直接打开即可构建，无需 resolve 任何 package。
- **可选 API 直连**：内置 OpenAI 兼容 Provider 作为可选后端，需自配 API Key，默认走网页端主通道。

## 工作流程

```
生成续跑 prompt → AX 自动提交给 ChatGPT → AX 自动读回结果
       ↓                                      ↓
 步骤标记 prepared                校验 → 原子提交 → 检查点 +1 → 准备下一步
       ↓
 额度/限流/卡死? → AccountRotationManager 自动切到下一可用账号 → 从检查点继续（零点击）
```

| 程序负责（全自动） | 你只需 |
|---|---|
| 任务状态 / 已完成步骤 / 检查点 | 首次为每个账号建立一个 Chrome Profile，并分别登录 ChatGPT 网页端 |
| 在目标 Profile 完成官方授权、重启并恢复任务 | 在设置中勾选至少两个 Profile |
| 生成自包含的续跑 prompt | |
| 通过 AX 自动提交、自动读回、自动切号 | |
| 检测到额度/登录异常且任务已停止时自动切换账号 | |
| 崩溃恢复 / 不重复已完成的工作 | |

## 多账号 AI 讨论组

讨论组是 AIRunner 的第二条执行线：不追求「一个任务跑到底」，而是让多个账号**互相质询后给出决策**。

- **角色互斥**：每个成员绑定一个已登录的 Chrome Profile，并持有一段只允许站在单一立场的角色设定。内置批判者 / 成本专家 / 乐观派 / 用户代言人 / 风险官 / 执行者六套模板——所有账号背后都是同一个 ChatGPT，角色不互斥就会退化成互相附和。
- **议程可配**：独立论述 → 交叉质询 → 收敛决策。每轮可单独设置**发言人顺序**与**可见性**（不看他人 / 看他人 / 看全部）；独立论述轮故意不喂他人观点，避免被带节奏。
- **收敛方式可配**：主席汇总 / 多数投票 / 一致同意 / 主席独裁。投票规则下强制成员在最后一行输出 `VOTE: YES` / `VOTE: NO`，并保证同轮后投票者看不到前人的票。
- **两条铁律**：**身份校验 fail closed**（窗口账号与成员不匹配立即停止整场讨论，绝不发错人）；**发言收到即落盘**（崩溃、强杀后从最后一条完成的发言续跑，不重复、不重跑已推进的轮次）。
- **两种执行模式**：真实 Chrome 会话 / 脚本演示（离线跑通流程）。模式不会被静默切换——成员未绑定账号时直接报错，不会偷偷降级冒充真实讨论。
- **一键分配账号**：从本地检测到的 Chrome Profile 中自动为各成员分配不同账号，可随机换一批避开失效账号。

完整说明（配置模型、轮次与可见性、收敛规则、审计与持久化）：**[docs/AI_DISCUSSION.md](./docs/AI_DISCUSSION.md)**

## 快速开始

### 构建与运行

```bash
cd AIRunner
swift build
swift test

# 组装可双击的 .app
bash Scripts/make_app.sh release
open dist/AIRunner.app
```

> 在本项目的开发沙箱内构建时才需要 `swift build --disable-sandbox`；你自己的终端直接 `swift build` 即可。

用 Xcode 打开：`open Package.swift`，选 `AIRunner` scheme 运行。

### 首次使用

1. 打开 App → `⌘,` 进入设置。
2. 在 Chrome 中建立至少两个 Profile，并在每个 Profile 分别登录一个 ChatGPT 账号。
3. 在「Codex 自动恢复」中重新检测并勾选这些 Profile；授予 AIRunner「辅助功能」权限。
4. 回主界面 `⌘N` 新建任务；创建后保持「排队中」，在任务详情点击「开始执行」才会登录并执行。
5. 想用讨论组：主界面打开「讨论组」→ 新建 → 在「配置」里填写议题并点「一键分配」绑定 Chrome 账号 → 选好会话模式后点「开始讨论」。

### 数据位置

| 内容 | 位置 |
|---|---|
| 任务 / 步骤 / 检查点 / 日志 | `~/Library/Application Support/AIRunner/airunner.sqlite` |
| API Key | macOS Keychain，`service = com.airunner.apikeys` |
| ChatGPT 账号密码 | macOS Keychain，`service = com.airunner.codex-accounts` |
| 非敏感配置 | `UserDefaults`，key `com.airunner.settings.v1` |

## 架构概览

```
UI (SwiftUI) → TaskManager → JobRunner(actor)
                              ├─ CheckpointManager   每步检查点
                              ├─ RecoveryManager      崩溃恢复
                              ├─ ResponseValidator    结果校验
                              └─ Web / API 执行通道（共用持久化与编排）

UI (SwiftUI) → DiscussionHubView → DiscussionOrchestrator
                              ├─ RoutingDiscussionSessionProvider  真实 Chrome / 脚本演示路由
                              └─ ChromeDiscussionSession           锁窗 · 身份校验 · 提交 · 读回

Repositories → Database(系统 SQLite3, 原子提交) → KeychainManager · LoggerService(脱敏)
```

网页端与 API 直连两条通道共用完全相同的持久化与编排设施，差别只在「这一步的结果从哪里来」。核心正确性保证是**单事务原子提交**（结果 + 检查点 + 进度要么全成功要么全回滚）与**幂等取步**（已完成步骤在 SQL 层就查不到）。

## 隐私与安全

- 不读取、导出或注入浏览器 Cookie / session token；切换的是你合法持有的账号，复用 Profile 中已有的网页登录。
- 凭据只写入 macOS Keychain；任务 / 设置 / 数据库 / 日志只保存非敏感记录 ID，日志经 `SecretRedactor` 强制脱敏。
- 遇到验证码 / 人机验证 / 2FA 会停止并提示你处理，不尝试绕过。
- 网络层使用临时会话配置，不落盘缓存、不写 cookie。
