import Foundation

/// 通过扫描 ~/.claude/projects/ 下的会话转录文件（.jsonl）来感知 Claude Code 会话。
///
/// 这是最简单可行的实现：用文件修改时间判断活跃度。
/// - 30 秒内有写入  → 运行中
/// - 5 分钟内有写入 → 等待用户（大概率是停下来等输入了）
/// - 更早            → 不展示
///
/// 进阶做法（留作 TODO）：
/// - 解析 jsonl 最后一行，精确区分「等待权限确认」和「回复完成」
/// - 通过 Claude Code hooks（Notification / Stop）主动推送状态，而不是轮询
struct ClaudeCodeMonitor: SessionMonitor {
    /// 支持多 profile：~/.claude 以及 CLAUDE_CONFIG_DIR 风格的 ~/.claude-work 等
    private var projectsDirs: [URL] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        // 注意不能用 .skipsHiddenFiles，目标本身就是 .claude-* 隐藏目录
        let candidates = (try? FileManager.default.contentsOfDirectory(
            at: home,
            includingPropertiesForKeys: nil
        )) ?? []
        var dirs = candidates
            .filter { $0.lastPathComponent.hasPrefix(".claude-") }
            .map { $0.appendingPathComponent("projects") }
        dirs.append(home.appendingPathComponent(".claude/projects"))
        return dirs.filter { FileManager.default.fileExists(atPath: $0.path) }
    }

    func currentSessions() -> [AgentSession] {
        projectsDirs.flatMap { sessions(in: $0) }
    }

    private func sessions(in projectsDir: URL) -> [AgentSession] {
        let fm = FileManager.default
        guard let projectDirs = try? fm.contentsOfDirectory(
            at: projectsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return [] }

        var sessions: [AgentSession] = []
        let now = Date()
        // 进程优先：有几个 claude 进程在某个 cwd，就显示几个会话。
        // 这样既排除无进程的普通终端（伪命题），又不漏同目录的并发会话。
        let procs = AgentProcessScanner.agentProcesses()
        var liveCount: [String: Int] = [:]
        for proc in procs { liveCount[proc.cwd, default: 0] += 1 }

        // 每个 cwd 下的进程（带启动时间 + 终端名），按启动时间升序，
        // 用于和该 cwd 的转录（按创建时间升序）配对，推断每条会话在哪个终端。
        let tree = procs.isEmpty ? ProcessTree(nodes: [:]) : ProcessTree.snapshot()
        var procsByCwd: [String: [(start: Date, host: String?)]] = [:]
        for proc in procs {
            let host = tree.findTerminal(fromPID: proc.pid)?.kind.displayName
            procsByCwd[proc.cwd, default: []].append((proc.startedAt, host))
        }
        for cwd in procsByCwd.keys {
            procsByCwd[cwd]?.sort { $0.start < $1.start }
        }

        for projectDir in projectDirs {
            guard let files = try? fm.contentsOfDirectory(
                at: projectDir,
                includingPropertiesForKeys: [.contentModificationDateKey],
                options: .skipsHiddenFiles
            ) else { continue }

            // 该项目目录下的转录按修改时间倒序（同一目录的转录共享同一 cwd）
            let dated = files
                .filter { $0.pathExtension == "jsonl" }
                .compactMap { url -> (URL, Date)? in
                    guard let date = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                        .contentModificationDate else { return nil }
                    return (url, date)
                }
                .sorted { $0.1 > $1.1 }
            guard let newest = dated.first else { continue }

            // 从文件头部读 cwd（比尾部稳，尾部可能落在超大记录中间读不到）；
            // 该目录必须有活跃 claude 进程才算有效会话
            guard let cwd = TranscriptReader.cwd(of: newest.0),
                  let n = liveCount[cwd], n > 0 else { continue }

            // 该目录有 N 个活跃 claude 进程 → 显示最近 N 个转录（一一对应这 N 个会话）。
            // 不按时间窗口卡——否则"进程还活着但空闲很久"的会话会被漏掉。
            let shown = Array(dated.prefix(n))

            // 推断每条转录所在终端。转录文件不记终端信息、进程也不暴露 sessionId，
            // 所以只能间接判断：
            //   ① 该 cwd 的所有进程都来自同一终端 → 直接确定，100% 准；
            //   ② 混用了多个终端 → 退回「转录创建时间 ↔ 进程启动时间」逐位配对（仅best-effort，可能标反）。
            let cwdProcs = procsByCwd[cwd] ?? []
            var hostByFile: [String: String] = [:]
            let distinctHosts = Set(cwdProcs.compactMap { $0.host })
            if distinctHosts.count == 1, let only = distinctHosts.first {
                for (file, _) in shown { hostByFile[file.path] = only }
            } else {
                let byCreation = shown.map { item -> (URL, Date) in
                    let c = (try? item.0.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? item.1
                    return (item.0, c)
                }.sorted { $0.1 < $1.1 }
                for (i, item) in byCreation.enumerated() where i < cwdProcs.count {
                    if let h = cwdProcs[i].host { hostByFile[item.0.path] = h }
                }
            }

            for (file, modified) in shown {
                let age = now.timeIntervalSince(modified)
                let tail = TranscriptReader.tail(of: file)
                // cwd 优先用可靠的头部读取，尾部读不到时兜底
                let sessionCwd = TranscriptReader.cwd(of: file) ?? tail.cwd ?? cwd

                // 状态基于最后一条转录记录的类型，修改时间只做辅助：
                // 工具执行中（长构建等）转录可能几分钟不写入，不能据此判定"已回复"
                let status: AgentSession.Status
                if tail.pendingQuestion != nil {
                    status = .asking
                } else {
                    switch tail.lastEntry {
                    case .assistantToolUse:
                        status = .running // 工具没出结果就是在干活，不限时长
                    case .userEntry:
                        // 用户消息/工具结果刚回来，Claude 在处理；
                        // 太久没动静大概率是会话被中断了
                        status = age < 60 ? .running : .replied
                    case .assistantText, .none:
                        status = age < 30 ? .running : .replied
                    }
                }

                sessions.append(AgentSession(
                    id: file.path,
                    tool: .claudeCode,
                    // 真实项目名只能取自转录里的 cwd——目录名是有损编码（/ 和 _ 都成了 -）
                    projectName: Self.projectName(cwd: sessionCwd, fallbackDir: projectDir.lastPathComponent),
                    title: tail.aiTitle,
                    conversationHint: tail.lastUserPrompt,
                    pendingQuestion: tail.pendingQuestion,
                    cwd: sessionCwd,
                    appBundleID: nil, // 终端里的 CLI 会话
                    hostName: hostByFile[file.path],
                    replyPreview: tail.lastAssistantText,
                    recentMessages: TranscriptReader.recentMessages(in: file, limit: 3),
                    currentAction: tail.currentAction,
                    status: status,
                    lastActivity: modified
                ))
            }
        }
        return sessions
    }

    /// 从真实 cwd 取项目名：默认末段；若末段是泛用名（ios/app/src 等）则带上父目录。
    /// cwd 缺失时退回编码目录名的末段（有损，仅兜底）。
    static func projectName(cwd: String?, fallbackDir: String) -> String {
        guard let cwd, !cwd.isEmpty else {
            return fallbackDir.split(separator: "-").last.map(String.init) ?? fallbackDir
        }
        let comps = cwd.split(separator: "/").map(String.init)
        guard let last = comps.last else { return cwd }
        let generic: Set<String> = ["ios", "android", "app", "apps", "src", "lib",
                                    "web", "frontend", "backend", "server", "client", "packages"]
        if generic.contains(last.lowercased()), comps.count >= 2 {
            return "\(comps[comps.count - 2])/\(last)" // 例：urbank_flutter/ios
        }
        return last
    }
}
