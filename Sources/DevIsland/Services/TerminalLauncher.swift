import AppKit

/// 开一个真实终端窗口，进入指定目录并运行 `claude "<首句>"` 进入交互会话。
/// 之后这个会话就和别的会话一样被 DevIsland 监控——无需自建多轮输入。
///
/// 只收录"能带命令自动启动"的终端。Warp / VS Code / Cursor 没有命令注入接口
/// （只能开窗口、无法自动跑 claude），故不作为启动目标，仅支持跳转。
enum TerminalLauncher {
    enum Target: String, CaseIterable, Identifiable {
        case ghostty = "Ghostty"
        case iterm2 = "iTerm2"
        case terminalApp = "Terminal"
        case wezterm = "WezTerm"
        case kitty = "kitty"
        case alacritty = "Alacritty"
        var id: String { rawValue }

        /// .app 路径（用于判断是否安装 + open -na 启动）
        var appPath: String {
            switch self {
            case .ghostty: return "/Applications/Ghostty.app"
            case .iterm2: return "/Applications/iTerm.app"
            case .terminalApp: return "/System/Applications/Utilities/Terminal.app"
            case .wezterm: return "/Applications/WezTerm.app"
            case .kitty: return "/Applications/kitty.app"
            case .alacritty: return "/Applications/Alacritty.app"
            }
        }
    }

    static func launch(target: Target, cwd: String, prompt: String) {
        // 用 $(cat 文件) 把首句喂给 claude，避免引号/换行转义问题
        let promptFile = "\(NSTemporaryDirectory())devisland-prompt-\(ProcessInfo.processInfo.globallyUniqueString).txt"
        try? prompt.write(toFile: promptFile, atomically: true, encoding: .utf8)
        runScript(target: target, cwd: cwd,
                  body: "claude \"$(cat \(q(promptFile)))\"\nrm -f \(q(promptFile))")
    }

    /// 在终端里恢复一段历史会话：cd 到原目录后 `claude --resume <sessionID>`。
    /// sessionID 即转录文件名（去掉 .jsonl）。
    static func resume(target: Target, cwd: String, sessionID: String) {
        runScript(target: target, cwd: cwd, body: "claude --resume \(q(sessionID))")
    }

    /// 写一个临时 .command 脚本（cd 到 cwd → 跑 body → 删自身 → 留登录 shell），按终端类型启动。
    private static func runScript(target: Target, cwd: String, body: String) {
        let scriptFile = "\(NSTemporaryDirectory())devisland-launch-\(ProcessInfo.processInfo.globallyUniqueString).command"
        let script = """
        #!/bin/zsh
        cd \(q(cwd))
        \(body)
        rm -f \(q(scriptFile))
        exec zsh -l
        """
        guard (try? script.write(toFile: scriptFile, atomically: true, encoding: .utf8)) != nil else { return }
        _ = Shell.run("/bin/chmod", ["+x", scriptFile])

        // 一律通过 /usr/bin/open 启动（立即返回，不阻塞 UI 线程）
        switch target {
        case .terminalApp:
            _ = Shell.run("/usr/bin/open", ["-a", "Terminal", scriptFile])
        case .iterm2:
            launchITerm(scriptFile: scriptFile)
        case .ghostty:
            // 新实例，-e 运行脚本（脚本自带 shebang + 可执行权限）
            _ = Shell.run("/usr/bin/open", ["-na", target.appPath, "--args", "-e", scriptFile])
        case .wezterm:
            _ = Shell.run("/usr/bin/open",
                          ["-na", target.appPath, "--args", "start", "--cwd", cwd, "--", "/bin/zsh", scriptFile])
        case .kitty:
            _ = Shell.run("/usr/bin/open",
                          ["-na", target.appPath, "--args", "--directory=\(cwd)", "/bin/zsh", scriptFile])
        case .alacritty:
            _ = Shell.run("/usr/bin/open",
                          ["-na", target.appPath, "--args", "--working-directory", cwd, "-e", "/bin/zsh", scriptFile])
        }
    }

    /// iTerm2 用 AppleScript 开新窗口运行脚本（比 open 更可靠）
    private static func launchITerm(scriptFile: String) {
        let osa = """
        tell application "iTerm2"
            create window with default profile command "/bin/zsh \(scriptFile)"
            activate
        end tell
        """
        _ = Shell.run("/usr/bin/osascript", ["-e", osa])
    }

    /// 单引号包裹 + 转义内部单引号，安全用于 shell
    private static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// 已安装、可作为启动目标的终端（菜单只列这些）
    static func installedTargets() -> [Target] {
        Target.allCases.filter { FileManager.default.fileExists(atPath: $0.appPath) }
    }
}
