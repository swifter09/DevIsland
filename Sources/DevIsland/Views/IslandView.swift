import SwiftUI
import AppKit

/// 屏幕顶部的"动态岛"主视图
struct IslandView: View {
    /// 真实菜单栏高度（刘海屏更高，自动适配）
    static var menuBarHeight: CGFloat {
        guard let s = NSScreen.main else { return 24 }
        let h = s.frame.maxY - s.visibleFrame.maxY
        return h > 1 ? h : 24
    }
    @EnvironmentObject var store: SessionStore
    @EnvironmentObject var approvals: ApprovalService
    @EnvironmentObject var managed: ManagedSessionStore
    @ObservedObject private var quota = QuotaReader.shared
    @ObservedObject private var loc = L10n.shared
    @State private var isExpanded = false
    /// 岛展开/收起动画时长（秒），可在设置里调
    @AppStorage("islandAnimDuration") private var animDuration: Double = 0.28
    /// 悬停离开后的延迟收起任务（防抖，避免鼠标连续进出打断动画）
    @State private var collapseTask: Task<Void, Never>?
    /// 是否展开“长期不活动”会话分组（默认折叠）
    @State private var showInactive = false
    /// 是否展开底部操作区（新建会话 / 项目组）
    @State private var showActions = false
    /// 审批响应后的「保持展开」截止时刻，避免响应瞬间面板收起闪烁
    @State private var holdExpandedUntil: Date = .distantPast

    /// 动态岛形状：顶边齐平、上角向外凹肩、下角外圆（像真刘海）
    private var islandShape: NotchShape { NotchShape(shoulder: 11, bottom: 20) }

