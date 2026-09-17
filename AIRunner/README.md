# AIRunner

macOS 上的 **AI 长任务自动执行器**。把一个跑几小时甚至几天的任务拆成有序步骤逐步调用 AI；当某账号触发额度 / 限流 / 卡死时，**无需任何人工点击即可自动切换到备用账号**，并在中断、切号、App 被强杀后**自动续跑**——每一步都落盘 + 存检查点，绝不从头重来。

## 核心功能

- **步骤化执行**：把长任务拆成有序步骤逐步调用 AI，每步产出结果 + 检查点。
- **自动续跑**：崩溃、中断、切号、App 被强杀后从检查点原地接上，绝不重复已完成步骤。
- **零点击账号切换**：某账号额度耗尽 / 限流 / 卡死时，自动切到下一个可用账号并继续，全程无需人工点击。
- **ChatGPT 网页端自动执行**：通过 macOS 辅助功能（AX）API 驱动网页端——生成自包含续跑 Prompt → 自动提交 → 自动读回 → 校验 → 原子推进检查点（无 AX 权限时可降级为剪贴板手工模式）。
- **多账号轮换**：在设置的多个 Chrome Profile 间循环，官方 OAuth 授权成功后才推进账号指针；失败不会提前推进检查点。
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
Repositories → Database(系统 SQLite3, 原子提交) → KeychainManager · LoggerService(脱敏)
```

网页端与 API 直连两条通道共用完全相同的持久化与编排设施，差别只在「这一步的结果从哪里来」。核心正确性保证是**单事务原子提交**（结果 + 检查点 + 进度要么全成功要么全回滚）与**幂等取步**（已完成步骤在 SQL 层就查不到）。

## 隐私与安全

- 凭据只写入 macOS Keychain；任务 / 设置 / 数据库 / 日志只保存非敏感记录 ID，日志经 `SecretRedactor` 强制脱敏。
- 遇到验证码 / 人机验证 / 2FA 会停止并提示你处理，不尝试绕过。
- 网络层使用临时会话配置，不落盘缓存。
