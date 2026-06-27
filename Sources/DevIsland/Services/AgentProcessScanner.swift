import Foundation

struct AgentProcess {
    let pid: String
    let tty: String   // 形如 ttys012
    let cwd: String
    var startedAt: Date = .distantPast   // 进程启动时间（用于和转录创建时间配对）
}

/// 扫描真正在运行的 AI CLI 进程（claude / codex），拿到它们的 tty 和工作目录。
///
/// 关键：只认 **agent 进程本身**，不是任意 shell。一个目录"有活跃 Claude 会话"
/// 的唯一标准是那里有个 claude 进程在跑——否则只是个普通终端，不该当成会话。
/// 这修正了之前"开着 shell + 有旧转录就误显示"的伪命题。
///
/// 性能：一次 ps + 一次批量 lsof，结果缓存 10 秒。
enum AgentProcessScanner {
    private static let lock = NSLock()
    private static var cached: [AgentProcess] = []
    private static var lastScan = Date.distantPast

    /// 有真实 agent 进程在跑的工作目录集合
    static func runningAgentCwds() -> Set<String> {
        Set(agentProcesses().map(\.cwd))
    }

    /// 找承载某 cwd 的 agent 进程（用于跳转拿 tty）
    static func process(forCwd cwd: String) -> AgentProcess? {
        agentProcesses().first { $0.cwd == cwd }
    }

    /// 命令行是否是一个 agent CLI（claude / codex），排除 GUI app 和我们自己
    private static func isAgentCommand(_ command: String) -> Bool {
        if command.contains(".app/") { return false }       // Claude.app / Codex.app 等 GUI
        if command.contains("DevIsland") || command.contains("mcp") { return false }
        // 取第一个 token 的 basename
        let first = command.split(separator: " ").first.map(String.init) ?? command
        let exe = (first as NSString).lastPathComponent
        return exe == "claude" || exe == "codex"
    }

    static func agentProcesses() -> [AgentProcess] {
        lock.lock()
        defer { lock.unlock() }
        if Date().timeIntervalSince(lastScan) < 10 { return cached }
        lastScan = Date()

        var ttyByPID: [String: String] = [:]
        var startByPID: [String: Date] = [:]
        let now = Date()
        // etime = 已运行时长（[[dd-]hh:]mm:ss），用它反推启动时间
        let psOut = Shell.run("/bin/ps", ["-axo", "pid=,tty=,etime=,command="])
        for line in psOut.split(separator: "\n") {
            let parts = line.drop(while: { $0 == " " })
                .split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard parts.count == 4 else { continue }
            let tty = String(parts[1])
            guard tty.hasPrefix("ttys") else { continue }
            let command = String(parts[3])
            guard isAgentCommand(command) else { continue }   // 只认 claude/codex 进程
            let pid = String(parts[0])
            ttyByPID[pid] = tty
            startByPID[pid] = now.addingTimeInterval(-Self.parseEtime(String(parts[2])))
        }
        guard !ttyByPID.isEmpty else { cached = []; return [] }

        // 一次 lsof 批量查这些 agent 进程的 cwd
        let lsofOut = Shell.run(
            "/usr/sbin/lsof",
            ["-a", "-d", "cwd", "-p", ttyByPID.keys.joined(separator: ","), "-Fn"]
        )
        var result: [AgentProcess] = []
        var currentPID: String?
        for line in lsofOut.split(separator: "\n") {
            if line.hasPrefix("p") {
                currentPID = String(line.dropFirst())
            } else if line.hasPrefix("n"), let pid = currentPID, let tty = ttyByPID[pid] {
                result.append(AgentProcess(pid: pid, tty: tty, cwd: String(line.dropFirst()),
                                           startedAt: startByPID[pid] ?? .distantPast))
            }
        }
        cached = result
        return result
    }

    /// 解析 ps 的 etime（[[dd-]hh:]mm:ss）为秒
    private static func parseEtime(_ s: String) -> TimeInterval {
        var days = 0.0
        var rest = s
        if let dash = rest.firstIndex(of: "-") {
            days = Double(rest[..<dash]) ?? 0
            rest = String(rest[rest.index(after: dash)...])
        }
        let parts = rest.split(separator: ":").map { Double($0) ?? 0 }
        var h = 0.0, m = 0.0, sec = 0.0
        switch parts.count {
        case 3: h = parts[0]; m = parts[1]; sec = parts[2]
        case 2: m = parts[0]; sec = parts[1]
        case 1: sec = parts[0]
        default: break
        }
        return days * 86400 + h * 3600 + m * 60 + sec
    }
}