    var body: some View {
        // 固定画布：岛顶部居中，其余透明区域点击穿透
        VStack(spacing: 0) {
            island
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .coordinateSpace(.named("panel"))
    }

    private var island: some View {
        // compactView 常驻；expandedView 出现时从顶部、由小放大盖住它，消失时反向收回
        ZStack(alignment: .top) {
            compactCapsule
            if isExpanded {
                expandedPanel
                    .transition(.scale(scale: 0.28, anchor: .top).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: animDuration), value: isExpanded)
        // 报告岛矩形供 hitTest 点击穿透
        .background(
            GeometryReader { geo in
                Color.clear
                    .onAppear { IslandHitState.shared.islandRect = geo.frame(in: .named("panel")) }
                    .onChange(of: geo.frame(in: .named("panel"))) { _, r in
                        IslandHitState.shared.islandRect = r
                    }
            }
        )
        .onHover { hovering in
            collapseTask?.cancel()          // 取消上一次待收起，避免连续进出打断动画
            if hovering {
                isExpanded = true           // 已展开时再设 true 是 no-op，不重启动画
            } else {
                collapseTask = Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 250_000_000)
                    if Task.isCancelled { return }
                    // 刚响应过审批 → 处于保护期，先等保护期过再收起，避免「收起→展开→收起」闪烁
                    let extra = holdExpandedUntil.timeIntervalSinceNow
                    if extra > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(extra * 1_000_000_000))
                        if Task.isCancelled { return }
                    }
                    // 用真实鼠标坐标兜底：光标仍在岛上就不收起（.onHover 在动画期间会误报离开）
                    guard !IslandHitState.shared.mouseIsOverIsland() else { return }
                    // 操作区展开时不自动收起（选目录/命名弹窗会让鼠标离开岛）
                    if approvals.pending.isEmpty && !showActions { isExpanded = false }
                }
            }
        }
        .onChange(of: approvals.pending) { _, pending in
            // 任何审批响应后（按钮或快捷键）都进入 0.7s 保护期，期间不收起，消除闪烁
            holdExpandedUntil = Date().addingTimeInterval(0.7)
            if pending.isEmpty {
                HotKeyManager.shared.disable()
            } else {
                isExpanded = true
                HotKeyManager.shared.enable()
            }
        }
        .onAppear {
            // ⌘Y 允许 / ⌘N 拒绝：作用于第一个待批准的「权限」请求（问题类不参与）
            HotKeyManager.shared.onAllow = { [weak approvals] in
                guard let approvals,
                      let r = approvals.pending.first(where: { $0.kind == .permission })
                else { return }
                approvals.respond(to: r, decision: .allow)
            }
            HotKeyManager.shared.onDeny = { [weak approvals] in
                guard let approvals,
                      let r = approvals.pending.first(where: { $0.kind == .permission })
                else { return }
                approvals.respond(to: r, decision: .deny)
            }
            if !approvals.pending.isEmpty { HotKeyManager.shared.enable() }
        }
    }

    /// 收起态胶囊（菜单栏高度，上平下圆）
    private var compactCapsule: some View {
        compactView
            .padding(.horizontal, 24)   // 横向留白，避开刘海肩部曲线，不贴边
            .frame(height: Self.menuBarHeight)
            .background(islandShape.fill(.black))
            .clipShape(islandShape)
            .fixedSize()
    }

    /// 展开态面板
    private var expandedPanel: some View {
        expandedView
            .padding(.horizontal, 16)
            .padding(.vertical, 12)
            .background(islandShape.fill(.black))
            .clipShape(islandShape)
            .shadow(color: .black.opacity(0.35), radius: 12, y: 5)
            .fixedSize()
            .animation(.easeInOut(duration: 0.2), value: store.sessions)
            .animation(.easeInOut(duration: 0.2), value: approvals.pending)
    }

    // MARK: - 收起态：一颗胶囊，显示总览

    private var compactView: some View {
        HStack(spacing: 8) {
            if !approvals.pending.isEmpty {
                Text(loc.t("island.pending", approvals.pending.count))
                    .foregroundStyle(.orange)
            } else if totalCount > 0 {
                Text(loc.t("island.sessions", totalCount))
                    .foregroundStyle(.white)
                if activeCount > 0 {
                    Text(loc.t("island.active", activeCount))
                        .foregroundStyle(.green)
                }
            } else {
                Text(loc.t("island.idle"))
                    .foregroundStyle(.secondary)
            }
            statusDot   // 状态点放末尾
        }
        .font(.system(size: 12, weight: .medium))
    }

    /// 会话总数
    private var totalCount: Int {
        store.sessions.count + managed.sessions.count
    }

    /// 正在活跃（运行中/在提问）的会话数
    private var activeCount: Int {
        let running = store.sessions.filter { $0.status == .running || $0.status == .asking }.count
        return running + managed.runningCount
    }

    // MARK: - 展开态：待批准请求 + （会话详情 或 会话列表）

    private var expandedView: some View {
        VStack(alignment: .leading, spacing: 8) {
            quotaBar
            // 顶部只放「孤儿」请求：问题类，或找不到对应会话行的权限请求（兜底，避免漏掉）。
            // 能匹配到会话的权限请求改为内联到该会话条目下显示。
            ForEach(topApprovals) { request in
                if request.kind == .question {
                    QuestionRowView(request: request) { selections in
                        approvals.answer(to: request, selections: selections)
                    }
                } else {
                    ApprovalRowView(request: request) { decision in
                        approvals.respond(to: request, decision: decision)
                    }
                }
            }
            if !topApprovals.isEmpty {
                Divider().overlay(.white.opacity(0.2))
            }

            // 会话直接内联展示（不再跳转详情页）
            sessionList

            // 底部操作区：点 + 展开新建会话 / 项目组
            if showActions {
                Divider().overlay(.white.opacity(0.2))
                IslandActionsView()
            }
        }
        .frame(width: 520)
    }

    // 顶部配额栏：按 Codex / Claude 两组聚类显示 + 音量 + 设置
    @ViewBuilder
    private var quotaBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "gauge.with.dots.needle.33percent")
                .font(.system(size: 11))
                .foregroundStyle(.cyan)

            // —— Codex 组：真实 5h/7d 用量（来自会话文件快照）——
            HStack(spacing: 5) {
                Text("Codex")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.cyan.opacity(0.9))
                if let p = quota.codexPrimary {
                    quotaSegment(p)
                    if let s = quota.codexSecondary { quotaSegment(s) }
                    Text(ageText(p.capturedAt))   // 快照新鲜度，配额只在 Codex 发起调用时写入，可能滞后
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.7))
                } else {
                    Text(loc.t("quota.none")).font(.system(size: 10)).foregroundStyle(.secondary)
                }
            }

            Divider().frame(height: 11).overlay(.white.opacity(0.18))

            // —— Claude 组：只能区分模式，5h/7d 限额本地读不到 ——
            // 订阅模式下点这组 → 打开 claude.ai 用量页看官方配额
            HStack(spacing: 5) {
                Text("Claude")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.orange.opacity(0.9))
                Text(loc.t(quota.claudeMode.textKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(quota.claudeMode == .subscription ? .green : .secondary)
                if quota.claudeTodayTokens > 0 {
                    // 本地累计的今日 token（仅参考，非官方配额）
                    Text(loc.t("quota.today", fmtTokens(quota.claudeTodayTokens)))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.85))
                } else if quota.claudeMode == .subscription {
                    Text(loc.t("quota.hidden"))
                        .font(.system(size: 9))
                        .foregroundStyle(.secondary.opacity(0.7))
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                guard quota.claudeMode == .subscription,
                      let url = URL(string: "https://claude.ai/settings/usage") else { return }
                NSWorkspace.shared.open(url)
            }
            .help(loc.t("quota.help"))

            Spacer()
            Image(systemName: showActions ? "plus.circle.fill" : "plus.circle")
                .font(.system(size: 13)).foregroundStyle(showActions ? .cyan : .white.opacity(0.7))
                .contentShape(Rectangle())
                .onTapGesture { withAnimation(.easeInOut(duration: 0.18)) { showActions.toggle() } }
                .help(loc.t("action.newHelp"))
            Image(systemName: "clock.arrow.circlepath")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                .contentShape(Rectangle())
                .onTapGesture { HistoryWindowController.shared.show() }
                .help(loc.t("action.historyHelp"))
            Image(systemName: "gearshape.fill")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                .contentShape(Rectangle())
                .onTapGesture { SettingsWindowController.shared.show() }
                .help(loc.t("action.settingsHelp"))
            Image(systemName: "power")
                .font(.system(size: 13)).foregroundStyle(.white.opacity(0.7))
                .contentShape(Rectangle())
                .onTapGesture { NSApp.terminate(nil) }
                .help(loc.t("action.quitHelp"))
        }
        .padding(.bottom, 2)
    }

    /// token 数缩写：1234 → "1.2k"，1_500_000 → "1.5M"
    private func fmtTokens(_ n: Int) -> String {
        if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
        if n >= 1_000 { return String(format: "%.0fk", Double(n) / 1_000) }
        return "\(n)"
    }

    /// 配额快照新鲜度,本地化("刚刚 / 8m前" vs "just now / 8m ago")
    private func ageText(_ capturedAt: Date) -> String {
        let s = max(0, Int(Date().timeIntervalSince(capturedAt)))
        if s < 60 { return loc.t("quota.age.now") }
        if s < 3600 { return loc.t("quota.age.m", s / 60) }
        if s < 86400 { return loc.t("quota.age.h", s / 3600) }
        return loc.t("quota.age.d", s / 86400)
    }

    private func quotaSegment(_ w: QuotaWindow) -> some View {
        HStack(spacing: 3) {
            Text(w.label).font(.system(size: 11, weight: .semibold)).foregroundStyle(.white)
            // 窗口已过重置点 → 缓存值失效，置灰提示「待刷新」，避免误读为实时值
            Text(w.isExpired ? "—" : "\(w.usedPercent)%")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(w.isExpired ? Color.secondary : (w.usedPercent >= 80 ? .orange : .green))
            Text(w.resetCountdown).font(.system(size: 10)).foregroundStyle(.secondary)
        }
        .opacity(w.isExpired ? 0.55 : 1)
    }

    private var sessionList: some View {
        Group {
            // 受管会话按项目组聚合：组任务带组标题 + 聚合进度
            ForEach(Array(managed.grouped().enumerated()), id: \.offset) { _, bucket in
                if let groupName = bucket.name {
                    GroupHeaderView(name: groupName, sessions: bucket.sessions) {
                        managed.removeGroup(named: groupName)
                    }
                }
                ForEach(bucket.sessions) { session in
                    ManagedRowView(session: session)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.leading, bucket.name == nil ? 0 : 10)
                }
            }
            // 活跃会话：正常展开显示；带待批准的会话把审批内联到其条目下
            ForEach(activeSessions) { session in
                sessionRow(session)
                ForEach(inlineApprovals(for: session)) { req in
                    ApprovalRowView(request: req, inline: true) { decision in
                        approvals.respond(to: req, decision: decision)
                    }
                    .padding(.leading, 32)   // 缩进，归属于上方会话
                    .padding(.trailing, 4)
                    .padding(.top, 2)
                }
                if session.id != activeSessions.last?.id || !inactiveSessions.isEmpty {
                    Divider().overlay(.white.opacity(0.12))
                }
            }
            // 长期不活动会话：折叠进一个可展开分组，默认收起
            if !inactiveSessions.isEmpty {
                inactiveHeader
                if showInactive {
                    ForEach(inactiveSessions) { session in
                        sessionRow(session)
                        if session.id != inactiveSessions.last?.id {
                            Divider().overlay(.white.opacity(0.12))
                        }
                    }
                }
            }
            if store.sessions.isEmpty && managed.sessions.isEmpty && approvals.pending.isEmpty {
                Text(loc.t("island.noSessions"))
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .center)
            }
        }
    }

    /// 活跃 = 在提问 或 30 分钟内有活动（与 SessionRowView 内的判断一致）
    private func isActiveSession(_ s: AgentSession) -> Bool {
        s.status == .asking || Date().timeIntervalSince(s.lastActivity) < 1800
    }
    /// 该会话目录下待批准的「权限」请求（问题类不在此内联）
    private func permissionApprovals(forCwd cwd: String?) -> [PermissionRequest] {
        guard let cwd, !cwd.isEmpty else { return [] }
        return approvals.pending.filter { $0.kind == .permission && $0.cwd == cwd }
    }
    private func hasApproval(_ s: AgentSession) -> Bool {
        !permissionApprovals(forCwd: s.cwd).isEmpty
    }
    /// 内联到本行的审批：同一 cwd 可能有多个会话，但每条请求只挂到第一个，避免重复显示
    private func inlineApprovals(for session: AgentSession) -> [PermissionRequest] {
        guard activeSessions.first(where: { $0.cwd == session.cwd })?.id == session.id
        else { return [] }
        return permissionApprovals(forCwd: session.cwd)
    }
    /// 顶部孤儿请求：问题类，或匹配不到任何会话行的权限请求（兜底不丢）
    private var topApprovals: [PermissionRequest] {
        let cwds = Set(store.sessions.compactMap { $0.cwd })
        return approvals.pending.filter { $0.kind == .question || !cwds.contains($0.cwd) }
    }
    // 活跃 + 带审批的会话才展开；带审批的排到最前，确保用户先看到
    private var activeSessions: [AgentSession] {
        let all = store.sessions.filter { isActiveSession($0) || hasApproval($0) }
        return all.filter(hasApproval) + all.filter { !hasApproval($0) }
    }
    private var inactiveSessions: [AgentSession] {
        store.sessions.filter { !isActiveSession($0) && !hasApproval($0) }
    }

    private func sessionRow(_ session: AgentSession) -> some View {
        SessionRowView(session: session)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .onTapGesture {
                TerminalJumper.jump(session: session)   // 点行=跳到终端/App，不再进详情页
            }
    }

    /// “长期不活动”分组的可点击折叠头
    private var inactiveHeader: some View {
        HStack(spacing: 6) {
            Image(systemName: "chevron.right")
                .font(.system(size: 10, weight: .bold))
                .foregroundStyle(.white.opacity(0.7))
                .rotationEffect(.degrees(showInactive ? 90 : 0))
            Text(showInactive ? loc.t("island.collapseInactive")
                              : loc.t("island.expandInactive", inactiveSessions.count))
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white.opacity(0.85))
            Spacer()
        }
        .padding(.vertical, 8)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8).fill(.white.opacity(0.06))
        )
        .contentShape(Rectangle())
        .onTapGesture {
            withAnimation(.easeInOut(duration: 0.18)) { showInactive.toggle() }
        }
    }

    @ViewBuilder
    private var statusDot: some View {
        if hasAttention {
            Circle().fill(.orange).frame(width: 8, height: 8)
        } else if store.runningCount > 0 {
            PixelRunnerView(color: .green, pixelSize: 1.6)
        } else {
            Circle().fill(.gray).frame(width: 8, height: 8)
        }
    }

    private var hasAttention: Bool {
        store.hasAttention || !approvals.pending.isEmpty
    }
}

