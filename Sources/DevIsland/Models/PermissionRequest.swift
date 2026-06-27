import Foundation

/// 一道 AskUserQuestion 的问题
struct PermissionQuestion: Equatable {
    let question: String
    let options: [String]
    let multiSelect: Bool
}

/// 一条等待用户处理的请求（由 hook 写入 ~/.devisland/requests/）：
/// 权限审批（允许/拒绝）或 AskUserQuestion 就地作答。
struct PermissionRequest: Identifiable, Equatable {
    enum Kind: Equatable { case permission, question }

    let id: String
    let kind: Kind
    /// kind == .question 时的问题列表
    let questions: [PermissionQuestion]
    let sessionId: String
    let toolName: String
    /// 请求来自哪个项目（工作目录名）
    let projectName: String
    /// 工作目录绝对路径（判定"前台不弹"用）
    let cwd: String
    /// 会话转录路径（用于检测会话是否已在别处推进、自动取消岛上卡片）
    let transcriptPath: String
    /// Claude 自述的这次调用意图（Bash 的 description 字段）
    let intent: String?
    /// 完整内容：Bash 命令原文 / 要写的文件完整路径
    let detail: String
    /// 该会话最近一条用户消息，回答"这是哪个对话"
    let conversationHint: String?
    let createdAt: Date
}
