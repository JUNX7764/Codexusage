import AppKit

private final class ChartHoverLabel: NSView {
    private let horizontalInset: CGFloat = 8
    private let verticalInset: CGFloat = 6
    private let lineSpacing: CGFloat = 2
    private let dateFont = NSFont.systemFont(ofSize: 10)
    private let valueFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private var date = ""
    private var value = ""
    var stringValue: String { "\(date)\n\(value)" }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setText(date: String, value: String) {
        self.date = date
        self.value = value
        needsDisplay = true
    }

    private func size(of text: String, font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    func fitToContent() {
        let dateSize = size(of: date, font: dateFont)
        let valueSize = size(of: value, font: valueFont)
        frame.size = NSSize(width: ceil(max(dateSize.width, valueSize.width)) + horizontalInset * 2,
                            height: ceil(dateSize.height + valueSize.height + lineSpacing) + verticalInset * 2)
    }

    override func draw(_ dirtyRect: NSRect) {
        let background = NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            return NSColor(calibratedWhite: dark ? 0.20 : 0.92, alpha: 0.96)
        }
        let bubble = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.25, dy: 0.25), xRadius: 6, yRadius: 6)
        background.setFill()
        bubble.fill()
        NSColor.labelColor.withAlphaComponent(0.10).setStroke()
        bubble.lineWidth = 0.5
        bubble.stroke()
        let dateSize = size(of: date, font: dateFont)
        let valueSize = size(of: value, font: valueFont)
        let width = max(0, bounds.width - horizontalInset * 2)
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        (date as NSString).draw(with: NSRect(x: horizontalInset, y: verticalInset, width: width, height: dateSize.height),
            options: [.usesLineFragmentOrigin],
            attributes: [.font: dateFont, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph])
        (value as NSString).draw(with: NSRect(x: horizontalInset, y: verticalInset + dateSize.height + lineSpacing,
            width: width, height: valueSize.height), options: [.usesLineFragmentOrigin],
            attributes: [.font: valueFont, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph])
    }
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
    private let hover = ChartHoverLabel()
    private var orange: NSColor { PanelAccent.codex.color }
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    /// 近 30 个日历日止于今日（官方最大源日期更晚时以其为界）；官方缺今日桶时以与用量情况同口径的本机合并用量补并描边标注未结束。
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
        hover.setText(date: day.0, value: value)
        hover.fitToContent()
        hover.frame.size.width = min(hover.frame.width, bounds.width)
        // Keep the overlay on the opposite side where possible; it does not affect layout or hit testing.
        let selectedX = (CGFloat(index) + 0.5) * bounds.width / CGFloat(days.count)
        hover.frame.origin = NSPoint(x: selectedX < bounds.midX ? bounds.width - hover.frame.width : 0, y: 0)
        hover.isHidden = false
        setAccessibilityValue("\(day.0)，\(value)")
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        guard !days.isEmpty else {
            let text = "暂无每日数据" as NSString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 12),
                .foregroundColor: NSColor.secondaryLabelColor
            ]
            let size = text.size(withAttributes: attrs)
            let x = (bounds.width - size.width) / 2
            let y = (46 - size.height) / 2
            text.draw(at: NSPoint(x: x, y: y), withAttributes: attrs)
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
            let textSize = text.size(withAttributes: attributes)
            let x = min(max(0, CGFloat(index) * width - textSize.width / 2), bounds.width - textSize.width)
            text.draw(at: NSPoint(x: x, y: 49), withAttributes: attributes)
        }
    }
}

final class UsageShareBar: NSView {
    let fraction: Double
    let barColor: NSColor
    init(fraction: Double, color: NSColor = PanelAccent.codex.color) {
        self.fraction = min(1, max(0, fraction))
        self.barColor = color
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: UsageBarMetrics.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        let radius = UsageBarMetrics.cornerRadius
        NSColor.secondaryLabelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: radius, yRadius: radius).fill()
        effectiveAppearance.performAsCurrentDrawingAppearance {
            barColor.setFill()
        }
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height), xRadius: radius, yRadius: radius).fill()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}
