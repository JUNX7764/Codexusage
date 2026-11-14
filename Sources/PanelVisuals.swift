import AppKit

// 面板显示层的小型绘图原语与图标常量：不依赖主文件业务模型，可独立编译进 fixture。
enum PanelVisuals {
    // 板块标题图标：用量简析保持原有身份，额度周期回顾用独立时钟符号区分。
    static let dailySymbol = "chart.bar.fill"
    static let historySymbol = "clock.arrow.circlepath"

    static let dailyCornerRadius: CGFloat = 1.5

    /// 顶部圆角、底部齐平的柱形路径；半径按宽高收紧，短柱不越界。坐标随调用方（翻转或非翻转）语义。
    static func topRoundedPath(in rect: NSRect, radius: CGFloat) -> NSBezierPath {
        let path = NSBezierPath()
        guard !rect.isEmpty else { return path }
        let r = max(0, min(radius, rect.width / 2, rect.height / 2))
        guard r > 0 else { return NSBezierPath(rect: rect) }
        // “顶部”取 rect 的最小 y 一侧：每日图为翻转视图，最小 y 即视觉顶端； maxY 侧保持直角（基线齐平）。
        path.move(to: NSPoint(x: rect.minX, y: rect.minY + r))
        path.appendArc(withCenter: NSPoint(x: rect.minX + r, y: rect.minY + r),
                       radius: r, startAngle: 180, endAngle: 270)
        path.line(to: NSPoint(x: rect.maxX - r, y: rect.minY))
        path.appendArc(withCenter: NSPoint(x: rect.maxX - r, y: rect.minY + r),
                       radius: r, startAngle: 270, endAngle: 360)
        path.line(to: NSPoint(x: rect.maxX, y: rect.maxY))
        path.line(to: NSPoint(x: rect.minX, y: rect.maxY))
        path.close()
        return path
    }

    /// 每日柱：普通柱仅顶部 1.5pt 圆角；占位线等直角元素继续用 NSRect。
    static func dailyBarPath(in rect: NSRect) -> NSBezierPath {
        topRoundedPath(in: rect, radius: dailyCornerRadius)
    }

    /// 额度周期单根额度槽：一根居中的上限槽，绿色填充按该轮自身上限归一化的已用比例。
    /// column 为该轮可用绘图区（周期图是翻转视图，填充锚定在视觉底部，即 maxY 一侧）。
    /// 0% 不画绿色（不伪造最小面积），100% 填满，非有限值同样不画。
    static func capacityTrack(in column: NSRect, usedPercent: Double) -> (track: NSRect, fill: NSRect?) {
        let width = min(12, max(0, column.width - 4))
        let track = NSRect(x: column.midX - width / 2, y: column.minY, width: width, height: column.height)
        guard usedPercent.isFinite, usedPercent > 0, !track.isEmpty else { return (track, nil) }
        let fraction = CGFloat(min(100, max(0, usedPercent)) / 100)
        let fillHeight = track.height * fraction
        let fill = NSRect(x: track.minX, y: track.maxY - fillHeight, width: track.width, height: fillHeight)
        return (track, fill)
    }
}
