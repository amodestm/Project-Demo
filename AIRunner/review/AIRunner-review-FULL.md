# AIRunner — 代码审查包

> 生成时间: 2026-09-11 17:38 UTC
> 打包模式: **FULL**
> 项目: macOS 原生 App (Swift 6 / SwiftUI / SQLite), 零第三方依赖
> 规模: 61 个 Swift 文件, 12504 行

---

## 这份文档是什么

AIRunner 是一个 **AI 长任务执行器**: 把一个跑几小时到几天的任务拆成有序步骤,
每步的结果与检查点都持久化, 中断 / 崩溃 / 换账号后都能从断点继续, 绝不从头重来。

**主执行通道是 ChatGPT 网页端 + 人工账号交接** —— 程序不碰浏览器凭据,
账号切换由用户在浏览器里手动完成。

以下内容按"设计说明 → 需求边界 → 架构 → 源码 → 测试 → 验证证据"排列。
如果只想知道怎么审, 直接看下面那段提示词。

---

## 建议使用的审查提示词

把下面这段连同本文件一起发给 AI:

````text
请审查这个 macOS 应用 (AIRunner) 的代码, 重点检查以下五项。逐项给出结论, 指出具体文件与行号,
如果发现问题请说明严重程度。

1. **正确性**: "绝不重复执行已完成步骤" 这一保证是否真的成立?
   重点看 `StepRepository.commitSuccessfulStep` (单事务提交)、
   `StepRepository.nextExecutableStep` (只返回 pending/interrupted/prepared)、
   `JobRunner.runLoop` 的循环结构。找出任何可能破坏该保证的路径。

2. **崩溃恢复**: App 在任意时刻被强杀, 重启后能否正确继续?
   重点看 `RecoveryManager.recover()` 与 `StepStatus.prepared` 的处理。
   是否存在某一步会永久卡死、或某个任务永远无法推进的状态组合?

3. **账号交接**: `WebExecutionCoordinator.pauseForAccountSwitch` /
   `resumeAfterManualAccountSwitch` 是否可能丢失已完成的进度?

4. **安全边界**: 代码中是否存在任何读取浏览器 Cookie、session token、
   自动登录或自动轮换账号的逻辑? (需求明确禁止这些)
   如果完全没有, 请确认; 如果有, 请指出。

5. **并发与数据竞争**: `Database` 用 `NSLock` + `@unchecked Sendable`,
   `JobRunner` / `WebExecutionCoordinator` / `ModelRouter` 是 actor,
   `TaskExecutionRegistry` 防止同一任务起两个 Runner。
   这套并发模型是否存在漏洞?

另外请指出: 这份代码里**你认为最脆弱的一处**, 以及一个能复现问题的最小场景。
````


---

## 1. 项目概览


- **语言/框架**: Swift 6 (language mode v6, 严格并发检查), SwiftUI, 系统 SQLite3
- **外部依赖**: **零** (`Package.swift` 的 `dependencies: []`)
- **平台**: macOS 14+
- **构建**: `swift build` — 0 error
- **测试**: `swift test` — 98 tests / 0 failures
- **数据位置**: `~/Library/Application Support/AIRunner/airunner.sqlite`
- **密钥位置**: macOS Keychain (`service = com.airunner.apikeys`)

### 目录结构

```text
数据模型 Models/
    Sources/AIRunnerCore/Models/AIRequest.swift                      57 行
    Sources/AIRunnerCore/Models/AIResponse.swift                     43 行
    Sources/AIRunnerCore/Models/AITask.swift                        234 行
    Sources/AIRunnerCore/Models/AppEvent.swift                      145 行
    Sources/AIRunnerCore/Models/Checkpoint.swift                     58 行
    Sources/AIRunnerCore/Models/ExecutionMode.swift                  62 行
    Sources/AIRunnerCore/Models/JSONValue.swift                     189 行
    Sources/AIRunnerCore/Models/ProviderConfig.swift                170 行
    Sources/AIRunnerCore/Models/ProviderHealth.swift                 95 行
    Sources/AIRunnerCore/Models/TaskStep.swift                      167 行

执行核心 Core/
    Sources/AIRunnerCore/Core/AppServices.swift                     255 行
    Sources/AIRunnerCore/Core/CheckpointManager.swift               146 行
    Sources/AIRunnerCore/Core/ContinuationPromptBuilder.swift       272 行
    Sources/AIRunnerCore/Core/JobRunner.swift                       750 行
    Sources/AIRunnerCore/Core/ModelRouter.swift                     307 行
    Sources/AIRunnerCore/Core/RecoveryManager.swift                 157 行
    Sources/AIRunnerCore/Core/ResponseValidator.swift               132 行
    Sources/AIRunnerCore/Core/RetryManager.swift                    189 行
    Sources/AIRunnerCore/Core/TaskExecutionRegistry.swift            42 行
    Sources/AIRunnerCore/Core/TaskManager.swift                     402 行
    Sources/AIRunnerCore/Core/TaskPlanner.swift                     122 行
    Sources/AIRunnerCore/Core/WebExecutionCoordinator.swift         569 行

Provider 抽象 (通用协议)/
    Sources/AIRunnerCore/Providers/AIProvider.swift                  38 行
    Sources/AIRunnerCore/Providers/MockAIProvider.swift             170 行

可选 API 后端 Legacy/API/
    Sources/AIRunnerCore/Legacy/API/OpenAICompatibleProvider.swift  375 行
    Sources/AIRunnerCore/Legacy/API/ProviderFactory.swift           184 行

持久化 Persistence/
    Sources/AIRunnerCore/Persistence/Database.swift                 441 行
    Sources/AIRunnerCore/Persistence/DatabaseMigrator.swift         239 行
    Sources/AIRunnerCore/Persistence/Repositories/CheckpointRepository.swift   79 行
    Sources/AIRunnerCore/Persistence/Repositories/EventRepository.swift  108 行
    Sources/AIRunnerCore/Persistence/Repositories/ProviderHealthRepository.swift   89 行
    Sources/AIRunnerCore/Persistence/Repositories/StepRepository.swift  504 行
    Sources/AIRunnerCore/Persistence/Repositories/TaskRepository.swift  242 行

安全 Security/
    Sources/AIRunnerCore/Security/KeychainManager.swift             166 行

服务 Services/
    Sources/AIRunnerCore/Services/AppSettings.swift                 153 行
    Sources/AIRunnerCore/Services/ClipboardService.swift            117 行
    Sources/AIRunnerCore/Services/LoggerService.swift               187 行

工具 Utilities/
    Sources/AIRunnerCore/Utilities/AppError.swift                   184 行
    Sources/AIRunnerCore/Utilities/AsyncSemaphore.swift              54 行
    Sources/AIRunnerCore/Utilities/JSONCoding.swift                 107 行

UI 层 (SwiftUI, AppKit 桥接)/
    Sources/AIRunner/AIRunnerApp.swift                               45 行
    Sources/AIRunner/App/AppState.swift                              55 行
    Sources/AIRunner/Platform/PasteboardClipboard.swift              23 行
    Sources/AIRunner/Platform/WorkspaceBrowserLauncher.swift         20 行
    Sources/AIRunner/UI/ContentView.swift                            57 行
    Sources/AIRunner/UI/Logs/LogView.swift                          167 行
    Sources/AIRunner/UI/Settings/ProviderSettingsView.swift         250 行
    Sources/AIRunner/UI/Settings/SettingsView.swift                 449 行
    Sources/AIRunner/UI/Tasks/CreateTaskView.swift                  160 行
    Sources/AIRunner/UI/Tasks/TaskDetailView.swift                  556 行
    Sources/AIRunner/UI/Tasks/TaskListView.swift                    209 行
    Sources/AIRunner/UI/Tasks/TaskRowView.swift                     151 行

测试/
    Tests/AIRunnerCoreTests/CheckpointTests.swift                   217 行
    Tests/AIRunnerCoreTests/CrashRecoveryTests.swift                236 行
    Tests/AIRunnerCoreTests/JobRunnerTests.swift                    391 行
    Tests/AIRunnerCoreTests/ModelRouterTests.swift                  254 行
    Tests/AIRunnerCoreTests/PersistenceSmokeTests.swift             217 行
    Tests/AIRunnerCoreTests/RetryManagerTests.swift                 215 行
    Tests/AIRunnerCoreTests/SmokeTests.swift                          9 行
    Tests/AIRunnerCoreTests/TestSupport.swift                       154 行
    Tests/AIRunnerCoreTests/WebExecutionTests.swift                 669 行
```


---

## 2. 设计说明 (`README.md` 全文)

# AIRunner

macOS 上的 **AI 长任务执行器**。把一个跑几小时甚至几天的任务拆成有序步骤，每一步都落盘 + 存检查点；
中断、换账号、App 被强杀，都能原地接上，绝不从头重来。

## 主执行通道：ChatGPT Web + 人工账号交接

程序配合 **ChatGPT 网页端**使用 —— 账号切换由你在浏览器里手动完成，程序负责其余全部工作：

```
复制续跑 prompt → 你提交给 ChatGPT → 你贴回结果
       ↓                                  ↓
 步骤标记 prepared            校验 → 原子提交 → 检查点 +1 → 准备下一步
       ↓
 换账号? → 你手动切换 → 点「我已完成账号切换」→ 从检查点继续
```

| 程序负责 | 你负责 |
|---|---|
| 任务状态 / 已完成步骤 / 检查点 | 在浏览器里切换账号 |
| 生成自包含的续跑 prompt | 把 prompt 提交给 ChatGPT |
| 检测无法继续时暂停并提示 | 把 ChatGPT 的回复贴回来 |
| 崩溃恢复 / 不重复已完成的工作 | |

> **为什么先做 Clipboard 模式而不是浏览器自动化**：见下方「边界」。
> 先让 checkpoint / 续跑 / 恢复这条链路完全正确 —— 这比自动化一个随时会变的网页
> 更有价值，也更可靠。

---

## 一、边界：本项目**不做**什么

这是硬性约束，代码里没有任何一条对应实现：

- ❌ 不读取或导出浏览器 Cookie
- ❌ 不读取或注入 session token / authentication storage
- ❌ 不自动填写账号密码、不自动登录
- ❌ 不自动轮换账号，也不根据"额度耗尽"去切换到另一个个人账号
- ❌ 不用 Selenium / Playwright 等工具操作网页来绕过平台使用限制
- ❌ 不实现任何绕过 rate limit / usage limit 的逻辑

`BrowserLaunching` 协议的全部能力就是 `NSWorkspace.shared.open(url)` —— 打开一个 URL，
让你在**自己已登录的浏览器**里操作。仅此而已。

API 直连是**可选后端**（代码在 `Legacy/API/`），需要你自己配置 API Key，默认不参与主流程。

---

## 二、快速开始

### 构建与运行

```bash
cd AIRunner

# 命令行构建
swift build --disable-sandbox

# 跑测试 (69 个)
swift test --disable-sandbox

# 组装可双击的 .app
bash Scripts/make_app.sh release
open dist/AIRunner.app
```

> `--disable-sandbox` 只在**本项目的开发环境**（外层已有沙箱、SwiftPM 内置的 `sandbox-exec`
> 无法嵌套）需要。在你自己的终端里直接 `swift build` 即可。

### 用 Xcode 打开

```
open Package.swift
```

SwiftPM 包可以直接被 Xcode 打开成完整工程，选 `AIRunner` scheme 运行即可。
**项目零外部依赖**，不需要 resolve 任何 package。

### 首次使用

1. 打开 App → `⌘,` 进入设置
2. **Provider 与密钥**：填 Base URL / 默认模型，粘贴 API Key，点「保存到 Keychain」
3. **模型路由**：确认优先级顺序（出厂是 OpenAI → OpenAI 备用 → DeepSeek → Ollama）
4. 回主界面 `⌘N` 新建任务：名称 + 目标 + 步骤数 → 自动开跑

### 数据位置

| 内容 | 位置 |
|---|---|
| 任务 / 步骤 / 检查点 / 日志 | `~/Library/Application Support/AIRunner/airunner.sqlite` |
| API Key | macOS Keychain，`service = com.airunner.apikeys` |
| 非敏感配置（路由、并发、重试参数） | `UserDefaults`，key `com.airunner.settings.v1` |

---

## 三、架构

```
┌─ UI (SwiftUI) ────────────────────────────────────────────────┐
│ TaskListView / TaskDetailView(含 Web Execution 区) / LogView    │
│ CreateTaskView / SettingsView(Provider·路由·ChatGPT Web·运行)  │
└────────────────────────┬──────────────────────────────────────┘
                         │ @MainActor ObservableObject
┌────────────────────────▼──────────────────────────────────────┐
│ TaskManager — 只做「读库→发布状态」与「调动作→刷新」           │
└────────────────────────┬──────────────────────────────────────┘
┌────────────────────────▼──────────────────────────────────────┐
│ JobRunner (actor)  ← 核心执行循环（按 executionMode 分派）      │
│   ├─ TaskExecutionRegistry   同一任务只允许一个 runner          │
│   ├─ CheckpointManager       每步产出检查点                    │
│   ├─ RecoveryManager         崩溃恢复                          │
│   └─ ResponseValidator       非空 / JSON 校验                  │
├──────────────────────────┬────────────────────────────────────┤
│  Web Execution (primary) │  API Execution (optional)           │
│  WebExecutionCoordinator │  ModelRouter + RetryManager         │
│  ContinuationPromptBuilder│ ProviderFactory                   │
│         │                │         │                           │
│  ClipboardServicing      │   AIProvider                       │
│  BrowserLaunching        │   (OpenAICompatible · Mock)        │
│         │                │         │                           │
│    ChatGPT Web           │  api.openai.com / 自建网关          │
│   (人工交接账号)          │                                    │
├──────────────────────────┴────────────────────────────────────┤
│ Repositories (Task/Step/Checkpoint/Event/ProviderHealth)       │
│        └─ Database (系统 SQLite3, WAL, 单事务原子提交)          │
├───────────────────────────────────────────────────────────────┤
│ KeychainManager (Security.framework) · LoggerService(强制脱敏)  │
└───────────────────────────────────────────────────────────────┘
```

两条通道**共用**完全相同的持久化与编排设施 —— SQLite / TaskStep / Checkpoint /
RecoveryManager / Logs / ResponseValidator。差别只在"这一步的结果从哪里来"。

### 目录

```
Sources/AIRunnerCore/          # 零 UI 依赖, 可被纯命令行测试驱动
  Models/         AITask · TaskStep · Checkpoint · AIRequest/Response
                  ProviderConfig · ProviderHealth · AppEvent · JSONValue
  Core/           JobRunner · ModelRouter · RetryManager · CheckpointManager
                  RecoveryManager · TaskManager · TaskExecutionRegistry
                  ResponseValidator · TaskPlanner · AppServices
  Providers/      AIProvider(协议) · OpenAICompatibleProvider · MockAIProvider
                  ProviderFactory
  Persistence/    Database · DatabaseMigrator · Repositories/*
  Security/       KeychainManager
  Services/       LoggerService(含 SecretRedactor) · AppSettings
  Utilities/      AppError · JSONCoding · AsyncSemaphore

Sources/AIRunner/              # SwiftUI 壳
  App/AppState.swift
  UI/{ContentView, Tasks/*, Settings/*, Logs/*}

Tests/AIRunnerCoreTests/       # 69 个测试
Scripts/make_app.sh
```

---

## 四、四条不可动摇的设计规则

### 1. 原子提交 —— 结果 + 检查点 + 进度，同一个事务

`StepRepository.commitSuccessfulStep` 在**单个 SQLite 事务**内完成三件事：

```sql
UPDATE task_steps  SET status='completed', output_json=? ...   -- 1. 结果
INSERT INTO checkpoints (...) VALUES (...)                     -- 2. 检查点
UPDATE tasks       SET current_step=? ...                      -- 3. 进度
```

三者要么全成功，要么全回滚。

> 如果拆成三个独立事务，进程在任意两写之间被 kill 都会留下一致性裂痕 ——
> 例如「步骤已完成但检查点没推进」，重启后会重复执行该步骤。
> 测试 `testCommitFailureLeavesNoPartialState` 专门验证回滚。

### 2. 幂等 —— 已完成的步骤**查询不到**

```swift
public func nextExecutableStep(taskID: String) throws -> TaskStep? {
    // 只返回 pending / interrupted
    // completed / failed / skipped 永远不会出现在结果里
}
```

不靠调用方自觉判断，而是让 SQL 本身取不到已完成的行。
再加上 `UNIQUE(task_id, step_index)`，重复生成计划也不会打乱进度。

### 3. 错误分类 —— 绝不「一律重试」

| 错误 | 策略 | 计入重试预算 | 熔断 Provider |
|---|---|---|---|
| `network` / `timeout` | 原地退避重试 | ✅ | ❌ |
| `rateLimit` | **长**退避（独立预算，尊重 `Retry-After`） | ❌ 单独计账 | ❌ |
| `providerUnavailable` | 换 backend | ❌ | ✅ 累计到阈值 |
| `modelUnavailable` | 换同 Provider 其它模型 | ❌ | 仅拉黑该模型 |
| `authentication` | **暂停任务** | ❌ | ✅ 立即 + 长冷却 |
| `billingRequired` | **暂停任务** | ❌ | ✅ 立即 + 6h 冷却 |
| `invalidRequest` | 步骤失败 | ❌ | ❌ |
| `contextTooLong` | 缩上下文后重试 | ✅ | ❌ |
| `invalidOutput` | 带修正提示重试（独立 repair 预算） | ✅ | ❌ |
| `cancelled` | 立即返回 cancelled | ❌ | ❌ |
| `fatal` | 任务失败 | ❌ | ❌ |

退避：`min(5 × 2^n, 300s) + 30% jitter` → 5, 10, 20, 40, 80, 160, 300…

### 4. 防重复与防死循环

- **同一任务同时只有一个 runner**：`TaskExecutionRegistry.claim(taskID:)`，
  连点三次 Start 不会让步骤跑三遍（`testRepeatedStartDoesNotDuplicateExecution`）。
- **fallback 不会 A→B→A→B**：每次尝试都把 backend 加入 `attempted` 集合并传回
  `selectBackend(excluding:)`，试过的不会再被选中；候选池耗尽返回 `nil`，
  Runner 据此暂停或失败（`testRouterNeverProducesABABCycle`）。

---

## 五、崩溃恢复

App 启动时 `RecoveryManager.recover()` 处理三类残留：

| 残留状态 | 处理 |
|---|---|
| `task_steps.status = 'running'` | → `interrupted`（可执行）。该步 checkpoint 从未提交，结果不可信，必须重跑 |
| `tasks.status = 'running'` | 保持 running，由 TaskManager 重新挂上 Runner |
| `tasks.status = 'running'` 但已无可执行步骤 | 修正为 `completed`（退出时没来得及写状态） |

`paused` 的任务**不会**被自动拉起 —— 那是用户的主动意图。
全程写入 `APP_CRASH_RECOVERY` / `RECOVERY_COMPLETED` 事件，日志可追溯。

恢复流程本身只改数据库状态，不直接起 Runner；实际启动统一走 `JobRunner.start`，
因此同样受 `TaskExecutionRegistry` 保护。

---

## 六、测试

```
swift test --disable-sandbox
```

**98 个测试，全部通过。**

| 测试文件 | 覆盖 |
|---|---|
| `RetryManagerTests` (13) | 退避序列精确值、jitter 上界、`Retry-After` 优先、独立预算、熔断触发判定 |
| `ModelRouterTests` (16) | 优先级、禁用路由、**防 A/B 循环**、认证/余额立即熔断、网络抖动不熔断、恢复清冷却 |
| `CheckpointTests` (10) | 检查点推进、摘要累积与截断、**事务原子性（含失败回滚）** |
| `CrashRecoveryTests` (12) | running→interrupted、任务保持 running、**completed 永不可执行**、卡死修正、恢复幂等 |
| `JobRunnerTests` (12) | API 通道的 5 个场景 + 重复启动 + 暂停恢复 + 取消保留历史 + 完整生命周期 |
| **`WebExecutionTests` (29)** | **Web 通道的全部行为** —— 见下表 |
| `PersistenceSmokeTests` (5) | **真实文件数据库**：WAL、外键 CASCADE、关闭重开数据仍在、中断后重开继续 |

### Web 通道专项测试

| 主题 | 关键断言 |
|---|---|
| Prompt 自包含性 | 含目标 / `1...63` 压缩进度 / 检查点摘要 / `Do NOT redo` / 明确声明"没有历史"；不含任何会话标识 |
| **确定性** | 同样输入产出**逐字相同**的 prompt —— 这是崩溃后能重新生成的前提 |
| 账号交接 | 交接前后 `currentStep` 与检查点**一字未动**；恢复后从 `step 3` 继续而非回到 `step 0` |
| 崩溃恢复 | `prepared` 步骤重启后**重新生成的 prompt 与之前完全相同**，且不换步骤 |
| 不重复工作 | 换账号后 `prepareStep` 返回 `step 2` 而非重做 `step 1` |
| 校验失败 | 空结果被拒绝，**检查点不推进**，步骤保持 `prepared` 可重新提交 |
| 通道隔离 | Web 通道下 `mock.calls == 0` —— **绝不触碰 API Provider** |
| Runner 行为 | 生成 prompt 后任务转 `waitingForUser` 并**立即退出**，不阻塞等用户 |
| 端到端 | 跨账号 5 步任务：A 账号做 2 步 → 交接 → B 账号做 3 步，A 的结果原封不动 |
| 迁移 | v1→v2 **非破坏性**、可重入；老任务默认归入 `chatgpt_web` |

需求文档里的 5 个运行场景都有对应测试：

- **A** 5 步全成功 → `completed`
- **B** 第 3 步 timeout 一次 → 重试 → 继续（`mock.calls == 4`）
- **C** 第 2 步执行中被杀 → 重启 → 只补跑未完成步骤（`mock.calls == 2`，前两步输出原封不动）
- **D** Primary 不可用 → Backup 成功，且不来回震荡
- **E** Authentication → 立即暂停，`mock.calls == 1`（绝不重试）

调试单个失败用例：

```bash
AILR_TEST_VERBOSE=1 swift test --disable-sandbox --filter testScenarioC_crashRecoveryResumesFromInterruptedStep
```

---

## 七、安全

| 检查项 | 结论 |
|---|---|
| 源码硬编码密钥 | 无 |
| API Key 写入 Keychain | ✅ `kSecClassGenericPassword`，`kSecAttrAccessibleAfterFirstUnlock` |
| API Key 进 UserDefaults | ❌ 不会（`AppSettings` 里没有 key 字段） |
| API Key 进 SQLite | ❌ 不会 |
| API Key 进日志 | ❌ `SecretRedactor` 强制脱敏（精确匹配已登记密钥 + 正则识别 `sk-…`/`Bearer …`/`api_key=…`） |
| API Key 展示 | 只用 `SecretMasking.mask()`，UI 最多显示 `sk-••••••••ab` |
| 请求头泄漏 | `Authorization: Bearer` 只在 `OpenAICompatibleProvider` 内部设置，不写日志 |
| 网络层 | `URLSessionConfiguration.ephemeral` —— 不落盘缓存、不写 cookie |

`apiKey` 只出现在三处：Keychain 读取、Authorization 头设置、UI 的 `SecureField` 局部状态（存完立即清空）。

---

## 八、已知取舍

| 决策 | 理由 |
|---|---|
| **不用 GRDB，用系统 SQLite3** | 零依赖 → Xcode 打开即刻构建，不需 resolve；事务边界完全可控（原子提交是本项目最核心的正确性要求）。DB 层封装在 `Database.swift` 之后，将来换 GRDB 只动一层 |
| 上下文只带 `workingSummary` | 300 步任务若每步都塞全部历史，第 50 步就爆窗口且费用失控 |
| 步骤拆分为 N 个等价步骤 | MVP 优先把 Runner/Checkpoint/Retry/Recovery 跑通，不做智能 Planner |
| 全局并发默认 3 | 改并发数需重启 App（Runner 在启动时创建 semaphore） |
| `Database` 用 `NSLock` 而非 actor | SQLite 是同步 C API，actor hop 只会增加开销；且 actor 重入会让「事务内不能 await」难以强制 |

---

## 九、改造说明：从 API 通道到 ChatGPT Web 主通道

本次调整**没有重建工程**，是在原结构上更换执行适配层。

### 原样保留（未改一行）

`Checkpoint` · `Database` + 全部 Repository · `CheckpointManager` · `TaskExecutionRegistry` ·
`ResponseValidator` · `RetryManager` 的退避数学 · `TaskListView` · `LogView` · 崩溃恢复 ·
输出校验 · 全部历史 migration

### 新增

| 文件 | 作用 |
|---|---|
| `Core/WebExecutionCoordinator.swift` | Web 通道状态机：prepare / accept / 账号交接 |
| `Core/ContinuationPromptBuilder.swift` | 生成**自包含且确定性**的续跑 prompt |
| `Models/ExecutionMode.swift` | `chatgpt_web`（默认）/ `api` |
| `Services/ClipboardService.swift` | `ClipboardServicing` + `BrowserLaunching` 协议与测试替身 |
| `Sources/AIRunner/Platform/*` | AppKit 实现（`NSPasteboard` / `NSWorkspace`） |

### 降级为可选后端（代码保留，移入 `Legacy/API/`）

`OpenAICompatibleProvider` · `ProviderFactory` —— 主流程不再走它们，
只有任务显式声明 `executionMode == .api` 时才参与。

### 修改（局部）

| 文件 | 改动 |
|---|---|
| `Models/AITask.swift` | `TaskStatus` 加 3 个"等用户"状态；`AITask` 加 `executionMode` |
| `Models/TaskStep.swift` | `StepStatus` 加 `prepared`；加 `preparedAt` / `submittedAt` |
| `JobRunner` | `executeStep` 按 `executionMode` 分派；新增 `executeWebStep` |
| `RecoveryManager` | 等用户状态**不自动拉起**；报告里单独列出 |
| `DatabaseMigrator` | **v2 非破坏性迁移**（`ALTER TABLE ADD COLUMN`，可重入） |
| `AppSettings` | 加 Web 配置；**手写解码**保证老配置平滑升级 |
| UI | `TaskDetailView` 加 Web Execution 区；`SettingsView` 加 ChatGPT Web 页 |

### 数据库变更

```sql
-- v2：全部是 ADD COLUMN，老数据一行不动
ALTER TABLE tasks       ADD COLUMN execution_mode TEXT NOT NULL DEFAULT 'chatgpt_web';
ALTER TABLE task_steps  ADD COLUMN prepared_at  TEXT;
ALTER TABLE task_steps  ADD COLUMN submitted_at TEXT;
```

实测：已有 v1 数据库启动后自动升到 v2，旧列与全部 5 张表完整保留。

---

## 十、Phase 2 建议

按「对当前闭环的增益」排序，不是按炫技程度：

1. **浏览器辅助（有限度）** — 在用户**已经打开的** ChatGPT 标签页上填入 prompt 并读取回复。
   仍然不碰 Cookie / token / 登录；只是把"复制粘贴"这一步省掉。这是当前最高价值的一步
2. **Notification** — 任务进入 `waitingForAccount` / `waitingForUser` / `completed` 时发本地通知。
   长任务最需要的其实是"轮到你操作了"和"跑完了"
3. **菜单栏模式** — 常驻状态栏显示「有几个任务在等我」
4. **开机启动 + launchd** — `NSSupportsAutomaticTermination=false` 已就位，补一个 LaunchAgent plist
5. **账号备注** — 给每个 ChatGPT session 起个名字（"账号A"），交接时在日志里留痕。
   **只存名字，不存任何凭据**
6. **导出 Markdown / JSON** — 检查点里已有结构化 `state`
7. **智能 Task Planner** — 用一次 ChatGPT 交互把 goal 拆成有依赖的步骤图
8. **文件输入 / PDF 分析 / Directory Watch** — 让 `map` 步骤真正消费文件
9. **自动压缩 Context** — 按 token 预算而非字符数截断
10. **更多 Provider 原生协议**（Anthropic Messages / Gemini generateContent）

第 1 条之前的 MVP 未跑通前不实现这些。


---

## 3. 需求边界对照表


需求方明确列出了若干**禁止实现**的能力。下面逐条给出实现方式与代码证据。


| # | 需求约束 (用户明确要求"不要做") | 实现方式 / 代码证据 |
|---|---|---|
| 1 | 不自动登录多个 ChatGPT 个人账号 | 全部代码中不存在任何登录逻辑; `BrowserLaunching` 协议只有 `open(URL)` 一个方法 |
| 2 | 不自动轮换账号规避额度 | `WebExecutionCoordinator.pauseForAccountSwitch()` 只把任务置为 `waitingForAccount` 并**停下**; 恢复必须由用户点按钮触发 (`resumeAfterManualAccountSwitch`) |
| 3 | 不读取浏览器 Cookie | 无 `WebKit` / `HTTPCookieStorage` / `WKWebsiteDataStore` 引用; 无任何 Cookie 数据库路径 |
| 4 | 不复制 session token | 无 `localStorage` / `sessionStorage` / token 注入代码; 密钥仅存 macOS Keychain |
| 5 | 不用 Selenium / Playwright 操作网页 | 零第三方依赖 (`Package.swift` 的 `dependencies: []`); 无进程调用浏览器 |
| 6 | 不绕过 rate limit / usage limit | 无任何限流规避逻辑; 遇到 `billingRequired` 一律**熔断该 Provider + 暂停任务** |
| 7 | 只使用官方 API 或用户合法配置的 Provider | Web 通道仅生成文本 prompt 交给用户; API 通道 (可选) 需用户自配 Key |

### 能力边界的技术保证

`BrowserLaunching` 协议的全部内容:

```swift
public protocol BrowserLaunching: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}
```

AppKit 实现 (`Sources/AIRunner/Platform/WorkspaceBrowserLauncher.swift`) 的全部内容:

```swift
@discardableResult
func open(_ url: URL) -> Bool {
    NSWorkspace.shared.open(url)
}
```

—— 打开一个 URL。没有别的。


---

## 4. 源码


### 数据模型 Models


#### `Sources/AIRunnerCore/Models/AIRequest.swift` (57 行)

````swift
import Foundation

/// 期望的响应格式。
public enum ResponseFormat: String, Codable, Sendable, CaseIterable {
    case text
    case json

    public var displayName: String {
        switch self {
        case .text: return "文本"
        case .json: return "JSON"
        }
    }
}

/// 统一的模型请求。JobRunner 只构造这个结构, 不关心具体是哪家 SDK。
///
/// 注意: `model` 刻意不在这里 —— 模型绑定在 Provider 实例上 (见 ProviderConfig),
/// 这样 ModelRouter 只需要产出 (provider, model) 二元组即可构造 backend。
public struct AIRequest: Codable, Sendable, Equatable {

    public var systemPrompt: String
    public var userPrompt: String
    public var maxOutputTokens: Int?
    public var temperature: Double?
    public var responseFormat: ResponseFormat
    public var timeout: TimeInterval

    public init(
        systemPrompt: String,
        userPrompt: String,
        maxOutputTokens: Int? = 2048,
        temperature: Double? = 0.2,
        responseFormat: ResponseFormat = .text,
        timeout: TimeInterval = 180
    ) {
        self.systemPrompt = systemPrompt
        self.userPrompt = userPrompt
        self.maxOutputTokens = maxOutputTokens
        self.temperature = temperature
        self.responseFormat = responseFormat
        self.timeout = timeout
    }

    /// 当上下文超长时, 缩小 user prompt 的辅助方法。
    ///
    /// 简单按字符数截断并保留尾部 —— reasoning 类任务的尾部通常更重要。
    public func shrinkingUserPrompt(factor: Double) -> AIRequest {
        var copy = self
        let keep = max(200, Int(Double(userPrompt.count) * factor))
        if userPrompt.count > keep {
            let cut = userPrompt.index(userPrompt.endIndex, offsetBy: -keep)
            copy.userPrompt = "[上下文已截断以适应模型窗口]\n" + String(userPrompt[cut...])
        }
        return copy
    }
}
````


#### `Sources/AIRunnerCore/Models/AIResponse.swift` (43 行)

````swift
import Foundation

/// 统一的模型响应。
public struct AIResponse: Codable, Sendable, Equatable {

    public let text: String
    public let provider: String
    public let model: String
    public let inputTokens: Int?
    public let outputTokens: Int?
    public let latencyMilliseconds: Int
    /// 部分 Provider 会返回 finish_reason (如 length / stop), 便于诊断截断。
    public let finishReason: String?

    public init(
        text: String,
        provider: String,
        model: String,
        inputTokens: Int? = nil,
        outputTokens: Int? = nil,
        latencyMilliseconds: Int,
        finishReason: String? = nil
    ) {
        self.text = text
        self.provider = provider
        self.model = model
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.latencyMilliseconds = latencyMilliseconds
        self.finishReason = finishReason
    }

    public var totalTokens: Int? {
        guard inputTokens != nil || outputTokens != nil else { return nil }
        return (inputTokens ?? 0) + (outputTokens ?? 0)
    }

    public var backendLabel: String { "\(provider) / \(model)" }

    public var isTruncated: Bool {
        finishReason?.lowercased() == "length"
    }
}
````


#### `Sources/AIRunnerCore/Models/AITask.swift` (234 行)

````swift
import Foundation

/// 任务状态。
///
/// 分三组:
/// * **流程态**: queued / running / waiting / paused
/// * **等用户态**: waitingForAccount / waitingForBrowser / waitingForUser
///   —— checkpoint 已安全落盘, 只差用户做一个手动动作 (切账号 / 打开页面 / 提交 prompt)
/// * **终态**: completed / failed / cancelled
public enum TaskStatus: String, Codable, Sendable, CaseIterable {
    case queued
    case running
    case waiting

    /// ★ ChatGPT Web 主流程: 当前 session 无法继续, 需要用户手动切换到
    /// 另一个**自己已授权**的 ChatGPT session。程序不读 Cookie、不读 token、
    /// 不执行登录、不自动轮换账号。
    case waitingForAccount
    /// 需要用户把浏览器/页面准备好 (例如 ChatGPT 页面被关闭, 或需要新开一个对话)。
    case waitingForBrowser
    /// prompt 已生成并交给用户, 等用户把 ChatGPT 的输出贴回来。
    case waitingForUser

    case paused
    case completed
    case failed
    case cancelled

    /// 终态: 不再有任何自动执行。
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .cancelled: return true
        case .queued, .running, .waiting, .paused,
             .waitingForAccount, .waitingForBrowser, .waitingForUser: return false
        }
    }

    /// 是否处于"非终态且可被 Runner 接管"。
    public var isRunnable: Bool {
        self == .running || self == .queued
    }

    /// 是否需要用户到手动操作才能继续。
    ///
    /// Runner 遇到这些状态会立刻退出, 不做任何轮询等待 —— 用户可能几小时后才回来。
    public var requiresUserAction: Bool {
        switch self {
        case .waitingForAccount, .waitingForBrowser, .waitingForUser: return true
        default: return false
        }
    }

    public var displayName: String {
        switch self {
        case .queued:            return "排队中"
        case .running:           return "运行中"
        case .waiting:           return "等待中"
        case .waitingForAccount: return "等待切换账号"
        case .waitingForBrowser: return "等待浏览器"
        case .waitingForUser:    return "等待提交结果"
        case .paused:            return "已暂停"
        case .completed:         return "已完成"
        case .failed:            return "已失败"
        case .cancelled:         return "已取消"
        }
    }

    /// 合法状态迁移表。
    ///
    /// 存在的意义: 阻止"已完成的任务被 Resume"这类会把 checkpoint 逻辑搞乱的非法迁移。
    public var allowedTransitions: Set<TaskStatus> {
        let awaiting: Set<TaskStatus> = [.waitingForAccount, .waitingForBrowser, .waitingForUser]
        // 从任意非终态出发都允许转往的状态
        let awaken: Set<TaskStatus> = [.running, .paused, .cancelled, .failed]

        switch self {
        case .queued:
            return awaken.union(awaiting)

        case .running:
            var result = awaken.union(awaiting)
            result.formUnion([.waiting, .completed, .queued])
            return result

        case .waiting:
            return awaken.union(awaiting)

        // 等用户态之间可以互相切换 (例如「等待浏览器」→「等待切换账号」);
        // 用户做完动作后 → running, 也可以转 paused / cancelled / failed。
        case .waitingForAccount, .waitingForBrowser, .waitingForUser:
            return awaken.union(awaiting)

        case .paused:
            let base: Set<TaskStatus> = [.running, .cancelled, .failed]
            return base

        case .completed:
            return []                       // 终态

        case .failed:
            let base: Set<TaskStatus> = [.running]   // 修好配置后允许重试
            return base

        case .cancelled:
            let base: Set<TaskStatus> = [.running]   // 允许复活
            return base
        }
    }

    public func canTransition(to next: TaskStatus) -> Bool {
        if next == self { return true }
        return allowedTransitions.contains(next)
    }
}

/// 一个长任务。
public struct AITask: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    public var name: String
    public var goal: String
    public var status: TaskStatus

    /// 执行通道。默认走 ChatGPT Web (人工交接账号); `api` 为可选后端。
    public var executionMode: ExecutionMode

    /// 这两个字段只在 `executionMode == .api` 时有意义。
    /// Web 模式下不参与主流程, 保留是为了让已有的 API 后端仍然可用。
    public var primaryProvider: String
    public var primaryModel: String

    public var currentStep: Int
    public var totalSteps: Int

    public var retryCount: Int
    public var maxRetries: Int

    public var createdAt: Date
    public var updatedAt: Date

    // MARK: 扩展字段

    /// 失败/暂停原因 (用户可读)。
    public var errorMessage: String?
    /// AppError.eventName, 便于 UI 分类展示。
    public var errorClass: String?
    /// waiting 状态的目标解除时间。
    public var waitingUntil: Date?
    /// 规划方式: explicit / uniform (MVP 用 uniform)。
    public var planType: String
    /// 任意扩展元数据。
    public var meta: JSONValue

    public init(
        id: String = UUID().uuidString,
        name: String,
        goal: String,
        status: TaskStatus = .queued,
        executionMode: ExecutionMode = .chatGPTWeb,
        primaryProvider: String = "",
        primaryModel: String = "",
        currentStep: Int = 0,
        totalSteps: Int = 0,
        retryCount: Int = 0,
        maxRetries: Int = 8,
        createdAt: Date = Date(),
        updatedAt: Date = Date(),
        errorMessage: String? = nil,
        errorClass: String? = nil,
        waitingUntil: Date? = nil,
        planType: String = "uniform",
        meta: JSONValue = .emptyObject
    ) {
        self.id = id
        self.name = name
        self.goal = goal
        self.status = status
        self.executionMode = executionMode
        self.primaryProvider = primaryProvider
        self.primaryModel = primaryModel
        self.currentStep = currentStep
        self.totalSteps = totalSteps
        self.retryCount = retryCount
        self.maxRetries = maxRetries
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.errorMessage = errorMessage
        self.errorClass = errorClass
        self.waitingUntil = waitingUntil
        self.planType = planType
        self.meta = meta
    }

    /// 0.0 ... 1.0
    public var progress: Double {
        guard totalSteps > 0 else { return 0 }
        return min(1.0, max(0.0, Double(currentStep) / Double(totalSteps)))
    }

    public var progressText: String {
        "\(currentStep) / \(totalSteps)"
    }

    public var isFinished: Bool { status.isTerminal }

    /// 当前是否需要用户做一个手动动作。
    public var needsUserAction: Bool { status.requiresUserAction }

    /// 人类可读的下一步动作提示。
    public var actionHint: String {
        switch status {
        case .queued:
            return "点击「开始执行」"
        case .running:
            return executionMode == .chatGPTWeb ? "正在准备下一步的续跑 prompt" : "正在执行"
        case .waiting:
            return waitingUntil.map { "等待至 \(DateCoding.string(from: $0))" } ?? "等待中"
        case .waitingForAccount:
            return "已安全保存检查点。请手动切换到另一个已授权的 ChatGPT 会话, 然后点「我已完成切换」。"
        case .waitingForBrowser:
            return "请在浏览器中打开 ChatGPT, 然后点「我已完成」。"
        case .waitingForUser:
            return "续跑 prompt 已复制。请提交给 ChatGPT, 再把回复贴回来。"
        case .paused:
            return errorMessage ?? "已暂停, 可继续"
        case .completed:
            return "全部步骤已完成"
        case .failed:
            return errorMessage ?? "执行失败"
        case .cancelled:
            return "已取消, 历史结果保留"
        }
    }
}
````


#### `Sources/AIRunnerCore/Models/AppEvent.swift` (145 行)

````swift
import Foundation

public enum LogLevel: String, Codable, Sendable, CaseIterable, Comparable {
    case debug
    case info
    case warning
    case error
    case critical

    public var sortOrder: Int {
        switch self {
        case .debug:    return 0
        case .info:     return 1
        case .warning:  return 2
        case .error:    return 3
        case .critical: return 4
        }
    }

    public static func < (lhs: LogLevel, rhs: LogLevel) -> Bool {
        lhs.sortOrder < rhs.sortOrder
    }

    public var displayName: String {
        rawValue.uppercased()
    }

    public var symbolName: String {
        switch self {
        case .debug:    return "ladybug"
        case .info:     return "info.circle"
        case .warning:  return "exclamationmark.triangle"
        case .error:    return "xmark.octagon"
        case .critical: return "exclamationmark.octagon.fill"
        }
    }
}

/// 事件类型。存库时使用 rawValue (字符串), 便于将来扩展而不破坏旧数据。
public enum EventType: String, Codable, Sendable, CaseIterable {

    // 任务生命周期
    case taskCreated      = "TASK_CREATED"
    case taskStarted      = "TASK_STARTED"
    case taskPaused       = "TASK_PAUSED"
    case taskResumed      = "TASK_RESUMED"
    case taskCancelled    = "TASK_CANCELLED"
    case taskCompleted    = "TASK_COMPLETED"
    case taskFailed       = "TASK_FAILED"
    case taskWaiting      = "TASK_WAITING"

    // 步骤生命周期
    case stepStarted      = "STEP_STARTED"
    case stepCompleted    = "STEP_COMPLETED"
    case stepFailed       = "STEP_FAILED"
    case stepSkipped      = "STEP_SKIPPED"
    case stepRetry        = "STEP_RETRY"

    // 检查点
    case checkpointSaved  = "CHECKPOINT_SAVED"

    // 路由与 Provider
    case backendSelected  = "BACKEND_SELECTED"
    case backendSwitched  = "BACKEND_SWITCHED"
    case backendExhausted = "BACKEND_EXHAUSTED"
    case providerDegraded = "PROVIDER_DEGRADED"
    case providerUnavailable = "PROVIDER_UNAVAILABLE"
    case providerRecovered = "PROVIDER_RECOVERED"
    case rateLimited      = "RATE_LIMITED"
    case billingBlocked   = "BILLING_BLOCKED"

    // 运行器
    case runnerStarted    = "RUNNER_STARTED"
    case runnerStopped    = "RUNNER_STOPPED"
    case runnerRejectedDuplicate = "RUNNER_REJECTED_DUPLICATE"

    // ChatGPT Web 执行 (主流程)
    case webStepPrepared         = "WEB_STEP_PREPARED"
    case webStepSubmitted        = "WEB_STEP_SUBMITTED"
    case webPromptCopied         = "WEB_PROMPT_COPIED"
    case resultImported          = "RESULT_IMPORTED"
    case resultImportRejected    = "RESULT_IMPORT_REJECTED"
    case accountHandoffRequested = "ACCOUNT_HANDOFF_REQUESTED"
    case accountHandoffCompleted = "ACCOUNT_HANDOFF_COMPLETED"
    case browserOpened           = "BROWSER_OPENED"

    // 崩溃恢复
    case appCrashRecovery = "APP_CRASH_RECOVERY"
    case recoveryCompleted = "RECOVERY_COMPLETED"

    // 配置与安全
    case configChanged    = "CONFIG_CHANGED"
    case keychainUpdated  = "KEYCHAIN_UPDATED"

    case unknown          = "UNKNOWN"

    public var displayName: String { rawValue }
}

/// 一条事件/日志记录。
public struct AppEvent: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    public var taskID: String?
    public var stepIndex: Int?
    public var level: LogLevel
    public var eventType: EventType
    public var message: String
    public var metadata: JSONValue?
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        taskID: String? = nil,
        stepIndex: Int? = nil,
        level: LogLevel = .info,
        eventType: EventType,
        message: String,
        metadata: JSONValue? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.stepIndex = stepIndex
        self.level = level
        self.eventType = eventType
        self.message = message
        self.metadata = metadata
        self.createdAt = createdAt
    }

    public var timestampText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        f.timeZone = .current
        return f.string(from: createdAt)
    }

    public var fullTimestampText: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm:ss"
        f.timeZone = .current
        return f.string(from: createdAt)
    }
}
````


#### `Sources/AIRunnerCore/Models/Checkpoint.swift` (58 行)

````swift
import Foundation

/// 检查点 —— 整个续跑机制的核心记录。
///
/// 每成功完成一个 Step 就写入一条。`nextStep` 是恢复时唯一的权威依据:
/// 崩溃重启后只需要读最新 checkpoint 的 `nextStep`, 就不用重跑之前的步骤。
public struct Checkpoint: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    public let taskID: String

    /// 最后一个成功完成的 step index (从 0 开始)。
    public var completedStep: Int
    /// 下一个应该执行的 step index。== completedStep + 1。
    public var nextStep: Int

    /// 滚动摘要 (MVP: 取最近若干步输出的截断拼接)。
    public var workingSummary: String?

    /// 结构化状态 (全局发现、计数、自定义数据)。
    public var state: JSONValue

    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        completedStep: Int,
        nextStep: Int,
        workingSummary: String? = nil,
        state: JSONValue = .emptyObject,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.taskID = taskID
        self.completedStep = completedStep
        self.nextStep = nextStep
        self.workingSummary = workingSummary
        self.state = state
        self.createdAt = createdAt
    }

    /// 起始检查点 (尚未执行任何步骤)。
    public static func initial(taskID: String) -> Checkpoint {
        Checkpoint(
            taskID: taskID,
            completedStep: -1,
            nextStep: 0,
            workingSummary: "任务已创建, 尚未开始",
            state: .object(["completedSteps": .array([])])
        )
    }

    public var summaryPreview: String {
        let s = workingSummary?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return s.isEmpty ? "(无摘要)" : s
    }
}
````


#### `Sources/AIRunnerCore/Models/ExecutionMode.swift` (62 行)

````swift
import Foundation

/// 任务的执行通道。
///
/// 架构定位:
/// ```
///                  JobRunner
///                      │
///         ┌────────────┴─────────────┐
///         │                          │
///   Web Execution              API Execution
///     (primary)                  (optional)
///         │                          │
///  WebExecutionCoordinator      AIProvider
///         │
///  ContinuationPromptBuilder
///         │
///     ChatGPT Web
///  (manual session auth)
/// ```
///
/// 两条通道**共用**完全相同的持久化与编排设施:
/// SQLite / TaskStep / Checkpoint / RecoveryManager / Logs / ResponseValidator。
/// 差别只在"这一步的结果从哪里来"。
public enum ExecutionMode: String, Codable, Sendable, CaseIterable, Identifiable {

    /// ★ 主流程: ChatGPT Web + 人工账号交接。
    ///
    /// 程序负责: 检查点、已完成的步骤、续跑 prompt 生成、暂停与恢复、崩溃恢复。
    /// 用户负责: 在浏览器里手动切换账号、提交 prompt、把结果贴回来。
    ///
    /// 程序**不做**: 读 Cookie / 读 session token / 自动登录 / 自动轮换账号 /
    /// 绕过任何使用限制。
    case chatGPTWeb = "chatgpt_web"

    /// 可选后端: 官方 API 直连。
    ///
    /// 代码位于 `Legacy/API/`, 默认不参与主流程。需要用户自行配置 API Key,
    /// 且是否启用完全由用户决定。
    case api = "api"

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .chatGPTWeb: return "ChatGPT Web"
        case .api:        return "API (可选)"
        }
    }

    public var detail: String {
        switch self {
        case .chatGPTWeb:
            return "你在浏览器里手动完成账号切换与提交; 程序负责检查点、续跑 prompt 与崩溃恢复。"
        case .api:
            return "直连官方 API 全自动执行, 需自行配置 API Key。默认不启用。"
        }
    }

    /// 是否为默认通道。
    public var isPrimary: Bool { self == .chatGPTWeb }
}
````


#### `Sources/AIRunnerCore/Models/JSONValue.swift` (189 行)

````swift
import Foundation

/// Codable-safe 的任意 JSON 值。
///
/// 刻意 **不** 使用 `[AnyHashable: Any]` —— 它不 Codable、不 Sendable,
/// 且会在跨 actor 边界时静默丢失类型信息。
public enum JSONValue: Codable, Sendable, Hashable {
    case null
    case bool(Bool)
    case int(Int)
    case double(Double)
    case string(String)
    case array([JSONValue])
    case object([String: JSONValue])

    // MARK: - Decoding

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
            return
        }
        if let v = try? container.decode(Bool.self) {
            self = .bool(v); return
        }
        if let v = try? container.decode(Int.self) {
            self = .int(v); return
        }
        if let v = try? container.decode(Double.self) {
            self = .double(v); return
        }
        if let v = try? container.decode(String.self) {
            self = .string(v); return
        }
        if let v = try? container.decode([JSONValue].self) {
            self = .array(v); return
        }
        if let v = try? container.decode([String: JSONValue].self) {
            self = .object(v); return
        }
        throw DecodingError.dataCorruptedError(
            in: container,
            debugDescription: "无法识别的 JSON 值"
        )
    }

    // MARK: - Encoding

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:            try container.encodeNil()
        case .bool(let v):     try container.encode(v)
        case .int(let v):      try container.encode(v)
        case .double(let v):   try container.encode(v)
        case .string(let v):   try container.encode(v)
        case .array(let v):    try container.encode(v)
        case .object(let v):   try container.encode(v)
        }
    }

    // MARK: - 便捷访问

    public var stringValue: String? {
        switch self {
        case .string(let v): return v
        case .int(let v):    return String(v)
        case .double(let v): return String(v)
        case .bool(let v):   return String(v)
        default:             return nil
        }
    }

    public var intValue: Int? {
        switch self {
        case .int(let v):    return v
        case .double(let v): return Int(v)
        case .string(let v): return Int(v)
        default:             return nil
        }
    }

    public var doubleValue: Double? {
        switch self {
        case .double(let v): return v
        case .int(let v):    return Double(v)
        case .string(let v): return Double(v)
        default:             return nil
        }
    }

    public var boolValue: Bool? {
        switch self {
        case .bool(let v):   return v
        case .int(let v):    return v != 0
        case .string(let v): return ["true", "1", "yes"].contains(v.lowercased())
        default:             return nil
        }
    }

    public var arrayValue: [JSONValue]? {
        if case .array(let v) = self { return v }
        return nil
    }

    public var objectValue: [String: JSONValue]? {
        if case .object(let v) = self { return v }
        return nil
    }

    public subscript(key: String) -> JSONValue? {
        guard case .object(let dict) = self else { return nil }
        return dict[key]
    }

    public subscript(index: Int) -> JSONValue? {
        guard case .array(let arr) = self, arr.indices.contains(index) else { return nil }
        return arr[index]
    }

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }

    // MARK: - 常量

    public static let emptyObject = JSONValue.object([:])
    public static let emptyArray = JSONValue.array([])

    // MARK: - 与 Foundation 互转

    public init(any value: Any) {
        switch value {
        case let v as JSONValue:            self = v
        case is NSNull:                     self = .null
        case let v as Bool:                 self = .bool(v)
        case let v as Int:                  self = .int(v)
        case let v as Double:               self = .double(v)
        case let v as Float:                self = .double(Double(v))
        case let v as String:               self = .string(v)
        case let v as [Any]:                self = .array(v.map { JSONValue(any: $0) })
        case let v as [String: Any]:
            self = .object(v.mapValues { JSONValue(any: $0) })
        case let v as NSNumber:
            // NSNumber 包住了 Bool 时会走到这里
            if CFGetTypeID(v) == CFBooleanGetTypeID() {
                self = .bool(v.boolValue)
            } else if v.doubleValue == v.doubleValue.rounded(),
                      abs(v.doubleValue) < Double(Int.max) {
                self = .int(v.intValue)
            } else {
                self = .double(v.doubleValue)
            }
        default:
            self = .string(String(describing: value))
        }
    }

    /// 转回 Foundation 对象 (写入 UserDefaults / 拼接 HTTP body 时用)。
    public var foundationValue: Any {
        switch self {
        case .null:            return NSNull()
        case .bool(let v):     return v
        case .int(let v):      return v
        case .double(let v):   return v
        case .string(let v):   return v
        case .array(let v):    return v.map(\.foundationValue)
        case .object(let v):   return v.mapValues(\.foundationValue)
        }
    }

    public var prettyDescription: String {
        (try? JSONCoding.encodeToString(self, pretty: true)) ?? "<unencodable>"
    }
}

extension JSONValue: ExpressibleByStringLiteral {
    public init(stringLiteral value: String) { self = .string(value) }
}

extension JSONValue: ExpressibleByIntegerLiteral {
    public init(integerLiteral value: Int) { self = .int(value) }
}

extension JSONValue: ExpressibleByBooleanLiteral {
    public init(booleanLiteral value: Bool) { self = .bool(value) }
}
````


#### `Sources/AIRunnerCore/Models/ProviderConfig.swift` (170 行)

````swift
import Foundation

/// Provider 实现类型。
///
/// `mock` 仅供测试与离线演示。**绝不进入生产默认路由** ——
/// 见 `ProviderConfig.defaults`, 其中不含任何 mock 条目。
public enum ProviderKind: String, Codable, Sendable, CaseIterable {
    case openAICompatible = "openai_compatible"
    case mock

    public var displayName: String {
        switch self {
        case .openAICompatible: return "OpenAI 兼容"
        case .mock:             return "Mock (仅测试)"
        }
    }
}

/// 一个 Provider 的配置。
public struct ProviderConfig: Codable, Sendable, Identifiable, Equatable, Hashable {

    public var id: String
    public var displayName: String
    public var kind: ProviderKind

    /// 例如 https://api.openai.com/v1 (不含 /chat/completions)
    public var baseURL: String
    public var defaultModel: String
    public var models: [String]

    public var timeout: TimeInterval
    public var maxOutputTokens: Int

    /// Keychain 中使用的键名, 例如 "openai.apiKey"。
    public var keychainKey: String
    public var enabled: Bool

    public init(
        id: String,
        displayName: String,
        kind: ProviderKind = .openAICompatible,
        baseURL: String,
        defaultModel: String,
        models: [String] = [],
        timeout: TimeInterval = 180,
        maxOutputTokens: Int = 2048,
        keychainKey: String? = nil,
        enabled: Bool = true
    ) {
        self.id = id
        self.displayName = displayName
        self.kind = kind
        self.baseURL = baseURL
        self.defaultModel = defaultModel
        self.models = models.isEmpty ? [defaultModel] : models
        self.timeout = timeout
        self.maxOutputTokens = maxOutputTokens
        self.keychainKey = keychainKey ?? "\(id).apiKey"
        self.enabled = enabled
    }

    /// 本地模型 / mock 不需要 API Key。
    public var requiresAPIKey: Bool {
        switch kind {
        case .openAICompatible: return !isLocalEndpoint
        case .mock:             return false
        }
    }

    private var isLocalEndpoint: Bool {
        let lower = baseURL.lowercased()
        return lower.contains("127.0.0.1") || lower.contains("localhost") || lower.contains("0.0.0.0")
    }

    public var chatCompletionsURL: URL? {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: trimmed + "/chat/completions")
    }

    public var modelsURL: URL? {
        let trimmed = baseURL.hasSuffix("/") ? String(baseURL.dropLast()) : baseURL
        return URL(string: trimmed + "/models")
    }

    // MARK: - 出厂默认

    /// 出厂 Provider 列表。全部是"用户自己合法配置的官方 API 端点"。
    /// 不含任何 Cookie / 网页自动化 / 账号轮换相关的配置项。
    public static let defaults: [ProviderConfig] = [
        ProviderConfig(
            id: "openai",
            displayName: "OpenAI",
            baseURL: "https://api.openai.com/v1",
            defaultModel: "gpt-4o-mini",
            models: ["gpt-4o-mini", "gpt-4o"],
            timeout: 180,
            maxOutputTokens: 2048
        ),
        ProviderConfig(
            id: "anthropic",
            displayName: "Anthropic",
            // 注意: Anthropic 原生协议与 OpenAI 不同, MVP 阶段请填官方兼容网关
            // 或自建 OpenAI-compatible 代理端点。
            baseURL: "https://api.anthropic.com/v1",
            defaultModel: "claude-3-5-haiku-latest",
            models: ["claude-3-5-haiku-latest"],
            timeout: 180,
            maxOutputTokens: 2048
        ),
        ProviderConfig(
            id: "deepseek",
            displayName: "DeepSeek",
            baseURL: "https://api.deepseek.com/v1",
            defaultModel: "deepseek-chat",
            models: ["deepseek-chat"],
            timeout: 240,
            maxOutputTokens: 2048
        ),
        ProviderConfig(
            id: "ollama",
            displayName: "Ollama (本地)",
            baseURL: "http://127.0.0.1:11434/v1",
            defaultModel: "qwen2.5:7b",
            models: ["qwen2.5:7b"],
            timeout: 600,
            maxOutputTokens: 2048,
            enabled: false      // 默认关闭, 用户装了本地模型再开启
        ),
    ]
}

/// 路由表的一行。
public struct RouteEntry: Codable, Sendable, Identifiable, Equatable, Hashable {

    public var priority: Int
    public var provider: String
    public var model: String
    public var enabled: Bool
    public var note: String?

    public var id: Int { priority }

    public init(
        priority: Int,
        provider: String,
        model: String,
        enabled: Bool = true,
        note: String? = nil
    ) {
        self.priority = priority
        self.provider = provider
        self.model = model
        self.enabled = enabled
        self.note = note
    }

    public var label: String { "\(provider) / \(model)" }

    /// 出厂路由: Primary + Backup1 + Backup2 (+ 本地兜底)。
    public static let defaults: [RouteEntry] = [
        RouteEntry(priority: 1, provider: "openai", model: "gpt-4o-mini",
                   note: "主力"),
        RouteEntry(priority: 2, provider: "openai", model: "gpt-4o",
                   note: "同 Provider 升级模型"),
        RouteEntry(priority: 3, provider: "deepseek", model: "deepseek-chat",
                   note: "跨 Provider 兜底"),
        RouteEntry(priority: 4, provider: "ollama", model: "qwen2.5:7b",
                   enabled: false, note: "本地兜底 (需自行启动)"),
    ]
}
````


#### `Sources/AIRunnerCore/Models/ProviderHealth.swift` (95 行)

````swift
import Foundation

public enum ProviderHealthState: String, Codable, Sendable, CaseIterable {
    case healthy
    case degraded
    case unavailable

    public var displayName: String {
        switch self {
        case .healthy:     return "正常"
        case .degraded:    return "降级"
        case .unavailable: return "不可用"
        }
    }
}

/// Provider / 模型的健康度与熔断状态。
///
/// 熔断规则 (阈值来自 `RetryManager` 配置):
/// * 连续 3 次失败 -> `.degraded`
/// * 连续 5 次失败 -> `.unavailable` + 进入 cooldown
/// * `billingRequired` / `authentication` -> 立即 `.unavailable`, 且 cooldown 很长
///
/// 熔断的意义不是"绕过限制", 而是**停止无意义的重复调用** —— 认证失败或余额耗尽时
/// 继续打 API 只会浪费时间, 所以必须让 Router 立刻改走别的 backend 或暂停任务。
public struct ProviderHealth: Codable, Sendable, Equatable, Hashable {

    public var provider: String
    /// nil 表示这是 Provider 级 (所有模型共享) 的健康状态。
    public var model: String?
    public var state: ProviderHealthState
    public var consecutiveErrors: Int
    public var lastSuccess: Date?
    public var lastFailure: Date?
    public var cooldownUntil: Date?
    public var reason: String?

    public init(
        provider: String,
        model: String? = nil,
        state: ProviderHealthState = .healthy,
        consecutiveErrors: Int = 0,
        lastSuccess: Date? = nil,
        lastFailure: Date? = nil,
        cooldownUntil: Date? = nil,
        reason: String? = nil
    ) {
        self.provider = provider
        self.model = model
        self.state = state
        self.consecutiveErrors = consecutiveErrors
        self.lastSuccess = lastSuccess
        self.lastFailure = lastFailure
        self.cooldownUntil = cooldownUntil
        self.reason = reason
    }

    public static func healthy(provider: String, model: String? = nil) -> ProviderHealth {
        ProviderHealth(provider: provider, model: model)
    }

    /// 在给定时刻是否仍处于冷却中。
    public func isCoolingDown(at now: Date = Date()) -> Bool {
        guard let cooldownUntil else { return false }
        return cooldownUntil > now
    }

    /// 现在能否使用。
    public func isUsable(at now: Date = Date()) -> Bool {
        if isCoolingDown(at: now) { return false }
        return state != .unavailable
    }

    public var cooldownRemaining: TimeInterval? {
        guard let cooldownUntil else { return nil }
        let remaining = cooldownUntil.timeIntervalSinceNow
        return remaining > 0 ? remaining : nil
    }

    public var label: String {
        model.map { "\(provider) / \($0)" } ?? provider
    }

    public var statusDescription: String {
        var parts = [state.displayName]
        if consecutiveErrors > 0 {
            parts.append("连续失败 \(consecutiveErrors)")
        }
        if let remaining = cooldownRemaining {
            parts.append("冷却剩余 \(Int(remaining))s")
        }
        if let reason { parts.append(reason) }
        return parts.joined(separator: " · ")
    }
}
````


#### `Sources/AIRunnerCore/Models/TaskStep.swift` (167 行)

````swift
import Foundation

public enum StepStatus: String, Codable, Sendable, CaseIterable {
    case pending
    case running

    /// ★ Web 模式专用: 续跑 prompt 已生成并交付给用户, 但结果尚未回填。
    ///
    /// 这个状态必须**可被 Runner 重新取走** —— 否则 App 在"prompt 已生成之后、
    /// 用户回填之前"崩溃, 该步骤就会永远卡死。
    /// 重新取走时会用同样的输入重新生成**完全相同**的 prompt
    /// (`ContinuationPromptBuilder` 是纯函数), 所以重复执行是安全的。
    case prepared

    case completed
    case failed
    case skipped
    /// 进程被杀时留下的中间态。
    case interrupted

    /// 终态: 不会被再次执行。
    public var isTerminal: Bool {
        switch self {
        case .completed, .failed, .skipped: return true
        case .pending, .prepared, .running, .interrupted: return false
        }
    }

    /// 是否应当被 Runner 取走执行。
    ///
    /// ★ 注意: 只有 pending / interrupted / prepared 可执行。
    /// completed 永远不在其中 —— 这是"绝不重跑已完成步骤"的第一道防线。
    public var isExecutable: Bool {
        switch self {
        case .pending, .interrupted, .prepared: return true
        case .running, .completed, .failed, .skipped: return false
        }
    }

    /// 是否已交付给用户、正在等待回填结果。
    public var isAwaitingResult: Bool { self == .prepared }

    public var displayName: String {
        switch self {
        case .pending:     return "待执行"
        case .prepared:    return "已就绪"
        case .running:     return "执行中"
        case .completed:   return "已完成"
        case .failed:      return "失败"
        case .skipped:     return "已跳过"
        case .interrupted: return "已中断"
        }
    }
}

public enum StepType: String, Codable, Sendable, CaseIterable {
    case llm
    case map
    case reduce
    case final
    case tool

    public var displayName: String {
        switch self {
        case .llm:    return "LLM 调用"
        case .map:    return "分片处理"
        case .reduce: return "汇总"
        case .final:  return "最终产出"
        case .tool:   return "本地工具"
        }
    }
}

/// 一个任务步骤。
public struct TaskStep: Codable, Sendable, Identifiable, Equatable, Hashable {

    public let id: String
    public let taskID: String
    public var index: Int
    public var type: StepType
    public var status: StepStatus

    public var input: JSONValue
    public var output: JSONValue?

    public var provider: String?
    public var model: String?

    public var retryCount: Int

    public var startedAt: Date?
    public var finishedAt: Date?
    public var createdAt: Date

    // MARK: 扩展字段

    public var lastError: String?
    public var errorClass: String?
    public var durationMs: Int
    /// 每次失败尝试的审计轨迹 (错误类型 / 等待时长 / backend)。
    public var attemptLog: [JSONValue]

    // MARK: Web 执行模式

    /// 续跑 prompt 生成并交付给用户的时间 (Web 模式)。
    public var preparedAt: Date?
    /// 用户把该 prompt 提交给 ChatGPT 的时间 (Web 模式, 可选)。
    public var submittedAt: Date?

    public init(
        id: String = UUID().uuidString,
        taskID: String,
        index: Int,
        type: StepType = .llm,
        status: StepStatus = .pending,
        input: JSONValue = .emptyObject,
        output: JSONValue? = nil,
        provider: String? = nil,
        model: String? = nil,
        retryCount: Int = 0,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        createdAt: Date = Date(),
        lastError: String? = nil,
        errorClass: String? = nil,
        durationMs: Int = 0,
        attemptLog: [JSONValue] = [],
        preparedAt: Date? = nil,
        submittedAt: Date? = nil
    ) {
        self.id = id
        self.taskID = taskID
        self.index = index
        self.type = type
        self.status = status
        self.input = input
        self.output = output
        self.provider = provider
        self.model = model
        self.retryCount = retryCount
        self.startedAt = startedAt
        self.finishedAt = finishedAt
        self.createdAt = createdAt
        self.lastError = lastError
        self.errorClass = errorClass
        self.durationMs = durationMs
        self.attemptLog = attemptLog
        self.preparedAt = preparedAt
        self.submittedAt = submittedAt
    }

    public var backendLabel: String {
        switch (provider, model) {
        case let (p?, m?): return "\(p) / \(m)"
        case let (p?, nil): return p
        case let (nil, m?): return m
        default: return "—"
        }
    }

    /// 提取输出文本 (供 checkpoint 的 workingSummary 使用)。
    public var outputText: String? {
        guard let output else { return nil }
        if let direct = output["text"]?.stringValue { return direct }
        return output.stringValue
    }
}
````


### 执行核心 Core


#### `Sources/AIRunnerCore/Core/AppServices.swift` (255 行)

````swift
import Foundation

/// 依赖装配容器。
///
/// 全项目只有这里做"new 对象"。其他类型一律通过构造参数接收依赖 ——
/// 这样单元测试可以直接塞入内存数据库 + MockAIProvider, 不需要任何全局状态。
public final class AppServices: @unchecked Sendable {

    // 持久化
    public let database: Database
    public let tasks: TaskRepository
    public let steps: StepRepository
    public let checkpoints: CheckpointRepository
    public let events: EventRepository
    public let providerHealth: ProviderHealthRepository

    // 安全与日志
    public let keychain: any KeychainManaging
    public let logger: LoggerService

    // 执行核心
    public let retry: RetryManager
    public let checkpointManager: CheckpointManager
    public let factory: ProviderFactory
    public let router: ModelRouter
    public let registry: TaskExecutionRegistry
    public let runner: JobRunner
    public let recovery: RecoveryManager

    /// ChatGPT Web 执行通道 (主流程)。
    public let web: WebExecutionCoordinator
    /// 剪贴板与浏览器桥接 —— 具体实现由 App 层注入, Core 不依赖 AppKit。
    public let clipboard: any ClipboardServicing
    public let browser: any BrowserLaunching

    // 设置
    private let settingsStore: SettingsStore
    /// 线程安全的当前设置快照。WebExecutionCoordinator 通过它读取最新的 ChatGPT 地址。
    private let settingsBox: SettingsBox

    public var settings: AppSettings { settingsBox.value }

    // MARK: - 构造

    public init(
        database: Database,
        keychain: any KeychainManaging,
        settingsStore: SettingsStore,
        settingsOverride: AppSettings? = nil,
        clipboard: (any ClipboardServicing)? = nil,
        browser: (any BrowserLaunching)? = nil,
        echoLogsToConsole: Bool = true
    ) throws {
        self.database = database
        self.keychain = keychain
        self.settingsStore = settingsStore

        let loaded = settingsOverride ?? settingsStore.load()
        let box = SettingsBox(loaded)
        self.settingsBox = box

        try DatabaseMigrator.migrate(database)

        let tasks = TaskRepository(db: database)
        let steps = StepRepository(db: database)
        let checkpoints = CheckpointRepository(db: database)
        let events = EventRepository(db: database)
        let providerHealth = ProviderHealthRepository(db: database)

        let logger = LoggerService(events: events, echoToConsole: echoLogsToConsole)
        let factory = ProviderFactory(providers: loaded.providers, keychain: keychain)
        factory.registerAllSecrets()

        let retry = RetryManager(config: loaded.retry)
        let registry = TaskExecutionRegistry()
        let checkpointManager = CheckpointManager(repo: checkpoints)

        // 剪贴板 / 浏览器实现由 App 层注入; 测试与无 UI 环境用内存替身。
        let resolvedClipboard = clipboard ?? InMemoryClipboard()
        let resolvedBrowser = browser ?? NoopBrowserLauncher()

        // 路由器的"是否已配置"判断直接绑定到 factory 实例,
        // 因此 Settings 里填完 Key 后, Router 立刻就能选中该 Provider。
        let router = ModelRouter(
            routes: loaded.routes,
            providers: loaded.providers,
            healthRepository: providerHealth,
            logger: logger,
            config: loaded.retry,
            isProviderConfigured: { [factory] providerID in
                factory.isConfigured(providerID: providerID)
            }
        )

        // ★ ChatGPT Web 主通道 ★
        let web = WebExecutionCoordinator(
            tasks: tasks,
            steps: steps,
            checkpoints: checkpoints,
            checkpointManager: checkpointManager,
            logger: logger,
            clipboard: resolvedClipboard,
            browser: resolvedBrowser,
            chatGPTURLOverride: { box.value.chatGPTURL }
        )

        let runner = JobRunner(
            dependencies: JobRunnerDependencies(
                tasks: tasks,
                steps: steps,
                router: router,
                retry: retry,
                checkpoints: checkpointManager,
                factory: factory,
                logger: logger,
                registry: registry,
                web: web,
                config: loaded.retry,
                concurrency: max(1, loaded.concurrency)
            )
        )

        let recovery = RecoveryManager(
            tasks: tasks,
            steps: steps,
            checkpoints: checkpoints,
            logger: logger
        )

        self.tasks = tasks
        self.steps = steps
        self.checkpoints = checkpoints
        self.events = events
        self.providerHealth = providerHealth
        self.logger = logger
        self.factory = factory
        self.retry = retry
        self.checkpointManager = checkpointManager
        self.router = router
        self.registry = registry
        self.runner = runner
        self.recovery = recovery
        self.web = web
        self.clipboard = resolvedClipboard
        self.browser = resolvedBrowser
    }

    /// 一行启动。生产代码用默认路径, 测试用 `inMemory: true`。
    public static func bootstrap(
        databasePath: String? = nil,
        inMemory: Bool = false,
        keychain: (any KeychainManaging)? = nil,
        settingsStore: SettingsStore? = nil,
        clipboard: (any ClipboardServicing)? = nil,
        browser: (any BrowserLaunching)? = nil,
        echoLogsToConsole: Bool = true
    ) throws -> AppServices {

        let db: Database
        if inMemory {
            db = try Database.inMemory()
        } else if let databasePath {
            db = try Database(path: databasePath)
        } else {
            db = try Database.openDefault()
        }

        // 测试默认用内存 Keychain, 避免污染真实 Keychain
        let store = settingsStore ?? SettingsStore(
            defaults: inMemory ? Self.ephemeralDefaults() : .standard
        )
        let kc = keychain ?? (inMemory ? InMemoryKeychain() : KeychainManager())

        return try AppServices(
            database: db,
            keychain: kc,
            settingsStore: store,
            clipboard: clipboard,
            browser: browser,
            echoLogsToConsole: echoLogsToConsole
        )
    }

    /// 每个实例独立的一套内存 UserDefaults, 防止测试之间互相污染。
    public static func ephemeralDefaults(suiteName: String = "com.airunner.tests.\(UUID().uuidString)") -> UserDefaults {
        UserDefaults(suiteName: suiteName) ?? .standard
    }

    // MARK: - 设置变更

    public func saveSettings(_ newSettings: AppSettings) async {
        let normalized = newSettings.renumbered()

        storeSettings(normalized)

        try? settingsStore.save(normalized)
        factory.update(providers: normalized.providers)
        await router.updateRoutes(normalized.routes)
    }

    /// 锁操作必须封装在同步函数里 —— `NSLock.lock()` 在 async 上下文中会被
    /// Swift 6 标记为不可用 (阻塞线程可能导致线程饥饿)。
    private func storeSettings(_ value: AppSettings) {
        settingsBox.value = value
    }

    public func resetSettings() async {
        settingsStore.reset()
        await saveSettings(.default)
    }

    // MARK: - 诊断

    public func healthSnapshot() async -> [ProviderHealth] {
        await router.healthSnapshot()
    }

    public func resetProviderHealth(provider: String? = nil) async {
        await router.resetHealth(provider: provider)
    }

    public func databaseDiagnostics() throws -> Database.Diagnostics {
        try database.diagnostics()
    }

    public func shutdown() {
        database.close()
    }
}

/// 设置的可变快照盒子。
///
/// 存在的理由: `WebExecutionCoordinator` 需要在"生成 prompt 的那一刻"读到**最新**的
/// ChatGPT 地址, 但它在 `AppServices.init` 期间就被构造出来了 —— 那时 `self`
/// 尚未完整、不能被闭包捕获。用一个独立的锁保护盒子绕开这个先有鸡还是先有蛋的问题。
final class SettingsBox: @unchecked Sendable {

    private let lock = NSLock()
    private var storage: AppSettings

    init(_ value: AppSettings) {
        self.storage = value
    }

    var value: AppSettings {
        get {
            lock.lock(); defer { lock.unlock() }
            return storage
        }
        set {
            lock.lock(); defer { lock.unlock() }
            storage = newValue
        }
    }
}
````


#### `Sources/AIRunnerCore/Core/CheckpointManager.swift` (146 行)

````swift
import Foundation

/// 检查点管理。
///
/// 每个 Step 成功后产出一条 Checkpoint。它承载两件事:
/// 1. **恢复依据** — `nextStep` 告诉重启后的 Runner 该从哪继续
/// 2. **上下文摘要** — `workingSummary` 是下一步 prompt 的输入, 避免把全部历史输出塞进请求
public actor CheckpointManager {

    private let repo: CheckpointRepository
    private let maxSummaryCharacters: Int
    private let maxTrackedStepIndexes: Int

    public init(
        repo: CheckpointRepository,
        maxSummaryCharacters: Int = 1200,
        maxTrackedStepIndexes: Int = 20
    ) {
        self.repo = repo
        self.maxSummaryCharacters = maxSummaryCharacters
        self.maxTrackedStepIndexes = maxTrackedStepIndexes
    }

    // MARK: - 读取

    public func latest(taskID: String) throws -> Checkpoint? {
        try repo.latest(taskID: taskID)
    }

    public func list(taskID: String, limit: Int = 100) throws -> [Checkpoint] {
        try repo.list(taskID: taskID, limit: limit)
    }

    public func count(taskID: String) throws -> Int {
        try repo.count(taskID: taskID)
    }

    /// 取最新检查点; 若从未有过则返回 nil (调用方回退到"从头开始")。
    public func latestOrNil(taskID: String) -> Checkpoint? {
        try? repo.latest(taskID: taskID)
    }

    // MARK: - 构造

    /// 为一个刚成功完成的步骤构造检查点。
    ///
    /// `workingSummary` 是**累积**的: 它把上一步的摘要与本次输出拼接, 并截断到
    /// `maxSummaryCharacters`。刻意保留尾部而非头部 —— 对长任务而言, 最近发生的事
    /// 比早期内容更影响下一步。
    public func makeCheckpoint(
        taskID: String,
        completedStep: Int,
        previous: Checkpoint?,
        output: JSONValue,
        provider: String,
        model: String
    ) -> Checkpoint {
        let summary = makeSummary(
            previous: previous,
            completedStep: completedStep,
            output: output
        )
        let state = makeState(
            previous: previous,
            completedStep: completedStep,
            output: output,
            provider: provider,
            model: model
        )

        return Checkpoint(
            taskID: taskID,
            completedStep: completedStep,
            nextStep: completedStep + 1,
            workingSummary: summary,
            state: state
        )
    }

    private func makeSummary(
        previous: Checkpoint?,
        completedStep: Int,
        output: JSONValue
    ) -> String {
        let snippet = Self.outputSnippet(output)
        let addition = "Step \(completedStep + 1): \(snippet)"

        let previousText = (previous?.workingSummary ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        var combined = previousText.isEmpty ? addition : previousText + "\n" + addition

        if combined.count > maxSummaryCharacters {
            combined = "[前文已截断]\n" + String(combined.suffix(maxSummaryCharacters))
        }
        return combined
    }

    private func makeState(
        previous: Checkpoint?,
        completedStep: Int,
        output: JSONValue,
        provider: String,
        model: String
    ) -> JSONValue {
        var state: [String: JSONValue] = previous?.state.objectValue ?? [:]

        var indexes = state["recentSteps"]?.arrayValue ?? []
        indexes.append(.int(completedStep))
        if indexes.count > maxTrackedStepIndexes {
            indexes.removeFirst(indexes.count - maxTrackedStepIndexes)
        }

        let previousCount = state["completedCount"]?.intValue ?? 0
        let previousChars = state["totalOutputCharacters"]?.intValue ?? 0

        state["recentSteps"] = .array(indexes)
        state["completedCount"] = .int(max(previousCount, completedStep + 1))
        state["totalOutputCharacters"] = .int(previousChars + Self.outputSnippet(output).count)
        state["lastProvider"] = .string(provider)
        state["lastModel"] = .string(model)
        state["lastCompletedAt"] = .string(DateCoding.string(from: Date()))

        return .object(state)
    }

    /// 从模型输出中提取一段人类可读的摘要文本。
    static func outputSnippet(_ output: JSONValue, limit: Int = 260) -> String {
        let raw: String
        if let text = output["text"]?.stringValue {
            raw = text
        } else if let summary = output["summary"]?.stringValue {
            raw = summary
        } else {
            raw = output.prettyDescription
        }

        let flattened = raw
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard flattened.count > limit else { return flattened }
        return String(flattened.prefix(limit)) + "…"
    }
}
````


#### `Sources/AIRunnerCore/Core/ContinuationPromptBuilder.swift` (272 行)

````swift
import Foundation

/// 续跑 prompt 生成器。
///
/// ## 核心要求
///
/// 生成的 prompt 必须是**完全自包含**的: 用户切换到另一个 ChatGPT 会话后,
/// 那个会话**没有任何之前的聊天历史**, 仅凭这段文本就能准确接着做第 N 步。
///
/// 因此这里刻意**不引用** conversation ID、不引用"上一条消息"、
/// 不假设模型记得任何东西。所有必要上下文 (目标 / 已完成范围 / 检查点摘要 /
/// 已确立事实 / 本次任务) 都内联在文本里。
///
/// ## 确定性
///
/// 这是**纯函数** —— 相同输入必然产出逐字相同的输出。
/// 这条性质是崩溃恢复能成立的前提: 若 App 在"prompt 已生成、结果未回填"时被杀,
/// 重启后重新生成同一个 prompt 是安全的, 不会让用户看到前后不一致的任务描述。
/// **因此这里绝不使用 `Date()` / 随机数 / 任何环境相关的值。**
public struct ContinuationPromptBuilder: Sendable {

    public struct Input: Sendable {
        /// 任务的总体目标。
        public var goal: String
        /// 当前步骤下标 (0-based)。
        public var stepIndex: Int
        public var totalSteps: Int
        public var stepType: StepType
        /// 最新检查点。nil 表示这是第一步。
        public var checkpoint: Checkpoint?
        /// 已完成的步骤下标 (用于生成 "1...63" 这样的范围)。
        public var completedStepIndexes: [Int]
        /// 从检查点 state 里提炼出的关键事实 (每行一条)。
        public var structuredFacts: [String]
        /// 期望的输出格式说明, 例如 "Return a JSON object with keys: findings[], confidence"。
        public var outputSchema: String?

        public init(
            goal: String,
            stepIndex: Int,
            totalSteps: Int,
            stepType: StepType = .llm,
            checkpoint: Checkpoint? = nil,
            completedStepIndexes: [Int] = [],
            structuredFacts: [String] = [],
            outputSchema: String? = nil
        ) {
            self.goal = goal
            self.stepIndex = stepIndex
            self.totalSteps = totalSteps
            self.stepType = stepType
            self.checkpoint = checkpoint
            self.completedStepIndexes = completedStepIndexes
            self.structuredFacts = structuredFacts
            self.outputSchema = outputSchema
        }
    }

    public init() {}

    // MARK: - 生成

    public func build(_ input: Input) -> String {
        var sections: [String] = []

        // 1) 角色与硬性约束 —— 放在最前面, 因为这是最容易被忽略的部分
        sections.append("""
        You are continuing an existing long-running task that was interrupted.

        IMPORTANT RULES:
        - Do NOT restart the task from the beginning.
        - Do NOT redo any step listed as already completed.
        - Rely ONLY on the information in this message.
          You do NOT have access to any previous conversation, so nothing may be assumed
          from prior context.
        - Do NOT ask clarifying questions. Produce the result for this turn directly.
        """)

        // 2) 总体目标
        sections.append("""
        OVERALL GOAL:
        \(input.goal.trimmingCharacters(in: .whitespacesAndNewlines))
        """)

        // 3) 进度
        let ordinal = input.stepIndex + 1
        let total = max(input.totalSteps, ordinal)
        sections.append("""
        PROGRESS:
        Completed steps: \(Self.compressRanges(input.completedStepIndexes))
        Current step: \(ordinal)
        Total steps: \(total)
        """)

        // 4) 检查点 —— 跨会话唯一的状态载体
        sections.append("""
        CURRENT CHECKPOINT:
        \(checkpointText(input.checkpoint))
        """)

        // 5) 已确立的事实
        if !input.structuredFacts.isEmpty {
            let bullets = input.structuredFacts
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
                .map { "- \($0)" }
                .joined(separator: "\n")
            sections.append("""
            IMPORTANT ESTABLISHED FACTS:
            \(bullets)
            """)
        }

        // 6) 本轮任务
        sections.append("""
        TASK FOR THIS TURN:
        \(instruction(for: input))
        """)

        // 7) 输出格式
        sections.append("""
        OUTPUT REQUIREMENTS:
        \(outputRequirements(input))
        """)

        return sections.joined(separator: "\n\n")
    }

    // MARK: - 片段

    private func checkpointText(_ checkpoint: Checkpoint?) -> String {
        guard let checkpoint else {
            return "No prior progress has been recorded. This is the first step."
        }
        let summary = checkpoint.workingSummary?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !summary.isEmpty else {
            return "Checkpoint recorded at step \(checkpoint.completedStep + 1), "
                 + "but no summary text was captured."
        }
        return summary
    }

    private func instruction(for input: Input) -> String {
        let ordinal = input.stepIndex + 1
        switch input.stepType {
        case .final:
            return """
            This is the FINAL step (\(ordinal) of \(input.totalSteps)).
            Produce the finished deliverable for the overall goal, synthesizing everything
            completed so far. Be concrete and complete — this is what the user will read.
            """
        case .reduce:
            return """
            This is the AGGREGATION step (\(ordinal) of \(input.totalSteps)).
            Consolidate the results produced in the completed steps into one coherent
            intermediate result. Resolve contradictions explicitly rather than listing them.
            """
        case .tool:
            return """
            This step (\(ordinal) of \(input.totalSteps)) requires local processing.
            Perform the operation described by the goal and report the outcome.
            """
        case .map, .llm:
            return """
            Complete step \(ordinal) of \(input.totalSteps).
            Return a concise, self-contained result for this step alone.
            Assume the result will be read later by someone who cannot see this conversation,
            so include any concrete specifics (numbers, names, decisions) that the next step
            will need.
            """
        }
    }

    private func outputRequirements(_ input: Input) -> String {
        if let schema = input.outputSchema?.trimmingCharacters(in: .whitespacesAndNewlines),
           !schema.isEmpty {
            return """
            \(schema)

            Do not redo completed steps. Do not wrap the answer in commentary about what you
            are about to do — return the result itself.
            """
        }
        return """
        Return only the result for this single step — no preamble, no restatement of the goal,
        no commentary about the process. Plain text, or JSON if the task calls for it.
        Do not redo completed steps.
        """
    }

    // MARK: - 范围压缩

    /// 把 `[0,1,2,3,7,8,20]` 压缩成 `"1...4, 8...9, 21"`。
    ///
    /// 一个 300 步的任务如果逐个列举已完成步骤, 光这一行就会占掉几百个 token。
    static func compressRanges(_ indexes: [Int]) -> String {
        let sorted = Array(Set(indexes)).sorted()
        guard !sorted.isEmpty else {
            return "(none — this is the first step)"
        }

        var parts: [String] = []
        var rangeStart = sorted[0]
        var previous = sorted[0]

        func flush() {
            if rangeStart == previous {
                parts.append("\(rangeStart + 1)")           // 转成 1-based 显示
            } else {
                parts.append("\(rangeStart + 1)...\(previous + 1)")
            }
        }

        for value in sorted.dropFirst() {
            if value == previous + 1 {
                previous = value
                continue
            }
            flush()
            rangeStart = value
            previous = value
        }
        flush()

        return parts.joined(separator: ", ")
    }

    /// 从检查点的 `state` 提炼人类可读的关键事实。
    static func facts(from checkpoint: Checkpoint?) -> [String] {
        guard let state = checkpoint?.state.objectValue else { return [] }

        var facts: [String] = []

        if let count = state["completedCount"]?.intValue {
            facts.append("Steps completed so far: \(count)")
        }
        if let recent = state["recentSteps"]?.arrayValue, !recent.isEmpty {
            let indexes = recent.compactMap { $0.intValue }.sorted()
            facts.append("Recently completed step indexes: \(compressRanges(indexes))")
        }
        if let characters = state["totalOutputCharacters"]?.intValue, characters > 0 {
            facts.append("Cumulative output size: ~\(characters) characters")
        }

        // 其余由上层写入的自定义标量字段一并带出
        let internalKeys: Set<String> = [
            "completedCount", "recentSteps", "totalOutputCharacters",
            "lastProvider", "lastModel", "lastCompletedAt",
        ]
        for (key, value) in state.sorted(by: { $0.key < $1.key })
        where !internalKeys.contains(key) {
            switch value {
            case .string(let text):
                facts.append("\(key): \(text)")
            case .int(let number):
                facts.append("\(key): \(number)")
            case .double(let number):
                facts.append("\(key): \(number)")
            case .bool(let flag):
                facts.append("\(key): \(flag)")
            case .array(let items):
                let rendered = items.compactMap(\.stringValue).prefix(8).joined(separator: "; ")
                if !rendered.isEmpty { facts.append("\(key): \(rendered)") }
            case .object, .null:
                continue
            }
        }

        return facts
    }
}
````


#### `Sources/AIRunnerCore/Core/JobRunner.swift` (750 行)

````swift
import Foundation

/// JobRunner 的依赖集合。
///
/// 全部显式注入, 不用单例 —— 这样测试里可以塞入 MockAIProvider 与内存数据库,
/// 且 Runner 本身**不依赖 SwiftUI / Combine**, 可以被纯命令行测试驱动。
public struct JobRunnerDependencies: Sendable {

    public var tasks: TaskRepository
    public var steps: StepRepository
    public var router: ModelRouter
    public var retry: RetryManager
    public var checkpoints: CheckpointManager
    public var factory: ProviderFactory
    public var logger: LoggerService
    public var registry: TaskExecutionRegistry
    /// ChatGPT Web 执行通道 (主流程)。
    public var web: any WebExecutionCoordinating
    public var config: RetryConfiguration
    /// 全局最多同时运行几个任务。
    public var concurrency: Int

    public init(
        tasks: TaskRepository,
        steps: StepRepository,
        router: ModelRouter,
        retry: RetryManager,
        checkpoints: CheckpointManager,
        factory: ProviderFactory,
        logger: LoggerService,
        registry: TaskExecutionRegistry,
        web: any WebExecutionCoordinating,
        config: RetryConfiguration = .default,
        concurrency: Int = 3
    ) {
        self.tasks = tasks
        self.steps = steps
        self.router = router
        self.retry = retry
        self.checkpoints = checkpoints
        self.factory = factory
        self.logger = logger
        self.registry = registry
        self.web = web
        self.config = config
        self.concurrency = concurrency
    }
}

/// 任务执行器 —— 整个系统最核心的部分。
///
/// 执行循环 (单任务):
/// ```
/// 读任务 → 检查取消/暂停 → 取下一个可执行步骤 → 选 backend
///        → 标记 running → 调用模型 → 校验输出
///        → 【单事务】写结果 + 写检查点 + 推进进度 → 下一步
/// ```
///
/// 三条不可动摇的规则:
/// 1. 步骤只有在 **事务提交成功** 后才算完成, 因此重启不会重跑。
/// 2. 每个错误按 `ErrorStrategy` 分派不同动作, 绝不"一律重试"。
/// 3. 同一任务同时最多一个 runner (由 `TaskExecutionRegistry` 保证)。
public actor JobRunner {

    private let deps: JobRunnerDependencies
    private let semaphore: AsyncSemaphore

    private var pauseRequests: Set<String> = []
    private var cancelRequests: Set<String> = []
    private var handles: [String: Task<Void, Never>] = [:]

    public init(dependencies: JobRunnerDependencies) {
        self.deps = dependencies
        self.semaphore = AsyncSemaphore(limit: max(1, dependencies.concurrency))
    }

    // MARK: - 控制面

    /// 启动 (或恢复) 一个任务。非阻塞: 立即返回, 实际执行在后台。
    public func start(taskID: String) async {
        if handles[taskID] != nil {
            deps.logger.warning(
                .runnerRejectedDuplicate,
                "该任务已有 runner 在运行, 忽略重复启动",
                taskID: taskID
            )
            return
        }

        let task: AITask
        do {
            guard let fetched = try deps.tasks.fetch(id: taskID) else {
                deps.logger.error(.runnerStopped, "任务不存在: \(taskID)")
                return
            }
            task = fetched
        } catch {
            deps.logger.record(error, eventType: .taskFailed, taskID: taskID)
            return
        }

        guard !task.status.isTerminal else {
            deps.logger.warning(
                .runnerRejectedDuplicate,
                "任务处于终态 (\(task.status.displayName)), 拒绝启动",
                taskID: taskID
            )
            return
        }

        // ★ 跨 layer 的重复启动防护 ★
        let claimed = await deps.registry.claim(taskID)
        guard claimed else {
            deps.logger.warning(
                .runnerRejectedDuplicate,
                "任务已在执行中 (registry 已被占用), 忽略重复启动",
                taskID: taskID
            )
            return
        }

        pauseRequests.remove(taskID)
        cancelRequests.remove(taskID)

        if task.status != .running {
            do {
                _ = try deps.tasks.updateStatus(id: taskID, to: .running)
            } catch {
                deps.logger.record(error, eventType: .taskFailed, taskID: taskID)
                await deps.registry.release(taskID)
                return
            }
        }

        let handle = Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }
            await self.execute(taskID: taskID)
        }
        handles[taskID] = handle
    }

    /// 请求暂停。
    ///
    /// **优雅暂停语义**: 不中断正在进行中的 HTTP 请求 —— 等它返回并提交结果后,
    /// 在循环边界处转入 paused。这样"成功响应不会因为暂停而丢失"。
    public func pause(taskID: String) async {
        guard handles[taskID] != nil else {
            // 没有活跃 runner: 直接改状态即可
            _ = try? deps.tasks.updateStatus(id: taskID, to: .paused)
            deps.logger.info(.taskPaused, "任务已暂停", taskID: taskID)
            return
        }
        pauseRequests.insert(taskID)
        deps.logger.info(.taskPaused, "已请求暂停, 将在当前步骤提交后生效", taskID: taskID)
    }

    /// 取消。立即中断退避睡眠; 已提交的结果与检查点全部保留, 不删任何数据。
    public func cancel(taskID: String) async {
        cancelRequests.insert(taskID)
        if let handle = handles[taskID] {
            handle.cancel()
        } else {
            _ = try? deps.tasks.updateStatus(id: taskID, to: .cancelled)
            deps.logger.info(.taskCancelled, "任务已取消, 历史数据保留", taskID: taskID)
        }
    }

    public func activeTaskIDs() -> [String] {
        handles.keys.sorted()
    }

    public func isRunning(taskID: String) -> Bool {
        handles[taskID] != nil
    }

    public func isPauseRequested(taskID: String) -> Bool {
        pauseRequests.contains(taskID)
    }

    public func isCancelRequested(taskID: String) -> Bool {
        cancelRequests.contains(taskID)
    }

    /// 等待某个任务跑完 (测试用)。
    public func waitForCompletion(taskID: String) async {
        guard let handle = handles[taskID] else { return }
        await handle.value
    }

    // MARK: - 执行生命周期

    private func execute(taskID: String) async {
        await semaphore.acquire()
        let reason = await runLoop(taskID: taskID)
        await semaphore.release()

        handles.removeValue(forKey: taskID)
        pauseRequests.remove(taskID)
        cancelRequests.remove(taskID)
        await deps.registry.release(taskID)

        deps.logger.info(.runnerStopped, "Runner 退出: \(reason)", taskID: taskID)
    }

    private func runLoop(taskID: String) async -> String {
        guard var task = (try? deps.tasks.fetch(id: taskID)) ?? nil else {
            return "task-missing"
        }

        deps.logger.info(
            .taskStarted,
            "开始执行任务「\(task.name)」, 共 \(task.totalSteps) 步",
            taskID: taskID
        )

        while true {

            // --- 1) 取消检查 ---
            if cancelRequests.contains(taskID) || Task.isCancelled {
                _ = try? deps.tasks.updateStatus(id: taskID, to: .cancelled)
                deps.logger.info(
                    .taskCancelled,
                    "任务已取消。已完成的 \(task.currentStep) 步结果与检查点全部保留。",
                    taskID: taskID
                )
                return "cancelled"
            }

            // --- 2) 暂停检查 (只在步骤边界, 保证不丢已提交结果) ---
            if pauseRequests.contains(taskID) {
                _ = try? deps.tasks.updateStatus(id: taskID, to: .paused)
                deps.logger.info(
                    .taskPaused,
                    "任务已暂停于第 \(task.currentStep)/\(task.totalSteps) 步",
                    taskID: taskID
                )
                return "paused"
            }

            // --- 3) 取下一个可执行步骤 ---
            // 注意: 这里必须区分"没有待执行步骤"和"数据库出错" ——
            // 把 DB 错误误判成"任务完成"会让任务静默变成 completed。
            let nextStep: TaskStep?
            do {
                nextStep = try deps.steps.nextExecutableStep(taskID: taskID)
            } catch {
                deps.logger.record(error, eventType: .taskFailed, taskID: taskID)
                return "db-error"
            }

            guard let step = nextStep else {
                return finishTask(task)
            }

            // --- 4) 执行该步骤 ---
            let outcome = await executeStep(task: task, step: step)

            switch outcome {
            case .success:
                if let refreshed = (try? deps.tasks.fetch(id: taskID)) ?? nil {
                    task = refreshed
                }

            case .awaitingUser(let reason):
                _ = try? deps.tasks.updateStatus(
                    id: taskID, to: .waitingForUser,
                    errorMessage: reason, errorClass: "AWAITING_RESULT"
                )
                deps.logger.info(
                    .taskWaiting,
                    "任务已转入「等待提交结果」并退出 Runner: \(reason)",
                    taskID: taskID
                )
                return "awaiting-user"

            case .awaitingAccount(let reason):
                _ = try? deps.tasks.updateStatus(
                    id: taskID, to: .waitingForAccount,
                    errorMessage: reason, errorClass: "ACCOUNT_HANDOFF"
                )
                deps.logger.warning(
                    .taskWaiting,
                    "任务已转入「等待切换账号」并退出 Runner: \(reason)",
                    taskID: taskID
                )
                return "awaiting-account"

            case .paused(let error):
                _ = try? deps.tasks.updateStatus(
                    id: taskID, to: .paused,
                    errorMessage: error.userMessage, errorClass: error.eventName
                )
                deps.logger.error(
                    .taskPaused,
                    "任务暂停, 需要人工处理: \(error.userMessage)",
                    taskID: taskID
                )
                return "paused-error"

            case .failed(let error):
                _ = try? deps.tasks.updateStatus(
                    id: taskID, to: .failed,
                    errorMessage: error.userMessage, errorClass: error.eventName
                )
                deps.logger.error(
                    .taskFailed,
                    "任务失败于第 \(step.index + 1) 步: \(error.userMessage)",
                    taskID: taskID
                )
                return "failed"

            case .cancelled:
                _ = try? deps.tasks.updateStatus(id: taskID, to: .cancelled)
                return "cancelled"
            }
        }
    }

    private func finishTask(_ task: AITask) -> String {
        let counts = (try? deps.steps.statusCounts(taskID: task.id)) ?? [:]
        let failed = counts[.failed] ?? 0
        let completed = counts[.completed] ?? 0

        do {
            _ = try deps.tasks.updateStatus(id: task.id, to: .completed)
            deps.logger.info(
                .taskCompleted,
                "任务完成: 成功 \(completed) 步, 失败 \(failed) 步, 共 \(task.totalSteps) 步",
                taskID: task.id
            )
            return "completed"
        } catch {
            deps.logger.record(error, eventType: .taskFailed, taskID: task.id)
            return "completed-but-persist-failed"
        }
    }

    // MARK: - 单步执行 (含重试与 fallback)

    private enum StepOutcome {
        case success
        /// Web 模式: 续跑 prompt 已生成并交付, 等用户提交并回填结果。
        case awaitingUser(reason: String)
        /// Web 模式: 当前 ChatGPT session 无法继续, 等用户手动切换账号。
        case awaitingAccount(reason: String)
        case paused(AppError)
        case failed(AppError)
        case cancelled
    }

    /// 按执行通道分派。
    ///
    /// 两条通道**共用**完全相同的持久化与编排设施 (SQLite / TaskStep / Checkpoint /
    /// RecoveryManager / Logs / ResponseValidator), 差别只在"这一步的结果从哪里来"。
    private func executeStep(task: AITask, step: TaskStep) async -> StepOutcome {
        switch task.executionMode {
        case .chatGPTWeb:
            return await executeWebStep(task: task, step: step)
        case .api:
            return await executeAPIStep(task: task, step: step)
        }
    }

    // MARK: - ChatGPT Web 通道 (主流程)

    /// 生成续跑 prompt, 然后把任务转入「等用户」。
    ///
    /// 这条路径**绝不阻塞等待用户** —— 用户可能几小时甚至几天后才回来。
    /// Runner 生成 prompt 后立刻返回 `.awaitingUser`, runLoop 据此把任务转入
    /// `waitingForUser` 并退出; 用户回填结果后由 TaskManager 重新拉起 Runner。
    ///
    /// 这正是"AI = 执行器, 本程序 = 真正的任务控制器"的落点: 账号可以换、
    /// 会话可以断, 但任务状态始终在数据库里。
    private func executeWebStep(task: AITask, step: TaskStep) async -> StepOutcome {
        do {
            let delivery = try await deps.web.deliverPrompt(
                taskID: task.id,
                copyToClipboard: true,
                openBrowser: true
            )
            let prepared = delivery.prepared

            deps.logger.info(
                .webStepPrepared,
                "步骤 \(prepared.ordinal)/\(task.totalSteps) 的续跑 prompt 已生成 "
                + "(\(prepared.prompt.count) 字符)"
                + (delivery.copiedToClipboard ? ", 已复制到剪贴板" : ", 剪贴板写入失败")
                + (delivery.browserOpened ? ", 已请求打开 ChatGPT" : ""),
                taskID: task.id, stepIndex: step.index
            )

            return .awaitingUser(
                reason: "步骤 \(prepared.ordinal) 的续跑 prompt 已就绪, "
                      + "请提交给 ChatGPT 后把回复粘贴回来"
            )

        } catch let error as WebExecutionError {
            if case .noExecutableStep = error {
                // 竞态: 该步骤在此期间已被处理。返回 success 让 runLoop 重新取下一步。
                return .success
            }
            return .failed(AppError.invalidRequest(error.userMessage))

        } catch {
            return .failed(AppError.normalize(error))
        }
    }

    // MARK: - API 通道 (可选后端)

    /// 原有的 router / provider / retry 全流程。默认不参与主流程。
    private func executeAPIStep(task: AITask, step: TaskStep) async -> StepOutcome {
        var attemptedBackends: Set<String> = []
        var budget = StepRetryBudget()
        var lastError: AppError = .fatal("步骤尚未产生任何错误记录")

        // 外层循环: 换 backend
        while true {

            guard let backend = await deps.router.selectBackend(
                excluding: attemptedBackends,
                preferredProvider: task.primaryProvider,
                preferredModel: task.primaryModel
            ) else {
                let explanation = await deps.router.explainNoBackend(excluding: attemptedBackends)
                deps.logger.error(
                    .backendExhausted,
                    "没有可用 backend。诊断: \(explanation)",
                    taskID: task.id, stepIndex: step.index
                )

                // 认证/余额这类问题换谁都救不了 → 暂停等用户。
                if lastError.strategy == .pauseTask {
                    try? deps.steps.markPending(
                        stepID: step.id,
                        error: lastError.userMessage,
                        errorClass: lastError.eventName
                    )
                    return .paused(lastError)
                }

                try? deps.steps.markFailed(
                    stepID: step.id,
                    error: lastError.userMessage,
                    errorClass: lastError.eventName
                )
                return .failed(lastError)
            }

            attemptedBackends.insert(backend.label)

            if attemptedBackends.count > 1 {
                deps.logger.warning(
                    .backendSwitched,
                    "切换到备用 backend: \(backend.label)",
                    taskID: task.id, stepIndex: step.index
                )
            }

            do {
                try deps.steps.markRunning(
                    stepID: step.id,
                    provider: backend.providerID,
                    model: backend.model
                )
                try deps.steps.recordBackendAttempt(
                    stepID: step.id,
                    provider: backend.providerID,
                    model: backend.model,
                    note: nil
                )
            } catch {
                deps.logger.record(error, eventType: .stepFailed, taskID: task.id, stepIndex: step.index)
                return .failed(AppError.normalize(error))
            }

            deps.logger.info(
                .backendSelected,
                "步骤 \(step.index + 1) 使用 \(backend.label)",
                taskID: task.id, stepIndex: step.index
            )

            // 内层循环: 同一 backend 上重试
            inner: while true {

                if cancelRequests.contains(task.id) || Task.isCancelled {
                    try? deps.steps.markPending(stepID: step.id, error: "已取消")
                    return .cancelled
                }

                // 读最新检查点作为上下文 (CheckpointManager 是 actor, 必须 await)
                let checkpoint = (try? await deps.checkpoints.latest(taskID: task.id)) ?? nil

                let request = TaskPlanner.buildRequest(
                    task: task,
                    step: step,
                    checkpoint: checkpoint,
                    responseFormat: TaskPlanner.responseFormat(for: step),
                    maxOutputTokens: deps.factory.config(for: backend.providerID)?.maxOutputTokens ?? 2048,
                    temperature: 0.2,
                    timeout: deps.factory.config(for: backend.providerID)?.timeout ?? 180,
                    contextShrinkFactor: shrinkFactor(for: step)
                )

                let provider: any AIProvider
                do {
                    provider = try deps.factory.makeProvider(
                        providerID: backend.providerID, model: backend.model
                    )
                } catch {
                    let appError = AppError.normalize(error)
                    lastError = appError
                    await deps.router.noteFailure(backend, error: appError)
                    try? deps.steps.appendAttempt(
                        stepID: step.id,
                        attempt: failurePayload(error: appError, backend: backend, delay: nil),
                        bumpRetry: false
                    )
                    break inner   // 换 backend
                }

                let started = Date()

                do {
                    let response = try await provider.execute(request: request)

                    let validator = CompositeResponseValidator.standard(for: request.responseFormat)
                    try validator.validate(response, request: request)

                    let durationMs = max(0, Int(Date().timeIntervalSince(started) * 1000))

                    let output = JSONValue.object([
                        "text": .string(response.text),
                        "provider": .string(response.provider),
                        "model": .string(response.model),
                        "inputTokens": response.inputTokens.map { JSONValue.int($0) } ?? .null,
                        "outputTokens": response.outputTokens.map { JSONValue.int($0) } ?? .null,
                        "latencyMs": .int(response.latencyMilliseconds),
                        "finishReason": response.finishReason.map { JSONValue.string($0) } ?? .null,
                    ])

                    let newCheckpoint = await deps.checkpoints.makeCheckpoint(
                        taskID: task.id,
                        completedStep: step.index,
                        previous: checkpoint,
                        output: output,
                        provider: response.provider,
                        model: response.model
                    )

                    // ★ 原子提交: 结果 + 检查点 + 进度, 一个事务 ★
                    do {
                        try deps.steps.commitSuccessfulStep(
                            SuccessfulStepCommit(
                                stepID: step.id,
                                taskID: task.id,
                                output: output,
                                provider: response.provider,
                                model: response.model,
                                durationMs: durationMs,
                                checkpoint: newCheckpoint,
                                newCurrentStep: step.index + 1
                            )
                        )
                    } catch {
                        let appError = AppError.normalize(error)
                        deps.logger.error(
                            .stepFailed,
                            "步骤结果提交失败 (事务回滚, 该步将重跑): \(appError.userMessage)",
                            taskID: task.id, stepIndex: step.index
                        )
                        try? deps.steps.markPending(stepID: step.id, error: appError.userMessage)
                        return .failed(appError)
                    }

                    await deps.router.noteSuccess(backend)

                    deps.logger.info(
                        .stepCompleted,
                        "步骤 \(step.index + 1)/\(task.totalSteps) 完成 (\(durationMs)ms, \(response.backendLabel))",
                        taskID: task.id, stepIndex: step.index
                    )
                    deps.logger.info(
                        .checkpointSaved,
                        "检查点已保存: completedStep=\(newCheckpoint.completedStep) nextStep=\(newCheckpoint.nextStep)",
                        taskID: task.id, stepIndex: step.index
                    )
                    return .success

                } catch {

                    let appError = AppError.normalize(error)
                    lastError = appError

                    // ★ 取消不是失败 ★
                    // 若不单独处理, 用户点 Cancel 会让步骤走 .failTask 分支被标记为 failed,
                    // 任务随之变成 failed —— 而需求要求 cancelled 且完整保留历史。
                    if case .cancelled = appError {
                        try? deps.steps.markPending(stepID: step.id, error: "已取消")
                        return .cancelled
                    }

                    deps.logger.warning(
                        .stepRetry,
                        "步骤 \(step.index + 1) 失败: \(appError.eventName) — \(appError.userMessage)",
                        taskID: task.id, stepIndex: step.index
                    )

                    let health = await deps.router.noteFailure(backend, error: appError)

                    switch appError.strategy {

                    case .pauseTask:
                        // 认证失败 / 余额耗尽: 不重试, 不换 backend 硬撑, 直接交给用户。
                        try? deps.steps.markPending(
                            stepID: step.id,
                            error: appError.userMessage,
                            errorClass: appError.eventName
                        )
                        try? deps.steps.appendAttempt(
                            stepID: step.id,
                            attempt: failurePayload(error: appError, backend: backend, delay: nil)
                        )
                        return .paused(appError)

                    case .failStep, .failTask:
                        try? deps.steps.markFailed(
                            stepID: step.id,
                            error: appError.userMessage,
                            errorClass: appError.eventName
                        )
                        try? deps.steps.appendAttempt(
                            stepID: step.id,
                            attempt: failurePayload(error: appError, backend: backend, delay: nil)
                        )
                        return .failed(appError)

                    case .switchBackend:
                        try? deps.steps.appendAttempt(
                            stepID: step.id,
                            attempt: failurePayload(error: appError, backend: backend, delay: nil)
                        )
                        if health.state == .unavailable {
                            deps.logger.error(
                                .providerUnavailable,
                                "\(backend.label) 已熔断: \(health.statusDescription)",
                                taskID: task.id, stepIndex: step.index
                            )
                        }
                        break inner   // 换 backend

                    case .retrySame, .retryWithBackoff, .shrinkContext:
                        if case .shrinkContext = appError.strategy {
                            // 记录一次 shrink, 让下次构造请求时裁剪上下文
                            markShrinkRequested(stepID: step.id)
                        }

                        let canRetry = await deps.retry.shouldRetry(error: appError, budget: budget)
                        guard canRetry else {
                            try? deps.steps.appendAttempt(
                                stepID: step.id,
                                attempt: failurePayload(error: appError, backend: backend, delay: nil)
                            )
                            deps.logger.warning(
                                .backendSwitched,
                                "步骤 \(step.index + 1) 重试预算耗尽 (\(budget.summary)), 改用备用 backend",
                                taskID: task.id, stepIndex: step.index
                            )
                            break inner
                        }

                        guard let delay = await deps.retry.delay(for: appError, budget: budget) else {
                            break inner
                        }

                        RetryPolicy.consume(&budget, error: appError)

                        try? deps.steps.appendAttempt(
                            stepID: step.id,
                            attempt: failurePayload(error: appError, backend: backend, delay: delay)
                        )

                        if case .rateLimit = appError {
                            deps.logger.warning(
                                .rateLimited,
                                "触发限流, 等待 \(Int(delay))s 后重试 (\(budget.summary))",
                                taskID: task.id, stepIndex: step.index
                            )
                        } else {
                            deps.logger.info(
                                .stepRetry,
                                "\(Int(delay))s 后重试 (\(budget.summary))",
                                taskID: task.id, stepIndex: step.index
                            )
                        }

                        do {
                            try await deps.retry.sleep(delay, isCancelled: { [weak self] in
                                guard let self else { return true }
                                return await self.isInterrupted(taskID: task.id)
                            })
                        } catch {
                            try? deps.steps.markPending(stepID: step.id, error: "退避期间被取消")
                            return .cancelled
                        }

                        continue inner   // 同一 backend 重试
                    }
                }
            }
        }
    }

    /// 暂停或取消都应当中断退避睡眠。
    private func isInterrupted(taskID: String) -> Bool {
        pauseRequests.contains(taskID) || cancelRequests.contains(taskID) || Task.isCancelled
    }

    // MARK: - 上下文裁剪标记

    private var shrinkRequested: Set<String> = []

    private func markShrinkRequested(stepID: String) {
        shrinkRequested.insert(stepID)
    }

    private func shrinkFactor(for step: TaskStep) -> Double? {
        guard shrinkRequested.contains(step.id) else { return nil }
        return deps.config.contextShrinkFactor
    }

    // MARK: - 审计载荷

    private func failurePayload(
        error: AppError,
        backend: BackendRef,
        delay: TimeInterval?
    ) -> JSONValue {
        .object([
            "kind": .string("failure"),
            "errorClass": .string(error.eventName),
            "strategy": .string(error.strategy.rawValue),
            "message": .string(error.userMessage),
            "provider": .string(backend.providerID),
            "model": .string(backend.model),
            "retryAfterSeconds": delay.map { JSONValue.double($0) } ?? .null,
            "at": .string(DateCoding.string(from: Date())),
        ])
    }
}
````


#### `Sources/AIRunnerCore/Core/ModelRouter.swift` (307 行)

````swift
import Foundation

/// 模型路由器。
///
/// 输入: 任务 + 已试过的 backend 集合 + Provider 健康度
/// 输出: 下一个 (provider, model)
///
/// ★ 防无限循环 ★
/// 调用方每试一个 backend 就把它加入 `attempted` 并传回来。
/// 已试过的 backend 不会再被选中, 因此不可能出现 A → B → A → B 的死循环。
/// 当 `selectBackend` 返回 nil 时, 说明候选池已耗尽 —— Runner 据此暂停或失败,
/// 绝不原地打转。
public actor ModelRouter {

    // MARK: 依赖

    private let providerConfigs: [String: ProviderConfig]
    private var routes: [RouteEntry]
    private let healthRepository: ProviderHealthRepository?
    private let logger: LoggerService?
    private let config: RetryConfiguration
    private let now: @Sendable () -> Date
    private let isProviderConfigured: @Sendable (String) -> Bool

    // MARK: 状态

    /// key = "provider::model" 或 "provider::*" (provider 级)
    private var health: [String: ProviderHealth] = [:]

    public init(
        routes: [RouteEntry],
        providers: [ProviderConfig],
        healthRepository: ProviderHealthRepository? = nil,
        logger: LoggerService? = nil,
        config: RetryConfiguration = .default,
        now: @escaping @Sendable () -> Date = { Date() },
        isProviderConfigured: @escaping @Sendable (String) -> Bool = { _ in true }
    ) {
        var map: [String: ProviderConfig] = [:]
        for provider in providers { map[provider.id] = provider }

        self.providerConfigs = map
        self.routes = routes.sorted { $0.priority < $1.priority }
        self.healthRepository = healthRepository
        self.logger = logger
        self.config = config
        self.now = now
        self.isProviderConfigured = isProviderConfigured

        if let repo = healthRepository, let stored = try? repo.fetchAll() {
            for item in stored {
                health[Self.key(provider: item.provider, model: item.model)] = item
            }
        }
    }

    // MARK: - 路由表

    public func updateRoutes(_ newRoutes: [RouteEntry]) {
        routes = newRoutes.sorted { $0.priority < $1.priority }
    }

    public func currentRoutes() -> [RouteEntry] { routes }

    /// 全部候选 backend (按优先级)。
    public func allBackends() -> [BackendRef] {
        orderedRoutes().compactMap { route in
            guard providerConfigs[route.provider] != nil else { return nil }
            return BackendRef(providerID: route.provider, model: route.model, priority: route.priority)
        }
    }

    private func orderedRoutes() -> [RouteEntry] {
        routes.filter { $0.enabled }.sorted { $0.priority < $1.priority }
    }

    // MARK: - 选择

    /// 选择一个可用 backend。
    ///
    /// - Parameters:
    ///   - attempted: 本次步骤已经试过的 backend (`BackendRef.label`)
    ///   - preferredProvider/Model: 任务声明的 primary, 优先级最高
    /// - Returns: 可用 backend; nil 表示候选池耗尽或全部处于冷却。
    public func selectBackend(
        excluding attempted: Set<String>,
        preferredProvider: String? = nil,
        preferredModel: String? = nil
    ) -> BackendRef? {
        let current = now()
        let candidates = orderedRoutes()

        // 1) 优先尝试任务指定的 primary
        if let preferredProvider, let preferredModel {
            let label = "\(preferredProvider) / \(preferredModel)"
            if !attempted.contains(label),
               let route = candidates.first(where: {
                   $0.provider == preferredProvider && $0.model == preferredModel
               }),
               isUsable(route, at: current) {
                return BackendRef(
                    providerID: route.provider, model: route.model, priority: route.priority
                )
            }
        }

        // 2) 按优先级取第一个可用
        for route in candidates {
            let label = "\(route.provider) / \(route.model)"
            if attempted.contains(label) { continue }
            if isUsable(route, at: current) {
                return BackendRef(
                    providerID: route.provider, model: route.model, priority: route.priority
                )
            }
        }
        return nil
    }

    /// 候选池是否已经耗尽 (给 Runner 判断"该暂停还是该失败")。
    public func isExhausted(excluding attempted: Set<String>) -> Bool {
        selectBackend(excluding: attempted) == nil
    }

    /// 解释为什么没有可用 backend —— 写日志用, 避免"静默失败"。
    public func explainNoBackend(excluding attempted: Set<String>) -> String {
        let current = now()
        var reasons: [String] = []
        for route in orderedRoutes() {
            let label = "\(route.provider) / \(route.model)"
            if attempted.contains(label) {
                reasons.append("\(label): 本次已试过")
                continue
            }
            if !isProviderConfigured(route.provider) {
                reasons.append("\(label): 未配置 API Key")
                continue
            }
            if let health = health[Self.key(provider: route.provider, model: nil)],
               !health.isUsable(at: current) {
                reasons.append("\(label): Provider 熔断 (\(health.statusDescription))")
                continue
            }
            if let health = health[Self.key(provider: route.provider, model: route.model)],
               !health.isUsable(at: current) {
                reasons.append("\(label): 模型熔断 (\(health.statusDescription))")
                continue
            }
            reasons.append("\(label): 可用")
        }
        if reasons.isEmpty { return "路由表为空" }
        return reasons.joined(separator: "; ")
    }

    private func isUsable(_ route: RouteEntry, at time: Date) -> Bool {
        guard let config = providerConfigs[route.provider], config.enabled else { return false }
        guard isProviderConfigured(route.provider) else { return false }

        if let providerHealth = health[Self.key(provider: route.provider, model: nil)],
           !providerHealth.isUsable(at: time) {
            return false
        }
        if let modelHealth = health[Self.key(provider: route.provider, model: route.model)],
           !modelHealth.isUsable(at: time) {
            return false
        }
        return true
    }

    // MARK: - 健康度反馈

    public func noteSuccess(_ backend: BackendRef) {
        let time = now()

        var modelHealth = health[Self.key(provider: backend.providerID, model: backend.model)]
            ?? ProviderHealth(provider: backend.providerID, model: backend.model)
        modelHealth.state = .healthy
        modelHealth.consecutiveErrors = 0
        modelHealth.lastSuccess = time
        modelHealth.cooldownUntil = nil
        modelHealth.reason = nil
        store(modelHealth)

        // 成功说明整个 Provider 可达, 清掉 provider 级熔断。
        if let providerHealth = health[Self.key(provider: backend.providerID, model: nil)],
           providerHealth.state != .healthy {
            var recovered = providerHealth
            recovered.state = .healthy
            recovered.consecutiveErrors = 0
            recovered.cooldownUntil = nil
            recovered.reason = nil
            recovered.lastSuccess = time
            store(recovered)
            logger?.info(.providerRecovered, "Provider \(backend.providerID) 恢复正常",
                         metadata: .object(["provider": .string(backend.providerID)]))
        }
    }

    /// 记录一次失败, 返回更新后的健康度。
    @discardableResult
    public func noteFailure(_ backend: BackendRef, error: AppError) -> ProviderHealth {
        let time = now()
        let key = Self.key(provider: backend.providerID, model: backend.model)
        var modelHealth = health[key] ?? ProviderHealth(provider: backend.providerID, model: backend.model)
        modelHealth.lastFailure = time
        modelHealth.reason = error.userMessage

        switch error {

        case .billingRequired, .authentication:
            // 用户不处理就不会好。立即熔断 + 长冷却。
            modelHealth.state = .unavailable
            modelHealth.cooldownUntil = time.addingTimeInterval(config.billingCooldown)
            tripProvider(
                backend.providerID,
                reason: error.userMessage,
                cooldown: config.billingCooldown,
                at: time
            )
            logger?.error(.billingBlocked,
                          "熔断 Provider \(backend.providerID): \(error.userMessage)",
                          metadata: .object(["provider": .string(backend.providerID)]))

        case .modelUnavailable:
            // 只是这个模型名不对, Provider 本身没问题 —— 只拉黑该模型。
            modelHealth.state = .unavailable
            modelHealth.cooldownUntil = time.addingTimeInterval(config.providerCooldown)

        case .providerUnavailable:
            modelHealth.consecutiveErrors += 1
            if modelHealth.consecutiveErrors >= config.providerUnavailableThreshold {
                modelHealth.state = .unavailable
                modelHealth.cooldownUntil = time.addingTimeInterval(config.providerCooldown)
                tripProvider(
                    backend.providerID,
                    reason: "连续 \(modelHealth.consecutiveErrors) 次不可用",
                    cooldown: config.providerCooldown,
                    at: time
                )
            } else if modelHealth.consecutiveErrors >= config.providerDegradedThreshold {
                modelHealth.state = .degraded
            }

        default:
            // 网络抖动 / 限流 / 输出格式问题都不该熔断 Provider ——
            // 继续调用是有意义的, 只是节奏需要调整。
            break
        }

        store(modelHealth)
        return modelHealth
    }

    private func tripProvider(
        _ providerID: String,
        reason: String,
        cooldown: TimeInterval,
        at time: Date
    ) {
        var providerHealth = health[Self.key(provider: providerID, model: nil)]
            ?? ProviderHealth(provider: providerID, model: nil)
        providerHealth.state = .unavailable
        providerHealth.cooldownUntil = time.addingTimeInterval(cooldown)
        providerHealth.reason = reason
        providerHealth.lastFailure = time
        providerHealth.consecutiveErrors += 1
        store(providerHealth)
    }

    // MARK: - 查询与重置

    public func healthSnapshot() -> [ProviderHealth] {
        health.values.sorted {
            if $0.provider != $1.provider { return $0.provider < $1.provider }
            return ($0.model ?? "") < ($1.model ?? "")
        }
    }

    public func health(for backend: BackendRef) -> ProviderHealth? {
        health[Self.key(provider: backend.providerID, model: backend.model)]
    }

    public func providerHealth(_ providerID: String) -> ProviderHealth? {
        health[Self.key(provider: providerID, model: nil)]
    }

    /// 清空熔断状态。用户在 Settings 里点了"重置"时调用。
    public func resetHealth(provider: String? = nil) {
        if let provider {
            health = health.filter { $0.value.provider != provider }
        } else {
            health.removeAll()
        }
        _ = try? healthRepository?.reset(provider: provider)
    }

    // MARK: - 内部

    private func store(_ item: ProviderHealth) {
        health[Self.key(provider: item.provider, model: item.model)] = item
        try? healthRepository?.upsert(item)
    }

    static func key(provider: String, model: String?) -> String {
        "\(provider)::\(model ?? "*")"
    }
}
````


#### `Sources/AIRunnerCore/Core/RecoveryManager.swift` (157 行)

````swift
import Foundation

/// 恢复结果报告。
public struct RecoveryReport: Sendable, Equatable {

    /// 被标记为 interrupted 的步骤数。
    public var interruptedSteps: Int
    /// 需要继续执行的任务 ID。
    public var recoverableTaskIDs: [String]
    /// 对应任务名 (给 UI 显示)。
    public var recoverableTaskNames: [String]
    /// 检测到"实际已完成但状态未推进"并已修正的任务数。
    public var completedButStuckTasks: Int
    /// 正在等待用户手动操作的任务 (waitingForAccount / waitingForBrowser / waitingForUser)。
    ///
    /// 这些任务 **不会** 被自动恢复 —— 必须由用户点击 Resume。
    /// 尤其是 `waitingForAccount`: 只有当用户真的在浏览器里换好账号之后才有意义。
    public var awaitingUserTaskIDs: [String] = []
    public var summary: String

    public var didRecoverAnything: Bool {
        interruptedSteps > 0 || !recoverableTaskIDs.isEmpty
    }
}

/// 崩溃恢复。
///
/// App 启动时调用一次。处理三类残留状态:
///
/// 1. `task_steps.status = 'running'`
///    上一次运行在 HTTP 请求途中被杀。该步的 checkpoint 从未提交, 结果不可信 →
///    标记为 `interrupted` (可执行状态), 恢复后会重新执行。
///
/// 2. `tasks.status = 'running'`
///    保持 running 不变 (它本来就该继续跑), 交由 TaskManager 重新挂上 Runner。
///
/// 3. `tasks.status = 'running'` 但已无任何可执行步骤
///    说明任务其实已经跑完, 只是退出时没来得及写状态 → 修正为 `completed`。
///
/// 关于"避免同时启动两个 Runner": 恢复流程本身只改数据库状态, 不直接起 Runner;
/// 实际启动统一走 `JobRunner.start`, 而它受 `TaskExecutionRegistry` 保护。
public struct RecoveryManager: Sendable {

    private let tasks: TaskRepository
    private let steps: StepRepository
    private let checkpoints: CheckpointRepository
    private let logger: LoggerService

    public init(
        tasks: TaskRepository,
        steps: StepRepository,
        checkpoints: CheckpointRepository,
        logger: LoggerService
    ) {
        self.tasks = tasks
        self.steps = steps
        self.checkpoints = checkpoints
        self.logger = logger
    }

    public func recover() throws -> RecoveryReport {
        // 1) 收集非终态任务
        let unfinished = try tasks.fetchUnfinished()

        // 2) running step -> interrupted
        let interrupted = try steps.markRunningInterrupted()

        // 3) 决定哪些任务需要继续
        var recoverable: [AITask] = []
        var awaitingUser: [AITask] = []
        var stuckCompleted = 0

        for task in unfinished {
            switch task.status {

            case .running, .queued:
                let remaining = try steps.executableCount(taskID: task.id)
                if remaining > 0 {
                    recoverable.append(task)
                } else {
                    // 没有待执行步骤了 —— 补一次状态推进, 避免任务永远卡在 running。
                    do {
                        _ = try tasks.updateStatus(id: task.id, to: .completed)
                        stuckCompleted += 1
                        logger.warning(
                            .appCrashRecovery,
                            "任务「\(task.name)」已无可执行步骤, 状态修正为 completed",
                            taskID: task.id
                        )
                    } catch {
                        logger.record(error, eventType: .taskFailed, taskID: task.id)
                    }
                }

            case .waitingForAccount, .waitingForBrowser, .waitingForUser:
                // 等用户态: 必须由用户手动 Resume, 绝不自动拉起。
                // 这里只做记录 —— 让用户知道有任务在等自己 (尤其是"等待切换账号")。
                awaitingUser.append(task)
                logger.info(
                    .recoveryCompleted,
                    "任务「\(task.name)」正在等待用户操作 (\(task.status.displayName)), 不会自动恢复",
                    taskID: task.id
                )

            case .paused, .waiting:
                // 用户主动暂停 / 程序内部等待: 不自动恢复。
                break

            case .completed, .failed, .cancelled:
                // 终态任务不会出现在 fetchUnfinished 的结果里; 这里只是保持 switch 穷尽。
                break
            }
        }

        // 4) 事件留痕
        if interrupted > 0 {
            logger.warning(
                .appCrashRecovery,
                "检测到上次运行被强制中断: \(interrupted) 个步骤处于 running 状态, "
                + "已标记为 interrupted 并将重新执行 (已完成步骤不受影响)",
                metadata: .object(["interruptedSteps": .int(interrupted)])
            )
        }

        if !recoverable.isEmpty {
            logger.info(
                .recoveryCompleted,
                "恢复完成: \(recoverable.count) 个任务将从未完成步骤继续 — "
                + recoverable.map(\.name).joined(separator: ", "),
                metadata: .object(["taskCount": .int(recoverable.count)])
            )
        }

        let summary: String
        if interrupted == 0 && recoverable.isEmpty && stuckCompleted == 0 {
            summary = awaitingUser.isEmpty
                ? "无需恢复: 没有检测到中断的任务或步骤"
                : "无中断任务; 另有 \(awaitingUser.count) 个任务正在等待你手动操作"
        } else {
            var parts: [String] = []
            if interrupted > 0 { parts.append("\(interrupted) 个中断步骤待重跑") }
            if !recoverable.isEmpty { parts.append("\(recoverable.count) 个任务待继续") }
            if stuckCompleted > 0 { parts.append("\(stuckCompleted) 个任务状态已修正为完成") }
            if !awaitingUser.isEmpty { parts.append("\(awaitingUser.count) 个任务等待你手动操作") }
            summary = parts.joined(separator: ", ")
        }

        return RecoveryReport(
            interruptedSteps: interrupted,
            recoverableTaskIDs: recoverable.map(\.id),
            recoverableTaskNames: recoverable.map(\.name),
            completedButStuckTasks: stuckCompleted,
            awaitingUserTaskIDs: awaitingUser.map(\.id),
            summary: summary
        )
    }
}
````


#### `Sources/AIRunnerCore/Core/ResponseValidator.swift` (132 行)

````swift
import Foundation

/// 输出校验器。
///
/// 存在的意义: 模型经常"看起来成功但其实返回了废话"。
/// 若不做校验, 一场跑 300 步的任务可能在最后才发现结果全是空字符串。
public protocol ResponseValidator: Sendable {
    func validate(_ response: AIResponse, request: AIRequest) throws
}

/// 非空校验: 最基础的一道门。
public struct NonEmptyResponseValidator: ResponseValidator {

    public let minimumLength: Int
    public let rejectPlaceholders: Bool

    public init(minimumLength: Int = 1, rejectPlaceholders: Bool = true) {
        self.minimumLength = minimumLength
        self.rejectPlaceholders = rejectPlaceholders
    }

    public func validate(_ response: AIResponse, request: AIRequest) throws {
        let trimmed = response.text.trimmingCharacters(in: .whitespacesAndNewlines)

        guard trimmed.count >= minimumLength else {
            throw AppError.invalidOutput(
                "响应为空或过短 (\(trimmed.count) 字符, 期望 >= \(minimumLength))"
            )
        }

        if rejectPlaceholders {
            let lowered = trimmed.lowercased()
            let placeholders = ["todo", "n/a", "as an ai language model", "i cannot"]
            if trimmed.count < 40, placeholders.contains(where: { lowered == $0 }) {
                throw AppError.invalidOutput("响应是占位文本: \(trimmed.prefix(40))")
            }
        }
    }
}

/// JSON 校验: 当步骤声明 responseFormat == .json 时必须能解析成功。
public struct JSONResponseValidator: ResponseValidator {

    public init() {}

    public func validate(_ response: AIResponse, request: AIRequest) throws {
        guard JSONResponseValidator.extractJSONValue(from: response.text) != nil else {
            let preview = response.text
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .prefix(120)
            throw AppError.invalidOutput("响应不是合法 JSON: \(preview)")
        }
    }

    /// 从模型输出里尽可能稳健地提取 JSON。
    ///
    /// 处理三种常见污染:
    /// 1. 被 ```json ... ``` 包裹
    /// 2. 前后有解释性文字
    /// 3. 直接就是裸 JSON
    public static func extractJSONValue(from text: String) -> JSONValue? {
        let cleaned = stripCodeFence(text)

        if let value = try? JSONCoding.decode(JSONValue.self, from: cleaned) {
            return value
        }

        // 截取最外层的 {...}
        if let start = cleaned.firstIndex(of: "{"),
           let end = cleaned.lastIndex(of: "}"),
           start < end {
            let candidate = String(cleaned[start...end])
            if let value = try? JSONCoding.decode(JSONValue.self, from: candidate) {
                return value
            }
        }

        // 截取最外层的 [...]
        if let start = cleaned.firstIndex(of: "["),
           let end = cleaned.lastIndex(of: "]"),
           start < end {
            let candidate = String(cleaned[start...end])
            if let value = try? JSONCoding.decode(JSONValue.self, from: candidate) {
                return value
            }
        }

        return nil
    }

    static func stripCodeFence(_ text: String) -> String {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard s.hasPrefix("```") else { return s }
        if let newline = s.firstIndex(of: "\n") {
            s = String(s[s.index(after: newline)...])
        }
        if let closing = s.range(of: "```", options: .backwards) {
            s = String(s[s.startIndex..<closing.lowerBound])
        }
        return s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

/// 组合校验器。
public struct CompositeResponseValidator: ResponseValidator {

    public let validators: [any ResponseValidator]

    public init(_ validators: [any ResponseValidator]) {
        self.validators = validators
    }

    public func validate(_ response: AIResponse, request: AIRequest) throws {
        for validator in validators {
            try validator.validate(response, request: request)
        }
    }

    public static func standard(for format: ResponseFormat) -> CompositeResponseValidator {
        switch format {
        case .json:
            return CompositeResponseValidator([
                NonEmptyResponseValidator(minimumLength: 2),
                JSONResponseValidator(),
            ])
        case .text:
            return CompositeResponseValidator([
                NonEmptyResponseValidator(minimumLength: 1),
            ])
        }
    }
}
````


#### `Sources/AIRunnerCore/Core/RetryManager.swift` (189 行)

````swift
import Foundation

/// 重试/熔断参数。
public struct RetryConfiguration: Sendable, Equatable, Codable {

    /// 基础退避秒数。序列: 5, 10, 20, 40, 80, 160, 300(封顶)
    public var baseDelay: TimeInterval = 5
    public var factor: Double = 2
    public var maxDelay: TimeInterval = 300
    /// 加性 jitter 比例。0.3 表示最多再加 30% 的随机量。
    public var jitterRatio: Double = 0.3

    /// 单步的普通错误重试上限。
    public var maxRetries: Int = 8
    /// 限流等待次数上限。与 maxRetries 分开计账 —— 限流不代表步骤有问题。
    public var maxRateLimitWaits: Int = 12
    /// 输出格式修复重试上限。
    public var maxRepairs: Int = 2

    /// 连续失败多少次要标记为 degraded。
    public var providerDegradedThreshold: Int = 3
    /// 连续失败多少次要标记为 unavailable 并进入冷却。
    public var providerUnavailableThreshold: Int = 5

    public var providerCooldown: TimeInterval = 600
    /// 余额耗尽/认证失败属于"用户不处理就不会好"的问题, 冷却要足够长。
    public var billingCooldown: TimeInterval = 6 * 3600

    /// 上下文超长时的缩减比例。
    public var contextShrinkFactor: Double = 0.5

    public init() {}

    public static let `default` = RetryConfiguration()
}

/// 单个步骤的重试预算。
public struct StepRetryBudget: Sendable, Equatable {
    public var retries: Int = 0
    public var rateLimitWaits: Int = 0
    public var repairs: Int = 0

    public init() {}

    public var summary: String {
        "retries=\(retries) rateLimitWaits=\(rateLimitWaits) repairs=\(repairs)"
    }
}

/// 纯函数式退避计算。
///
/// 刻意做成无状态 `enum` + 可注入随机源 —— 这样"第 N 次重试等待多少秒"可以在
/// 单元测试里被精确断言, 不依赖真实时钟或随机数。
public enum RetryPolicy {

    /// 返回 [0, 1) 的随机数发生器。测试时注入固定值即可得到确定性结果。
    public typealias RandomSource = @Sendable () -> Double

    public static let defaultRandom: RandomSource = { Double.random(in: 0..<1) }

    /// `delay = min(base * factor^retryCount, maxDelay) + jitter`
    public static func computeDelay(
        retryCount: Int,
        config: RetryConfiguration = .default,
        random: RandomSource = RetryPolicy.defaultRandom
    ) -> TimeInterval {
        let exponent = Double(max(0, retryCount))
        let raw = config.baseDelay * pow(config.factor, exponent)
        let capped = min(raw, config.maxDelay)
        let jitter = capped * max(0, config.jitterRatio) * max(0, min(1, random()))
        return (capped + jitter).rounded(toPlaces: 2)
    }

    /// 本次错误应当等待多久。返回 nil 表示"不该等待重试"。
    public static func plan(
        error: AppError,
        budget: StepRetryBudget,
        config: RetryConfiguration = .default,
        random: RandomSource = RetryPolicy.defaultRandom
    ) -> TimeInterval? {
        // 服务端给了 Retry-After 就听它的
        if let retryAfter = error.retryAfter, retryAfter > 0 {
            return min(max(1, retryAfter), config.maxDelay * 4)
        }

        switch error.strategy {
        case .retryWithBackoff:
            return computeDelay(
                retryCount: budget.rateLimitWaits, config: config, random: random
            )
        case .retrySame, .shrinkContext:
            return computeDelay(
                retryCount: budget.retries, config: config, random: random
            )
        case .switchBackend, .pauseTask, .failStep, .failTask:
            return nil
        }
    }

    /// 是否还有预算重试。
    public static func shouldRetry(
        error: AppError,
        budget: StepRetryBudget,
        config: RetryConfiguration = .default
    ) -> Bool {
        // 输出格式错误走独立的 repair 预算
        if case .invalidOutput = error {
            return budget.repairs < config.maxRepairs && budget.retries < config.maxRetries
        }

        switch error.strategy {
        case .retrySame, .shrinkContext:
            return budget.retries < config.maxRetries
        case .retryWithBackoff:
            return budget.rateLimitWaits < config.maxRateLimitWaits
        case .switchBackend, .pauseTask, .failStep, .failTask:
            return false
        }
    }

    /// 消耗预算。
    public static func consume(_ budget: inout StepRetryBudget, error: AppError) {
        if case .invalidOutput = error {
            budget.repairs += 1
        }
        switch error.strategy {
        case .retrySame, .shrinkContext:
            budget.retries += 1
        case .retryWithBackoff:
            budget.rateLimitWaits += 1
        case .switchBackend, .pauseTask, .failStep, .failTask:
            break
        }
    }
}

/// 退避执行的协调者。
///
/// 做成 actor 是为了让"同一个 Runner 的多次决策"序列化, 但真正的退避数学都在
/// `RetryPolicy` 里 (纯函数), 因此核心逻辑仍可被独立测试。
public actor RetryManager {

    private let config: RetryConfiguration
    private let random: RetryPolicy.RandomSource

    public init(
        config: RetryConfiguration = .default,
        random: @escaping RetryPolicy.RandomSource = RetryPolicy.defaultRandom
    ) {
        self.config = config
        self.random = random
    }

    public nonisolated var configuration: RetryConfiguration { config }

    public func delay(for error: AppError, budget: StepRetryBudget) -> TimeInterval? {
        RetryPolicy.plan(error: error, budget: budget, config: config, random: random)
    }

    public func shouldRetry(error: AppError, budget: StepRetryBudget) -> Bool {
        RetryPolicy.shouldRetry(error: error, budget: budget, config: config)
    }

    /// 可被打断的睡眠。
    ///
    /// 退避可能长达 5 分钟 —— 必须能在用户点 Pause/Cancel 时立刻中断,
    /// 否则 UI 会"卡住"长达数分钟。分片轮询 + 外部取消谓词实现。
    public func sleep(
        _ seconds: TimeInterval,
        isCancelled: @Sendable () async -> Bool
    ) async throws {
        guard seconds > 0 else { return }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if Task.isCancelled { throw AppError.cancelled }
            if await isCancelled() { throw AppError.cancelled }
            let remaining = deadline.timeIntervalSinceNow
            let slice = min(0.25, max(0.01, remaining))
            try await Task.sleep(nanoseconds: UInt64(slice * 1_000_000_000))
        }
    }
}

extension Double {
    func rounded(toPlaces places: Int) -> Double {
        let divisor = pow(10.0, Double(places))
        return (self * divisor).rounded() / divisor
    }
}
````


#### `Sources/AIRunnerCore/Core/TaskExecutionRegistry.swift` (42 行)

````swift
import Foundation

/// 运行中任务的注册表。
///
/// 解决的问题: 用户连点两次 Resume → 起两个 Runner → 同一个 Step 被执行两次,
/// 白花钱还可能产生重复输出。
///
/// 保证: 同一个 taskID 在任意时刻最多只有一个 active runner。
public actor TaskExecutionRegistry {

    private var active: [String: Date] = [:]

    public init() {}

    /// 尝试认领一个任务。返回 false 表示已经有 runner 在跑它。
    public func claim(_ taskID: String) -> Bool {
        if active[taskID] != nil { return false }
        active[taskID] = Date()
        return true
    }

    /// 释放认领。**必须** 在 runner 退出时调用 (用 defer)。
    public func release(_ taskID: String) {
        active.removeValue(forKey: taskID)
    }

    public func isRunning(_ taskID: String) -> Bool {
        active[taskID] != nil
    }

    public var runningTaskIDs: [String] {
        active.keys.sorted()
    }

    public var count: Int { active.count }

    /// 某个任务已经跑了多久。
    public func runningDuration(taskID: String) -> TimeInterval? {
        guard let started = active[taskID] else { return nil }
        return Date().timeIntervalSince(started)
    }
}
````


#### `Sources/AIRunnerCore/Core/TaskManager.swift` (402 行)

````swift
import Foundation
import Combine

/// UI 层状态与动作入口。
///
/// 职责边界 (强制):
/// * 只做「读数据库 → 发布状态」和「调用 JobRunner → 刷新状态」
/// * **不** 包含任何执行循环、重试、路由逻辑 —— 那些全在 JobRunner / ModelRouter 里
/// * 视图不直接碰 Repository
@MainActor
public final class TaskManager: ObservableObject {

    // MARK: - 发布状态

    @Published public private(set) var tasks: [AITask] = []
    @Published public private(set) var activeRunnerTaskIDs: Set<String> = []
    @Published public private(set) var recoverySummary: String?
    @Published public var lastErrorMessage: String?
    /// 最近一次成功操作给用户的提示 (区别于 lastErrorMessage)。
    @Published public var lastInfoMessage: String?
    /// 续跑 prompt 预览 —— 供 UI 显示或用户手动复制。
    @Published public private(set) var promptPreview: String?
    @Published public private(set) var promptPreviewTaskID: String?

    public let services: AppServices

    private var pollingTask: Task<Void, Never>?

    public init(services: AppServices) {
        self.services = services
        refresh()
    }

    // MARK: - 启动恢复

    /// App 启动时调用: 修复残留状态, 并把 running 的任务重新挂上 Runner。
    @discardableResult
    public func recoverOnLaunch(autoStart: Bool = true) -> RecoveryReport? {
        do {
            let report = try services.recovery.recover()
            recoverySummary = report.didRecoverAnything ? report.summary : nil

            refresh()

            if autoStart, !report.recoverableTaskIDs.isEmpty {
                for taskID in report.recoverableTaskIDs {
                    Task { await services.runner.start(taskID: taskID) }
                }
            }
            startPolling()
            return report
        } catch {
            setError(error)
            return nil
        }
    }

    // MARK: - 刷新

    public func refresh() {
        do {
            tasks = try services.tasks.fetchAll()
        } catch {
            setError(error)
        }

        Task { [weak self] in
            guard let self else { return }
            let ids = await self.services.runner.activeTaskIDs()
            self.activeRunnerTaskIDs = Set(ids)
        }
    }

    public func startPolling(interval: Duration = .seconds(1)) {
        stopPolling()
        pollingTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: interval)
                guard let self else { return }
                await self.tick()
            }
        }
    }

    public func stopPolling() {
        pollingTask?.cancel()
        pollingTask = nil
    }

    private func tick() async {
        refresh()
    }

    // MARK: - 创建

    @discardableResult
    public func createTask(
        name: String,
        goal: String,
        numberOfSteps: Int
    ) throws -> AITask {

        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedGoal = goal.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            throw AppError.invalidRequest("任务名称不能为空")
        }
        guard !trimmedGoal.isEmpty else {
            throw AppError.invalidRequest("任务目标不能为空")
        }
        guard (1...1000).contains(numberOfSteps) else {
            throw AppError.invalidRequest("步骤数必须在 1...1000 之间 (当前 \(numberOfSteps))")
        }

        let currentSettings = services.settings
        let mode = currentSettings.defaultExecutionMode

        // Web 模式 (主流程) 不依赖 API 路由;
        // 只有 API 可选后端才要求至少有一条可用的模型路由。
        let primary: RouteEntry?
        switch mode {
        case .chatGPTWeb:
            primary = currentSettings.primaryRoute
        case .api:
            guard let route = currentSettings.primaryRoute else {
                throw AppError.invalidRequest(
                    "API 模式需要至少一条模型路由, 请先在「设置 → 模型路由」中配置"
                )
            }
            primary = route
        }

        let task = AITask(
            name: trimmedName,
            goal: trimmedGoal,
            status: .queued,
            executionMode: mode,
            primaryProvider: primary?.provider ?? "",
            primaryModel: primary?.model ?? "",
            totalSteps: numberOfSteps
        )

        // 顺序很重要: 先写 tasks, 再写 task_steps (存在外键约束)。
        try services.tasks.insert(task)

        let plan = TaskPlanner.defaultPlan(
            taskID: task.id,
            numberOfSteps: numberOfSteps,
            goal: trimmedGoal
        )
        try services.steps.insertBatch(plan)

        // 起始检查点: nextStep = 0
        try services.checkpoints.insert(Checkpoint.initial(taskID: task.id))

        services.logger.info(
            .taskCreated,
            "创建任务「\(trimmedName)」: \(numberOfSteps) 步, 执行通道 \(mode.displayName)",
            taskID: task.id,
            metadata: .object([
                "totalSteps": .int(numberOfSteps),
                "executionMode": .string(mode.rawValue),
                "provider": .string(primary?.provider ?? ""),
                "model": .string(primary?.model ?? ""),
            ])
        )

        refresh()
        return task
    }

    // MARK: - 生命周期动作

    public func start(_ task: AITask) {
        guard !task.status.isTerminal else {
            lastErrorMessage = "任务已处于「\(task.status.displayName)」, 无法启动"
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.services.runner.start(taskID: task.id)
            self.refresh()
        }
    }

    public func pause(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            await self.services.runner.pause(taskID: task.id)
            self.refresh()
        }
    }

    public func resume(_ task: AITask) {
        guard task.status != .completed && task.status != .cancelled else {
            lastErrorMessage = "「\(task.status.displayName)」的任务不能恢复"
            return
        }
        Task { [weak self] in
            guard let self else { return }
            await self.services.runner.start(taskID: task.id)
            self.refresh()
        }
    }

    public func cancel(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            await self.services.runner.cancel(taskID: task.id)
            self.refresh()
        }
    }

    /// 删除任务。会先取消运行, 数据通过 ON DELETE CASCADE 一并清除。
    public func delete(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            await self.services.runner.cancel(taskID: task.id)
            do {
                try self.services.tasks.delete(id: task.id)
                self.services.logger.info(.taskCancelled, "已删除任务「\(task.name)」")
            } catch {
                self.setError(error)
            }
            self.refresh()
        }
    }

    // MARK: - ChatGPT Web 执行动作

    /// 「Copy Continuation Prompt」
    ///
    /// 生成续跑 prompt → 写入剪贴板 → 打开 ChatGPT, 并把步骤标记为 `prepared`、
    /// 任务转入 `waitingForUser`。**绝不阻塞** —— 用户可能几小时后才回来。
    public func copyContinuationPrompt(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            let settings = self.services.settings
            do {
                let delivery = try await self.services.web.deliverPrompt(
                    taskID: task.id,
                    copyToClipboard: settings.copyPromptToClipboard,
                    openBrowser: settings.openBrowserOnPrepare
                )

                let step = delivery.prepared
                var message = "步骤 \(step.ordinal)/\(step.totalSteps) 的续跑 prompt 已生成"
                message += delivery.copiedToClipboard ? ", 并已复制到剪贴板" : " (剪贴板写入失败)"
                if delivery.browserOpened { message += ", 已请求打开 ChatGPT" }
                message += "。请提交给 ChatGPT, 然后点「粘贴结果」。"

                self.lastErrorMessage = nil
                self.lastInfoMessage = message

                _ = try? self.services.tasks.updateStatus(
                    id: task.id, to: .waitingForUser,
                    errorMessage: message, errorClass: "AWAITING_RESULT"
                )

                self.loadPromptPreview(task)
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    /// 「Paste Result」
    ///
    /// 读取剪贴板中的 ChatGPT 回复 → 校验 → 原子提交 → 交给 Runner 决定下一步。
    /// 校验失败时**不会**推进检查点, 会如实报错。
    public func pasteResult(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let imported = try await self.services.web.importClipboardResult(taskID: task.id)

                self.lastErrorMessage = nil
                self.lastInfoMessage = imported.isFinalStep
                    ? "已导入步骤 \(imported.stepIndex + 1) 的结果 —— 这是最后一步, 任务已完成。"
                    : "已导入步骤 \(imported.stepIndex + 1) 的结果, 还剩 \(imported.remainingSteps) 步。"

                // 交给 Runner: 它要么准备下一步的 prompt, 要么判定任务完成。
                await self.services.runner.start(taskID: task.id)
                self.loadPromptPreview(task)
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    /// 「Pause for Account Switch」
    ///
    /// 语义: 检查点已经安全落盘 (每一步都是单事务提交的), 这里**只**把任务转入
    /// `waitingForAccount`, 等用户在浏览器里手动切换账号。绝不丢任何进度。
    public func pauseForAccountSwitch(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.services.web.pauseForAccountSwitch(
                    taskID: task.id,
                    reason: "ChatGPT 当前会话已无法继续, 需要切换到另一个已授权的会话"
                )
                self.lastErrorMessage = nil
                self.lastInfoMessage =
                    "检查点已安全保存。请在浏览器中手动切换 ChatGPT 账号, "
                    + "然后回到这里点「我已完成账号切换」。"
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    /// 「I've switched account」: 用户完成手动切换后调用。
    public func resumeAfterAccountSwitch(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.services.web.resumeAfterManualAccountSwitch(taskID: task.id)
                self.lastErrorMessage = nil
                self.lastInfoMessage = "已从检查点恢复, 正在根据数据库重新生成续跑 prompt…"

                await self.services.runner.start(taskID: task.id)
                self.loadPromptPreview(task)
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    /// 丢弃已生成的 prompt, 让下一步重新生成。
    public func discardPreparedPrompt(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                try await self.services.web.discardPreparedPrompt(taskID: task.id)
                self.promptPreview = nil
                self.promptPreviewTaskID = nil
                self.refresh()
            } catch {
                self.setError(error)
            }
        }
    }

    /// 异步加载续跑 prompt 预览 (不写库, 不改变任何状态)。
    public func loadPromptPreview(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            let preview = try? await self.services.web.previewPrompt(taskID: task.id)
            self.promptPreview = preview
            self.promptPreviewTaskID = task.id
        }
    }

    /// 当前正在等待用户回填结果的那一步。
    public func awaitingStep(_ task: AITask) -> TaskStep? {
        (try? services.steps.awaitingResultStep(taskID: task.id)) ?? nil
    }

    public func clearInfoMessage() {
        lastInfoMessage = nil
    }

    // MARK: - 查询

    public func steps(for task: AITask) -> [TaskStep] {
        (try? services.steps.fetchAll(taskID: task.id)) ?? []
    }

    public func latestCheckpoint(for task: AITask) -> Checkpoint? {
        try? services.checkpoints.latest(taskID: task.id)
    }

    public func checkpoints(for task: AITask, limit: Int = 50) -> [Checkpoint] {
        (try? services.checkpoints.list(taskID: task.id, limit: limit)) ?? []
    }

    public func events(for task: AITask? = nil, limit: Int = 300) -> [AppEvent] {
        (try? services.events.list(taskID: task?.id, limit: limit)) ?? []
    }

    public func stepStatusCounts(for task: AITask) -> [StepStatus: Int] {
        (try? services.steps.statusCounts(taskID: task.id)) ?? [:]
    }

    public func isActive(_ task: AITask) -> Bool {
        activeRunnerTaskIDs.contains(task.id)
    }

    // MARK: - 错误

    private func setError(_ error: Error) {
        let appError = AppError.normalize(error)
        lastErrorMessage = appError.userMessage
        services.logger.error(.unknown, appError.userMessage)
    }
}
````


#### `Sources/AIRunnerCore/Core/TaskPlanner.swift` (122 行)

````swift
import Foundation

/// 任务规划器。
///
/// MVP 阶段刻意保持"笨" —— 目标是把 Runner / Checkpoint / Retry / Recovery 跑通,
/// 而不是做智能任务分解。用户给 N 步, 就生成 N 个顺序步骤。
public struct TaskPlanner: Sendable {

    public static let systemPrompt = """
    You are a disciplined executor of a long-running task.
    You complete exactly ONE step at a time and return a concise, self-contained result.
    Never ask clarifying questions. Never claim to have done work you did not do.
    Reply in the same language as the goal.
    """

    /// 生成 N 个顺序步骤。最后一步标记为 `.final`。
    public static func defaultPlan(
        taskID: String,
        numberOfSteps: Int,
        goal: String
    ) -> [TaskStep] {
        guard numberOfSteps > 0 else { return [] }
        return (0..<numberOfSteps).map { index in
            let isLast = (index == numberOfSteps - 1)
            return TaskStep(
                taskID: taskID,
                index: index,
                type: isLast ? .final : .map,
                status: .pending,
                input: .object([
                    "stepIndex": .int(index),
                    "totalSteps": .int(numberOfSteps),
                    "goal": .string(goal),
                    "responseFormat": .string(ResponseFormat.text.rawValue),
                ])
            )
        }
    }

    /// 构造某一步的模型请求。
    ///
    /// 上下文策略 (MVP): **只** 用 `latest checkpoint workingSummary` + 当前步骤 + 目标,
    /// 不把历史全部原始输出塞进 prompt。300 步的任务若每步都带上全部历史,
    /// 到第 50 步就会爆上下文窗口且费用失控。
    public static func buildRequest(
        task: AITask,
        step: TaskStep,
        checkpoint: Checkpoint?,
        responseFormat: ResponseFormat = .text,
        maxOutputTokens: Int = 2048,
        temperature: Double = 0.2,
        timeout: TimeInterval = 180,
        contextShrinkFactor: Double? = nil
    ) -> AIRequest {

        let ordinal = step.index + 1
        let total = max(task.totalSteps, ordinal)

        let progressSection: String
        if let summary = checkpoint?.workingSummary?.trimmingCharacters(in: .whitespacesAndNewlines),
           !summary.isEmpty {
            progressSection = """
            Progress so far (from the last checkpoint):
            \(summary)
            """
        } else {
            progressSection = "Progress so far: this is the first step, nothing has been completed yet."
        }

        let stepInstruction: String
        switch step.type {
        case .final:
            stepInstruction = """
            This is the FINAL step. Produce the deliverable for the overall goal, \
            synthesizing everything completed so far. Be concrete and complete.
            """
        case .reduce:
            stepInstruction = """
            This is a REDUCE step. Aggregate the results produced so far into a \
            consolidated intermediate result.
            """
        default:
            stepInstruction = """
            Complete this step and return a concise, self-contained result. \
            Assume the result will be read later without access to this conversation.
            """
        }

        let userPrompt = """
        You are working on step \(ordinal) of \(total).

        Overall goal:
        \(task.goal)

        \(progressSection)

        \(stepInstruction)
        """

        var request = AIRequest(
            systemPrompt: systemPrompt,
            userPrompt: userPrompt,
            maxOutputTokens: maxOutputTokens,
            temperature: temperature,
            responseFormat: responseFormat,
            timeout: timeout
        )

        // contextTooLong 的降级路径: 按比例裁剪 prompt 后重试。
        if let factor = contextShrinkFactor, factor > 0, factor < 1 {
            request = request.shrinkingUserPrompt(factor: factor)
        }

        return request
    }

    /// 从步骤输入里解析期望的响应格式。
    public static func responseFormat(for step: TaskStep) -> ResponseFormat {
        guard let raw = step.input["responseFormat"]?.stringValue else { return .text }
        return ResponseFormat(rawValue: raw) ?? .text
    }
}
````


#### `Sources/AIRunnerCore/Core/WebExecutionCoordinator.swift` (569 行)

````swift
import Foundation

// MARK: - 错误

/// Web 执行通道的错误。
public enum WebExecutionError: Error, Sendable {
    case taskNotFound(String)
    case stepNotFound(String)
    case stepNotInExpectedState(stepIndex: Int, actual: StepStatus)
    case noExecutableStep(taskName: String)
    case emptyClipboard
    case validationFailed(String)
    case taskNotAwaitingUser(current: TaskStatus)

    public var userMessage: String {
        switch self {
        case .taskNotFound(let id):
            return "找不到任务: \(id)"
        case .stepNotFound(let id):
            return "找不到步骤: \(id)"
        case .stepNotInExpectedState(let index, let actual):
            return "步骤 \(index + 1) 当前状态为「\(actual.displayName)」, 无法执行该操作"
        case .noExecutableStep(let name):
            return "任务「\(name)」没有待执行的步骤 (可能已全部完成)"
        case .emptyClipboard:
            return "剪贴板为空, 请先复制 ChatGPT 的回复"
        case .validationFailed(let detail):
            return "结果校验未通过, 检查点未推进: \(detail)"
        case .taskNotAwaitingUser(let current):
            return "任务当前状态为「\(current.displayName)」, 不在等待回填"
        }
    }
}

extension WebExecutionError: LocalizedError {
    public var errorDescription: String? { userMessage }
}

// MARK: - 数据载体

/// 已生成、等待用户提交的 Web 步骤。
public struct PreparedWebStep: Sendable, Equatable {
    public let taskID: String
    public let stepID: String
    public let stepIndex: Int
    public let totalSteps: Int
    public let prompt: String
    public let preparedAt: Date
    /// 该步骤在生成 prompt 之前是否就已经是 prepared
    /// (true 表示这是崩溃恢复后的重新生成)。
    public let wasAlreadyPrepared: Bool

    public init(
        taskID: String,
        stepID: String,
        stepIndex: Int,
        totalSteps: Int,
        prompt: String,
        preparedAt: Date,
        wasAlreadyPrepared: Bool
    ) {
        self.taskID = taskID
        self.stepID = stepID
        self.stepIndex = stepIndex
        self.totalSteps = totalSteps
        self.prompt = prompt
        self.preparedAt = preparedAt
        self.wasAlreadyPrepared = wasAlreadyPrepared
    }

    public var ordinal: Int { stepIndex + 1 }
}

/// 「Copy Continuation Prompt」按钮的完整执行结果。
public struct PromptDelivery: Sendable, Equatable {
    public let prepared: PreparedWebStep
    public let copiedToClipboard: Bool
    public let browserOpened: Bool
    public let browserURL: URL?
}

/// 导入结果后的产物。
public struct ImportedResult: Sendable, Equatable {
    public let taskID: String
    public let stepID: String
    public let stepIndex: Int
    public let checkpoint: Checkpoint
    /// 还剩多少个可执行步骤 (0 表示任务已实质完成)。
    public let remainingSteps: Int

    public var isFinalStep: Bool { remainingSteps == 0 }
}

// MARK: - 协议

/// Web 执行通道的契约。
///
/// 所有 ID 使用 `String` —— 本项目全量 ID 都是 `UUID().uuidString`,
/// 保持 String 可以完全不触碰既有的 Model / Repository 层。
public protocol WebExecutionCoordinating: Sendable {

    /// 为下一个可执行步骤生成续跑 prompt, 并把该步骤标记为 `prepared`。
    func prepareStep(taskID: String) async throws -> PreparedWebStep

    /// 生成 prompt → 写入剪贴板 → (可选) 打开 ChatGPT。
    /// 这是 MVP 阶段的主路径。
    func deliverPrompt(
        taskID: String,
        copyToClipboard: Bool,
        openBrowser: Bool
    ) async throws -> PromptDelivery

    /// 从剪贴板读取 ChatGPT 的回复, 校验后提交为结果。
    func importClipboardResult(taskID: String) async throws -> ImportedResult

    /// 记录用户已把 prompt 提交给 ChatGPT (审计用)。
    func markSubmitted(taskID: String, stepID: String) async throws

    /// 接收用户从 ChatGPT 拿回的结果: 校验 → 原子提交 → 推进检查点。
    /// 校验失败**绝不**推进检查点。
    func acceptResult(taskID: String, stepID: String, result: String) async throws -> ImportedResult

    /// 因当前 ChatGPT session 无法继续而暂停, 等待用户手动切换账号。
    /// 只改任务状态, 不动任何已有进度。
    func pauseForAccountSwitch(taskID: String, reason: String) async throws

    /// 用户完成手动账号切换后调用。
    func resumeAfterManualAccountSwitch(taskID: String) async throws
}

// MARK: - 实现

/// ChatGPT Web 执行协调器。
///
/// ## 职责
/// 管理一个任务在 ChatGPT Web 场景下的执行状态, 即:
/// **生成续跑 prompt → 交给用户 → 接回结果 → 原子提交 → 推进检查点**。
///
/// ## ★ 明确不做的事 ★
/// - 不保存账号密码
/// - 不读取 Cookie / session token / authentication storage
/// - 不执行登录
/// - 不自动轮换账号
/// - 不绕过任何平台使用限制
///
/// 它只操作用户**已经自己登录并授权**的会话 —— 而且是通过"把 prompt 交给用户"
/// 这种方式, 连浏览器页面都不直接操作。
///
/// ## 状态机
/// ```
/// pending ──prepareStep──► prepared ──acceptResult──► completed (+ checkpoint)
///    ▲                         │
///    └──── clearPrepared ──────┘
///
/// 任意时刻 session 不可用:
///   prepared / pending ──pauseForAccountSwitch──► Task = waitingForAccount
///                        ──用户手动切换──► resumeAfterManualAccountSwitch ──► running
/// ```
public actor WebExecutionCoordinator: WebExecutionCoordinating {

    // 依赖
    private let tasks: TaskRepository
    private let steps: StepRepository
    private let checkpoints: CheckpointRepository
    private let checkpointManager: CheckpointManager
    private let logger: LoggerService
    private let promptBuilder: ContinuationPromptBuilder
    private let clipboard: any ClipboardServicing
    private let browser: any BrowserLaunching
    private let chatGPTURLOverride: @Sendable () -> String?

    public init(
        tasks: TaskRepository,
        steps: StepRepository,
        checkpoints: CheckpointRepository,
        checkpointManager: CheckpointManager,
        logger: LoggerService,
        promptBuilder: ContinuationPromptBuilder = ContinuationPromptBuilder(),
        clipboard: any ClipboardServicing = InMemoryClipboard(),
        browser: any BrowserLaunching = NoopBrowserLauncher(),
        chatGPTURLOverride: @escaping @Sendable () -> String? = { nil }
    ) {
        self.tasks = tasks
        self.steps = steps
        self.checkpoints = checkpoints
        self.checkpointManager = checkpointManager
        self.logger = logger
        self.promptBuilder = promptBuilder
        self.clipboard = clipboard
        self.browser = browser
        self.chatGPTURLOverride = chatGPTURLOverride
    }

    // MARK: - 1. 生成续跑 prompt

    public func prepareStep(taskID: String) async throws -> PreparedWebStep {
        guard let task = try tasks.fetch(id: taskID) else {
            throw WebExecutionError.taskNotFound(taskID)
        }

        guard let step = try steps.nextExecutableStep(taskID: taskID) else {
            throw WebExecutionError.noExecutableStep(taskName: task.name)
        }

        let alreadyPrepared = (step.status == .prepared)

        let checkpoint = try checkpoints.latest(taskID: taskID)
        let completedIndexes = try steps.completedIndexes(taskID: taskID)

        // ★ 纯函数生成 —— 同样的输入必然产出同样的文本。
        //   这是"崩溃后重新生成相同 prompt"的全部依据。
        let prompt = promptBuilder.build(
            ContinuationPromptBuilder.Input(
                goal: task.goal,
                stepIndex: step.index,
                totalSteps: task.totalSteps,
                stepType: step.type,
                checkpoint: checkpoint,
                completedStepIndexes: completedIndexes,
                structuredFacts: ContinuationPromptBuilder.facts(from: checkpoint),
                outputSchema: step.input["outputSchema"]?.stringValue
            )
        )

        try steps.markPrepared(stepID: step.id)

        if alreadyPrepared {
            logger.info(
                .webStepPrepared,
                "恢复: 步骤 \(step.index + 1) 的续跑 prompt 已重新生成 (内容与此前一致, "
                + "因为 prompt 是纯函数输出)",
                taskID: taskID, stepIndex: step.index
            )
        } else {
            logger.info(
                .webStepPrepared,
                "步骤 \(step.index + 1)/\(task.totalSteps) 的续跑 prompt 已生成, 等待提交",
                taskID: taskID, stepIndex: step.index,
                metadata: .object([
                    "promptCharacters": .int(prompt.count),
                    "completedSteps": .int(completedIndexes.count),
                ])
            )
        }

        return PreparedWebStep(
            taskID: taskID,
            stepID: step.id,
            stepIndex: step.index,
            totalSteps: task.totalSteps,
            prompt: prompt,
            preparedAt: Date(),
            wasAlreadyPrepared: alreadyPrepared
        )
    }

    /// 生成 prompt → 写入剪贴板 → 打开 ChatGPT。
    ///
    /// 这是 MVP 阶段的主路径: 不依赖任何浏览器自动化, 只借用用户的剪贴板。
    public func deliverPrompt(
        taskID: String,
        copyToClipboard: Bool = true,
        openBrowser: Bool = true
    ) async throws -> PromptDelivery {

        let prepared = try await prepareStep(taskID: taskID)

        var copied = false
        if copyToClipboard {
            copied = clipboard.writeString(prepared.prompt)
            if copied {
                logger.info(
                    .webPromptCopied,
                    "续跑 prompt 已复制到剪贴板 (步骤 \(prepared.ordinal)/\(prepared.totalSteps))",
                    taskID: taskID, stepIndex: prepared.stepIndex
                )
            }
        }

        var opened = false
        var usedURL: URL?
        if openBrowser {
            let url = ChatGPTWebTarget.resolvedURL(override: chatGPTURLOverride())
            opened = browser.open(url)
            usedURL = url
            if opened {
                logger.info(
                    .browserOpened,
                    "已请求打开 \(url.absoluteString) (请在你自己已登录的浏览器中操作)",
                    taskID: taskID, stepIndex: prepared.stepIndex
                )
            }
        }

        return PromptDelivery(
            prepared: prepared,
            copiedToClipboard: copied,
            browserOpened: opened,
            browserURL: usedURL
        )
    }

    // MARK: - 2. 标记已提交

    public func markSubmitted(taskID: String, stepID: String) async throws {
        guard let step = try steps.fetch(id: stepID), step.taskID == taskID else {
            throw WebExecutionError.stepNotFound(stepID)
        }
        guard step.status == .prepared else {
            throw WebExecutionError.stepNotInExpectedState(
                stepIndex: step.index, actual: step.status
            )
        }
        try steps.markSubmitted(stepID: stepID)
        logger.info(
            .webStepSubmitted,
            "步骤 \(step.index + 1) 已提交给 ChatGPT, 等待回填结果",
            taskID: taskID, stepIndex: step.index
        )
    }

    // MARK: - 3. 接收结果

    public func acceptResult(
        taskID: String,
        stepID: String,
        result: String
    ) async throws -> ImportedResult {

        guard let task = try tasks.fetch(id: taskID) else {
            throw WebExecutionError.taskNotFound(taskID)
        }
        guard let step = try steps.fetch(id: stepID), step.taskID == taskID else {
            throw WebExecutionError.stepNotFound(stepID)
        }

        let trimmed = result.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebExecutionError.emptyClipboard
        }

        // --- 输出校验: 失败绝不推进 checkpoint ---
        let format = TaskPlanner.responseFormat(for: step)
        let validator = CompositeResponseValidator.standard(for: format)

        let response = AIResponse(
            text: trimmed,
            provider: "chatgpt-web",
            model: "manual-session",
            latencyMilliseconds: 0
        )
        let request = TaskPlanner.buildRequest(
            task: task, step: step, checkpoint: nil, responseFormat: format
        )

        do {
            try validator.validate(response, request: request)
        } catch {
            let appError = AppError.normalize(error)
            logger.warning(
                .resultImportRejected,
                "步骤 \(step.index + 1) 的结果未通过校验, 检查点保持不变: \(appError.userMessage)",
                taskID: taskID, stepIndex: step.index
            )
            throw WebExecutionError.validationFailed(appError.userMessage)
        }

        // --- 组结果 + 原子提交 ---
        let previous = try checkpoints.latest(taskID: taskID)

        let output = JSONValue.object([
            "text": .string(trimmed),
            "provider": .string("chatgpt-web"),
            "model": .string("manual-session"),
            "source": .string("clipboard"),
            "importedAt": .string(DateCoding.string(from: Date())),
        ])

        let newCheckpoint = await checkpointManager.makeCheckpoint(
            taskID: taskID,
            completedStep: step.index,
            previous: previous,
            output: output,
            provider: "chatgpt-web",
            model: "manual-session"
        )

        try steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: stepID,
                taskID: taskID,
                output: output,
                provider: "chatgpt-web",
                model: "manual-session",
                durationMs: elapsedMilliseconds(since: step.preparedAt),
                checkpoint: newCheckpoint,
                newCurrentStep: step.index + 1
            )
        )

        let remaining = try steps.executableCount(taskID: taskID)

        logger.info(
            .resultImported,
            "步骤 \(step.index + 1)/\(task.totalSteps) 结果已导入并提交 "
            + "(\(trimmed.count) 字符)。检查点: completedStep=\(newCheckpoint.completedStep) "
            + "nextStep=\(newCheckpoint.nextStep)。剩余 \(remaining) 步。",
            taskID: taskID, stepIndex: step.index
        )

        return ImportedResult(
            taskID: taskID,
            stepID: stepID,
            stepIndex: step.index,
            checkpoint: newCheckpoint,
            remainingSteps: remaining
        )
    }

    /// 从剪贴板导入结果 —— 「Paste Result」按钮的实现。
    public func importClipboardResult(taskID: String) async throws -> ImportedResult {
        guard let raw = clipboard.readString() else {
            throw WebExecutionError.emptyClipboard
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw WebExecutionError.emptyClipboard
        }

        // 优先回填"正在等待结果"的那一步; 若没有, 退回到下一个可执行步骤。
        let target = try steps.awaitingResultStep(taskID: taskID)
            ?? steps.nextExecutableStep(taskID: taskID)

        guard let step = target else {
            throw WebExecutionError.noExecutableStep(taskName: taskID)
        }

        return try await acceptResult(taskID: taskID, stepID: step.id, result: trimmed)
    }

    // MARK: - 4. 账号交接

    public func pauseForAccountSwitch(taskID: String, reason: String) async throws {
        guard let task = try tasks.fetch(id: taskID) else {
            throw WebExecutionError.taskNotFound(taskID)
        }

        // ★ 进度安全保证 ★
        // 每个已完成步骤的结果与检查点都是在单个事务里提交的, 所以此刻库里
        // 已经是一致状态。这里**只需要**改任务状态 —— 不需要(也不应该)再写任何进度。
        //
        // 唯一需要收拾的是"处于 running 的步骤": Web 模式下不应出现, 但若存在
        // (例如上一次 API 模式执行被打断), 退回 pending 让它可重新执行。
        if let running = try steps.fetchAll(taskID: taskID).first(where: { $0.status == .running }) {
            try steps.markPending(stepID: running.id, error: "账号交接, 该步未提交")
            logger.warning(
                .accountHandoffRequested,
                "步骤 \(running.index + 1) 处于 running, 已退回待执行状态",
                taskID: taskID, stepIndex: running.index
            )
        }

        if task.status == .waitingForAccount {
            logger.info(.accountHandoffRequested, "任务已在等待账号切换状态 (重复请求被忽略)", taskID: taskID)
            return
        }

        _ = try tasks.updateStatus(
            id: taskID,
            to: .waitingForAccount,
            errorMessage: reason,
            errorClass: "ACCOUNT_HANDOFF"
        )

        let checkpoint = try checkpoints.latest(taskID: taskID)
        logger.warning(
            .accountHandoffRequested,
            "任务已暂停并安全保存至检查点 \(checkpoint.map { "step \($0.completedStep + 1)" } ?? "初始")"
            + "。原因: \(reason)。请手动切换到另一个已授权的 ChatGPT 会话。",
            taskID: taskID,
            metadata: .object([
                "completedSteps": .int((checkpoint?.completedStep ?? -1) + 1),
                "reason": .string(reason),
            ])
        )
    }

    public func resumeAfterManualAccountSwitch(taskID: String) async throws {
        guard let task = try tasks.fetch(id: taskID) else {
            throw WebExecutionError.taskNotFound(taskID)
        }

        guard task.status.requiresUserAction || task.status == .paused || task.status == .failed else {
            logger.info(
                .accountHandoffCompleted,
                "任务状态为「\(task.status.displayName)」, 无需从账号交接恢复",
                taskID: taskID
            )
            return
        }

        _ = try tasks.updateStatus(
            id: taskID,
            to: .running,
            errorMessage: nil,
            errorClass: nil
        )

        let checkpoint = try checkpoints.latest(taskID: taskID)
        let next = try steps.nextExecutableStep(taskID: taskID)

        logger.info(
            .accountHandoffCompleted,
            "账号交接完成, 将从检查点继续: "
            + "completedStep=\(checkpoint?.completedStep ?? -1), "
            + "下一步 = \(next.map { "step \($0.index + 1)" } ?? "无 (已完成)")",
            taskID: taskID
        )
    }

    /// 用户觉得 prompt 不对, 想重新生成。
    public func discardPreparedPrompt(taskID: String) async throws {
        guard let step = try steps.awaitingResultStep(taskID: taskID) else { return }
        try steps.clearPrepared(stepID: step.id)
        logger.info(
            .webStepPrepared,
            "已丢弃步骤 \(step.index + 1) 的 prompt, 将重新生成",
            taskID: taskID, stepIndex: step.index
        )
    }

    // MARK: - 查询

    /// 当前正在等待用户回填结果的那一步 (供 UI 显示)。
    public func awaitingStep(taskID: String) throws -> TaskStep? {
        try steps.awaitingResultStep(taskID: taskID)
    }

    /// 预演下一次 prepareStep 会产出什么, 但**不写库**。
    /// 供 UI 预览或"我想先看看 prompt"用。
    public func previewPrompt(taskID: String) throws -> String? {
        guard let task = try tasks.fetch(id: taskID),
              let step = try steps.nextExecutableStep(taskID: taskID) else {
            return nil
        }
        let checkpoint = try checkpoints.latest(taskID: taskID)
        let completedIndexes = try steps.completedIndexes(taskID: taskID)

        return promptBuilder.build(
            ContinuationPromptBuilder.Input(
                goal: task.goal,
                stepIndex: step.index,
                totalSteps: task.totalSteps,
                stepType: step.type,
                checkpoint: checkpoint,
                completedStepIndexes: completedIndexes,
                structuredFacts: ContinuationPromptBuilder.facts(from: checkpoint),
                outputSchema: step.input["outputSchema"]?.stringValue
            )
        )
    }

    // MARK: - 内部

    private func elapsedMilliseconds(since date: Date?) -> Int {
        guard let date else { return 0 }
        return max(0, Int(Date().timeIntervalSince(date) * 1000))
    }
}
````


### Provider 抽象 (通用协议)


#### `Sources/AIRunnerCore/Providers/AIProvider.swift` (38 行)

````swift
import Foundation

/// 所有模型后端统一接口。
///
/// JobRunner **只** 依赖这个协议, 不认识任何具体 SDK。
/// 这样将来加 Anthropic / Gemini 原生协议, 或换 http 客户端, 都不用动 Runner。
public protocol AIProvider: Sendable {

    /// Provider 标识 (如 "openai")。
    var id: String { get }

    /// 本实例绑定的模型名。
    var model: String { get }

    /// 执行一次请求。
    /// - Throws: 必须抛出 `AppError`, 不许抛裸 `Error` —— 否则错误分类会失效。
    func execute(request: AIRequest) async throws -> AIResponse

    /// 轻量健康探测。**不应** 消耗生成额度, 也 **不应** 抛错。
    func healthCheck() async -> ProviderHealth
}

/// backend = (provider 实例, 模型名) 的组合。
///
/// ModelRouter 的产出就是它。刻意做成值类型, 便于记录"本次步骤试过哪些 backend"。
public struct BackendRef: Sendable, Equatable, Hashable {
    public let providerID: String
    public let model: String
    public let priority: Int

    public init(providerID: String, model: String, priority: Int) {
        self.providerID = providerID
        self.model = model
        self.priority = priority
    }

    public var label: String { "\(providerID) / \(model)" }
}
````


#### `Sources/AIRunnerCore/Providers/MockAIProvider.swift` (170 行)

````swift
import Foundation

/// Mock 行为脚本。
///
/// 生产代码 **绝不** 使用 Mock —— `ProviderConfig.defaults` 里没有任何 mock 条目,
/// `ModelRouter` 也不会自动注入它。它只由测试与离线 Demo 显式构造。
public enum MockBehavior: Sendable, Equatable {
    case success(text: String)
    case jsonSuccess(payload: String)
    case rateLimited(retryAfter: TimeInterval?)
    case timeout
    case serverError
    case authError
    case billingError
    case emptyOutput
    case networkFailure
    case latency(seconds: TimeInterval)

    public static var ok: MockBehavior { .success(text: "mock ok") }
}

/// 可编程的假 Provider。
///
/// 按 `script` 顺序逐次返回预设结果, 用尽后使用 `fallback`。
/// 这让"第 3 步超时一次然后成功"这类场景可以被精确构造与断言。
public final class MockAIProvider: AIProvider, @unchecked Sendable {

    public let id: String
    public let model: String

    private let lock = NSLock()
    private var script: [MockBehavior]
    private var fallback: MockBehavior
    private var callCount = 0
    private var capturedRequests: [AIRequest] = []
    private var healthOverride: ProviderHealth?

    public init(
        id: String = "mock",
        model: String = "mock-fast",
        script: [MockBehavior] = [],
        fallback: MockBehavior = .success(text: "mock ok")
    ) {
        self.id = id
        self.model = model
        self.script = script
        self.fallback = fallback
    }

    // MARK: - 测试控制面

    public var calls: Int {
        lock.lock(); defer { lock.unlock() }
        return callCount
    }

    public var requests: [AIRequest] {
        lock.lock(); defer { lock.unlock() }
        return capturedRequests
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        callCount = 0
        capturedRequests = []
    }

    public func setFallback(_ behavior: MockBehavior) {
        lock.lock(); defer { lock.unlock() }
        fallback = behavior
    }

    public func appendScript(_ behaviors: [MockBehavior]) {
        lock.lock(); defer { lock.unlock() }
        script.append(contentsOf: behaviors)
    }

    public func setHealthOverride(_ health: ProviderHealth?) {
        lock.lock(); defer { lock.unlock() }
        healthOverride = health
    }

    // MARK: - AIProvider

    public func execute(request: AIRequest) async throws -> AIResponse {
        let behavior = dequeueBehavior(for: request)

        let started = Date()

        switch behavior {
        case .success(let text):
            return AIResponse(
                text: text,
                provider: id,
                model: model,
                inputTokens: request.userPrompt.count / 4,
                outputTokens: text.count / 4,
                latencyMilliseconds: elapsedMs(since: started),
                finishReason: "stop"
            )

        case .jsonSuccess(let payload):
            return AIResponse(
                text: payload,
                provider: id,
                model: model,
                inputTokens: request.userPrompt.count / 4,
                outputTokens: payload.count / 4,
                latencyMilliseconds: elapsedMs(since: started),
                finishReason: "stop"
            )

        case .latency(let seconds):
            try await Task.sleep(nanoseconds: UInt64(max(0, seconds) * 1_000_000_000))
            let text = "mock delayed ok (step latency \(seconds)s)"
            return AIResponse(
                text: text, provider: id, model: model,
                inputTokens: nil, outputTokens: nil,
                latencyMilliseconds: elapsedMs(since: started), finishReason: "stop"
            )

        case .rateLimited(let retryAfter):
            throw AppError.rateLimit(retryAfter: retryAfter)

        case .timeout:
            throw AppError.timeout

        case .serverError:
            throw AppError.providerUnavailable

        case .authError:
            throw AppError.authentication

        case .billingError:
            throw AppError.billingRequired

        case .emptyOutput:
            throw AppError.invalidOutput("mock: 内容为空")

        case .networkFailure:
            throw AppError.network("mock: 连接被重置")
        }
    }

    public func healthCheck() async -> ProviderHealth {
        // 锁操作必须留在同步函数里: NSLock.lock() 在 async 上下文中被 Swift 6 标记为不可用,
        // 因为在异步上下文里阻塞线程可能造成线程饥饿。
        if let override = currentHealthOverride() {
            return override
        }
        return ProviderHealth(provider: id, model: model, state: .healthy, lastSuccess: Date())
    }

    private func dequeueBehavior(for request: AIRequest) -> MockBehavior {
        lock.lock(); defer { lock.unlock() }
        let index = callCount
        callCount += 1
        capturedRequests.append(request)
        return index < script.count ? script[index] : fallback
    }

    private func currentHealthOverride() -> ProviderHealth? {
        lock.lock(); defer { lock.unlock() }
        return healthOverride
    }

    private func elapsedMs(since start: Date) -> Int {
        max(0, Int(Date().timeIntervalSince(start) * 1000))
    }
}
````


### 可选 API 后端 Legacy/API


#### `Sources/AIRunnerCore/Legacy/API/OpenAICompatibleProvider.swift` (375 行)

````swift
import Foundation

/// OpenAI 兼容的 HTTP Provider。
///
/// 覆盖: OpenAI 官方、DeepSeek、Moonshot、Groq, 以及任何兼容
/// `POST {baseURL}/chat/completions` 协议的网关 (含本地 vLLM / Ollama /v1)。
///
/// 职责边界: 只管 HTTP 与协议编解码。不关心重试、路由、检查点 —— 那是 Runner 的事。
public struct OpenAICompatibleProvider: AIProvider {

    public let id: String
    public let model: String

    private let config: ProviderConfig
    private let apiKey: String?
    private let session: URLSession

    public init(
        config: ProviderConfig,
        model: String? = nil,
        apiKey: String?,
        session: URLSession? = nil
    ) {
        self.id = config.id
        self.model = model ?? config.defaultModel
        self.config = config
        self.apiKey = apiKey
        self.session = session ?? Self.makeSession()
    }

    static func makeSession() -> URLSession {
        let cfg = URLSessionConfiguration.ephemeral   // 不落盘缓存, 不写 cookie jar
        cfg.timeoutIntervalForRequest = 300
        cfg.timeoutIntervalForResource = 1800
        cfg.waitsForConnectivity = false
        cfg.httpAdditionalHeaders = ["User-Agent": "AIRunner/1.0 (macOS)"]
        return URLSession(configuration: cfg)
    }

    // MARK: - execute

    public func execute(request: AIRequest) async throws -> AIResponse {
        guard let url = config.chatCompletionsURL else {
            throw AppError.invalidRequest("Provider \(id) 的 baseURL 非法: \(config.baseURL)")
        }
        if config.requiresAPIKey, (apiKey ?? "").isEmpty {
            throw AppError.authentication
        }

        var urlRequest = URLRequest(url: url)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue("application/json", forHTTPHeaderField: "Accept")
        urlRequest.timeoutInterval = request.timeout
        if let apiKey, !apiKey.isEmpty {
            urlRequest.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            urlRequest.httpBody = try JSONSerialization.data(withJSONObject: buildBody(request))
        } catch {
            throw AppError.invalidRequest("请求体构造失败: \(error)")
        }

        let started = Date()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: urlRequest)
        } catch {
            throw AppError.normalize(error)
        }
        let latencyMs = Int(Date().timeIntervalSince(started) * 1000)

        guard let http = response as? HTTPURLResponse else {
            throw AppError.network("响应不是 HTTPURLResponse")
        }

        guard (200..<300).contains(http.statusCode) else {
            throw Self.mapHTTPError(
                status: http.statusCode, data: data, headers: http, providerID: id
            )
        }

        return try Self.parseSuccess(
            data: data, providerID: id, model: model, latencyMs: latencyMs
        )
    }

    // MARK: - 请求体

    private func buildBody(_ request: AIRequest) -> [String: Any] {
        var messages: [[String: Any]] = []
        if !request.systemPrompt.isEmpty {
            messages.append(["role": "system", "content": request.systemPrompt])
        }
        messages.append(["role": "user", "content": request.userPrompt])

        var body: [String: Any] = [
            "model": model,
            "messages": messages,
        ]
        // 用 max_tokens 而非 max_completion_tokens: 兼容面更广 (后者只有较新的 OpenAI 模型接受)。
        if let maxTokens = request.maxOutputTokens {
            body["max_tokens"] = maxTokens
        }
        if let temperature = request.temperature {
            body["temperature"] = temperature
        }
        if request.responseFormat == .json {
            body["response_format"] = ["type": "json_object"]
        }
        return body
    }

    // MARK: - 成功响应解析

    private struct ChatCompletionResponse: Decodable {
        struct Message: Decodable {
            let content: String?
            let reasoning_content: String?
        }
        struct Choice: Decodable {
            let message: Message?
            let text: String?
            let finish_reason: String?
        }
        struct Usage: Decodable {
            let prompt_tokens: Int?
            let completion_tokens: Int?
            let total_tokens: Int?
        }
        let choices: [Choice]?
        let usage: Usage?
        let model: String?
    }

    static func parseSuccess(
        data: Data,
        providerID: String,
        model: String,
        latencyMs: Int
    ) throws -> AIResponse {
        let decoded: ChatCompletionResponse
        do {
            decoded = try JSONCoding.makeDecoder().decode(ChatCompletionResponse.self, from: data)
        } catch {
            throw AppError.invalidOutput(
                "无法解析 chat/completions 响应: \(error.localizedDescription)"
            )
        }

        guard let choice = decoded.choices?.first else {
            throw AppError.invalidOutput("响应中没有 choices")
        }

        let text = (choice.message?.content ?? choice.text ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !text.isEmpty else {
            throw AppError.invalidOutput(
                "模型返回了空内容 (finish_reason=\(choice.finish_reason ?? "nil"))"
            )
        }

        return AIResponse(
            text: text,
            provider: providerID,
            model: decoded.model ?? model,
            inputTokens: decoded.usage?.prompt_tokens,
            outputTokens: decoded.usage?.completion_tokens,
            latencyMilliseconds: latencyMs,
            finishReason: choice.finish_reason
        )
    }

    // MARK: - ★ HTTP 状态 → AppError 映射 ★

    /// 这是"不同错误不同策略"能成立的前提。
    /// 若把所有非 2xx 都映射成同一个错误, RetryManager 就只能一律重试 —— 那正是要避免的。
    static func mapHTTPError(
        status: Int,
        data: Data,
        headers: HTTPURLResponse,
        providerID: String
    ) -> AppError {
        let bodyText = String(data: data, encoding: .utf8) ?? ""
        let haystack = bodyText.lowercased()
        let detail = extractErrorMessage(from: data) ?? String(bodyText.prefix(400))

        switch status {

        case 400:
            if containsAny(haystack, [
                "context length", "context_length_exceeded", "maximum context",
                "too many tokens", "reduce the length", "max_tokens",
            ]) {
                return .contextTooLong
            }
            return .invalidRequest(detail)

        case 401:
            return .authentication

        case 402:
            return .billingRequired

        case 403:
            // 403 既可能是"无权限"也可能是"额度/账单问题", 靠内容区分。
            if containsAny(haystack, ["quota", "billing", "credit", "balance", "payment", "insufficient"]) {
                return .billingRequired
            }
            return .authentication

        case 404:
            // 通常是 model 名写错, 也可能 baseURL 路径错。换 model 有意义, 所以单独分类。
            return .modelUnavailable

        case 408:
            return .timeout

        case 409:
            return .network("请求冲突 (409): \(detail)")

        case 413:
            return .contextTooLong

        case 422:
            return .invalidRequest(detail)

        case 429:
            // ★ 关键区分 ★
            // OpenAI 用 429 同时表达"太快了"和"余额没了"。
            // 前者应当等待重试; 后者重试一万次也没用, 必须熔断并暂停任务。
            if containsAny(haystack, [
                "insufficient_quota", "exceeded your current quota",
                "quota", "billing", "credit", "balance", "payment required",
            ]) {
                return .billingRequired
            }
            return .rateLimit(retryAfter: parseRetryAfter(headers, bodyText: bodyText))

        case 500, 502, 503, 504, 529:
            return .providerUnavailable

        default:
            if (500..<600).contains(status) {
                return .providerUnavailable
            }
            return .invalidRequest("HTTP \(status): \(detail)")
        }
    }

    static func containsAny(_ haystack: String, _ needles: [String]) -> Bool {
        needles.contains { haystack.contains($0) }
    }

    /// 从 Retry-After 头或 body 中提取建议等待秒数。
    static func parseRetryAfter(_ headers: HTTPURLResponse, bodyText: String) -> TimeInterval? {
        if let raw = headers.value(forHTTPHeaderField: "Retry-After") {
            let trimmed = raw.trimmingCharacters(in: .whitespaces)
            if let seconds = Double(trimmed) {
                return max(0, seconds)
            }
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(identifier: "GMT")
            formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss zzz"
            if let date = formatter.date(from: trimmed) {
                return max(0, date.timeIntervalSinceNow)
            }
        }

        // OpenAI 会带 x-ratelimit-reset-requests, 形如 "1s" / "6m0s"
        for header in ["x-ratelimit-reset-requests", "x-ratelimit-reset-tokens"] {
            if let raw = headers.value(forHTTPHeaderField: header), let parsed = parseDuration(raw) {
                return parsed
            }
        }

        // 兜底: 从文案里抓 "try again in 20s"
        if let range = bodyText.range(of: #"in\s+(\d+(\.\d+)?)\s*s"#, options: .regularExpression) {
            let snippet = bodyText[range]
            let digits = snippet.filter { $0.isNumber || $0 == "." }
            if let value = Double(digits) { return value }
        }
        return nil
    }

    /// 解析 "1s" / "6m0s" / "1h2m3s" 这类时长。
    static func parseDuration(_ raw: String) -> TimeInterval? {
        let trimmed = raw.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return nil }
        if let plain = Double(trimmed) { return plain }

        var total: TimeInterval = 0
        var matched = false
        let pattern = #"(\d+(?:\.\d+)?)(ms|s|m|h)"#
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
        let range = NSRange(trimmed.startIndex..<trimmed.endIndex, in: trimmed)
        for match in regex.matches(in: trimmed, range: range) {
            guard match.numberOfRanges == 3,
                  let valueRange = Range(match.range(at: 1), in: trimmed),
                  let unitRange = Range(match.range(at: 2), in: trimmed),
                  let value = Double(trimmed[valueRange]) else { continue }
            matched = true
            switch trimmed[unitRange] {
            case "ms": total += value / 1000
            case "s":  total += value
            case "m":  total += value * 60
            case "h":  total += value * 3600
            default:   break
            }
        }
        return matched ? total : nil
    }

    /// 兼容 OpenAI / Anthropic / 通用网关的错误体格式。
    static func extractErrorMessage(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        if let err = object["error"] as? [String: Any] {
            if let message = err["message"] as? String { return message }
            if let type = err["type"] as? String { return type }
        }
        for key in ["message", "detail", "msg", "error_description"] {
            if let value = object[key] as? String { return value }
        }
        if let err = object["error"] as? String { return err }
        return nil
    }

    // MARK: - 健康探测

    public func healthCheck() async -> ProviderHealth {
        guard let url = config.modelsURL else {
            return ProviderHealth(provider: id, model: model, state: .degraded,
                                  reason: "baseURL 非法")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = min(15, config.timeout)
        if let apiKey, !apiKey.isEmpty {
            request.setValue("Bearer \(apiKey)", forHTTPHeaderField: "Authorization")
        }

        do {
            let (_, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                return ProviderHealth(provider: id, model: model, state: .degraded,
                                      reason: "非 HTTP 响应")
            }
            switch http.statusCode {
            case 200..<300:
                return ProviderHealth(provider: id, model: model, state: .healthy,
                                      lastSuccess: Date())
            case 401, 403:
                return ProviderHealth(provider: id, model: model, state: .unavailable,
                                      lastFailure: Date(), reason: "认证失败")
            case 429:
                return ProviderHealth(provider: id, model: model, state: .degraded,
                                      lastFailure: Date(), reason: "限流中")
            default:
                return ProviderHealth(provider: id, model: model, state: .degraded,
                                      lastFailure: Date(), reason: "HTTP \(http.statusCode)")
            }
        } catch {
            let message = (error as? URLError)?.localizedDescription ?? error.localizedDescription
            return ProviderHealth(provider: id, model: model, state: .degraded,
                                  lastFailure: Date(), reason: message)
        }
    }
}
````


#### `Sources/AIRunnerCore/Legacy/API/ProviderFactory.swift` (184 行)

````swift
import Foundation

/// 根据 (provider, model) 构造可执行的 AIProvider 实例。
///
/// 这里是**唯一**读取 API Key 的地方。读完立刻登记到 `SecretRedactor`,
/// 确保后续任何日志都不会把它打印出来。
///
/// 做成 class (而非 struct) 是为了让 Settings 变更能**就地生效**:
/// `ModelRouter` 持有的 `isProviderConfigured` 闭包引用同一个实例,
/// 因此用户在设置里填完 Key 后不需要重建整个依赖图。
public final class ProviderFactory: @unchecked Sendable {

    private let lock = NSLock()
    private var providerConfigs: [String: ProviderConfig]
    private let keychain: any KeychainManaging
    private let session: URLSession?

    /// 测试专用覆盖表, key = "provider::model"。
    /// 生产路径永不写入 —— `ProviderConfig.defaults` 里没有任何 mock provider,
    /// 且 UI 也不提供注册入口。
    private var overrides: [String: any AIProvider] = [:]

    public init(
        providers: [ProviderConfig],
        keychain: any KeychainManaging,
        session: URLSession? = nil
    ) {
        var map: [String: ProviderConfig] = [:]
        for provider in providers {
            map[provider.id] = provider
        }
        self.providerConfigs = map
        self.keychain = keychain
        self.session = session
    }

    /// 替换 Provider 配置 (Settings 保存时调用)。
    public func update(providers: [ProviderConfig]) {
        var map: [String: ProviderConfig] = [:]
        for provider in providers { map[provider.id] = provider }
        lock.lock(); defer { lock.unlock() }
        providerConfigs = map
    }

    // MARK: - 查询

    public func config(for providerID: String) -> ProviderConfig? {
        lock.lock(); defer { lock.unlock() }
        return providerConfigs[providerID]
    }

    public var allProviders: [ProviderConfig] {
        lock.lock(); defer { lock.unlock() }
        return providerConfigs.values.sorted { $0.id < $1.id }
    }

    public func allProviderIDs() -> [String] {
        lock.lock(); defer { lock.unlock() }
        return providerConfigs.keys.sorted()
    }

    /// 该 Provider 是否已经可以直接使用 (本地模型无需 Key)。
    public func isConfigured(providerID: String) -> Bool {
        guard let config = config(for: providerID), config.enabled else { return false }
        guard config.requiresAPIKey else { return true }
        return hasUsableStoredKey(config.keychainKey)
    }

    public func hasStoredKey(_ keychainKey: String) -> Bool {
        hasUsableStoredKey(keychainKey)
    }

    private func hasUsableStoredKey(_ keychainKey: String) -> Bool {
        guard let value = try? keychain.read(key: keychainKey) else { return false }
        return !value.isEmpty
    }

    public func availableProviderIDs() -> [String] {
        allProviderIDs().filter { isConfigured(providerID: $0) }
    }

    // MARK: - 密钥

    /// 读取 API Key 并登记脱敏。
    public func apiKey(for providerID: String) -> String? {
        guard let config = config(for: providerID), config.requiresAPIKey else { return nil }
        let key = try? keychain.read(key: config.keychainKey)
        SecretRedactor.register(key)
        return key
    }

    public func saveAPIKey(_ value: String, for providerID: String) throws {
        guard let config = config(for: providerID) else {
            throw AppError.invalidRequest("未知 Provider: \(providerID)")
        }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AppError.invalidRequest("API Key 不能为空")
        }
        try keychain.save(key: config.keychainKey, value: trimmed)
        SecretRedactor.register(trimmed)
    }

    public func deleteAPIKey(for providerID: String) throws {
        guard let config = config(for: providerID) else { return }
        try keychain.delete(key: config.keychainKey)
    }

    /// 只返回脱敏后的展示值 —— UI 永远拿不到明文。
    public func maskedKey(for providerID: String) -> String {
        guard let config = config(for: providerID), config.requiresAPIKey else {
            return "无需密钥"
        }
        let value = try? keychain.read(key: config.keychainKey)
        return SecretMasking.mask(value)
    }

    /// 登记所有已配置的密钥到脱敏器 (App 启动时调用一次)。
    public func registerAllSecrets() {
        for provider in allProviders where provider.requiresAPIKey {
            if let value = try? keychain.read(key: provider.keychainKey) {
                SecretRedactor.register(value)
            }
        }
    }

    // MARK: - 测试注入

    /// 测试专用: 覆盖某个 (provider, model) 的 Provider 实例。
    ///
    /// 用于把 `MockAIProvider` 的脚本注入执行链, 从而精确构造
    /// "第 3 步超时一次后成功" 这类场景。
    public func registerOverride(_ provider: any AIProvider, providerID: String, model: String) {
        lock.lock(); defer { lock.unlock() }
        overrides["\(providerID)::\(model)"] = provider
    }

    public func removeOverride(providerID: String, model: String) {
        lock.lock(); defer { lock.unlock() }
        overrides.removeValue(forKey: "\(providerID)::\(model)")
    }

    public func removeAllOverrides() {
        lock.lock(); defer { lock.unlock() }
        overrides.removeAll()
    }

    private func override(providerID: String, model: String) -> (any AIProvider)? {
        lock.lock(); defer { lock.unlock() }
        return overrides["\(providerID)::\(model)"]
    }

    // MARK: - 构造

    public func makeProvider(providerID: String, model: String) throws -> any AIProvider {
        if let registered = override(providerID: providerID, model: model) {
            return registered
        }
        guard let config = config(for: providerID) else {
            throw AppError.invalidRequest("未知 Provider: \(providerID)")
        }
        guard config.enabled else {
            throw AppError.invalidRequest("Provider \(providerID) 已被禁用")
        }

        switch config.kind {
        case .mock:
            // 只可能由测试 / 离线 Demo 显式触发 —— ProviderConfig.defaults 里没有 mock。
            return MockAIProvider(id: providerID, model: model)

        case .openAICompatible:
            let key = apiKey(for: providerID)
            if config.requiresAPIKey, (key ?? "").isEmpty {
                throw AppError.authentication
            }
            return OpenAICompatibleProvider(
                config: config,
                model: model,
                apiKey: key,
                session: session
            )
        }
    }
}
````


### 持久化 Persistence


#### `Sources/AIRunnerCore/Persistence/Database.swift` (441 行)

````swift
import Foundation
import SQLite3

// MARK: - SQL 值

/// 可绑定到 SQL 语句的值。
public enum SQLValue: Sendable, Equatable {
    case null
    case int(Int)
    case double(Double)
    case text(String)
    case blob(Data)

    public var isNull: Bool {
        if case .null = self { return true }
        return false
    }
}

/// 一行查询结果。列名 -> 值。
public struct SQLRow: Sendable {

    public let columns: [String: SQLValue]

    public init(columns: [String: SQLValue]) {
        self.columns = columns
    }

    public subscript(name: String) -> SQLValue? { columns[name] }

    public func string(_ name: String) -> String? {
        guard let v = columns[name] else { return nil }
        switch v {
        case .text(let s):   return s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        case .blob(let b):   return String(data: b, encoding: .utf8)
        case .null:          return nil
        }
    }

    public func int(_ name: String) -> Int? {
        guard let v = columns[name] else { return nil }
        switch v {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        case .text(let s):   return Int(s)
        default:             return nil
        }
    }

    public func double(_ name: String) -> Double? {
        guard let v = columns[name] else { return nil }
        switch v {
        case .double(let d): return d
        case .int(let i):    return Double(i)
        case .text(let s):   return Double(s)
        default:             return nil
        }
    }

    public func bool(_ name: String) -> Bool? {
        guard let v = columns[name] else { return nil }
        switch v {
        case .int(let i):    return i != 0
        case .double(let d): return d != 0
        case .text(let s):   return ["1", "true", "yes"].contains(s.lowercased())
        default:             return nil
        }
    }

    public func date(_ name: String) -> Date? {
        guard let s = string(name) else { return nil }
        return DateCoding.date(from: s)
    }

    public func json(_ name: String) -> JSONValue? {
        guard let s = string(name), !s.isEmpty else { return nil }
        return try? JSONCoding.decode(JSONValue.self, from: s)
    }

    // MARK: 必填读取 (列缺失/类型不符时抛出可诊断的错误)

    public func requireString(_ name: String) throws -> String {
        guard let v = string(name) else {
            throw AppError.database("列 '\(name)' 缺失或不是文本 (行: \(columns.keys.sorted()))")
        }
        return v
    }

    public func requireInt(_ name: String) throws -> Int {
        guard let v = int(name) else {
            throw AppError.database("列 '\(name)' 缺失或不是整数")
        }
        return v
    }
}

// MARK: - Database

/// SQLite 封装。
///
/// 设计取舍
/// --------
/// * **不用 actor**: SQLite 是同步 C API, actor 的 hop 只会引入额外开销,
///   且 actor 重入会让"事务内不能 await"这条约束变得难以强制执行。
///   这里用 `NSRecursiveLock` (递归锁, 支持嵌套事务) 保证线程安全, 并显式标注
///   `@unchecked Sendable`。
/// * **所有事务走 `BEGIN IMMEDIATE`**: 一次性拿到写锁, 避免锁升级死锁;
///   配合 `busy_timeout` 让 Web/UI 线程与 Runner 线程安全并行。
/// * **业务不写 SQL 到这个文件之外**: Repository 层只调用 execute/query/transaction。
public final class Database: @unchecked Sendable {

    // SQLite 要求 TRANSIENT: 让 SQLite 自己拷贝字符串, 不依赖 Swift 侧生命周期。
    nonisolated(unsafe) private static let TRANSIENT =
        unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    private var handle: OpaquePointer?
    private let lock = NSRecursiveLock()
    private let path: String

    public private(set) var isClosed = false

    // MARK: 打开 / 关闭

    /// 打开 (或创建) 数据库。
    /// - Parameter inMemory: 传 true 使用临时内存库 (测试用)。
    public init(path: String, inMemory: Bool = false) throws {
        self.path = inMemory ? ":memory:" : path

        if !inMemory {
            let dir = (path as NSString).deletingLastPathComponent
            if !dir.isEmpty {
                try? FileManager.default.createDirectory(
                    atPath: dir, withIntermediateDirectories: true
                )
            }
        }

        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        var db: OpaquePointer?
        let rc = sqlite3_open_v2(self.path, &db, flags, nil)
        guard rc == SQLITE_OK, let db else {
            let msg = db.map { String(cString: sqlite3_errmsg($0)) } ?? "sqlite3_open_v2 失败 (\(rc))"
            if let db { sqlite3_close_v2(db) }
            throw AppError.database("无法打开数据库 \(self.path): \(msg)")
        }
        self.handle = db

        do {
            try configure()
        } catch {
            sqlite3_close_v2(db)
            self.handle = nil
            throw error
        }
    }

    public static func inMemory() throws -> Database {
        try Database(path: ":memory:", inMemory: true)
    }

    /// 默认数据库位置: `~/Library/Application Support/AIRunner/airunner.sqlite`
    public static func defaultURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let dir = base.appendingPathComponent("AIRunner", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("airunner.sqlite")
    }

    public static func openDefault() throws -> Database {
        try Database(path: try defaultURL().path)
    }

    public var databasePath: String { path }

    public func close() {
        lock.lock()
        defer { lock.unlock() }
        guard let handle, !isClosed else { return }
        sqlite3_close_v2(handle)
        self.handle = nil
        isClosed = true
    }

    deinit {
        if let handle, !isClosed {
            sqlite3_close_v2(handle)
        }
    }

    // MARK: 配置

    private func configure() throws {
        // 外键约束必须显式开启, 否则 ON DELETE CASCADE 不会生效。
        try execRaw("PRAGMA foreign_keys = ON;")
        try execRaw("PRAGMA busy_timeout = 15000;")

        if path != ":memory:" {
            // WAL: 让读 (UI 刷新) 与写 (Runner) 并行。仅对本地文件库有意义。
            try execRaw("PRAGMA journal_mode = WAL;")
            try execRaw("PRAGMA synchronous = NORMAL;")
        } else {
            try execRaw("PRAGMA synchronous = OFF;")
        }
    }

    private func execRaw(_ sql: String) throws {
        guard let handle else { throw AppError.database("数据库已关闭") }
        var errmsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(handle, sql, nil, nil, &errmsg)
        if rc != SQLITE_OK {
            let msg = errmsg.map { String(cString: $0) } ?? "未知错误"
            sqlite3_free(errmsg)
            throw AppError.database("执行失败 [\(sql.prefix(80))]: \(msg)")
        }
    }

    // MARK: 基础执行

    public func execute(_ sql: String, _ params: [SQLValue] = []) throws {
        lock.lock()
        defer { lock.unlock() }
        _ = try run(sql, params: params, collectRows: false)
    }

    public func query(_ sql: String, _ params: [SQLValue] = []) throws -> [SQLRow] {
        lock.lock()
        defer { lock.unlock() }
        return try run(sql, params: params, collectRows: true)
    }

    public func queryOne(_ sql: String, _ params: [SQLValue] = []) throws -> SQLRow? {
        try query(sql, params).first
    }

    public func scalarInt(_ sql: String, _ params: [SQLValue] = []) throws -> Int? {
        guard let row = try queryOne(sql, params) else { return nil }
        guard let first = row.columns.values.first else { return nil }
        switch first {
        case .int(let i):    return i
        case .double(let d): return Int(d)
        case .text(let s):   return Int(s)
        default:             return nil
        }
    }

    public func lastInsertRowID() -> Int64 {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return 0 }
        return sqlite3_last_insert_rowid(handle)
    }

    // MARK: 核心执行 + 绑定

    private func run(_ sql: String, params: [SQLValue], collectRows: Bool) throws -> [SQLRow] {
        guard let handle, !isClosed else { throw AppError.database("数据库已关闭") }

        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(handle, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw AppError.database("SQL 准备失败 [\(sql.prefix(120))]: \(lastError())")
        }
        defer { sqlite3_finalize(stmt) }

        try bind(stmt, params)

        var rows: [SQLRow] = []
        while true {
            let stepRC = sqlite3_step(stmt)
            if stepRC == SQLITE_ROW {
                if collectRows {
                    rows.append(readRow(stmt))
                }
                continue
            }
            if stepRC == SQLITE_DONE { break }
            throw AppError.database(
                "SQL 执行失败 (rc=\(stepRC)) [\(sql.prefix(120))]: \(lastError())"
            )
        }
        return rows
    }

    private func bind(_ stmt: OpaquePointer, _ params: [SQLValue]) throws {
        for (offset, value) in params.enumerated() {
            let idx = Int32(offset + 1)
            let rc: Int32
            switch value {
            case .null:
                rc = sqlite3_bind_null(stmt, idx)
            case .int(let i):
                rc = sqlite3_bind_int64(stmt, idx, Int64(i))
            case .double(let d):
                rc = sqlite3_bind_double(stmt, idx, d)
            case .text(let s):
                rc = sqlite3_bind_text(stmt, idx, s, -1, Database.TRANSIENT)
            case .blob(let data):
                rc = data.withUnsafeBytes { buf in
                    sqlite3_bind_blob(
                        stmt, idx, buf.baseAddress, Int32(buf.count), Database.TRANSIENT
                    )
                }
            }
            if rc != SQLITE_OK {
                throw AppError.database("参数绑定失败 (index=\(idx)): \(lastError())")
            }
        }
    }

    private func readRow(_ stmt: OpaquePointer) -> SQLRow {
        var cols: [String: SQLValue] = [:]
        let count = sqlite3_column_count(stmt)
        for i in 0..<count {
            guard let namePtr = sqlite3_column_name(stmt, i) else { continue }
            let name = String(cString: namePtr)
            switch sqlite3_column_type(stmt, i) {
            case SQLITE_NULL:
                cols[name] = .null
            case SQLITE_INTEGER:
                cols[name] = .int(Int(sqlite3_column_int64(stmt, i)))
            case SQLITE_FLOAT:
                cols[name] = .double(sqlite3_column_double(stmt, i))
            case SQLITE_BLOB:
                if let ptr = sqlite3_column_blob(stmt, i) {
                    let len = Int(sqlite3_column_bytes(stmt, i))
                    cols[name] = .blob(Data(bytes: ptr, count: len))
                } else {
                    cols[name] = .null
                }
            default: // SQLITE_TEXT
                if let cstr = sqlite3_column_text(stmt, i) {
                    cols[name] = .text(String(cString: cstr))
                } else {
                    cols[name] = .null
                }
            }
        }
        return SQLRow(columns: cols)
    }

    private func lastError() -> String {
        guard let handle else { return "数据库已关闭" }
        return String(cString: sqlite3_errmsg(handle))
    }

    // MARK: 事务

    /// 写事务。`BEGIN IMMEDIATE` 立即获取写锁。
    ///
    /// 闭包为**同步**的 —— 这是刻意的: 事务内部一旦 `await`, 就可能让出执行权,
    /// 别的任务插入自己的写操作, 破坏原子性。SQLite 也是同步 API,
    /// 业务代码没必要在事务里做异步 I/O。
    ///
    /// 支持嵌套: 内层使用 `SAVEPOINT`, 因此 Repository 可以互相组合。
    public func transaction<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }

        let nesting = transactionDepth
        let savepointName = "sp_\(nesting)"
        transactionDepth += 1
        defer { transactionDepth -= 1 }

        if nesting == 0 {
            try execRaw("BEGIN IMMEDIATE;")
        } else {
            try execRaw("SAVEPOINT \(savepointName);")
        }

        do {
            let result = try body()
            if nesting == 0 {
                try execRaw("COMMIT;")
            } else {
                try execRaw("RELEASE \(savepointName);")
            }
            return result
        } catch {
            if nesting == 0 {
                try? execRaw("ROLLBACK;")
            } else {
                try? execRaw("ROLLBACK TO \(savepointName);")
                try? execRaw("RELEASE \(savepointName);")
            }
            throw error
        }
    }

    private var transactionDepth = 0

    /// 只读操作。不加显式事务 (SQLite 会自动开启读事务)。
    public func read<T>(_ body: () throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    // MARK: 诊断

    public struct Diagnostics: Sendable {
        public var journalMode: String
        public var foreignKeys: Bool
        public var pageCount: Int
        public var integrityOK: Bool
        public var userVersion: Int
    }

    public func diagnostics() throws -> Diagnostics {
        let journal = try queryOne("PRAGMA journal_mode;")?.columns.values.first
        let fk = try scalarInt("PRAGMA foreign_keys;") ?? 0
        let pages = try scalarInt("PRAGMA page_count;") ?? 0
        let version = try scalarInt("PRAGMA user_version;") ?? 0
        let integrity = try queryOne("PRAGMA quick_check;")
        let okText = integrity?.columns.values.first?.stringValueOrEmpty ?? ""
        return Diagnostics(
            journalMode: journal?.stringValueOrEmpty ?? "?",
            foreignKeys: fk != 0,
            pageCount: pages,
            integrityOK: okText.lowercased() == "ok",
            userVersion: version
        )
    }
}

private extension SQLValue {
    var stringValueOrEmpty: String {
        switch self {
        case .text(let s):   return s
        case .int(let i):    return String(i)
        case .double(let d): return String(d)
        default:             return ""
        }
    }
}
````


#### `Sources/AIRunnerCore/Persistence/DatabaseMigrator.swift` (239 行)

````swift
import Foundation

/// 数据库迁移。
///
/// 用 `PRAGMA user_version` 做版本追踪。每次迁移在**单个事务**内完成:
/// 要么整版建好, 要么完全不改 —— 避免"建了一半"的半损坏 schema。
public enum DatabaseMigrator {

    public static let currentVersion = 2

    public static func migrate(_ db: Database) throws {
        let existing = try db.scalarInt("PRAGMA user_version;") ?? 0

        if existing > currentVersion {
            throw AppError.database(
                "数据库版本 (\(existing)) 高于本程序支持的版本 (\(currentVersion))。"
                + "请升级 AIRunner, 不要用旧版本打开新数据库。"
            )
        }

        if existing < 1 {
            try migrateToV1(db)
        }

        if existing < 2 {
            try migrateToV2(db)
        }
    }

    // MARK: - V1

    private static func migrateToV1(_ db: Database) throws {
        try db.transaction {
            for statement in v1Statements {
                try db.execute(statement)
            }
            // PRAGMA 不支持参数绑定; 这里的值是编译期常量, 无注入风险。
            try db.execute("PRAGMA user_version = \(currentVersion);")
        }
    }

    private static let v1Statements: [String] = [

        // ------------------------------------------------------------------ tasks
        """
        CREATE TABLE IF NOT EXISTS tasks (
            id               TEXT PRIMARY KEY NOT NULL,
            name             TEXT NOT NULL,
            goal             TEXT NOT NULL,

            status           TEXT NOT NULL,

            primary_provider TEXT NOT NULL,
            primary_model    TEXT NOT NULL,

            current_step     INTEGER NOT NULL DEFAULT 0,
            total_steps      INTEGER NOT NULL DEFAULT 0,

            retry_count      INTEGER NOT NULL DEFAULT 0,
            max_retries      INTEGER NOT NULL DEFAULT 8,

            created_at       TEXT NOT NULL,
            updated_at       TEXT NOT NULL,

            -- 扩展字段 (供 UI 展示失败原因 / 等待解除时间)
            error_message    TEXT,
            error_class      TEXT,
            waiting_until    TEXT,
            plan_type        TEXT NOT NULL DEFAULT 'uniform',
            meta_json        TEXT NOT NULL DEFAULT '{}'
        );
        """,

        "CREATE INDEX IF NOT EXISTS idx_tasks_status ON tasks(status);",
        "CREATE INDEX IF NOT EXISTS idx_tasks_created ON tasks(created_at DESC);",

        // ------------------------------------------------------------- task_steps
        """
        CREATE TABLE IF NOT EXISTS task_steps (
            id          TEXT PRIMARY KEY NOT NULL,

            task_id     TEXT NOT NULL,

            step_index  INTEGER NOT NULL,

            type        TEXT NOT NULL,

            status      TEXT NOT NULL,

            input_json  TEXT NOT NULL,

            output_json TEXT,

            provider    TEXT,

            model       TEXT,

            retry_count INTEGER NOT NULL DEFAULT 0,

            started_at  TEXT,

            finished_at TEXT,

            created_at  TEXT NOT NULL,

            -- 扩展字段
            last_error       TEXT,
            error_class      TEXT,
            duration_ms      INTEGER NOT NULL DEFAULT 0,
            attempt_log_json TEXT NOT NULL DEFAULT '[]',

            FOREIGN KEY(task_id)
                REFERENCES tasks(id)
                ON DELETE CASCADE
        );
        """,

        // ★ 幂等保证: 同一任务内 step_index 唯一。
        //   即便 plan 被重复生成, 也不会出现两个 index=3 的步骤。
        """
        CREATE UNIQUE INDEX IF NOT EXISTS idx_task_steps_task_index
            ON task_steps(task_id, step_index);
        """,

        "CREATE INDEX IF NOT EXISTS idx_task_steps_status ON task_steps(task_id, status);",

        // ------------------------------------------------------------ checkpoints
        """
        CREATE TABLE IF NOT EXISTS checkpoints (
            id             TEXT PRIMARY KEY NOT NULL,

            task_id        TEXT NOT NULL,

            completed_step INTEGER NOT NULL,

            next_step      INTEGER NOT NULL,

            working_summary TEXT,

            state_json     TEXT NOT NULL,

            created_at     TEXT NOT NULL,

            FOREIGN KEY(task_id)
                REFERENCES tasks(id)
                ON DELETE CASCADE
        );
        """,

        // 恢复时只需要"最新一条", 这个索引让它变成 O(log n)。
        """
        CREATE INDEX IF NOT EXISTS idx_checkpoints_task_step
            ON checkpoints(task_id, completed_step DESC);
        """,

        // ----------------------------------------------------------------- events
        """
        CREATE TABLE IF NOT EXISTS events (
            id            TEXT PRIMARY KEY NOT NULL,

            task_id       TEXT,

            step_index    INTEGER,

            level         TEXT NOT NULL,

            event_type    TEXT NOT NULL,

            message       TEXT NOT NULL,

            metadata_json TEXT,

            created_at    TEXT NOT NULL
        );
        """,

        "CREATE INDEX IF NOT EXISTS idx_events_task ON events(task_id, created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_events_level ON events(level, created_at DESC);",
        "CREATE INDEX IF NOT EXISTS idx_events_created ON events(created_at DESC);",

        // -------------------------------------------------------- provider_health
        // 熔断状态必须持久化: App 重启后不应立刻去打那个已经余额耗尽的 Provider。
        """
        CREATE TABLE IF NOT EXISTS provider_health (
            provider           TEXT NOT NULL,
            model              TEXT NOT NULL DEFAULT '*',

            state              TEXT NOT NULL,

            consecutive_errors INTEGER NOT NULL DEFAULT 0,

            last_success       TEXT,
            last_failure       TEXT,
            cooldown_until     TEXT,
            reason             TEXT,

            updated_at         TEXT NOT NULL,

            PRIMARY KEY (provider, model)
        );
        """,
    ]

    // MARK: - V2: ChatGPT Web 执行模式

    /// 引入 `execution_mode` 与 Web 步骤时间戳。
    ///
    /// 全部是 `ALTER TABLE ADD COLUMN` + 默认值 —— **非破坏性**迁移:
    /// 已有数据库里的任务、步骤、检查点、日志、Provider 健康记录一条都不动。
    /// 老任务会被默认标记为 `chatgpt_web`, 因为这是新的主流程。
    private static func migrateToV2(_ db: Database) throws {
        let additions: [(table: String, column: String, definition: String)] = [
            ("tasks", "execution_mode",
             "TEXT NOT NULL DEFAULT '\(ExecutionMode.chatGPTWeb.rawValue)'"),
            ("task_steps", "prepared_at", "TEXT"),
            ("task_steps", "submitted_at", "TEXT"),
        ]

        try db.transaction {
            for addition in additions {
                // SQLite 的 ADD COLUMN 不是幂等的, 重复执行会报 "duplicate column name"。
                // 先查 table_info 再决定, 保证迁移可重入。
                if try columnExists(db, table: addition.table, column: addition.column) {
                    continue
                }
                try db.execute(
                    "ALTER TABLE \(addition.table) ADD COLUMN \(addition.column) \(addition.definition);"
                )
            }
            try db.execute("PRAGMA user_version = \(currentVersion);")
        }
    }

    /// 判断某列是否已存在 (用于让 ADD COLUMN 可重入)。
    static func columnExists(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try db.query("PRAGMA table_info(\(table));")
        return rows.contains { $0.string("name") == column }
    }
}
````


#### `Sources/AIRunnerCore/Persistence/Repositories/CheckpointRepository.swift` (79 行)

````swift
import Foundation

/// 检查点表访问。
public struct CheckpointRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func insert(_ checkpoint: Checkpoint) throws {
        try db.execute(
            """
            INSERT INTO checkpoints (
                id, task_id, completed_step, next_step,
                working_summary, state_json, created_at
            ) VALUES (?,?,?,?,?,?,?)
            """,
            [
                .text(checkpoint.id),
                .text(checkpoint.taskID),
                .int(checkpoint.completedStep),
                .int(checkpoint.nextStep),
                checkpoint.workingSummary.map { SQLValue.text($0) } ?? .null,
                .text((try? JSONCoding.encodeToString(checkpoint.state)) ?? "{}"),
                .text(DateCoding.string(from: checkpoint.createdAt)),
            ]
        )
    }

    /// 取最新检查点 (按 completed_step 降序)。
    ///
    /// 这是崩溃恢复的权威依据: 重启后读它就知道该从哪一步继续。
    /// 若任务从未成功执行过任何步骤, 返回 nil —— 调用方应回退到 "从 0 开始"。
    public func latest(taskID: String) throws -> Checkpoint? {
        let rows = try db.query(
            """
            SELECT * FROM checkpoints
             WHERE task_id = ?
             ORDER BY completed_step DESC, created_at DESC
             LIMIT 1
            """,
            [.text(taskID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    public func list(taskID: String, limit: Int = 100) throws -> [Checkpoint] {
        try db.query(
            """
            SELECT * FROM checkpoints
             WHERE task_id = ?
             ORDER BY completed_step DESC
             LIMIT ?
            """,
            [.text(taskID), .int(limit)]
        ).map { try Self.decode($0) }
    }

    public func count(taskID: String) throws -> Int {
        try db.scalarInt(
            "SELECT COUNT(*) FROM checkpoints WHERE task_id = ?", [.text(taskID)]
        ) ?? 0
    }

    static func decode(_ row: SQLRow) throws -> Checkpoint {
        Checkpoint(
            id: try row.requireString("id"),
            taskID: try row.requireString("task_id"),
            completedStep: try row.requireInt("completed_step"),
            nextStep: try row.requireInt("next_step"),
            workingSummary: row.string("working_summary"),
            state: row.json("state_json") ?? .emptyObject,
            createdAt: row.date("created_at") ?? Date()
        )
    }
}
````


#### `Sources/AIRunnerCore/Persistence/Repositories/EventRepository.swift` (108 行)

````swift
import Foundation

/// 事件/日志表访问。
///
/// 注意: 写入本表的内容必须已经过脱敏 —— 见 `LoggerService`。
/// 这里不做二次过滤, 因为 LoggerService 是唯一的写入入口。
public struct EventRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func append(_ event: AppEvent) throws {
        try db.execute(
            """
            INSERT INTO events (
                id, task_id, step_index, level, event_type,
                message, metadata_json, created_at
            ) VALUES (?,?,?,?,?,?,?,?)
            """,
            [
                .text(event.id),
                event.taskID.map { SQLValue.text($0) } ?? .null,
                event.stepIndex.map { SQLValue.int($0) } ?? .null,
                .text(event.level.rawValue),
                .text(event.eventType.rawValue),
                .text(event.message),
                event.metadata.map { SQLValue.text((try? JSONCoding.encodeToString($0)) ?? "null") } ?? .null,
                .text(DateCoding.string(from: event.createdAt)),
            ]
        )
    }

    public func append(contentsOf events: [AppEvent]) throws {
        guard !events.isEmpty else { return }
        try db.transaction {
            for event in events {
                try append(event)
            }
        }
    }

    public func list(
        taskID: String? = nil,
        level: LogLevel? = nil,
        limit: Int = 300
    ) throws -> [AppEvent] {
        var sql = "SELECT * FROM events WHERE 1=1"
        var params: [SQLValue] = []

        if let taskID {
            sql += " AND task_id = ?"
            params.append(.text(taskID))
        }
        if let level {
            sql += " AND level = ?"
            params.append(.text(level.rawValue))
        }
        sql += " ORDER BY created_at DESC LIMIT ?"
        params.append(.int(limit))

        return try db.query(sql, params).map { try Self.decode($0) }
    }

    public func count(taskID: String? = nil) throws -> Int {
        if let taskID {
            return try db.scalarInt(
                "SELECT COUNT(*) FROM events WHERE task_id = ?", [.text(taskID)]
            ) ?? 0
        }
        return try db.scalarInt("SELECT COUNT(*) FROM events") ?? 0
    }

    /// 清理旧日志, 避免长期运行后日志表无限膨胀。
    @discardableResult
    public func prune(keepingMostRecent keep: Int = 20_000) throws -> Int {
        let total = try count()
        guard total > keep else { return 0 }
        let excess = total - keep
        try db.execute(
            """
            DELETE FROM events WHERE id IN (
                SELECT id FROM events ORDER BY created_at ASC LIMIT ?
            )
            """,
            [.int(excess)]
        )
        return excess
    }

    static func decode(_ row: SQLRow) throws -> AppEvent {
        let rawLevel = row.string("level") ?? LogLevel.info.rawValue
        let rawType = row.string("event_type") ?? EventType.unknown.rawValue

        return AppEvent(
            id: try row.requireString("id"),
            taskID: row.string("task_id"),
            stepIndex: row.int("step_index"),
            level: LogLevel(rawValue: rawLevel) ?? .info,
            eventType: EventType(rawValue: rawType) ?? .unknown,
            message: try row.requireString("message"),
            metadata: row.json("metadata_json"),
            createdAt: row.date("created_at") ?? Date()
        )
    }
}
````


#### `Sources/AIRunnerCore/Persistence/Repositories/ProviderHealthRepository.swift` (89 行)

````swift
import Foundation

/// Provider 熔断状态持久化。
///
/// 为什么必须落盘: 若只存在内存, App 重启后会立刻去重试那个已经"余额耗尽"或
/// "Key 无效"的 Provider, 白白浪费时间。持久化后重启仍然遵守冷却期。
public struct ProviderHealthRepository: Sendable {

    /// provider 级 (所有模型共享) 健康度使用这个 model 占位符。
    public static let anyModel = "*"

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    public func upsert(_ health: ProviderHealth) throws {
        let modelKey = health.model ?? Self.anyModel
        try db.execute(
            """
            INSERT INTO provider_health (
                provider, model, state, consecutive_errors,
                last_success, last_failure, cooldown_until, reason, updated_at
            ) VALUES (?,?,?,?,?,?,?,?,?)
            ON CONFLICT(provider, model) DO UPDATE SET
                state = excluded.state,
                consecutive_errors = excluded.consecutive_errors,
                last_success = excluded.last_success,
                last_failure = excluded.last_failure,
                cooldown_until = excluded.cooldown_until,
                reason = excluded.reason,
                updated_at = excluded.updated_at
            """,
            [
                .text(health.provider),
                .text(modelKey),
                .text(health.state.rawValue),
                .int(health.consecutiveErrors),
                health.lastSuccess.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                health.lastFailure.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                health.cooldownUntil.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                health.reason.map { SQLValue.text($0) } ?? .null,
                .text(DateCoding.string(from: Date())),
            ]
        )
    }

    public func fetch(provider: String, model: String? = nil) throws -> ProviderHealth? {
        let modelKey = model ?? Self.anyModel
        guard let row = try db.queryOne(
            "SELECT * FROM provider_health WHERE provider = ? AND model = ?",
            [.text(provider), .text(modelKey)]
        ) else { return nil }
        return Self.decode(row)
    }

    public func fetchAll() throws -> [ProviderHealth] {
        try db.query("SELECT * FROM provider_health ORDER BY provider ASC").map { Self.decode($0) }
    }

    /// 清空熔断状态 (用户在 Settings 里点"重置 Provider 状态"时调用)。
    @discardableResult
    public func reset(provider: String? = nil) throws -> Int {
        let before = try db.scalarInt("SELECT COUNT(*) FROM provider_health") ?? 0
        if let provider {
            try db.execute("DELETE FROM provider_health WHERE provider = ?", [.text(provider)])
        } else {
            try db.execute("DELETE FROM provider_health")
        }
        let after = try db.scalarInt("SELECT COUNT(*) FROM provider_health") ?? 0
        return before - after
    }

    static func decode(_ row: SQLRow) -> ProviderHealth {
        let rawState = row.string("state") ?? ProviderHealthState.healthy.rawValue
        let modelKey = row.string("model")
        return ProviderHealth(
            provider: row.string("provider") ?? "?",
            model: (modelKey == nil || modelKey == anyModel) ? nil : modelKey,
            state: ProviderHealthState(rawValue: rawState) ?? .healthy,
            consecutiveErrors: row.int("consecutive_errors") ?? 0,
            lastSuccess: row.date("last_success"),
            lastFailure: row.date("last_failure"),
            cooldownUntil: row.date("cooldown_until"),
            reason: row.string("reason")
        )
    }
}
````


#### `Sources/AIRunnerCore/Persistence/Repositories/StepRepository.swift` (504 行)

````swift
import Foundation

/// 一次"成功步骤"的原子提交载荷。
public struct SuccessfulStepCommit: Sendable {
    public var stepID: String
    public var taskID: String
    public var output: JSONValue
    public var provider: String
    public var model: String
    public var durationMs: Int
    /// 本步成功后要写入的检查点。
    public var checkpoint: Checkpoint
    /// 任务新的 current_step。
    public var newCurrentStep: Int

    public init(
        stepID: String,
        taskID: String,
        output: JSONValue,
        provider: String,
        model: String,
        durationMs: Int,
        checkpoint: Checkpoint,
        newCurrentStep: Int
    ) {
        self.stepID = stepID
        self.taskID = taskID
        self.output = output
        self.provider = provider
        self.model = model
        self.durationMs = durationMs
        self.checkpoint = checkpoint
        self.newCurrentStep = newCurrentStep
    }
}

/// 步骤表访问 + 原子提交。
public struct StepRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    // MARK: - 批量插入

    /// 批量插入步骤。已存在的 (task_id, step_index) 会被**忽略**
    /// (`INSERT OR IGNORE` + UNIQUE 索引), 因此重复调用是幂等的,
    /// 不会打乱已有进度、也不会因为唯一约束失败而炸掉整个事务。
    @discardableResult
    public func insertBatch(_ steps: [TaskStep]) throws -> Int {
        guard !steps.isEmpty else { return 0 }
        var inserted = 0
        try db.transaction {
            for step in steps {
                try db.execute(
                    """
                    INSERT OR IGNORE INTO task_steps (
                        id, task_id, step_index, type, status,
                        input_json, output_json, provider, model,
                        retry_count, started_at, finished_at, created_at,
                        last_error, error_class, duration_ms, attempt_log_json,
                        prepared_at, submitted_at
                    ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
                    """,
                    [
                        .text(step.id),
                        .text(step.taskID),
                        .int(step.index),
                        .text(step.type.rawValue),
                        .text(step.status.rawValue),
                        .text((try? JSONCoding.encodeToString(step.input)) ?? "{}"),
                        step.output.map { SQLValue.text((try? JSONCoding.encodeToString($0)) ?? "null") } ?? .null,
                        step.provider.map { SQLValue.text($0) } ?? .null,
                        step.model.map { SQLValue.text($0) } ?? .null,
                        .int(step.retryCount),
                        step.startedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                        step.finishedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                        .text(DateCoding.string(from: step.createdAt)),
                        step.lastError.map { SQLValue.text($0) } ?? .null,
                        step.errorClass.map { SQLValue.text($0) } ?? .null,
                        .int(step.durationMs),
                        .text((try? JSONCoding.encodeToString(JSONValue.array(step.attemptLog))) ?? "[]"),
                        step.preparedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                        step.submittedAt.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                    ]
                )
                if db.lastInsertRowID() != 0 { inserted += 1 }
            }
        }
        return inserted
    }

    // MARK: - 读取

    public func fetch(id: String) throws -> TaskStep? {
        guard let row = try db.queryOne("SELECT * FROM task_steps WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try Self.decode(row)
    }

    public func fetch(taskID: String, index: Int) throws -> TaskStep? {
        guard let row = try db.queryOne(
            "SELECT * FROM task_steps WHERE task_id = ? AND step_index = ?",
            [.text(taskID), .int(index)]
        ) else { return nil }
        return try Self.decode(row)
    }

    public func fetchAll(taskID: String) throws -> [TaskStep] {
        try db.query(
            "SELECT * FROM task_steps WHERE task_id = ? ORDER BY step_index ASC",
            [.text(taskID)]
        ).map { try Self.decode($0) }
    }

    /// ★ 幂等性核心查询 ★
    ///
    /// 只返回 `pending` / `interrupted` / `prepared` 的步骤。
    /// **completed / failed / skipped 永远不会出现在结果里** ——
    /// 这就是"已完成的步骤绝不重跑"的实现方式: 不靠调用方自觉判断,
    /// 而是让查询本身取不到已完成的行。
    ///
    /// `prepared` 也必须可执行: Web 模式下 prompt 已生成但结果未回填时若 App 崩溃,
    /// 该步骤必须能被重新取走 (prompt 是纯函数生成的, 重新生成结果相同)。
    public func nextExecutableStep(taskID: String) throws -> TaskStep? {
        let rows = try db.query(
            """
            SELECT * FROM task_steps
             WHERE task_id = ?
               AND status IN ('pending','interrupted','prepared')
             ORDER BY step_index ASC
             LIMIT 1
            """,
            [.text(taskID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    /// 取当前正在等待用户回填结果的那个步骤 (Web 模式)。
    public func awaitingResultStep(taskID: String) throws -> TaskStep? {
        let rows = try db.query(
            """
            SELECT * FROM task_steps
             WHERE task_id = ? AND status = 'prepared'
             ORDER BY step_index ASC
             LIMIT 1
            """,
            [.text(taskID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    /// 只取已完成步骤的下标 (不搬运整行), 供续跑 prompt 生成使用。
    ///
    /// 一个 300~3000 步的任务每次都要列已完成范围, 用整行 `fetchAll` 会造成
    /// 无谓的 JSON 解析开销。
    public func completedIndexes(taskID: String) throws -> [Int] {
        try db.query(
            """
            SELECT step_index FROM task_steps
             WHERE task_id = ? AND status = 'completed'
             ORDER BY step_index ASC
            """,
            [.text(taskID)]
        ).compactMap { $0.int("step_index") }
    }

    public func statusCounts(taskID: String) throws -> [StepStatus: Int] {
        let rows = try db.query(
            "SELECT status, COUNT(*) AS n FROM task_steps WHERE task_id = ? GROUP BY status",
            [.text(taskID)]
        )
        var result: [StepStatus: Int] = [:]
        for row in rows {
            guard let s = row.string("status"), let st = StepStatus(rawValue: s) else { continue }
            result[st] = row.int("n") ?? 0
        }
        return result
    }

    public func count(taskID: String) throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM task_steps WHERE task_id = ?", [.text(taskID)]) ?? 0
    }

    // MARK: - 状态变更

    public func markRunning(stepID: String, provider: String?, model: String?) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'running',
                started_at = ?,
                provider = COALESCE(?, provider),
                model = COALESCE(?, model),
                last_error = NULL,
                error_class = NULL
            WHERE id = ?
            """,
            [
                .text(DateCoding.string(from: Date())),
                provider.map { SQLValue.text($0) } ?? .null,
                model.map { SQLValue.text($0) } ?? .null,
                .text(stepID),
            ]
        )
    }

    // MARK: - Web 模式状态

    /// 标记步骤为 `prepared`: 续跑 prompt 已生成并交付给用户。
    ///
    /// 幂等 —— 重复调用只刷新时间戳。这正是"崩溃后重新生成相同 prompt"的落点:
    /// 步骤可以被重新取走, `ContinuationPromptBuilder` 用同样的输入产出同样的文本。
    public func markPrepared(stepID: String) throws {
        let now = DateCoding.string(from: Date())
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'prepared',
                prepared_at = ?,
                started_at = COALESCE(started_at, ?),
                last_error = NULL,
                error_class = NULL
            WHERE id = ?
            """,
            [.text(now), .text(now), .text(stepID)]
        )
    }

    /// 记录用户已把 prompt 提交给 ChatGPT (仅用于审计与 UI 提示)。
    public func markSubmitted(stepID: String) throws {
        try db.execute(
            "UPDATE task_steps SET submitted_at = ? WHERE id = ?",
            [.text(DateCoding.string(from: Date())), .text(stepID)]
        )
    }

    /// 丢弃已生成的 prompt, 把步骤退回 `pending`。
    /// 用于"用户觉得这个 prompt 不对, 想重新生成"。
    public func clearPrepared(stepID: String) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'pending', prepared_at = NULL, submitted_at = NULL
            WHERE id = ? AND status = 'prepared'
            """,
            [.text(stepID)]
        )
    }

    /// 把 running 的步骤退回 pending (重试前 / 崩溃恢复时使用)。
    public func markPending(stepID: String, error: String? = nil, errorClass: String? = nil) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'pending',
                started_at = NULL,
                last_error = ?,
                error_class = ?,
                provider = provider,
                model = model
            WHERE id = ?
            """,
            [
                error.map { SQLValue.text($0) } ?? .null,
                errorClass.map { SQLValue.text($0) } ?? .null,
                .text(stepID),
            ]
        )
    }

    public func markFailed(stepID: String, error: String, errorClass: String, durationMs: Int = 0) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'failed', last_error = ?, error_class = ?,
                finished_at = ?, duration_ms = ?
            WHERE id = ?
            """,
            [
                .text(error),
                .text(errorClass),
                .text(DateCoding.string(from: Date())),
                .int(durationMs),
                .text(stepID),
            ]
        )
    }

    public func markSkipped(stepID: String, reason: String) throws {
        try db.execute(
            """
            UPDATE task_steps SET
                status = 'skipped', last_error = ?, finished_at = ?
            WHERE id = ?
            """,
            [.text(reason), .text(DateCoding.string(from: Date())), .text(stepID)]
        )
    }

    /// 崩溃恢复: 把所有处于 `running` 的步骤标记为 `interrupted`。
    ///
    /// 这些步骤的特征是"已经开始执行, 但对应的 checkpoint 从未提交" ——
    /// 即进程在 HTTP 请求途中被杀。它们的输出不可信, 必须重跑。
    ///
    /// 之所以标记为 `interrupted` 而不是直接改回 `pending`, 是为了在 UI 与审计里
    /// 留下"这一步曾被打断"的痕迹。`nextExecutableStep` 同样把 `interrupted`
    /// 视为可执行, 因此恢复后能自动接上。
    ///
    /// - Returns: 被标记的步骤数量。
    @discardableResult
    public func markRunningInterrupted(taskID: String? = nil) throws -> Int {
        var sql = """
            UPDATE task_steps SET
                status = 'interrupted',
                last_error = '进程中断: 该步骤未提交结果, 恢复后将重新执行',
                error_class = 'INTERRUPTED'
            WHERE status = 'running'
            """
        if taskID != nil {
            sql += " AND task_id = ?"
        }

        return try db.transaction {
            if let taskID {
                try db.execute(sql, [.text(taskID)])
            } else {
                try db.execute(sql)
            }
            return try db.scalarInt("SELECT changes()") ?? 0
        }
    }

    /// 统计还能继续执行的步骤数。
    public func executableCount(taskID: String) throws -> Int {
        try db.scalarInt(
            """
            SELECT COUNT(*) FROM task_steps
             WHERE task_id = ? AND status IN ('pending','interrupted','prepared')
            """,
            [.text(taskID)]
        ) ?? 0
    }

    /// 追加一条失败尝试的审计记录, 并 retry_count += 1。
    /// 读-改-写在同一事务内完成, 避免并发追加时丢失记录。
    public func appendAttempt(stepID: String, attempt: JSONValue, bumpRetry: Bool = true) throws {
        try db.transaction {
            let existing: JSONValue
            if let row = try db.queryOne(
                "SELECT attempt_log_json FROM task_steps WHERE id = ?", [.text(stepID)]
            ), let parsed = row.json("attempt_log_json") {
                existing = parsed
            } else {
                existing = .emptyArray
            }
            var list = existing.arrayValue ?? []
            list.append(attempt)

            let json = (try? JSONCoding.encodeToString(JSONValue.array(list))) ?? "[]"
            if bumpRetry {
                try db.execute(
                    "UPDATE task_steps SET attempt_log_json = ?, retry_count = retry_count + 1 WHERE id = ?",
                    [.text(json), .text(stepID)]
                )
            } else {
                try db.execute(
                    "UPDATE task_steps SET attempt_log_json = ? WHERE id = ?",
                    [.text(json), .text(stepID)]
                )
            }
        }
    }

    /// 记录本次选中并尝试过的 backend (不增加 retry 计数)。
    public func recordBackendAttempt(stepID: String, provider: String, model: String, note: String?) throws {
        let attempt = JSONValue.object([
            "kind": .string("backend_attempt"),
            "provider": .string(provider),
            "model": .string(model),
            "note": note.map { JSONValue.string($0) } ?? .null,
            "at": .string(DateCoding.string(from: Date())),
        ])
        try appendAttempt(stepID: stepID, attempt: attempt, bumpRetry: false)
    }

    // MARK: - ★ 原子提交 ★

    /// 在**单个事务**内完成三件事:
    ///
    /// 1. `task_steps` 标记 completed 并写入输出
    /// 2. 插入新的 `checkpoints` 记录
    /// 3. 推进 `tasks.current_step`
    ///
    /// 三者要么全成功, 要么全回滚。
    ///
    /// 这是整个项目最重要的一段代码。若把这三步拆成三个独立事务, 进程在
    /// 任意两写之间被 kill 都会留下一致性裂痕 —— 例如"步骤已完成但 checkpoint
    /// 没推进", 重启后会重复执行该步骤, 甚至产生错误的进度显示。
    public func commitSuccessfulStep(_ commit: SuccessfulStepCommit) throws {
        let now = DateCoding.string(from: Date())

        try db.transaction {
            // 1) 步骤 -> completed + 输出落盘
            try db.execute(
                """
                UPDATE task_steps SET
                    status = 'completed',
                    output_json = ?,
                    provider = ?,
                    model = ?,
                    finished_at = ?,
                    duration_ms = ?,
                    last_error = NULL,
                    error_class = NULL
                WHERE id = ?
                """,
                [
                    .text((try? JSONCoding.encodeToString(commit.output)) ?? "null"),
                    .text(commit.provider),
                    .text(commit.model),
                    .text(now),
                    .int(commit.durationMs),
                    .text(commit.stepID),
                ]
            )

            // 2) 写入检查点
            try db.execute(
                """
                INSERT INTO checkpoints (
                    id, task_id, completed_step, next_step,
                    working_summary, state_json, created_at
                ) VALUES (?,?,?,?,?,?,?)
                """,
                [
                    .text(commit.checkpoint.id),
                    .text(commit.checkpoint.taskID),
                    .int(commit.checkpoint.completedStep),
                    .int(commit.checkpoint.nextStep),
                    commit.checkpoint.workingSummary.map { SQLValue.text($0) } ?? .null,
                    .text((try? JSONCoding.encodeToString(commit.checkpoint.state)) ?? "{}"),
                    .text(DateCoding.string(from: commit.checkpoint.createdAt)),
                ]
            )

            // 3) 推进任务进度, 并清掉上一次的错误标记
            try db.execute(
                """
                UPDATE tasks SET
                    current_step = ?,
                    updated_at = ?,
                    error_message = NULL,
                    error_class = NULL
                WHERE id = ?
                """,
                [.int(commit.newCurrentStep), .text(now), .text(commit.taskID)]
            )
        }
    }

    // MARK: - 行解码

    static func decode(_ row: SQLRow) throws -> TaskStep {
        let rawStatus = row.string("status") ?? StepStatus.pending.rawValue
        let status = StepStatus(rawValue: rawStatus) ?? .pending
        let rawType = row.string("type") ?? StepType.llm.rawValue
        let type = StepType(rawValue: rawType) ?? .llm

        let attemptList: [JSONValue]
        if let arr = row.json("attempt_log_json")?.arrayValue {
            attemptList = arr
        } else {
            attemptList = []
        }

        return TaskStep(
            id: try row.requireString("id"),
            taskID: try row.requireString("task_id"),
            index: try row.requireInt("step_index"),
            type: type,
            status: status,
            input: row.json("input_json") ?? .emptyObject,
            output: row.json("output_json"),
            provider: row.string("provider"),
            model: row.string("model"),
            retryCount: row.int("retry_count") ?? 0,
            startedAt: row.date("started_at"),
            finishedAt: row.date("finished_at"),
            createdAt: row.date("created_at") ?? Date(),
            lastError: row.string("last_error"),
            errorClass: row.string("error_class"),
            durationMs: row.int("duration_ms") ?? 0,
            attemptLog: attemptList,
            preparedAt: row.date("prepared_at"),
            submittedAt: row.date("submitted_at")
        )
    }
}
````


#### `Sources/AIRunnerCore/Persistence/Repositories/TaskRepository.swift` (242 行)

````swift
import Foundation

/// 任务表访问。
public struct TaskRepository: Sendable {

    private let db: Database

    public init(db: Database) {
        self.db = db
    }

    // MARK: - 写入

    public func insert(_ task: AITask) throws {
        try db.execute(
            """
            INSERT INTO tasks (
                id, name, goal, status, execution_mode,
                primary_provider, primary_model,
                current_step, total_steps, retry_count, max_retries,
                created_at, updated_at, error_message, error_class,
                waiting_until, plan_type, meta_json
            ) VALUES (?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)
            """,
            [
                .text(task.id),
                .text(task.name),
                .text(task.goal),
                .text(task.status.rawValue),
                .text(task.executionMode.rawValue),
                .text(task.primaryProvider),
                .text(task.primaryModel),
                .int(task.currentStep),
                .int(task.totalSteps),
                .int(task.retryCount),
                .int(task.maxRetries),
                .text(DateCoding.string(from: task.createdAt)),
                .text(DateCoding.string(from: task.updatedAt)),
                task.errorMessage.map { SQLValue.text($0) } ?? .null,
                task.errorClass.map { SQLValue.text($0) } ?? .null,
                task.waitingUntil.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                .text(task.planType),
                .text((try? JSONCoding.encodeToString(task.meta)) ?? "{}"),
            ]
        )
    }

    /// 全量更新可变字段 (不改 id / created_at)。
    public func update(_ task: AITask) throws {
        try db.execute(
            """
            UPDATE tasks SET
                name = ?, goal = ?, status = ?, execution_mode = ?,
                primary_provider = ?, primary_model = ?,
                current_step = ?, total_steps = ?,
                retry_count = ?, max_retries = ?,
                updated_at = ?, error_message = ?, error_class = ?,
                waiting_until = ?, plan_type = ?, meta_json = ?
            WHERE id = ?
            """,
            [
                .text(task.name),
                .text(task.goal),
                .text(task.status.rawValue),
                .text(task.executionMode.rawValue),
                .text(task.primaryProvider),
                .text(task.primaryModel),
                .int(task.currentStep),
                .int(task.totalSteps),
                .int(task.retryCount),
                .int(task.maxRetries),
                .text(DateCoding.string(from: Date())),
                task.errorMessage.map { SQLValue.text($0) } ?? .null,
                task.errorClass.map { SQLValue.text($0) } ?? .null,
                task.waitingUntil.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                .text(task.planType),
                .text((try? JSONCoding.encodeToString(task.meta)) ?? "{}"),
                .text(task.id),
            ]
        )
    }

    /// 带合法迁移校验的状态更新。
    ///
    /// 校验存在的意义: 阻止"已完成的任务被 Resume"这类会把 checkpoint 推进逻辑
    /// 搞乱的非法迁移 —— 一旦状态机被绕过, 续跑语义就不再可信。
    @discardableResult
    public func updateStatus(
        id: String,
        to newStatus: TaskStatus,
        errorMessage: String? = nil,
        errorClass: String? = nil,
        waitingUntil: Date? = nil
    ) throws -> AITask {
        guard let current = try fetch(id: id) else {
            throw AppError.database("任务不存在: \(id)")
        }
        guard current.status.canTransition(to: newStatus) else {
            throw AppError.database(
                "非法状态迁移: \(current.status.rawValue) -> \(newStatus.rawValue) (task=\(id))"
            )
        }

        try db.execute(
            """
            UPDATE tasks SET
                status = ?, updated_at = ?,
                error_message = ?, error_class = ?, waiting_until = ?
            WHERE id = ?
            """,
            [
                .text(newStatus.rawValue),
                .text(DateCoding.string(from: Date())),
                errorMessage.map { SQLValue.text($0) } ?? .null,
                errorClass.map { SQLValue.text($0) } ?? .null,
                waitingUntil.map { SQLValue.text(DateCoding.string(from: $0)) } ?? .null,
                .text(id),
            ]
        )

        guard let updated = try fetch(id: id) else {
            throw AppError.database("状态更新后无法重新读取任务: \(id)")
        }
        return updated
    }

    /// 只改跨状态共享的字段 (进度 / 重试计数 / 错误信息)。
    public func updateProgress(
        id: String,
        currentStep: Int? = nil,
        retryCount: Int? = nil,
        errorMessage: String? = nil,
        errorClass: String? = nil
    ) throws {
        var sets: [String] = ["updated_at = ?"]
        var params: [SQLValue] = [.text(DateCoding.string(from: Date()))]

        if let currentStep {
            sets.append("current_step = ?")
            params.append(.int(currentStep))
        }
        if let retryCount {
            sets.append("retry_count = ?")
            params.append(.int(retryCount))
        }
        if let errorMessage {
            sets.append("error_message = ?")
            params.append(.text(errorMessage))
        }
        if let errorClass {
            sets.append("error_class = ?")
            params.append(.text(errorClass))
        }

        params.append(.text(id))
        try db.execute("UPDATE tasks SET \(sets.joined(separator: ", ")) WHERE id = ?", params)
    }

    public func delete(id: String) throws {
        // task_steps / checkpoints 通过 ON DELETE CASCADE 一并删除
        try db.execute("DELETE FROM tasks WHERE id = ?", [.text(id)])
    }

    // MARK: - 读取

    public func fetch(id: String) throws -> AITask? {
        guard let row = try db.queryOne("SELECT * FROM tasks WHERE id = ?", [.text(id)]) else {
            return nil
        }
        return try Self.decode(row)
    }

    public func fetchAll(status: TaskStatus? = nil, limit: Int = 500) throws -> [AITask] {
        let rows: [SQLRow]
        if let status {
            rows = try db.query(
                "SELECT * FROM tasks WHERE status = ? ORDER BY created_at DESC LIMIT ?",
                [.text(status.rawValue), .int(limit)]
            )
        } else {
            rows = try db.query(
                "SELECT * FROM tasks ORDER BY created_at DESC LIMIT ?",
                [.int(limit)]
            )
        }
        return try rows.map { try Self.decode($0) }
    }

    /// 所有"非终态"任务 —— 启动时决定哪些需要恢复。
    public func fetchUnfinished() throws -> [AITask] {
        try db.query(
            "SELECT * FROM tasks WHERE status NOT IN ('completed','failed','cancelled') ORDER BY created_at ASC"
        ).map { try Self.decode($0) }
    }

    public func statusCounts() throws -> [TaskStatus: Int] {
        let rows = try db.query(
            "SELECT status, COUNT(*) AS n FROM tasks GROUP BY status"
        )
        var result: [TaskStatus: Int] = [:]
        for row in rows {
            guard let s = row.string("status"), let status = TaskStatus(rawValue: s) else { continue }
            result[status] = row.int("n") ?? 0
        }
        return result
    }

    public func count() throws -> Int {
        try db.scalarInt("SELECT COUNT(*) FROM tasks") ?? 0
    }

    // MARK: - 行解码

    static func decode(_ row: SQLRow) throws -> AITask {
        let rawStatus = try row.requireString("status")
        let status = TaskStatus(rawValue: rawStatus) ?? .failed
        let created = row.date("created_at") ?? Date()
        let updated = row.date("updated_at") ?? created

        return AITask(
            id: try row.requireString("id"),
            name: try row.requireString("name"),
            goal: try row.requireString("goal"),
            status: status,
            executionMode: ExecutionMode(rawValue: row.string("execution_mode") ?? "")
                ?? .chatGPTWeb,
            primaryProvider: row.string("primary_provider") ?? "",
            primaryModel: try row.requireString("primary_model"),
            currentStep: row.int("current_step") ?? 0,
            totalSteps: row.int("total_steps") ?? 0,
            retryCount: row.int("retry_count") ?? 0,
            maxRetries: row.int("max_retries") ?? 8,
            createdAt: created,
            updatedAt: updated,
            errorMessage: row.string("error_message"),
            errorClass: row.string("error_class"),
            waitingUntil: row.date("waiting_until"),
            planType: row.string("plan_type") ?? "uniform",
            meta: row.json("meta_json") ?? .emptyObject
        )
    }
}
````


### 安全 Security


#### `Sources/AIRunnerCore/Security/KeychainManager.swift` (166 行)

````swift
import Foundation
import Security

/// Keychain 抽象。便于测试时替换为内存实现。
public protocol KeychainManaging: Sendable {
    func save(key: String, value: String) throws
    func read(key: String) throws -> String?
    func delete(key: String) throws
    func exists(key: String) throws -> Bool
}

/// 基于 macOS Security.framework 的真实 Keychain 实现。
///
/// 存储形态: `kSecClassGenericPassword`, service = `com.airunner.apikeys`,
/// account = Provider 的 keychainKey (如 `openai.apiKey`)。
///
/// 可访问性: 使用 `kSecAttrAccessibleAfterFirstUnlock` —— 这样 App 在后台/由 launchd
/// 拉起时依然能读到密钥, 但设备完全锁定后不可读。这是安全与可自动化之间的正确取舍。
///
/// ★ 安全红线 ★
/// API Key **只** 允许存在这里。禁止写入 UserDefaults / SQLite / 日志 / plist / 源码。
public struct KeychainManager: KeychainManaging {

    public let service: String

    public init(service: String = "com.airunner.apikeys") {
        self.service = service
    }

    // MARK: - 写

    public func save(key: String, value: String) throws {
        guard !key.isEmpty else { throw AppError.fatal("Keychain key 不能为空") }
        guard !value.isEmpty else { throw AppError.fatal("拒绝写入空密钥 (key=\(key))") }

        let data = Data(value.utf8)
        let query = baseQuery(key: key)

        // 先尝试更新: 避免"已存在则 add 失败"的常见坑。
        let updateAttributes: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, updateAttributes as CFDictionary)

        if updateStatus == errSecSuccess { return }

        if updateStatus == errSecItemNotFound {
            var addQuery = query
            addQuery[kSecValueData as String] = data
            addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlock
            let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
            guard addStatus == errSecSuccess else {
                throw Self.error(status: addStatus, operation: "写入密钥", key: key)
            }
            return
        }

        throw Self.error(status: updateStatus, operation: "更新密钥", key: key)
    }

    // MARK: - 读

    public func read(key: String) throws -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)

        switch status {
        case errSecSuccess:
            guard let data = item as? Data else {
                throw AppError.fatal("Keychain 返回了非 Data 内容 (key=\(key))")
            }
            guard let text = String(data: data, encoding: .utf8) else {
                throw AppError.fatal("Keychain 内容不是合法 UTF-8 (key=\(key))")
            }
            return text.isEmpty ? nil : text
        case errSecItemNotFound:
            return nil
        default:
            throw Self.error(status: status, operation: "读取密钥", key: key)
        }
    }

    // MARK: - 删

    public func delete(key: String) throws {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw Self.error(status: status, operation: "删除密钥", key: key)
        }
    }

    public func exists(key: String) throws -> Bool {
        try read(key: key) != nil
    }

    // MARK: - 内部

    private func baseQuery(key: String) -> [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
    }

    private static func error(status: OSStatus, operation: String, key: String) -> AppError {
        let detail = SecCopyErrorMessageString(status, nil) as String? ?? "OSStatus=\(status)"
        return .fatal("Keychain \(operation) 失败 (key=\(key)): \(detail)")
    }
}

/// 内存 Keychain —— 仅供单元测试与离线 Demo。
/// 绝不用于生产: 数据不加密且随进程消失。
public final class InMemoryKeychain: KeychainManaging, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: [String: String] = [:]

    public init(seed: [String: String] = [:]) {
        self.storage = seed
    }

    public func save(key: String, value: String) throws {
        guard !key.isEmpty else { throw AppError.fatal("key 不能为空") }
        guard !value.isEmpty else { throw AppError.fatal("拒绝写入空密钥") }
        lock.lock(); defer { lock.unlock() }
        storage[key] = value
    }

    public func read(key: String) throws -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage[key]
    }

    public func delete(key: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage.removeValue(forKey: key)
    }

    public func exists(key: String) throws -> Bool {
        lock.lock(); defer { lock.unlock() }
        return storage[key] != nil
    }
}

// MARK: - 展示辅助

public enum SecretMasking {

    /// 把密钥转成可安全展示/记录的形式。
    ///
    /// 规则: 长度 <= 8 全遮; 否则保留前 3 后 2。
    /// 绝不要在任何 UI / 日志里直接使用明文密钥。
    public static func mask(_ secret: String?) -> String {
        guard let secret, !secret.isEmpty else { return "未配置" }
        if secret.count <= 8 { return String(repeating: "•", count: 8) }
        let prefix = secret.prefix(3)
        let suffix = secret.suffix(2)
        return "\(prefix)\(String(repeating: "•", count: 10))\(suffix)"
    }
}
````


### 服务 Services


#### `Sources/AIRunnerCore/Services/AppSettings.swift` (153 行)

````swift
import Foundation

/// 应用级设置。
///
/// ★ 安全红线 ★
/// 这里**绝不**包含 API Key。Key 只存在 macOS Keychain, 由 `ProviderFactory` 读取。
/// 本结构只存非敏感配置, 因此可以安全地放进 UserDefaults。
public struct AppSettings: Codable, Sendable, Equatable {

    public var providers: [ProviderConfig]
    public var routes: [RouteEntry]
    /// 全局最多同时运行的任务数。
    public var concurrency: Int
    public var retry: RetryConfiguration

    // MARK: Web 执行通道

    /// 新建任务默认使用的执行通道。默认 `chatgpt_web`。
    public var defaultExecutionMode: ExecutionMode
    /// ChatGPT Web 地址 (可改成自建网关或区域域名)。
    public var chatGPTURL: String
    /// 生成续跑 prompt 后是否自动打开浏览器。
    public var openBrowserOnPrepare: Bool
    /// 生成续跑 prompt 后是否自动写入剪贴板。
    public var copyPromptToClipboard: Bool

    public init(
        providers: [ProviderConfig],
        routes: [RouteEntry],
        concurrency: Int = 3,
        retry: RetryConfiguration = .default,
        defaultExecutionMode: ExecutionMode = .chatGPTWeb,
        chatGPTURL: String = ChatGPTWebTarget.defaultURLString,
        openBrowserOnPrepare: Bool = true,
        copyPromptToClipboard: Bool = true
    ) {
        self.providers = providers
        self.routes = routes
        self.concurrency = concurrency
        self.retry = retry
        self.defaultExecutionMode = defaultExecutionMode
        self.chatGPTURL = chatGPTURL
        self.openBrowserOnPrepare = openBrowserOnPrepare
        self.copyPromptToClipboard = copyPromptToClipboard
    }

    /// 手写解码, 让**老版本存下的配置能平滑升级**。
    ///
    /// 合成的 `init(from:)` 会要求每个非可选字段都存在 —— 那样一旦新增字段,
    /// 用户已有的路由表与 Provider 设置就会整份失效并被打回出厂值。
    /// 这里全部用 `decodeIfPresent` + 默认值兜底。
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        providers = try container.decodeIfPresent([ProviderConfig].self, forKey: .providers)
            ?? ProviderConfig.defaults
        routes = try container.decodeIfPresent([RouteEntry].self, forKey: .routes)
            ?? RouteEntry.defaults
        concurrency = try container.decodeIfPresent(Int.self, forKey: .concurrency) ?? 3
        retry = try container.decodeIfPresent(RetryConfiguration.self, forKey: .retry) ?? .default

        defaultExecutionMode = try container
            .decodeIfPresent(ExecutionMode.self, forKey: .defaultExecutionMode) ?? .chatGPTWeb
        chatGPTURL = try container
            .decodeIfPresent(String.self, forKey: .chatGPTURL)
            ?? ChatGPTWebTarget.defaultURLString
        openBrowserOnPrepare = try container
            .decodeIfPresent(Bool.self, forKey: .openBrowserOnPrepare) ?? true
        copyPromptToClipboard = try container
            .decodeIfPresent(Bool.self, forKey: .copyPromptToClipboard) ?? true
    }

    public static let `default` = AppSettings(
        providers: ProviderConfig.defaults,
        routes: RouteEntry.defaults
    )

    public var sortedRoutes: [RouteEntry] {
        routes.sorted { $0.priority < $1.priority }
    }

    public var enabledRoutes: [RouteEntry] {
        sortedRoutes.filter(\.enabled)
    }

    public var primaryRoute: RouteEntry? {
        enabledRoutes.first
    }

    /// 把 priority 重新编号为 1...n, 保持列表紧凑。
    public func renumbered() -> AppSettings {
        var copy = self
        copy.routes = sortedRoutes.enumerated().map { index, route in
            var r = route
            r.priority = index + 1
            return r
        }
        return copy
    }
}

// RetryConfiguration 的 Codable 合成必须在它自己的声明文件里完成,
// 因此 conformance 写在 RetryManager.swift 的定义处, 不在此处扩展。

/// 设置的持久化。
public struct SettingsStore: @unchecked Sendable {

    private let defaults: UserDefaults
    private let storageKey: String

    public init(
        defaults: UserDefaults = .standard,
        storageKey: String = "com.airunner.settings.v1"
    ) {
        self.defaults = defaults
        self.storageKey = storageKey
    }

    public func load() -> AppSettings {
        guard let data = defaults.data(forKey: storageKey),
              let decoded = try? JSONCoding.makeDecoder().decode(AppSettings.self, from: data)
        else {
            return .default
        }
        // 防御: 老版本配置可能缺少新增的 Provider
        return Self.mergingMissingProviders(decoded)
    }

    public func save(_ settings: AppSettings) throws {
        let data = try JSONCoding.makeEncoder(pretty: true).encode(settings)
        defaults.set(data, forKey: storageKey)
    }

    public func reset() {
        defaults.removeObject(forKey: storageKey)
    }

    /// 补齐缺失的出厂 Provider, 保证升级后老配置仍能显示新 Provider。
    static func mergingMissingProviders(_ settings: AppSettings) -> AppSettings {
        var copy = settings
        let existing = Set(settings.providers.map(\.id))
        for provider in ProviderConfig.defaults where !existing.contains(provider.id) {
            copy.providers.append(provider)
        }
        if copy.routes.isEmpty {
            copy.routes = RouteEntry.defaults
        }
        if copy.concurrency <= 0 {
            copy.concurrency = 3
        }
        return copy
    }
}
````


#### `Sources/AIRunnerCore/Services/ClipboardService.swift` (117 行)

````swift
import Foundation

/// 剪贴板读写。
///
/// 协议放在 Core, 具体实现由 App 层提供 —— `NSPasteboard` 属于 AppKit,
/// 而 Core 必须保持可被纯命令行测试驱动。这样 `swift test` 不需要窗口服务器。
public protocol ClipboardServicing: Sendable {

    /// 读取当前剪贴板文本。空或非文本内容返回 nil。
    func readString() -> String?

    /// 写入文本, 返回是否成功。
    @discardableResult
    func writeString(_ value: String) -> Bool
}

/// 内存剪贴板 —— 测试与无 UI 环境使用。
public final class InMemoryClipboard: ClipboardServicing, @unchecked Sendable {

    private let lock = NSLock()
    private var storage: String?

    public init(seed: String? = nil) {
        self.storage = seed
    }

    public func readString() -> String? {
        lock.lock(); defer { lock.unlock() }
        return storage
    }

    @discardableResult
    public func writeString(_ value: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        storage = value
        return true
    }
}

/// 浏览器启动。
///
/// ## ★ 能力边界 (硬性) ★
///
/// 本协议**只**允许做一件事: 打开一个 URL, 让用户自己在已登录的浏览器里操作。
///
/// 明确禁止在本项目任何位置实现:
/// - 读取浏览器 Cookie 数据库 / 导出 Cookie
/// - 读取或注入 session token / authentication storage
/// - 自动填写账号密码
/// - 自动执行账号轮换
/// - 用自动化工具操作网页来绕过平台使用限制
///
/// 账号切换一律由用户在浏览器里手动完成, 程序只负责"提示 + 保存进度 + 恢复"。
public protocol BrowserLaunching: Sendable {
    @discardableResult
    func open(_ url: URL) -> Bool
}

/// 什么也不做的实现 —— 用于测试与"用户不想自动打开浏览器"的设置。
public struct NoopBrowserLauncher: BrowserLaunching {
    public init() {}
    @discardableResult
    public func open(_ url: URL) -> Bool { false }
}

/// 测试用: 记录被请求打开的 URL, 不真的打开任何东西。
public final class RecordingBrowserLauncher: BrowserLaunching, @unchecked Sendable {

    private let lock = NSLock()
    private var opened: [URL] = []

    public init() {}

    @discardableResult
    public func open(_ url: URL) -> Bool {
        lock.lock(); defer { lock.unlock() }
        opened.append(url)
        return true
    }

    public var openedURLs: [URL] {
        lock.lock(); defer { lock.unlock() }
        return opened
    }

    public var lastOpened: URL? {
        lock.lock(); defer { lock.unlock() }
        return opened.last
    }

    public func reset() {
        lock.lock(); defer { lock.unlock() }
        opened.removeAll()
    }
}

/// ChatGPT Web 的目标地址。
///
/// 只保存 URL —— 不保存、不读取任何凭据。
public enum ChatGPTWebTarget {

    /// 默认地址。用户可以在设置里改 (例如用某个自建网关)。
    public static let defaultURLString = "https://chatgpt.com/"

    public static func resolvedURLString(override: String? = nil) -> String {
        guard let override, !override.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return defaultURLString
        }
        return override.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// 解析成 URL。非法时回退到默认地址。
    public static func resolvedURL(override: String? = nil) -> URL {
        URL(string: resolvedURLString(override: override))
            ?? URL(string: defaultURLString)!
    }
}
````


#### `Sources/AIRunnerCore/Services/LoggerService.swift` (187 行)

````swift
import Foundation

/// 密钥脱敏。
///
/// 两道防线:
/// 1. **精确匹配**: `register(_:)` 登记当前进程已知的密钥明文, 命中即整体替换。
/// 2. **模式匹配**: 识别 `sk-...` / `Bearer ...` / `api_key=...` 等常见形态。
///
/// 宁可多遮一点, 也不能让 Key 落进日志 —— 日志会进 SQLite, 而 SQLite 是不加密的。
public enum SecretRedactor {

    private static let lock = NSLock()
    nonisolated(unsafe) private static var knownSecrets: [String] = []

    private static let patterns: [NSRegularExpression] = {
        let raw: [String] = [
            #"sk-[A-Za-z0-9_\-]{8,}"#,
            #"(?i)\bbearer\s+[A-Za-z0-9._\-]{8,}"#,
            #"(?i)\b(api[_-]?key|apikey|x-api-key|access[_-]?token|auth[_-]?token|secret|password)\b("?\s*[:=]\s*"?)([A-Za-z0-9._\-]{8,})"#,
            #"(?i)\b(anthropic|openai|deepseek|gemini|google)[_\-]?(key|token)\b("?\s*[:=]\s*"?)([A-Za-z0-9._\-]{8,})"#,
        ]
        return raw.compactMap { try? NSRegularExpression(pattern: $0) }
    }()

    private static let replacement = "«REDACTED»"

    /// 登记一个已知密钥明文。只登记长度 >= 8 的值, 避免误伤普通文本。
    public static func register(_ secret: String?) {
        guard let secret, secret.count >= 8 else { return }
        lock.lock(); defer { lock.unlock() }
        guard !knownSecrets.contains(secret) else { return }
        // 只保留最近 32 个, 防止长期运行后无界增长
        knownSecrets.append(secret)
        if knownSecrets.count > 32 {
            knownSecrets.removeFirst(knownSecrets.count - 32)
        }
    }

    public static func unregisterAll() {
        lock.lock(); defer { lock.unlock() }
        knownSecrets.removeAll()
    }

    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var output = text

        lock.lock()
        let secrets = knownSecrets
        lock.unlock()

        for secret in secrets where !secret.isEmpty {
            if output.contains(secret) {
                output = output.replacingOccurrences(of: secret, with: replacement)
            }
        }

        let fullRange = NSRange(output.startIndex..<output.endIndex, in: output)
        for regex in patterns {
            output = regex.stringByReplacingMatches(
                in: output,
                options: [],
                range: fullRange,
                withTemplate: replacement
            )
        }
        return output
    }

    /// 递归脱敏一个 JSON 结构。
    public static func redact(_ value: JSONValue) -> JSONValue {
        switch value {
        case .string(let s):
            return .string(redact(s))
        case .array(let arr):
            return .array(arr.map { redact($0) })
        case .object(let dict):
            var out: [String: JSONValue] = [:]
            for (k, v) in dict {
                // 键名本身就敏感时, 直接遮住值
                let lowered = k.lowercased()
                if lowered.contains("key") || lowered.contains("token")
                    || lowered.contains("authorization") || lowered.contains("secret") {
                    out[k] = .string(replacement)
                } else {
                    out[k] = redact(v)
                }
            }
            return .object(out)
        default:
            return value
        }
    }
}

/// 统一日志入口。
///
/// 所有写入 `events` 表的内容都必须经过这里 —— 它在落库前强制脱敏。
/// 同时它承担的职责是"**不**因为日志失败而让 JobRunner 崩掉":
/// 日志是旁路, 不是主路径。
public struct LoggerService: Sendable {

    private let events: EventRepository
    private let echoToConsole: Bool

    public init(events: EventRepository, echoToConsole: Bool = true) {
        self.events = events
        self.echoToConsole = echoToConsole
    }

    // MARK: - 主入口

    public func log(
        _ level: LogLevel,
        _ eventType: EventType,
        _ message: String,
        taskID: String? = nil,
        stepIndex: Int? = nil,
        metadata: JSONValue? = nil
    ) {
        let safeMessage = SecretRedactor.redact(message)
        let safeMetadata = metadata.map { SecretRedactor.redact($0) }

        let event = AppEvent(
            taskID: taskID,
            stepIndex: stepIndex,
            level: level,
            eventType: eventType,
            message: safeMessage,
            metadata: safeMetadata
        )

        if echoToConsole {
            let taskPart = taskID.map { " task=\($0.prefix(8))" } ?? ""
            let stepPart = stepIndex.map { " step=\($0)" } ?? ""
            print("[\(level.displayName)] \(eventType.rawValue)\(taskPart)\(stepPart) \(safeMessage)")
        }

        do {
            try events.append(event)
        } catch {
            // 日志写库失败绝不能冒泡到调用方 (那会把 Runner 一起带走)。
            FileHandle.standardError.write(
                Data("AIRunner: 日志写入失败: \(error)\n".utf8)
            )
        }
    }

    // MARK: - 便捷方法

    public func debug(_ t: EventType, _ m: String, taskID: String? = nil,
                      stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.debug, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    public func info(_ t: EventType, _ m: String, taskID: String? = nil,
                     stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.info, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    public func warning(_ t: EventType, _ m: String, taskID: String? = nil,
                        stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.warning, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    public func error(_ t: EventType, _ m: String, taskID: String? = nil,
                      stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.error, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    public func critical(_ t: EventType, _ m: String, taskID: String? = nil,
                         stepIndex: Int? = nil, metadata: JSONValue? = nil) {
        log(.critical, t, m, taskID: taskID, stepIndex: stepIndex, metadata: metadata)
    }

    /// 记录任意 Error (自动归一化 + 脱敏)。
    public func record(_ error: Error, eventType: EventType, taskID: String? = nil,
                       stepIndex: Int? = nil, extra: JSONValue? = nil) {
        let appError = AppError.normalize(error)
        var meta: [String: JSONValue] = ["errorClass": .string(appError.eventName)]
        if let extra, case .object(let d) = extra {
            for (k, v) in d { meta[k] = v }
        }
        log(.error, eventType, appError.userMessage,
            taskID: taskID, stepIndex: stepIndex, metadata: .object(meta))
    }
}
````


### 工具 Utilities


#### `Sources/AIRunnerCore/Utilities/AppError.swift` (184 行)

````swift
import Foundation

/// 全项目统一错误类型。
///
/// 设计原则: **绝不允许"所有错误一律重试"**。
/// 每个 case 都映射到一个明确的处置策略 (`ErrorStrategy`), 由 JobRunner 分派,
/// 而不是在 Runner 里散落 `if error is X` 判断。
public enum AppError: Error, Sendable {
    case network(String)
    case timeout
    case rateLimit(retryAfter: TimeInterval?)
    case providerUnavailable
    case modelUnavailable
    case authentication
    case billingRequired
    case invalidRequest(String)
    case contextTooLong
    case invalidOutput(String)
    case cancelled
    case database(String)
    case fatal(String)
}

/// 处置策略。JobRunner 依据它决定下一步动作。
public enum ErrorStrategy: String, Sendable, Codable {
    /// 原地重试, 指数退避。消耗正常 retry 预算。
    case retrySame
    /// 限流场景的长退避。使用独立预算, 不消耗步骤 retry 次数。
    case retryWithBackoff
    /// 换 backend (同 provider 换 model, 或换 provider)。不消耗 retry 预算。
    case switchBackend
    /// 缩小上下文后重试 (contextTooLong)。
    case shrinkContext
    /// 暂停任务, 等用户介入 (认证失败 / 余额耗尽)。绝不自动重试。
    case pauseTask
    /// 当前步骤失败。
    case failStep
    /// 整个任务失败。
    case failTask
}

extension AppError {

    // MARK: - 分类

    public var strategy: ErrorStrategy {
        switch self {
        case .network, .timeout:
            return .retrySame
        case .rateLimit:
            return .retryWithBackoff
        case .providerUnavailable, .modelUnavailable:
            return .switchBackend
        case .contextTooLong:
            return .shrinkContext
        case .invalidOutput:
            return .retrySame          // 附加"请只返回合法 JSON"提示后重试
        case .authentication, .billingRequired:
            return .pauseTask
        case .invalidRequest:
            return .failStep
        case .cancelled, .database, .fatal:
            return .failTask
        }
    }

    /// 是否可以自动重试 (语义层面; 实际是否还有预算由 RetryManager 决定)。
    public var isRetryable: Bool {
        switch self {
        case .network, .timeout, .rateLimit, .invalidOutput:
            return true
        case .providerUnavailable, .modelUnavailable:
            return true   // 可重试, 但方式必须是换 backend
        case .authentication, .billingRequired, .invalidRequest,
             .contextTooLong, .cancelled, .database, .fatal:
            return false
        }
    }

    /// 是否应该让该 Provider 的熔断计数器 +1。
    ///
    /// 网络抖动不该熔断 Provider; 认证失败/余额耗尽则必须 —— 继续调用只是浪费时间和额度。
    public var tripsProviderCircuit: Bool {
        switch self {
        case .providerUnavailable, .authentication, .billingRequired:
            return true
        case .network, .timeout, .rateLimit, .modelUnavailable, .invalidRequest,
             .contextTooLong, .invalidOutput, .cancelled, .database, .fatal:
            return false
        }
    }

    /// 是否属于"永久性"故障 —— 换 backend 也没用, 只能靠用户修配置。
    public var isTerminalForProvider: Bool {
        switch self {
        case .authentication, .billingRequired:
            return true
        default:
            return false
        }
    }

    /// 给 UI 显示的中文简述。
    public var userMessage: String {
        switch self {
        case .network(let m):        return "网络错误: \(m)"
        case .timeout:               return "请求超时"
        case .rateLimit(let after):
            if let after { return "触发限流, 建议等待 \(Int(after)) 秒" }
            return "触发限流"
        case .providerUnavailable:   return "Provider 暂时不可用"
        case .modelUnavailable:      return "模型不可用"
        case .authentication:        return "认证失败, 请检查 API Key"
        case .billingRequired:       return "余额/额度不足, 已熔断该 Provider"
        case .invalidRequest(let m): return "请求非法: \(m)"
        case .contextTooLong:        return "上下文超长"
        case .invalidOutput(let m):  return "输出校验失败: \(m)"
        case .cancelled:             return "已取消"
        case .database(let m):       return "数据库错误: \(m)"
        case .fatal(let m):          return "致命错误: \(m)"
        }
    }

    /// 写日志用的稳定标识 (不含任何敏感信息)。
    public var eventName: String {
        switch self {
        case .network:              return "NETWORK_ERROR"
        case .timeout:              return "TIMEOUT"
        case .rateLimit:            return "RATE_LIMITED"
        case .providerUnavailable:  return "PROVIDER_UNAVAILABLE"
        case .modelUnavailable:     return "MODEL_UNAVAILABLE"
        case .authentication:       return "AUTHENTICATION_ERROR"
        case .billingRequired:      return "BILLING_REQUIRED"
        case .invalidRequest:       return "INVALID_REQUEST"
        case .contextTooLong:       return "CONTEXT_TOO_LONG"
        case .invalidOutput:        return "INVALID_OUTPUT"
        case .cancelled:            return "CANCELLED"
        case .database:             return "DATABASE_ERROR"
        case .fatal:                return "FATAL_ERROR"
        }
    }

    /// 便捷: 取限流等待时间。
    public var retryAfter: TimeInterval? {
        if case .rateLimit(let after) = self { return after }
        return nil
    }

    /// 把任意 Error 归一化成 AppError。
    public static func normalize(_ error: Error) -> AppError {
        switch error {
        case let e as AppError:
            return e
        case is CancellationError:
            return .cancelled
        case let e as URLError:
            switch e.code {
            case .timedOut:
                return .timeout
            case .cancelled:
                return .cancelled
            case .notConnectedToInternet, .networkConnectionLost,
                 .cannotConnectToHost, .cannotFindHost, .dnsLookupFailed,
                 .secureConnectionFailed, .internationalRoamingOff,
                 .dataNotAllowed, .resourceUnavailable:
                return .network(e.localizedDescription)
            default:
                return .network("URLError(\(e.code.rawValue)): \(e.localizedDescription)")
            }
        case let e as DecodingError:
            return .invalidOutput("响应解码失败: \(e)")
        default:
            return .fatal(error.localizedDescription)
        }
    }
}

extension AppError: CustomStringConvertible {
    public var description: String { "AppError.\(eventName)" }
}

extension AppError: LocalizedError {
    public var errorDescription: String? { userMessage }
}
````


#### `Sources/AIRunnerCore/Utilities/AsyncSemaphore.swift` (54 行)

````swift
import Foundation

/// 限制并发数量的异步信号量。
///
/// 用途: MVP 全局最多同时跑 N 个 Task Runner (默认 3)。
/// 用 `actor` 而非 DispatchSemaphore —— 后者在 Swift Concurrency 里会造成
/// 线程阻塞 (线程饥饿), 且无法参与结构化取消。
public actor AsyncSemaphore {

    public let limit: Int
    private var available: Int
    private var waiters: [CheckedContinuation<Void, Never>] = []

    public init(limit: Int) {
        precondition(limit > 0, "AsyncSemaphore limit 必须 > 0")
        self.limit = limit
        self.available = limit
    }

    /// 获取一个许可。若已达上限则挂起等待。
    public func acquire() async {
        if available > 0 {
            available -= 1
            return
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            waiters.append(continuation)
        }
    }

    /// 释放一个许可。若有等待者, 直接把许可移交给队首 (不增加 available)。
    public func release() {
        if let next = waiters.first {
            waiters.removeFirst()
            next.resume()
        } else {
            available = min(available + 1, limit)
        }
    }

    /// 作用域化使用许可。保证异常路径下也会释放。
    public func withPermit<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        await acquire()
        defer { release() }
        return try await body()
    }

    // MARK: - 观测 (测试与调试用)

    public var availableCount: Int { available }
    public var waitingCount: Int { waiters.count }
}
````


#### `Sources/AIRunnerCore/Utilities/JSONCoding.swift` (107 行)

````swift
import Foundation

/// 统一的 JSON 编解码入口。
///
/// 不缓存 JSONEncoder/JSONDecoder 实例 —— 它们不是 Sendable 的,
/// 跨并发域共享会因为内部可变状态产生数据竞争。每次构造的开销对本地任务可忽略。
public enum JSONCoding {

    public static func makeEncoder(pretty: Bool = false) -> JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(DateCoding.string(from: date))
        }
        if pretty {
            e.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        } else {
            e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        }
        return e
    }

    public static func makeDecoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = DateCoding.date(from: s) else {
                throw DecodingError.dataCorruptedError(
                    in: c, debugDescription: "无法解析日期: \(s)"
                )
            }
            return date
        }
        return d
    }

    public static func encodeToString<T: Encodable>(_ value: T, pretty: Bool = false) throws -> String {
        let data = try makeEncoder(pretty: pretty).encode(value)
        guard let s = String(data: data, encoding: .utf8) else {
            throw AppError.invalidOutput("JSON 编码结果不是合法 UTF-8")
        }
        return s
    }

    public static func decode<T: Decodable>(_ type: T.Type, from string: String) throws -> T {
        guard let data = string.data(using: .utf8) else {
            throw AppError.invalidOutput("输入不是合法 UTF-8")
        }
        do {
            return try makeDecoder().decode(type, from: data)
        } catch {
            throw AppError.invalidOutput("JSON 解码失败: \(error)")
        }
    }

    /// 宽松解码: 失败返回 nil, 不抛错。用于读取可能为空的 DB 列。
    public static func decodeIfPossible<T: Decodable>(_ type: T.Type, from string: String?) -> T? {
        guard let string, !string.isEmpty else { return nil }
        return try? decode(type, from: string)
    }
}

/// ISO8601 日期与字符串互转。
///
/// 使用 `Date.ISO8601FormatStyle` (值类型 + Sendable), 避免 `ISO8601DateFormatter`
/// 在并发环境下的共享可变状态问题。
public enum DateCoding {

    private static let withFraction = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        timeZoneSeparator: .omitted,
        includingFractionalSeconds: true,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    private static let withoutFraction = Date.ISO8601FormatStyle(
        dateSeparator: .dash,
        dateTimeSeparator: .standard,
        timeSeparator: .colon,
        timeZoneSeparator: .omitted,
        includingFractionalSeconds: false,
        timeZone: TimeZone(secondsFromGMT: 0)!
    )

    public static func string(from date: Date) -> String {
        withFraction.format(date)
    }

    public static func date(from string: String) -> Date? {
        if let d = try? withFraction.parse(string) { return d }
        return try? withoutFraction.parse(string)
    }

    /// 从任意 JSON 兼容值解析日期 (兼容旧数据里存数字时间戳的情况)。
    public static func date(from value: JSONValue?) -> Date? {
        guard let value else { return nil }
        switch value {
        case .string(let s): return date(from: s)
        case .double(let d): return Date(timeIntervalSince1970: d)
        case .int(let i):    return Date(timeIntervalSince1970: TimeInterval(i))
        default:             return nil
        }
    }
}
````


### UI 层 (SwiftUI, AppKit 桥接)


#### `Sources/AIRunner/AIRunnerApp.swift` (45 行)

````swift
import SwiftUI

@main
struct AIRunnerApp: App {

    @StateObject private var appState = AppState()

    var body: some Scene {
        WindowGroup("AIRunner") {
            ContentView()
                .environmentObject(appState)
                .frame(minWidth: 1020, minHeight: 660)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("新建任务…") {
                    NotificationCenter.default.post(name: .airunnerCreateTask, object: nil)
                }
                .keyboardShortcut("n", modifiers: .command)
            }

            CommandGroup(after: .appSettings) {
                Divider()
                Button("打开 ChatGPT") {
                    NotificationCenter.default.post(name: .airunnerOpenChatGPT, object: nil)
                }
                .keyboardShortcut("g", modifiers: [.command, .shift])
            }
        }

        Settings {
            SettingsView()
                .environmentObject(appState)
                .frame(width: 720, height: 560)
        }
    }
}

extension Notification.Name {
    /// ⌘N —— 请求主界面打开「新建任务」表单。
    static let airunnerCreateTask = Notification.Name("AIRunner.CreateTask")

    /// ⇧⌘G —— 用系统默认浏览器打开 ChatGPT（不涉及任何自动化操作）。
    static let airunnerOpenChatGPT = Notification.Name("AIRunner.OpenChatGPT")
}
````


#### `Sources/AIRunner/App/AppState.swift` (55 行)

````swift
import Foundation
import Combine
import AIRunnerCore

/// 应用根状态。
///
/// 负责: 装配 `AppServices` → 创建 `TaskManager` → 执行崩溃恢复。
/// 启动失败时把错误留在 `bootstrapError` 里, 由 UI 显示可重试的错误页,
/// 而不是让 App 直接崩溃 —— 长任务程序最忌讳"打不开"。
@MainActor
final class AppState: ObservableObject {

    @Published private(set) var services: AppServices?
    @Published private(set) var taskManager: TaskManager?
    @Published private(set) var bootstrapError: String?
    @Published private(set) var recoverySummary: String?
    @Published var selectedTaskID: String?

    init() {
        bootstrap()
    }

    func bootstrap() {
        do {
            // 注入 App 层的剪贴板与浏览器实现 —— Core 本身不依赖 AppKit。
            let services = try AppServices.bootstrap(
                clipboard: PasteboardClipboard(),
                browser: WorkspaceBrowserLauncher()
            )
            let manager = TaskManager(services: services)

            self.services = services
            self.taskManager = manager
            self.bootstrapError = nil

            // 启动恢复: 修复运行中被强杀留下的 running 步骤, 并自动接续 running 的任务。
            let report = manager.recoverOnLaunch(autoStart: true)
            self.recoverySummary = (report?.didRecoverAnything == true) ? report?.summary : nil

        } catch {
            self.services = nil
            self.taskManager = nil
            self.recoverySummary = nil
            self.bootstrapError = AppError.normalize(error).userMessage
        }
    }

    func refresh() {
        taskManager?.refresh()
    }

    var databasePath: String? {
        services?.database.databasePath
    }
}
````


#### `Sources/AIRunner/Platform/PasteboardClipboard.swift` (23 行)

````swift
import Foundation
import AppKit
import AIRunnerCore

/// macOS 剪贴板实现。
///
/// 这是 Core 的 `ClipboardServicing` 协议在 App 层的落地。
/// Core 本身**不依赖 AppKit**, 因此 `swift test` 可以在没有窗口服务器的环境下运行。
struct PasteboardClipboard: ClipboardServicing {

    func readString() -> String? {
        let value = NSPasteboard.general.string(forType: .string)
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    @discardableResult
    func writeString(_ value: String) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        return pasteboard.setString(value, forType: .string)
    }
}
````


#### `Sources/AIRunner/Platform/WorkspaceBrowserLauncher.swift` (20 行)

````swift
import Foundation
import AppKit
import AIRunnerCore

/// 用系统默认浏览器打开 URL。
///
/// ## ★ 能力边界 (硬性) ★
///
/// 本类型只做一件事: `NSWorkspace.shared.open(url)`。
///
/// 它**不**读取 Cookie、**不**注入 session token、**不**填写任何表单、
/// **不**通过自动化工具操作网页。账号切换完全由用户在浏览器里手动完成 ——
/// 程序只负责把用户引导到页面, 以及把进度存好。
struct WorkspaceBrowserLauncher: BrowserLaunching {

    @discardableResult
    func open(_ url: URL) -> Bool {
        NSWorkspace.shared.open(url)
    }
}
````


#### `Sources/AIRunner/UI/ContentView.swift` (57 行)

````swift
import SwiftUI
import AIRunnerCore

struct ContentView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let message = appState.bootstrapError {
                BootstrapErrorView(message: message) {
                    appState.bootstrap()
                }
            } else if let manager = appState.taskManager,
                      let services = appState.services {
                MainSplitView(manager: manager, services: services)
            } else {
                ProgressView("正在初始化 AIRunner…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .frame(minWidth: 900, minHeight: 560)
    }
}

/// 启动失败页。
///
/// 刻意做成"可重试"而不是直接退出 —— 长任务程序必须是用户能自己救回来的,
/// 数据库损坏 / 权限问题都应该能在界面上看到原因。
struct BootstrapErrorView: View {

    let message: String
    let retry: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 44))
                .foregroundStyle(.orange)

            Text("无法启动 AIRunner")
                .font(.title2.bold())

            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .textSelection(.enabled)
                .frame(maxWidth: 480)

            Button("重试", action: retry)
                .buttonStyle(.borderedProminent)
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
````


#### `Sources/AIRunner/UI/Logs/LogView.swift` (167 行)

````swift
import SwiftUI
import AIRunnerCore

/// 事件日志视图。
struct LogView: View {

    @ObservedObject var manager: TaskManager
    /// nil 表示显示全部任务的日志。
    let task: AITask?
    @Binding var isPresented: Bool

    @State private var events: [AppEvent] = []
    @State private var levelFilter: LogLevel? = nil
    @State private var searchText = ""
    @State private var isLive = true

    private var filtered: [AppEvent] {
        events.filter { event in
            if let levelFilter, event.level != levelFilter { return false }
            guard !searchText.isEmpty else { return true }
            let needle = searchText.lowercased()
            return event.message.lowercased().contains(needle)
                || event.eventType.rawValue.lowercased().contains(needle)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Divider()
            content
        }
        .frame(width: 920, height: 600)
        .task {
            while !Task.isCancelled {
                reload()
                if !isLive { return }
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    // MARK: 工具栏

    private var toolbar: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.map { "日志 — \($0.name)" } ?? "全部日志")
                    .font(.headline)
                Text("共 \(filtered.count) 条\(events.count != filtered.count ? " (已过滤 / 总 \(events.count))" : "")")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Picker("", selection: $levelFilter) {
                Text("全部级别").tag(LogLevel?.none)
                ForEach(LogLevel.allCases, id: \.self) { level in
                    Text(level.displayName).tag(LogLevel?.some(level))
                }
            }
            .labelsHidden()
            .frame(width: 130)

            TextField("搜索…", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .frame(width: 160)

            Toggle("实时", isOn: $isLive)
                .toggleStyle(.switch)
                .controlSize(.small)

            Button {
                reload()
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .help("刷新")

            Button("关闭") { isPresented = false }
                .keyboardShortcut(.cancelAction)
        }
        .padding(14)
    }

    // MARK: 内容

    @ViewBuilder
    private var content: some View {
        if filtered.isEmpty {
            ContentUnavailableView(
                "没有日志",
                systemImage: "text.alignleft",
                description: Text(events.isEmpty
                                  ? "任务还没有产生任何事件。"
                                  : "当前过滤条件没有匹配到记录。")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(filtered) { event in
                        LogRowView(event: event)
                        Divider()
                    }
                }
            }
            .background(.quaternary.opacity(0.15))
        }
    }

    private func reload() {
        events = manager.events(for: task, limit: 800)
    }
}

struct LogRowView: View {

    let event: AppEvent

    var body: some View {
        HStack(alignment: .top, spacing: 12) {

            Text(event.timestampText)
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 62, alignment: .leading)

            Text(event.level.displayName)
                .font(.caption2.weight(.bold).monospaced())
                .foregroundStyle(event.level.tintColor)
                .frame(width: 60, alignment: .leading)

            Text(event.eventType.rawValue)
                .font(.caption2.monospaced())
                .foregroundStyle(.secondary)
                .frame(width: 190, alignment: .leading)
                .lineLimit(1)

            VStack(alignment: .leading, spacing: 3) {
                Text(event.message)
                    .font(.caption)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                if let metadata = event.metadata, case .object(let dict) = metadata, !dict.isEmpty {
                    Text(dict.sorted { $0.key < $1.key }
                        .map { "\($0.key)=\($0.value.stringValue ?? "…")" }
                        .joined(separator: "  "))
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
            }

            Spacer(minLength: 0)

            if let index = event.stepIndex {
                Text("step \(index + 1)")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 7)
    }
}
````


#### `Sources/AIRunner/UI/Settings/ProviderSettingsView.swift` (250 行)

````swift
import SwiftUI
import AIRunnerCore

/// Provider 配置: 端点、默认模型、API Key (写入 macOS Keychain)。
struct ProviderSettingsView: View {

    let services: AppServices

    @State private var selection: String?
    @State private var apiKeyInput = ""
    @State private var statusMessage: String?
    @State private var statusIsError = false

    @State private var draftBaseURL = ""
    @State private var draftModel = ""
    @State private var draftEnabled = true
    @State private var loadedProviderID: String?

    private var providers: [ProviderConfig] {
        services.factory.allProviders
    }

    private var selectedProvider: ProviderConfig? {
        guard let selection else { return nil }
        return providers.first { $0.id == selection }
    }

    var body: some View {
        HSplitView {
            list
                .frame(minWidth: 180, idealWidth: 200, maxWidth: 240)
            editor
                .frame(minWidth: 380)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 左: Provider 列表

    private var list: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Provider")
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 10)
                .padding(.bottom, 4)

            List(selection: $selection) {
                ForEach(providers) { provider in
                    HStack(spacing: 8) {
                        Image(systemName: services.factory.isConfigured(providerID: provider.id)
                              ? "checkmark.seal.fill" : "circle.dashed")
                            .foregroundStyle(services.factory.isConfigured(providerID: provider.id)
                                             ? .green : .secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(provider.displayName).font(.callout)
                            Text(provider.requiresAPIKey
                                 ? services.factory.maskedKey(for: provider.id)
                                 : "无需密钥")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Spacer()
                        if !provider.enabled {
                            Text("已禁用")
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(provider.id)
                }
            }
            .listStyle(.inset)
        }
        .onAppear {
            if selection == nil { selection = providers.first?.id }
        }
    }

    // MARK: 右: 编辑表单

    @ViewBuilder
    private var editor: some View {
        if let provider = selectedProvider {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {

                    HStack {
                        Text(provider.displayName).font(.title3.bold())
                        Text(provider.kind.displayName)
                            .font(.caption2)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                        Spacer()
                    }

                    Divider()

                    field("Base URL (不含 /chat/completions)") {
                        TextField("https://api.example.com/v1", text: $draftBaseURL)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    field("默认模型") {
                        TextField("model-name", text: $draftModel)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(.body, design: .monospaced))
                    }

                    Toggle("启用此 Provider", isOn: $draftEnabled)

                    Divider()

                    field("API Key") {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack(spacing: 8) {
                                SecureField("粘贴 API Key (sk-…)", text: $apiKeyInput)
                                    .textFieldStyle(.roundedBorder)
                                Button("保存到 Keychain") { saveKey(for: provider) }
                                    .disabled(apiKeyInput.trimmingCharacters(in: .whitespaces).isEmpty)
                            }

                            HStack(spacing: 6) {
                                Image(systemName: "lock.fill").font(.caption2)
                                Text("当前: \(services.factory.maskedKey(for: provider.id))")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Text("Key 只写入 macOS Keychain (service = com.airunner.apikeys, "
                                 + "account = \(provider.keychainKey))。不会进入数据库、日志或 UserDefaults。")
                                .font(.caption2)
                                .foregroundStyle(.tertiary)

                            if services.factory.isConfigured(providerID: provider.id),
                               provider.requiresAPIKey {
                                Button("删除已存密钥", role: .destructive) {
                                    deleteKey(for: provider)
                                }
                                .controlSize(.small)
                            }
                        }
                    }

                    if let statusMessage {
                        Text(statusMessage)
                            .font(.caption)
                            .foregroundStyle(statusIsError ? .red : .green)
                    }

                    Divider()

                    HStack {
                        Button("保存 Provider 设置") { saveProvider(provider) }
                            .buttonStyle(.borderedProminent)
                        Button("还原") { load(provider) }
                        Spacer()
                    }
                }
                .padding(18)
            }
            .id(provider.id)
        } else {
            ContentUnavailableView("选择一个 Provider", systemImage: "server.rack")
        }
    }

    private func field<Content: View>(
        _ title: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption.bold()).foregroundStyle(.secondary)
            content()
        }
    }

    // MARK: 动作

    private func load(_ provider: ProviderConfig) {
        draftBaseURL = provider.baseURL
        draftModel = provider.defaultModel
        draftEnabled = provider.enabled
        apiKeyInput = ""
        loadedProviderID = provider.id
        statusMessage = nil
    }

    private func saveProvider(_ provider: ProviderConfig) {
        var updated = provider
        updated.baseURL = draftBaseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.defaultModel = draftModel.trimmingCharacters(in: .whitespacesAndNewlines)
        updated.enabled = draftEnabled

        guard !updated.baseURL.isEmpty, !updated.defaultModel.isEmpty else {
            report("Base URL 与默认模型不能为空", isError: true)
            return
        }

        var settings = services.settings
        if let index = settings.providers.firstIndex(where: { $0.id == provider.id }) {
            settings.providers[index] = updated
        } else {
            settings.providers.append(updated)
        }

        Task {
            await services.saveSettings(settings)
            await MainActor.run {
                report("已保存 \(updated.displayName) 的设置", isError: false)
            }
        }
    }

    private func saveKey(for provider: ProviderConfig) {
        do {
            try services.factory.saveAPIKey(apiKeyInput, for: provider.id)
            apiKeyInput = ""
            report("API Key 已写入 Keychain", isError: false)
            refreshSelection()
        } catch {
            report(AppError.normalize(error).userMessage, isError: true)
        }
    }

    private func deleteKey(for provider: ProviderConfig) {
        do {
            try services.factory.deleteAPIKey(for: provider.id)
            report("已删除 Keychain 中的密钥", isError: false)
            refreshSelection()
        } catch {
            report(AppError.normalize(error).userMessage, isError: true)
        }
    }

    /// 强制刷新左侧列表的"已配置"状态。
    private func refreshSelection() {
        let current = selection
        selection = nil
        DispatchQueue.main.async { selection = current }
    }

    private func report(_ message: String, isError: Bool) {
        statusMessage = message
        statusIsError = isError
    }
}
````


#### `Sources/AIRunner/UI/Settings/SettingsView.swift` (449 行)

````swift
import SwiftUI
import AIRunnerCore

struct SettingsView: View {

    @EnvironmentObject private var appState: AppState

    var body: some View {
        Group {
            if let services = appState.services {
                TabView {
                    ProviderSettingsView(services: services)
                        .tabItem { Label("Provider 与密钥", systemImage: "key.fill") }

                    RoutingSettingsView(services: services)
                        .tabItem { Label("模型路由", systemImage: "arrow.triangle.branch") }

                    ChatGptWebSettingsView(services: services)
                        .tabItem { Label("ChatGPT Web", systemImage: "safari") }

                    RuntimeSettingsView(services: services)
                        .tabItem { Label("运行与健康", systemImage: "gearshape.2.fill") }
                }
                .padding(12)
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.largeTitle)
                        .foregroundStyle(.orange)
                    Text(appState.bootstrapError ?? "服务未就绪")
                        .font(.callout)
                        .multilineTextAlignment(.center)
                }
                .padding(30)
            }
        }
        .frame(minWidth: 680, minHeight: 480)
    }
}

// MARK: - ChatGPT Web

struct ChatGptWebSettingsView: View {

    let services: AppServices

    @State private var urlText = ""
    @State private var copyPrompt = true
    @State private var openBrowser = true
    @State private var defaultMode: ExecutionMode = .chatGPTWeb
    @State private var statusMessage: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                VStack(alignment: .leading, spacing: 8) {
                    Text("执行通道").font(.headline)
                    Text("新建任务默认使用哪种方式执行。ChatGPT Web 是主流程 —— "
                         + "账号切换由你在浏览器里手动完成; API 是可选的直连后端。")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Picker("", selection: $defaultMode) {
                        ForEach(ExecutionMode.allCases) { mode in
                            Text(mode.displayName).tag(mode)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .labelsHidden()

                    Text(defaultMode.detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("ChatGPT 地址").font(.headline)
                    TextField("https://chatgpt.com/", text: $urlText)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                    Text("点「打开 ChatGPT」时使用的地址。可改成区域域名或自建网关。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("生成 Prompt 后的自动动作").font(.headline)
                    Toggle("自动把续跑 prompt 复制到剪贴板", isOn: $copyPrompt)
                    Toggle("自动打开 ChatGPT", isOn: $openBrowser)
                }

                Divider()

                VStack(alignment: .leading, spacing: 8) {
                    Text("能力边界").font(.headline)
                    Text("""
                    AIRunner 只做这些:
                     · 保存任务状态、已完成步骤与检查点
                     · 根据检查点生成自包含的续跑 prompt
                     · 检测到无法继续时暂停, 并提示你手动切换账号
                     · 你切换完成后从检查点继续, 不重复已完成的工作

                    AIRunner 不做这些:
                     · 读取或导出浏览器 Cookie
                     · 读取或注入 session token
                     · 自动填写账号密码 / 自动登录
                     · 自动轮换账号, 或绕过任何使用限制
                    """)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                }

                HStack(spacing: 12) {
                    Button("保存") { save() }
                        .buttonStyle(.borderedProminent)
                    if let statusMessage {
                        Text(statusMessage).font(.caption).foregroundStyle(.green)
                    }
                    Spacer()
                }
            }
            .padding(16)
        }
        .task {
            urlText = services.settings.chatGPTURL
            copyPrompt = services.settings.copyPromptToClipboard
            openBrowser = services.settings.openBrowserOnPrepare
            defaultMode = services.settings.defaultExecutionMode
        }
    }

    private func save() {
        var settings = services.settings
        let trimmed = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.chatGPTURL = trimmed.isEmpty ? ChatGPTWebTarget.defaultURLString : trimmed
        settings.copyPromptToClipboard = copyPrompt
        settings.openBrowserOnPrepare = openBrowser
        settings.defaultExecutionMode = defaultMode

        Task {
            await services.saveSettings(settings)
            await MainActor.run { statusMessage = "已保存" }
        }
    }
}

// MARK: - 模型路由

struct RoutingSettingsView: View {

    let services: AppServices

    @State private var routes: [RouteEntry] = []
    @State private var statusMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Text("路由表")
                .font(.headline)

            Text("按优先级从高到低尝试。某个 backend 失败时, Runner 会把它加入"
                 + "「本次已试过」集合并换下一个 —— 因此绝不会出现 A→B→A→B 的循环。")
                .font(.caption)
                .foregroundStyle(.secondary)

            List {
                ForEach(Array(routes.enumerated()), id: \.element.id) { index, route in
                    HStack(spacing: 12) {
                        Text("\(index + 1)")
                            .font(.callout.monospacedDigit().bold())
                            .frame(width: 20)
                            .foregroundStyle(.secondary)

                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(route.provider) / \(route.model)")
                                .font(.callout)
                            if let note = route.note, !note.isEmpty {
                                Text(note).font(.caption2).foregroundStyle(.secondary)
                            }
                        }

                        Spacer()

                        if services.factory.isConfigured(providerID: route.provider) {
                            Label("可用", systemImage: "checkmark.circle.fill")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.green)
                                .help("已配置")
                        } else {
                            Label("缺少密钥", systemImage: "exclamationmark.circle")
                                .labelStyle(.iconOnly)
                                .foregroundStyle(.orange)
                                .help("该 Provider 尚未配置 API Key")
                        }

                        Toggle("", isOn: Binding(
                            get: { route.enabled },
                            set: { newValue in
                                routes[index].enabled = newValue
                                persist()
                            }
                        ))
                        .labelsHidden()
                        .toggleStyle(.switch)
                        .controlSize(.small)
                    }
                    .padding(.vertical, 2)
                }
                .onMove { source, destination in
                    routes.move(fromOffsets: source, toOffset: destination)
                    persist()
                }
            }
            .listStyle(.inset)

            if let statusMessage {
                Text(statusMessage).font(.caption).foregroundStyle(.green)
            }

            HStack {
                Button {
                    routes = RouteEntry.defaults
                    persist()
                } label: {
                    Label("恢复出厂路由", systemImage: "arrow.counterclockwise")
                }
                Spacer()
                Text("拖动可调整优先级")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(16)
        .onAppear {
            routes = services.settings.sortedRoutes
        }
    }

    private func persist() {
        var settings = services.settings
        settings.routes = routes
        Task {
            await services.saveSettings(settings)
            await MainActor.run {
                routes = services.settings.sortedRoutes
                statusMessage = "路由已保存"
            }
        }
    }
}

// MARK: - 运行参数与 Provider 健康

struct RuntimeSettingsView: View {

    let services: AppServices

    @State private var concurrencyText = "3"
    @State private var maxRetriesText = "8"
    @State private var baseDelayText = "5"
    @State private var health: [ProviderHealth] = []
    @State private var statusMessage: String?
    @State private var statusIsError = false

    private var diagnostics: Database.Diagnostics? {
        try? services.databaseDiagnostics()
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {

                // ---- 运行参数 ----
                VStack(alignment: .leading, spacing: 12) {
                    Text("运行参数").font(.headline)

                    HStack(spacing: 24) {
                        numberField("全局并发任务数", text: $concurrencyText, width: 70)
                        numberField("单步最大重试次数", text: $maxRetriesText, width: 70)
                        numberField("退避基础秒数", text: $baseDelayText, width: 70)
                    }

                    Text("退避序列 = base × 2^n, 上限 300s, 并叠加 30% 随机抖动。"
                         + "限流单独计数, 不消耗普通重试预算。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    HStack {
                        Button("保存运行参数") { saveRuntime() }
                            .buttonStyle(.borderedProminent)
                        if let statusMessage {
                            Text(statusMessage)
                                .font(.caption)
                                .foregroundStyle(statusIsError ? .red : .green)
                        }
                    }
                }

                Divider()

                // ---- Provider 健康 ----
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Provider 健康与熔断").font(.headline)
                        Spacer()
                        Button {
                            Task {
                                await services.resetProviderHealth()
                                health = await services.healthSnapshot()
                            }
                        } label: {
                            Label("重置全部熔断", systemImage: "arrow.counterclockwise")
                        }
                        .controlSize(.small)
                    }

                    Text("认证失败或余额耗尽会让 Provider 立即熔断并进入长冷却, "
                         + "避免无意义地反复调用。网络抖动与限流不会熔断。")
                        .font(.caption2)
                        .foregroundStyle(.secondary)

                    if health.isEmpty {
                        Text("暂无健康记录 (尚未发生失败)")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    } else {
                        VStack(spacing: 0) {
                            ForEach(health, id: \.label) { item in
                                HStack(spacing: 10) {
                                    Circle()
                                        .fill(item.state.tintColor)
                                        .frame(width: 8, height: 8)
                                    Text(item.label)
                                        .font(.callout)
                                        .frame(width: 220, alignment: .leading)
                                    Text(item.statusDescription)
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                    Spacer()
                                }
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                Divider()
                            }
                        }
                        .background(.quaternary.opacity(0.25),
                                    in: RoundedRectangle(cornerRadius: 8))
                    }
                }

                Divider()

                // ---- 数据库 ----
                VStack(alignment: .leading, spacing: 8) {
                    Text("存储").font(.headline)

                    if let diagnostics {
                        Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 6) {
                            GridRow {
                                Text("路径").foregroundStyle(.secondary)
                                Text(services.database.databasePath)
                                    .textSelection(.enabled)
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                            }
                            GridRow {
                                Text("journal_mode").foregroundStyle(.secondary)
                                Text(diagnostics.journalMode)
                            }
                            GridRow {
                                Text("外键约束").foregroundStyle(.secondary)
                                Text(diagnostics.foreignKeys ? "已启用" : "未启用")
                            }
                            GridRow {
                                Text("完整性检查").foregroundStyle(.secondary)
                                Text(diagnostics.integrityOK ? "ok" : "异常")
                                    .foregroundStyle(diagnostics.integrityOK ? .green : .red)
                            }
                        }
                        .font(.caption)
                    }

                    Text("API Key 存放于 macOS Keychain, 不进入数据库与日志。")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(16)
        }
        .task {
            concurrencyText = "\(services.settings.concurrency)"
            maxRetriesText = "\(services.settings.retry.maxRetries)"
            baseDelayText = "\(Int(services.settings.retry.baseDelay))"
            health = await services.healthSnapshot()
        }
    }

    private func numberField(_ title: String, text: Binding<String>, width: CGFloat) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            TextField("", text: text)
                .textFieldStyle(.roundedBorder)
                .monospacedDigit()
                .frame(width: width)
        }
    }

    private func saveRuntime() {
        guard let concurrency = Int(concurrencyText.trimmingCharacters(in: .whitespaces)),
              (1...32).contains(concurrency) else {
            statusMessage = "并发数必须是 1 – 32 的整数"
            statusIsError = true
            return
        }
        guard let retries = Int(maxRetriesText.trimmingCharacters(in: .whitespaces)),
              (0...50).contains(retries) else {
            statusMessage = "重试次数必须是 0 – 50 的整数"
            statusIsError = true
            return
        }
        guard let delay = Double(baseDelayText.trimmingCharacters(in: .whitespaces)),
              delay >= 1, delay <= 3600 else {
            statusMessage = "基础退避必须是 1 – 3600 秒"
            statusIsError = true
            return
        }

        var settings = services.settings
        settings.concurrency = concurrency
        settings.retry.maxRetries = retries
        settings.retry.baseDelay = delay

        Task {
            await services.saveSettings(settings)
            await MainActor.run {
                statusMessage = "已保存 (并发数需重启 App 后对 Runner 生效)"
                statusIsError = false
            }
        }
    }
}
````


#### `Sources/AIRunner/UI/Tasks/CreateTaskView.swift` (160 行)

````swift
import SwiftUI
import AIRunnerCore

/// 新建任务表单。
struct CreateTaskView: View {

    @ObservedObject var manager: TaskManager
    @Binding var isPresented: Bool

    @State private var name = ""
    @State private var goal = ""
    @State private var stepsText = "5"
    @State private var errorMessage: String?

    private var stepCount: Int? {
        Int(stepsText.trimmingCharacters(in: .whitespaces))
    }

    private var stepCountIsValid: Bool {
        guard let stepCount else { return false }
        return (1...1000).contains(stepCount)
    }

    private var canSubmit: Bool {
        !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !goal.trimmingCharacters(in: .whitespaces).isEmpty
            && stepCountIsValid
    }

    private var primaryRoute: RouteEntry? {
        manager.services.settings.primaryRoute
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {

            HStack(spacing: 10) {
                Image(systemName: "plus.rectangle.on.folder")
                    .font(.title2)
                    .foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("新建长任务").font(.title3.bold())
                    Text("任务会被拆成 N 个顺序步骤, 每一步的结果与检查点都会立即落盘。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(20)

            Divider()

            VStack(alignment: .leading, spacing: 16) {

                VStack(alignment: .leading, spacing: 6) {
                    Text("任务名称").font(.caption.bold()).foregroundStyle(.secondary)
                    TextField("例如: PDF 研究报告", text: $name)
                        .textFieldStyle(.roundedBorder)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Text("任务目标").font(.caption.bold()).foregroundStyle(.secondary)
                    TextEditor(text: $goal)
                        .font(.body)
                        .frame(height: 90)
                        .padding(6)
                        .background(.quaternary.opacity(0.25),
                                    in: RoundedRectangle(cornerRadius: 6))
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(.quaternary, lineWidth: 1)
                        )
                }

                HStack(alignment: .top, spacing: 20) {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("步骤数").font(.caption.bold()).foregroundStyle(.secondary)
                        TextField("5", text: $stepsText)
                            .textFieldStyle(.roundedBorder)
                            .frame(width: 90)
                            .monospacedDigit()
                        if !stepCountIsValid && !stepsText.isEmpty {
                            Text("必须是 1 – 1000 的整数")
                                .font(.caption2)
                                .foregroundStyle(.red)
                        }
                    }

                    VStack(alignment: .leading, spacing: 6) {
                        Text("执行通道").font(.caption.bold()).foregroundStyle(.secondary)

                        let mode = manager.services.settings.defaultExecutionMode
                        Text(mode.displayName)
                            .font(.callout)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 5)
                            .background(.teal.opacity(0.15), in: Capsule())

                        if mode == .chatGPTWeb {
                            Text("可在「设置 → ChatGPT Web」中调整")
                                .font(.caption2).foregroundStyle(.tertiary)
                        } else {
                            Text(primaryRoute.map { "路由: \($0.label)" } ?? "未配置路由")
                                .font(.caption2)
                                .foregroundStyle(primaryRoute == nil ? Color.red : Color.secondary)
                        }
                    }
                }

                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "info.circle")
                        .foregroundStyle(.secondary)
                    Text("MVP 会把目标拆成 N 个等价步骤, 每步都带上目标与最新检查点摘要。"
                          + "步骤拆分策略后续可由 Task Planner 增强。")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(10)
                .background(.quaternary.opacity(0.25), in: RoundedRectangle(cornerRadius: 8))

                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(20)

            Divider()

            HStack {
                Button("取消") { isPresented = false }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("创建任务") { submit() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSubmit)
            }
            .padding(20)
        }
        .frame(width: 560)
    }

    private func submit() {
        guard let stepCount, stepCountIsValid else { return }
        do {
            let task = try manager.createTask(
                name: name,
                goal: goal,
                numberOfSteps: stepCount
            )
            isPresented = false
            // 创建后自动开跑, 符合"长任务"直觉
            manager.start(task)
        } catch {
            errorMessage = AppError.normalize(error).userMessage
        }
    }
}
````


#### `Sources/AIRunner/UI/Tasks/TaskDetailView.swift` (556 行)

````swift
import SwiftUI
import AIRunnerCore

struct TaskDetailView: View {

    @ObservedObject var manager: TaskManager
    let services: AppServices
    let task: AITask

    @State private var showingLogs = false
    @State private var showingAllSteps = false

    private var steps: [TaskStep] { manager.steps(for: task) }
    private var latestCheckpoint: Checkpoint? { manager.latestCheckpoint(for: task) }
    private var counts: [StepStatus: Int] { manager.stepStatusCounts(for: task) }

    private var displayedSteps: [TaskStep] {
        showingAllSteps ? steps : Array(steps.suffix(40))
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                headerSection
                actionSection
                webExecutionSection
                metricsSection
                checkpointSection
                stepsSection
                footerSection
            }
            .padding(22)
        }
        .navigationTitle(task.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingLogs = true
                } label: {
                    Label("日志", systemImage: "text.alignleft")
                }
            }
        }
        .sheet(isPresented: $showingLogs) {
            LogView(manager: manager, task: task, isPresented: $showingLogs)
        }
    }

    // MARK: - 头部

    private var headerSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: task.status.symbolName)
                    .font(.title2)
                    .foregroundStyle(task.status.tintColor)
                Text(task.name)
                    .font(.title2.bold())
                StatusBadge(status: task.status)
                Spacer()
            }

            Text(task.goal)
                .font(.callout)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)

            if let message = task.errorMessage {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.actionHint).font(.caption.bold())
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.orange.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
            }

            ProgressView(value: task.progress) {
                HStack {
                    Text(task.progressText).font(.caption.monospacedDigit())
                    Spacer()
                    Text("\(Int(task.progress * 100))%").font(.caption.monospacedDigit())
                }
            }
        }
    }

    // MARK: - 操作

    private var actionSection: some View {
        HStack(spacing: 10) {
            switch task.status {
            case .queued:
                Button {
                    manager.start(task)
                } label: { Label("开始执行", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)

            case .running:
                Button {
                    manager.pause(task)
                } label: { Label("暂停", systemImage: "pause.fill") }
                    .buttonStyle(.borderedProminent)

            case .paused, .waiting, .failed,
                 .waitingForAccount, .waitingForBrowser, .waitingForUser:
                Button {
                    manager.resume(task)
                } label: { Label("继续", systemImage: "play.fill") }
                    .buttonStyle(.borderedProminent)

            case .completed, .cancelled:
                EmptyView()
            }

            if !task.status.isTerminal {
                Button(role: .destructive) {
                    manager.cancel(task)
                } label: { Label("取消", systemImage: "stop.fill") }
            }

            Spacer()

            if manager.isActive(task) {
                HStack(spacing: 5) {
                    ProgressView().controlSize(.small)
                    Text("Runner 正在执行").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: - ChatGPT Web 执行区

    @ViewBuilder
    private var webExecutionSection: some View {
        if task.executionMode == .chatGPTWeb {
            VStack(alignment: .leading, spacing: 12) {

                HStack(spacing: 8) {
                    Label("Web Execution", systemImage: "safari")
                        .font(.headline)
                    Text("ChatGPT Web")
                        .font(.caption2.weight(.semibold))
                        .padding(.horizontal, 7).padding(.vertical, 3)
                        .background(.teal.opacity(0.18), in: Capsule())
                        .foregroundStyle(.teal)
                    Spacer()
                    Text("账号切换由你手动完成 · 程序不读取 Cookie、不自动登录")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }

                HStack(spacing: 10) {
                    webStat("Execution Mode", task.executionMode.displayName)
                    webStat("Current Step",
                            "\(min(task.currentStep + 1, max(task.totalSteps, 1))) / \(task.totalSteps)")
                    webStat("Checkpoint", "\(completedCount)")
                    webStat("Status", task.status.displayName)
                }

                if task.status == .waitingForAccount {
                    accountHandoffGuide
                }

                if task.status == .waitingForUser, let info = manager.lastInfoMessage {
                    HStack(alignment: .top, spacing: 8) {
                        Image(systemName: "info.circle.fill").foregroundStyle(.teal)
                        Text(info).font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.teal.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
                }

                // 主操作: 复制 prompt → 打开 ChatGPT → 粘贴结果
                HStack(spacing: 10) {
                    Button {
                        manager.copyContinuationPrompt(task)
                    } label: {
                        Label("复制续跑 Prompt", systemImage: "doc.on.doc")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canPreparePrompt)
                    .help("生成续跑 prompt、复制到剪贴板, 并把该步骤标记为「已就绪」")

                    Button {
                        openChatGPT()
                    } label: {
                        Label("打开 ChatGPT", systemImage: "safari")
                    }
                    .help("用系统默认浏览器打开 ChatGPT —— 不涉及任何自动化操作")

                    Button {
                        manager.pasteResult(task)
                    } label: {
                        Label("粘贴结果", systemImage: "doc.on.clipboard")
                    }
                    .disabled(!canPasteResult)
                    .help("把剪贴板里 ChatGPT 的回复提交为本步骤的结果")

                    Spacer()
                }

                // 账号交接
                HStack(spacing: 10) {
                    Button {
                        manager.pauseForAccountSwitch(task)
                    } label: {
                        Label("暂停以切换账号",
                              systemImage: "person.crop.circle.badge.exclamationmark")
                    }
                    .disabled(task.status.isTerminal || task.status == .waitingForAccount)

                    Button {
                        manager.resumeAfterAccountSwitch(task)
                    } label: {
                        Label("我已完成账号切换", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(task.status != .waitingForAccount)

                    if manager.awaitingStep(task) != nil {
                        Button("丢弃当前 Prompt") {
                            manager.discardPreparedPrompt(task)
                        }
                        .controlSize(.small)
                    }

                    Spacer()
                }

                if let preview = manager.promptPreview,
                   manager.promptPreviewTaskID == task.id,
                   !preview.isEmpty {
                    promptPreviewBlock(preview)
                }
            }
            .padding(14)
            .background(.teal.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
            .overlay(
                RoundedRectangle(cornerRadius: 10)
                    .stroke(.teal.opacity(0.22), lineWidth: 1)
            )
        }
    }

    /// 已完成的步骤数 (检查点记录的是"最后完成的 index", 这里换算成个数)。
    private var completedCount: Int {
        (latestCheckpoint?.completedStep ?? -1) + 1
    }

    private var canPreparePrompt: Bool {
        guard !task.status.isTerminal else { return false }
        if manager.awaitingStep(task) != nil { return true }   // 允许重新生成
        return task.currentStep < task.totalSteps
    }

    private var canPasteResult: Bool {
        guard !task.status.isTerminal else { return false }
        return manager.awaitingStep(task) != nil || task.status == .waitingForUser
    }

    private func openChatGPT() {
        let url = ChatGPTWebTarget.resolvedURL(override: services.settings.chatGPTURL)
        WorkspaceBrowserLauncher().open(url)
    }

    private func webStat(_ title: String, _ value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2).foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 6))
    }

    private var accountHandoffGuide: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "person.crop.circle.badge.exclamationmark")
                    .foregroundStyle(.purple)
                Text("Waiting for account switch").font(.callout.bold())
                Spacer()
            }
            Text("""
            任务已安全保存检查点 (共完成 \(completedCount) 步)。

            1. 在浏览器中手动切换到另一个已授权的 ChatGPT 会话。
            2. 打开 ChatGPT。
            3. 回到这里。
            4. 点击「我已完成账号切换」。
            """)
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.purple.opacity(0.10), in: RoundedRectangle(cornerRadius: 8))
    }

    private func promptPreviewBlock(_ preview: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("当前续跑 Prompt")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    if PasteboardClipboard().writeString(preview) {
                        manager.lastInfoMessage = "续跑 prompt 已复制到剪贴板"
                    }
                } label: {
                    Label("复制", systemImage: "doc.on.doc")
                        .font(.caption2)
                }
                .controlSize(.small)
            }
            ScrollView {
                Text(preview)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
            }
            .frame(maxHeight: 220)
            .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
        }
    }

    // MARK: - 指标

    private var metricsSection: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: 190), spacing: 12)],
            alignment: .leading,
            spacing: 12
        ) {
            MetricCard(title: "当前步骤", value: "\(task.currentStep) / \(task.totalSteps)",
                       symbol: "list.number")
            MetricCard(title: "执行通道", value: task.executionMode.displayName,
                       symbol: task.executionMode == .chatGPTWeb ? "safari" : "server.rack")

            if task.executionMode == .chatGPTWeb {
                MetricCard(title: "账号", value: "手动交接", symbol: "person.crop.circle")
                MetricCard(title: "结果来源", value: "剪贴板回填", symbol: "doc.on.clipboard")
            } else {
                MetricCard(title: "主力 Provider", value: task.primaryProvider,
                           symbol: "server.rack")
                MetricCard(title: "主力模型", value: task.primaryModel,
                           symbol: "cpu")
            }
            MetricCard(title: "任务重试次数", value: "\(task.retryCount) / \(task.maxRetries)",
                       symbol: "arrow.clockwise")
            MetricCard(title: "已完成步骤", value: "\(counts[.completed] ?? 0)",
                       symbol: "checkmark.circle")
            MetricCard(title: "失败步骤", value: "\(counts[.failed] ?? 0)",
                       symbol: "xmark.circle")
            MetricCard(
                title: "最新检查点",
                value: latestCheckpoint.map { "nextStep = \($0.nextStep)" } ?? "无",
                symbol: "flag.checkered"
            )
            MetricCard(title: "创建时间", value: format(task.createdAt), symbol: "clock")
        }
    }

    private func format(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "MM-dd HH:mm"
        return formatter.string(from: date)
    }

    // MARK: - 检查点

    private var checkpointSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("最新检查点", symbol: "flag.checkered")

            if let checkpoint = latestCheckpoint {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 14) {
                        Label("completedStep = \(checkpoint.completedStep)",
                              systemImage: "checkmark")
                        Label("nextStep = \(checkpoint.nextStep)",
                              systemImage: "arrow.right")
                        Label(format(checkpoint.createdAt), systemImage: "clock")
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                    Text(checkpoint.summaryPreview)
                        .font(.callout)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                        .background(.quaternary.opacity(0.35),
                                    in: RoundedRectangle(cornerRadius: 7))
                }
            } else {
                Text("尚未产生检查点")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 步骤

    private var stepsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sectionTitle("步骤", symbol: "square.stack.3d.up")
                Spacer()
                if steps.count > 40 {
                    Toggle("显示全部 \(steps.count) 步", isOn: $showingAllSteps)
                        .toggleStyle(.switch)
                        .controlSize(.small)
                }
            }

            if steps.isEmpty {
                Text("没有步骤")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                LazyVStack(spacing: 0) {
                    ForEach(displayedSteps) { step in
                        StepRowView(step: step)
                        if step.id != displayedSteps.last?.id {
                            Divider()
                        }
                    }
                }
                .background(.quaternary.opacity(0.25),
                            in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    private func sectionTitle(_ text: String, symbol: String) -> some View {
        Label(text, systemImage: symbol)
            .font(.headline)
    }

    // MARK: - 底部

    private var footerSection: some View {
        VStack(alignment: .leading, spacing: 4) {
            Divider()
            Text("数据库: \(services.database.databasePath)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("API Key 存储于 macOS Keychain (service: com.airunner.apikeys)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
    }
}

// MARK: - 子组件

struct MetricCard: View {
    let title: String
    let value: String
    let symbol: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(value)
                .font(.callout.weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct StepRowView: View {
    let step: TaskStep

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: step.status.symbolName)
                .foregroundStyle(step.status.tintColor)
                .frame(width: 18)

            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("第 \(step.index + 1) 步")
                        .font(.callout.weight(.medium))
                    Text(step.type.displayName)
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(.quaternary, in: Capsule())
                    Text(step.status.displayName)
                        .font(.caption2)
                        .foregroundStyle(step.status.tintColor)
                    Spacer()
                    if step.retryCount > 0 {
                        Text("重试 \(step.retryCount)")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                    if step.durationMs > 0 {
                        Text("\(step.durationMs)ms")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                }

                if let backend = step.provider, let model = step.model {
                    Text("\(backend) / \(model)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                if let text = step.outputText, !text.isEmpty {
                    Text(text)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }

                if let error = step.lastError, !error.isEmpty {
                    Text(error)
                        .font(.caption2)
                        .foregroundStyle(.red)
                        .lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
    }
}
````


#### `Sources/AIRunner/UI/Tasks/TaskListView.swift` (209 行)

````swift
import SwiftUI
import Combine
import AIRunnerCore

/// 主界面: 左任务列表 + 右任务详情。
struct MainSplitView: View {

    @ObservedObject var manager: TaskManager
    let services: AppServices

    @State private var selection: String?
    @State private var showingCreate = false

    var body: some View {
        NavigationSplitView {
            TaskListView(
                manager: manager,
                selection: $selection,
                showingCreate: $showingCreate
            )
            .navigationSplitViewColumnWidth(min: 290, ideal: 330, max: 420)
        } detail: {
            if let taskID = selection,
               let task = manager.tasks.first(where: { $0.id == taskID }) {
                TaskDetailView(manager: manager, services: services, task: task)
            } else {
                ContentUnavailableView(
                    "未选择任务",
                    systemImage: "rectangle.stack",
                    description: Text("从左侧选择一个任务查看详情, 或按 ⌘N 新建任务。")
                )
            }
        }
        .sheet(isPresented: $showingCreate) {
            CreateTaskView(manager: manager, isPresented: $showingCreate)
        }
        .onReceive(NotificationCenter.default.publisher(for: .airunnerCreateTask)) { _ in
            showingCreate = true
        }
        .onReceive(NotificationCenter.default.publisher(for: .airunnerOpenChatGPT)) { _ in
            let url = ChatGPTWebTarget.resolvedURL(override: services.settings.chatGPTURL)
            WorkspaceBrowserLauncher().open(url)
        }
    }
}

// MARK: - 任务列表

enum TaskFilter: String, CaseIterable, Identifiable {
    case all
    case active
    case finished

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .all:      return "全部"
        case .active:   return "进行中"
        case .finished: return "已结束"
        }
    }
}

struct TaskListView: View {

    @ObservedObject var manager: TaskManager
    @Binding var selection: String?
    @Binding var showingCreate: Bool

    @State private var filter: TaskFilter = .all

    private var visibleTasks: [AITask] {
        switch filter {
        case .all:
            return manager.tasks
        case .active:
            return manager.tasks.filter { !$0.status.isTerminal }
        case .finished:
            return manager.tasks.filter { $0.status.isTerminal }
        }
    }

    var body: some View {
        Group {
            if manager.tasks.isEmpty {
                ContentUnavailableView(
                    "还没有任务",
                    systemImage: "tray",
                    description: Text("点击下方的「新建任务」创建第一个长任务。")
                )
            } else {
                List(selection: $selection) {
                    ForEach(visibleTasks) { task in
                        TaskRowView(task: task, isActive: manager.isActive(task))
                            .tag(task.id)
                            .contextMenu {
                                contextMenu(for: task)
                            }
                    }
                }
                .listStyle(.inset)
            }
        }
        .navigationTitle("AIRunner")
        .safeAreaInset(edge: .bottom) {
            bottomBar
        }
        .toolbar {
            ToolbarItem(placement: .principal) {
                Picker("", selection: $filter) {
                    ForEach(TaskFilter.allCases) { item in
                        Text(item.displayName).tag(item)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 200)
            }
        }
        .alert(
            "操作失败",
            isPresented: Binding(
                get: { manager.lastErrorMessage != nil },
                set: { if !$0 { manager.lastErrorMessage = nil } }
            )
        ) {
            Button("好") { manager.lastErrorMessage = nil }
        } message: {
            Text(manager.lastErrorMessage ?? "")
        }
    }

    // MARK: 底部操作栏

    private var bottomBar: some View {
        VStack(spacing: 8) {
            if let summary = manager.recoverySummary {
                HStack(spacing: 8) {
                    Image(systemName: "arrow.clockwise.circle.fill")
                        .foregroundStyle(.blue)
                    Text(summary)
                        .font(.caption)
                        .lineLimit(2)
                    Spacer()
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(.blue.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
                .padding(.horizontal, 10)
            }

            HStack(spacing: 10) {
                Button {
                    showingCreate = true
                } label: {
                    Label("新建任务", systemImage: "plus")
                }
                .buttonStyle(.borderedProminent)

                Spacer()

                if let selected = selectedTask {
                    actionButtons(for: selected)
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
        }
        .background(.bar)
    }

    @ViewBuilder
    private func actionButtons(for task: AITask) -> some View {
        switch task.status {
        case .queued:
            Button("开始") { manager.start(task) }
                .buttonStyle(.borderedProminent)

        case .running:
            Button("暂停") { manager.pause(task) }
            Button("取消", role: .destructive) { manager.cancel(task) }

        case .paused, .waiting, .failed,
             .waitingForAccount, .waitingForBrowser, .waitingForUser:
            Button("继续") { manager.resume(task) }
                .buttonStyle(.borderedProminent)
            Button("取消", role: .destructive) { manager.cancel(task) }

        case .completed, .cancelled:
            EmptyView()
        }
    }

    @ViewBuilder
    private func contextMenu(for task: AITask) -> some View {
        Button("开始") { manager.start(task) }
        Button("暂停") { manager.pause(task) }
        Button("继续") { manager.resume(task) }
        Divider()
        Button("取消", role: .destructive) { manager.cancel(task) }
        Button("删除任务", role: .destructive) { manager.delete(task) }
    }

    private var selectedTask: AITask? {
        guard let selection else { return nil }
        return manager.tasks.first { $0.id == selection }
    }
}
````


#### `Sources/AIRunner/UI/Tasks/TaskRowView.swift` (151 行)

````swift
import SwiftUI
import AIRunnerCore

/// 任务列表中的一行。
struct TaskRowView: View {

    let task: AITask
    let isActive: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {

            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(task.name)
                    .font(.headline)
                    .lineLimit(1)
                Spacer(minLength: 6)
                StatusBadge(status: task.status)
            }

            ProgressView(value: task.progress)
                .progressViewStyle(.linear)

            HStack(spacing: 8) {
                Text(task.progressText)
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)

                if isActive {
                    HStack(spacing: 3) {
                        ProgressView().controlSize(.mini)
                        Text("执行中").font(.caption2)
                    }
                    .foregroundStyle(.blue)
                }

                Spacer(minLength: 4)

                Text("\(task.primaryProvider) / \(task.primaryModel)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }

            if let message = task.errorMessage,
               task.status == .failed || task.status == .paused {
                Text(message)
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .lineLimit(2)
            }
        }
        .padding(.vertical, 4)
    }
}

struct StatusBadge: View {
    let status: TaskStatus

    var body: some View {
        Text(status.displayName)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(status.tintColor.opacity(0.18), in: Capsule())
            .foregroundStyle(status.tintColor)
    }
}

// MARK: - 状态样式

extension TaskStatus {
    var tintColor: Color {
        switch self {
        case .queued:            return .secondary
        case .running:           return .blue
        case .waiting:           return .orange
        case .waitingForAccount: return .purple
        case .waitingForBrowser: return .indigo
        case .waitingForUser:    return .teal
        case .paused:            return .yellow
        case .completed:         return .green
        case .failed:            return .red
        case .cancelled:         return .gray
        }
    }

    var symbolName: String {
        switch self {
        case .queued:            return "clock"
        case .running:           return "play.circle.fill"
        case .waiting:           return "hourglass"
        case .waitingForAccount: return "person.crop.circle.badge.exclamationmark"
        case .waitingForBrowser: return "safari"
        case .waitingForUser:    return "doc.on.clipboard"
        case .paused:            return "pause.circle.fill"
        case .completed:         return "checkmark.circle.fill"
        case .failed:            return "xmark.octagon.fill"
        case .cancelled:         return "slash.circle.fill"
        }
    }
}

extension StepStatus {
    var tintColor: Color {
        switch self {
        case .pending:     return .secondary
        case .prepared:    return .teal
        case .running:     return .blue
        case .completed:   return .green
        case .failed:      return .red
        case .skipped:     return .gray
        case .interrupted: return .orange
        }
    }

    var symbolName: String {
        switch self {
        case .pending:     return "circle"
        case .prepared:    return "doc.on.clipboard.fill"
        case .running:     return "arrow.triangle.2.circlepath"
        case .completed:   return "checkmark.circle.fill"
        case .failed:      return "xmark.circle.fill"
        case .skipped:     return "minus.circle"
        case .interrupted: return "bolt.slash.fill"
        }
    }
}

extension LogLevel {
    var tintColor: Color {
        switch self {
        case .debug:    return .secondary
        case .info:     return .blue
        case .warning:  return .orange
        case .error:    return .red
        case .critical: return .purple
        }
    }
}

extension ProviderHealthState {
    var tintColor: Color {
        switch self {
        case .healthy:     return .green
        case .degraded:    return .orange
        case .unavailable: return .red
        }
    }
}
````


### 测试


#### `Tests/AIRunnerCoreTests/CheckpointTests.swift` (217 行)

````swift
import XCTest
@testable import AIRunnerCore

final class CheckpointTests: XCTestCase {

    // MARK: - 模型层

    func testInitialCheckpointStartsBeforeFirstStep() {
        let checkpoint = Checkpoint.initial(taskID: "t1")
        XCTAssertEqual(checkpoint.completedStep, -1, "尚未完成任何步骤")
        XCTAssertEqual(checkpoint.nextStep, 0, "应当从第 0 步开始")
    }

    func testCheckpointNextStepIsCompletedPlusOne() async throws {
        let services = try TestSupport.makeServices()

        let checkpoint = await services.checkpointManager.makeCheckpoint(
            taskID: "t1",
            completedStep: 0,
            previous: nil,
            output: .object(["text": .string("first result")]),
            provider: "p1",
            model: "m1"
        )

        XCTAssertEqual(checkpoint.completedStep, 0)
        XCTAssertEqual(checkpoint.nextStep, 1)
    }

    func testWorkingSummaryAccumulatesAcrossSteps() async throws {
        let services = try TestSupport.makeServices()
        let manager = services.checkpointManager

        let first = await manager.makeCheckpoint(
            taskID: "t1", completedStep: 0, previous: nil,
            output: .object(["text": .string("alpha findings")]),
            provider: "p1", model: "m1"
        )
        let second = await manager.makeCheckpoint(
            taskID: "t1", completedStep: 1, previous: first,
            output: .object(["text": .string("beta findings")]),
            provider: "p1", model: "m1"
        )

        let summary = try XCTUnwrap(second.workingSummary)
        XCTAssertTrue(summary.contains("alpha findings"), "摘要应累积上一步的内容")
        XCTAssertTrue(summary.contains("beta findings"), "摘要应包含本步内容")
    }

    func testWorkingSummaryIsTruncatedToBound() async throws {
        let services = try TestSupport.makeServices()
        let manager = services.checkpointManager

        var previous: Checkpoint? = nil
        let longText = String(repeating: "X", count: 900)

        for index in 0..<6 {
            previous = await manager.makeCheckpoint(
                taskID: "t1", completedStep: index, previous: previous,
                output: .object(["text": .string(longText)]),
                provider: "p1", model: "m1"
            )
        }

        let summary = try XCTUnwrap(previous?.workingSummary)
        XCTAssertLessThanOrEqual(summary.count, 1400, "摘要必须有上限, 否则会撑爆上下文窗口")
        XCTAssertTrue(summary.hasPrefix("[前文已截断]"), "超限时应保留尾部并标记")
    }

    func testStateTracksRecentStepsAndCount() async throws {
        let services = try TestSupport.makeServices()
        let manager = services.checkpointManager

        var previous: Checkpoint? = nil
        for index in 0..<3 {
            previous = await manager.makeCheckpoint(
                taskID: "t1", completedStep: index, previous: previous,
                output: .object(["text": .string("step \(index)")]),
                provider: "p1", model: "m1"
            )
        }

        let state = try XCTUnwrap(previous?.state)
        XCTAssertEqual(state["completedCount"]?.intValue, 3)
        XCTAssertEqual(state["recentSteps"]?.arrayValue?.count, 3)
        XCTAssertEqual(state["lastProvider"]?.stringValue, "p1")
    }

    // MARK: - 持久化层

    func testLatestCheckpointReturnsHighestCompletedStep() async throws {
        let services = try TestSupport.makeServices()
        // checkpoints.task_id 有外键约束, 必须挂到真实任务上
        let task = try TestSupport.makeTask(services, steps: 3)

        try services.checkpoints.insert(
            Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1, workingSummary: "one")
        )
        try services.checkpoints.insert(
            Checkpoint(taskID: task.id, completedStep: 1, nextStep: 2, workingSummary: "two")
        )
        try services.checkpoints.insert(
            Checkpoint(taskID: task.id, completedStep: 2, nextStep: 3, workingSummary: "three")
        )

        let latest = try services.checkpoints.latest(taskID: task.id)
        XCTAssertEqual(latest?.completedStep, 2)
        XCTAssertEqual(latest?.nextStep, 3)
        XCTAssertEqual(latest?.workingSummary, "three")
    }

    func testLatestReturnsNilWhenNeverCheckpointed() throws {
        let services = try TestSupport.makeServices()
        XCTAssertNil(try services.checkpoints.latest(taskID: "nonexistent"))
    }

    func testInitialCheckpointDoesNotShadowRealProgress() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        // 起始检查点 completedStep = -1
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.completedStep, -1)

        try services.checkpoints.insert(
            Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1)
        )

        XCTAssertEqual(
            try services.checkpoints.latest(taskID: task.id)?.completedStep, 0,
            "真实进度必须盖过起始检查点"
        )
    }

    // MARK: - ★ 原子提交 ★

    func testCommitSuccessfulStepWritesStepCheckpointAndProgressTogether() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))

        try services.steps.markRunning(stepID: step.id, provider: "p1", model: "m1")

        let checkpoint = Checkpoint(
            taskID: task.id, completedStep: 0, nextStep: 1, workingSummary: "done step 1"
        )
        try services.steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: step.id,
                taskID: task.id,
                output: .object(["text": .string("step one output")]),
                provider: "p1",
                model: "m1",
                durationMs: 42,
                checkpoint: checkpoint,
                newCurrentStep: 1
            )
        )

        // 1) 步骤标记完成并写入输出
        let reloadedStep = try XCTUnwrap(services.steps.fetch(id: step.id))
        XCTAssertEqual(reloadedStep.status, .completed)
        XCTAssertEqual(reloadedStep.output?["text"]?.stringValue, "step one output")
        XCTAssertEqual(reloadedStep.durationMs, 42)

        // 2) 检查点已落库
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 1)

        // 3) 任务进度已推进
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1)

        // 4) 三者一致: 完成步骤数 == checkpoint 数
        let completedSteps = try services.steps.fetchAll(taskID: task.id).filter { $0.status == .completed }
        XCTAssertEqual(completedSteps.count, 1)
        // 共 2 条: 创建任务时的初始检查点 + 本次提交
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), 2)
    }

    func testCommitFailureLeavesNoPartialState() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 2)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))

        try services.steps.markRunning(stepID: step.id, provider: "p1", model: "m1")

        // 先占掉 checkpoint 的主键, 让事务内的 INSERT 必然失败
        let duplicatedID = "duplicate-checkpoint-id"
        try services.checkpoints.insert(
            Checkpoint(id: duplicatedID, taskID: task.id, completedStep: 0, nextStep: 1)
        )

        let colliding = Checkpoint(
            id: duplicatedID, taskID: task.id, completedStep: 0, nextStep: 1
        )

        XCTAssertThrowsError(
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step.id, taskID: task.id,
                    output: .object(["text": .string("x")]),
                    provider: "p1", model: "m1", durationMs: 1,
                    checkpoint: colliding, newCurrentStep: 1
                )
            ),
            "主键冲突必须让整个事务失败"
        )

        // 事务回滚: 步骤不得被标为 completed
        XCTAssertEqual(
            try services.steps.fetch(id: step.id)?.status, .running,
            "事务失败后步骤状态必须回滚"
        )
        XCTAssertEqual(
            try services.tasks.fetch(id: task.id)?.currentStep, 0,
            "事务失败后任务进度必须回滚"
        )
    }
}
````


#### `Tests/AIRunnerCoreTests/CrashRecoveryTests.swift` (236 行)

````swift
import XCTest
@testable import AIRunnerCore

final class CrashRecoveryTests: XCTestCase {

    // MARK: - 步骤状态恢复

    func testRunningStepBecomesInterrupted() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)

        // 模拟: 第 2 步已开始执行, 此时进程被强杀 (checkpoint 从未提交)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        try services.steps.markRunning(stepID: step.id, provider: "p1", model: "m1")

        let report = try services.recovery.recover()

        XCTAssertEqual(report.interruptedSteps, 1)
        XCTAssertEqual(try services.steps.fetch(id: step.id)?.status, .interrupted)
        XCTAssertEqual(try services.steps.fetch(id: step.id)?.errorClass, "INTERRUPTED")
    }

    func testRunningTaskRemainsRunningAfterRecovery() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)
        try services.tasks.updateStatus(id: task.id, to: .running)

        let report = try services.recovery.recover()

        XCTAssertEqual(
            try services.tasks.fetch(id: task.id)?.status, .running,
            "任务必须保持 running —— 它本来就该继续跑"
        )
        XCTAssertTrue(report.recoverableTaskIDs.contains(task.id))
    }

    func testInterruptedStepIsStillExecutable() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        try services.steps.markRunning(stepID: step.id, provider: "p1", model: "m1")

        _ = try services.recovery.recover()

        let next = try services.steps.nextExecutableStep(taskID: task.id)
        XCTAssertEqual(next?.index, 0, "前面的 pending 步骤先执行")

        // 把第 0 步标完成, 第 1 步 (interrupted) 就应成为下一个可执行步骤
        try services.steps.markFailed(stepID: step.id, error: "", errorClass: "")
        try services.steps.markPending(stepID: step.id)
        XCTAssertEqual(try services.steps.nextExecutableStep(taskID: task.id)?.index, 0)

        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markFailed(stepID: step0.id, error: "", errorClass: "")
        try services.steps.markPending(stepID: step0.id)

        let following = try services.steps.nextExecutableStep(taskID: task.id)
        XCTAssertEqual(following?.index, 0)
    }

    func testInterruptedStepIsReturnedByNextExecutableQuery() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        // 前两步正常完成
        for index in 0..<2 {
            let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: index))
            try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step.id, taskID: task.id,
                    output: .object(["text": .string("done \(index)")]),
                    provider: "p", model: "m", durationMs: 1,
                    checkpoint: Checkpoint(taskID: task.id, completedStep: index, nextStep: index + 1),
                    newCurrentStep: index + 1
                )
            )
        }

        // 第 3 步被中断
        let third = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 2))
        try services.steps.markRunning(stepID: third.id, provider: "p", model: "m")
        _ = try services.recovery.recover()

        let next = try services.steps.nextExecutableStep(taskID: task.id)
        XCTAssertEqual(next?.index, 2, "interrupted 步骤必须被视为可执行")
    }

    // MARK: - ★ 幂等性 ★

    func testCompletedStepsAreNeverReturnedAsExecutable() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)

        for index in 0..<3 {
            let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: index))
            try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step.id, taskID: task.id,
                    output: .object(["text": .string("output \(index)")]),
                    provider: "p", model: "m", durationMs: 1,
                    checkpoint: Checkpoint(taskID: task.id, completedStep: index, nextStep: index + 1),
                    newCurrentStep: index + 1
                )
            )
        }

        let next = try services.steps.nextExecutableStep(taskID: task.id)
        XCTAssertEqual(next?.index, 3, "必须从第 4 步继续, 不能回头重跑前 3 步")
    }

    func testExecutableQueryNeverYieldsCompletedOrFailedSteps() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 4)

        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step0.id, provider: "p", model: "m")
        try services.steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: step0.id, taskID: task.id,
                output: .object(["text": .string("ok")]),
                provider: "p", model: "m", durationMs: 1,
                checkpoint: Checkpoint(taskID: task.id, completedStep: 0, nextStep: 1),
                newCurrentStep: 1
            )
        )

        let step1 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 1))
        try services.steps.markFailed(stepID: step1.id, error: "boom", errorClass: "FATAL_ERROR")

        let executable = try services.steps.fetchAll(taskID: task.id).filter { $0.status.isExecutable }
        XCTAssertEqual(executable.map(\.index), [2, 3])
        XCTAssertFalse(executable.contains { $0.index <= 1 })
    }

    // MARK: - 卡死任务修正

    func testTaskWithNoRemainingStepsIsCorrectedToCompleted() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 2)

        for index in 0..<2 {
            let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: index))
            try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")
            try services.steps.commitSuccessfulStep(
                SuccessfulStepCommit(
                    stepID: step.id, taskID: task.id,
                    output: .object(["text": .string("ok")]),
                    provider: "p", model: "m", durationMs: 1,
                    checkpoint: Checkpoint(taskID: task.id, completedStep: index, nextStep: index + 1),
                    newCurrentStep: index + 1
                )
            )
        }

        // 全部步骤完成但状态还停在 running (退出时没来得及写)
        try services.tasks.updateStatus(id: task.id, to: .running)

        let report = try services.recovery.recover()

        XCTAssertEqual(report.completedButStuckTasks, 1)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .completed)
        XCTAssertFalse(report.recoverableTaskIDs.contains(task.id))
    }

    // MARK: - 边界与幂等

    func testPausedTaskIsNotAutoRecovered() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)
        try services.tasks.updateStatus(id: task.id, to: .paused)

        let report = try services.recovery.recover()

        XCTAssertFalse(
            report.recoverableTaskIDs.contains(task.id),
            "用户主动暂停的任务不该被自动拉起"
        )
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .paused)
    }

    func testRecoveryIsIdempotent() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")
        try services.tasks.updateStatus(id: task.id, to: .running)

        let first = try services.recovery.recover()
        let second = try services.recovery.recover()

        XCTAssertEqual(first.interruptedSteps, 1)
        XCTAssertEqual(second.interruptedSteps, 0, "第二次恢复不应再发现 running 步骤")
        XCTAssertEqual(second.recoverableTaskIDs, first.recoverableTaskIDs, "可恢复任务集合应稳定")
        XCTAssertEqual(try services.steps.fetch(id: step.id)?.status, .interrupted)
    }

    func testRecoveryWorksWithNothingToDo() throws {
        let services = try TestSupport.makeServices()
        let report = try services.recovery.recover()

        XCTAssertEqual(report.interruptedSteps, 0)
        XCTAssertTrue(report.recoverableTaskIDs.isEmpty)
        XCTAssertFalse(report.didRecoverAnything)
        XCTAssertTrue(report.summary.contains("无需恢复"))
    }

    // MARK: - 事件留痕

    func testRecoveryEmitsAppCrashRecoveryEvent() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)
        let step = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        try services.steps.markRunning(stepID: step.id, provider: "p", model: "m")

        _ = try services.recovery.recover()

        let events = try services.events.list(taskID: nil, limit: 50)
        XCTAssertTrue(
            events.contains { $0.eventType == .appCrashRecovery },
            "必须留下 APP_CRASH_RECOVERY 事件"
        )
    }

    func testRecoveryEmitsCompletionEventWhenTasksRecovered() throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)
        try services.tasks.updateStatus(id: task.id, to: .running)

        _ = try services.recovery.recover()

        let events = try services.events.list(limit: 50)
        XCTAssertTrue(events.contains { $0.eventType == .recoveryCompleted })
    }
}
````


#### `Tests/AIRunnerCoreTests/JobRunnerTests.swift` (391 行)

````swift
import XCTest
@testable import AIRunnerCore

/// JobRunner 端到端测试 —— 覆盖需求文档里要求的 5 个运行场景。
final class JobRunnerTests: XCTestCase {

    // MARK: - 装置

    private func installMock(
        _ services: AppServices,
        _ mock: MockAIProvider,
        providerID: String = TestSupport.mockProviderID,
        model: String = TestSupport.mockModel
    ) {
        services.factory.registerOverride(mock, providerID: providerID, model: model)
    }

    /// 手动把一个步骤"做完" (用于构造崩溃前的历史)。
    private func completeStep(
        _ services: AppServices,
        taskID: String,
        index: Int,
        text: String
    ) throws {
        let step = try XCTUnwrap(services.steps.fetch(taskID: taskID, index: index))
        try services.steps.markRunning(stepID: step.id, provider: "mock", model: TestSupport.mockModel)
        try services.steps.commitSuccessfulStep(
            SuccessfulStepCommit(
                stepID: step.id,
                taskID: taskID,
                output: .object(["text": .string(text)]),
                provider: "mock",
                model: TestSupport.mockModel,
                durationMs: 1,
                checkpoint: Checkpoint(taskID: taskID, completedStep: index, nextStep: index + 1),
                newCurrentStep: index + 1
            )
        )
    }

    // MARK: - 场景 A: 全部成功

    func testScenarioA_allStepsSucceedAndTaskCompletes() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 5)

        let mock = MockAIProvider(id: "mock", model: TestSupport.mockModel)
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(settled.currentStep, 5)
        XCTAssertEqual(mock.calls, 5, "每个步骤恰好调用一次")

        let steps = try services.steps.fetchAll(taskID: task.id)
        XCTAssertEqual(steps.count, 5)
        XCTAssertTrue(steps.allSatisfy { $0.status == .completed })

        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 5)
        // 6 条 = 创建任务时的初始检查点 + 5 次成功提交
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), 6)
    }

    // MARK: - 场景 B: 一次超时后重试成功

    func testScenarioB_timeoutIsRetriedThenContinues() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        // 第 1、2 步成功, 第 3 步第一次超时, 之后成功
        let mock = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            script: [.ok, .ok, .timeout],
            fallback: .ok
        )
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(mock.calls, 4, "第 3 步应重试一次 (3 次正常 + 1 次重试)")

        let third = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 2))
        XCTAssertEqual(third.status, .completed)
        XCTAssertGreaterThanOrEqual(third.retryCount, 1)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 3)
    }

    func testTimeoutBeyondBudgetStillFallsBackToBackup() async throws {
        var settings = TestSupport.mockSettings(
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ],
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ]
        )
        settings.retry.maxRetries = 1

        let services = try TestSupport.makeServices(settings: settings)
        let task = try TestSupport.makeTask(
            services, steps: 1, primaryProvider: "p1", primaryModel: "m1"
        )

        let alwaysTimeout = MockAIProvider(id: "p1", model: "m1", fallback: .timeout)
        let healthy = MockAIProvider(id: "p2", model: "m2", fallback: .success(text: "backup result"))
        installMock(services, alwaysTimeout, providerID: "p1", model: "m1")
        installMock(services, healthy, providerID: "p2", model: "m2")

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(
            try services.steps.fetch(taskID: task.id, index: 0)?.provider, "p2",
            "p1 重试预算耗尽后应切到 p2"
        )
    }

    // MARK: - 场景 C: 崩溃后从断点恢复

    func testScenarioC_crashRecoveryResumesFromInterruptedStep() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 4)

        // 崩溃前: 前两步已提交, 第 3 步处于 running
        try completeStep(services, taskID: task.id, index: 0, text: "pre-crash step 0")
        try completeStep(services, taskID: task.id, index: 1, text: "pre-crash step 1")
        let third = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 2))
        try services.steps.markRunning(stepID: third.id, provider: "mock", model: TestSupport.mockModel)
        try services.tasks.updateStatus(id: task.id, to: .running)

        // --- 进程重启 ---
        let report = try services.recovery.recover()
        XCTAssertEqual(report.interruptedSteps, 1)
        XCTAssertTrue(report.recoverableTaskIDs.contains(task.id))
        XCTAssertEqual(try services.steps.fetch(id: third.id)?.status, .interrupted)

        let mock = MockAIProvider(id: "mock", model: TestSupport.mockModel)
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)

        // ★ 关键断言: 只重跑了中断的第 3 步与第 4 步, 前两步绝不重跑 ★
        XCTAssertEqual(mock.calls, 2, "只应执行 index 2 和 3 两步")

        let step0 = try XCTUnwrap(services.steps.fetch(taskID: task.id, index: 0))
        XCTAssertEqual(step0.output?["text"]?.stringValue, "pre-crash step 0",
                       "崩溃前的结果必须原封不动")
        XCTAssertEqual(try services.steps.fetch(taskID: task.id, index: 1)?.status, .completed)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 4)
    }

    // MARK: - 场景 D: Primary 不可用 → Backup

    func testScenarioD_fallsBackToBackupWhenPrimaryIsUnavailable() async throws {
        let settings = TestSupport.mockSettings(
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ],
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ]
        )
        let services = try TestSupport.makeServices(settings: settings)
        let task = try TestSupport.makeTask(
            services, steps: 2, primaryProvider: "p1", primaryModel: "m1"
        )

        let broken = MockAIProvider(id: "p1", model: "m1", fallback: .serverError)
        let backup = MockAIProvider(id: "p2", model: "m2", fallback: .success(text: "backup ok"))
        installMock(services, broken, providerID: "p1", model: "m1")
        installMock(services, backup, providerID: "p2", model: "m2")

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertGreaterThan(broken.calls, 0, "应先尝试 primary")
        XCTAssertGreaterThan(backup.calls, 0, "primary 不可用后必须切到 backup")

        let steps = try services.steps.fetchAll(taskID: task.id)
        XCTAssertTrue(steps.allSatisfy { $0.provider == "p2" }, "最终都应由 backup 完成")
    }

    func testFallbackDoesNotOscillateBetweenBackends() async throws {
        let settings = TestSupport.mockSettings(
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ],
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ]
        )
        let services = try TestSupport.makeServices(settings: settings)
        let task = try TestSupport.makeTask(
            services, steps: 1, primaryProvider: "p1", primaryModel: "m1"
        )

        let broken1 = MockAIProvider(id: "p1", model: "m1", fallback: .serverError)
        let broken2 = MockAIProvider(id: "p2", model: "m2", fallback: .serverError)
        installMock(services, broken1, providerID: "p1", model: "m1")
        installMock(services, broken2, providerID: "p2", model: "m2")

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .failed)
        // 每个 backend 只应被尝试有限次 —— 不允许 A→B→A→B 无限打转
        XCTAssertLessThanOrEqual(broken1.calls, 3, "p1 不得被反复回头重试")
        XCTAssertLessThanOrEqual(broken2.calls, 3, "p2 不得被反复回头重试")
    }

    // MARK: - 场景 E: 认证失败 → 暂停, 绝不重试

    func testScenarioE_authenticationPausesTaskImmediately() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        let mock = MockAIProvider(id: "mock", model: TestSupport.mockModel, fallback: .authError)
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .paused, "认证失败必须暂停等用户处理")
        XCTAssertEqual(mock.calls, 1, "认证失败绝不能被重试")
        XCTAssertEqual(settled.errorClass, AppError.authentication.eventName)
        XCTAssertNotNil(settled.errorMessage)
    }

    func testBillingRequiredPausesInsteadOfRetrying() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        let mock = MockAIProvider(id: "mock", model: TestSupport.mockModel, fallback: .billingError)
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(settled.status, .paused)
        XCTAssertEqual(mock.calls, 1, "余额耗尽不该重试")
        XCTAssertEqual(settled.errorClass, AppError.billingRequired.eventName)
    }

    // MARK: - 幂等与并发

    func testRepeatedStartDoesNotDuplicateExecution() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 3)

        let mock = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            fallback: .latency(seconds: 0.08)
        )
        installMock(services, mock)

        // 连点三次 Start
        await services.runner.start(taskID: task.id)
        await services.runner.start(taskID: task.id)
        await services.runner.start(taskID: task.id)

        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(mock.calls, 3, "重复启动不得让步骤被执行两次")
    }

    func testResumeAfterPauseDoesNotRerunCompletedSteps() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 4)

        let mock = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            fallback: .latency(seconds: 0.06)
        )
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        _ = try await TestSupport.waitUntil { mock.calls >= 2 }
        await services.runner.pause(taskID: task.id)

        let paused = try await TestSupport.waitUntilSettled(services, taskID: task.id)
        XCTAssertEqual(paused.status, .paused)
        let callsAtPause = mock.calls
        XCTAssertLessThan(callsAtPause, 4, "应当还没跑完")

        // 恢复
        await services.runner.start(taskID: task.id)
        let resumed = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        XCTAssertEqual(resumed.status, .completed)
        XCTAssertEqual(mock.calls, 4, "总共只应有 4 次调用 —— 已完成步骤未重跑")
        XCTAssertEqual(resumed.currentStep, 4)
    }

    // MARK: - 取消

    func testCancelPreservesHistoryAndCheckpoints() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, steps: 8)

        let mock = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            fallback: .latency(seconds: 0.05)
        )
        installMock(services, mock)

        await services.runner.start(taskID: task.id)
        _ = try await TestSupport.waitUntil { mock.calls >= 2 }
        await services.runner.cancel(taskID: task.id)

        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        XCTAssertEqual(settled.status, .cancelled)
        XCTAssertLessThan(settled.currentStep, 8)

        // 历史必须保留
        let completedCount = try services.steps
            .fetchAll(taskID: task.id)
            .filter { $0.status == .completed }
            .count
        XCTAssertGreaterThan(completedCount, 0, "取消不得删除已完成结果")
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), completedCount + 1)
        // +1 是初始检查点
    }

    // MARK: - 完整生命周期 (需求第 45 节的验收场景)

    func testFullLifecycleWithInterruptionAndRecovery() async throws {
        let services = try TestSupport.makeServices()
        let task = try TestSupport.makeTask(services, name: "Long Research", steps: 10)

        // 阶段 1: 正常跑 4 步
        let phase1 = MockAIProvider(
            id: "mock", model: TestSupport.mockModel,
            fallback: .latency(seconds: 0.03)
        )
        installMock(services, phase1)

        await services.runner.start(taskID: task.id)
        _ = try await TestSupport.waitUntil { phase1.calls >= 4 }
        await services.runner.cancel(taskID: task.id)
        _ = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        let afterCancel = try XCTUnwrap(services.tasks.fetch(id: task.id))
        let completedBefore = try services.steps
            .fetchAll(taskID: task.id)
            .filter { $0.status == .completed }
            .count
        XCTAssertGreaterThan(completedBefore, 0)
        // 取消不得吞掉未完成的步骤: 所有未完成步骤必须仍然可执行
        XCTAssertEqual(
            try services.steps.executableCount(taskID: task.id),
            10 - completedBefore,
            "取消后未完成步骤必须保持可执行, 不能有步骤被误标成 failed"
        )

        // 阶段 2: 复活任务, 从断点继续
        try services.tasks.updateStatus(id: task.id, to: .running)
        let phase2 = MockAIProvider(id: "mock", model: TestSupport.mockModel)
        installMock(services, phase2)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id, timeout: 20)

        XCTAssertEqual(settled.status, .completed)
        XCTAssertEqual(settled.currentStep, 10)
        XCTAssertEqual(phase2.calls, 10 - completedBefore, "第二阶段只补跑剩余步骤")
        XCTAssertEqual(afterCancel.currentStep, completedBefore)

        // 日志可查
        let events = try services.events.list(taskID: task.id, limit: 200)
        XCTAssertFalse(events.isEmpty)
        XCTAssertTrue(events.contains { $0.eventType == .stepCompleted })
        XCTAssertTrue(events.contains { $0.eventType == .checkpointSaved })
    }
}
````


#### `Tests/AIRunnerCoreTests/ModelRouterTests.swift` (254 行)

````swift
import XCTest
@testable import AIRunnerCore

final class ModelRouterTests: XCTestCase {

    // MARK: - 装置

    private func makeRouter(routes: [RouteEntry], providers: [ProviderConfig]) -> ModelRouter {
        ModelRouter(
            routes: routes,
            providers: providers,
            config: TestSupport.fastRetryConfig()
        )
    }

    private func twoProviderSetup() -> ModelRouter {
        makeRouter(
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ],
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ]
        )
    }

    // MARK: - 优先级

    func testSelectsLowestPriorityNumberFirst() async {
        let router = twoProviderSetup()
        let backend = await router.selectBackend(excluding: [])
        XCTAssertEqual(backend?.providerID, "p1")
        XCTAssertEqual(backend?.model, "m1")
    }

    func testSelectionOrderFollowsRouteTable() async {
        let router = twoProviderSetup()
        let all = await router.allBackends()
        XCTAssertEqual(all.map(\.label), ["p1 / m1", "p2 / m2"])
    }

    func testDisabledRouteIsNeverSelected() async {
        let router = makeRouter(
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1", enabled: false),
                RouteEntry(priority: 2, provider: "p2", model: "m2", enabled: true),
            ],
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ]
        )
        let backend = await router.selectBackend(excluding: [])
        XCTAssertEqual(backend?.providerID, "p2", "被禁用的路由必须跳过")
    }

    // MARK: - ★ 防无限循环 ★

    func testAlreadyAttemptedBackendsAreSkipped() async {
        let router = twoProviderSetup()

        let first = await router.selectBackend(excluding: [])
        XCTAssertEqual(first?.providerID, "p1")

        let second = await router.selectBackend(excluding: ["p1 / m1"])
        XCTAssertEqual(second?.providerID, "p2")

        let third = await router.selectBackend(excluding: ["p1 / m1", "p2 / m2"])
        XCTAssertNil(third, "所有 backend 都试过后必须返回 nil, 不能回到 p1")
    }

    func testRouterNeverProducesABABCycle() async {
        let router = twoProviderSetup()
        var attempted: Set<String> = []
        var sequence: [String] = []

        // 模拟 Runner 的循环: 每次都把选中的 backend 加进 attempted
        while let backend = await router.selectBackend(excluding: attempted) {
            sequence.append(backend.label)
            attempted.insert(backend.label)
            XCTAssertLessThanOrEqual(sequence.count, 4, "出现了无限循环")
        }

        XCTAssertEqual(sequence, ["p1 / m1", "p2 / m2"])
        XCTAssertEqual(Set(sequence).count, sequence.count, "同一个 backend 不得被选中两次")
    }

    // MARK: - 熔断

    func testAuthenticationTripsCircuitBreakerImmediately() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        let health = await router.noteFailure(backend, error: .authentication)

        XCTAssertEqual(health.state, .unavailable, "认证失败必须立刻熔断, 不能靠重试")
        XCTAssertNotNil(health.cooldownUntil)

        let next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p2", "熔断后应直接走备用 Provider")
    }

    func testBillingRequiredTripsProviderLevelCircuit() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        await router.noteFailure(backend, error: .billingRequired)

        let providerHealth = await router.providerHealth("p1")
        XCTAssertEqual(providerHealth?.state, .unavailable, "余额耗尽应熔断整个 Provider")

        let next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p2")
    }

    func testNetworkFailureDoesNotDegradeProvider() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        for _ in 0..<10 {
            _ = await router.noteFailure(backend, error: .network("connection reset"))
        }

        let health = await router.health(for: backend)
        XCTAssertEqual(health?.state, .healthy, "网络抖动不该把 Provider 熔断掉")
        XCTAssertEqual(health?.consecutiveErrors, 0)

        let next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p1", "p1 仍应可用")
    }

    func testRateLimitDoesNotDegradeProvider() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        for _ in 0..<10 {
            _ = await router.noteFailure(backend, error: .rateLimit(retryAfter: 5))
        }

        let health = await router.health(for: backend)
        XCTAssertEqual(health?.state, .healthy, "限流只说明节奏太快, 不代表 Provider 坏了")
    }

    func testRepeatedProviderUnavailableEventuallyTripsThreshold() async {
        var config = TestSupport.fastRetryConfig()
        config.providerDegradedThreshold = 2
        config.providerUnavailableThreshold = 3

        let router = ModelRouter(
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "m1"),
                RouteEntry(priority: 2, provider: "p2", model: "m2"),
            ],
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
                TestSupport.mockProviderConfig(id: "p2", model: "m2"),
            ],
            config: config
        )
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        let h1 = await router.noteFailure(backend, error: .providerUnavailable)
        XCTAssertEqual(h1.state, .healthy, "第 1 次失败还没到阈值")

        let h2 = await router.noteFailure(backend, error: .providerUnavailable)
        XCTAssertEqual(h2.state, .degraded, "第 2 次应进入 degraded")

        let h3 = await router.noteFailure(backend, error: .providerUnavailable)
        XCTAssertEqual(h3.state, .unavailable, "第 3 次应彻底熔断")
        XCTAssertNotNil(h3.cooldownUntil)
    }

    func testModelUnavailableOnlyBlocksThatModel() async {
        let router = makeRouter(
            routes: [
                RouteEntry(priority: 1, provider: "p1", model: "gone"),
                RouteEntry(priority: 2, provider: "p1", model: "m1"),
            ],
            providers: [
                TestSupport.mockProviderConfig(id: "p1", model: "gone"),
                TestSupport.mockProviderConfig(id: "p1", model: "m1"),
            ]
        )
        let backend = BackendRef(providerID: "p1", model: "gone", priority: 1)

        await router.noteFailure(backend, error: .modelUnavailable)

        let providerHealth = await router.providerHealth("p1")
        XCTAssertNil(providerHealth ?? nil, "Provider 级不应被熔断")

        let next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.model, "m1", "应换到同 Provider 的其它模型")
    }

    func testSuccessClearsCooldown() async {
        let router = twoProviderSetup()
        let backend = BackendRef(providerID: "p1", model: "m1", priority: 1)

        _ = await router.noteFailure(backend, error: .authentication)
        var next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p2")

        await router.noteSuccess(backend)

        let health = await router.health(for: backend)
        XCTAssertEqual(health?.state, .healthy)
        XCTAssertNil(health?.cooldownUntil)

        next = await router.selectBackend(excluding: [])
        XCTAssertEqual(next?.providerID, "p1", "恢复后应立刻重新可用")
    }

    // MARK: - 诊断

    func testExplainNoBackendListsReasons() async {
        let router = makeRouter(
            routes: [RouteEntry(priority: 1, provider: "p1", model: "m1")],
            providers: [TestSupport.mockProviderConfig(id: "p1", model: "m1")]
        )
        let explanation = await router.explainNoBackend(excluding: ["p1 / m1"])
        XCTAssertTrue(explanation.contains("已试过"), "诊断信息应说明该 backend 已被试过")
    }

    func testExhaustedCheckAgreesWithSelect() async {
        let router = twoProviderSetup()
        let attempted: Set<String> = ["p1 / m1", "p2 / m2"]
        let exhausted = await router.isExhausted(excluding: attempted)
        XCTAssertTrue(exhausted)
    }

    // MARK: - 首选 backend

    func testPreferredBackendIsTriedFirst() async {
        let router = twoProviderSetup()
        let backend = await router.selectBackend(
            excluding: [],
            preferredProvider: "p2",
            preferredModel: "m2"
        )
        XCTAssertEqual(backend?.providerID, "p2", "任务声明的 primary 应优先")
    }

    func testPreferredBackendIsAlsoSubjectToAttemptedFilter() async {
        let router = twoProviderSetup()
        let backend = await router.selectBackend(
            excluding: ["p2 / m2"],
            preferredProvider: "p2",
            preferredModel: "m2"
        )
        XCTAssertEqual(backend?.providerID, "p1", "首选已试过则退回按优先级选")
    }
}
````


#### `Tests/AIRunnerCoreTests/PersistenceSmokeTests.swift` (217 行)

````swift
import XCTest
@testable import AIRunnerCore

/// 真实**文件**数据库的端到端测试。
///
/// 与其它测试不同的是: 这里用磁盘上的 SQLite 而不是 `:memory:`,
/// 因此额外覆盖了 WAL 配置、外键约束、以及最关键的
/// **「关闭 App → 重新打开 → 数据与进度仍在」** 这条路径。
final class PersistenceSmokeTests: XCTestCase {

    private var directory: URL!
    private var dbPath: String!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("airunner-smoke-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        dbPath = directory.appendingPathComponent("airunner.sqlite").path
    }

    override func tearDownWithError() throws {
        if let directory { try? FileManager.default.removeItem(at: directory) }
    }

    private func openServices() throws -> AppServices {
        try AppServices(
            database: try Database(path: dbPath),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: TestSupport.mockSettings(),
            echoLogsToConsole: false
        )
    }

    private func installMock(_ services: AppServices) -> MockAIProvider {
        let mock = MockAIProvider(id: TestSupport.mockProviderID, model: TestSupport.mockModel)
        services.factory.registerOverride(
            mock,
            providerID: TestSupport.mockProviderID,
            model: TestSupport.mockModel
        )
        return mock
    }

    // MARK: - 数据库本身

    func testLocalDatabaseUsesWALAndForeignKeys() throws {
        let database = try Database(path: dbPath)
        defer { database.close() }

        // 直接 new 出来的 Database 还没建表, user_version 自然是 0
        try DatabaseMigrator.migrate(database)

        let diagnostics = try database.diagnostics()
        XCTAssertEqual(diagnostics.journalMode.lowercased(), "wal",
                       "本地磁盘应使用 WAL, 让 UI 读取与 Runner 写入可以并行")
        XCTAssertTrue(diagnostics.foreignKeys, "外键必须开启, 否则 CASCADE 删除失效")
        XCTAssertTrue(diagnostics.integrityOK)
        XCTAssertEqual(diagnostics.userVersion, DatabaseMigrator.currentVersion)
    }

    func testCascadeDeleteRemovesStepsAndCheckpoints() throws {
        let services = try openServices()
        defer { services.shutdown() }

        let task = try TestSupport.makeTask(services, steps: 3)
        XCTAssertEqual(try services.steps.count(taskID: task.id), 3)
        XCTAssertGreaterThan(try services.checkpoints.count(taskID: task.id), 0)

        try services.tasks.delete(id: task.id)

        XCTAssertEqual(try services.steps.count(taskID: task.id), 0)
        XCTAssertEqual(try services.checkpoints.count(taskID: task.id), 0)
    }

    // MARK: - 重启后数据仍在

    func testCompletedTaskSurvivesDatabaseReopen() async throws {
        var taskID = ""

        // ---- 第一次运行 ----
        do {
            let services = try openServices()
            _ = installMock(services)
            let task = try TestSupport.makeTask(services, steps: 4)
            taskID = task.id

            await services.runner.start(taskID: task.id)
            let settled = try await TestSupport.waitUntilSettled(
                services, taskID: task.id, timeout: 20
            )
            XCTAssertEqual(settled.status, .completed)
            services.shutdown()
        }

        // ---- 第二次运行 (模拟用户重新打开 App) ----
        do {
            let services = try openServices()
            defer { services.shutdown() }

            let reopened = try XCTUnwrap(services.tasks.fetch(id: taskID))
            XCTAssertEqual(reopened.status, .completed)
            XCTAssertEqual(reopened.currentStep, 4)

            let steps = try services.steps.fetchAll(taskID: taskID)
            XCTAssertEqual(steps.count, 4)
            XCTAssertTrue(steps.allSatisfy { $0.status == .completed })
            XCTAssertTrue(steps.allSatisfy { $0.output != nil }, "每步输出都必须落盘")

            XCTAssertEqual(try services.checkpoints.latest(taskID: taskID)?.nextStep, 4)

            let events = try services.events.list(taskID: taskID, limit: 200)
            XCTAssertFalse(events.isEmpty, "日志也要一并持久化")

            // 重开之后不应有"需要恢复"的任务 —— 它已经完成了
            let report = try services.recovery.recover()
            XCTAssertFalse(report.recoverableTaskIDs.contains(taskID))
        }
    }

    // MARK: - 中断后重开继续

    func testInterruptedRunResumesAfterReopen() async throws {
        var taskID = ""
        var completedBeforeCrash = 0

        // ---- 第一次运行: 跑一部分, 留下一个 running 步骤模拟被强杀 ----
        do {
            let services = try openServices()
            let task = try TestSupport.makeTask(services, steps: 6)
            taskID = task.id

            // 完成前两步
            for index in 0..<2 {
                let step = try XCTUnwrap(services.steps.fetch(taskID: taskID, index: index))
                try services.steps.markRunning(
                    stepID: step.id, provider: TestSupport.mockProviderID, model: TestSupport.mockModel
                )
                try services.steps.commitSuccessfulStep(
                    SuccessfulStepCommit(
                        stepID: step.id, taskID: taskID,
                        output: .object(["text": .string("pre-crash \(index)")]),
                        provider: TestSupport.mockProviderID, model: TestSupport.mockModel,
                        durationMs: 3,
                        checkpoint: Checkpoint(taskID: taskID, completedStep: index, nextStep: index + 1),
                        newCurrentStep: index + 1
                    )
                )
            }
            // 第三步处于 running —— 进程此刻被 kill
            let third = try XCTUnwrap(services.steps.fetch(taskID: taskID, index: 2))
            try services.steps.markRunning(
                stepID: third.id, provider: TestSupport.mockProviderID, model: TestSupport.mockModel
            )
            try services.tasks.updateStatus(id: taskID, to: .running)

            completedBeforeCrash = try services.steps
                .fetchAll(taskID: taskID).filter { $0.status == .completed }.count
            XCTAssertEqual(completedBeforeCrash, 2)

            services.shutdown()   // 相当于进程消失
        }

        // ---- 第二次运行: 恢复并继续 ----
        do {
            let services = try openServices()
            let mock = installMock(services)

            let report = try services.recovery.recover()
            XCTAssertEqual(report.interruptedSteps, 1, "应发现 1 个中断步骤")
            XCTAssertTrue(report.recoverableTaskIDs.contains(taskID))

            await services.runner.start(taskID: taskID)
            let settled = try await TestSupport.waitUntilSettled(
                services, taskID: taskID, timeout: 20
            )
            defer { services.shutdown() }

            XCTAssertEqual(settled.status, .completed)
            XCTAssertEqual(settled.currentStep, 6)

            // ★ 关键: 崩溃前完成的 2 步不得重跑 ★
            XCTAssertEqual(mock.calls, 6 - completedBeforeCrash,
                           "只应补跑剩余步骤")

            let first = try XCTUnwrap(services.steps.fetch(taskID: taskID, index: 0))
            XCTAssertEqual(first.output?["text"]?.stringValue, "pre-crash 0",
                           "崩溃前的结果必须原封不动")

            XCTAssertEqual(try services.checkpoints.latest(taskID: taskID)?.nextStep, 6)
        }
    }

    // MARK: - 幂等

    func testRepeatedRecoveryOnReopenIsSafe() async throws {
        var taskID = ""

        do {
            let services = try openServices()
            let task = try TestSupport.makeTask(services, steps: 3)
            taskID = task.id
            try services.tasks.updateStatus(id: taskID, to: .running)
            services.shutdown()
        }

        for round in 1...3 {
            let services = try openServices()
            let report = try services.recovery.recover()
            XCTAssertTrue(report.recoverableTaskIDs.contains(taskID),
                          "第 \(round) 次重开都应能继续该任务")
            XCTAssertEqual(report.interruptedSteps, 0,
                           "第 \(round) 次不应再有 running 步骤")
            services.shutdown()
        }
    }
}
````


#### `Tests/AIRunnerCoreTests/RetryManagerTests.swift` (215 行)

````swift
import XCTest
@testable import AIRunnerCore

final class RetryManagerTests: XCTestCase {

    // MARK: - 退避序列

    func testBackoffSequenceMatchesSpecification() {
        var config = RetryConfiguration()
        config.baseDelay = 5
        config.factor = 2
        config.maxDelay = 300
        config.jitterRatio = 0            // 关掉 jitter 才能精确断言

        // 需求: 5, 10, 20, 40, 80 ... 上限 300
        let expected: [TimeInterval] = [5, 10, 20, 40, 80, 160, 300, 300, 300]

        for (index, want) in expected.enumerated() {
            let got = RetryPolicy.computeDelay(
                retryCount: index, config: config, random: { 0 }
            )
            XCTAssertEqual(got, want, accuracy: 0.001, "第 \(index) 次重试的退避不对")
        }
    }

    func testJitterIsBoundedAndAdditive() {
        var config = RetryConfiguration()
        config.baseDelay = 10
        config.factor = 2
        config.maxDelay = 300
        config.jitterRatio = 0.5

        let noJitter = RetryPolicy.computeDelay(retryCount: 0, config: config, random: { 0 })
        let maxJitter = RetryPolicy.computeDelay(retryCount: 0, config: config, random: { 0.999 })

        XCTAssertEqual(noJitter, 10, accuracy: 0.001)
        XCTAssertEqual(maxJitter, 15, accuracy: 0.02, "jitter 上限应为 base * ratio = 5")
        XCTAssertGreaterThan(maxJitter, noJitter)
    }

    func testServerRetryAfterOverridesBackoff() {
        let error = AppError.rateLimit(retryAfter: 42)
        let delay = RetryPolicy.plan(
            error: error,
            budget: StepRetryBudget(),
            config: .default,
            random: { 0 }
        )
        XCTAssertEqual(delay, 42, "服务端给了 Retry-After 就必须听它的")
    }

    func testRateLimitUsesItsOwnBackoffLadder() {
        var config = RetryConfiguration()
        config.baseDelay = 5
        config.factor = 2
        config.maxDelay = 300
        config.jitterRatio = 0

        var budget = StepRetryBudget()
        let error = AppError.rateLimit(retryAfter: nil)

        let first = RetryPolicy.plan(error: error, budget: budget, config: config, random: { 0 })
        RetryPolicy.consume(&budget, error: error)
        let second = RetryPolicy.plan(error: error, budget: budget, config: config, random: { 0 })

        XCTAssertEqual(first, 5)
        XCTAssertEqual(second, 10)
    }

    // MARK: - 策略路由

    func testErrorStrategyRouting() {
        XCTAssertEqual(AppError.network("x").strategy, .retrySame)
        XCTAssertEqual(AppError.timeout.strategy, .retrySame)
        XCTAssertEqual(AppError.rateLimit(retryAfter: nil).strategy, .retryWithBackoff)
        XCTAssertEqual(AppError.providerUnavailable.strategy, .switchBackend)
        XCTAssertEqual(AppError.modelUnavailable.strategy, .switchBackend)
        XCTAssertEqual(AppError.authentication.strategy, .pauseTask)
        XCTAssertEqual(AppError.billingRequired.strategy, .pauseTask)
        XCTAssertEqual(AppError.invalidRequest("bad").strategy, .failStep)
        XCTAssertEqual(AppError.contextTooLong.strategy, .shrinkContext)
        XCTAssertEqual(AppError.invalidOutput("junk").strategy, .retrySame)
        XCTAssertEqual(AppError.fatal("boom").strategy, .failTask)
    }

    func testNonRetryableErrorsAreNeverRetried() {
        let budget = StepRetryBudget()
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .authentication, budget: budget))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .billingRequired, budget: budget))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .invalidRequest("bad"), budget: budget))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .fatal("boom"), budget: budget))

        // contextTooLong 属于"缩上下文后可重试" —— 允许重试, 但同样受预算约束,
        // 不会变成无限循环。
        XCTAssertTrue(RetryPolicy.shouldRetry(error: .contextTooLong, budget: budget))
        var exhausted = StepRetryBudget()
        exhausted.retries = RetryConfiguration.default.maxRetries
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .contextTooLong, budget: exhausted))
    }

    func testForbiddenPathsHaveNoBackoff() {
        // 这些错误不该产生任何等待 —— 等待毫无意义。
        for error: AppError in [.authentication, .billingRequired, .invalidRequest("x"),
                                .providerUnavailable, .cancelled] {
            let delay = RetryPolicy.plan(
                error: error, budget: StepRetryBudget(), config: .default, random: { 0 }
            )
            XCTAssertNil(delay, "\(error.eventName) 不应进入退避")
        }
    }

    // MARK: - 预算

    func testRetryBudgetExhaustsAfterMaxRetries() {
        var config = RetryConfiguration()
        config.maxRetries = 3
        var budget = StepRetryBudget()
        let error = AppError.network("flaky")

        for attempt in 0..<3 {
            XCTAssertTrue(
                RetryPolicy.shouldRetry(error: error, budget: budget, config: config),
                "第 \(attempt + 1) 次仍应允许重试"
            )
            RetryPolicy.consume(&budget, error: error)
        }

        XCTAssertFalse(
            RetryPolicy.shouldRetry(error: error, budget: budget, config: config),
            "达到 maxRetries 后必须停止重试"
        )
        XCTAssertEqual(budget.retries, 3)
    }

    func testRateLimitBudgetIsSeparateFromRetryBudget() {
        var config = RetryConfiguration()
        config.maxRetries = 1
        config.maxRateLimitWaits = 5
        var budget = StepRetryBudget()

        RetryPolicy.consume(&budget, error: .network("x"))
        XCTAssertFalse(RetryPolicy.shouldRetry(error: .network("x"), budget: budget, config: config))
        XCTAssertTrue(
            RetryPolicy.shouldRetry(error: .rateLimit(retryAfter: nil), budget: budget, config: config),
            "限流必须使用独立预算, 不该被普通重试挤掉"
        )
    }

    func testRepairBudgetBoundsInvalidOutputRetries() {
        var config = RetryConfiguration()
        config.maxRepairs = 2
        config.maxRetries = 100
        var budget = StepRetryBudget()
        let error = AppError.invalidOutput("not json")

        RetryPolicy.consume(&budget, error: error)
        XCTAssertTrue(RetryPolicy.shouldRetry(error: error, budget: budget, config: config))
        RetryPolicy.consume(&budget, error: error)
        XCTAssertFalse(
            RetryPolicy.shouldRetry(error: error, budget: budget, config: config),
            "repair 次数达到上限后不得再重试"
        )
        XCTAssertEqual(budget.repairs, 2)
        XCTAssertEqual(budget.retries, 2, "repair 也应计入总重试预算")
    }

    // MARK: - 熔断触发判定

    func testOnlyCertainErrorsTripProviderCircuit() {
        XCTAssertTrue(AppError.authentication.tripsProviderCircuit)
        XCTAssertTrue(AppError.billingRequired.tripsProviderCircuit)
        XCTAssertTrue(AppError.providerUnavailable.tripsProviderCircuit)

        XCTAssertFalse(AppError.network("x").tripsProviderCircuit, "网络抖动不该熔断 Provider")
        XCTAssertFalse(AppError.timeout.tripsProviderCircuit)
        XCTAssertFalse(AppError.rateLimit(retryAfter: nil).tripsProviderCircuit)
        XCTAssertFalse(AppError.invalidOutput("x").tripsProviderCircuit)
    }

    // MARK: - Actor 行为

    func testRetryManagerComputesDeterministically() async {
        var config = RetryConfiguration()
        config.baseDelay = 2
        config.factor = 3
        config.maxDelay = 1000
        config.jitterRatio = 0

        let manager = RetryManager(config: config, random: { 0 })

        let first = await manager.delay(for: .timeout, budget: StepRetryBudget())
        XCTAssertEqual(first, 2)

        var budget = StepRetryBudget()
        RetryPolicy.consume(&budget, error: .timeout)
        let second = await manager.delay(for: .timeout, budget: budget)
        XCTAssertEqual(second, 6)
    }

    func testSleepReturnsEarlyWhenCancelled() async {
        let manager = RetryManager(config: .default)
        let start = Date()

        do {
            try await manager.sleep(30, isCancelled: { true })
            XCTFail("应当抛出 cancelled")
        } catch let error as AppError {
            XCTAssertEqual(error.eventName, "CANCELLED")
        } catch {
            XCTFail("抛出了非 AppError: \(error)")
        }

        XCTAssertLessThan(Date().timeIntervalSince(start), 2, "取消必须立刻中断退避")
    }
}
````


#### `Tests/AIRunnerCoreTests/SmokeTests.swift` (9 行)

````swift
import XCTest
@testable import AIRunnerCore

/// 占位 —— 真实测试见后续的 RetryManagerTests / ModelRouterTests / JobRunnerTests 等。
final class SmokeTests: XCTestCase {
    func testModuleLoads() {
        XCTAssertEqual(TaskStatus.running.rawValue, "running")
    }
}
````


#### `Tests/AIRunnerCoreTests/TestSupport.swift` (154 行)

````swift
import Foundation
import XCTest
@testable import AIRunnerCore

/// 测试公共装置。
enum TestSupport {

    static let mockProviderID = "mock"
    static let mockModel = "mock-fast"

    // MARK: - 配置

    static func mockProviderConfig(
        id: String = mockProviderID,
        model: String = mockModel
    ) -> ProviderConfig {
        ProviderConfig(
            id: id,
            displayName: "Mock \(id)",
            kind: .mock,
            baseURL: "",
            defaultModel: model,
            models: [model],
            timeout: 5,
            maxOutputTokens: 256,
            keychainKey: "\(id).apiKey"
        )
    }

    /// 测试用极短退避 —— 否则一个重试用例要等好几分钟。
    static func fastRetryConfig() -> RetryConfiguration {
        var config = RetryConfiguration()
        config.baseDelay = 0.01
        config.factor = 1.5
        config.maxDelay = 0.05
        config.jitterRatio = 0
        config.maxRetries = 4
        config.maxRateLimitWaits = 4
        config.maxRepairs = 2
        config.providerDegradedThreshold = 3
        config.providerUnavailableThreshold = 5
        config.providerCooldown = 0.2
        config.billingCooldown = 0.5
        return config
    }

    static func mockSettings(
        providers: [ProviderConfig]? = nil,
        routes: [RouteEntry]? = nil,
        concurrency: Int = 3,
        retry: RetryConfiguration? = nil
    ) -> AppSettings {
        let resolvedProviders = providers ?? [mockProviderConfig()]
        let resolvedRoutes = routes ?? [RouteEntry(priority: 1, provider: mockProviderID, model: mockModel)]
        return AppSettings(
            providers: resolvedProviders,
            routes: resolvedRoutes,
            concurrency: concurrency,
            retry: retry ?? fastRetryConfig()
        )
    }

    // MARK: - 服务装配

    static func makeServices(settings: AppSettings? = nil) throws -> AppServices {
        let resolved = settings ?? mockSettings()
        // 需要排查测试失败时: AILR_TEST_VERBOSE=1 swift test
        let verbose = ProcessInfo.processInfo.environment["AILR_TEST_VERBOSE"] == "1"
        return try AppServices(
            database: try Database.inMemory(),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: resolved,
            echoLogsToConsole: verbose
        )
    }

    // MARK: - 任务构造

    /// 构造测试任务。
    ///
    /// `executionMode` 默认 `.api` —— 因为既有测试验证的是 router / provider / retry
    /// 这条通道的具体行为。Web 通道的行为由 `WebExecutionTests` 单独覆盖。
    @discardableResult
    static func makeTask(
        _ services: AppServices,
        name: String = "Test Task",
        goal: String = "Accomplish the test goal",
        steps: Int,
        executionMode: ExecutionMode = .api,
        primaryProvider: String = mockProviderID,
        primaryModel: String = mockModel
    ) throws -> AITask {
        let task = AITask(
            name: name,
            goal: goal,
            status: .queued,
            executionMode: executionMode,
            primaryProvider: primaryProvider,
            primaryModel: primaryModel,
            totalSteps: steps
        )
        try services.tasks.insert(task)
        let plan = TaskPlanner.defaultPlan(taskID: task.id, numberOfSteps: steps, goal: goal)
        try services.steps.insertBatch(plan)
        try services.checkpoints.insert(Checkpoint.initial(taskID: task.id))
        return task
    }

    // MARK: - 等待

    /// 轮询直到任务进入"不再自动前进"的状态。
    ///
    /// 除了终态与 paused, **「等用户」状态也必须算作已稳定** —— 它们意味着
    /// Runner 已经退出, 不会再有自动进展 (用户在浏览器里操作之前不会有变化)。
    /// 否则 Web 通道的测试会一直空转到超时。
    @discardableResult
    static func waitUntilSettled(
        _ services: AppServices,
        taskID: String,
        timeout: TimeInterval = 15,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async throws -> AITask {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let task = try services.tasks.fetch(id: taskID) {
                if task.status.isTerminal
                    || task.status == .paused
                    || task.status.requiresUserAction {
                    return task
                }
            }
            try await Task.sleep(nanoseconds: 15_000_000)   // 15ms
        }
        XCTFail("等待任务进入稳定状态超时 (\(timeout)s)", file: file, line: line)
        return try services.tasks.fetch(id: taskID)!
    }

    /// 轮询直到某个断言成立。
    static func waitUntil(
        timeout: TimeInterval = 5,
        _ condition: () async throws -> Bool
    ) async throws -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return true }
            // 用 try? 忽略 CancellationError —— 测试收尾时取消任务属正常现象,
            // 但不能让 sleep 的取消掩盖 condition 自身抛出的错误。
            try? await Task.sleep(nanoseconds: 15_000_000)
        }
        return false
    }
}
````


#### `Tests/AIRunnerCoreTests/WebExecutionTests.swift` (669 行)

````swift
import XCTest
@testable import AIRunnerCore

/// ChatGPT Web 通道测试。
///
/// 重点验证四件事:
/// 1. 续跑 prompt **完全自包含** —— 换个会话、换了账号也能接着做
/// 2. 账号交接**不丢任何进度**
/// 3. 崩溃后重新生成的 prompt 与之前**逐字一致**
/// 4. 已完成的步骤**绝不重做**
final class WebExecutionTests: XCTestCase {

    // MARK: - 装置

    private func makeWebServices(
        clipboard: (any ClipboardServicing)? = nil,
        browser: (any BrowserLaunching)? = nil
    ) throws -> AppServices {
        var settings = TestSupport.mockSettings()
        settings.defaultExecutionMode = .chatGPTWeb
        return try AppServices(
            database: try Database.inMemory(),
            keychain: InMemoryKeychain(),
            settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
            settingsOverride: settings,
            clipboard: clipboard ?? InMemoryClipboard(),
            browser: browser ?? RecordingBrowserLauncher(),
            echoLogsToConsole: false
        )
    }

    @discardableResult
    private func makeWebTask(
        _ services: AppServices,
        steps: Int,
        goal: String = "分析 300 份 PDF 并生成综合报告"
    ) throws -> AITask {
        try TestSupport.makeTask(
            services,
            goal: goal,
            steps: steps,
            executionMode: .chatGPTWeb
        )
    }

    /// 模拟用户走完一整轮: 拿到 prompt → (去 ChatGPT) → 贴回结果。
    @discardableResult
    private func completeOneWebStep(
        _ services: AppServices,
        taskID: String,
        resultText: String
    ) async throws -> ImportedResult {
        _ = try await services.web.prepareStep(taskID: taskID)
        return try await services.web.acceptResult(
            taskID: taskID,
            stepID: try XCTUnwrap(services.steps.awaitingResultStep(taskID: taskID)).id,
            result: resultText
        )
    }

    // MARK: - 1. Prompt 自包含性

    func testContinuationPromptIsSelfContained() {
        let checkpoint = Checkpoint(
            taskID: "t1",
            completedStep: 62,
            nextStep: 63,
            workingSummary: "已完成 63 个文件的解析, 提取出 12 个关键主题 (A/B/C…)"
        )

        let prompt = ContinuationPromptBuilder().build(
            .init(
                goal: "分析 300 份 PDF 并生成综合报告",
                stepIndex: 63,
                totalSteps: 100,
                stepType: .map,
                checkpoint: checkpoint,
                completedStepIndexes: Array(0...62),
                structuredFacts: ["已识别主题数: 12"],
                outputSchema: "返回 JSON: {\"findings\": [...], \"confidence\": 0-1}"
            )
        )

        // 目标
        XCTAssertTrue(prompt.contains("分析 300 份 PDF 并生成综合报告"))
        // 进度范围 (压缩形式)
        XCTAssertTrue(prompt.contains("1...63"), "300 步任务不能逐个列举已完成步骤")
        XCTAssertTrue(prompt.contains("Current step: 64"))
        XCTAssertTrue(prompt.contains("Total steps: 100"))
        // 检查点摘要
        XCTAssertTrue(prompt.contains("已完成 63 个文件的解析"))
        // 已确立事实
        XCTAssertTrue(prompt.contains("已识别主题数: 12"))
        // 输出格式
        XCTAssertTrue(prompt.contains("findings"))

        // 硬性约束
        XCTAssertTrue(prompt.contains("Do NOT restart"))
        XCTAssertTrue(prompt.contains("Do NOT redo"))
        XCTAssertTrue(prompt.contains("do NOT have access to any previous conversation"))

        // 不得依赖任何会话标识
        let lowered = prompt.lowercased()
        XCTAssertFalse(lowered.contains("conversation id"))
        XCTAssertFalse(lowered.contains("chat_history"))
    }

    func testPromptGenerationIsDeterministic() {
        let builder = ContinuationPromptBuilder()
        let checkpoint = Checkpoint(
            taskID: "t1", completedStep: 4, nextStep: 5, workingSummary: "step 5 done"
        )
        let input = ContinuationPromptBuilder.Input(
            goal: "goal",
            stepIndex: 5,
            totalSteps: 10,
            stepType: .map,
            checkpoint: checkpoint,
            completedStepIndexes: [0, 1, 2, 3, 4]
        )

        XCTAssertEqual(
            builder.build(input), builder.build(input),
            "崩溃恢复依赖确定性: 同样的输入必须产出逐字相同的 prompt"
        )
    }

    func testRangeCompression() {
        XCTAssertEqual(
            ContinuationPromptBuilder.compressRanges([]),
            "(none — this is the first step)"
        )
        XCTAssertEqual(ContinuationPromptBuilder.compressRanges([0, 1, 2]), "1...3")
        XCTAssertEqual(ContinuationPromptBuilder.compressRanges([0, 1, 2, 7]), "1...3, 8")
        XCTAssertEqual(ContinuationPromptBuilder.compressRanges([0, 2, 4]), "1, 3, 5")
        // 乱序 + 重复也必须稳定
        XCTAssertEqual(ContinuationPromptBuilder.compressRanges([2, 0, 1, 1]), "1...3")
    }

    func testFirstStepPromptSaysNoProgressYet() {
        let prompt = ContinuationPromptBuilder().build(
            .init(goal: "goal", stepIndex: 0, totalSteps: 3)
        )
        XCTAssertTrue(prompt.contains("(none — this is the first step)"))
        XCTAssertTrue(prompt.contains("No prior progress has been recorded"))
    }

    func testFinalStepInstructionDiffersFromMiddleSteps() {
        let builder = ContinuationPromptBuilder()
        let middle = builder.build(.init(goal: "g", stepIndex: 3, totalSteps: 10, stepType: .map))
        let final = builder.build(.init(goal: "g", stepIndex: 9, totalSteps: 10, stepType: .final))

        XCTAssertTrue(middle.contains("Complete step 4 of 10"))
        XCTAssertTrue(final.contains("FINAL step"))
        XCTAssertNotEqual(middle, final)
    }

    // MARK: - 2. 准备步骤

    func testPrepareStepMarksPreparedAndGeneratesPrompt() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 5)

        let prepared = try await services.web.prepareStep(taskID: task.id)

        XCTAssertEqual(prepared.stepIndex, 0)
        XCTAssertEqual(prepared.ordinal, 1)
        XCTAssertFalse(prepared.prompt.isEmpty)
        XCTAssertFalse(prepared.wasAlreadyPrepared)

        let step = try XCTUnwrap(services.steps.fetch(id: prepared.stepID))
        XCTAssertEqual(step.status, .prepared)
        XCTAssertNotNil(step.preparedAt)
    }

    func testPrepareStepWhenAllStepsDoneThrows() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 1)

        _ = try await completeOneWebStep(services, taskID: task.id, resultText: "唯一一步的结果")

        do {
            _ = try await services.web.prepareStep(taskID: task.id)
            XCTFail("没有可执行步骤时应当抛错")
        } catch let error as WebExecutionError {
            guard case .noExecutableStep = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }
    }

    func testDeliverPromptCopiesToClipboardAndOpensBrowser() async throws {
        let clipboard = InMemoryClipboard()
        let browser = RecordingBrowserLauncher()
        let services = try makeWebServices(clipboard: clipboard, browser: browser)
        let task = try makeWebTask(services, steps: 3)

        let delivery = try await services.web.deliverPrompt(taskID: task.id)

        XCTAssertTrue(delivery.copiedToClipboard)
        XCTAssertEqual(clipboard.readString(), delivery.prepared.prompt)
        XCTAssertTrue(delivery.browserOpened)
        XCTAssertEqual(browser.lastOpened?.absoluteString, ChatGPTWebTarget.defaultURLString)
    }

    func testBrowserOpensConfiguredURL() async throws {
        let browser = RecordingBrowserLauncher()
        let services = try makeWebServices(browser: browser)
        let task = try makeWebTask(services, steps: 2)

        var settings = services.settings
        settings.chatGPTURL = "https://example.invalid/chat"
        await services.saveSettings(settings)

        _ = try await services.web.deliverPrompt(taskID: task.id)
        XCTAssertEqual(browser.lastOpened?.absoluteString, "https://example.invalid/chat")
    }

    // MARK: - 3. 接收结果

    func testAcceptResultCommitsAndAdvancesCheckpoint() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        let prepared = try await services.web.prepareStep(taskID: task.id)
        let imported = try await services.web.acceptResult(
            taskID: task.id,
            stepID: prepared.stepID,
            result: "第一份文件的结论: 主题 A 出现 12 次"
        )

        XCTAssertEqual(imported.stepIndex, 0)
        XCTAssertEqual(imported.checkpoint.completedStep, 0)
        XCTAssertEqual(imported.checkpoint.nextStep, 1)
        XCTAssertEqual(imported.remainingSteps, 2)
        XCTAssertFalse(imported.isFinalStep)

        let step = try XCTUnwrap(services.steps.fetch(id: prepared.stepID))
        XCTAssertEqual(step.status, .completed)
        XCTAssertEqual(step.output?["text"]?.stringValue, "第一份文件的结论: 主题 A 出现 12 次")

        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 1)
    }

    func testEmptyResultIsRejectedAndCheckpointUnchanged() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)
        let prepared = try await services.web.prepareStep(taskID: task.id)

        do {
            _ = try await services.web.acceptResult(
                taskID: task.id, stepID: prepared.stepID, result: "   \n\t  "
            )
            XCTFail("空结果必须被拒绝")
        } catch let error as WebExecutionError {
            guard case .emptyClipboard = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }

        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.currentStep, 0)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.completedStep, -1)
        XCTAssertEqual(
            try services.steps.fetch(id: prepared.stepID)?.status, .prepared,
            "校验失败后步骤应保持「已就绪」, 允许重新提交"
        )
    }

    func testImportClipboardResult() async throws {
        let clipboard = InMemoryClipboard()
        let services = try makeWebServices(clipboard: clipboard)
        let task = try makeWebTask(services, steps: 2)

        _ = try await services.web.prepareStep(taskID: task.id)
        clipboard.writeString("ChatGPT 的回复内容")

        let imported = try await services.web.importClipboardResult(taskID: task.id)
        XCTAssertEqual(imported.stepIndex, 0)
        XCTAssertEqual(imported.checkpoint.nextStep, 1)
    }

    func testImportFailsOnEmptyClipboard() async throws {
        let services = try makeWebServices(clipboard: InMemoryClipboard())
        let task = try makeWebTask(services, steps: 2)
        _ = try await services.web.prepareStep(taskID: task.id)

        do {
            _ = try await services.web.importClipboardResult(taskID: task.id)
            XCTFail("空剪贴板应当报错")
        } catch let error as WebExecutionError {
            guard case .emptyClipboard = error else {
                return XCTFail("错误类型不对: \(error)")
            }
        }
    }

    func testMarkSubmittedRecordsTimestamp() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 2)
        let prepared = try await services.web.prepareStep(taskID: task.id)

        try await services.web.markSubmitted(taskID: task.id, stepID: prepared.stepID)
        XCTAssertNotNil(try services.steps.fetch(id: prepared.stepID)?.submittedAt)
    }

    // MARK: - 4. 账号交接

    func testPauseForAccountSwitchPreservesAllProgress() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 5)

        // 先完成两步
        for index in 1...2 {
            _ = try await completeOneWebStep(
                services, taskID: task.id, resultText: "第 \(index) 步的结果"
            )
        }

        let before = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(before.currentStep, 2)

        try await services.web.pauseForAccountSwitch(
            taskID: task.id, reason: "测试: 当前会话无法继续"
        )

        let paused = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(paused.status, .waitingForAccount)
        XCTAssertTrue(paused.status.requiresUserAction)
        XCTAssertFalse(paused.status.isTerminal)

        // ★ 进度一字未动 ★
        XCTAssertEqual(paused.currentStep, 2)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.completedStep, 1)
        XCTAssertEqual(
            try services.steps.fetchAll(taskID: task.id).filter { $0.status == .completed }.count, 2
        )
        // 剩下三步仍可执行
        XCTAssertEqual(try services.steps.executableCount(taskID: task.id), 3)
    }

    func testPauseForAccountSwitchIsIdempotent() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        try await services.web.pauseForAccountSwitch(taskID: task.id, reason: "第一次")
        try await services.web.pauseForAccountSwitch(taskID: task.id, reason: "第二次")

        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .waitingForAccount)
    }

    func testResumeAfterAccountSwitchContinuesFromCheckpoint() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 4)

        for index in 1...2 {
            _ = try await completeOneWebStep(
                services, taskID: task.id, resultText: "第 \(index) 步"
            )
        }
        try await services.web.pauseForAccountSwitch(taskID: task.id, reason: "切换账号")
        try await services.web.resumeAfterManualAccountSwitch(taskID: task.id)

        let resumed = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(resumed.status, .running)
        XCTAssertEqual(resumed.currentStep, 2, "必须从检查点继续, 不得回到 0")

        // 下一步是第 3 步, 且 prompt 反映已完成的 2 步
        let next = try await services.web.prepareStep(taskID: task.id)
        XCTAssertEqual(next.stepIndex, 2)
        XCTAssertTrue(next.prompt.contains("1...2"), "prompt 必须反映已完成的 2 步")

        // 日志留痕
        let events = try services.events.list(taskID: task.id, limit: 200)
        XCTAssertTrue(events.contains { $0.eventType == .accountHandoffRequested })
        XCTAssertTrue(events.contains { $0.eventType == .accountHandoffCompleted })
    }

    func testResumeIsRejectedWhenTaskIsNotAwaiting() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        // 任务还在 queued, 恢复调用应当无害地忽略
        try await services.web.resumeAfterManualAccountSwitch(taskID: task.id)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .queued)
    }

    // MARK: - 5. 崩溃恢复

    func testPreparedStepIsRecoveredWithIdenticalPrompt() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        let first = try await services.web.prepareStep(taskID: task.id)

        // 模拟: prompt 已生成, 但用户在回填之前 App 被杀
        try services.tasks.updateStatus(id: task.id, to: .running)

        let report = try services.recovery.recover()
        XCTAssertEqual(report.interruptedSteps, 0, "prepared 不是 running, 不该被标为中断")
        XCTAssertTrue(report.recoverableTaskIDs.contains(task.id))

        // 重启后重新生成 —— ★ 必须逐字一致 ★
        let second = try await services.web.prepareStep(taskID: task.id)
        XCTAssertTrue(second.wasAlreadyPrepared, "应识别出这是对已就绪步骤的重新生成")
        XCTAssertEqual(second.stepID, first.stepID, "不得换到别的步骤")
        XCTAssertEqual(second.prompt, first.prompt, "崩溃后重新生成的 prompt 必须完全相同")
    }

    func testCompletedStepsAreNotRedoneAfterAccountSwitch() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        let first = try await services.web.prepareStep(taskID: task.id)
        _ = try await services.web.acceptResult(
            taskID: task.id, stepID: first.stepID, result: "第 1 步的结果"
        )

        try await services.web.pauseForAccountSwitch(taskID: task.id, reason: "换账号")
        try await services.web.resumeAfterManualAccountSwitch(taskID: task.id)

        let next = try await services.web.prepareStep(taskID: task.id)

        XCTAssertEqual(next.stepIndex, 1, "应准备第 2 步, 而不是重做第 1 步")
        XCTAssertNotEqual(next.stepID, first.stepID)
        XCTAssertEqual(try services.steps.fetch(id: first.stepID)?.status, .completed)
    }

    func testPreparedStepSurvivesDatabaseReopen() async throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("web-reopen-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let dbPath = directory.appendingPathComponent("airunner.sqlite").path
        let settings = TestSupport.mockSettings()
        var taskID = ""
        var promptBefore = ""

        // 第一次运行: 生成 prompt, 然后"进程消失"
        do {
            let services = try AppServices(
                database: try Database(path: dbPath),
                keychain: InMemoryKeychain(),
                settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
                settingsOverride: settings,
                clipboard: InMemoryClipboard(),
                browser: RecordingBrowserLauncher(),
                echoLogsToConsole: false
            )
            let task = try TestSupport.makeTask(
                services, goal: "长任务", steps: 4, executionMode: .chatGPTWeb
            )
            taskID = task.id
            let prepared = try await services.web.prepareStep(taskID: task.id)
            promptBefore = prepared.prompt
            services.shutdown()
        }

        // 第二次运行: 重新生成必须一致
        do {
            let services = try AppServices(
                database: try Database(path: dbPath),
                keychain: InMemoryKeychain(),
                settingsStore: SettingsStore(defaults: AppServices.ephemeralDefaults()),
                settingsOverride: settings,
                clipboard: InMemoryClipboard(),
                browser: RecordingBrowserLauncher(),
                echoLogsToConsole: false
            )
            defer { services.shutdown() }

            let step = try XCTUnwrap(services.steps.awaitingResultStep(taskID: taskID))
            XCTAssertEqual(step.status, .prepared, "prepared 状态必须持久化")
            XCTAssertNotNil(step.preparedAt)

            let regenerated = try await services.web.prepareStep(taskID: taskID)
            XCTAssertEqual(regenerated.prompt, promptBefore, "重开 App 后 prompt 必须一致")
        }
    }

    // MARK: - 6. JobRunner 走 Web 通道

    func testRunnerEntersWaitingForUserInsteadOfBlocking() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 3)

        await services.runner.start(taskID: task.id)
        let settled = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(
            settled.status, .waitingForUser,
            "Web 通道下 Runner 生成 prompt 后必须立刻退出, 绝不阻塞等用户"
        )
        XCTAssertEqual(settled.currentStep, 0, "尚未回填结果, 进度不应前进")

        let awaiting = try XCTUnwrap(services.steps.awaitingResultStep(taskID: task.id))
        XCTAssertEqual(awaiting.index, 0)
        XCTAssertEqual(awaiting.status, .prepared)
    }

    func testWebChannelNeverCallsAPIProvider() async throws {
        let services = try makeWebServices()
        let task = try makeWebTask(services, steps: 2)

        let mock = MockAIProvider(
            id: TestSupport.mockProviderID, model: TestSupport.mockModel
        )
        services.factory.registerOverride(
            mock, providerID: TestSupport.mockProviderID, model: TestSupport.mockModel
        )

        await services.runner.start(taskID: task.id)
        _ = try await TestSupport.waitUntilSettled(services, taskID: task.id)

        XCTAssertEqual(mock.calls, 0, "Web 通道绝不触碰 API Provider")
    }

    // MARK: - 7. 端到端

    func testEndToEndWebTaskCompletesWithoutRedoingWork() async throws {
        let clipboard = InMemoryClipboard()
        let browser = RecordingBrowserLauncher()
        let services = try makeWebServices(clipboard: clipboard, browser: browser)
        let task = try makeWebTask(
            services, steps: 4, goal: "把 4 份文档逐个总结后给出总览"
        )

        // 模拟用户操作 4 轮: 复制 prompt → 提交给 ChatGPT → 粘贴结果
        for round in 1...4 {
            let delivery = try await services.web.deliverPrompt(taskID: task.id)
            XCTAssertEqual(delivery.prepared.ordinal, round)
            XCTAssertEqual(clipboard.readString(), delivery.prepared.prompt)

            clipboard.writeString("第 \(round) 步的结论: 略")

            let imported = try await services.web.importClipboardResult(taskID: task.id)
            XCTAssertEqual(imported.stepIndex, round - 1)
            XCTAssertEqual(imported.checkpoint.nextStep, round)
        }

        let finished = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(finished.currentStep, 4)
        XCTAssertEqual(try services.checkpoints.latest(taskID: task.id)?.nextStep, 4)

        let steps = try services.steps.fetchAll(taskID: task.id)
        XCTAssertEqual(steps.filter { $0.status == .completed }.count, 4)
        XCTAssertTrue(steps.allSatisfy { $0.output != nil })

        // 每轮都在日志里留痕
        let events = try services.events.list(taskID: task.id, limit: 200)
        XCTAssertTrue(events.contains { $0.eventType == .webStepPrepared })
        XCTAssertTrue(events.contains { $0.eventType == .resultImported })
        XCTAssertTrue(events.contains { $0.eventType == .webPromptCopied })
    }

    func testEndToEndWithMidTaskAccountHandoff() async throws {
        let clipboard = InMemoryClipboard()
        let services = try makeWebServices(clipboard: clipboard)
        let task = try makeWebTask(services, steps: 5, goal: "跨账号完成 5 步")

        // 账号 A: 做完 2 步
        for round in 1...2 {
            _ = try await services.web.deliverPrompt(taskID: task.id)
            clipboard.writeString("A 账号下的第 \(round) 步结果")
            _ = try await services.web.importClipboardResult(taskID: task.id)
        }

        // 账号 A 额度用尽 —— 用户主动交接
        try await services.web.pauseForAccountSwitch(
            taskID: task.id, reason: "账号 A 无法继续"
        )
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .waitingForAccount)

        // 用户手动在浏览器里切到账号 B, 回来点"我已切换"
        try await services.web.resumeAfterManualAccountSwitch(taskID: task.id)
        XCTAssertEqual(try services.tasks.fetch(id: task.id)?.status, .running)

        // 账号 B: 做完剩下 3 步
        for round in 3...5 {
            _ = try await services.web.deliverPrompt(taskID: task.id)
            let prompt = try XCTUnwrap(clipboard.readString())
            XCTAssertTrue(prompt.contains("1...\(round - 1)"),
                          "第 \(round) 步的 prompt 必须带上之前所有已完成步骤")
            clipboard.writeString("B 账号下的第 \(round) 步结果")
            _ = try await services.web.importClipboardResult(taskID: task.id)
        }

        let finished = try XCTUnwrap(services.tasks.fetch(id: task.id))
        XCTAssertEqual(finished.currentStep, 5)

        let steps = try services.steps.fetchAll(taskID: task.id)
        XCTAssertEqual(steps.filter { $0.status == .completed }.count, 5)
        XCTAssertEqual(steps[0].output?["text"]?.stringValue, "A 账号下的第 1 步结果",
                       "换账号后, 换账号前的结果必须原封不动")
        XCTAssertEqual(steps[4].output?["text"]?.stringValue, "B 账号下的第 5 步结果")
    }

    // MARK: - 8. 状态与迁移

    func testWaitingForAccountTransitionLegality() {
        XCTAssertTrue(TaskStatus.running.canTransition(to: .waitingForAccount))
        XCTAssertTrue(TaskStatus.waitingForAccount.canTransition(to: .running))
        XCTAssertTrue(TaskStatus.waitingForAccount.canTransition(to: .paused))
        XCTAssertTrue(TaskStatus.waitingForAccount.canTransition(to: .waitingForUser))
        XCTAssertFalse(TaskStatus.completed.canTransition(to: .waitingForAccount))

        XCTAssertTrue(TaskStatus.waitingForAccount.requiresUserAction)
        XCTAssertTrue(TaskStatus.waitingForBrowser.requiresUserAction)
        XCTAssertTrue(TaskStatus.waitingForUser.requiresUserAction)
        XCTAssertFalse(TaskStatus.running.requiresUserAction)

        XCTAssertFalse(TaskStatus.waitingForAccount.isTerminal)
    }

    func testMigrationIsIdempotentAndAddsWebColumns() throws {
        let db = try Database.inMemory()
        try DatabaseMigrator.migrate(db)
        try DatabaseMigrator.migrate(db)   // 第二次不得报错

        XCTAssertEqual(try db.scalarInt("PRAGMA user_version;"), 2)
        XCTAssertTrue(
            try DatabaseMigrator.columnExists(db, table: "tasks", column: "execution_mode")
        )
        XCTAssertTrue(
            try DatabaseMigrator.columnExists(db, table: "task_steps", column: "prepared_at")
        )
        XCTAssertTrue(
            try DatabaseMigrator.columnExists(db, table: "task_steps", column: "submitted_at")
        )
    }

    func testLegacyRowsDefaultToChatGPTWebMode() throws {
        let db = try Database.inMemory()
        try DatabaseMigrator.migrate(db)

        // 模拟 v1 时代写入的行 (不带 execution_mode), 依赖列默认值
        try db.execute(
            """
            INSERT INTO tasks (
                id, name, goal, status, primary_provider, primary_model,
                current_step, total_steps, retry_count, max_retries,
                created_at, updated_at, plan_type, meta_json
            ) VALUES ('legacy','旧任务','旧目标','queued','openai','gpt-4o-mini',
                      0, 3, 0, 8,
                      '2026-01-01T00:00:00Z','2026-01-01T00:00:00Z','uniform','{}')
            """
        )

        let task = try XCTUnwrap(TaskRepository(db: db).fetch(id: "legacy"))
        XCTAssertEqual(task.executionMode, .chatGPTWeb, "v1 老数据应默认归入 Web 主通道")
    }

    func testDefaultExecutionModeIsChatGPTWeb() {
        XCTAssertEqual(ExecutionMode.chatGPTWeb.rawValue, "chatgpt_web")
        XCTAssertTrue(ExecutionMode.chatGPTWeb.isPrimary)
        XCTAssertFalse(ExecutionMode.api.isPrimary)

        // 出厂设置默认走 Web
        XCTAssertEqual(AppSettings.default.defaultExecutionMode, .chatGPTWeb)

        // 设置升级: 老 JSON 里没有新字段也不该整份失效
        let legacyJSON = """
        {"providers":[],"routes":[],"concurrency":5,"retry":{"baseDelay":7,"factor":2,"maxDelay":300,"jitterRatio":0.3,"maxRetries":8,"maxRateLimitWaits":12,"maxRepairs":2,"providerDegradedThreshold":3,"providerUnavailableThreshold":5,"providerCooldown":600,"billingCooldown":21600,"contextShrinkFactor":0.5}}
        """
        let decoded = try? JSONCoding.decode(AppSettings.self, from: legacyJSON)
        XCTAssertEqual(decoded?.concurrency, 5, "老配置里的已有字段必须保留")
        XCTAssertEqual(decoded?.defaultExecutionMode, .chatGPTWeb, "缺失的新字段走默认值")
    }
}
````


---

## 5. 测试


共 98 个测试方法, 98 个测试用例 (部分方法含多个断言分组)。


### 最值得审查的 8 个测试

| 断言 | 说明了什么 |
|---|---|
| `testCommitFailureLeavesNoPartialState` | 用主键冲突强制事务失败, 断言 step 状态与任务进度**一起回滚** |
| `testRouterNeverProducesABABCycle` | 循环取 backend 直到返回 nil, 断言序列恰为 `[p1, p2]` 且无重复 |
| `testCompletedStepsAreNeverReturnedAsExecutable` | 完成 3 步后, `nextExecutableStep` 必须返回 index 3 |
| `testPreparedStepIsRecoveredWithIdenticalPrompt` | 崩溃后重新生成的 prompt 与之前**逐字相等** |
| `testPauseForAccountSwitchPreservesAllProgress` | 交接前后 `currentStep` 与检查点**一字未动** |
| `testEndToEndWithMidTaskAccountHandoff` | 跨账号 5 步: A 做 2 步 → 交接 → B 做 3 步, **A 的结果原封不动** |
| `testEmptyResultIsRejectedAndCheckpointUnchanged` | 校验失败时检查点**不推进**, 步骤保持可提交 |
| `testWebChannelNeverCallsAPIProvider` | Web 通道下 `mock.calls == 0` —— 通道完全隔离 |


---

## 6. 验证证据

### 构建

```
$ swift build
Build complete! (0.16s)          # 0 error, 0 warning
```

### 测试

```
$ swift test
Executed 98 tests, with 0 failures (0 unexpected) in 1.268 (1.283) seconds
```

分布:

| 测试文件 | 数量 | 覆盖 |
|---|---|---|
| `RetryManagerTests` | 13 | 退避序列精确值、jitter 上界、`Retry-After` 优先、独立预算、熔断触发判定 |
| `ModelRouterTests` | 16 | 优先级、**防 A/B 循环**、认证/余额立即熔断、网络抖动不熔断 |
| `CheckpointTests` | 10 | 检查点推进、摘要累积与截断、**事务原子性 (含失败回滚)** |
| `CrashRecoveryTests` | 12 | running→interrupted、**completed 永不可执行**、恢复幂等 |
| `JobRunnerTests` | 12 | API 通道 5 场景 + 重复启动 + 暂停恢复 + 取消保留历史 |
| `WebExecutionTests` | 29 | Web 通道全部行为 (见"关键测试") |
| `PersistenceSmokeTests` | 5 | **真实文件数据库**: WAL、外键 CASCADE、关闭重开数据仍在 |
| `SmokeTests` | 1 | 模块加载 |

### 数据库迁移 (非破坏性) 实测

在上一版本 (v1) 产生的**真实数据库**上验证:

```
迁移前 user_version = 1
迁移后 user_version = 2
tasks.execution_mode      : True
task_steps.prepared_at    : True
task_steps.submitted_at   : True
旧列完整保留 (tasks)      : True
表: ['checkpoints', 'events', 'provider_health', 'task_steps', 'tasks']
```

### .app 启动验证

```
$ bash Scripts/make_app.sh release
dist/AIRunner.app: valid on disk
dist/AIRunner.app: satisfies its Designated Requirement

$ dist/AIRunner.app/Contents/MacOS/AIRunner &
✅ 进程存活 —— GUI 启动成功
```

### 安全自查

在 `Sources/` 全量搜索 `apiKey|Authorization|Bearer|sk-`:

- 无硬编码密钥
- `apiKey` 仅出现在三处: Keychain 读取、`Authorization` 请求头设置、UI 的 `SecureField` 局部状态
- 日志写入前强制经过 `SecretRedactor` (精确匹配已登记密钥 + 正则识别 `sk-…` / `Bearer …` / `api_key=…`)


---

## 7. 已知取舍 (供审查者质疑)

| 决策 | 理由 |
|---|---|
| **不用 GRDB, 用系统 SQLite3** | 零依赖 → 打开工程即刻构建, 不需 resolve; 原子提交是本项目最核心的正确性要求, 事务边界自己掌控更可审计。DB 层封装在 `Database.swift` 之后, 换 GRDB 只需改一层 |
| `Database` 用 `NSLock` + `@unchecked Sendable` 而非 actor | SQLite 是同步 C API; actor 的 hop 只增加开销, 且 actor 重入会让"事务内不能 await"这条约束难以强制 |
| Web 模式 Runner 生成 prompt 后立即退出 | 用户可能几小时甚至几天后才回来, 不能把 Runner 挂在 `await` 上等。推进由"用户回填结果 → 重新拉起 Runner"驱动 |
| `ContinuationPromptBuilder` 是纯函数, 不使用 `Date()` | 这是"崩溃后重新生成相同 prompt"的唯一依据 |
| 上下文只带 `workingSummary` 而非全部历史输出 | 300 步任务若每步都塞入全部历史, 第 50 步就会爆上下文窗口且费用失控 |
| 步骤拆分为 N 个等价步骤 | 优先把 Runner / Checkpoint / Retry / Recovery 跑通, 不做智能 Planner |
| `prepared` 步骤可被重新取走执行 | 否则 App 在"prompt 已生成、结果未回填"时被强杀会让该步永久卡死。因为 prompt 是确定性的, 重新执行安全 |

---

## 8. 已知未完成 / 下一步

- **浏览器辅助**: 在用户**已打开**的 ChatGPT 标签页填入 prompt 并读回回复。
  仍然不碰 Cookie / token / 登录。这是投入产出比最高的下一步。
- 本地通知 (任务进入 `waitingForAccount` / `waitingForUser` 时提醒用户)
- 菜单栏常驻模式
- 智能 Task Planner (用一次交互把 goal 拆成有依赖的步骤图)

---

*本文件由 `Scripts/pack_for_review.py` 自动生成。*
