import Foundation
import Combine
import AppKit

/// 权限批准服务：和 hook 脚本通过 ~/.devisland/ 下的文件通信。
///
/// 协议（与 hooks/devisland-gate.py 对应）：
/// - hook 写入   requests/<id>.request.json   → 这里轮询发现，进入 pending 列表
/// - 用户点按钮 → 这里写入 requests/<id>.response.json {"behavior":"allow"|"deny"}
/// - hook 读到应答，输出决定给 Claude Code，并清理两个文件
/// - gate.on 标记文件 = 网关总开关；alive 心跳文件证明本应用活着
@MainActor
final class ApprovalService: ObservableObject {
    static let shared = ApprovalService()

    @Published private(set) var pending: [PermissionRequest] = []
    @Published var gateEnabled: Bool {
        didSet {
            if gateEnabled {
                FileManager.default.createFile(atPath: gateFlag.path, contents: nil)
            } else {
                try? FileManager.default.removeItem(at: gateFlag)
            }
        }
    }

    private let baseDir = FileManager.default
        .homeDirectoryForCurrentUser
        .appendingPathComponent(".devisland")
    private var requestsDir: URL { baseDir.appendingPathComponent("requests") }
    private var gateFlag: URL { baseDir.appendingPathComponent("gate.on") }
    private var aliveFile: URL { baseDir.appendingPathComponent("alive") }

    private var timer: Timer?
    private var scanCount = 0

    /// 请求超过这个年龄就认为 hook 已超时退出，丢弃。
    /// 用户可在菜单设置里调（AppStorage "approvalTimeout"，秒）；缺省 60s。
    private var staleAge: TimeInterval {
        let v = UserDefaults.standard.double(forKey: "approvalTimeout")
        return v > 0 ? v : 60
    }

    /// 已判定过"是否前台不弹"的请求 id（避免重复评估）
    private var evaluated: Set<String> = []
    /// 判定应展示在岛上的请求 id（前台不弹的会被跳过、不进这里）
    private var shouldShow: Set<String> = []
    /// 已写过应答、等 hook 清理 request 文件的 id。
    /// 期间轮询若仍读到残留的 request.json 不能再加回，否则卡片会「消失→又出现」闪烁。
    private var responded: Set<String> = []
    /// 请求首次见到时其转录的修改时间（用于检测会话是否已在别处推进）
    private var baselineMtime: [String: Date] = [:]

    private init() {
        gateEnabled = FileManager.default.fileExists(atPath: baseDir.appendingPathComponent("gate.on").path)
    }

    func start() {
        try? FileManager.default.createDirectory(at: requestsDir, withIntermediateDirectories: true)
        touchAlive()
        scan()
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { _ in
            Task { @MainActor in
                ApprovalService.shared.tick()
            }
        }
    }

    enum Decision {
        case allow        // 仅放行这一次
        case alwaysAllow  // 放行并加一条会话级 allow 规则，本会话不再询问
        case deny
    }

    func respond(to request: PermissionRequest, decision: Decision) {
        var body: [String: Any]
        switch decision {
        case .allow:
            body = ["behavior": "allow"]
        case .alwaysAllow:
            // 规则内容必须是合法的单行模式，否则 Claude Code 会连同 allow 一起拒收，
            // 导致"总是允许"点了终端毫无反应（而单纯的 allow 正常）
            body = ["behavior": "allow"]
            if let rule = Self.ruleContent(for: request) {
                body["updatedPermissions"] = [[
                    "toolName": request.toolName,
                    "ruleContent": rule,
                    "type": "allow",
                    "destination": "session",
                ]]
            }
        case .deny:
            body = ["behavior": "deny"]
        }
        let url = requestsDir.appendingPathComponent("\(request.id).response.json")
        let data = try? JSONSerialization.data(withJSONObject: body)
        try? data?.write(to: url, options: .atomic)
        responded.insert(request.id)            // 标记已答，扫描时别再加回（防闪烁）
        pending.removeAll { $0.id == request.id }
    }

    /// 就地作答 AskUserQuestion。selections: {问题文本: [选中的选项label]}。
    /// 单选问题回字符串、多选回数组（对齐 Claude Code 期望的 answers 形状）。
    func answer(to request: PermissionRequest, selections: [String: [String]]) {
        var answers: [String: Any] = [:]
        for q in request.questions {
            let sel = selections[q.question] ?? []
            answers[q.question] = q.multiSelect ? sel : (sel.first ?? "")
        }
        let body: [String: Any] = ["answers": answers]
        let url = requestsDir.appendingPathComponent("\(request.id).response.json")
        try? JSONSerialization.data(withJSONObject: body).write(to: url, options: .atomic)
        responded.insert(request.id)            // 标记已答，扫描时别再加回（防卡片闪烁），同 respond()
        pending.removeAll { $0.id == request.id }
    }

