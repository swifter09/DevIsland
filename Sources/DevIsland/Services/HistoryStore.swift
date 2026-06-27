import Foundation
import Combine

/// 一段历史会话（一个转录文件 = 一段对话）
struct HistoryConversation: Identifiable, Equatable {
    let id: String          // 文件路径
    let url: URL
    let sessionID: String   // 文件名去掉 .jsonl，用于 claude --resume
    let projectName: String
    let cwd: String?
    let title: String?      // Claude 生成的会话标题
    let lastUserPrompt: String?
    let lastActivity: Date  // 文件最后修改时间
    let sizeBytes: Int

    static func == (l: HistoryConversation, r: HistoryConversation) -> Bool {
        l.id == r.id && l.lastActivity == r.lastActivity
    }
}

/// 扫描 ~/.claude*/projects 下的**全部**转录文件（不只活跃的），供历史复盘。
///
/// 与 ClaudeCodeMonitor 的区别：监控器只关心「有活跃进程」的会话且每 2 秒轮询；
/// 这里是按需（打开历史窗口时）一次性扫全部，不进刷新循环、不依赖进程是否在跑。
/// 数据本身一直由 Claude Code 持久化在转录文件里，App 没开也不丢。
@MainActor
final class HistoryStore: ObservableObject {
    static let shared = HistoryStore()

    @Published private(set) var conversations: [HistoryConversation] = []
    @Published private(set) var isLoading = false

    private init() {}

    /// 与 ClaudeCodeMonitor 一致：~/.claude 及 ~/.claude-* 多 profile
    private static func projectsDirs() -> [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: home, includingPropertiesForKeys: nil)) ?? []
        var dirs = candidates
            .filter { $0.lastPathComponent.hasPrefix(".claude-") }
            .map { $0.appendingPathComponent("projects") }
        dirs.append(home.appendingPathComponent(".claude/projects"))
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// 重新扫描（打开窗口或点刷新时调用）。文件 IO 较重，放后台线程。
    func reload() {
        guard !isLoading else { return }
        isLoading = true
        let dirs = Self.projectsDirs()
        Task.detached(priority: .userInitiated) {
            let list = Self.scan(dirs)
            await MainActor.run {
                self.conversations = list
                self.isLoading = false
            }
        }
    }

    nonisolated private static func scan(_ projectsDirs: [URL]) -> [HistoryConversation] {
        let fm = FileManager.default
        var out: [HistoryConversation] = []

        for projectsDir in projectsDirs {
            guard let projectDirs = try? fm.contentsOfDirectory(
                at: projectsDir, includingPropertiesForKeys: nil,
                options: .skipsHiddenFiles) else { continue }

            for projectDir in projectDirs {
                guard let files = try? fm.contentsOfDirectory(
                    at: projectDir,
                    includingPropertiesForKeys: [.contentModificationDateKey, .fileSizeKey],
                    options: .skipsHiddenFiles) else { continue }

                for url in files where url.pathExtension == "jsonl" {
                    let vals = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    let size = vals?.fileSize ?? 0
                    guard size > 0 else { continue }   // 空转录跳过
                    let mtime = vals?.contentModificationDate ?? .distantPast

                    let tail = TranscriptReader.tail(of: url)
                    let cwd = TranscriptReader.cwd(of: url) ?? tail.cwd
                    out.append(HistoryConversation(
                        id: url.path,
                        url: url,
                        sessionID: url.deletingPathExtension().lastPathComponent,
                        projectName: ClaudeCodeMonitor.projectName(
                            cwd: cwd, fallbackDir: projectDir.lastPathComponent),
                        cwd: cwd,
                        title: tail.aiTitle,
                        lastUserPrompt: tail.lastUserPrompt,
                        lastActivity: mtime,
                        sizeBytes: size
                    ))
                }
            }
        }
        return out.sorted { $0.lastActivity > $1.lastActivity }
    }
}
