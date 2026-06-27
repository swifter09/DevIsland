import Foundation
import AppKit

/// 监控 OpenAI Codex 的会话（CLI 与 Codex Desktop GUI 都覆盖）。
/// 会话写在 ~/.codex/sessions/<年>/<月>/<日>/rollout-*.jsonl。
/// session_meta（首行）的 payload 带 cwd 和 originator（"Codex Desktop" = GUI）。
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

            sessions.append(AgentSession(
                id: url.path,
                tool: .codex,
                projectName: URL(fileURLWithPath: cwd).lastPathComponent,
                title: meta.firstUserText,
                conversationHint: isGUI ? "Codex Desktop" : "Codex CLI",
                pendingQuestion: nil,
                cwd: cwd,
                appBundleID: isGUI ? "com.openai.codex" : nil,
                hostName: isGUI ? "Codex.app" : "Codex CLI",
                replyPreview: nil,
                status: age < 30 ? .running : .replied,
                lastActivity: modified
            ))
        }
        return sessions
    }

    private struct Meta { var cwd: String?; var originator: String?; var firstUserText: String? }

    /// 读文件头部：第一行 session_meta 拿 cwd/originator，再扫前几行找首条用户输入做标题
    private static func meta(of url: URL) -> Meta {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return Meta() }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: 32_768),
              let text = String(data: data, encoding: .utf8) else { return Meta() }

        var meta = Meta()
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            let payload = obj["payload"] as? [String: Any]
            if meta.cwd == nil, let c = payload?["cwd"] as? String { meta.cwd = c }
            if meta.originator == nil, let o = payload?["originator"] as? String { meta.originator = o }
            // 首条用户消息作标题
            if meta.firstUserText == nil,
               (payload?["role"] as? String) == "user" || (obj["type"] as? String) == "event_msg" {
                if let t = Self.extractText(payload), !t.isEmpty {
                    meta.firstUserText = String(t.prefix(80))
                }
            }
            if meta.cwd != nil && meta.firstUserText != nil { break }
        }
        return meta
    }

    private static func extractText(_ payload: [String: Any]?) -> String? {
        guard let payload else { return nil }
        if let s = payload["text"] as? String { return clean(s) }
        if let s = payload["message"] as? String { return clean(s) }
        if let content = payload["content"] as? [[String: Any]] {
            for part in content where part["type"] as? String == "text" || part["type"] as? String == "input_text" {
                if let s = part["text"] as? String { return clean(s) }
            }
        }
        return nil
    }

    private static func clean(_ s: String) -> String? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).replacingOccurrences(of: "\n", with: " ")
        guard !t.isEmpty, !t.hasPrefix("<") else { return nil }
        return t
    }
}
