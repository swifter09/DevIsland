import Foundation

/// 一次性抓取的进程表，用于在内存里顺 ppid 链向上走，
/// 避免对每个父进程都单独 fork 一次 ps。
struct ProcessTree {
    struct Node { let ppid: String; let command: String }
    let nodes: [String: Node]

    static func snapshot() -> ProcessTree {
        var map: [String: Node] = [:]
        let out = Shell.run("/bin/ps", ["-axo", "pid=,ppid=,command="])
        for line in out.split(separator: "\n") {
            let trimmed = line.drop(while: { $0 == " " })
            let parts = trimmed.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard parts.count == 3 else { continue }
            map[String(parts[0])] = Node(ppid: String(parts[1]), command: String(parts[2]))
        }
        return ProcessTree(nodes: map)
    }

    /// 顺着 ppid 链向上找承载该进程的 GUI 终端。
    /// 返回终端类型 + 该 GUI App 主进程的 pid（用于激活）。
    func findTerminal(fromPID pid: String) -> (kind: TerminalKind, guiPID: String)? {
        var current = pid
        var sawMultiplexer = false
        for _ in 0..<24 { // 防御性上限，避免坏数据成环
            guard let node = nodes[current] else { return nil }
            if let kind = TerminalKind.match(command: node.command) {
                if kind.isMultiplexer {
                    // zellij/tmux 等复用器没有自己的窗口，记下后继续往上找真正的 GUI 终端
                    sawMultiplexer = true
                } else {
                    return (sawMultiplexer ? .multiplexer(host: kind) : kind, current)
                }
            }
            let ppid = node.ppid
            if ppid == "0" || ppid == "1" || ppid == current { return nil }
            current = ppid
        }
        return nil
    }
}

/// DevIsland 认识的终端类型
enum TerminalKind: Equatable {
    case terminalApp, iterm2, ghostty, warp, wezterm, kitty, vscode, cursor
    indirect case multiplexer(host: TerminalKind) // 复用器里的会话，host 是外层 GUI 终端

    /// 把进程命令行匹配成终端类型；非终端返回 nil
    static func match(command c: String) -> TerminalKind? {
        if c.contains("Terminal.app/Contents/MacOS/Terminal") { return .terminalApp }
        if c.contains("iTerm.app/") || c.contains("/iTerm2") { return .iterm2 }
        if c.contains("Ghostty.app/") { return .ghostty }
        if c.contains("Warp.app/") { return .warp }
        if c.contains("wezterm-gui") || c.contains("WezTerm.app/") { return .wezterm }
        if c.contains("kitty.app/Contents/MacOS/kitty") || c.hasPrefix("kitty") { return .kitty }
        if c.contains("Visual Studio Code.app/") || c.contains("Code Helper") { return .vscode }
        if c.contains("Cursor.app/") || c.contains("Cursor Helper") { return .cursor }
        if c.hasPrefix("zellij") || c.contains("/zellij") || c == "tmux" || c.hasPrefix("tmux ") {
            return .zellijMarker
        }
        return nil
    }

    /// 复用器内部用的哨兵（match 返回它，findTerminal 据此继续上溯）
    static let zellijMarker = TerminalKind.multiplexer(host: .terminalApp)

    var isMultiplexer: Bool {
        if case .multiplexer = self { return true }
        return false
    }

    /// 用于激活的 App bundle id（多路复用器取其 host）
    var bundleIDs: [String] {
        switch self {
        case .terminalApp: return ["com.apple.Terminal"]
        case .iterm2: return ["com.googlecode.iterm2"]
        case .ghostty: return ["com.mitchellh.ghostty"]
        case .warp: return ["dev.warp.Warp-Stable", "dev.warp.Warp"]
        case .wezterm: return ["com.github.wez.wezterm"]
        case .kitty: return ["net.kovidgoyal.kitty"]
        case .vscode: return ["com.microsoft.VSCode", "com.microsoft.VSCodeInsiders"]
        case .cursor: return ["com.todesktop.230313mzl4w4u92", "com.cursor.Cursor"]
        case .multiplexer(let host): return host.bundleIDs
        }
    }

    var displayName: String {
        switch self {
        case .terminalApp: return "Terminal"
        case .iterm2: return "iTerm2"
        case .ghostty: return "Ghostty"
        case .warp: return "Warp"
        case .wezterm: return "WezTerm"
        case .kitty: return "kitty"
        case .vscode: return "VS Code"
        case .cursor: return "Cursor"
        case .multiplexer(let host): return host.displayName
        }
    }
}
