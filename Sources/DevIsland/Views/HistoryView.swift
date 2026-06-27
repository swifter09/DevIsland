import SwiftUI
import AppKit

/// 历史对话浏览窗口：左侧按项目分组列出所有转录，右侧渲染整段对话，便于复盘。
/// 从菜单栏面板的「历史对话」打开（HistoryWindowController）。
struct HistoryView: View {
    @StateObject private var store = HistoryStore.shared
    @State private var query = ""
    @State private var selectedID: String?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                List(selection: $selectedID) {
                    ForEach(groupedProjects, id: \.self) { project in
                        Section(project) {
                            ForEach(conversations(in: project)) { conv in
                                HistoryRow(conversation: conv).tag(conv.id)
                            }
                        }
                    }
                }
                .listStyle(.sidebar)
            }
            .searchable(text: $query, placement: .sidebar, prompt: "搜索项目 / 标题 / 内容")
            .navigationSplitViewColumnWidth(min: 240, ideal: 280, max: 360)
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        store.reload()
                    } label: {
                        Image(systemName: "arrow.clockwise")
                    }
                    .help("重新扫描")
                    .disabled(store.isLoading)
                }
            }
        } detail: {
            if let id = selectedID,
               let conv = store.conversations.first(where: { $0.id == id }) {
                HistoryDetailView(conversation: conv)
            } else {
                placeholder
            }
        }
        .frame(minWidth: 820, minHeight: 540)
        .onAppear { if store.conversations.isEmpty { store.reload() } }
        .overlay(alignment: .top) {
            if store.isLoading {
                ProgressView().controlSize(.small)
                    .padding(6)
                    .background(.regularMaterial, in: Capsule())
                    .padding(.top, 8)
            }
        }
    }

    private var placeholder: some View {
        VStack(spacing: 10) {
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 40)).foregroundStyle(.secondary)
            Text(store.conversations.isEmpty
                 ? "没有找到历史会话\n（~/.claude/projects 下的转录文件）"
                 : "从左侧选择一段对话")
                .font(.system(size: 13)).foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: 过滤 + 分组

    private var filtered: [HistoryConversation] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return store.conversations }
        return store.conversations.filter {
            $0.projectName.lowercased().contains(q)
            || ($0.title?.lowercased().contains(q) ?? false)
            || ($0.lastUserPrompt?.lowercased().contains(q) ?? false)
        }
    }

    /// 项目名按各自最近活跃时间排序（最近用过的项目排上面）
    private var groupedProjects: [String] {
        var newest: [String: Date] = [:]
        for c in filtered {
            if c.lastActivity > (newest[c.projectName] ?? .distantPast) {
                newest[c.projectName] = c.lastActivity
            }
        }
        return newest.keys.sorted { (newest[$0] ?? .distantPast) > (newest[$1] ?? .distantPast) }
    }

    private func conversations(in project: String) -> [HistoryConversation] {
        filtered.filter { $0.projectName == project }   // 已整体按时间倒序
    }
}

// MARK: - 侧栏行

private struct HistoryRow: View {
    let conversation: HistoryConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(conversation.title ?? conversation.lastUserPrompt ?? "（无标题会话）")
                .font(.system(size: 12, weight: .medium))
                .lineLimit(1)
            HStack(spacing: 6) {
                Text(Self.dateLabel(conversation.lastActivity))
                Text("·")
                Text(Self.sizeLabel(conversation.sizeBytes))
            }
            .font(.system(size: 10))
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    static func dateLabel(_ date: Date) -> String {
        let cal = Calendar.current
        let f = DateFormatter()
        if cal.isDateInToday(date) { f.dateFormat = "今天 HH:mm" }
        else if cal.isDateInYesterday(date) { f.dateFormat = "昨天 HH:mm" }
        else if cal.isDate(date, equalTo: Date(), toGranularity: .year) { f.dateFormat = "M月d日 HH:mm" }
        else { f.dateFormat = "yyyy/M/d" }
        return f.string(from: date)
    }

    static func sizeLabel(_ bytes: Int) -> String {
        if bytes < 1024 { return "\(bytes)B" }
        if bytes < 1024 * 1024 { return "\(bytes / 1024)KB" }
        return String(format: "%.1fMB", Double(bytes) / 1_048_576)
    }
}

// MARK: - 详情：整段对话

struct HistoryDetailView: View {
    let conversation: HistoryConversation
    @State private var messages: [TranscriptMessage] = []
    @State private var loading = true
    @AppStorage("launchTarget") private var launchTargetRaw = TerminalLauncher.Target.ghostty.rawValue

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if loading {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if messages.isEmpty {
                Text("这段转录里没有可显示的文本消息")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 14) {
                        ForEach(messages) { msg in
                            MessageBubble(message: msg)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .id(conversation.id)
        .task(id: conversation.id) { await load() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.title ?? conversation.projectName)
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            HStack(spacing: 8) {
                Label(conversation.projectName, systemImage: "folder")
                if let cwd = conversation.cwd {
                    Text(cwd).lineLimit(1).truncationMode(.middle)
                }
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)

            HStack(spacing: 8) {
                Button {
                    let target = TerminalLauncher.Target(rawValue: launchTargetRaw) ?? .ghostty
                    TerminalLauncher.resume(target: target,
                                            cwd: conversation.cwd ?? "",
                                            sessionID: conversation.sessionID)
                } label: {
                    Label("在终端恢复", systemImage: "play.fill")
                }
                .controlSize(.small)
                .disabled(conversation.cwd == nil)
                .help("cd 到原目录并执行 claude --resume")

                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([conversation.url])
                } label: {
                    Label("在访达中显示", systemImage: "doc.text.magnifyingglass")
                }
                .controlSize(.small)

                Spacer()
                Text("\(messages.count) 条消息")
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }
            .padding(.top, 2)
        }
        .padding(14)
    }

    private func load() async {
        loading = true
        let url = conversation.url
        let msgs = await Task.detached(priority: .userInitiated) {
            TranscriptReader.fullMessages(in: url)
        }.value
        messages = msgs
        loading = false
    }
}

private struct MessageBubble: View {
    let message: TranscriptMessage
    private var isUser: Bool { message.role == .user }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(isUser ? "You" : "Claude")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(isUser ? .cyan : .green)
            Text(message.text)
                .font(.system(size: 12.5))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(10)
                .background(
                    RoundedRectangle(cornerRadius: 9)
                        .fill(isUser ? Color.accentColor.opacity(0.12)
                                     : Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 9)
                        .stroke(.white.opacity(0.06), lineWidth: 1)
                )
        }
    }
}

/// 历史窗口控制器：菜单栏应用按需创建一个窗口。
@MainActor
final class HistoryWindowController {
    static let shared = HistoryWindowController()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        HistoryStore.shared.reload()
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 860, height: 580),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false
        )
        w.title = "历史对话"
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: HistoryView())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
