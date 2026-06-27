import AppKit
import SwiftUI

/// 岛在窗口内的实际矩形（"panel" 坐标空间，左上原点）。
/// SwiftUI 侧把岛的 frame 写进来，hitTest 据此让岛之外的点击穿透。
final class IslandHitState {
    static let shared = IslandHitState()
    var islandRect: CGRect = .zero
    weak var panel: NSPanel?

    /// 鼠标当前是否真的落在岛的屏幕矩形内。
    /// 用真实坐标判断，比 SwiftUI 的 .onHover 可靠——后者在展开/收起动画期间会因
    /// 命中区域缩放而误触发 false/true，导致面板反复抖动。
    func mouseIsOverIsland() -> Bool {
        guard let panel else { return false }
        let r = islandRect                       // panel 内坐标，左上原点
        let h = panel.frame.height
        let screenRect = CGRect(
            x: panel.frame.minX + r.minX,
            y: panel.frame.minY + (h - r.maxY),  // 翻到左下原点的屏幕坐标
            width: r.width, height: r.height
        )
        return screenRect.contains(NSEvent.mouseLocation)
    }
}

/// 只有命中岛本体才拦截鼠标，其余透明区域点击穿透到下方应用。
private final class PassthroughHostingView<Content: View>: NSHostingView<Content> {
    override func hitTest(_ point: NSPoint) -> NSView? {
        // point 是 AppKit 坐标（左下原点）；转成左上原点和 SwiftUI 的 frame 比较
        let topLeft = CGPoint(x: point.x, y: bounds.height - point.y)
        guard IslandHitState.shared.islandRect.contains(topLeft) else { return nil }
        return super.hitTest(point)
    }
}

/// 贴在屏幕顶部的固定透明画布。窗口本身不缩放——岛在画布内自己做展开/收起动画，
/// 这样动画完全由 SwiftUI 驱动、丝滑，不再有"窗口缩放和内容不同步"的卡顿。
final class NotchPanel: NSPanel {
    init<Content: View>(content: Content) {
        super.init(
            contentRect: NSRect(x: 0, y: 0, width: 1, height: 1),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        backgroundColor = .clear
        isOpaque = false
        hasShadow = false        // 阴影交给 SwiftUI 的岛形状，窗口本身不画
        hidesOnDeactivate = false
        acceptsMouseMovedEvents = true

        let hosting = PassthroughHostingView(rootView: content)
        hosting.layer?.backgroundColor = NSColor.clear.cgColor
        contentView = hosting

        IslandHitState.shared.panel = self
    }

    func show() {
        positionAtTop()
        orderFrontRegardless()
    }

    /// 固定画布：宽度取屏宽、高度给足展开所需，顶边与屏幕顶齐平、水平居中
    private func positionAtTop() {
        guard let screen = NSScreen.main else { return }
        let width = min(screen.frame.width, 900)
        let height: CGFloat = 760
        let x = screen.frame.midX - width / 2
        let y = screen.frame.maxY - height   // 顶边贴屏幕最顶
        setFrame(NSRect(x: x, y: y, width: width, height: height), display: true)
    }

    // 必须能成为 key window：操作区（IslandActionsView）里的 TextField / Picker / Button
    // 等 AppKit 控件只有在 key window 中才会响应点击与键盘输入。
    // 因为是 .nonactivatingPanel，成为 key 只接管键盘焦点，不会把整个 App 切到前台、
    // 不抢占终端的“活跃应用”状态。
    override var canBecomeKey: Bool { true }
}
