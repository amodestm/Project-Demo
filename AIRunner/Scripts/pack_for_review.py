#!/usr/bin/env python3
"""
把 AIRunner 打包成单个 Markdown 文件, 便于上传给 ChatGPT / Claude 做代码审查。

用法:
    python3 Scripts/pack_for_review.py --mode full
    python3 Scripts/pack_for_review.py --mode core
    python3 Scripts/pack_for_review.py --mode full --output review/自定义名.md

两种模式:
    full  — 全部 61 个 Swift 文件 + README。约 14 万 token, 适合长上下文模型,
            或分多次提问。
    core  — 全部设计与正确性相关代码 + 测试清单 + UI 结构摘要。约 5 万 token,
            适合一次喂完走完整审查。
"""

from __future__ import annotations

import argparse
import glob
import re
from datetime import datetime, timezone
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
FENCE = "````"          # 4 个反引号: 防止代码里出现 ``` 时破坏 Markdown

MODULE_GROUPS: list[tuple[str, list[str]]] = [
    ("数据模型 Models",
     ["Sources/AIRunnerCore/Models/*.swift"]),
    ("执行核心 Core",
     ["Sources/AIRunnerCore/Core/*.swift"]),
    ("Provider 抽象 (通用协议)",
     ["Sources/AIRunnerCore/Providers/*.swift"]),
    ("可选 API 后端 Legacy/API",
     ["Sources/AIRunnerCore/Legacy/API/*.swift"]),
    ("持久化 Persistence",
     ["Sources/AIRunnerCore/Persistence/*.swift",
      "Sources/AIRunnerCore/Persistence/Repositories/*.swift"]),
    ("安全 Security",
     ["Sources/AIRunnerCore/Security/*.swift"]),
    ("服务 Services",
     ["Sources/AIRunnerCore/Services/*.swift"]),
    ("工具 Utilities",
     ["Sources/AIRunnerCore/Utilities/*.swift"]),
    ("UI 层 (SwiftUI, AppKit 桥接)",
     ["Sources/AIRunner/AIRunnerApp.swift",
      "Sources/AIRunner/App/*.swift",
      "Sources/AIRunner/Platform/*.swift",
      "Sources/AIRunner/UI/*.swift",
      "Sources/AIRunner/UI/**/*.swift"]),
    ("测试",
     ["Tests/AIRunnerCoreTests/*.swift"]),
]

# CORE 模式: 只展开这些文件的源码 —— 即"正确性 / 崩溃恢复 / 安全边界"三项审查
# 真正需要读的代码。其余文件 (UI / 测试 / 可选 API 后端 / 机械 Repository) 仅列清单。
CORE_WHITELIST: set[str] = {
    # 数据模型
    "Sources/AIRunnerCore/Models/AITask.swift",
    "Sources/AIRunnerCore/Models/TaskStep.swift",
    "Sources/AIRunnerCore/Models/Checkpoint.swift",
    "Sources/AIRunnerCore/Models/ExecutionMode.swift",
    # 持久化 —— 原子提交是本项目最核心的正确性要求
    "Sources/AIRunnerCore/Persistence/Database.swift",
    "Sources/AIRunnerCore/Persistence/DatabaseMigrator.swift",
    "Sources/AIRunnerCore/Persistence/Repositories/StepRepository.swift",
    "Sources/AIRunnerCore/Persistence/Repositories/TaskRepository.swift",
    "Sources/AIRunnerCore/Persistence/Repositories/CheckpointRepository.swift",
    # 执行核心
    "Sources/AIRunnerCore/Core/JobRunner.swift",
    "Sources/AIRunnerCore/Core/WebExecutionCoordinator.swift",
    "Sources/AIRunnerCore/Core/ContinuationPromptBuilder.swift",
    "Sources/AIRunnerCore/Core/RecoveryManager.swift",
    "Sources/AIRunnerCore/Core/CheckpointManager.swift",
    "Sources/AIRunnerCore/Core/TaskExecutionRegistry.swift",
    "Sources/AIRunnerCore/Core/ResponseValidator.swift",
    "Sources/AIRunnerCore/Core/TaskManager.swift",
    "Sources/AIRunnerCore/Core/AppServices.swift",
    # 安全与错误分类
    "Sources/AIRunnerCore/Security/KeychainManager.swift",
    "Sources/AIRunnerCore/Services/LoggerService.swift",
    "Sources/AIRunnerCore/Services/ClipboardService.swift",
    "Sources/AIRunnerCore/Utilities/AppError.swift",
}