    /// 生成合法的会话级 allow 规则内容；不适用则返回 nil（只放行本次）。
    /// Bash 用"命令前缀:*"（贴近终端"不再询问"的措辞），文件工具用路径。
    private static func ruleContent(for request: PermissionRequest) -> String? {
        let firstLine = request.detail
            .components(separatedBy: .newlines).first?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !firstLine.isEmpty else { return nil }
        switch request.toolName {
        case "Bash":
            // 取首段命令（到第一个 shell 操作符为止），加 :* 前缀匹配
            let head = firstLine
                .components(separatedBy: CharacterSet(charactersIn: "|&;>"))
                .first?.trimmingCharacters(in: .whitespaces) ?? firstLine
            return head.isEmpty ? nil : "\(head):*"
        case "Write", "Edit", "NotebookEdit":
            return firstLine
        default:
            return nil
        }
    }

    // MARK: - 内部

    private func tick() {
        scanCount += 1
        if scanCount % 7 == 0 { touchAlive() } // 约 2 秒一次心跳
        // 同步外部对 gate.on 的改动（如命令行手动开关），保持 UI 开关一致
        let fileExists = FileManager.default.fileExists(atPath: gateFlag.path)
        if fileExists != gateEnabled { gateEnabled = fileExists }
        scan()
    }

    /// hook 用心跳文件的修改时间判断本应用是否在运行
    private func touchAlive() {
        try? Data().write(to: aliveFile)
    }

