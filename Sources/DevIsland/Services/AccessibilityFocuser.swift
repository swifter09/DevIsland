import AppKit
import ApplicationServices

/// 用辅助功能（Accessibility）API 精确 raise 某个终端窗口。
///
/// 给没有"选标签"脚本接口的终端（Ghostty、Warp 等）兜底：枚举目标 App 的窗口、
/// 按标题匹配出承载该项目的那个窗口并置顶。精确到窗口级（同窗口内多标签
/// AX 不暴露，无法再细分）。需要用户授予辅助功能权限。
@MainActor
enum AccessibilityFocuser {
    /// 是否已获辅助功能授权；needsPrompt 为真时会弹系统授权框。
    /// nonisolated：底层 AXIsProcessTrustedWithOptions 线程安全、无需主线程隔离，
    /// 这样才能在 SwiftUI 的 @State 默认值（nonisolated 上下文）里直接调用——
    /// 否则新版 Swift 工具链会报 "main actor-isolated ... in a synchronous nonisolated context"。
    @discardableResult
    nonisolated static func isTrusted(promptIfNeeded: Bool) -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        return AXIsProcessTrustedWithOptions([key: promptIfNeeded] as CFDictionary)
    }

    /// 在 bundleID 对应的 App 里，raise 标题命中 needles 之一的窗口。
    /// 返回是否成功命中并置顶。
    static func focusWindow(bundleID: String, matching needles: [String]) -> Bool {
        guard isTrusted(promptIfNeeded: false) else { return false }
        guard let app = NSWorkspace.shared.runningApplications
            .first(where: { $0.bundleIdentifier == bundleID }) else { return false }

        let appRef = AXUIElementCreateApplication(app.processIdentifier)
        var windowsValue: CFTypeRef?
        guard AXUIElementCopyAttributeValue(appRef, kAXWindowsAttribute as CFString, &windowsValue) == .success,
              let windows = windowsValue as? [AXUIElement] else { return false }

        let lowered = needles.filter { !$0.isEmpty }.map { $0.lowercased() }
        for window in windows {
            var titleValue: CFTypeRef?
            AXUIElementCopyAttributeValue(window, kAXTitleAttribute as CFString, &titleValue)
            let title = (titleValue as? String ?? "").lowercased()
            guard lowered.contains(where: { title.contains($0) }) else { continue }

            AXUIElementSetAttributeValue(window, kAXMainAttribute as CFString, kCFBooleanTrue)
            AXUIElementPerformAction(window, kAXRaiseAction as CFString)
            app.activate() // macOS 14+ 的无参版；options 形式已废弃且无效
            return true
        }
        return false
    }
}
