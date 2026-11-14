import AppKit

private final class ChartHoverLabel: NSView {
    /// 悬停数值：有 token 数的日桶走数值过渡，「暂无数据」等文本立即到位。
    enum Value {
        case amount(Double, suffix: String)
        case text(String)
    }

    private let horizontalInset: CGFloat = 8
    private let verticalInset: CGFloat = 6
    private let lineSpacing: CGFloat = 2
    private let dateFont = NSFont.systemFont(ofSize: 10)
    private let valueFont = NSFont.systemFont(ofSize: 10, weight: .medium)
    private var date = ""
    private var value = ""
    private var transition = TokenValueTransition()
    private var suffix = ""
    private var plainText: String?
    private var timer: Timer?
    var stringValue: String { "\(date)\n\(value)" }
    override var isFlipped: Bool { true }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    /// 气泡可见且前后都是数值时做 320ms 过渡（从当前显示值重定向）；首次显示/缺数/减少动态效果立即到位。
    func setText(date: String, value: Value, animated: Bool) {
        self.date = date
        stopTimer()
        switch value {
        case .text(let text):
            plainText = text
            transition.set(nil, at: ProcessInfo.processInfo.systemUptime, animated: false)
            suffix = ""
            render()
        case .amount(let amount, let targetSuffix):
            plainText = nil
            let wasVisible = !isHidden && transition.display != nil
            let allowed = animated && wasVisible && window != nil
                && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            transition.set(amount, at: ProcessInfo.processInfo.systemUptime, animated: allowed)
            suffix = targetSuffix
            render()
            if transition.isAnimating { startTimer() }
        }
    }

    /// 隐藏气泡与视图离窗时立即定格到目标值，不留活跃 timer。
    func finishImmediately() {
        stopTimer()
        if transition.isAnimating {
            transition.set(transition.target, at: ProcessInfo.processInfo.systemUptime, animated: false)
        }
        render()
    }

    private func render() {
        if let plain = plainText {
            value = plain
        } else if let display = transition.display {
            // 过渡期间保留「Token」计量词，结尾定性后缀（未结束/无活动记录）在定格后出现，避免中途自相矛盾。
            value = Fmt.tokensAbbr(display) + (transition.isAnimating ? " Token" : suffix)
        } else {
            value = ""
        }
        needsDisplay = true
    }

    /// 气泡尺寸按「起点与终值中较宽者」计算：动画期间只改文本不改 frame，
    /// 从大值缩到小值+长后缀的中间帧也不会被截断（缩短方向的中值宽度介于两者之间）。
    private var finalText: String {
        if let plain = plainText { return plain }
        guard let target = transition.target else { return "" }
        return Fmt.tokensAbbr(target) + suffix
    }

    private func startTimer() {
        let t = Timer(timeInterval: 1.0 / 60.0, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.transition.advance(at: ProcessInfo.processInfo.systemUptime)
            self.render()
            if !self.transition.isAnimating { self.stopTimer() }
        }
        timer = t
        RunLoop.main.add(t, forMode: .common)
    }

    private func stopTimer() {
        timer?.invalidate()
        timer = nil
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { finishImmediately() }
    }

    deinit { stopTimer() }

    private func size(of text: String, font: NSFont) -> NSSize {
        (text as NSString).size(withAttributes: [.font: font])
    }

    func fitToContent() {
        let dateSize = size(of: date, font: dateFont)
        var valueWidth = size(of: finalText, font: valueFont).width
        if transition.isAnimating, let start = transition.display {
            valueWidth = max(valueWidth, size(of: Fmt.tokensAbbr(start) + " Token", font: valueFont).width)
        }
        let valueHeight = size(of: finalText, font: valueFont).height
        frame.size = NSSize(width: ceil(max(dateSize.width, valueWidth)) + horizontalInset * 2,
                            height: ceil(dateSize.height + valueHeight + lineSpacing) + verticalInset * 2)
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
        guard let index = selection else {
            hover.isHidden = true
            hover.finishImmediately()
            return
        }
        let day = days[index]
        let hoverValue: ChartHoverLabel.Value
        switch day.1 {
        case .reported(let amount):
            hoverValue = .amount(amount, suffix: day.0 == todayKey ? " Token（今日未结束）" : " Token")
        case .scanned(let amount):
            hoverValue = .amount(amount, suffix: " Token（今日未结束）")
        case .inferredZero:
            hoverValue = .amount(0, suffix: " Token（无活动记录）")
        case .missing:
            hoverValue = .text("暂无数据")
        }
        // 辅功能值与气泡终值同串：值文本从 hoverValue 派生，避免同一后缀字面量写两遍。
        let value: String
        switch hoverValue {
        case .amount(let amount, let suffix): value = Fmt.tokensAbbr(amount) + suffix
        case .text(let text): value = text
        }
        // 辅功能值始终是目标准确值；气泡文字按显示规则做 320ms 过渡。
        hover.setText(date: day.0, value: hoverValue, animated: true)
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
                // 仅顶部 1.5pt 微圆角、底部齐平（基线）；今日空心描边柱同一路径。
                let bar = PanelVisuals.dailyBarPath(in: NSRect(x: x + barInset, y: 46 - height, width: barWidth, height: height))
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