/// 待批准请求卡片：是哪个项目/对话、Claude 想干什么、完整命令
/// AskUserQuestion 就地作答卡片：显示问题 + 选项按钮，点选即回填到会话
struct QuestionRowView: View {
    let request: PermissionRequest
    let onAnswer: ([String: [String]]) -> Void
    @State private var selections: [String: [String]] = [:]
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "questionmark.bubble.fill")
                    .font(.system(size: 13)).foregroundStyle(.cyan)
                Text(request.projectName)
                    .font(.system(size: 12, weight: .medium)).foregroundStyle(.white)
                Spacer(minLength: 8)
                Text(request.toolName == "AskUserQuestion" ? loc.t("tool.askQuestion") : request.toolName)
                    .font(.system(size: 10)).foregroundStyle(.secondary)
            }

            ForEach(Array(request.questions.enumerated()), id: \.offset) { _, q in
                VStack(alignment: .leading, spacing: 4) {
                    Text(q.question)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white.opacity(0.95))
                    ForEach(q.options, id: \.self) { opt in
                        optionButton(question: q, option: opt)
                    }
                }
            }

            // 多选/多问题：显示提交按钮；单问题单选则点选即提交
            if needsSubmit {
                Text(loc.t("common.submit"))
                    .font(.system(size: 11, weight: .semibold))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(.cyan.opacity(0.25)))
                    .foregroundStyle(.cyan)
                    .contentShape(Capsule())
                    .onTapGesture { onAnswer(selections) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var needsSubmit: Bool {
        request.questions.count > 1 || request.questions.contains { $0.multiSelect }
    }

    private func isSelected(_ q: PermissionQuestion, _ opt: String) -> Bool {
        selections[q.question]?.contains(opt) ?? false
    }

    private func optionButton(question q: PermissionQuestion, option opt: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: isSelected(q, opt)
                ? (q.multiSelect ? "checkmark.square.fill" : "largecircle.fill.circle")
                : (q.multiSelect ? "square" : "circle"))
                .font(.system(size: 11)).foregroundStyle(.cyan)
            Text(opt).font(.system(size: 11)).foregroundStyle(.white.opacity(0.9))
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8).padding(.vertical, 5)
        .background(RoundedRectangle(cornerRadius: 6).fill(.cyan.opacity(isSelected(q, opt) ? 0.2 : 0.08)))
        .contentShape(Rectangle())
        .onTapGesture { tap(q, opt) }
    }

    private func tap(_ q: PermissionQuestion, _ opt: String) {
        if q.multiSelect {
            var cur = selections[q.question] ?? []
            if let i = cur.firstIndex(of: opt) { cur.remove(at: i) } else { cur.append(opt) }
            selections[q.question] = cur
        } else {
            selections[q.question] = [opt]
            if !needsSubmit { onAnswer(selections) }   // 单问题单选：点选即提交
        }
    }
}

