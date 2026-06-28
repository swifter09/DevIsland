import Foundation

/// 受管会话：由 DevIsland 自己 spawn 的 headless Claude 会话（编排能力的地基）。
///
/// 原理：`claude -p <任务> --output-format stream-json` 把整个会话过程
/// 以每行一条 JSON 的形式输出（assistant 文本、工具调用、最终 result），
/// 这里解析后直接渲染到岛上，不需要终端。
/// 权限确认走已有的 PermissionRequest hook 通道，照常出现在岛上。
@MainActor
final class ManagedSession: ObservableObject, Identifiable {
    enum State: Equatable {
        case launching, running, succeeded
        case failed(String)

        var labelKey: String {
            switch self {
            case .launching: return "mstate.launching"
            case .running: return "mstate.running"
            case .succeeded: return "mstate.succeeded"
            case .failed: return "mstate.failed"
            }
        }
    }

    nonisolated let id = UUID().uuidString
    let prompt: String
    let cwd: String
    /// 所属项目组名（nil 表示单独发起的任务）
    let groupName: String?
    var projectName: String { URL(fileURLWithPath: cwd).lastPathComponent }

    @Published private(set) var messages: [TranscriptMessage] = []
    @Published private(set) var state: State = .launching

    private var process: Process?
    private var stdoutBuffer = Data()
    private var nextMessageID = 0

    init(prompt: String, cwd: String, groupName: String? = nil) {
        self.prompt = prompt
        self.cwd = cwd
        self.groupName = groupName
    }

    func start() {
        append(.user, prompt)

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        // 经 login shell 解析用户 PATH 找到 claude；prompt 走环境变量避免引号注入
        proc.arguments = ["-lc", #"claude -p "$DEVISLAND_PROMPT" --output-format stream-json --verbose"#]
        var env = ProcessInfo.processInfo.environment
        env["DEVISLAND_PROMPT"] = prompt
        proc.environment = env
        proc.currentDirectoryURL = URL(fileURLWithPath: cwd)

        let stdout = Pipe()
        proc.standardOutput = stdout
        proc.standardError = Pipe()
        stdout.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty else { return }
            Task { @MainActor [weak self] in self?.consume(data) }
        }
        proc.terminationHandler = { [weak self] finished in
            let code = finished.terminationStatus
            Task { @MainActor [weak self] in self?.finish(exitCode: code) }
        }

        do {
            try proc.run()
            process = proc
            state = .running
        } catch {
            state = .failed("无法启动 claude：\(error.localizedDescription)")
        }
    }

    func cancel() {
        process?.terminate()
    }

    // MARK: - stream-json 解析

    private func consume(_ data: Data) {
        stdoutBuffer.append(data)
        while let newline = stdoutBuffer.firstIndex(of: UInt8(ascii: "\n")) {
            let line = stdoutBuffer.prefix(upTo: newline)
            stdoutBuffer.removeSubrange(...newline)
            handleLine(line)
        }
    }

    private func handleLine(_ data: Data) {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = obj["type"] as? String else { return }

        switch type {
        case "assistant":
            guard let message = obj["message"] as? [String: Any],
                  let parts = message["content"] as? [[String: Any]] else { return }
            for part in parts {
                switch part["type"] as? String {
                case "text":
                    if let text = (part["text"] as? String)?
                        .trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
                        append(.assistant, Self.clip(text))
                    }
                case "tool_use":
                    let name = part["name"] as? String ?? "?"
                    let input = part["input"] as? [String: Any]
                    let detail = (input?["command"] as? String)
                        ?? (input?["file_path"] as? String) ?? ""
                    append(.assistant, "🔧 \(name) \(Self.clip(detail, limit: 80))")
                default:
                    break
                }
            }
        case "result":
            if obj["is_error"] as? Bool == true {
                state = .failed(Self.clip(obj["result"] as? String ?? "未知错误", limit: 120))
            } else {
                state = .succeeded
            }
        default:
            break // system/init 等事件暂不展示
        }
    }

    private func finish(exitCode: Int32) {
        process = nil
        // result 事件已定状态的不覆盖
        if state == .running || state == .launching {
            state = exitCode == 0 ? .succeeded : .failed("退出码 \(exitCode)")
        }
    }

    private func append(_ role: TranscriptMessage.Role, _ text: String) {
        messages.append(TranscriptMessage(id: nextMessageID, role: role, text: text))
        nextMessageID += 1
    }

    private static func clip(_ s: String, limit: Int = 280) -> String {
        let oneLine = limit <= 80 ? s.replacingOccurrences(of: "\n", with: " ") : s
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }
}

/// 受管会话的集合，菜单里启动、岛上展示
@MainActor
final class ManagedSessionStore: ObservableObject {
    static let shared = ManagedSessionStore()
    @Published private(set) var sessions: [ManagedSession] = []

    private init() {}

    var runningCount: Int {
        sessions.filter { $0.state == .running || $0.state == .launching }.count
    }

    func launch(prompt: String, cwd: String) {
        let session = ManagedSession(prompt: prompt, cwd: cwd)
        sessions.insert(session, at: 0)
        session.start()
    }

    /// 把同一条指令并行分发给项目组里的每个目录
    func launchGroup(_ group: ProjectGroup, prompt: String) {
        for dir in group.dirs {
            let session = ManagedSession(prompt: prompt, cwd: dir, groupName: group.name)
            sessions.insert(session, at: 0)
            session.start()
        }
    }

    func remove(_ session: ManagedSession) {
        session.cancel()
        sessions.removeAll { $0.id == session.id }
    }

    /// 移除某项目组的全部会话
    func removeGroup(named name: String) {
        for s in sessions where s.groupName == name { s.cancel() }
        sessions.removeAll { $0.groupName == name }
    }

    /// 按组聚合：返回 [(组名, 该组会话)]；nil 组名表示单独任务
    func grouped() -> [(name: String?, sessions: [ManagedSession])] {
        var order: [String?] = []
        var bucket: [String?: [ManagedSession]] = [:]
        for s in sessions {
            if bucket[s.groupName] == nil { order.append(s.groupName) }
            bucket[s.groupName, default: []].append(s)
        }
        return order.map { ($0, bucket[$0] ?? []) }
    }
}
