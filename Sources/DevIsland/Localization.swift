import SwiftUI

/// 应用语言。默认英文,用户可在设置里切到中文,运行时实时生效(无需重启)。
enum AppLanguage: String, CaseIterable, Identifiable {
    case english = "en"
    case chinese = "zh"
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .english: return "English"
        case .chinese: return "中文"
        }
    }
}

/// 运行时本地化中心。SwiftUI 视图持有 `@ObservedObject var loc = L10n.shared`,
/// 调用 `loc.t("key")`;切换语言时 @Published 触发全局重渲染。
/// 不用 Apple 标准 .strings 是因为那个跟随系统语言、切换需重启,满足不了"设置里实时切换"。
@MainActor
final class L10n: ObservableObject {
    static let shared = L10n()

    @Published var language: AppLanguage {
        didSet { UserDefaults.standard.set(language.rawValue, forKey: "appLanguage") }
    }

    private init() {
        let saved = UserDefaults.standard.string(forKey: "appLanguage")
        language = saved.flatMap(AppLanguage.init(rawValue:)) ?? .english   // 默认英文
    }

    /// 取当前语言下 key 对应的文案;缺失时回退英文、再回退 key 本身。
    func t(_ key: String) -> String {
        guard let e = Self.table[key] else { return key }
        switch language {
        case .english: return e.en
        case .chinese: return e.zh
        }
    }

    /// 带格式参数的便捷封装,如 t("island.sessions", count)
    func t(_ key: String, _ args: CVarArg...) -> String {
        String(format: t(key), arguments: args)
    }

    private struct Entry { let en: String; let zh: String }
    private static func e(_ en: String, _ zh: String) -> Entry { Entry(en: en, zh: zh) }