struct ApprovalRowView: View {
    let request: PermissionRequest
    /// 内联在会话条目下时为 true：省去重复的「工具 · 项目」大标题
    var inline: Bool = false
    let respond: (ApprovalService.Decision) -> Void
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            // 非内联（顶部孤儿卡片）才显示完整标题；内联时项目名已在会话行上
            if !inline {
                HStack(spacing: 8) {
                    Image(systemName: "exclamationmark.shield.fill")
                        .font(.system(size: 13))
                        .foregroundStyle(.orange)
                    Text("\(request.toolName) · \(request.projectName)")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(.white)
                    Spacer(minLength: 12)
                }
            }

            if let intent = request.intent, !intent.isEmpty {
                Text(intent)
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.85))
            }

            if !request.detail.isEmpty {
                // 命令块：橙色背景 + 工具名标签（如 bash）
                VStack(alignment: .leading, spacing: 4) {
                    Text(request.toolName.lowercased())
                        .font(.system(size: 9, weight: .bold, design: .monospaced))
                        .foregroundStyle(.orange)
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().fill(.orange.opacity(0.22)))
                    Text(request.detail)
                        .font(.system(size: 10, design: .monospaced))
                        .foregroundStyle(.white.opacity(0.85))
                        .lineLimit(4)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(.orange.opacity(0.12))
                )
            }

            // 允许 / 拒绝：左右排列
            HStack(spacing: 8) {
                optionButton(icon: "checkmark.circle.fill", color: .green,
                             text: loc.t("common.allow"), shortcut: "⌘Y", decision: .allow)
                optionButton(icon: "xmark.circle.fill", color: .red,
                             text: loc.t("common.deny"), shortcut: "⌘N", decision: .deny)
            }
        }
        .frame(maxWidth: .infinity)
    }

    /// 用 onTapGesture 而不是 Button：面板不抢键盘焦点（canBecomeKey = false），
    /// 普通 Button 在非 key window 里可能不响应
    private func optionButton(icon: String, color: Color, text: String,
                              shortcut: String, decision: ApprovalService.Decision) -> some View {
        HStack(spacing: 6) {
            Image(systemName: icon)
                .font(.system(size: 11))
                .foregroundStyle(color)
            Text(text)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))
                .lineLimit(1)
            Spacer(minLength: 4)
            Text(shortcut)
                .font(.system(size: 10, weight: .medium, design: .rounded))
                .foregroundStyle(.white.opacity(0.5))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(RoundedRectangle(cornerRadius: 4).fill(.white.opacity(0.1)))
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(color.opacity(0.12))
        )
        .contentShape(Rectangle())
        .onTapGesture { respond(decision) }
    }
}

