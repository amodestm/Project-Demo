# 多账号 AI 讨论组（方案 C：Chrome 多 Profile 并行）

> 状态：**首个可运行版本已完成**。P1 数据与持久化、P2 真实 Chrome 会话、
> P3 串行多账号讨论闭环、P4 UI 和 P5 最近运行恢复均已接入；真实 Chrome 页面选择器仍需在登录好的 Profile 上完成一次人工验收。

---

## 1. 目标

基于已有的 8 个 Chrome Profile（账号池），组建一个**可配置的多账号 AI 讨论组**：
多个 ChatGPT 账号各自扮演不同角色，围绕同一议题独立论述 → 交叉质询 → 收敛出决策。

### ★ 前提假设（2026-09-14 用户确认，据此修正全篇）

| 项 | 结论 | 连带影响 |
|---|---|---|
| **载体** | **Chrome 网页版 ChatGPT**（不是 Codex 桌面 App） | 走 `WebExecutionCoordinator` 线；Codex 3073 行 OAuth 驱动**完全不动** |
| **额度** | **无限，不设限** | ❌ 删掉「额度消耗 ×N」风险；❌ 不需要额度轮换/quota monitor；❌ 不需要「同角色备用账号」 |

> 额度无限是**架构级的简化**：原设计里为省钱而存在的轮换、熔断、备用账号全部作废。
> 唯一剩下的瓶颈是**时间**，而时间可以通过窗口常驻 + 调度优化来压，不靠并行硬扛。

### 非目标（明确不做）

- 不做 API 通道的多模型（那是方案 B，未选）
- 不绕过任何验证码 / 人机验证
- 不修改 Codex OAuth 主线（1.5.50）的现有行为

---

## 2. 已查证的硬约束

| # | 约束 | 证据 |
|---|---|---|
| C1 | 驱动层写死**单进程**：`runningApplications.first { bundleIdentifier }` | `Automation/CodexUIAutomationDriver.swift:3069` |
| C2 | 驱动层写死**单窗口**：`windows.first` | 同文件窗口解析处 |
| C3 | 轮换语义是**接力**不是并存：`rotate` / `nextProfile` 循环指针 | `Core/AccountRotationManager.swift:162, 256` |
| C4 | 输入主路径是 `AXUIElementSetAttributeValue`（**不要求窗口前台**） | `:1989`；键盘 CGEvent 是后备 |
| C5 | Chrome 启动用 `open -b ... --profile-directory=X` | `Automation/ChromeProfileScanner.swift:237-250` |
| C6 | `open` 对已运行的 Chrome 会**复用现有实例**，不会开第二个 | macOS `open` 语义 |
| C7 | CGWindowList 读窗口标题需**屏幕录制权限**（AIRunner 无）→ 只能用 AX | 实测：285 条窗口、标题全空 |
| C8 | 账号池现状：8 个 Profile（`Default`, `Profile 2/3/4/5/7/8/10`） | 实测 `~/Library/Application Support/Google/Chrome/` |

**C4 是整个方案唯一的技术支点**：AXValue 直接写入不要求前台，所以「后台窗口并行输入」在理论上有可能。
但它**尚未被验证**——见第 3 节。

---

## 3. Spike：三项必须先验证的风险 ⚠️

> 不通过就不写代码。这三项决定方案 C 是「真并行」还是「伪装成并行的串行」。

### S1（决定性）后台窗口的 AXValue 写入是否真的生效

- 做法：开两个 ChatGPT 窗口（不同 Profile），把 A 置于前台，对**后台的 B** 执行
  `AXUIElementSetAttributeValue(composer, kAXValueAttribute, text)`，再轮询 AX 读回。
- **通过标准**：后台窗口 Composer 回读到完整文本。
- **失败后果**：并行不成立 → 只能前台轮询切换 → 退化为「串行讨论（省掉重新登录）」，
  仍比现状快，但架构要砍掉并行调度器。
- 已知风险：部分 App 在失焦时会丢弃 AX 写入或重置焦点。

### S2 窗口 ↔ 账号身份的映射是否可靠

- 问题：AX **不暴露**窗口属于哪个 Chrome Profile。
- 候选方案：读 ChatGPT 页面内的账号标识（左下角邮箱 / 设置入口文本），建立 `window → email` 映射。
- **通过标准**：N 个窗口各自读出**互不相同且稳定**的账号标识。
- 风险：页面未加载完时读不到；账号标识文案变更。

