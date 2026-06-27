import Foundation
import Combine

/// 所有监控器汇总到这里，UI 只观察这一个对象。
@MainActor
final class SessionStore: ObservableObject {
    static let shared = SessionStore()

    @Published private(set) var sessions: [AgentSession] = []

    /// 有会话在向用户提问时，菜单栏图标高亮
    var hasAttention: Bool {
        sessions.contains { $0.status == .asking }
    }

    var runningCount: Int {
        sessions.filter { $0.status == .running }.count
    }

    private var monitors: [any SessionMonitor] = []
    private var timer: Timer?
    /// 正在刷新时的开始时间；nil 表示空闲。
    /// 用时间戳而非布尔，是为了自愈：万一某次扫描异常没能复位，
    /// 超时后下一轮仍能放行，岛不会被一次卡顿永久冻结。
    private var refreshStartedAt: Date?
    private let refreshTimeout: TimeInterval = 15

    private init() {}

    func startMonitoring() {
        // 在这里注册各工具的监控器；新增工具 = 新增一个 SessionMonitor 实现
        monitors = [
            ClaudeCodeMonitor(),
            CodexMonitor(),
        ]
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in
                SessionStore.shared.refresh()
            }
        }
    }

    /// 扫描在后台线程执行（文件 IO + ps/lsof 较重，曾把主线程卡死），
    /// 只有发布结果回到主线程
    func refresh() {
        // 上一轮还在跑就跳过；但超过 timeout 视为卡死，强制放行
        if let started = refreshStartedAt,
           Date().timeIntervalSince(started) < refreshTimeout {
            return
        }
        refreshStartedAt = Date()
        let monitors = self.monitors
        Task.detached(priority: .utility) {
            let all = monitors.flatMap { $0.currentSessions() }
            // 按活跃时间倒序，最多展示最近的 8 个
            // 同目录并发会话可能很多，放宽上限到 12
            let sorted = Array(all.sorted { $0.lastActivity > $1.lastActivity }.prefix(12))
            await MainActor.run {
                let store = SessionStore.shared
                if sorted != store.sessions {
                    store.sessions = sorted
                }
                store.refreshStartedAt = nil
            }
        }
    }
}