/// 单个会话行
struct SessionRowView: View {
    let session: AgentSession
    @ObservedObject private var loc = L10n.shared

    private let iconSize: CGFloat = 22
    private let iconGap: CGFloat = 10

    var body: some View {
        // 活跃行多行内容用顶对齐；不活跃单行用居中，图标与标题对齐
        HStack(alignment: isActive ? .top : .center, spacing: iconGap) {
            // 左侧图标：运行中是像素小人，否则静态点
            Group {
                if session.status == .running {
                    PixelRunnerView(color: .green, pixelSize: 2)
                } else {
                    Image(systemName: session.tool.symbolName)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
            .frame(width: iconSize, height: iconSize)
            .padding(.top, isActive ? 1 : 0)

            VStack(alignment: .leading, spacing: 3) {
                // 第一行：文件夹 · 标题   +   工具标签 / 主机标签 / 时间 / 状态点
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(titleText)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.white)
                        .lineLimit(1)
                    Spacer(minLength: 8)
                    // 固定列宽，保证各行标签纵向对齐（左对齐成列）
                    tag(session.tool.shortName, bg: .blue.opacity(0.35), fg: .blue)
                        .frame(width: 52, alignment: .leading)
                    Group {
                        if let host = session.hostName {
                            tag(host, bg: .white.opacity(0.12), fg: .secondary)
                        }
                    }
                    .frame(width: 62, alignment: .leading)
                    Text(relativeTime)
                        .font(.system(size: 10))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, alignment: .trailing)
                    // 看板按钮：仅当 <cwd>/.board/board.html 存在时显示，独立 tap 不触发行跳转
                    if session.hasBoard {
                        Image(systemName: "chart.bar.doc.horizontal")
                            .font(.system(size: 11))
                            .foregroundStyle(.cyan)
                            .contentShape(Rectangle())
                            .onTapGesture { BoardWindowController.shared.show(session: session) }
                            .help(loc.t("board.openHelp"))
                    }
                    Circle().fill(statusColor).frame(width: 7, height: 7)
                }
                .padding(.trailing, 12)   // 右侧留点边距，标签/状态点不贴边

                // 活跃会话才展开内容；长时间不活跃（已回复）的默认收起，只留标题行
                if isActive {
                    // 当前正在执行的动作（让用户看到反应，如 🔧 Bash: npm run build）
                    if let action = session.currentAction {
                        HStack(spacing: 5) {
                            Image(systemName: "wrench.and.screwdriver.fill")
                                .font(.system(size: 9)).foregroundStyle(.orange)
                            Text(action)
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.orange)
                                .lineLimit(1).truncationMode(.middle)
                        }
                    }
                    // 内联最近 3 句对话
                    ForEach(session.recentMessages) { msg in
                        HStack(alignment: .top, spacing: 5) {
                            Text(msg.role == .user ? "You" : "AI")
                                .font(.system(size: 9, weight: .semibold))
                                .foregroundStyle(msg.role == .user ? .cyan : .green)
                                .frame(width: 20, alignment: .leading)
                            Text(msg.text)
                                .font(.system(size: 11))
                                .foregroundStyle(.white.opacity(msg.role == .user ? 0.9 : 0.7))
                                .lineLimit(2)
                        }
                    }
                    if let question = session.pendingQuestion {
                        Text("❓ \(question)")
                            .font(.system(size: 11)).foregroundStyle(.orange).lineLimit(2)
                    }
                }
                // 不活跃会话：只保留标题行（收起），不再显示第二行，行高统一对齐
            }
        }
        .padding(.vertical, isActive ? 5 : 3)
    }

    /// 活跃 = 在提问 或 30 分钟内有活动；否则收起
    private var isActive: Bool {
        session.status == .asking || Date().timeIntervalSince(session.lastActivity) < 1800
    }

    private var titleText: String {
        if let t = session.title { return "\(session.projectName) · \(t)" }
        return session.projectName
    }

    /// 相对时间，如 <1m / 5m / 2h
    private var relativeTime: String {
        let s = Int(Date().timeIntervalSince(session.lastActivity))
        if s < 60 { return "<1m" }
        if s < 3600 { return "\(s / 60)m" }
        return "\(s / 3600)h"
    }

    private func tag(_ text: String, bg: Color, fg: Color) -> some View {
        Text(text)
            .font(.system(size: 10, weight: .medium))
            .padding(.horizontal, 7)
            .padding(.vertical, 2)
            .background(Capsule().fill(bg))
            .foregroundStyle(fg)
            .fixedSize()
    }

    private var statusColor: Color {
        switch session.status {
        case .running: return .green
        case .asking: return .orange
        case .replied: return .blue
        }
    }
}

