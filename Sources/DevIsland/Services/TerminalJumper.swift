import AppKit

/// 点击会话 → 跳到它所在的终端。按终端类型分派，能力分三档：
/// - Terminal.app / iTerm2：AppleScript 按 tty 精确选中标签页
/// - WezTerm / Kitty：各自 CLI 精确激活 pane/window（需 CLI 在 PATH、Kitty 需开启远程控制）
/// - Ghostty / Warp / VS Code / Cursor：无对外"选标签"接口，精确激活到对应 App
enum TerminalJumper {
    /// 统一入口：GUI 工具会话（Codex Desktop 等）激活其 App；终端 CLI 会话走终端跳转。
    static func jump(session: AgentSession) {
        if let bundleID = session.appBundleID {
            let needles = session.cwd.map { titleNeedles(forCwd: $0) } ?? []
            Task { @MainActor in
                // 先试按窗口标题精确 raise（需辅助功能），失败就激活整个 App
                if !AccessibilityFocuser.focusWindow(bundleID: bundleID, matching: needles) {
                    NSWorkspace.shared.runningApplications
                        .first { $0.bundleIdentifier == bundleID }?
                        .activate()
                }
            }
            return
        }
        jump(toCwd: session.cwd)
    }

    static func jump(toCwd cwd: String?) {
        Task.detached(priority: .userInitiated) {
            guard let cwd,
                  let agent = AgentProcessScanner.process(forCwd: cwd)
            else {
                await MainActor.run { activateFirstRunning(of: nil) }
                return
            }

            let owner = ProcessTree.snapshot().findTerminal(fromPID: agent.pid)
            let kind = owner?.kind

            // 1) CLI 类精确跳转（跑在后台，因为要起子进程）
            var precise = false
            switch kind {
            case .wezterm, .multiplexer(.wezterm):
                precise = WezTermFocuser.focus(tty: agent.tty as String?, cwd: cwd)
            case .kitty, .multiplexer(.kitty):
                precise = KittyFocuser.focus(cwd: cwd, agentPID: agent.pid)
            default:
                break
            }

            let tty = agent.tty
            let didPrecise = precise
            // 窗口标题匹配用的关键词：项目名、完整路径、~ 缩写路径
            let needles = Self.titleNeedles(forCwd: cwd)
            await MainActor.run {
                if didPrecise { return }
                // 2) AppleScript 类精确跳转（必须在主线程）
                switch kind {
                case .terminalApp, .multiplexer(.terminalApp):
                    if AppleScriptFocuser.focusTerminalApp(tty: tty) { return }
                case .iterm2, .multiplexer(.iterm2):
                    if AppleScriptFocuser.focusITerm2(tty: tty) { return }
                case .ghostty, .multiplexer(.ghostty):
                    // Ghostty 的 AppleScript 字典支持按 working directory 精确到分屏终端
                    if AppleScriptFocuser.focusGhostty(cwd: cwd) { return }
                default:
                    break
                }
                // 3) 辅助功能：按窗口标题精确 raise 到对应窗口（Ghostty/Warp/VSCode/Cursor）
                if let kind {
                    for id in kind.bundleIDs {
                        if AccessibilityFocuser.focusWindow(bundleID: id, matching: needles) { return }
                    }
                    // 没授权辅助功能就提示一次（之后用户授予即可精确到窗口）
                    if !AccessibilityFocuser.isTrusted(promptIfNeeded: false) {
                        AccessibilityFocuser.isTrusted(promptIfNeeded: true)
                    }
                }
                // 4) 兜底：激活到正确的 App
                activateFirstRunning(of: kind)
            }
        }
    }

    /// 终端窗口标题里可能出现的、能定位到这个会话的关键词
    private static func titleNeedles(forCwd cwd: String) -> [String] {
        let basename = (cwd as NSString).lastPathComponent
        let home = NSHomeDirectory()
        let tilde = cwd.hasPrefix(home) ? "~" + cwd.dropFirst(home.count) : cwd
        return [basename, cwd, String(tilde)]
    }

    /// 激活指定终端 App；kind 为 nil 时挑一个在跑的已知终端
    @MainActor
    private static func activateFirstRunning(of kind: TerminalKind?) {
        let running = NSWorkspace.shared.runningApplications
        let candidates: [String]
        if let kind {
            candidates = kind.bundleIDs
        } else {
            candidates = ["com.mitchellh.ghostty", "com.googlecode.iterm2", "com.apple.Terminal",
                          "dev.warp.Warp-Stable", "net.kovidgoyal.kitty", "com.github.wez.wezterm"]
        }
        for id in candidates {
            if let app = running.first(where: { $0.bundleIdentifier == id }) {
                // 非激活面板调用 NSRunningApplication.activate 会被系统忽略；
                // 改走 App 自身 AppleScript activate（实测能把 iTerm 等真正拉到前台）。
                app.unhide()
                if AppleScriptFocuser.activateApp(bundleID: id) { return }
                app.activate(options: [.activateAllWindows]) // 退而求其次
                return
            }
        }
    }
}

