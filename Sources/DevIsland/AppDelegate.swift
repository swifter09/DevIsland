import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var islandPanel: NotchPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // 菜单栏应用：不出现在 Dock，也没有主窗口
        NSApp.setActivationPolicy(.accessory)

        let panel = NotchPanel(
            content: IslandView()
                .environmentObject(SessionStore.shared)
                .environmentObject(ApprovalService.shared)
                .environmentObject(ManagedSessionStore.shared)
        )
        panel.show()
        islandPanel = panel

        SessionStore.shared.startMonitoring()
        ApprovalService.shared.start()
        QuotaReader.shared.start()
    }

    func toggleIsland() {
        guard let panel = islandPanel else { return }
        if panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.show()
        }
    }
}