### S3 多 Profile 窗口能否稳定并存且各自保持登录态

- 做法：依次为 N 个 Profile 开窗并访问 ChatGPT，确认不互相踢下线。
- **通过标准**：N 个窗口同时在线，各自登录态独立。
- 风险：同一 `--user-data-dir` 下 Chrome 是单实例；不同 user-data-dir 会丢失登录态（C8 相关）。

### Spike 的副作用（需用户批准）

- 会**打开新的 Chrome 窗口**并访问 ChatGPT（不关闭用户现有窗口）
- 不退出任何账号、不发送真实提示词（只做 Composer 读写探测）

---

## 3.5 两种调度架构（额度无限后重新评估）

额度无限把「省钱」从目标里移除，于是**并行不再是刚需**。两种架构：

| | **架构 I：串行·多窗口常驻** | **架构 II：严格并行** |
|---|---|---|
| 做法 | N 个窗口常驻（各自已登录），同一时刻只操作一个：`AXRaise` 到前台 → 输入 → 读回 → 切下一个 | N 个窗口同时输入，全部后台 AXValue 写入，并行轮询读回 |
| 依赖 | 无特殊依赖 | **必须 S1 通过** |
| 速度 | 串行，N×M 次顺序执行 | 理论 N 倍 |
| 稳定性 | 高（前台操作，与现有代码路径一致） | 低（后台 AX 写入可能被丢弃/焦点竞争） |
| 改造量 | 小（新增窗口定位 + 身份校验） | 大（全部操作去前台化） |
| 掉登录态风险 | 无（窗口常驻） | 无 |

### 结论：**先做架构 I，把 II 作为可选加速**

理由：
1. 额度无限 → 时间不值钱，没必要为速度承担 S1 的失败风险
2. 架构 I 相对现状已经是巨大提升：现状每换一个账号要**退出 + OAuth 重登**（10–30s + 交互），
   架构 I 只是**切窗口**（<1s，零交互）
3. 架构 I 跑通后，若实测太慢，再单独验证 S1 升级到 II——**两条路不冲突，II 是 I 的增量**

> 因此 Spike 中只有 S1 对架构 I 是非阻塞项：串行时允许前置目标窗口。
> 架构 I 仍依赖 S2（窗口↔账号映射）和 S3（多 Profile 登录态稳定并存）。

---

## 4. 数据模型（可配置讨论组）

```
DiscussionGroup           一次讨论的**配置**（可复用、可持久化）
├─ id, name
├─ topic                  议题 / 决策问题
├─ participants: [Participant]
├─ agenda: [RoundConfig]  轮次序列（顺序可配）
├─ consensus: ConsensusRule
└─ maxRounds: Int

Participant               一个"团队成员"
├─ id, displayName        如「批判者」「乐观派」「成本专家」
├─ rolePrompt             角色设定（制造认知差异的唯一手段）
├─ account: AccountBinding
│   ├─ profileDirectory   "Profile 3"
│   └─ emailHint          用于 S2 校验窗口身份
└─ enabled: Bool

RoundConfig               一轮
├─ index
├─ kind: RoundKind
│   ├─ independentOpinion    独立论述（看不到别人的发言）
│   ├─ crossExamination      交叉质询（能看到指定/全部他人发言）
│   └─ convergence           收敛
├── visibleTo: Visibility    本轮能看到谁的输出（all / others / none）
└── speakerOrder: [ParticipantID]  发言人顺序可配

ConsensusRule             收敛规则（可配，MVP 先实现前两种）
├─ moderatorSummary      主席汇总（指定某 participant 或新建 moderator 角色）
├─ majorityVote          多数投票
├─ unanimous             一致同意（否则再来一轮）
└─ chairmanDecides       主席独裁

DiscussionRun             一次讨论的**运行时**（落盘，可崩溃恢复）
├─ groupID
├─ state: RunState
├─ currentRound: Int
├─ utterances: [Utterance]
└─ finalDecision: String?

Utterance                 一条发言（完整留痕）
├─ runID, roundIndex, participantID
├─ promptSent, responseText
├─ accountEmailUsed       实际用到的账号（审计）
├─ status: pending/sent/received/failed
└─ timestamps

RunState: idle → preparingWindows → roundInProgress → collecting
        → (nextRound) → converging → done / failed
```

### 崩溃恢复