// MARK: - Terminal.app / iTerm2（AppleScript 按 tty）

@MainActor
enum AppleScriptFocuser {
    static func focusTerminalApp(tty: String) -> Bool {
        let script = """
        tell application "Terminal"
            repeat with w in windows
                repeat with t in tabs of w
                    if tty of t is "/dev/\(tty)" then
                        set selected of t to true
                        set index of w to 1
                        activate
                        return "true"
                    end if
                end repeat
            end repeat
        end tell
        return "false"
        """
        return run(script) == "true"
    }

    static func focusITerm2(tty: String) -> Bool {
        let script = """
        tell application "iTerm2"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with s in sessions of t
                        if tty of s is "/dev/\(tty)" then
                            select s
                            select t
                            select w
                            activate
                            return "true"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "false"
        """
        return run(script) == "true"
    }

    /// Ghostty：遍历 window→tab→terminal(含分屏)，按 working directory 匹配，
    /// 命中后 select tab + focus 终端（focus 会把其窗口带到最前）。
    /// 限制：Ghostty terminal 不暴露 tty，同一 cwd 多会话只能命中第一个。
    static func focusGhostty(cwd: String) -> Bool {
        let escaped = cwd.replacingOccurrences(of: "\"", with: "\\\"")
        let script = """
        tell application "Ghostty"
            repeat with w in windows
                repeat with t in tabs of w
                    repeat with tm in terminals of t
                        if (working directory of tm) is "\(escaped)" then
                            select tab t
                            focus tm
                            activate window w
                            return "true"
                        end if
                    end repeat
                end repeat
            end repeat
        end tell
        return "false"
        """
        return run(script) == "true"
    }

    /// 通过 App 自身 activate（绕过非激活面板"不能抢焦点"的限制，
    /// 比 NSRunningApplication.activate 可靠）。
    static func activateApp(bundleID: String) -> Bool {
        run("tell application id \"\(bundleID)\" to activate") != nil
    }

    private static func run(_ source: String) -> String? {
        var error: NSDictionary?
        let out = NSAppleScript(source: source)?.executeAndReturnError(&error)
        return error == nil ? (out?.stringValue ?? "") : nil
    }
}

// MARK: - WezTerm（wezterm cli）

enum WezTermFocuser {
    /// `wezterm cli list --format json` 列出所有 pane，按 tty/cwd 匹配后 activate-pane
    static func focus(tty: String?, cwd: String) -> Bool {
        guard let wezterm = Shell.which("wezterm") else { return false }
        let json = Shell.run(wezterm, ["cli", "list", "--format", "json"])
        guard let data = json.data(using: .utf8),
              let panes = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }

        let wantTTY = tty.map { "/dev/\($0)" }
        let match = panes.first { pane in
            if let t = wantTTY, pane["tty_name"] as? String == t { return true }
            if let c = pane["cwd"] as? String, c.hasSuffix(cwd) || c.hasSuffix(cwd + "/") { return true }
            return false
        }
        guard let paneID = match?["pane_id"] as? Int else { return false }

        _ = Shell.run(wezterm, ["cli", "activate-pane", "--pane-id", String(paneID)])
        // 激活 App 窗口到前台
        Task { @MainActor in
            NSWorkspace.shared.runningApplications
                .first { $0.bundleIdentifier == "com.github.wez.wezterm" }?
                .activate()
        }
        return true
    }
}

// MARK: - Kitty（kitty @ 远程控制）

enum KittyFocuser {
    /// `kitty @ ls` 找到承载该 cwd/pid 的 window，再 focus-window。
    /// 需要 kitty 开启 allow_remote_control 且能连上 socket。
    static func focus(cwd: String, agentPID: String) -> Bool {
        guard let kitty = Shell.which("kitty") else { return false }
        let json = Shell.run(kitty, ["@", "ls"])
        guard let data = json.data(using: .utf8),
              let osWindows = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]]
        else { return false }

        for osw in osWindows {
            for tab in (osw["tabs"] as? [[String: Any]] ?? []) {
                for win in (tab["windows"] as? [[String: Any]] ?? []) {
                    let procs = win["foreground_processes"] as? [[String: Any]] ?? []
                    let hit = procs.contains { p in
                        (p["cwd"] as? String)?.hasSuffix(cwd) == true
                            || String(describing: p["pid"] ?? "") == agentPID
                    }
                    if hit, let id = win["id"] as? Int {
                        _ = Shell.run(kitty, ["@", "focus-window", "--match", "id:\(id)"])
                        Task { @MainActor in
                            NSWorkspace.shared.runningApplications
                                .first { $0.bundleIdentifier == "net.kovidgoyal.kitty" }?
                                .activate()
                        }
                        return true
                    }
                }
            }
        }
        return false
    }
}
