import Foundation
import AppKit

/// 监控 OpenAI Codex 的会话（CLI 与 Codex Desktop GUI 都覆盖）。
/// 会话写在 ~/.codex/sessions/<年>/<月>/<日>/rollout-*.jsonl。
/// - 首行 session_meta 的 payload 带 cwd 和 originator（"Codex Desktop" = GUI）。
/// - 后续行是 response_item / event_msg：function_call（工具调用）、agent_message
///   （助手回复）、user_message、task_started / task_complete（回合状态）等。
struct CodexMonitor: SessionMonitor {
    private let sessionsDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions")

    func currentSessions() -> [AgentSession] {
        let fm = FileManager.default
        let now = Date()
        // 递归扫描：Codex 会续用老会话文件（按"创建日期"归档但一直追加），
        // 只能按"修改时间"在全部文件里筛活跃的，不能只看今天/昨天目录。
        guard fm.fileExists(atPath: sessionsDir.path),
              let enumerator = fm.enumerator(
                at: sessionsDir, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles]) else { return [] }

        let codexRunning = Shell.run("/bin/ps", ["-axo", "command="])
            .contains("Codex.app/Contents/MacOS/Codex")

        var sessions: [AgentSession] = []
        for case let url as URL in enumerator where url.pathExtension == "jsonl" {
            guard let modified = try? url.resourceValues(forKeys: [.contentModificationDateKey])
                .contentModificationDate else { continue }
            let age = now.timeIntervalSince(modified)
            guard age < 1800 else { continue }   // 粗筛，跳过明显陈旧的

            let meta = Self.meta(of: url)
            guard let cwd = meta.cwd else { continue }
            let isGUI = meta.originator?.localizedCaseInsensitiveContains("desktop") ?? false
            // CLI：5 分钟内有写入算活跃；GUI：Codex.app 运行时放宽到 30 分钟
            let window: TimeInterval = (isGUI && codexRunning) ? 1800 : 300
            guard age < window else { continue }

            let tail = Self.tailInfo(of: url)

            // 状态基于最后一条有意义记录的类型，修改时间只做辅助（与 Claude 监控一致）：
            // 工具执行中（长命令）文件可能几分钟不写入，不能据此判定"已回复"。
            let status: AgentSession.Status
            switch tail.lastKind {
            case .toolCall, .taskStarted:
                status = .running                  // 在跑工具/回合进行中，不限时长
            case .userMessage:
                status = age < 60 ? .running : .replied
            case .agentMessage, .taskComplete, .none:
                status = age < 30 ? .running : .replied
            }

            sessions.append(AgentSession(
                id: url.path,
                tool: .codex,
                projectName: URL(fileURLWithPath: cwd).lastPathComponent,
                title: meta.firstUserText ?? tail.firstUserText,
                conversationHint: isGUI ? "Codex Desktop" : "Codex CLI",
                pendingQuestion: nil,              // Codex 无 AskUserQuestion 式提问流
                cwd: cwd,
                appBundleID: isGUI ? "com.openai.codex" : nil,
                hostName: isGUI ? "Codex.app" : "Codex CLI",
                replyPreview: tail.lastAgentMessage,
                recentMessages: tail.recentMessages,
                currentAction: status == .running ? tail.currentAction : nil,
                status: status,
                lastActivity: modified
            ))
        }
        return sessions
    }

    private struct Meta { var cwd: String?; var originator: String?; var firstUserText: String? }

    /// 读首行 session_meta 拿 cwd/originator。
    /// 关键：首行含巨大的 base_instructions（可达数十 KB），必须读到**首个换行符**为止，
    /// 否则固定大小的截断会让整行 JSON 解析失败 → 连 cwd 都拿不到 → 会话被整条漏掉。
    private static func meta(of url: URL) -> Meta {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Meta() }
        defer { try? handle.close() }

        var data = Data()
        while data.count < 4_194_304 {                          // 4MB 兜底,正常远小于此
            guard let chunk = try? handle.read(upToCount: 65_536), !chunk.isEmpty else { break }
            data.append(chunk)
            if let nl = data.firstIndex(of: 0x0A) {             // 0x0A = '\n'
                data = data.prefix(upTo: nl)
                break
            }
        }
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let payload = obj["payload"] as? [String: Any] else { return Meta() }

        var meta = Meta()
        meta.cwd = payload["cwd"] as? String
        meta.originator = payload["originator"] as? String
        // 标题留给 tail 里抓到的首条用户消息（session_meta 本身不含用户输入）
        return meta
    }

    private struct TailInfo {
        var recentMessages: [TranscriptMessage] = []
        var currentAction: String?
        var lastAgentMessage: String?
        var firstUserText: String?
        var lastKind: LastKind = .none
        enum LastKind { case toolCall, taskStarted, taskComplete, agentMessage, userMessage, none }
    }

    /// 读文件尾部，解析最近消息 / 当前动作 / 状态 / 回复预览。
    private static func tailInfo(of url: URL, maxBytes: Int = 131_072) -> TailInfo {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return TailInfo() }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()
        let text = String(decoding: data, as: UTF8.self)

        var lines = text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
        if start > 0, !lines.isEmpty { lines.removeFirst() }   // 丢掉被截断的首行

        var info = TailInfo()
        var msgs: [TranscriptMessage] = []
        var idx = 0
        for line in lines {
            defer { idx += 1 }
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let payload = obj["payload"] as? [String: Any] else { continue }
            let ptype = payload["type"] as? String

            switch ptype {
            case "function_call":
                info.lastKind = .toolCall
                if let a = Self.actionText(payload) { info.currentAction = a }
            case "function_call_output":
                // 工具有了输出 → 上一个动作已结束;清掉"当前动作",避免显示已完成的命令
                if info.lastKind == .toolCall { info.lastKind = .taskStarted }
                info.currentAction = nil
            case "task_started":
                info.lastKind = .taskStarted
            case "task_complete":
                info.lastKind = .taskComplete
                if let s = payload["last_agent_message"] as? String, let c = clean(s) {
                    info.lastAgentMessage = c
                }
            case "agent_message":
                info.lastKind = .agentMessage
                if let t = (payload["message"] as? String).flatMap(clean) {
                    info.lastAgentMessage = t
                    msgs.append(TranscriptMessage(id: idx, role: .assistant, text: String(t.prefix(300))))
                }
            case "user_message":
                info.lastKind = .userMessage
                if let t = (payload["message"] as? String).flatMap(clean) {
                    if info.firstUserText == nil { info.firstUserText = String(t.prefix(80)) }
                    msgs.append(TranscriptMessage(id: idx, role: .user, text: String(t.prefix(300))))
                }
            default:
                break
            }
        }
        info.recentMessages = Array(msgs.suffix(3))
        return info
    }

    /// 把一次 function_call 渲染成简短动作文案,如 "exec_command: pwd"、"apply_patch: file.swift"
    private static func actionText(_ payload: [String: Any]) -> String? {
        guard let name = payload["name"] as? String else { return nil }
        guard let argStr = payload["arguments"] as? String,
              let args = try? JSONSerialization.jsonObject(with: Data(argStr.utf8)) as? [String: Any]
        else { return name }

        if let cmd = args["cmd"] as? String, let c = clean(cmd) { return "\(name): \(c)" }
        if let cmd = args["command"] as? String, let c = clean(cmd) { return "\(name): \(c)" }
        if let arr = args["cmd"] as? [String], !arr.isEmpty { return "\(name): \(arr.joined(separator: " "))" }
        if let path = (args["path"] as? String) ?? (args["file_path"] as? String) {
            return "\(name): \((path as NSString).lastPathComponent)"
        }
        return name
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !t.isEmpty, !t.hasPrefix("<") else { return nil }
        return String(t.prefix(200))
    }
}
