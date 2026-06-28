import SwiftUI
import AppKit
import ServiceManagement

/// macOS「系统设置」风格的设置窗口：左侧分类侧栏 + 右侧分组卡片。
/// 从岛展开态右上角的齿轮打开（SettingsWindowController）。
struct SettingsView: View {
    enum Pane: String, CaseIterable, Identifiable {
        case general, approvals, permissions, about
        var id: String { rawValue }
        var titleKey: String {
            switch self {
            case .general: return "settings.pane.general"
            case .approvals: return "settings.pane.approvals"
            case .permissions: return "settings.pane.permissions"
            case .about: return "settings.pane.about"
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
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        NavigationSplitView {
            List(Pane.allCases, selection: $pane) { p in
                Label {
                    Text(loc.t(p.titleKey)).font(.system(size: 13))
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
            .navigationTitle(loc.t(pane.titleKey))
        }
        .frame(minWidth: 680, minHeight: 460)
    }
}

// MARK: - 各分页

private struct GeneralPane: View {
    @AppStorage("islandAnimDuration") private var animDuration: Double = 0.28
    @AppStorage("launchTarget") private var launchTargetRaw = TerminalLauncher.Target.ghostty.rawValue
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        SettingsSection(loc.t("settings.section.language")) {
            SettingRow(title: loc.t("settings.section.language"), subtitle: loc.t("settings.language.sub")) {
                Picker("", selection: $loc.language) {
                    ForEach(AppLanguage.allCases) { lang in
                        Text(lang.displayName).tag(lang)
                    }
                }
                .labelsHidden().frame(width: 130)
            }
        }

        SettingsSection(loc.t("settings.section.system")) {
            SettingRow(title: loc.t("settings.launchAtLogin"), subtitle: loc.t("settings.launchAtLogin.sub")) {
                Toggle("", isOn: $launchAtLogin)
                    .labelsHidden().toggleStyle(.switch)
                    .onChange(of: launchAtLogin) { _, on in setLaunch(on) }
            }
        }

        SettingsSection(loc.t("settings.section.anim")) {
            SettingRow(title: loc.t("settings.animSpeed"), subtitle: loc.t("settings.animSpeed.sub")) {
                HStack(spacing: 8) {
                    Slider(value: $animDuration, in: 0.12...0.6).frame(width: 160)
                    Text(loc.t(animDuration <= 0.18 ? "settings.anim.fast" : animDuration >= 0.45 ? "settings.anim.slow" : "settings.anim.medium"))
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 28, alignment: .trailing)
                }
            }
        }

        SettingsSection(loc.t("settings.section.newChat")) {
            SettingRow(title: loc.t("settings.defaultTerminal"), subtitle: loc.t("settings.defaultTerminal.sub")) {
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
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        SettingsSection(loc.t("settings.section.approval")) {
            SettingRow(title: loc.t("settings.showApproval"),
                       subtitle: loc.t("settings.showApproval.sub")) {
                Toggle("", isOn: $approvals.gateEnabled)
                    .labelsHidden().toggleStyle(.switch)
            }
            Divider().padding(.leading, 14)
            SettingRow(title: loc.t("settings.approvalTimeout"),
                       subtitle: loc.t("settings.approvalTimeout.sub")) {
                HStack(spacing: 8) {
                    Slider(value: $approvalTimeout, in: 30...600, step: 10).frame(width: 160)
                    Text("\(Int(approvalTimeout))s")
                        .font(.system(size: 11)).foregroundStyle(.secondary)
                        .frame(width: 40, alignment: .trailing)
                }
            }
        }

        SettingsSection(loc.t("settings.section.hotkeys")) {
            SettingRow(title: loc.t("settings.hotkey.allow")) { KeyCap("⌘Y") }
            Divider().padding(.leading, 14)
            SettingRow(title: loc.t("settings.hotkey.deny")) { KeyCap("⌘N") }
        }
    }
}

private struct PermissionsPane: View {
    @State private var trusted = AccessibilityFocuser.isTrusted(promptIfNeeded: false)
    @ObservedObject private var loc = L10n.shared

    var body: some View {
        SettingsSection(loc.t("settings.section.a11y")) {
            SettingRow(title: loc.t("settings.a11y.preciseJump"),
                       subtitle: trusted ? loc.t("settings.a11y.authorized") : loc.t("settings.a11y.notAuthorized")) {
                if trusted {
                    Text(loc.t("settings.a11y.on")).font(.system(size: 12)).foregroundStyle(.green)
                } else {
                    Button(loc.t("settings.a11y.enable")) {
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
    @ObservedObject private var loc = L10n.shared
    var body: some View {
        SettingsSection(loc.t("settings.section.about")) {
            SettingRow(title: "DevIsland", subtitle: loc.t("settings.about.sub")) {
                Text(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
            }
        }

        // 退出兜底：岛上也有 ⏻ 按钮，这里再留一个，万一岛没渲染出来时仍能退出
        SettingsSection(loc.t("settings.section.app")) {
            SettingRow(title: loc.t("settings.quit"), subtitle: loc.t("settings.quit.sub")) {
                Button(loc.t("settings.quit.button")) { NSApp.terminate(nil) }
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
        w.title = L10n.shared.t("settings.windowTitle")
        w.titlebarAppearsTransparent = false
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: SettingsView())
        w.center()
        window = w
        w.makeKeyAndOrderFront(nil)
    }
}
