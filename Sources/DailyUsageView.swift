import AppKit

private final class ChartHoverLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class DailyUsageChart: NSView {
    /// 图元口径：官方日桶 / 官方范围内缺桶（官方客户端按 0 渲染）/ 本机扫描补今日 / 缺失。
    enum Entry { case reported(Double), inferredZero, scanned(Double), missing }
    private let days: [(String, Entry)]
    private let todayKey: String?
    var selectedIndexForPreview: Int? { selection }
    var selectedTextForPreview: String { hover.stringValue }
    var hoverWithinBoundsForPreview: Bool {
        !hover.isHidden && hover.frame.minX >= bounds.minX && hover.frame.maxX <= bounds.maxX
            && hover.frame.minY >= bounds.minY && hover.frame.maxY <= bounds.maxY
            && hover.hitTest(.zero) == nil
    }
    private var selection: Int? { didSet { needsDisplay = true; updateAccessibility() } }
    private let hover = ChartHoverLabel(labelWithString: "")
    private var orange: NSColor { PanelAccent.codex.color }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// 近 30 个日历日止于今日（官方最大源日期更晚时以其为界）；官方缺今日桶时以本机扫描补并描边标注未结束。
    init(snapshot: OfficialUsageSnapshot?, scannedToday: Double? = nil) {
        var entries: [(String, Entry)] = []
        var today: String?
        if let snapshot = snapshot, !snapshot.days.isEmpty {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = .current
            formatter.calendar = Calendar(identifier: .gregorian)
            formatter.dateFormat = "yyyy-MM-dd"
            let calendar = Calendar.current
            let now = Date()
            let todayName = formatter.string(from: now)
            today = todayName
            let end = max(todayName, snapshot.days.keys.max() ?? todayName)
            if let endDate = formatter.date(from: end) {
                for index in (0..<30).reversed() {
                    let day = formatter.string(from: calendar.date(byAdding: .day, value: -index, to: endDate)!)
                    let entry: Entry
                    switch snapshot.day(day) {
                    case .reported(let value): entry = .reported(value)
                    case .inferredZero: entry = .inferredZero
                    case .missing: entry = day == todayName && scannedToday != nil ? .scanned(scannedToday!) : .missing
                    }
                    entries.append((day, entry))
                }
            }
        }
        days = entries
        todayKey = today
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 61).isActive = true
        hover.font = .systemFont(ofSize: 10, weight: .medium)
        hover.backgroundColor = .controlBackgroundColor
        hover.drawsBackground = true
        hover.cell?.lineBreakMode = .byTruncatingTail
        hover.isHidden = true
        addSubview(hover)
        setAccessibilityElement(true)
        setAccessibilityRole(.group)
        setAccessibilityLabel("用量简析图，使用左右方向键查看日期")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        window?.acceptsMouseMovedEvents = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach { removeTrackingArea($0) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) {
        guard !days.isEmpty else { return }
        let x = convert(event.locationInWindow, from: nil).x
        selection = min(days.count - 1, max(0, Int(x / max(1, bounds.width) * CGFloat(days.count))))
    }
    override func mouseExited(with event: NSEvent) { selection = nil }
    override func mouseDown(with event: NSEvent) { window?.makeFirstResponder(self); mouseMoved(with: event) }
    override func mouseDragged(with event: NSEvent) { mouseMoved(with: event) }
    override func keyDown(with event: NSEvent) {
        guard !days.isEmpty else { super.keyDown(with: event); return }
        if event.keyCode == 123 { selection = max(0, (selection ?? days.count) - 1) }
        else if event.keyCode == 124 { selection = min(days.count - 1, (selection ?? -1) + 1) }
        else { super.keyDown(with: event) }
    }
    private func updateAccessibility() {
        guard let index = selection else { hover.isHidden = true; return }
        let day = days[index]
        let value: String
        switch day.1 {
        case .reported(let amount): value = Fmt.tokensAbbr(amount) + " Token" + (day.0 == todayKey ? "（今日未结束）" : "")
        case .scanned(let amount): value = Fmt.tokensAbbr(amount) + " Token（今日未结束）"
        case .inferredZero: value = "0 Token（无活动记录）"
        case .missing: value = "暂无数据"
        }
        let text = "\(day.0) · \(value)"
        hover.stringValue = text
        hover.sizeToFit()
        hover.frame.size.width = min(hover.frame.width, bounds.width)
        // Keep the overlay on the opposite side where possible; it does not affect layout or hit testing.
        let selectedX = (CGFloat(index) + 0.5) * bounds.width / CGFloat(days.count)
        hover.frame.origin = NSPoint(x: selectedX < bounds.midX ? bounds.width - hover.frame.width : 0, y: 0)
        hover.isHidden = false
        setAccessibilityValue(text)
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !days.isEmpty else {
            ("暂无每日数据" as NSString).draw(at: NSPoint(x: 4, y: 17), withAttributes: [.font: NSFont.systemFont(ofSize: 11), .foregroundColor: NSColor.secondaryLabelColor])
            return
        }
        let maxValue = max(1, days.compactMap { item -> Double? in
            switch item.1 { case .reported(let value), .scanned(let value): return value; default: return nil }
        }.max() ?? 1)
        let width = bounds.width / CGFloat(days.count)
        let barWidth = min(6, width)
        let barInset = (width - barWidth) / 2
        for (index, day) in days.enumerated() {
            let x = CGFloat(index) * width
            if index == selection { NSColor.labelColor.withAlphaComponent(0.07).setFill(); NSRect(x: x, y: 0, width: width, height: 46).fill() }
            let dayValue: Double?
            var open = false   // 今日未结束：描边空心柱
            switch day.1 {
            case .reported(let value): dayValue = value
            case .scanned(let value): dayValue = value; open = true
            case .inferredZero: dayValue = 0
            case .missing: dayValue = nil
            }
            if let value = dayValue {
                let minimum: CGFloat = open ? (value == 0 ? 2 : 3) : (value == 0 ? 1 : 2)
                let height = max(minimum, CGFloat(value / maxValue) * 46)
                let bar = NSBezierPath(roundedRect: NSRect(x: x + barInset, y: 46 - height, width: barWidth, height: height), xRadius: 1, yRadius: 1)
                if open {
                    orange.setStroke(); bar.lineWidth = 1; bar.stroke()
                } else {
                    orange.setFill(); bar.fill()
                }
            } else {
                NSColor.tertiaryLabelColor.setFill(); NSRect(x: x + 2, y: 45, width: max(1, width - 4), height: 1).fill()
            }
        }
        let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        for index in [0, 15, 29] where index < days.count {
            let text = String(days[index].0.suffix(5)) as NSString
            let x = min(max(0, CGFloat(index) * width - text.size(withAttributes: attributes).width / 2), bounds.width - text.size(withAttributes: attributes).width)
            text.draw(at: NSPoint(x: x, y: 49), withAttributes: attributes)
        }
    }
}

final class UsageShareBar: NSView {
    let fraction: Double
    init(fraction: Double) {
        self.fraction = min(1, max(0, fraction))
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: UsageBarMetrics.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let radius = UsageBarMetrics.cornerRadius
        NSColor.secondaryLabelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        PanelAccent.codex.color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }
}
