import Foundation

/// 每种 AI 工具一个监控器实现。
/// 实现方式可以是：读取工具的本地会话文件、监听 hook 回调、扫描进程等。
/// 注意：currentSessions() 在后台线程执行（文件 IO + 进程扫描较重），实现必须无状态。
protocol SessionMonitor: Sendable {
    func currentSessions() -> [AgentSession]
}