REQUIREMENT_MATRIX = """\
| # | 需求约束 (用户明确要求"不要做") | 实现方式 / 代码证据 |
|---|---|---|
| 1 | ChatGPT 登录密码不得进入数据库或设置 | 密码只写入 macOS Keychain；设置仅保存随机账号 ID 和顺序 |
| 2 | 登录失败不得推进账号指针 | `AccountRotationManager` 仅在登录成功后写入下一个账号 ID；任务保持 `waitingForAccount` |
| 3 | 不读取浏览器 Cookie | 无 `WebKit` / `HTTPCookieStorage` / `WKWebsiteDataStore` 引用; 无任何 Cookie 数据库路径 |
| 4 | 不复制 session token | 无 `localStorage` / `sessionStorage` / token 注入代码; 密钥仅存 macOS Keychain |
| 5 | 不用 Selenium / Playwright | 零第三方依赖；登录使用 macOS Accessibility API 与键盘事件 |
| 6 | 不绕过验证码或安全挑战 | 检测到 CAPTCHA、2FA、邮箱验证码或验证提示时立即停止并提示用户 |
| 7 | 只使用用户主动保存的账号或 API 配置 | ChatGPT 凭据由用户在设置页录入；API 通道需用户自配 Key |

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
"""

VERIFICATION_EVIDENCE = """\
### 构建

```
$ swift build
Build complete! (0.16s)          # 0 error, 0 warning
```

### 测试

```
$ swift test
Executed 115 tests, with 0 failures (0 unexpected) in 1.604 (1.627) seconds
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
| `WebExecutionRegressionTests` | 17 | **PHASE A 回归**: 重复粘贴、状态校验、CAS 提交、迁移版本推进、failed/cancelled 恢复语义 |
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
"""

CRITICAL_TESTS = """\
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
"""

REVIEW_PROMPT = """\
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
"""


def rel(path: Path) -> str:
    return str(path.relative_to(ROOT))


def collect_files(patterns: list[str]) -> list[Path]:
    seen: dict[str, Path] = {}
    for pattern in patterns:
        for match in glob.glob(str(ROOT / pattern), recursive=True):
            p = Path(match)
            if p.is_file():
                seen[rel(p)] = p
    return [seen[k] for k in sorted(seen)]


def code_block(text: str, lang: str = "swift") -> str:
    body = text.rstrip("\n")
    return f"{FENCE}{lang}\n{body}\n{FENCE}\n"


def directory_tree() -> str:
    lines: list[str] = []
    for group, patterns in MODULE_GROUPS:
        files = collect_files(patterns)
        if not files:
            continue
        lines.append(f"\n{group}/")
        for f in files:
            n = len(f.read_text(encoding="utf-8").splitlines())
            lines.append(f"    {rel(f):<62} {n:>4} 行")
    return "```text\n" + "\n".join(lines).lstrip("\n") + "\n```\n"


def test_method_names() -> list[str]:
    names: list[str] = []
    for path in collect_files(["Tests/AIRunnerCoreTests/*.swift"]):
        for line in path.read_text(encoding="utf-8").splitlines():
            m = re.match(r"\s*func (test\w+)\s*\(", line)
            if m:
                names.append(m.group(1))
    return sorted(set(names))


def run_and_render_verification() -> str:
    """真正执行 swift build / swift test, 把 command / 起止时间 / exit code / 输出写入包内。

    只有 `--verify` 时才会走这条路径。目的是杜绝"把历史结果伪装成本次实时验证"。
    """
    import shlex
    import subprocess

    blocks: list[str] = []
    for label, cmd in (
        ("构建", ["swift", "build", "--disable-sandbox"]),
        ("测试", ["swift", "test", "--disable-sandbox"]),
    ):
        started = datetime.now(timezone.utc)
        proc = subprocess.run(cmd, cwd=ROOT, capture_output=True, text=True)
        finished = datetime.now(timezone.utc)
        combined = (proc.stdout or "") + (proc.stderr or "")
        tail = "\n".join(combined.splitlines()[-30:]) or "(无输出)"

        blocks.append(
            f"### {label}（本次实测）\n\n"
            f"{FENCE}text\n"
            f"$ {' '.join(shlex.quote(c) for c in cmd)}\n"
            f"# 开始: {started.strftime('%Y-%m-%d %H:%M:%S UTC')}\n"
            f"# 结束: {finished.strftime('%Y-%m-%d %H:%M:%S UTC')}\n"
            f"# exit code: {proc.returncode}\n"
            f"{tail}\n"
            f"{FENCE}\n"
        )
    return "\n".join(blocks) + "\n"