/// 单个会话的详情页：最近几轮对话 + 跳转终端
struct SessionDetailView: View {
    let session: AgentSession
    let onBack: () -> Void
    @State private var messages: [TranscriptMessage] = []
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 头部：返回 + 项目名 + 状态
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(0.1)))
                    .contentShape(Circle())
                    .onTapGesture { onBack() }

                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(session.tool.rawValue)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)

                Spacer()

                if session.status == .running {
                    PixelRunnerView(color: .green, pixelSize: 2)
                }
                Text(loc.t(session.status.labelKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(session.status == .running ? .green : .secondary)
            }

            if let question = session.pendingQuestion {
                Text("❓ \(question)")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
            }

            Divider().overlay(.white.opacity(0.2))

            // 最近对话
            if messages.isEmpty {
                Text(loc.t("session.unparseable"))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(messages) { message in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: message.role == .user
                                    ? "person.fill" : "sparkle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(message.role == .user ? .cyan : .green)
                                    .frame(width: 14)
                                    .padding(.top, 2)
                                Text(message.text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.white.opacity(message.role == .user ? 0.08 : 0.04))
                            )
                        }
                    }
                }
                .frame(maxHeight: 240)
            }

            // 底部操作：GUI 工具会话激活 App，终端会话跳转终端
            HStack(spacing: 8) {
                Image(systemName: session.appBundleID == nil ? "terminal.fill" : "app.badge")
                    .font(.system(size: 10))
                Text(session.appBundleID == nil ? loc.t("session.jumpTerminal") : loc.t("session.activate", session.tool.rawValue))
                    .font(.system(size: 11, weight: .medium))
                Spacer()
            }
            .foregroundStyle(.cyan)
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6).fill(.cyan.opacity(0.12)))
            .contentShape(Rectangle())
            .onTapGesture {
                TerminalJumper.jump(session: session)
            }
        }
        .onAppear(perform: load)
        .onChange(of: session.lastActivity) { _, _ in load() }
    }

    private func load() {
        messages = TranscriptReader.recentMessages(
            in: URL(fileURLWithPath: session.id)
        )
    }
}

