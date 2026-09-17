# AIRunner — 代码审查包

> 生成时间: 2026-09-11 17:56 UTC
> 打包模式: **CORE**
> 项目: macOS 原生 App (Swift 6 / SwiftUI / SQLite), 零第三方依赖
> 规模: 62 个 Swift 文件, 13358 行

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
    Sources/AIRunnerCore/Models/AITask.swift                        244 行
    Sources/AIRunnerCore/Models/AppEvent.swift                      147 行
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
    Sources/AIRunnerCore/Core/JobRunner.swift                       767 行
    Sources/AIRunnerCore/Core/ModelRouter.swift                     307 行
    Sources/AIRunnerCore/Core/RecoveryManager.swift                 197 行
    Sources/AIRunnerCore/Core/ResponseValidator.swift               132 行
    Sources/AIRunnerCore/Core/RetryManager.swift                    189 行
    Sources/AIRunnerCore/Core/TaskExecutionRegistry.swift            42 行
    Sources/AIRunnerCore/Core/TaskManager.swift                     449 行
    Sources/AIRunnerCore/Core/TaskPlanner.swift                     122 行
    Sources/AIRunnerCore/Core/WebExecutionCoordinator.swift         594 行

Provider 抽象 (通用协议)/
    Sources/AIRunnerCore/Providers/AIProvider.swift                  38 行
    Sources/AIRunnerCore/Providers/MockAIProvider.swift             170 行

可选 API 后端 Legacy/API/
    Sources/AIRunnerCore/Legacy/API/OpenAICompatibleProvider.swift  375 行
    Sources/AIRunnerCore/Legacy/API/ProviderFactory.swift           184 行

持久化 Persistence/
    Sources/AIRunnerCore/Persistence/Database.swift                 441 行
    Sources/AIRunnerCore/Persistence/DatabaseMigrator.swift         331 行
    Sources/AIRunnerCore/Persistence/Repositories/CheckpointRepository.swift   79 行
    Sources/AIRunnerCore/Persistence/Repositories/EventRepository.swift  108 行
    Sources/AIRunnerCore/Persistence/Repositories/ProviderHealthRepository.swift   89 行
    Sources/AIRunnerCore/Persistence/Repositories/StepRepository.swift  639 行
    Sources/AIRunnerCore/Persistence/Repositories/TaskRepository.swift  242 行

安全 Security/
    Sources/AIRunnerCore/Security/KeychainManager.swift             166 行

服务 Services/
    Sources/AIRunnerCore/Services/AppSettings.swift                 153 行
    Sources/AIRunnerCore/Services/ClipboardService.swift            117 行
    Sources/AIRunnerCore/Services/LoggerService.swift               187 行

工具 Utilities/
    Sources/AIRunnerCore/Utilities/AppError.swift                   192 行
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
    Tests/AIRunnerCoreTests/JobRunnerTests.swift                    394 行
    Tests/AIRunnerCoreTests/ModelRouterTests.swift                  254 行
    Tests/AIRunnerCoreTests/PersistenceSmokeTests.swift             217 行
    Tests/AIRunnerCoreTests/RetryManagerTests.swift                 215 行
    Tests/AIRunnerCoreTests/SmokeTests.swift                          9 行
    Tests/AIRunnerCoreTests/TestSupport.swift                       154 行
    Tests/AIRunnerCoreTests/WebExecutionRegressionTests.swift       475 行
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

# 跑测试
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

Tests/AIRunnerCoreTests/       # 115 个测试
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

**115 个测试，全部通过。**（数字以 `swift test` 的实际输出为准）

| 测试文件 | 覆盖 |
|---|---|
| `RetryManagerTests` (13) | 退避序列精确值、jitter 上界、`Retry-After` 优先、独立预算、熔断触发判定 |
| `ModelRouterTests` (16) | 优先级、禁用路由、**防 A/B 循环**、认证/余额立即熔断、网络抖动不熔断、恢复清冷却 |
| `CheckpointTests` (10) | 检查点推进、摘要累积与截断、**事务原子性（含失败回滚）** |
| `CrashRecoveryTests` (12) | running→interrupted、任务保持 running、**completed 永不可执行**、卡死修正、恢复幂等 |
| `JobRunnerTests` (12) | API 通道的 5 个场景 + 重复启动 + 暂停恢复 + 取消保留历史 + 完整生命周期 |
| **`WebExecutionTests` (29)** | **Web 通道的全部行为** —— 见下表 |
| **`WebExecutionRegressionTests` (17)** | **正确性回归** —— 重复粘贴、步骤状态校验、CAS 提交、迁移版本推进、failed/cancelled 恢复语义 |
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


> **CORE 模式**：只展开了与「正确性 / 崩溃恢复 / 安全边界」直接相关的代码，
> 其余文件在各节末尾以清单形式列出。UI 层、测试源码、可选 API 后端均未展开。
> 需要全部源码请用 `--mode full`。



### 数据模型 Models


