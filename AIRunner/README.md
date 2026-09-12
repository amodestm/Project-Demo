# AIRunner

macOS 上的 **AI 长任务自动执行器**。把一个跑几小时甚至几天的任务拆成有序步骤，逐步调用 AI；
当某账号触发额度 / 限流 / 卡死时，**无需任何人工点击即可自动切换到备用账号**，并在中断、切号、App 被强杀后**自动续跑**——每一步都落盘 + 存检查点，绝不从头重来。

## 当前实现状态（2026-09-12）

当前工作区已经可以构建并组装为可运行的 macOS App：

- Swift 6 核心、SQLite 持久化、检查点、崩溃恢复、重试与路由已完成。
- ChatGPT Web 主流程已完成：生成确定性的续跑 Prompt、通过 macOS 辅助功能(AX) API 自动提交并读回结果、校验后原子推进检查点（也可降级为剪贴板手工模式）。
- Codex Existing Thread 可选通道已完成：基于 macOS Accessibility API 定位和唯一性验证线程，支持 Test Locate、Dry Run、Resume、冷却、跨进程租约，以及认证后的自动恢复监视。
- 新建任务只保存为“排队中”，不会自动执行、登录或打开网页；用户从任务详情点击“开始执行”后才进入执行链。
- Codex 运行中自动交接已接入：只检查当前焦点窗口末尾 16 条有效 AX 文本里的额度耗尽、登录失效和任务停止信号；只有任务已停止生成、页面空闲（或明确显示已停止）并连续确认两次后，才进入账号轮换。轮换完成后旧错误保持锁定，直到它从最新输出消失，避免重复切号。
- Chrome Profile + Codex 官方浏览器 OAuth 账号轮换已完成：AIRunner 从 Codex 原生应用菜单发起“注销”，精确识别并按下“退出登录？”确认框，再在登录界面按下“使用 ChatGPT/GPT 账号登录”；官方授权随后在目标 Chrome Profile 中继续，自动完成账号选择、授权继续和个人工作空间继续，确认登录后重启 Codex、定位原任务并从检查点续跑。不会读取、复制或注入网页 Cookie/session token。
- 设置页提供独立的“一键测试安全退出并登录”：手动点击后先扫描全部 Codex 窗口并验证页面空闲，依次完成原生“注销”、退出确认和登录页验证；只有检测到 Codex 原生登录入口后才打开下一个 Profile，避免失败时留下空白浏览器窗口。该测试不创建或绑定任务，不修改检查点，也不发送“继续”；检测到任一窗口仍在生成或状态无法确认时，会在退出前拒绝。
- 原钥匙串邮箱密码路线完整保留为回退；在设置中关闭 OAuth 开关即可继续使用，也可以直接运行旧版 App。
- 当前自动化测试为 **228 个**；没有失败用例。
- 两个 Release App 并存：旧路线 `dist/AIRunner.app` 保持 **1.3.2 / build 26**；新路线 `dist/AIRunner OAuth.app` 为 **1.5.5 / build 41**，使用独立应用名和 bundle id，不覆盖旧版。

Codex 的真实 UI 操作仍需在用户机器上授予 AIRunner「系统设置 → 隐私与安全性 → 辅助功能」权限后，用实际 Codex 窗口执行 Test Locate / Dry Run 验收。没有权限时程序会停止并报告原因，不会猜测目标或发送消息。

## 主执行通道：ChatGPT Web 自动执行（含自动账号切换）

程序配合 **ChatGPT 网页端**使用，全程由 AIRunner 通过 macOS 辅助功能(AX) API 驱动，**无需人工点击**：

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
| 退出 Codex、在目标 Profile 完成官方授权、重启 Codex | 在设置中勾选至少两个 Profile |
| 生成自包含的续跑 prompt | |
| 通过 AX 自动提交 prompt、自动读回结果 | |
| 检测到额度/登录异常且任务已停止时自动切换账号 | |
| 崩溃恢复 / 不重复已完成的工作 | |

> **为什么走 macOS 辅助功能(AX) 而不是 Selenium/Playwright**：见下方「边界」。
> 先让 checkpoint / 续跑 / 恢复这条链路完全正确，再用原生 AX 把提交、读回、切号全流程自动化。

