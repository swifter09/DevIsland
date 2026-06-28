import Foundation
import Combine

/// 一个配额窗口（如 5 小时 / 7 天）
struct QuotaWindow: Equatable {
    let usedPercent: Int
    let resetsAt: Date
    let windowMinutes: Int
    /// 这条配额快照被记录的时间（用于判断新鲜度）
    let capturedAt: Date

    var label: String {
        windowMinutes >= 1440 ? "\(windowMinutes / 1440)d"
            : windowMinutes >= 60 ? "\(windowMinutes / 60)h"
            : "\(windowMinutes)m"
    }
    /// 距重置的倒计时，如 "4h44m" / "3d21h"
    var resetCountdown: String {
        let s = max(0, Int(resetsAt.timeIntervalSinceNow))
        let d = s / 86400, h = (s % 86400) / 3600, m = (s % 3600) / 60
        if d > 0 { return "\(d)d\(h)h" }
        if h > 0 { return "\(h)h\(m)m" }
        return "\(m)m"
    }
    /// 窗口已过快照里的重置点 → 缓存的 used_percent 属于上一个窗口，已失效
    var isExpired: Bool { resetsAt.timeIntervalSinceNow <= 0 }
    /// 快照新鲜度，如 "刚刚" / "8m前" / "3h前"
    var ageText: String {
        let s = max(0, Int(Date().timeIntervalSince(capturedAt)))
        if s < 60 { return "刚刚" }
        if s < 3600 { return "\(s / 60)m前" }
        if s < 86400 { return "\(s / 3600)h前" }
        return "\(s / 86400)d前"
    }
}

/// Claude 的计费/登录模式。
enum ClaudeMode {
    case subscription   // OAuth 订阅（Pro/Max）——有 5h/7d 限额，但本地读不到具体百分比
    case apiKey         // API Key 计费——没有窗口配额概念
    case unknown

    var textKey: String {
        switch self {
        case .subscription: return "quota.mode.subscription"
        case .apiKey: return "quota.mode.apikey"
        case .unknown: return "quota.mode.unknown"
        }
    }
}

/// 配额读取：
/// - Codex：从最近的 codex 会话文件读 rate_limits（5h/7d 用量）。
/// - Claude：5h/7d 限额只在 API 响应头实时返回、本地不存，只能判断登录模式（订阅 / apikey）。
@MainActor
final class QuotaReader: ObservableObject {
    static let shared = QuotaReader()
    @Published private(set) var codexPrimary: QuotaWindow?
    @Published private(set) var codexSecondary: QuotaWindow?
    @Published private(set) var planType: String?
    @Published private(set) var claudeMode: ClaudeMode = .unknown
    /// Claude 今日 token 用量（本地从 transcripts 累计，仅作参考，非官方配额）
    @Published private(set) var claudeTodayTokens: Int = 0

    private var timer: Timer?
    private let sessionsDir = FileManager.default
        .homeDirectoryForCurrentUser.appendingPathComponent(".codex/sessions")

    private init() {}

    func start() {
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { _ in
            Task { @MainActor in QuotaReader.shared.refresh() }
        }
    }

    func refresh() {
        let dir = sessionsDir
        Task.detached(priority: .utility) {
            let result = Self.readLatest(in: dir)
            let mode = Self.detectClaudeMode()
            let claudeTokens = Self.claudeTokensToday()
            await MainActor.run {
                QuotaReader.shared.codexPrimary = result?.primary
                QuotaReader.shared.codexSecondary = result?.secondary
                QuotaReader.shared.planType = result?.plan
                QuotaReader.shared.claudeMode = mode
                QuotaReader.shared.claudeTodayTokens = claudeTokens
            }
        }
    }

