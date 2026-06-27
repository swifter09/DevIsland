import SwiftUI
import AppKit
import ServiceManagement

/// macOS「系统设置」风格的设置窗口：左侧分类侧栏 + 右侧分组卡片。
/// 从岛展开态右上角的齿轮打开（SettingsWindowController）。
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, approvals, permissions, about
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "通用"
            case .approvals: return "审批"
            case .permissions: return "权限"
            case .about: return "关于"
            }
        }
        var icon: String {
            switch self {
            case .general: return "gearshape.fill"
            case .approvals: return "checkmark.shield.fill"
            case .permissions: return "lock.fill"
            case .about: return "info.circle.fill"
            }
        }
        var tint: Color {
            switch self {
            case .general: return .gray
            case .approvals: return .green
            case .permissions: return .orange
            case .about: return .blue
            }
        }
    }

    @State private var pane: Pane = .general

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label {
                    Text(p.title).font(.system(size: 13))
                } icon: {
                    Image(systemName: p.icon)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(RoundedRectangle(cornerRadius: 6).fill(p.tint))
                }
                .tag(p)
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(190)
        } detail: {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    switch pane {
                    case .general: GeneralPane()
                    case .approvals: ApprovalsPane()
                    case .permissions: PermissionsPane()
                    case .about: AboutPane()
                    }
                }
                .padding(24)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .navigationTitle(pane.title)
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

// MARK: - 各分页

private struct GeneralPane: View {
    @AppStorage("islandAnimDuration") private var animDuration: Double = 0.28
    @AppStorage("launchTarget") private var launchTargetRaw = TerminalLauncher.Target.ghostty.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled

    var body: some View {
        SettingsSection("系统") {
            SettingRow(title: "开机自启动", subtitle: "登录时自动启动 DevIsland") {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in setLaunch(on) }
            }
        }

        SettingsSection("展开 / 动画") {
            SettingRow(title: "动画速度", subtitle: "岛展开/收起的时长") {
                HStack(spacing: 8) {
                    Slider(value: $animDuration, in: 0.12...0.6).frame(width: 160)
                    Text(animDuration <= 0.18 ? "快" : animDuration >= 0.45 ? "慢" : "适中")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }

        SettingsSection("新建会话") {
            SettingRow(title: "默认终端", subtitle: "「开终端」用哪个终端启动会话") {
                Picker("", selection: $launchTargetRaw) {
                    ForEach(TerminalLauncher.installedTargets()) { t in
                        Text(t.rawValue).tag(t.rawValue)
                    }
                }
                .labelsHidden().frame(width: 130)
            }
        }
    }

    private func setLaunch(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() }
            else { try SMAppService.mainApp.unregister() }
        } catch {
            // 失败时回滚开关状态，反映真实情况
            launchAtLogin = SMAppService.mainApp.status == .enabled
        }
    }
}

private struct ApprovalsPane: View {
    @ObservedObject private var approvals = ApprovalService.shared
    @AppStorage("approvalTimeout") private var approvalTimeout: Double = 60

    var body: some View {
        SettingsSection("岛上批准") {
            SettingRow(title: "在岛上显示权限确认",
                       subtitle: "开启后，Claude/Codex 的权限请求会弹到岛上批准") {
                Toggle("", isOn: $approvals.gateEnabled)
                    .labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.leading, 14)
            SettingRow(title: "审批超时",
                       subtitle: "超过这个时长没点允许/拒绝就自动撤掉卡片") {
                HStack(spacing: 8) {
                    Slider(value: $approvalTimeout, in: 30...600, step: 10).frame(width: 160)
                    Text("\(Int(approvalTimeout))s")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }

        SettingsSection("快捷键") {
            SettingRow(title: "允许当前请求") { KeyCap("⌘Y") }
            Divider().padding(.leading, 14)
            SettingRow(title: "拒绝当前请求") { KeyCap("⌘N") }
        }
    }
}

private struct PermissionsPane: View {
    @State private var trusted = AccessibilityFocuser.isTrusted(promptIfNeeded: false)

    var body: some View {
        SettingsSection("辅助功能") {
            SettingRow(title: "精确跳转到窗口",
                       subtitle: trusted ? "已授权" : "未授权——点右侧开启后才能精确激活对应终端窗口") {
                if trusted {
                    Text("已开启").font(.system(size: 12)).foregroundStyle(.green)
                } else {
                    Button("开启") {
                        AccessibilityFocuser.isTrusted(promptIfNeeded: true)
                        NSWorkspace.shared.open(URL(string:
                            "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
                    }
                }
            }
        }
        .onAppear { trusted = AccessibilityFocuser.isTrusted(promptIfNeeded: false) }
    }
}

private struct AboutPane: View {
    var body: some View {
        SettingsSection("关于") {
            SettingRow(title: "DevIsland", subtitle: "顶部动态岛 · AI 会话监控与批准") {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }

        // 退出兜底：岛上也有 ⏻ 按钮，这里再留一个，万一岛没渲染出来时仍能退出
        SettingsSection("应用") {
            SettingRow(title: "退出 DevIsland", subtitle: "完全关闭 App（含顶部悬浮岛与后台监控）") {
                Button("退出") { NSApp.terminate(nil) }
                    .controlSize(.small)
            }
        }
    }
}

// MARK: - 复用组件

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content
    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(title)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.secondary)
            VStack(spacing: 0) { content }
                .background(RoundedRectangle(cornerRadius: 10)
                    .fill(Color(nsColor: .controlBackgroundColor)))
                .overlay(RoundedRectangle(cornerRadius: 10)
                    .stroke(.white.opacity(0.06), lineWidth: 1))
        }
    }
}

private struct SettingRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    @ViewBuilder var trailing: Trailing
    init(title: String, subtitle: String? = nil, @ViewBuilder trailing: () -> Trailing) {
        self.title = title
        self.subtitle = subtitle
        self.trailing = trailing()
    }
    var body: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 13))
                if let subtitle {
                    Text(subtitle).font(.system(size: 11)).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 8)
            trailing
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }
}

private struct KeyCap: View {
    let text: String
    init(_ t: String) { text = t }
    var body: some View {
        Text(text)
            .font(.system(size: 12, weight: .medium, design: .rounded))
            .padding(.horizontal, 8).padding(.vertical, 3)
            .background(RoundedRectangle(cornerRadius: 5).fill(.white.opacity(0.1)))
    }
}

/// 设置窗口控制器：菜单栏应用没有常规窗口，这里按需创建一个。
@MainActor
final class SettingsWindowController {
    static let shared = SettingsWindowController()
    private var window: NSWindow?

    func show() {
        NSApp.activate(ignoringOtherApps: true)
        if let window {
            window.makeKeyAndOrderFront(nil)
            return
        }
        let w = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 720, height: 500),
            styleMask: [.titled, .closable, .miniaturizable],
            backing: .buffered, defer: false
        )
        w.title = "DevIsland 设置"
        w.titlebarAppearsTransparent = false
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
