import SwiftUI

/// 动态岛/刘海形状：顶边与屏幕齐平、两上角向外凹出"肩部"圆弧（像真刘海），
/// 下边两角正常外圆角。
struct NotchShape: Shape {
    var shoulder: CGFloat = 10   // 顶部外凹肩部半径
    var bottom: CGFloat = 20     // 底部圆角半径

    func path(in rect: CGRect) -> Path {
        var p = Path()
        let s = min(shoulder, rect.height / 2)
        let b = min(bottom, (rect.width - 2 * s) / 2, rect.height - s)

        // 顶左：屏幕顶边的点
        p.move(to: CGPoint(x: rect.minX, y: rect.minY))
        // 左肩：从顶边凹向内下方（控制点在顶边内侧，形成外凹）
        p.addQuadCurve(to: CGPoint(x: rect.minX + s, y: rect.minY + s),
                       control: CGPoint(x: rect.minX + s, y: rect.minY))
        // 左侧向下
        p.addLine(to: CGPoint(x: rect.minX + s, y: rect.maxY - b))
        // 左下外圆角
        p.addQuadCurve(to: CGPoint(x: rect.minX + s + b, y: rect.maxY),
                       control: CGPoint(x: rect.minX + s, y: rect.maxY))
        // 底边
        p.addLine(to: CGPoint(x: rect.maxX - s - b, y: rect.maxY))
        // 右下外圆角
        p.addQuadCurve(to: CGPoint(x: rect.maxX - s, y: rect.maxY - b),
                       control: CGPoint(x: rect.maxX - s, y: rect.maxY))
        // 右侧向上
        p.addLine(to: CGPoint(x: rect.maxX - s, y: rect.minY + s))
        // 右肩：凹回顶边
        p.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                       control: CGPoint(x: rect.maxX - s, y: rect.minY))
        // 顶边（回到起点）
        p.closeSubpath()
        return p
    }
}