/// 受管任务行（紫色齿轮标识，区别于外部终端会话）
/// 项目组标题 + 聚合进度（N 完成 / M 运行中），右侧可整组清除
struct GroupHeaderView: View {
    let name: String
    let sessions: [ManagedSession]
    let onClear: () -> Void
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        let done = sessions.filter { $0.state == .succeeded }.count
        let failed = sessions.filter { if case .failed = $0.state { return true } else { return false } }.count
        let running = sessions.count - done - failed

        HStack(spacing: 8) {
            Image(systemName: "square.stack.3d.up.fill")
                .font(.system(size: 11))
                .foregroundStyle(.purple)
            Text(name)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
            Spacer(minLength: 8)
            if running > 0 { PixelRunnerView(color: .purple, pixelSize: 2) }
            Text(loc.t("group.progress", done, sessions.count) + (failed > 0 ? loc.t("group.failed", failed) : ""))
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .contentShape(Circle())
                .onTapGesture { onClear() }
        }
        .padding(.top, 2)
    }
}

struct ManagedRowView: View {
    @ObservedObject var session: ManagedSession
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .center, spacing: 10) {
                Image(systemName: "gearshape.2.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.purple)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(.purple.opacity(0.15)))

                Text(session.projectName)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)

                Spacer(minLength: 12)

                if session.state == .running || session.state == .launching {
                    PixelRunnerView(color: .purple, pixelSize: 2)
                }
                Text(loc.t(session.state.labelKey))
                    .font(.system(size: 10, weight: .medium))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(stateColor.opacity(0.2)))
                    .foregroundStyle(stateColor)
                    .fixedSize()
            }

            Text(session.prompt)
                .font(.system(size: 10))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .padding(.leading, 32)
        }
    }

    private var stateColor: Color {
        switch session.state {
        case .launching, .running: return .purple
        case .succeeded: return .blue
        case .failed: return .red
        }
    }
}

