import AppKit

// Controller owns this object; rebuilding an AppKit view does not reset the page or selection.
final class QuotaCycleUIState {
    var browser = QuotaCycleBrowser()
    var expanded = true
    var hover: UUID?
    func reset() { browser = QuotaCycleBrowser(); hover = nil }
}

final class QuotaCycleHistoryView: NSView {
    private let snapshot: QuotaCycleSnapshot
    private let available: Bool
    private let now: Date
    private let state: QuotaCycleUIState
    private let earlier = NSButton(title: "‹", target: nil, action: nil)
    private let newer = NSButton(title: "›", target: nil, action: nil)
    private let more = NSButton(title: "更早记录", target: nil, action: nil)
    private let legend = NSTextField(labelWithString: "上限  ·  已用")
    private let detail1 = NSTextField(labelWithString: "")
    private let chart: QuotaCycleChart
    override var isFlipped: Bool { true }

    init(snapshot: QuotaCycleSnapshot, available: Bool, state: QuotaCycleUIState, now: Date = Date()) {
        self.snapshot = snapshot; self.available = available; self.state = state; self.now = now
        chart = QuotaCycleChart(state: state, snapshot: snapshot, now: now)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        heightAnchor.constraint(equalToConstant: 132).isActive = true
        for view in [earlier, newer, more, legend, detail1, chart] { addSubview(view) }
        for button in [earlier, newer, more] { button.bezelStyle = .inline; button.target = self; button.font = .systemFont(ofSize: 11) }
        earlier.action = #selector(showEarlier); newer.action = #selector(showNewer); more.action = #selector(showMore)
        earlier.setAccessibilityLabel("更早的额度周期"); newer.setAccessibilityLabel("更新的额度周期")
        more.setAccessibilityLabel("加载更早的额度周期")
        let legendText = NSMutableAttributedString(string: "■ 上限   ", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: NSColor.secondaryLabelColor])
        legendText.append(NSAttributedString(string: "■ 已用   ● 当前", attributes: [.font: NSFont.systemFont(ofSize: 10), .foregroundColor: PanelAccent.codex.color]))
        legend.attributedStringValue = legendText
        for field in [detail1] {
            field.font = .systemFont(ofSize: 10); field.lineBreakMode = .byTruncatingTail
            field.textColor = .secondaryLabelColor; field.maximumNumberOfLines = 1
        }
        detail1.textColor = .labelColor
        chart.changed = { [weak self] in self?.refresh() }
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }
    override func layout() {
        super.layout()
        let width = bounds.width
        legend.frame = NSRect(x: 0, y: 0, width: max(50, width - 132), height: 19)
        more.frame = NSRect(x: max(0, width - 132), y: 0, width: 78, height: 19)
        earlier.frame = NSRect(x: width - 51, y: 0, width: 24, height: 19)
        newer.frame = NSRect(x: width - 26, y: 0, width: 24, height: 19)
        chart.frame = NSRect(x: 0, y: 21, width: width, height: 94)
        detail1.frame = NSRect(x: 0, y: 117, width: width, height: 15)
    }
    var previewText: String { detail1.stringValue }
    var previewTooltip: String { detail1.toolTip ?? "" }
    var previewPercentageLabels: [String] { chart.percentageLabelsForPreview }
    var previewLayoutFits: Bool {
        chart.frame.maxY <= detail1.frame.minY && detail1.frame.maxY <= bounds.maxY
            && chart.frame.width <= bounds.width
    }
    private func refresh() {
        let records = state.browser.records
        let visible = state.browser.visible
        let first = visible.first.flatMap { item in records.firstIndex { $0.id == item.id } } ?? 0
        earlier.isEnabled = first > max(0, records.count - state.browser.visibleLimit)
        newer.isEnabled = state.browser.olderPage > 0
        more.isHidden = state.browser.visibleLimit >= records.count
        let selected = state.hover ?? state.browser.selectedCycleID
        if let cycle = records.first(where: { $0.id == selected }) {
            let lines = Self.detail(cycle, pending: snapshot.state.current?.id == cycle.id ? snapshot.state.pendingTransition : nil, now: now)
            let status = !snapshot.isSaved ? "历史未保存 · " : (snapshot.isLoading ? "正在读取历史 · " : "")
            detail1.stringValue = status + lines.0
            let fullDescription = status + Self.fullDescription(cycle, pending: snapshot.state.current?.id == cycle.id ? snapshot.state.pendingTransition : nil, now: now)
            detail1.toolTip = fullDescription
            detail1.setAccessibilityHelp(fullDescription)
            chart.setAccessibilityValue(fullDescription)
        } else {
            detail1.stringValue = snapshot.isLoading ? "正在读取历史" : (!available ? "无法确认稳定账户，暂不记录" : "从首次成功读取额度后开始记录")
            if !snapshot.isSaved { detail1.stringValue = "历史未保存 · " + detail1.stringValue }
            detail1.toolTip = detail1.stringValue
            detail1.setAccessibilityHelp(detail1.stringValue)
        }
        chart.needsDisplay = true
    }
    @objc private func showEarlier() {
        state.hover = nil; state.browser.earlier()
        if let id = state.browser.visible.last?.id { state.browser.select(id) }
        refresh()
    }
    @objc private func showNewer() {
        state.hover = nil; state.browser.newer()
        if let id = state.browser.visible.last?.id { state.browser.select(id) }
        refresh()
    }
    @objc private func showMore() { state.browser.loadEarlier(); refresh() }
    static func date(_ date: Date, format: String = "MM/dd HH:mm") -> String {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_CN"); f.dateFormat = format; return f.string(from: date)
    }
    static func detail(_ cycle: QuotaCycleRecord, pending: QuotaPendingTransition?, now: Date = Date()) -> (String, String) {
        let used = String(format: "%.1f", cycle.lastObservedUsedPercent).replacingOccurrences(of: ".0", with: "")
        let remaining = String(format: "%.1f", cycle.remainingAtLastObservation).replacingOccurrences(of: ".0", with: "")
        let start = cycle.startKind == .afterPlanChange ? "开始未知(首观" + date(cycle.firstObservedAt, format: "MM/dd") + ")" : (cycle.inferredStartAt.map { "推算" + date($0, format: "MM/dd") } ?? "首次观测" + date(cycle.firstObservedAt, format: "MM/dd"))
        let ending: String
        if cycle.end == nil {
            ending = "至今(" + (cycle.expectedResetAt < now ? "原定" : "预计") + date(cycle.expectedResetAt, format: "MM/dd") + ")"
        } else if let lower = cycle.boundaryLower, let upper = cycle.boundaryUpper {
            let lowDate = date(lower, format: "MM/dd"), highDate = date(upper, format: "MM/dd")
            ending = lowDate == highDate ? "约" + highDate : lowDate + "~" + highDate + "间"
        } else {
            ending = "结束未知"
        }
        let span = start + "–" + ending
        if let pending = pending { return (span + " · " + (pending.reason == .planChange ? "套餐/额度变更待确认" : "重置待确认"), "最后观测已用 \(used)%") }
        switch cycle.end {
        case .natural: return (span + " · 正常到期", "最后观测已用 \(used)% · 到期未用约 \(remaining)%")
        case .redeemed: return (span + " · 主动用卡", "最后观测已用 \(used)% · 重置前剩余约 \(remaining)%")
        case .earlyUnknown: return (span + " · 提前重置（来源未知）", "最后观测已用 \(used)% · 重置前剩余约 \(remaining)%")
        case .gap: return (span + " · 观测缺口", "最后观测已用 \(used)%")
        case .unconfirmed: return (span + " · 套餐/额度变更", "最后观测已用 \(used)%")
        case nil:
            let origin = cycle.startKind == .afterPlanChange ? "套餐/额度变更后，开始未知" : (cycle.startKind == .afterGap ? "缺口后首次观测" : "进行中")
            let expired = cycle.expectedResetAt < now
            let status = expired ? (cycle.startKind == .afterPlanChange ? "套餐变更后 · 等待重置确认" : "等待重置确认") : origin
            return (span + " · " + status, expired ? "最后观测已用 \(used)% · 剩余 \(remaining)%" : "已用 \(used)% · 当前剩余 \(remaining)%")
        }
    }
    static func fullDescription(_ cycle: QuotaCycleRecord, pending: QuotaPendingTransition?, now: Date) -> String {
        let lines = detail(cycle, pending: pending, now: now)
        let format = "yyyy/MM/dd HH:mm"
        let start: String
        if let inferred = cycle.inferredStartAt { start = "开始时间推算 " + date(inferred, format: format) }
        else if cycle.startKind == .afterPlanChange { start = "开始时间未知，首次观测 " + date(cycle.firstObservedAt, format: format) }
        else { start = "首次观测 " + date(cycle.firstObservedAt, format: format) }
        let end: String
        if let lower = cycle.boundaryLower, let upper = cycle.boundaryUpper {
            end = "结束边界在 " + date(lower, format: format) + " 至 " + date(upper, format: format) + " 之间"
        } else if cycle.end == nil {
            end = "至今，" + (cycle.expectedResetAt < now ? "原定" : "预计") + "重置 " + date(cycle.expectedResetAt, format: format)
        } else { end = "结束时间未知" }
        return [lines.0, start, end, lines.1, "最后观测 " + date(cycle.lastObservedAt, format: format)].joined(separator: "，")
    }
}

