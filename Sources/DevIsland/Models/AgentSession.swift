import Foundation

/// 一个被监控的 AI 编程工具会话
struct AgentSession: Identifiable, Equatable {
    /// 状态只基于转录里的事实，不做时间猜测（曾经的"等待确认"误导性太强）
    enum Status: Equatable {
        case running   // 转录正在写入
        case asking    // Claude 正通过 AskUserQuestion 等用户选择
        case replied   // 最后一条是 Claude 的回复，等用户下一条消息

        /// 本地化 key,调用方用 L10n.shared.t(labelKey) 取当前语言文案
        var labelKey: String {
            switch self {
            case .running: return "status.running"
            case .asking: return "status.asking"
            case .replied: return "status.replied"
            }
        }
    }

    enum Tool: String, CaseIterable {
        case claudeCode = "Claude Code"
        case codex = "Codex"
        case geminiCLI = "Gemini CLI"
        case cursor = "Cursor"

        var symbolName: String {
            switch self {
            case .claudeCode: return "asterisk"
            case .codex: return "chevron.left.forwardslash.chevron.right"
            case .geminiCLI: return "sparkle"
            case .cursor: return "cursorarrow"
            }
        }

        /// 卡片标签用的短名
        var shortName: String {
            switch self {
            case .claudeCode: return "Claude"
            case .codex: return "Codex"
            case .geminiCLI: return "Gemini"
            case .cursor: return "Cursor"
            }
        }
    }

    let id: String
    let tool: Tool
    /// 项目名（通常是工作目录名）
    let projectName: String
    /// Claude 生成的会话标题（区分同目录的多个会话，类似终端标签标题）
    var title: String?
    /// 该会话最近一条用户消息，回答"这是哪个对话"
    var conversationHint: String?
    /// Claude 正在问的问题（status == .asking 时有值）
    var pendingQuestion: String?
    /// 会话工作目录，用于跳转到对应终端
    var cwd: String?
    /// 若是 GUI 工具（如 Codex Desktop）发起的会话，这里是它的 App bundle id；
    /// 跳转时激活这个 App 而不是找终端。终端里的 CLI 会话为 nil。
    var appBundleID: String?
    /// 承载会话的应用名标签（如 Codex.app / Ghostty / VS Code），展示在卡片右侧
    var hostName: String?
    /// 最近一条 AI 回复预览（卡片第三行）
    var replyPreview: String?
    /// 最近几条对话（内联展示，最多 3 条）
    var recentMessages: [TranscriptMessage] = []
    /// 正在执行的动作（如 "Bash: npm run build"），让用户看到反应
    var currentAction: String?
    var status: Status
    var lastActivity: Date

    /// 该会话项目的看板 HTML 固定约定路径：<cwd>/.board/board.html（由 /update-board 生成）
    var boardPath: String? {
        cwd.map { ($0 as NSString).appendingPathComponent(".board/board.html") }
    }

    /// 看板文件是否真实存在；cwd 为 nil 或文件缺失都为 false
    var hasBoard: Bool {
        guard let boardPath else { return false }
        return FileManager.default.fileExists(atPath: boardPath)
    }
}