/// 受管任务详情：实时消息流 + 取消
struct ManagedDetailView: View {
    @ObservedObject var session: ManagedSession
    let onBack: () -> Void
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "chevron.left")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .background(Circle().fill(.white.opacity(0.1)))
                    .contentShape(Circle())
                    .onTapGesture { onBack() }

                Text(session.projectName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                Text(loc.t("managed.title"))
                    .font(.system(size: 10))
                    .foregroundStyle(.purple)

                Spacer()

                if session.state == .running || session.state == .launching {
                    PixelRunnerView(color: .purple, pixelSize: 2)
                }
                Text(loc.t(session.state.labelKey))
                    .font(.system(size: 10, weight: .medium))
                    .foregroundStyle(.secondary)
            }

            if case .failed(let reason) = session.state {
                Text(reason)
                    .font(.system(size: 10))
                    .foregroundStyle(.red)
                    .lineLimit(2)
            }

            Divider().overlay(.white.opacity(0.2))

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(session.messages) { message in
                            HStack(alignment: .top, spacing: 6) {
                                Image(systemName: message.role == .user
                                    ? "person.fill" : "sparkle")
                                    .font(.system(size: 9))
                                    .foregroundStyle(message.role == .user ? .cyan : .purple)
                                    .frame(width: 14)
                                    .padding(.top, 2)
                                Text(message.text)
                                    .font(.system(size: 11))
                                    .foregroundStyle(.white.opacity(0.85))
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                            .padding(6)
                            .background(
                                RoundedRectangle(cornerRadius: 6)
                                    .fill(.white.opacity(message.role == .user ? 0.08 : 0.04))
                            )
                            .id(message.id)
                        }
                    }
                }
                .frame(maxHeight: 240)
                .onChange(of: session.messages.count) { _, _ in
                    if let last = session.messages.last {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }

            if session.state == .running || session.state == .launching {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 10))
                    Text(loc.t("managed.cancel"))
                        .font(.system(size: 11, weight: .medium))
                    Spacer()
                }
                .foregroundStyle(.red)
                .padding(.horizontal, 8)
                .padding(.vertical, 5)
                .background(RoundedRectangle(cornerRadius: 6).fill(.red.opacity(0.12)))
                .contentShape(Rectangle())
                .onTapGesture { session.cancel() }
            }
        }
    }
}
