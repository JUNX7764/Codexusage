import AppKit

private final class ChartHoverLabel: NSTextField {
    override func hitTest(_ point: NSPoint) -> NSView? { nil }
}

final class DailyUsageChart: NSView {
    private let days: [(String, OfficialUsageSnapshot.Day)]
    var selectedIndexForPreview: Int? { selection }
    var selectedTextForPreview: String { hover.stringValue }
    var hoverWithinBoundsForPreview: Bool {
        !hover.isHidden && hover.frame.minX >= bounds.minX && hover.frame.maxX <= bounds.maxX
            && hover.frame.minY >= bounds.minY && hover.frame.maxY <= bounds.maxY
            && hover.hitTest(.zero) == nil
    }
    private var selection: Int? { didSet { needsDisplay = true; updateAccessibility() } }
    private let hover = ChartHoverLabel(labelWithString: "")
    private let orange = NSColor(srgbRed: 0.72, green: 0.39, blue: 0.22, alpha: 1)
    override var acceptsFirstResponder: Bool { true }
    override var isFlipped: Bool { true }

    init(snapshot: OfficialUsageSnapshot?) {
        var entries: [(String, OfficialUsageSnapshot.Day)] = []
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"
        if let end = snapshot?.days.keys.sorted().last, let endDate = formatter.date(from: end) {
            for index in (0..<30).reversed() {
                let day = formatter.string(from: endDate.addingTimeInterval(-Double(index) * 86400))
                entries.append((day, snapshot?.day(day) ?? .missing))
            }
        }
        days = entries
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
        case .reported(let amount): value = Fmt.tokensAbbr(amount) + " Token"
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
            if case .reported(let value) = item.1 { return value }; return nil
        }.max() ?? 1)
        let width = bounds.width / CGFloat(days.count)
        for (index, day) in days.enumerated() {
            let x = CGFloat(index) * width
            if index == selection { NSColor.labelColor.withAlphaComponent(0.07).setFill(); NSRect(x: x, y: 0, width: width, height: 46).fill() }
            let dayValue: Double?
            switch day.1 { case .reported(let value): dayValue = value; case .inferredZero: dayValue = 0; case .missing: dayValue = nil }
            if let value = dayValue {
                orange.setFill()
                let height = max(value == 0 ? 1 : 2, CGFloat(value / maxValue) * 46)
                NSBezierPath(roundedRect: NSRect(x: x + 1, y: 46 - height, width: max(1, width - 2), height: height), xRadius: 1, yRadius: 1).fill()
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
        heightAnchor.constraint(equalToConstant: 6).isActive = true
    }
    required init?(coder: NSCoder) { fatalError() }
    override func draw(_ dirtyRect: NSRect) {
        NSColor.secondaryLabelColor.withAlphaComponent(0.16).setFill()
        NSBezierPath(roundedRect: bounds, xRadius: 3, yRadius: 3).fill()
        PanelAccent.codex.color.setFill()
        NSBezierPath(roundedRect: NSRect(x: 0, y: 0, width: bounds.width * fraction, height: bounds.height), xRadius: 3, yRadius: 3).fill()
    }
}