---

## 一、边界与设计红线

AIRunner 的核心能力就是**自动切换账号（零点击）+ 自动续跑**，但它遵守以下硬性边界：

- ✅ **主动登录与切换账号**：用户点击开始或发生账号交接时，程序选择下一个 Chrome Profile，通过 Codex 原生“注销 → 退出登录确认”完成安全退出，再从“使用 ChatGPT/GPT 账号登录”入口进入官方浏览器授权，确认成功后重启 Codex 并恢复任务。
- ✅ **自动续跑**：中断、切号、App 被强杀后从检查点原地接上，绝不重复已完成步骤。
- ❌ 不读取或导出浏览器 Cookie。
- ✅ 旧版邮箱密码回退仍只把密码写入 macOS 钥匙串；任务、设置 JSON、数据库和日志只保存非敏感记录 ID/备注。
- ❌ 不读取或注入 session token / authentication storage；主路线复用 Profile 中已有的网页登录，并让 Codex 自己管理 OAuth 凭据。
- ❌ 不用 Selenium / Playwright 等网页自动化框架（采用原生 macOS AX API 驱动 UI）。
- ❌ 不伪造或绕过平台安全机制：切换的是使用者自己合法持有的账号，不做 token 注入 / cookie 盗用 / 伪造请求。

账号登录入口是设置页的“Codex 自动恢复”：点击“重新检测”，勾选至少两个已经登录不同 ChatGPT 账号的 Chrome Profile。轮换成功后才更新任务的 Profile 指针；失败不会提前推进检查点。

`CodexLoginAutomator.swift` 与 `CodexAccountVault.swift` 已装配到 `AppServices`。自动登录使用 Chrome 的可访问性树定位官方登录控件，不读取网页 Cookie、Token 或浏览器密码库。检测到验证码、人机验证或 2FA 时会停止并明确提示用户处理，不尝试绕过。

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

# 单独组装 OAuth/Profile 版本（不会覆盖上面的旧版）
bash Scripts/make_oauth_app.sh release
open "dist/AIRunner OAuth.app"
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
2. 在 Chrome 中建立至少两个 Profile，并在每个 Profile 中分别登录一个 ChatGPT 账号
3. 在“Codex 自动恢复”中重新检测并勾选这些 Profile；所有 Codex 任务停止后，可用“一键测试安全退出并登录”单独验收闭环；如需旧路线，可关闭 OAuth 并继续使用钥匙串账号
4. 授予 AIRunner OAuth 辅助功能权限；需要 API 可选通道时再配置 Provider 与 API Key
5. 回主界面 `⌘N` 新建任务；创建后保持“排队中”，在任务详情点击“开始执行”才会登录并执行

### 数据位置

| 内容 | 位置 |
|---|---|
| 任务 / 步骤 / 检查点 / 日志 | `~/Library/Application Support/AIRunner/airunner.sqlite` |
| API Key | macOS Keychain，`service = com.airunner.apikeys` |
| ChatGPT 账号密码 | macOS Keychain，`service = com.airunner.codex-accounts` |
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
│ (钥匙串自动登录/切换账号) │                                    │
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

Tests/AIRunnerCoreTests/       # 228 个测试（含 2 个真实辅助功能树探针）
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

**228 个测试，0 个失败。**（数字以 `swift test` 的实际输出为准）

