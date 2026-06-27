import Foundation

enum Shell {
    /// 运行命令并返回 stdout（出错返回空字符串）。
    ///
    /// 注意必须先把管道读空再等进程退出：ps/lsof 等命令的输出可能远超
    /// 管道缓冲区（~64KB），若先 waitUntilExit 再读，子进程会卡在写管道、
    /// 我们卡在等它退出 —— 经典双向死锁，曾让整个监控线程挂死。
    static func run(_ launchPath: String, _ args: [String]) -> String {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: launchPath)
        process.arguments = args
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        guard (try? process.run()) != nil else { return "" }
        // readDataToEndOfFile 会持续读到子进程关闭管道（即退出），不会填满缓冲
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return String(data: data, encoding: .utf8) ?? ""
    }

    /// 在常见安装路径里找可执行文件。
    /// GUI App 不继承登录 shell 的 PATH，所以不能直接靠 PATH 找 wezterm/kitty 等。
    static func which(_ tool: String) -> String? {
        let dirs = [
            "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin",
            "/Applications/WezTerm.app/Contents/MacOS",
            "/Applications/kitty.app/Contents/MacOS",
        ]
        for dir in dirs {
            let path = "\(dir)/\(tool)"
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }
}
