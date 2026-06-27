import SwiftUI

@main
struct DevIslandApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    // 不再有菜单栏图标：UI 全在顶部悬浮岛上（AppDelegate 创建并常驻）。
    // 纯 accessory App 仍需一个 Scene 才能启动，用空 Settings 占位（无可见窗口）。
    var body: some Scene {
        Settings { EmptyView() }
    }
}
