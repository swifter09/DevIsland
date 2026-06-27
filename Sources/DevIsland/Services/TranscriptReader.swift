import Foundation

/// 转录尾部解析出的会话上下文
struct TranscriptTail {
    /// 最后一条记录是什么——判断"是否正在干活"的依据。
    /// 关键：工具执行中（如长构建）转录可能几分钟不写入，不能只看文件修改时间。
    enum LastEntryKind {
        case assistantText     // Claude 文本回复 → 回合大概率结束
        case assistantToolUse  // 工具调用还没出结果 → 正在干活（可能很久）
        case userEntry         // 用户消息/工具结果刚写入 → Claude 在处理
        case none
    }

    /// 最近一条真正的用户消息（"这是哪个对话"）
    var lastUserPrompt: String?
    /// Claude 正通过 AskUserQuestion 向用户提的问题（终端里有选项在等）
    var pendingQuestion: String?
    var lastEntry: LastEntryKind = .none
    /// 会话工作目录（转录条目自带）
    var cwd: String?
    /// Claude 自动生成的会话标题（区分同目录多会话）
    var aiTitle: String?
    /// 最近一条 AI 文本回复（卡片回复预览）
    var lastAssistantText: String?
    /// 正在执行的动作（最新一条是未完成的 tool_use 时），如 "Bash: npm run build"
    var currentAction: String?
}

/// 详情页里展示的一条对话消息
struct TranscriptMessage: Identifiable, Equatable {
    enum Role: Equatable { case user, assistant }
    /// 行在文件中的序号，刷新间保持稳定
    let id: Int
    let role: Role
    let text: String
}

/// 从 Claude Code 转录文件（.jsonl）里提取上下文信息。
/// 只读文件尾部，避免大文件开销。
enum TranscriptReader {