private final class QuotaCycleAccessibilityItem: NSAccessibilityElement {
    var onPress: (() -> Void)?
    override func accessibilityPerformPress() -> Bool { onPress?(); return true }
}

final class QuotaCycleChart: NSView {
    private let state: QuotaCycleUIState
    private let snapshot: QuotaCycleSnapshot
    private let now: Date
    var changed: (() -> Void)?
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }
    static func isCurrent(_ cycle: QuotaCycleRecord, snapshot: QuotaCycleSnapshot) -> Bool { snapshot.state.current?.id == cycle.id }
    static func usedPercentage(_ value: Double) -> String {
        String(format: "%.1f", value).replacingOccurrences(of: ".0", with: "") + "%"
    }
    var percentageLabelsForPreview: [String] { state.browser.visible.map { Self.usedPercentage($0.lastObservedUsedPercent) } }
    init(state: QuotaCycleUIState, snapshot: QuotaCycleSnapshot, now: Date) {
        self.state = state; self.snapshot = snapshot; self.now = now; super.init(frame: .zero)
        setAccessibilityElement(true); setAccessibilityRole(.group)
        setAccessibilityLabel("额度周期双柱图，使用左右方向键选择周期")
    }
    required init?(coder: NSCoder) { fatalError() }
    override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); window?.acceptsMouseMovedEvents = true }
    override func updateTrackingAreas() {
        super.updateTrackingAreas(); trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.activeAlways, .mouseMoved, .mouseEnteredAndExited, .inVisibleRect], owner: self))
    }
    private func cycle(at event: NSEvent) -> QuotaCycleRecord? {
        let x = convert(event.locationInWindow, from: nil).x
        guard bounds.contains(convert(event.locationInWindow, from: nil)) else { return nil }
        let visible = state.browser.visible, width = max(1, (bounds.width - 22) / 6)
        let index = Int(floor((x - 22) / width)) - (6 - visible.count)
        return index >= 0 && index < visible.count ? visible[index] : nil
    }
    override func mouseEntered(with event: NSEvent) { mouseMoved(with: event) }
    override func mouseMoved(with event: NSEvent) { state.hover = cycle(at: event)?.id; changed?() }
    override func mouseExited(with event: NSEvent) { state.hover = nil; changed?() }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        guard let selected = cycle(at: event) else { return }
        window?.makeFirstResponder(self); state.browser.select(selected.id); state.hover = nil; changed?()
    }
    override func keyDown(with event: NSEvent) {
        guard event.keyCode == 123 || event.keyCode == 124 else { super.keyDown(with: event); return }
        let records = state.browser.records
        guard !records.isEmpty else { return }
        let index = records.firstIndex { $0.id == state.browser.selectedCycleID } ?? records.count - 1
        let target = max(0, min(records.count - 1, index + (event.keyCode == 123 ? -1 : 1)))
        let id = records[target].id
        if !state.browser.visible.contains(where: { $0.id == id }) {
            if event.keyCode == 123 { state.browser.earlier() } else { state.browser.newer() }
        }
        if state.browser.visible.contains(where: { $0.id == id }) { state.browser.select(id) }
        state.hover = nil; changed?()
    }
    override func accessibilityChildren() -> [Any]? {
        guard let window = window else { return [] }
        let visible = state.browser.visible, width = max(1, (bounds.width - 22) / 6)
        return visible.enumerated().map { index, cycle in
            let item = QuotaCycleAccessibilityItem()
            let x = 22 + CGFloat(index + 6 - visible.count) * width
            let frameInWindow = convert(NSRect(x: x, y: 0, width: width, height: bounds.height), to: nil)
            item.setAccessibilityFrame(window.convertToScreen(frameInWindow))
            item.setAccessibilityParent(self)
            item.setAccessibilityRole(.button)
            let full = QuotaCycleHistoryView.fullDescription(cycle, pending: snapshot.state.current?.id == cycle.id ? snapshot.state.pendingTransition : nil, now: now)
            item.setAccessibilityLabel((Self.isCurrent(cycle, snapshot: snapshot) ? "当前轮次，" : "") + full)
            item.onPress = { [weak self] in self?.state.browser.select(cycle.id); self?.state.hover = nil; self?.changed?() }
            return item
        }
    }
    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let visible = state.browser.visible, width = max(1, (bounds.width - 22) / 6)
        let attrs: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: 9), .foregroundColor: NSColor.secondaryLabelColor]
        ("100%" as NSString).draw(at: NSPoint(x: 0, y: 0), withAttributes: attrs)
        for (i, cycle) in visible.enumerated() {
            let x = 22 + CGFloat(i + 6 - visible.count) * width
            if cycle.id == (state.hover ?? state.browser.selectedCycleID) {
                PanelAccent.codex.color.withAlphaComponent(0.09).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: 0, width: width, height: 64), xRadius: 4, yRadius: 4).fill()
            }
            let barWidth = min(7, max(3, (width - 8) / 3)), left = x + (width - barWidth * 2 - 3) / 2
            NSColor.secondaryLabelColor.withAlphaComponent(0.25).setFill()
            NSBezierPath(roundedRect: NSRect(x: left, y: 2, width: barWidth, height: 58), xRadius: 1, yRadius: 1).fill()
            PanelAccent.codex.color.setFill()
            let height = max(1, CGFloat(cycle.lastObservedUsedPercent / 100) * 58)
            NSBezierPath(roundedRect: NSRect(x: left + barWidth + 3, y: 60 - height, width: barWidth, height: height), xRadius: 1, yRadius: 1).fill()
            let date = cycle.inferredStartAt ?? cycle.firstObservedAt
            let label = (cycle.inferredStartAt == nil ? "" : "~") + QuotaCycleHistoryView.date(date, format: "MM/dd")
            let text = label as NSString, size = text.size(withAttributes: attrs)
            let isCurrent = Self.isCurrent(cycle, snapshot: snapshot)
            let markerWidth: CGFloat = isCurrent ? 6 : 0
            let textX = x + max(0, (width - size.width - markerWidth) / 2)
            text.draw(at: NSPoint(x: textX, y: 64), withAttributes: attrs)
            if isCurrent {
                PanelAccent.codex.color.setFill()
                NSBezierPath(ovalIn: NSRect(x: textX + size.width + 2, y: 68, width: 3, height: 3)).fill()
            }
            let percentage = Self.usedPercentage(cycle.lastObservedUsedPercent) as NSString
            let percentageAttrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .medium),
                .foregroundColor: NSColor.labelColor
            ]
            let percentageSize = percentage.size(withAttributes: percentageAttrs)
            percentage.draw(at: NSPoint(x: x + max(0, (width - percentageSize.width) / 2), y: 78),
                            withAttributes: percentageAttrs)
        }
    }
}