def build(mode: str, verify: bool = False) -> str:
    parts: list[str] = []
    stamp = datetime.now(timezone.utc).strftime("%Y-%m-%d %H:%M UTC")

    swift_files = collect_files(["Sources/**/*.swift", "Tests/**/*.swift"])
    total_lines = sum(len(f.read_text(encoding="utf-8").splitlines()) for f in swift_files)

    # ---------- 封面 ----------
    parts.append(f"""\
# AIRunner — 代码审查包

> 生成时间: {stamp}
> 打包模式: **{mode.upper()}**
> 项目: macOS 原生 App (Swift 6 / SwiftUI / SQLite), 零第三方依赖
> 规模: {len(swift_files)} 个 Swift 文件, {total_lines} 行

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

{code_block(REVIEW_PROMPT, "text")}
""")

    # ---------- 项目概览 ----------
    parts.append("---\n\n## 1. 项目概览\n")
    parts.append(f"""
- **语言/框架**: Swift 6 (language mode v6, 严格并发检查), SwiftUI, 系统 SQLite3
- **外部依赖**: **零** (`Package.swift` 的 `dependencies: []`)
- **平台**: macOS 14+
- **构建**: `swift build` — 0 error
- **测试**: `swift test` — 98 tests / 0 failures
- **数据位置**: `~/Library/Application Support/AIRunner/airunner.sqlite`
- **密钥位置**: macOS Keychain (`service = com.airunner.apikeys`)

### 目录结构

{directory_tree()}
""")

    # ---------- README ----------
    readme = (ROOT / "README.md").read_text(encoding="utf-8")
    parts.append("---\n\n## 2. 设计说明 (`README.md` 全文)\n")
    parts.append(readme.rstrip() + "\n")

    # ---------- 需求边界 ----------
    parts.append("\n---\n\n## 3. 需求边界对照表\n")
    parts.append("""
需求方明确列出了若干**禁止实现**的能力。下面逐条给出实现方式与代码证据。

""")
    parts.append(REQUIREMENT_MATRIX)

    # ---------- 源码 ----------
    parts.append("\n---\n\n## 4. 源码\n")
    if mode == "core":
        parts.append("""
> **CORE 模式**：只展开了与「正确性 / 崩溃恢复 / 安全边界」直接相关的代码，
> 其余文件在各节末尾以清单形式列出。UI 层、测试源码、可选 API 后端均未展开。
> 需要全部源码请用 `--mode full`。

""")

    for group, patterns in MODULE_GROUPS:
        files = collect_files(patterns)
        if not files:
            continue

        parts.append(f"\n### {group}\n")

        if mode == "core":
            expanded = [f for f in files if rel(f) in CORE_WHITELIST]
            listed = [f for f in files if rel(f) not in CORE_WHITELIST]
        else:
            expanded, listed = files, []

        for f in expanded:
            n = len(f.read_text(encoding="utf-8").splitlines())
            parts.append(f"\n#### `{rel(f)}` ({n} 行)\n")
            parts.append(code_block(f.read_text(encoding="utf-8")))

        if listed:
            parts.append("\n*以下文件在 CORE 模式下未展开源码 (仅清单):*\n")
            for f in listed:
                n = len(f.read_text(encoding="utf-8").splitlines())
                parts.append(f"- `{rel(f)}` — {n} 行")
            parts.append("")

    # ---------- 测试 ----------
    parts.append("\n---\n\n## 5. 测试\n")
    parts.append(f"""
共 {len(test_method_names())} 个测试方法, 98 个测试用例 (部分方法含多个断言分组)。

""")
    parts.append(CRITICAL_TESTS)

    if mode == "core":
        parts.append("\n### 全部测试方法清单\n")
        names = test_method_names()
        chunks = [names[i:i + 3] for i in range(0, len(names), 3)]
        parts.append("```text")
        for chunk in chunks:
            parts.append("  ".join(f"{n:<58}" for n in chunk).rstrip())
        parts.append("```\n")
        parts.append("*测试源码见 FULL 版。*\n")

    # ---------- 验证证据 ----------
    parts.append("\n---\n\n## 6. 验证证据\n")
    if verify:
        parts.append(
            "本次打包**实际执行**了构建与测试, 下面是原始输出。\n\n"
        )
        parts.append(run_and_render_verification())
    else:
        parts.append(
            "> ⚠️ **Recorded evidence only — not executed by this packing run.**\n"
            ">\n"
            "> 以下内容是**上一次已知良好运行的历史记录**, 不是本次打包时实测的结果。\n"
            "> 要获得实时证据, 请用 `python3 Scripts/pack_for_review.py "
            f"--mode {mode} --verify` 重新生成。\n\n"
        )
        parts.append(VERIFICATION_EVIDENCE)

    # ---------- 已知取舍 ----------
    parts.append("""
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
""")

    return "\n".join(parts)


def main() -> int:
    parser = argparse.ArgumentParser(description="把 AIRunner 打包成单个 Markdown 供代码审查")
    parser.add_argument("--mode", choices=["full", "core"], default="core")
    parser.add_argument("--output", default=None)
    parser.add_argument(
        "--verify",
        action="store_true",
        help="真正执行 swift build / swift test, 把 command、起止时间、exit code 与原始输出写入包内。"
             "不加此参数时, 包内会明确标注证据为历史记录而非本次实测。",
    )
    args = parser.parse_args()

    output = Path(args.output) if args.output else (
        ROOT / "review" / f"AIRunner-review-{args.mode.upper()}.md"
    )
    output.parent.mkdir(parents=True, exist_ok=True)

    content = build(args.mode, verify=args.verify)
    output.write_text(content, encoding="utf-8")

    size = output.stat().st_size
    # 粗估 token: 代码以 ASCII 为主, 约 3.5 字符/token
    approx_tokens = int(size / 3.5)
    print(f"已生成: {output}")
    print(f"体积  : {size:,} 字节 ({size/1024:.0f} KB)")
    print(f"行数  : {len(content.splitlines()):,}")
    print(f"约 token: {approx_tokens:,} (粗估)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