    /// 累计今天（本地时区）Claude transcripts 里的 token 用量。
    /// 这里只扫今天改过的文件，逐条 assistant 消息累加 usage 各项。
    nonisolated private static func claudeTokensToday() -> Int {
        let fm = FileManager.default
        let dir = fm.homeDirectoryForCurrentUser.appendingPathComponent(".claude/projects")
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return 0 }
        let startOfDay = Calendar.current.startOfDay(for: Date())
        var total = 0
        for case let u as URL in en where u.pathExtension == "jsonl" {
            guard let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  m >= startOfDay,
                  let handle = try? FileHandle(forReadingFrom: u) else { continue }
            defer { try? handle.close() }
            guard let data = try? handle.readToEnd() else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") where line.contains("\"usage\"") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
                // 只算今天（本地）的消息
                if let ts = obj["timestamp"] as? String, let d = parseISO(ts), d < startOfDay { continue }
                guard let msg = obj["message"] as? [String: Any],
                      let usage = msg["usage"] as? [String: Any] else { continue }
                let inT = usage["input_tokens"] as? Int ?? 0
                let outT = usage["output_tokens"] as? Int ?? 0
                let cc = usage["cache_creation_input_tokens"] as? Int ?? 0
                let cr = usage["cache_read_input_tokens"] as? Int ?? 0
                total += inT + outT + cc + cr
            }
        }
        return total
    }

    /// 判断 Claude 用的是 API Key 还是订阅登录（无法读到具体配额，只能区分模式）。
    /// 启发式：显式配了 API Key（环境变量 / settings.json）→ apikey；否则默认订阅（OAuth 登录）。
    nonisolated private static func detectClaudeMode() -> ClaudeMode {
        if let k = ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"], !k.isEmpty {
            return .apiKey
        }
        let settings = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/settings.json")
        if let data = try? Data(contentsOf: settings),
           let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            if obj["apiKeyHelper"] != nil { return .apiKey }
            if let env = obj["env"] as? [String: Any],
               let k = env["ANTHROPIC_API_KEY"] as? String, !k.isEmpty { return .apiKey }
        }
        return .subscription
    }

    nonisolated private static func readLatest(in dir: URL)
        -> (primary: QuotaWindow?, secondary: QuotaWindow?, plan: String?)? {
        let fm = FileManager.default
        guard let en = fm.enumerator(at: dir, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        // 收集所有 rollout 文件，按修改时间倒序
        var files: [(URL, Date)] = []
        for case let u as URL in en where u.pathExtension == "jsonl" {
            guard let m = try? u.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate else { continue }
            files.append((u, m))
        }
        files.sort { $0.1 > $1.1 }

        // 跨最近若干个文件，挑“记录时间(timestamp)最新”的那条 rate_limits——
        // 单看 mtime 最新的文件可能是被其它原因 touch 的旧会话，未必含最新配额。
        var best: (capturedAt: Date, rl: [String: Any])?
        for (file, _) in files.prefix(12) {
            guard let handle = try? FileHandle(forReadingFrom: file) else { continue }
            defer { try? handle.close() }
            // rate_limits 在事件流里靠后，读尾部 256KB
            let size = (try? handle.seekToEnd()) ?? 0
            let off = size > 262_144 ? size - 262_144 : 0
            try? handle.seek(toOffset: off)
            guard let data = try? handle.readToEnd() else { continue }
            let text = String(decoding: data, as: UTF8.self)
            for line in text.split(separator: "\n") {
                guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                      let rl = Self.findRateLimits(obj) else { continue }
                let cap = (obj["timestamp"] as? String).flatMap(Self.parseISO) ?? .distantPast
                if best == nil || cap > best!.capturedAt { best = (cap, rl) }
            }
        }
        guard let b = best else { return nil }
        let plan = b.rl["plan_type"] as? String
        return (Self.window(b.rl["primary"], capturedAt: b.capturedAt),
                Self.window(b.rl["secondary"], capturedAt: b.capturedAt),
                plan)
    }

    /// 解析 ISO8601 时间戳（兼容带/不带毫秒两种格式）
    nonisolated private static func parseISO(_ s: String) -> Date? {
        let withMs = ISO8601DateFormatter()
        withMs.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withMs.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    nonisolated private static func findRateLimits(_ any: Any) -> [String: Any]? {
        if let d = any as? [String: Any] {
            if let rl = d["rate_limits"] as? [String: Any] { return rl }
            for v in d.values { if let r = findRateLimits(v) { return r } }
        }
        return nil
    }

    nonisolated private static func window(_ any: Any?, capturedAt: Date) -> QuotaWindow? {
        guard let d = any as? [String: Any],
              let pct = d["used_percent"] as? Double,
              let win = d["window_minutes"] as? Int,
              let reset = d["resets_at"] as? TimeInterval else { return nil }
        return QuotaWindow(usedPercent: Int(pct.rounded()),
                           resetsAt: Date(timeIntervalSince1970: reset),
                           windowMinutes: win,
                           capturedAt: capturedAt)
    }
}
