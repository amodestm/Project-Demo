import Foundation

/// 把 UI 上找到的候选线程与绑定的 fingerprint 做匹配。
///
/// ## 为什么要有独立的匹配器
///
/// "找到线程"和"确认是那一个线程"是两回事。Driver 只负责把 UI 上看到的东西
/// 如实报出来; **是否足够可靠到可以自动发送** 由这里判定。
///
/// ## 判定档位
///
/// | 结果 | 含义 |
/// |---|---|
/// | `.unique` | 恰好一个非 weak 候选 —— **唯一允许自动发送的情况** |
/// | `.ambiguous` | 两个及以上可用候选 —— 绝不猜, 交用户重新绑定 |
/// | `.onlyWeakMatches` | 有候选但全部对不上 —— 提示用户, 不发送 |
/// | `.notFound` | 一个候选都没有 |
///
/// 生产路径下, 只有 `.unique` 会继续; 其余一律停止。
public struct CodexTaskMatcher: Sendable {

    public enum Outcome: Sendable, Equatable {
        case unique(CodexScoredCandidate)
        case ambiguous(candidates: [CodexScoredCandidate])
        case onlyWeakMatches(candidates: [CodexScoredCandidate])
        case notFound

        /// 是否可以继续自动发送。
        public var isUnique: Bool {
            if case .unique = self { return true }
            return false
        }

        public var candidateCount: Int {
            switch self {
            case .unique:                          return 1
            case .ambiguous(let list):              return list.count
            case .onlyWeakMatches(let list):        return list.count
            case .notFound:                         return 0
            }
        }
    }

    public init() {}

    // MARK: - 主入口

    public func match(
        fingerprint: CodexTaskFingerprint,
        candidates: [CodexThreadCandidate]
    ) -> Outcome {

        guard !candidates.isEmpty else { return .notFound }

        let scored = candidates.map {
            CodexScoredCandidate(
                candidate: $0,
                strength: strength(of: $0, against: fingerprint)
            )
        }

        let viable = scored.filter { $0.strength != .weak }

        switch viable.count {
        case 0:
            // 有候选, 但没有一个对得上 —— 与"压根没候选"是不同的情况, 要分开报。
            return .onlyWeakMatches(candidates: scored)
        case 1:
            return .unique(viable[0])
        default:
            // ≥2 个可用候选。即使它们都是 exact 也**不能猜** ——
            // 猜错意味着把「继续」发进错误的对话。
            return .ambiguous(candidates: viable)
        }
    }

    // MARK: - 强度评定

    /// 给单个候选评定强度。
    ///
    /// 规则:
    /// * 标题不等 → `weak` (标题是最可靠的单一信号)
    /// * 标题相等, 且有辅助信号**明确矛盾** → `weak`
    /// * 标题相等, 且至少一个辅助信号相等 → `exact`
    /// * 标题相等, 但无从佐证 (UI 读不到辅助字段) → `strong`
    public func strength(
        of candidate: CodexThreadCandidate,
        against fingerprint: CodexTaskFingerprint
    ) -> CodexMatchStrength {

        guard Self.equal(candidate.title, fingerprint.threadTitle) else {
            return .weak
        }

        let compared = compareSecondary(candidate, fingerprint)

        // 有明确矛盾 (两边都有值且不等) —— 说明这不是同一个线程。
        if compared.mismatched > 0 { return .weak }
        // 至少一个辅助信号吻合。
        if compared.matched > 0 { return .exact }
        // 标题对上但没有任何辅助信号可比对。
        return .strong
    }

    /// 比较辅助信号。
    ///
    /// 注意 `nil` 表示"UI 上读不到", 视为**未知**而不是"不等" ——
    /// 把未知当成不等会导致永远匹配不上, 把未知当成相等又会太宽松;
    /// 这里选择记入 `unknown`, 只让"两边都有值且不同"算矛盾。
    private func compareSecondary(
        _ candidate: CodexThreadCandidate,
        _ fingerprint: CodexTaskFingerprint
    ) -> (matched: Int, mismatched: Int, unknown: Int) {

        var matched = 0
        var mismatched = 0
        var unknown = 0

        func compare(_ lhs: String?, _ rhs: String?) {
            guard let rhs, !rhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                return  // fingerprint 没这个信号 → 不参与比较
            }
            guard let lhs, !lhs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                unknown += 1
                return
            }
            if Self.equal(lhs, rhs) { matched += 1 } else { mismatched += 1 }
        }

        compare(candidate.projectName, fingerprint.projectName)
        compare(candidate.repositoryPath, fingerprint.repositoryPath)
        compare(candidate.worktreePath, fingerprint.worktreePath)

        return (matched, mismatched, unknown)
    }

    /// 大小写不敏感 + 去除首尾空白后比较。
    static func equal(_ lhs: String?, _ rhs: String?) -> Bool {
        guard let lhs, let rhs else { return false }
        let a = lhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        let b = rhs.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !a.isEmpty, !b.isEmpty else { return false }
        return a == b
    }

    // MARK: - 二次验证

    /// 打开线程后, 用**主会话区**读到的上下文再确认一次。
    ///
    /// 这是整个自动化最关键的一道 Gate。点了 sidebar 上的候选项之后,
    /// 绝不能立刻输入消息 —— 必须回到主区域重新确认打开的确实是那一个。
    ///
    /// 要求: 标题吻合 **且** 至少一个辅助信号吻合 (两个独立信号)。
    public func verifyOpenedThread(
        context: CodexOpenThreadContext,
        against fingerprint: CodexTaskFingerprint
    ) -> (passed: Bool, secondaryMatched: Bool, reason: String?) {

        guard Self.equal(context.threadTitle, fingerprint.threadTitle) else {
            return (false, false, "主会话区的线程标题与绑定不一致 "
                    + "(期望「\(fingerprint.threadTitle ?? "nil")」, "
                    + "实际「\(context.threadTitle ?? "nil")」)")
        }

        // 标题吻合后, 再要一个独立信号。
        let pairs: [(String?, String?)] = [
            (context.projectName, fingerprint.projectName),
            (context.repositoryPath, fingerprint.repositoryPath),
            (context.worktreePath, fingerprint.worktreePath),
        ]

        var matched = 0
        var compared = 0
        for (lhs, rhs) in pairs {
            guard let rhs, !rhs.isEmpty else { continue }
            compared += 1
            guard let lhs, !lhs.isEmpty else { continue }
            if Self.equal(lhs, rhs) { matched += 1 }
        }

        if matched > 0 {
            return (true, true, nil)
        }

        if compared == 0 {
            // 绑定里没有辅助信号可比 —— 只有标题这一个信号。
            // 定位可以放行 (Test Locate), 但发送门槛会因为这个 false 而拒绝。
            return (true, false, "只有标题这一个信号, 缺少第二个独立信号佐证")
        }

        return (false, false, "标题吻合, 但辅助上下文对不上 (可能打开的是同名线程)")
    }
}