    private static let table: [String: Entry] = [
        // —— 通用 ——
        "common.submit":       e("Submit", "提交"),
        "common.allow":        e("Allow", "允许"),
        "common.alwaysAllow":  e("Always allow", "总是允许"),
        "common.deny":         e("Deny", "拒绝"),

        // —— 岛:收起态 / 头部 ——
        "island.pending":      e("%d pending", "%d 待批准"),
        "island.sessions":     e("%d sessions", "%d 会话"),
        "island.active":       e("· %d active", "· %d 活跃"),
        "island.idle":         e("Idle", "空闲"),
        "island.noSessions":   e("No AI sessions running", "没有正在运行的 AI 会话"),

        // —— 配额栏 ——
        "quota.none":          e("No quota (apikey / no data)", "无配额(apikey/无数据)"),
        "quota.today":         e("Today %@", "今日 %@"),
        "quota.hidden":        e("Limits hidden ↗", "限额不可见 ↗"),
        "quota.help":          e("Subscription mode: click to open the claude.ai usage page for official 5h/7d quota (not readable locally); today's tokens are a local tally, for reference only.",
                                  "订阅模式:点击打开 claude.ai 用量页看官方 5h/7d 配额(本地不可读);今日 token 为本地累计,仅参考"),

        // —— 头部按钮 tooltip ——
        "action.newHelp":      e("New session / project group", "新建会话 / 项目组"),
        "action.historyHelp":  e("History", "历史对话"),
        "action.settingsHelp": e("Settings", "设置"),
        "action.quitHelp":     e("Quit DevIsland", "退出 DevIsland"),
        "board.openHelp":      e("Open project board", "打开项目看板"),

        // —— 会话行 / 详情 ——
        "tool.askQuestion":    e("Question", "提问"),
        "session.unparseable": e("(Can't parse this session's conversation)", "(无法解析此会话的对话内容)"),
        "session.jumpTerminal": e("Jump to terminal", "跳转到终端"),
        "session.activate":    e("Activate %@", "唤起 %@"),
        "managed.title":       e("Managed tasks", "受管任务"),
        "managed.cancel":      e("Cancel task", "取消任务"),

        // —— 会话状态 ——
        "status.running":      e("Running", "运行中"),
        "status.asking":       e("Asking", "在提问"),
        "status.replied":      e("Replied", "已回复"),

        // —— 设置:节标题 ——
        "settings.section.system":   e("System", "系统"),
        "settings.section.anim":     e("Expand / Animation", "展开 / 动画"),
        "settings.section.newChat":  e("New session", "新建会话"),
        "settings.section.approval": e("Island approval", "岛上批准"),
        "settings.section.hotkeys":  e("Shortcuts", "快捷键"),
        "settings.section.a11y":     e("Accessibility", "辅助功能"),
        "settings.section.about":    e("About", "关于"),
        "settings.section.app":      e("Application", "应用"),
        "settings.section.language": e("Language", "语言"),

        // —— 设置:行 ——
        "settings.launchAtLogin":         e("Launch at login", "开机自启动"),
        "settings.launchAtLogin.sub":     e("Start DevIsland automatically on login", "登录时自动启动 DevIsland"),
        "settings.animSpeed":             e("Animation speed", "动画速度"),
        "settings.animSpeed.sub":         e("Duration of island expand/collapse", "岛展开/收起的时长"),
        "settings.anim.fast":             e("Fast", "快"),
        "settings.anim.slow":             e("Slow", "慢"),
        "settings.anim.medium":           e("Medium", "适中"),
        "settings.defaultTerminal":       e("Default terminal", "默认终端"),
        "settings.defaultTerminal.sub":   e("Which terminal \"Open terminal\" launches", "「开终端」用哪个终端启动会话"),
        "settings.showApproval":          e("Show permission prompts on the island", "在岛上显示权限确认"),
        "settings.approvalTimeout":       e("Approval timeout", "审批超时"),
        "settings.hotkey.allow":          e("Allow current request", "允许当前请求"),
        "settings.hotkey.deny":           e("Deny current request", "拒绝当前请求"),
        "settings.a11y.preciseJump":      e("Precise jump to window", "精确跳转到窗口"),
        "settings.a11y.authorized":       e("Authorized", "已授权"),
        "settings.a11y.on":               e("On", "已开启"),
        "settings.a11y.notAuthorized":    e("Not authorized — enable on the right to precisely activate the matching terminal window", "未授权——点右侧开启后才能精确激活对应终端窗口"),
        "settings.a11y.enable":           e("Enable", "开启"),
        "settings.about.sub":             e("Top dynamic island · AI session monitoring & approval", "顶部动态岛 · AI 会话监控与批准"),
        "settings.quit":                  e("Quit DevIsland", "退出 DevIsland"),
        "settings.quit.sub":              e("Fully close the app (island + background monitoring)", "完全关闭 App(含顶部悬浮岛与后台监控)"),
        "settings.language.sub":          e("Interface language", "界面语言"),
        "settings.pane.general":          e("General", "通用"),
        "settings.pane.approvals":        e("Approvals", "审批"),
        "settings.pane.permissions":      e("Permissions", "权限"),
        "settings.pane.about":            e("About", "关于"),
        "settings.windowTitle":           e("DevIsland Settings", "DevIsland 设置"),
        "settings.showApproval.sub":      e("When on, Claude/Codex permission requests pop to the island", "开启后,Claude/Codex 的权限请求会弹到岛上批准"),
        "settings.approvalTimeout.sub":   e("Auto-dismiss the card if not allowed/denied within this time", "超过这个时长没点允许/拒绝就自动撤掉卡片"),
        "settings.quit.button":           e("Quit", "退出"),

        // —— 新建会话 / 项目组 ——
        "actions.newSession":    e("New session", "新建会话"),
        "actions.noDir":         e("No directory", "未选目录"),
        "actions.projectGroup":  e("Project group (batch tasks)", "项目组(批量任务)"),
        "actions.noGroups":      e("No project groups yet — tap \"New group\" to pick repo dirs", "还没有项目组——点「新建组」选多个仓库目录"),

        // —— 历史 ——
        "history.rescan":        e("Rescan", "重新扫描"),
        "history.noTitle":       e("(Untitled session)", "(无标题会话)"),
        "history.noText":        e("No displayable text messages in this transcript", "这段转录里没有可显示的文本消息"),
        "history.resume":        e("Resume in terminal", "在终端恢复"),
        "history.resume.help":   e("cd to the original dir and run claude --resume", "cd 到原目录并执行 claude --resume"),
        "history.revealFinder":  e("Reveal in Finder", "在访达中显示"),
    ]
}
