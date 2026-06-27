import SwiftUI

/// 8×8 像素小人跑步动画，代码直绘无需图片资源。
/// 运行中的会话用它代替静态状态点。
struct PixelRunnerView: View {
    var color: Color = .green
    var pixelSize: CGFloat = 2

    /// 跑步循环：迈步 → 收腿 → 反向迈步 → 收腿
    private static let f0 = [
        "..XX....",
        "..XX....",
        "..XX....",
        ".XXXX...",
        "X..X....",
        "..XX....",
        ".X..X...",
        "X....X..",
    ]
    private static let f1 = [
        "..XX....",
        "..XX....",
        "..XX....",
        "..XXX...",
        "..XX....",
        "..XX....",
        "..XX....",
        "..X.X...",
    ]
    private static let f2 = [
        "..XX....",
        "..XX....",
        "..XX....",
        ".XXXX...",
        "...XX...",
        "..XX....",
        "..X.X...",
        ".X...X..",
    ]
    private static let frames = [f0, f1, f2, f1]

    var body: some View {
        TimelineView(.periodic(from: .now, by: 0.18)) { context in
            let index = Int(context.date.timeIntervalSinceReferenceDate / 0.18)
                % Self.frames.count
            Canvas { ctx, _ in
                for (y, row) in Self.frames[index].enumerated() {
                    for (x, ch) in row.enumerated() where ch == "X" {
                        ctx.fill(
                            Path(CGRect(
                                x: CGFloat(x) * pixelSize,
                                y: CGFloat(y) * pixelSize,
                                width: pixelSize,
                                height: pixelSize
                            )),
                            with: .color(color)
                        )
                    }
                }
            }
            .frame(width: pixelSize * 8, height: pixelSize * 8)
        }
    }
}