// Fixed fake observations for visual/event tests; never initializes a store.
enum QuotaCyclePreviewFixture {
    static func make(count: Int) -> QuotaCycleSnapshot {
        let newestObservation = Date(timeIntervalSince1970: 1_793_897_600)
        let base = newestObservation.addingTimeInterval(-Double(max(0, count - 1)) * 604800 - 400000)
        var records: [QuotaCycleRecord] = []
        for i in 0..<max(0, count) {
            let start = base.addingTimeInterval(Double(i) * 604800)
            let observed = start.addingTimeInterval(400000)
            let used = [100.0, 81, 72, 36, 0][i % 5]
            let sample = QuotaObservation(requestStartedAt: observed.addingTimeInterval(-1), observedAt: observed,
                                          usedPercent: used, resetAt: start.addingTimeInterval(604800), planType: "fixture")
            let ending: QuotaCycleEnd = [QuotaCycleEnd.natural, .redeemed, .earlyUnknown, .gap, .unconfirmed][i % 5]
            let id = UUID(uuidString: String(format: "00000000-0000-0000-0000-%012d", i + 1))!
            records.append(QuotaCycleRecord(id: id, startKind: i == 0 ? .inferred : .observedTransition,
                inferredStartAt: i == 0 ? start : nil, firstObservedAt: observed, expectedResetAt: sample.resetAt,
                lastObservedAt: observed, lastObservedUsedPercent: used,
                boundaryLower: i == count - 1 ? nil : observed,
                boundaryUpper: i == count - 1 ? nil : observed.addingTimeInterval(120),
                end: i == count - 1 ? nil : ending, incomplete: i == 0, evidence: [sample]))
        }
        var state = QuotaCycleState()
        if let last = records.popLast() { state.closed = records; state.current = last; state.previous = last.evidence.last; state.lastRequestStartedAt = state.previous?.requestStartedAt }
        return QuotaCycleSnapshot(state: state, isLoading: false, isSaved: true)
    }
}