    private func scan() {
        let fm = FileManager.default
        guard let files = try? fm.contentsOfDirectory(
            at: requestsDir,
            includingPropertiesForKeys: nil,
            options: .skipsHiddenFiles
        ) else { return }

        var found: [PermissionRequest] = []
        let now = Date()

        for url in files {
            if url.lastPathComponent.hasSuffix(".response.json") {
                // hook 没来取的孤儿应答（如手动测试），过期清理
                let modified = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(modified) > staleAge {
                    try? fm.removeItem(at: url)
                }
                continue
            }
            guard url.lastPathComponent.hasSuffix(".request.json") else { continue }
            guard let request = Self.parse(url) else {
                // 损坏/解析不了的请求文件：清掉，别让它常驻（之前会泄漏）
                let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(m) > 5 { try? fm.removeItem(at: url) }
                continue
            }
            // 过期清理（撤掉 hook 已退出/被杀留下的孤儿卡片）：
            // - 权限类：hook 45s 内必返回，按创建时间 + staleAge(默认60s) 判定即可。
            // - 问题类：hook 会等用户在岛上作答（最长 5min）并每 3s touch 一次 request 文件，
            //   故改按文件 mtime 判活——停更 >15s 即视为 hook 已死（会话结束/Ctrl+C），撤卡。
            //   若仍用 createdAt+60s，长等待的问题卡会在 60 秒被错误清掉。
            if request.kind == .question {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey])
                    .contentModificationDate) ?? .distantPast
                if now.timeIntervalSince(mtime) > 15 {
                    try? fm.removeItem(at: url)
                    continue
                }
            } else if now.timeIntervalSince(request.createdAt) > staleAge {
                try? fm.removeItem(at: url)
                continue
            }
            // 自动取消：会话若真在等我们的 hook，转录不会再写入；一旦转录推进
            // （在终端答了/会话继续），说明这条请求已在别处解决 → 撤掉岛上卡片。
            // 仅对权限审批生效：AskUserQuestion 是「就地作答」头号功能，必须始终上岛，
            // 否则转录的延迟刷新会误把它当成「已在别处解决」而撤卡。
            if request.kind == .permission, !request.transcriptPath.isEmpty {
                let m = (try? URL(fileURLWithPath: request.transcriptPath)
                    .resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate)
                if let m {
                    if let base = baselineMtime[request.id] {
                        if m.timeIntervalSince(base) > 1.0 {
                            respondSkip(request)
                            try? fm.removeItem(at: url)
                            continue
                        }
                    } else {
                        baselineMtime[request.id] = m
                    }
                }
            }
            // 前台不弹：首次见到的请求先异步判定，触发它的终端/App 若正在前台，
            // 直接交回它处理（写 skip 应答），不上岛。
            // 例外：AskUserQuestion 必须始终上岛——就地作答是头号卖点，而你测试时
            // Claude 正跑在聚焦的终端标签里，前台抑制会必然命中、把问题 skip 回终端 TUI，
            // 岛上只剩会话行那条无选项的 ❓ 文本（正是本 bug 的现象）。
            if !evaluated.contains(request.id) {
                evaluated.insert(request.id)
                if request.kind == .question {
                    shouldShow.insert(request.id)   // 问题类不做前台抑制，始终上岛作答
                } else {
                    evaluateForeground(request)
                }
            }
            if shouldShow.contains(request.id) && !responded.contains(request.id) {
                found.append(request)
            }
        }

        // 清理已消失请求的判定缓存：保留仍存在 .request.json 的 id
        let onDisk: Set<String> = Set(files.compactMap { url in
            let name = url.lastPathComponent
            guard name.hasSuffix(".request.json") else { return nil }
            return String(name.dropLast(".request.json".count))
        })
        evaluated.formIntersection(onDisk)
        shouldShow.formIntersection(onDisk)
        responded.formIntersection(onDisk)      // hook 删掉 request 文件后即可释放
        baselineMtime = baselineMtime.filter { onDisk.contains($0.key) }

        let sorted = found.sorted { $0.createdAt < $1.createdAt }
        if sorted != pending {
            pending = sorted
        }
    }

    /// 前台不弹：仅当"你此刻正看着的那个终端标签"恰好就是发起请求的会话时才跳过
    /// （按 cwd 精确比对当前聚焦终端），否则一律上岛。App 级粗判会把后台标签误伤。
    private func evaluateForeground(_ request: PermissionRequest) {
        if let focused = Self.focusedTerminalCwd(), focused == request.cwd {
            respondSkip(request)              // 正看着它 → 交回终端
        } else {
            shouldShow.insert(request.id)     // 后台/别处 → 上岛显示
        }
    }

    /// 当前前台终端里聚焦标签的工作目录（拿不到返回 nil = 不抑制）
    private static func focusedTerminalCwd() -> String? {
        let front = NSWorkspace.shared.frontmostApplication?.bundleIdentifier
        let script: String
        switch front {
        case "com.mitchellh.ghostty":
            script = "tell application \"Ghostty\" to get working directory of focused terminal of selected tab of front window"
        default:
            return nil   // 其他终端无法可靠取聚焦标签 → 不抑制，宁可上岛
        }
        var err: NSDictionary?
        let r = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue
        return (r?.isEmpty == false) ? r : nil
    }

    /// 写 skip 应答，让 hook 输出空、交回终端自己处理
    private func respondSkip(_ request: PermissionRequest) {
        let url = requestsDir.appendingPathComponent("\(request.id).response.json")
        try? JSONSerialization.data(withJSONObject: ["behavior": "skip"]).write(to: url, options: .atomic)
        responded.insert(request.id)
        pending.removeAll { $0.id == request.id }
    }

    private static func parse(_ url: URL) -> PermissionRequest? {
        guard let data = try? Data(contentsOf: url),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = obj["id"] as? String,
              let toolName = obj["toolName"] as? String
        else { return nil }

        let input = obj["toolInput"] as? [String: Any] ?? [:]
        let kind: PermissionRequest.Kind = (obj["kind"] as? String == "question") ? .question : .permission

        // AskUserQuestion：解析问题与选项
        var questions: [PermissionQuestion] = []
        if kind == .question {
            for q in (input["questions"] as? [[String: Any]] ?? []) {
                let text = q["question"] as? String ?? ""
                let opts = (q["options"] as? [[String: Any]] ?? []).compactMap { $0["label"] as? String }
                questions.append(PermissionQuestion(
                    question: text, options: opts,
                    multiSelect: q["multiSelect"] as? Bool ?? false))
            }
        }

        let detail: String
        var intent: String? = nil
        switch toolName {
        case "Bash":
            detail = input["command"] as? String ?? ""
            intent = input["description"] as? String
        case "Write", "Edit", "NotebookEdit":
            detail = input["file_path"] as? String ?? ""
        case "AskUserQuestion":
            detail = questions.first?.question ?? ""
        default:
            let dump = (try? JSONSerialization.data(withJSONObject: input))
                .flatMap { String(data: $0, encoding: .utf8) } ?? ""
            detail = String(dump.prefix(200))
        }

        var conversationHint: String? = nil
        if let transcriptPath = obj["transcriptPath"] as? String, !transcriptPath.isEmpty {
            conversationHint = TranscriptReader.lastUserPrompt(in: URL(fileURLWithPath: transcriptPath))
        }

        let cwd = obj["cwd"] as? String ?? ""
        let created = (obj["createdAt"] as? TimeInterval).map { Date(timeIntervalSince1970: $0) } ?? Date()

        return PermissionRequest(
            id: id,
            kind: kind,
            questions: questions,
            sessionId: obj["sessionId"] as? String ?? "",
            toolName: toolName,
            projectName: URL(fileURLWithPath: cwd).lastPathComponent,
            cwd: cwd,
            transcriptPath: obj["transcriptPath"] as? String ?? "",
            intent: intent,
            detail: detail,
            conversationHint: conversationHint,
            createdAt: created
        )
    }
}
