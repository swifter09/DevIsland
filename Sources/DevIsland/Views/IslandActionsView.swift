import SwiftUI
import AppKit

/// 岛展开态里的操作区：新建会话 + 项目组批量任务。
/// 原先在菜单栏下拉面板（MenuContentView），随六边形图标移除一并搬到岛上。
struct IslandActionsView: View {
    @ObservedObject private var loc = L10n.shared

    @State private var taskPrompt = ""
    @AppStorage("lastTaskDir") private var taskDir = ""
    @AppStorage("launchTarget") private var launchTargetRaw = TerminalLauncher.Target.ghostty.rawValue

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
            // 注：项目组（批量分发）UI 已下线——它只是"同一指令并行广播到多个独立仓库",
            // 不符合"多仓协作完成一个大需求"的预期,易误导。底层 ManagedSession /
            // launchGroup / ProjectGroupStore 保留,待做成真正的协调式编排再恢复入口。
        }
        .colorScheme(.dark)
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

}