    /// 最近几轮对话（详情页用），按时间正序返回
    static func recentMessages(in transcript: URL, limit: Int = 8,
                               maxBytes: Int = 200_000) -> [TranscriptMessage] {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return [] }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return [] }
        // 容错解码：活跃写入的文件尾部可能截断在多字节字符中间，
        // .utf8 会整体返回 nil，这里用替换式解码保证总能拿到文本
        let text = String(decoding: data, as: UTF8.self)

        var messages: [TranscriptMessage] = []
        let lines = Array(text.split(separator: "\n").enumerated())

        for (index, line) in lines.reversed() {
            guard messages.count < limit,
                  let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  obj["isMeta"] as? Bool != true,
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any]
            else { continue }

            var content: String?
            if let s = message["content"] as? String {
                content = s
            } else if let parts = message["content"] as? [[String: Any]] {
                content = parts.first { $0["type"] as? String == "text" }?["text"] as? String
            }

            guard let raw = content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, !raw.hasPrefix("<"), !raw.hasPrefix("Caveat:"), !raw.hasPrefix("[Request")
            else { continue }

            let role: TranscriptMessage.Role
            switch type {
            case "user": role = .user
            case "assistant": role = .assistant
            default: continue
            }

            let clipped = raw.count > 280 ? String(raw.prefix(280)) + "…" : raw
            messages.append(TranscriptMessage(id: index, role: role, text: clipped))
        }
        return messages.reversed()
    }

    /// 完整对话（历史复盘用）：从文件头部按时间正序解析全部用户/AI 文本消息，不截断每条内容。
    /// 与 recentMessages 的区别——后者只读尾部、每条裁到 280 字、用于卡片预览。
    static func fullMessages(in transcript: URL, limit: Int = 2000,
                             maxBytes: Int = 8_000_000) -> [TranscriptMessage] {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return [] }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return [] }
        let text = String(decoding: data, as: UTF8.self)

        var messages: [TranscriptMessage] = []
        for (index, line) in text.split(separator: "\n").enumerated() {
            guard messages.count < limit,
                  let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let type = obj["type"] as? String,
                  obj["isMeta"] as? Bool != true,
                  obj["isSidechain"] as? Bool != true,
                  let message = obj["message"] as? [String: Any]
            else { continue }

            // 一条消息可能含多个 text 块，全拼起来；忽略 tool_use / tool_result 等
            var content: String?
            if let s = message["content"] as? String {
                content = s
            } else if let parts = message["content"] as? [[String: Any]] {
                let texts = parts.compactMap { part -> String? in
                    part["type"] as? String == "text" ? part["text"] as? String : nil
                }
                content = texts.isEmpty ? nil : texts.joined(separator: "\n")
            }

            guard let raw = content?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !raw.isEmpty, !raw.hasPrefix("<"), !raw.hasPrefix("Caveat:"), !raw.hasPrefix("[Request")
            else { continue }

            let role: TranscriptMessage.Role
            switch type {
            case "user": role = .user
            case "assistant": role = .assistant
            default: continue
            }
            messages.append(TranscriptMessage(id: index, role: role, text: raw))
        }
        return messages
    }

    static func lastUserPrompt(in transcript: URL) -> String? {
        tail(of: transcript).lastUserPrompt
    }

    /// 从文件头部读会话的 cwd（会话开始即有，记录小且可靠）。
    /// 比读尾部稳——尾部可能落在超大单条记录（截图/大文件）中间而读不到。
    static func cwd(of transcript: URL, maxBytes: Int = 65_536) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: maxBytes) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        for line in text.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any]
            else { continue }
            if let c = obj["cwd"] as? String, !c.isEmpty { return c }
        }
        return nil
    }

    static func tail(of transcript: URL, maxBytes: Int = 200_000) -> TranscriptTail {
        var info = TranscriptTail()
        guard let handle = try? FileHandle(forReadingFrom: transcript) else { return info }
        defer { try? handle.close() }

        let size = (try? handle.seekToEnd()) ?? 0
        let offset = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        try? handle.seek(toOffset: offset)
        guard let data = try? handle.readToEnd() else { return info }
        // 容错解码：活跃写入的文件尾部可能截断在多字节字符中间
        let text = String(decoding: data, as: UTF8.self)

        var latestEntrySeen = false

        for line in text.split(separator: "\n").reversed() {
            guard let lineData = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: lineData) as? [String: Any],
                  let type = obj["type"] as? String,
                  obj["isMeta"] as? Bool != true,
                  obj["isSidechain"] as? Bool != true
            else { continue }

            if info.cwd == nil {
                info.cwd = obj["cwd"] as? String
            }

            // Claude 生成的会话标题（即 Ghostty 标签显示的摘要），用来区分同目录多会话。
            // 记录形如 {"type":"ai-title","aiTitle":"...","sessionId":"..."}
            if info.aiTitle == nil, type == "ai-title",
               let t = obj["aiTitle"] as? String,
               !t.trimmingCharacters(in: .whitespaces).isEmpty {
                info.aiTitle = clip(t, limit: 80)
            }

            guard let message = obj["message"] as? [String: Any] else { continue }

            // 最新一条记录决定"Claude 现在处于什么状态"
            if !latestEntrySeen {
                if type == "assistant", let parts = message["content"] as? [[String: Any]] {
                    latestEntrySeen = true
                    if let ask = parts.first(where: {
                        $0["type"] as? String == "tool_use" &&
                        $0["name"] as? String == "AskUserQuestion"
                    }) {
                        let questions = (ask["input"] as? [String: Any])?["questions"] as? [[String: Any]]
                        if let q = questions?.first?["question"] as? String {
                            info.pendingQuestion = clip(q)
                        }
                        info.lastEntry = .assistantToolUse
                    } else if let tu = parts.first(where: { $0["type"] as? String == "tool_use" }) {
                        info.lastEntry = .assistantToolUse
                        // 提取正在执行的动作：工具名 + 命令/文件
                        let name = tu["name"] as? String ?? "工具"
                        let tin = tu["input"] as? [String: Any]
                        let detail = (tin?["command"] as? String)
                            ?? (tin?["file_path"] as? String).map { ($0 as NSString).lastPathComponent }
                            ?? ""
                        info.currentAction = detail.isEmpty ? name : "\(name): \(clip(detail, limit: 70))"
                    } else if parts.contains(where: { $0["type"] as? String == "text" }) {
                        info.lastEntry = .assistantText
                    }
                } else if type == "user" {
                    latestEntrySeen = true
                    info.lastEntry = .userEntry
                }
            }

            // 最近一条 AI 文本回复（卡片预览），扫到第一条即止，不影响状态判定
            if info.lastAssistantText == nil, type == "assistant",
               let parts = message["content"] as? [[String: Any]],
               let t = parts.first(where: { $0["type"] as? String == "text" })?["text"] as? String {
                let c = t.trimmingCharacters(in: .whitespacesAndNewlines)
                if !c.isEmpty { info.lastAssistantText = clip(c, limit: 100) }
            }

            // 最近一条真正的用户输入（跳过 tool_result、命令、系统注入等）
            if info.lastUserPrompt == nil, type == "user" {
                var prompt: String?
                if let s = message["content"] as? String {
                    prompt = s
                } else if let parts = message["content"] as? [[String: Any]] {
                    // content 数组里可能混着 tool_result，只取 text 块
                    prompt = parts.first { $0["type"] as? String == "text" }?["text"] as? String
                }
                if let p = prompt?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !p.isEmpty,
                   !p.hasPrefix("<"),          // <command-name> / <system-reminder> 等注入内容
                   !p.hasPrefix("Caveat:"),
                   !p.hasPrefix("[Request") {  // 中断标记
                    info.lastUserPrompt = clip(p)
                }
            }

            if info.lastUserPrompt != nil && latestEntrySeen { break }
        }
        return info
    }

    private static func clip(_ s: String, limit: Int = 60) -> String {
        let oneLine = s.replacingOccurrences(of: "\n", with: " ")
        return oneLine.count > limit ? String(oneLine.prefix(limit)) + "…" : oneLine
    }
}