#### `Sources/AIRunnerCore/Models/AITask.swift` (244 行)

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
            // 允许 → running, 但**必须**经由 `TaskManager.retryFailedTask`:
            // 那条路径会先把失败步骤重置为 pending, 再启动 Runner。
            // 直接 start 会让失败的步骤被静默跳过 (见 JobRunner.start 的守卫)。
            let base: Set<TaskStatus> = [.running]
            return base

        case .cancelled:
            // ★ 终态, 不可恢复 ★
            //
            // 取消是用户的明确决定, 不该被一个「继续」按钮直接复活。
            // 若将来确实需要重做, 应当从检查点 Clone 出一个**新任务**,
            // 而不是把原任务拉起来 —— 那样才能保持"取消就是取消"的语义清晰。
            //
            // 之前这里声明了 `.running`, 但 TaskManager.resume 又拒绝 cancelled,
            // 造成"状态表说可以、实际操作被拒"的矛盾。现在两边一致了。
            return []
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


*以下文件在 CORE 模式下未展开源码 (仅清单):*

- `Sources/AIRunnerCore/Models/AIRequest.swift` — 57 行
- `Sources/AIRunnerCore/Models/AIResponse.swift` — 43 行
- `Sources/AIRunnerCore/Models/AppEvent.swift` — 147 行
- `Sources/AIRunnerCore/Models/JSONValue.swift` — 189 行
- `Sources/AIRunnerCore/Models/ProviderConfig.swift` — 170 行
- `Sources/AIRunnerCore/Models/ProviderHealth.swift` — 95 行


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