| 测试文件 | 覆盖 |
|---|---|
| `RetryManagerTests` (13) | 退避序列精确值、jitter 上界、`Retry-After` 优先、独立预算、熔断触发判定 |
| `ModelRouterTests` (16) | 优先级、禁用路由、**防 A/B 循环**、认证/余额立即熔断、网络抖动不熔断、恢复清冷却 |
| `CheckpointTests` (10) | 检查点推进、摘要累积与截断、**事务原子性（含失败回滚）** |
| `CrashRecoveryTests` (12) | running→interrupted、任务保持 running、**completed 永不可执行**、卡死修正、恢复幂等 |
| `JobRunnerTests` (12) | API 通道的 5 个场景 + 重复启动 + 暂停恢复 + 取消保留历史 + 完整生命周期 |
| **`WebExecutionTests` (29)** | **Web 通道的全部行为** —— 见下表 |
| **`WebExecutionRegressionTests` (17)** | **正确性回归** —— 重复粘贴、步骤状态校验、CAS 提交、迁移版本推进、failed/cancelled 恢复语义 |
| `CodexTaskMatcherTests` (15) | Codex 线程匹配、唯一性门槛、弱匹配拒绝与打开后二次验证 |
| `AccountHandoffMonitorTests` (15) | 认证后监视、冷却、防重入、自动恢复与危险错误停止 |
| `ChatGPTAccountSwitchTests` (29) | 网页账号切换、原生 Codex 登录入口识别、创建只排队、显式启动后登录、原生退出先于登录、指针落盘与管理器编排 |
| `CodexQuotaMonitorTests` (11) | 最新输出范围、连续确认、生成中拒绝退出、旧错误锁定和安全轮换门控 |
| `CodexOAuthSafetyTesterTests` (5) | 设置页独立测试、全窗口生成中拒绝、当前窗口忙碌拒绝、状态不明 fail closed、空闲时允许 OAuth 闭环 |
| `CodexNativeLogoutConfirmerTests` (4) | 原生注销菜单、确认框标题和确认按钮的中英文本精确匹配，以及正文误匹配拒绝 |
| `CredentialRotationTests` (9) | 凭据轮换、跨任务全局下一账号、首次登录、OpenAI“登录其他账户”识别、失败时不推进账号指针 |
| `AccountRotationTests` (14) | 历史 Chrome Profile 兼容层的轮换池、持久化指针、窗口前置失败降级，以及无任务记录的一键 OAuth 测试轮换 |
| `CodexResumeLeaseTests` (9) | 跨进程 Resume 租约、过期锁显式恢复与并发互斥 |
| `PersistenceSmokeTests` (5) | **真实文件数据库**：WAL、外键 CASCADE、关闭重开数据仍在、中断后重开继续 |
| `SmokeTests` (1) | 模块加载冒烟检查 |
| `AXTreeProbeTests` (2) | 真实应用 AX 探针；未授予辅助功能权限时按预期跳过 |

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
| `Automation/CodexUIAutomationDriver.swift` | 基于 AX 树的线程定位、Composer 输入、发送与确认观察；无法确认时 fail closed |
| `Automation/CodexResumeController.swift` | Test Locate / Dry Run / Resume 的统一安全门槛、冷却与租约 |
| `Core/AccountHandoffResumeMonitor.swift` | 认证后轮询 Codex 可用性并自动恢复绑定线程 |
| `Core/AccountRotationManager.swift` | 在显式选择的 Chrome Profile 间循环；OAuth 成功后才推进账号指针；旧钥匙串路线继续作为回退 |
| `Automation/CodexBrowserOAuthAuthenticator.swift` | 驱动 Codex 原生注销菜单和退出确认框，从 ChatGPT 登录入口进入目标 Chrome Profile，确认成功后重启 Codex |
| `Automation/CodexLoginAutomator.swift` | 驱动官方登录页的“登录其他账户”、邮箱、下一步、密码与登录流程；验证码/2FA 时停止 |
| `Security/CodexAccountVault.swift` | ChatGPT 账号凭据的 macOS 钥匙串存取，数据库只保存记录 ID |

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

1. **Notification** — 任务进入 `waitingForAccount` / `waitingForUser` / `completed` 时发本地通知。
   长任务最需要的其实是"轮到你操作了"和"跑完了"
2. **菜单栏模式** — 常驻状态栏显示「有几个任务在等我」
3. **开机启动 + launchd** — `NSSupportsAutomaticTermination=false` 已就位，补一个 LaunchAgent plist
4. **导出 Markdown / JSON** — 检查点里已有结构化 `state`
5. **智能 Task Planner** — 用一次 ChatGPT 交互把 goal 拆成有依赖的步骤图
6. **文件输入 / PDF 分析 / Directory Watch** — 让 `map` 步骤真正消费文件
7. **自动压缩 Context** — 按 token 预算而非字符数截断
8. **更多 Provider 原生协议**（Anthropic Messages / Gemini generateContent）

这些是后续增强项；当前登录、任务执行、账号轮换与检查点续跑闭环已经接通。
