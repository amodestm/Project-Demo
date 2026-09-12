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
