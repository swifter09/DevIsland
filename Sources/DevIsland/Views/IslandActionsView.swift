import SwiftUI
import AppKit

/// 岛展开态里的操作区：新建会话 + 项目组批量任务。
/// 原先在菜单栏下拉面板（MenuContentView），随六边形图标移除一并搬到岛上。
struct IslandActionsView: View {
    @EnvironmentObject var managed: ManagedSessionStore
    @StateObject private var groups = ProjectGroupStore.shared
    @ObservedObject private var loc = L10n.shared

    @State private var taskPrompt = ""
    @AppStorage("lastTaskDir") private var taskDir = ""
    @AppStorage("launchTarget") private var launchTargetRaw = TerminalLauncher.Target.ghostty.rawValue

    @State private var groupPrompt = ""
    @AppStorage("lastGroupID") private var selectedGroupID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 新建会话：开一个真终端跑 claude "<首句>"，之后照常被监控
            Text(loc.t("actions.newSession"))
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField(loc.t("actions.taskPlaceholder"), text: $taskPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...3)

            HStack(spacing: 8) {
                Text(taskDir.isEmpty ? loc.t("actions.noDir") : URL(fileURLWithPath: taskDir).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button(loc.t("actions.chooseDir")) { pickDirectory() }
                    .controlSize(.small)
                Spacer()
                Picker("", selection: $launchTargetRaw) {
                    ForEach(TerminalLauncher.installedTargets()) { t in
                        Text(t.rawValue).tag(t.rawValue)
                    }
                }
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 90)
                Button(loc.t("actions.openTerminal")) {
                    let target = TerminalLauncher.Target(rawValue: launchTargetRaw) ?? .ghostty
                    TerminalLauncher.launch(target: target, cwd: taskDir, prompt: taskPrompt)
                    taskPrompt = ""
                }
                .controlSize(.small)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(taskPrompt.trimmingCharacters(in: .whitespaces).isEmpty || taskDir.isEmpty)
            }

            Divider().overlay(.white.opacity(0.12))

            // 项目组：一条指令并行分发给组里每个目录（headless）
            HStack {
                Text(loc.t("actions.projectGroup"))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button(loc.t("actions.newGroup")) { createGroupFlow() }
                    .controlSize(.small)
            }

            if groups.groups.isEmpty {
                Text(loc.t("actions.noGroups"))
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selectedGroupID) {
                    ForEach(groups.groups) { g in
                        Text(loc.t("actions.groupItem", g.name, g.dirs.count)).tag(g.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)

                TextField(loc.t("actions.groupPlaceholder"), text: $groupPrompt, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12))
                    .lineLimit(1...3)

                HStack(spacing: 8) {
                    if let g = currentGroup {
                        Button(role: .destructive) { groups.remove(g) } label: {
                            Image(systemName: "trash").font(.system(size: 10))
                        }
                        .controlSize(.small)
                    }
                    Spacer()
                    Button(loc.t("actions.distribute")) {
                        if let g = currentGroup {
                            managed.launchGroup(g, prompt: groupPrompt)
                            groupPrompt = ""
                        }
                    }
                    .controlSize(.small)
                    .disabled(groupPrompt.trimmingCharacters(in: .whitespaces).isEmpty || currentGroup == nil)
                }
            }
        }
        .colorScheme(.dark)
    }

    private var currentGroup: ProjectGroup? {
        groups.groups.first { $0.id == selectedGroupID } ?? groups.groups.first
    }

    private func pickDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = loc.t("actions.pickDirMsg")
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url {
            taskDir = url.path
        }
    }

    /// 新建项目组：先多选目录，再起个名字
    private func createGroupFlow() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.message = loc.t("actions.pickGroupMsg")
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let dirs = panel.urls.map(\.path)

        let alert = NSAlert()
        alert.messageText = loc.t("actions.nameGroup")
        alert.informativeText = loc.t("actions.nameGroup.info", dirs.count)
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = dirs.count == 1
            ? URL(fileURLWithPath: dirs[0]).lastPathComponent
            : URL(fileURLWithPath: dirs[0]).deletingLastPathComponent().lastPathComponent + loc.t("actions.groupSuffix")
        alert.accessoryView = field
        alert.addButton(withTitle: loc.t("common.create"))
        alert.addButton(withTitle: loc.t("common.cancel"))
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            groups.add(name: name.isEmpty ? loc.t("actions.unnamedGroup") : name, dirs: dirs)
        }
    }
}
