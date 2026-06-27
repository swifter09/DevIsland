import SwiftUI
import AppKit

/// 岛展开态里的操作区：新建会话 + 项目组批量任务。
/// 原先在菜单栏下拉面板（MenuContentView），随六边形图标移除一并搬到岛上。
struct IslandActionsView: View {
    @EnvironmentObject var managed: ManagedSessionStore
    @StateObject private var groups = ProjectGroupStore.shared

    @State private var taskPrompt = ""
    @AppStorage("lastTaskDir") private var taskDir = ""
    @AppStorage("launchTarget") private var launchTargetRaw = TerminalLauncher.Target.ghostty.rawValue

    @State private var groupPrompt = ""
    @AppStorage("lastGroupID") private var selectedGroupID = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            // 新建会话：开一个真终端跑 claude "<首句>"，之后照常被监控
            Text("新建会话")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)

            TextField("开场白，例如：模拟一场前端面试…", text: $taskPrompt, axis: .vertical)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .lineLimit(1...3)

            HStack(spacing: 8) {
                Text(taskDir.isEmpty ? "未选目录" : URL(fileURLWithPath: taskDir).lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Button("选目录") { pickDirectory() }
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
                Button("开终端") {
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
                Text("项目组（批量任务）")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Button("新建组") { createGroupFlow() }
                    .controlSize(.small)
            }

            if groups.groups.isEmpty {
                Text("还没有项目组——点「新建组」选多个仓库目录")
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
            } else {
                Picker("", selection: $selectedGroupID) {
                    ForEach(groups.groups) { g in
                        Text("\(g.name)（\(g.dirs.count) 个目录）").tag(g.id)
                    }
                }
                .labelsHidden()
                .controlSize(.small)

                TextField("给全组的指令，例如：把接口超时改成 30s…", text: $groupPrompt, axis: .vertical)
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
                    Button("并行分发") {
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
        panel.message = "选择任务运行的项目目录"
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
        panel.message = "选择项目组包含的多个仓库目录（可多选）"
        NSApp.activate(ignoringOtherApps: true)
        guard panel.runModal() == .OK, !panel.urls.isEmpty else { return }
        let dirs = panel.urls.map(\.path)

        let alert = NSAlert()
        alert.messageText = "给项目组起个名字"
        alert.informativeText = "包含 \(dirs.count) 个目录"
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 220, height: 24))
        field.stringValue = dirs.count == 1
            ? URL(fileURLWithPath: dirs[0]).lastPathComponent
            : URL(fileURLWithPath: dirs[0]).deletingLastPathComponent().lastPathComponent + " 组"
        alert.accessoryView = field
        alert.addButton(withTitle: "创建")
        alert.addButton(withTitle: "取消")
        if alert.runModal() == .alertFirstButtonReturn {
            let name = field.stringValue.trimmingCharacters(in: .whitespaces)
            groups.add(name: name.isEmpty ? "未命名组" : name, dirs: dirs)
        }
    }
}