复用现有 `CheckpointManager` + `TaskStep` 的原子提交模式：
每条 utterance 在 `received` 时原子落盘；重开只补未完成的发言，不重复已完成的。

---

## 5. 驱动层改造点（方案 C 的核心工作量）

| 现状 | 需要改成 |
|---|---|
| `runningApplication(bundleIdentifier:)` 取第一个 | 枚举 Chrome 实例，返回全部 |
| `windows.first` | 按 `accountHint` 筛选并锁定目标窗口 |
| 函数签名传 `app: AXUIElement` | 传 `session: ChatSession`（pid + window + accountHint） |
| 每个操作前 `AXRaise` 拉前台 | 并行时**禁止**逐个 raise，改依赖后台 AXValue 写入（依赖 S1） |

新增抽象：

```swift
struct ChatSession: Sendable {
    let pid: pid_t
    let window: AXUIElement
    let accountHint: String      // S2 用于校验"这个窗口确实是这个账号"
    var lastVerified: Date
}
```

**注意**：`CodexUIAutomationDriver.swift` 有 3073 行，且是 Codex **桌面 App** 的驱动。
讨论组走的是 **Chrome 网页 ChatGPT**（`WebExecutionCoordinator` / `ChatGPTAccountSwitcher` 这条线），
因此**不改动 Codex 驱动**，而是在其旁新开 `DiscussionSessionDriver`。
→ 这大幅降低了 C1/C2 的改造风险，也避免污染 OAuth 主线。

---

## 6. 分阶段实施

| 阶段 | 内容 | 前置 | 阻塞? |
|---|---|---|---|
| **P1 骨架** | `DiscussionGroup` / `Participant` / `RoundConfig` 模型 + 持久化（DB v8 迁移） | — | 否 |
| **P2 窗口会话层** | `ChatSession` + 多窗口定位 + **账号身份校验（S2）** | P1 | 否 |
| **P3 串行跑通（架构 I）** | N 窗口常驻，串行轮流发言，跑完一次完整讨论（论述→质询→收敛） | P2 | 否 |
| **P4 UI** | 讨论组配置界面 + 运行界面（发言流、轮次进度、最终决策） | P3 | 否 |
| **P5 恢复** | 崩溃恢复、发言去重、断点续跑 | P3 | 否 |
| **P6 并行加速（架构 II，可选）** | 后台 AX 写入，真并行 | **S1 通过** | 是 |

**Spike 已降级为非阻塞项**：架构 I 不依赖 S1，可直接开工。
S1 只在想升级到架构 II（P6）时才需要验证——而额度无限使得 P6 的收益有限。

顺序上**先把串行完整跑通（P3）再做 UI（P4）**：确保编排逻辑正确后再投入界面工作量。

---

## 7. 风险登记

| 风险 | 等级 | 缓解 |
|---|---|---|
| S2 窗口↔账号映射不稳 | **高** | 开窗时校验 + 每轮发言前复核；失败 fail closed 不发言。**架构 I 同样依赖** |
| 同质模型回声室 | **高** | 角色 prompt 必须强差异化（见下）。**本方案最大隐性风险** |
| AX 脆弱性 ×N | 中 | 复用现有 fail-closed 纪律；每个 session 独立超时 |
| ~~额度消耗 ×N~~ | — | **已消除**：额度无限，不需要轮换 / 熔断 / 备用账号 |
| S1 后台 AX 写入失效 | 低（已降级） | 架构 I 不依赖；仅升级到架构 II 时才需要 |

### 关于「同质模型」

8 个账号都是同一个 ChatGPT，天然同质。讨论质量**完全取决于角色 prompt 的差异化程度**。
最低要求：每个角色必须有**互斥的立场指令**（例如强制一个角色只找漏洞、一个只算成本、
一个只考虑用户体验），否则讨论会退化成互相附和。这是配置 UI 必须引导的。

---

## 8. 验收标准

1. 配置 3 个角色 + 2 轮（独立论述 + 主席收敛），一键运行，产出最终决策
2. 每条发言可追溯：用的哪个账号、发的什么 prompt、回了什么
3. 中途强杀 App，重启后从最后一条完成发言继续，不重复
4. 不出现「用错账号发言」（S2 身份校验拦截）
5. N 个窗口全程保持各自登录态，不互相踢下线
6. ~~任一账号额度耗尽自动换备用账号~~ → **额度无限，本条作废**