#### `Sources/AIRunnerCore/Core/JobRunner.swift` (767 行)

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

        // ★ A7: failed 任务不能直接 start ★
        //
        // 直接 start 会把状态改成 running, 随后 nextExecutableStep 会返回下一个
        // pending 步骤 —— **失败的那一步被静默跳过**, 后续结果全部建立在缺失的
        // 前置输入上, 而且不报任何错。
        //
        // 唯一合法路径是 `TaskManager.retryFailedTask`: 先重置失败步骤, 再启动。
        guard task.status != .failed else {
            deps.logger.warning(
                .runnerRejectedDuplicate,
                "任务处于失败状态。请使用「重试失败步骤」—— 直接继续会跳过失败的那一步。",
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
                    // 走 API 专用入口 —— 强制前置状态必须是 running。
                    do {
                        try deps.steps.commitRunningAPIStep(
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


#### `Sources/AIRunnerCore/Core/RecoveryManager.swift` (197 行)

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
    /// 恢复时被判定为"存在失败步骤"并置为 failed 的任务数。
    public var reconciledFailedTasks: Int = 0
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
        var reconciledFailed = 0

        for task in unfinished {
            switch task.status {

            case .running, .queued:
                // ★ A6: 先看有没有失败步骤 ★
                //
                // 存在这样一个崩溃窗口: `markFailed(step)` → App 被 kill → task 仍是 running。
                // 如果只看 executableCount, 会得出"后面还有 pending 步骤, 继续跑"的结论,
                // 于是**跳过失败的那一步**接着往后执行 —— 后续结果全部建立在
                // 缺失的前置输入上, 而且不会报任何错。
                //
                // 正确做法: 停下来, 把任务如实标为 failed, 让用户决定是否重试。
                if let failedStep = try steps.firstFailedStep(taskID: task.id) {
                    let remainingAfterFailure =
                        (try? steps.executableCount(taskID: task.id)) ?? 0
                    do {
                        _ = try tasks.updateStatus(
                            id: task.id, to: .failed,
                            errorMessage: "步骤 \(failedStep.index + 1) 失败: "
                                + (failedStep.lastError ?? "未知原因"),
                            errorClass: failedStep.errorClass ?? "STEP_FAILED"
                        )
                        reconciledFailed += 1
                        logger.error(
                            .recoveryReconciledFailedTask,
                            "任务「\(task.name)」卡在失败步骤 (第 \(failedStep.index + 1) 步)。"
                            + "已把任务置为 failed 并停止自动推进 —— 后续 \(remainingAfterFailure) "
                            + "个步骤不会被跳过执行。如需继续请使用「重试失败步骤」。",
                            taskID: task.id, stepIndex: failedStep.index
                        )
                    } catch {
                        logger.record(error, eventType: .taskFailed, taskID: task.id)
                    }
                    continue
                }

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
        if interrupted == 0 && recoverable.isEmpty
            && stuckCompleted == 0 && reconciledFailed == 0 {
            summary = awaitingUser.isEmpty
                ? "无需恢复: 没有检测到中断的任务或步骤"
                : "无中断任务; 另有 \(awaitingUser.count) 个任务正在等待你手动操作"
        } else {
            var parts: [String] = []
            if interrupted > 0 { parts.append("\(interrupted) 个中断步骤待重跑") }
            if !recoverable.isEmpty { parts.append("\(recoverable.count) 个任务待继续") }
            if stuckCompleted > 0 { parts.append("\(stuckCompleted) 个任务状态已修正为完成") }
            if reconciledFailed > 0 {
                parts.append("\(reconciledFailed) 个任务因存在失败步骤已停止推进")
            }
            if !awaitingUser.isEmpty { parts.append("\(awaitingUser.count) 个任务等待你手动操作") }
            summary = parts.joined(separator: ", ")
        }

        return RecoveryReport(
            interruptedSteps: interrupted,
            recoverableTaskIDs: recoverable.map(\.id),
            recoverableTaskNames: recoverable.map(\.name),
            completedButStuckTasks: stuckCompleted,
            reconciledFailedTasks: reconciledFailed,
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


#### `Sources/AIRunnerCore/Core/TaskManager.swift` (449 行)

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
        switch task.status {
        case .failed:
            // failed 必须走专门入口: 先重置失败步骤, 否则它们会被跳过。
            retryFailedTask(task)

        case .completed:
            lastErrorMessage = "任务已完成, 无需恢复"

        case .cancelled:
            lastErrorMessage = "任务已取消, 无法恢复。如需重做请新建任务 (历史结果仍在数据库里)。"

        default:
            Task { [weak self] in
                guard let self else { return }
                await self.services.runner.start(taskID: task.id)
                self.refresh()
            }
        }
    }

    /// 「重试失败步骤」
    ///
    /// failed 任务**唯一**合法的恢复路径:
    /// 1. 把失败步骤重置为 `pending`
    /// 2. 清掉任务的错误标记
    /// 3. 转 `running` 并交回 Runner
    ///
    /// 之所以不能直接 `task.status = running`: 那样 Runner 会从下一个 pending 步骤
    /// 继续, 失败的那一步被跳过 —— 后续结果会建立在缺失的输入上。
    public func retryFailedTask(_ task: AITask) {
        Task { [weak self] in
            guard let self else { return }
            do {
                let reset = try self.services.steps.resetFailedSteps(taskID: task.id)
                guard reset > 0 else {
                    throw AppError.invalidRequest("该任务没有处于失败状态的步骤, 无需重试")
                }

                _ = try self.services.tasks.updateStatus(
                    id: task.id, to: .running, errorMessage: nil, errorClass: nil
                )

                self.services.logger.info(
                    .taskResumed,
                    "已重置 \(reset) 个失败步骤, 任务重新执行",
                    taskID: task.id
                )
                self.lastErrorMessage = nil
                self.lastInfoMessage = "已重置 \(reset) 个失败步骤, 正在重新执行…"

                await self.services.runner.start(taskID: task.id)
                self.refresh()
            } catch {
                self.setError(error)
            }
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


#### `Sources/AIRunnerCore/Core/WebExecutionCoordinator.swift` (594 行)

````swift
import Foundation

// MARK: - 错误

/// Web 执行通道的错误。
public enum WebExecutionError: Error, Sendable {
    case taskNotFound(String)
    case stepNotFound(String)
    case stepNotInExpectedState(stepIndex: Int, actual: StepStatus)
    case noExecutableStep(taskName: String)
    /// ★ 没有处于 `prepared` 的步骤时, 结果导入必须被拒绝。
    ///
    /// 存在的意义: 阻止"用户重复点击 Paste Result"把上一轮的结果
    /// 错误地提交到下一条 pending 步骤上 —— 那会污染该步骤之后的所有输出。
    case noStepAwaitingResult(taskID: String)
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
        case .noStepAwaitingResult:
            return "当前没有等待回填结果的步骤。请先点「复制续跑 Prompt」生成下一步, 再粘贴结果。"
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

        // ★ A2: 只允许 prepared → completed ★
        //
        // pending / interrupted / completed / failed 一律拒绝。
        // 否则"重复提交同一份结果"会覆盖已有输出并凭空多出一条检查点。
        guard step.status == .prepared else {
            logger.warning(
                .resultImportRejected,
                "步骤 \(step.index + 1) 当前状态为「\(step.status.displayName)」, 拒绝导入结果 "
                + "(只有「已就绪」的步骤才允许提交)",
                taskID: taskID, stepIndex: step.index
            )
            throw WebExecutionError.stepNotInExpectedState(
                stepIndex: step.index, actual: step.status
            )
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

        // ★ A3: 走 Web 专用入口 —— 强制前置状态必须是 prepared ★
        try steps.commitPreparedWebStep(
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

        // ★ A1: 只允许回填"明确处于 prepared"的那一步 ★
        //
        // 这里**绝不能** fallback 到 nextExecutableStep。
        // 否则用户重复点击「粘贴结果」时, 上一轮的剪贴板内容会被当作下一条 pending
        // 步骤的结果提交 —— 之后所有步骤都建立在错误输入上。
        guard let step = try steps.awaitingResultStep(taskID: taskID) else {
            throw WebExecutionError.noStepAwaitingResult(taskID: taskID)
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


*以下文件在 CORE 模式下未展开源码 (仅清单):*

- `Sources/AIRunnerCore/Core/ModelRouter.swift` — 307 行
- `Sources/AIRunnerCore/Core/RetryManager.swift` — 189 行
- `Sources/AIRunnerCore/Core/TaskPlanner.swift` — 122 行


### Provider 抽象 (通用协议)


*以下文件在 CORE 模式下未展开源码 (仅清单):*

- `Sources/AIRunnerCore/Providers/AIProvider.swift` — 38 行
- `Sources/AIRunnerCore/Providers/MockAIProvider.swift` — 170 行


### 可选 API 后端 Legacy/API


*以下文件在 CORE 模式下未展开源码 (仅清单):*

- `Sources/AIRunnerCore/Legacy/API/OpenAICompatibleProvider.swift` — 375 行
- `Sources/AIRunnerCore/Legacy/API/ProviderFactory.swift` — 184 行


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


#### `Sources/AIRunnerCore/Persistence/DatabaseMigrator.swift` (331 行)

````swift
import Foundation

/// 数据库迁移。
///
/// 用 `PRAGMA user_version` 做版本追踪。每次迁移在**单个事务**内完成:
/// 要么整版建好, 要么完全不改 —— 避免"建了一半"的半损坏 schema。
public enum DatabaseMigrator {

    /// 当前 schema 版本。
    ///
    /// ★ 每个 migration 只允许把自己推进到**自己的**版本号 ★
    /// 详见 `migrateToV1` 的注释。
    public static let currentVersion = 3

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

        if existing < 3 {
            try migrateToV3(db)
        }
    }

    // MARK: - V1

    private static func migrateToV1(_ db: Database) throws {
        try db.transaction {
            for statement in v1Statements {
                try db.execute(statement)
            }
            // ★ 只推进到 1 —— 不是 currentVersion ★
            //
            // 若这里写 currentVersion, V1 跑完版本号就等于最新版了; 之后 V2/V3 万一失败,
            // 下次启动会因为"已是最新版本"而跳过它们, 留下 schema 残缺但版本号很新的库。
            try db.execute("PRAGMA user_version = 1;")
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
            // ★ 只推进到 2 ★
            try db.execute("PRAGMA user_version = 2;")
        }
    }

    // MARK: - V3: Codex Existing Thread 绑定

    /// 引入 Codex 长任务绑定表与跨进程 Resume 租约表。
    ///
    /// 同样是**非破坏性**迁移 —— 只新建表, 不触碰任何既有表。
    ///
    /// 这里**不存**任何认证信息: 没有 email / password / cookie / session token /
    /// authentication storage。存的全部是"如何在自己的 UI 里重新找到那个线程"
    /// 的可重建定位信息。
    private static func migrateToV3(_ db: Database) throws {
        try db.transaction {
            for statement in v3Statements {
                try db.execute(statement)
            }
            try db.execute("PRAGMA user_version = 3;")
        }
    }

    private static let v3Statements: [String] = [
        """
        CREATE TABLE IF NOT EXISTS codex_task_bindings (
            id                            TEXT PRIMARY KEY NOT NULL,
            task_id                       TEXT,

            display_title                 TEXT NOT NULL,
            project_name                  TEXT,
            repository_path               TEXT,
            worktree_path                 TEXT,

            application_bundle_identifier TEXT NOT NULL,
            application_name              TEXT,
            window_title_hint             TEXT,

            fingerprint_json              TEXT NOT NULL,
            resume_message                TEXT NOT NULL DEFAULT '继续',

            last_verified_at              TEXT,
            last_resume_sent_at           TEXT,

            created_at                    TEXT NOT NULL,
            updated_at                    TEXT NOT NULL,

            FOREIGN KEY(task_id) REFERENCES tasks(id) ON DELETE SET NULL
        );
        """,

        """
        CREATE INDEX IF NOT EXISTS idx_codex_bindings_task
            ON codex_task_bindings(task_id);
        """,

        // 跨进程 Resume 租约。
        //
        // 不能只用 actor 内存状态防重复 —— 用户可能同时开着两个 AIRunner 实例,
        // 或者上次发送途中 App 异常退出。binding_id 作为主键天然保证"一个 binding 一行",
        // claim 在 SQLite 事务里完成, 因此两个进程只会有一个成功。
        """
        CREATE TABLE IF NOT EXISTS codex_resume_leases (
            binding_id  TEXT PRIMARY KEY NOT NULL,
            owner_id    TEXT NOT NULL,
            acquired_at TEXT NOT NULL,
            expires_at  TEXT NOT NULL
        );
        """,

        """
        CREATE INDEX IF NOT EXISTS idx_codex_leases_expiry
            ON codex_resume_leases(expires_at);
        """,
    ]

    /// 判断某列是否已存在 (用于让 ADD COLUMN 可重入)。
    static func columnExists(_ db: Database, table: String, column: String) throws -> Bool {
        let rows = try db.query("PRAGMA table_info(\(table));")
        return rows.contains { $0.string("name") == column }
    }

    /// 判断某表是否已存在。
    static func tableExists(_ db: Database, table: String) throws -> Bool {
        let rows = try db.query(
            "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            [.text(table)]
        )
        return !rows.isEmpty
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


#### `Sources/AIRunnerCore/Persistence/Repositories/StepRepository.swift` (639 行)

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

    /// 允许被提交的**前置状态** —— 即 CAS (Compare-And-Swap) 的期望值。
    ///
    /// * Web 通道只应是 `[.prepared]`
    /// * API 通道只应是 `[.running]`
    ///
    /// 默认值是两者的并集, 仅为让既有的底层调用点保持兼容;
    /// 两条通道的正式入口是 `commitPreparedWebStep` / `commitRunningAPIStep`,
    /// 它们会强制传入各自唯一合法的前置状态。
    public var expectedStatuses: Set<StepStatus>

    public init(
        stepID: String,
        taskID: String,
        output: JSONValue,
        provider: String,
        model: String,
        durationMs: Int,
        checkpoint: Checkpoint,
        newCurrentStep: Int,
        expectedStatuses: Set<StepStatus> = [.running, .prepared]
    ) {
        self.stepID = stepID
        self.taskID = taskID
        self.output = output
        self.provider = provider
        self.model = model
        self.durationMs = durationMs
        self.checkpoint = checkpoint
        self.newCurrentStep = newCurrentStep
        self.expectedStatuses = expectedStatuses
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

    /// 统计失败步骤数。
    public func failedCount(taskID: String) throws -> Int {
        try db.scalarInt(
            "SELECT COUNT(*) FROM task_steps WHERE task_id = ? AND status = 'failed'",
            [.text(taskID)]
        ) ?? 0
    }

    /// 第一个失败的步骤 (按 index 升序)。
    ///
    /// 崩溃恢复时用它判断"任务里是否卡着一个失败步骤" —— 存在的话**不能**继续
    /// 往后跑 pending 步骤, 否则结果会建立在缺失的前置输入上。
    public func firstFailedStep(taskID: String) throws -> TaskStep? {
        let rows = try db.query(
            """
            SELECT * FROM task_steps
             WHERE task_id = ? AND status = 'failed'
             ORDER BY step_index ASC
             LIMIT 1
            """,
            [.text(taskID)]
        )
        guard let row = rows.first else { return nil }
        return try Self.decode(row)
    }

    /// 把所有 `failed` 步骤重置为 `pending` —— 「重试失败步骤」的实现。
    ///
    /// - Returns: 被重置的步骤数量。
    @discardableResult
    public func resetFailedSteps(taskID: String) throws -> Int {
        try db.transaction {
            try db.execute(
                """
                UPDATE task_steps SET
                    status = 'pending',
                    last_error = NULL,
                    error_class = NULL,
                    started_at = NULL,
                    finished_at = NULL
                WHERE task_id = ? AND status = 'failed'
                """,
                [.text(taskID)]
            )
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

        guard !commit.expectedStatuses.isEmpty else {
            throw AppError.invalidRequest("expectedStatuses 不能为空 —— 否则 CAS 形同虚设")
        }

        try db.transaction {

            // ---- 0) 顺序不变量校验 ----
            //
            // 只允许"提交任务当前的下一步"。这同时挡住了两类错误:
            //   * 过期 / 重复的提交把进度推回去 (currentStep > stepIndex)
            //   * 跳步提交 (currentStep < stepIndex)
            //
            // 这里刻意**不用** MAX() 静默掩盖 —— 一旦不一致就整体回滚并明确报错,
            // 因为不一致本身说明上层逻辑已经出问题了, 掩盖只会让问题后移。
            guard let taskRow = try db.queryOne(
                "SELECT current_step FROM tasks WHERE id = ?",
                [.text(commit.taskID)]
            ), let currentStep = taskRow.int("current_step") else {
                throw AppError.database("任务不存在: \(commit.taskID)")
            }

            guard let stepRow = try db.queryOne(
                "SELECT step_index, status FROM task_steps WHERE id = ? AND task_id = ?",
                [.text(commit.stepID), .text(commit.taskID)]
            ), let stepIndex = stepRow.int("step_index") else {
                throw AppError.database("步骤不存在或不属于该任务: \(commit.stepID)")
            }

            let actualStatus = stepRow.string("status") ?? "?"

            guard commit.newCurrentStep == stepIndex + 1 else {
                throw AppError.database(
                    "提交不自洽: newCurrentStep=\(commit.newCurrentStep), 但该步骤 index=\(stepIndex)。"
                    + "拒绝写入以避免进度错乱。"
                )
            }

            guard currentStep == stepIndex else {
                throw AppError.concurrentModification(
                    "任务进度为 \(currentStep), 但本次要提交的是第 \(stepIndex + 1) 步。"
                    + "这可能是一次重复或过期的提交。"
                )
            }

            // ---- 1) CAS: 只有处于期望状态的步骤才能被标记完成 ----
            let allowed = commit.expectedStatuses.map(\.rawValue).sorted()
            let placeholders = Array(repeating: "?", count: allowed.count).joined(separator: ",")

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
                WHERE id = ? AND task_id = ? AND status IN (\(placeholders))
                """,
                [
                    .text((try? JSONCoding.encodeToString(commit.output)) ?? "null"),
                    .text(commit.provider),
                    .text(commit.model),
                    .text(now),
                    .int(commit.durationMs),
                    .text(commit.stepID),
                    .text(commit.taskID),
                ] + allowed.map { SQLValue.text($0) }
            )

            // changed 必须恰好为 1。0 表示状态不匹配 (stale / duplicate 提交)。
            let changed = try db.scalarInt("SELECT changes()") ?? 0
            guard changed == 1 else {
                throw AppError.concurrentModification(
                    "步骤 \(stepIndex + 1) 不处于可提交状态 "
                    + "(期望 \(allowed.joined(separator: "/")), 实际 \(actualStatus))。"
                    + "本次提交已回滚, 不会生成新检查点。"
                )
            }

            // ---- 2) 写入检查点 ----
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

            // ---- 3) 推进任务进度, 并清掉上一次的错误标记 ----
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

    // MARK: - 两条通道的正式提交入口

    /// Web 通道专用: 前置状态**必须**是 `prepared`。
    ///
    /// 让调用方无法"忘记"校验 —— 状态约束被固化在入口里。
    public func commitPreparedWebStep(_ commit: SuccessfulStepCommit) throws {
        var strict = commit
        strict.expectedStatuses = [.prepared]
        try commitSuccessfulStep(strict)
    }

    /// API 通道专用: 前置状态**必须**是 `running`。
    public func commitRunningAPIStep(_ commit: SuccessfulStepCommit) throws {
        var strict = commit
        strict.expectedStatuses = [.running]
        try commitSuccessfulStep(strict)
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


*以下文件在 CORE 模式下未展开源码 (仅清单):*

- `Sources/AIRunnerCore/Persistence/Repositories/EventRepository.swift` — 108 行
- `Sources/AIRunnerCore/Persistence/Repositories/ProviderHealthRepository.swift` — 89 行


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


*以下文件在 CORE 模式下未展开源码 (仅清单):*

- `Sources/AIRunnerCore/Services/AppSettings.swift` — 153 行


### 工具 Utilities


#### `Sources/AIRunnerCore/Utilities/AppError.swift` (192 行)

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
    /// 乐观并发冲突: 目标行的状态在本次操作期间被改动了 (CAS 失败)。
    ///
    /// 典型场景是"同一份结果被提交两次"。绝不能重试 —— 必须让调用方重新读取状态。
    case concurrentModification(String)
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
        case .invalidRequest, .concurrentModification:
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
             .concurrentModification,
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
             .concurrentModification,
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
        case .concurrentModification(let m): return "并发冲突 (状态已被改动): \(m)"
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
        case .concurrentModification: return "CONCURRENT_MODIFICATION"
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


*以下文件在 CORE 模式下未展开源码 (仅清单):*

- `Sources/AIRunnerCore/Utilities/AsyncSemaphore.swift` — 54 行
- `Sources/AIRunnerCore/Utilities/JSONCoding.swift` — 107 行


### UI 层 (SwiftUI, AppKit 桥接)


*以下文件在 CORE 模式下未展开源码 (仅清单):*

- `Sources/AIRunner/AIRunnerApp.swift` — 45 行
- `Sources/AIRunner/App/AppState.swift` — 55 行
- `Sources/AIRunner/Platform/PasteboardClipboard.swift` — 23 行
- `Sources/AIRunner/Platform/WorkspaceBrowserLauncher.swift` — 20 行
- `Sources/AIRunner/UI/ContentView.swift` — 57 行
- `Sources/AIRunner/UI/Logs/LogView.swift` — 167 行
- `Sources/AIRunner/UI/Settings/ProviderSettingsView.swift` — 250 行
- `Sources/AIRunner/UI/Settings/SettingsView.swift` — 449 行
- `Sources/AIRunner/UI/Tasks/CreateTaskView.swift` — 160 行
- `Sources/AIRunner/UI/Tasks/TaskDetailView.swift` — 556 行
- `Sources/AIRunner/UI/Tasks/TaskListView.swift` — 209 行
- `Sources/AIRunner/UI/Tasks/TaskRowView.swift` — 151 行


### 测试


*以下文件在 CORE 模式下未展开源码 (仅清单):*

- `Tests/AIRunnerCoreTests/CheckpointTests.swift` — 217 行
- `Tests/AIRunnerCoreTests/CrashRecoveryTests.swift` — 236 行
- `Tests/AIRunnerCoreTests/JobRunnerTests.swift` — 394 行
- `Tests/AIRunnerCoreTests/ModelRouterTests.swift` — 254 行
- `Tests/AIRunnerCoreTests/PersistenceSmokeTests.swift` — 217 行
- `Tests/AIRunnerCoreTests/RetryManagerTests.swift` — 215 行
- `Tests/AIRunnerCoreTests/SmokeTests.swift` — 9 行
- `Tests/AIRunnerCoreTests/TestSupport.swift` — 154 行
- `Tests/AIRunnerCoreTests/WebExecutionRegressionTests.swift` — 475 行
- `Tests/AIRunnerCoreTests/WebExecutionTests.swift` — 669 行


---

## 5. 测试


共 115 个测试方法, 98 个测试用例 (部分方法含多个断言分组)。


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


### 全部测试方法清单

```text
testAcceptResultCommitsAndAdvancesCheckpoint                testAcceptResultRejectsCompletedStep                        testAcceptResultRejectsInterruptedStep
testAcceptResultRejectsPendingStep                          testAlreadyAttemptedBackendsAreSkipped                      testAuthenticationTripsCircuitBreakerImmediately
testBackoffSequenceMatchesSpecification                     testBillingRequiredPausesInsteadOfRetrying                  testBillingRequiredTripsProviderLevelCircuit
testBrowserOpensConfiguredURL                               testCancelPreservesHistoryAndCheckpoints                    testCancelledIsATrueTerminalState
testCascadeDeleteRemovesStepsAndCheckpoints                 testCheckpointNextStepIsCompletedPlusOne                    testCommitFailureLeavesNoPartialState
testCommitRejectsCurrentStepMismatch                        testCommitSuccessfulStepWritesStepCheckpointAndProgressTogether  testCompletedStepsAreNeverReturnedAsExecutable
testCompletedStepsAreNotRedoneAfterAccountSwitch            testCompletedTaskSurvivesDatabaseReopen                     testContinuationPromptIsSelfContained
testDefaultExecutionModeIsChatGPTWeb                        testDeliverPromptCopiesToClipboardAndOpensBrowser           testDisabledRouteIsNeverSelected
testDuplicateCommitDoesNotCreateSecondCheckpoint            testEmptyResultIsRejectedAndCheckpointUnchanged             testEndToEndWebTaskCompletesWithoutRedoingWork
testEndToEndWithMidTaskAccountHandoff                       testErrorStrategyRouting                                    testExecutableQueryNeverYieldsCompletedOrFailedSteps
testExhaustedCheckAgreesWithSelect                          testExplainNoBackendListsReasons                            testFailedOnlyTransitionsToRunning
testFallbackDoesNotOscillateBetweenBackends                 testFinalStepInstructionDiffersFromMiddleSteps              testFirstStepPromptSaysNoProgressYet
testForbiddenPathsHaveNoBackoff                             testFullLifecycleWithInterruptionAndRecovery                testImportClipboardResult
testImportFailsOnEmptyClipboard                             testImportWithoutAnyPreparedStepIsRejected                  testInitialCheckpointDoesNotShadowRealProgress
testInitialCheckpointStartsBeforeFirstStep                  testInterruptedRunResumesAfterReopen                        testInterruptedStepIsReturnedByNextExecutableQuery
testInterruptedStepIsStillExecutable                        testJitterIsBoundedAndAdditive                              testLatestCheckpointReturnsHighestCompletedStep
testLatestReturnsNilWhenNeverCheckpointed                   testLegacyRowsDefaultToChatGPTWebMode                       testLocalDatabaseUsesWALAndForeignKeys
testMarkSubmittedRecordsTimestamp                           testMigrationBackfillsMissingV3TablesAfterVersionRollback   testMigrationIsIdempotentAndAddsWebColumns
testMigrationReachesCurrentVersion                          testModelUnavailableOnlyBlocksThatModel                     testModuleLoads
testNetworkFailureDoesNotDegradeProvider                    testNonRetryableErrorsAreNeverRetried                       testOnlyCertainErrorsTripProviderCircuit
testPauseForAccountSwitchIsIdempotent                       testPauseForAccountSwitchPreservesAllProgress               testPausedTaskIsNotAutoRecovered
testPreferredBackendIsAlsoSubjectToAttemptedFilter          testPreferredBackendIsTriedFirst                            testPrepareStepMarksPreparedAndGeneratesPrompt
testPrepareStepWhenAllStepsDoneThrows                       testPreparedStepIsRecoveredWithIdenticalPrompt              testPreparedStepSurvivesDatabaseReopen
testPromptGenerationIsDeterministic                         testRangeCompression                                        testRateLimitBudgetIsSeparateFromRetryBudget
testRateLimitDoesNotDegradeProvider                         testRateLimitUsesItsOwnBackoffLadder                        testRecoveryDoesNotRunLaterStepsPastAFailure
testRecoveryEmitsAppCrashRecoveryEvent                      testRecoveryEmitsCompletionEventWhenTasksRecovered          testRecoveryIsIdempotent
testRecoveryStopsTaskWhenFailedStepExists                   testRecoveryWorksWithNothingToDo                            testRepairBudgetBoundsInvalidOutputRetries
testRepeatedProviderUnavailableEventuallyTripsThreshold     testRepeatedRecoveryOnReopenIsSafe                          testRepeatedStartDoesNotDuplicateExecution
testResetFailedStepsMakesThemRunnableAgain                  testResumeAfterAccountSwitchContinuesFromCheckpoint         testResumeAfterPauseDoesNotRerunCompletedSteps
testResumeIsRejectedWhenTaskIsNotAwaiting                   testRetryBudgetExhaustsAfterMaxRetries                      testRetryManagerComputesDeterministically
testRouterNeverProducesABABCycle                            testRunnerEntersWaitingForUserInsteadOfBlocking             testRunnerRefusesToStartFailedTaskWithoutReset
testRunningStepBecomesInterrupted                           testRunningTaskRemainsRunningAfterRecovery                  testScenarioA_allStepsSucceedAndTaskCompletes
testScenarioB_timeoutIsRetriedThenContinues                 testScenarioC_crashRecoveryResumesFromInterruptedStep       testScenarioD_fallsBackToBackupWhenPrimaryIsUnavailable
testScenarioE_authenticationPausesTaskImmediately           testSecondPasteDoesNotCompleteNextPendingStep               testSelectionOrderFollowsRouteTable
testSelectsLowestPriorityNumberFirst                        testServerRetryAfterOverridesBackoff                        testSleepReturnsEarlyWhenCancelled
testStaleCommitDoesNotAdvanceTaskProgress                   testStateTracksRecentStepsAndCount                          testSuccessClearsCooldown
testTaskWithNoRemainingStepsIsCorrectedToCompleted          testTimeoutBeyondBudgetStillFallsBackToBackup               testV3MigrationPreservesExistingTaskData
testWaitingForAccountTransitionLegality                     testWebChannelNeverCallsAPIProvider                         testWorkingSummaryAccumulatesAcrossSteps
testWorkingSummaryIsTruncatedToBound
```

*测试源码见 FULL 版。*


---

## 6. 验证证据

本次打包**实际执行**了构建与测试, 下面是原始输出。


### 构建（本次实测）

````text
$ swift build --disable-sandbox
# 开始: 2026-09-11 17:56:21 UTC
# 结束: 2026-09-11 17:56:22 UTC
# exit code: 0
[0/1] Planning build
Building for debugging...
[0/3] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.15s)
````

### 测试（本次实测）

````text
$ swift test --disable-sandbox
# 开始: 2026-09-11 17:56:22 UTC
# 结束: 2026-09-11 17:56:24 UTC
# exit code: 0
Test Case '-[AIRunnerCoreTests.WebExecutionTests testPrepareStepWhenAllStepsDoneThrows]' started.
Test Case '-[AIRunnerCoreTests.WebExecutionTests testPrepareStepWhenAllStepsDoneThrows]' passed (0.001 seconds).
Test Case '-[AIRunnerCoreTests.WebExecutionTests testPromptGenerationIsDeterministic]' started.
Test Case '-[AIRunnerCoreTests.WebExecutionTests testPromptGenerationIsDeterministic]' passed (0.000 seconds).
Test Case '-[AIRunnerCoreTests.WebExecutionTests testRangeCompression]' started.
Test Case '-[AIRunnerCoreTests.WebExecutionTests testRangeCompression]' passed (0.000 seconds).
Test Case '-[AIRunnerCoreTests.WebExecutionTests testResumeAfterAccountSwitchContinuesFromCheckpoint]' started.
Test Case '-[AIRunnerCoreTests.WebExecutionTests testResumeAfterAccountSwitchContinuesFromCheckpoint]' passed (0.003 seconds).
Test Case '-[AIRunnerCoreTests.WebExecutionTests testResumeIsRejectedWhenTaskIsNotAwaiting]' started.
Test Case '-[AIRunnerCoreTests.WebExecutionTests testResumeIsRejectedWhenTaskIsNotAwaiting]' passed (0.001 seconds).
Test Case '-[AIRunnerCoreTests.WebExecutionTests testRunnerEntersWaitingForUserInsteadOfBlocking]' started.
Test Case '-[AIRunnerCoreTests.WebExecutionTests testRunnerEntersWaitingForUserInsteadOfBlocking]' passed (0.024 seconds).
Test Case '-[AIRunnerCoreTests.WebExecutionTests testWaitingForAccountTransitionLegality]' started.
Test Case '-[AIRunnerCoreTests.WebExecutionTests testWaitingForAccountTransitionLegality]' passed (0.000 seconds).
Test Case '-[AIRunnerCoreTests.WebExecutionTests testWebChannelNeverCallsAPIProvider]' started.
Test Case '-[AIRunnerCoreTests.WebExecutionTests testWebChannelNeverCallsAPIProvider]' passed (0.024 seconds).
Test Suite 'WebExecutionTests' passed at 2026-09-12 01:56:24.731.
	 Executed 29 tests, with 0 failures (0 unexpected) in 0.104 (0.108) seconds
Test Suite 'AIRunnerPackageTests.xctest' passed at 2026-09-12 01:56:24.731.
	 Executed 115 tests, with 0 failures (0 unexpected) in 1.619 (1.642) seconds
Test Suite 'All tests' passed at 2026-09-12 01:56:24.731.
	 Executed 115 tests, with 0 failures (0 unexpected) in 1.619 (1.643) seconds
◇ Test run started.
↳ Testing Library Version: 1743
↳ Target Platform: arm64e-apple-macos14.0
✔ Test run with 0 tests in 0 suites passed after 0.001 seconds.
[0/1] Planning build
Building for debugging...
[0/4] Write swift-version--58304C5D6DBC2206.txt
Build complete! (0.12s)
````



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
