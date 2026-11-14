import AppKit

func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}

switch CommandLine.arguments.dropFirst().first {
case "dailyCorners":
    let rect = NSRect(x: 0, y: 0, width: 6, height: 20)
    let path = PanelVisuals.dailyBarPath(in: rect)
    check(path.bounds == rect, "rounding must preserve width, height and bounds")
    check(path.contains(NSPoint(x: 0.05, y: 10)), "bar body kept")
    // 翻转视图：最小 y 是视觉顶部（圆角），最大 y 是基线（直角）。
    check(!path.contains(NSPoint(x: 0.05, y: 0.05)), "top corner is rounded")
    check(path.contains(NSPoint(x: 0.05, y: 19.9)), "bottom stays flush at baseline")
    for height in [0.2, 1.0, 3.0] {
        let tiny = PanelVisuals.dailyBarPath(in: NSRect(x: 0, y: 0, width: 6, height: height))
        check(tiny.bounds.minY >= 0 && tiny.bounds.maxY <= height + 0.0001, "short bars stay in bounds")
    }
    print("PASS: dailyCorners")
case "capacityTrack":
    let column = NSRect(x: 20, y: 0, width: 43, height: 58)
    let zero = PanelVisuals.capacityTrack(in: column, usedPercent: 0)
    check(zero.track.width == 12 && zero.track.midX == column.midX, "one centered 12pt slot")
    check(zero.fill == nil, "0% does not fabricate usage")
    let half = PanelVisuals.capacityTrack(in: column, usedPercent: 50)
    check(abs(half.fill!.height / half.track.height - 0.5) < 0.0001, "fill is normalized")
    check(half.fill!.maxY == half.track.maxY && half.fill!.width == half.track.width
        && half.fill!.minX == half.track.minX, "fill shares track x-range and anchors at its bottom edge")
    let full = PanelVisuals.capacityTrack(in: column, usedPercent: 100)
    check(full.fill == full.track, "100% fills the slot")
    let tiny = PanelVisuals.capacityTrack(in: column, usedPercent: 0.4)
    check(tiny.fill!.height < 1, "tiny use is not inflated")
    check(PanelVisuals.capacityTrack(in: column, usedPercent: .nan).fill == nil, "nonfinite does not fill")
    check(PanelVisuals.capacityTrack(in: column, usedPercent: -5).fill == nil, "negative does not fill")
    let narrow = PanelVisuals.capacityTrack(in: NSRect(x: 0, y: 0, width: 10, height: 58), usedPercent: 50)
    check(narrow.track.width == 6 && narrow.track.midX == 5, "narrow columns clamp track width")
    print("PASS: capacityTrack")
case "deltaChip":
    let font = NSFont.systemFont(ofSize: 11, weight: .semibold)
    for value in ["+18.0%", "−6.0%", "持平", "由 0 增至 11.8M", "数据不足"] {
        let size = PanelDeltaChip.size(for: value, font: font)
        check(size.height == 20 && size.width > 12, "chip has text and padding")
    }
    check(!PanelDeltaChip.requiresTwoRows(halfWidth: 144, captionWidth: 40, chipWidth: 77), "normal width stays one row")
    check(PanelDeltaChip.requiresTwoRows(halfWidth: 120, captionWidth: 40, chipWidth: 77), "narrow long values must not truncate numbers")
    print("PASS: deltaChip")
case "tokenTransition":
    var s = TokenValueTransition()
    s.set(100, at: 0, animated: true)
    check(s.display == 100 && !s.isAnimating, "first display snaps")
    s.set(200, at: 10, animated: true)
    check(s.isAnimating, "interaction animates")
    check(s.advance(at: 10) == 100, "starts at current value")
    let middle = s.advance(at: 10.160)!
    check(abs(middle - 187.5) < 0.001, "320ms cubic ease-out midpoint")
    s.set(50, at: 10.160, animated: true)
    check(abs(s.display! - middle) < 0.001, "retarget without zero or jump")
    check(s.advance(at: 10.481) == 50 && !s.isAnimating, "latest target wins")
    s.set(nil, at: 11, animated: true)
    check(s.display == nil && s.target == nil && !s.isAnimating, "missing cancels")
    s.set(0, at: 12, animated: true)
    check(s.display == 0 && !s.isAnimating, "recovery and zero are real values")
    s.set(1_000_000, at: 13, animated: false)
    check(s.display == 1_000_000 && !s.isAnimating, "reduce motion snaps")
    s.set(.nan, at: 14, animated: true)
    check(s.target == nil && !s.isAnimating, "nonfinite values do not animate")
    s.set(-1, at: 15, animated: true)
    check(s.target == nil && !s.isAnimating, "negative values do not animate")
    print("PASS: tokenTransition")
case "layoutModel":
    check(PanelCardLayout.default.order == PanelCardID.allCases, "default order")
    check(PanelCardLayout.default.visibleOrder == PanelCardID.allCases, "default visibility")
    var layout = PanelCardLayout.default
    layout.setVisible(false, for: .tools)
    check(!layout.isVisible(.tools) && !layout.visibleOrder.contains(.tools), "hide card")
    layout.setVisible(true, for: .tools)
    check(layout.isVisible(.tools), "re-show card")
    layout.move(.daily, direction: .up)
    check(layout.order.firstIndex(of: .daily)! < layout.order.firstIndex(of: .tokens)!, "move up")
    var top = PanelCardLayout.default
    top.move(.quota, direction: .up)
    check(top.order == PanelCardID.allCases, "move at top is a no-op")
    var bottom = PanelCardLayout.default
    bottom.move(.tools, direction: .down)
    check(bottom.order == PanelCardID.allCases, "move at bottom is a no-op")
    let suiteName = "ui-refinements-\(UUID().uuidString)"
    let store = UserDefaults(suiteName: suiteName)!
    defer { store.removePersistentDomain(forName: suiteName) }
    layout.save(store: store)
    check(PanelCardLayout.load(store: store) == layout, "roundtrip")
    store.set(Data("garbage".utf8), forKey: PanelCardLayout.defaultsKey)
    check(PanelCardLayout.load(store: store) == .default, "corrupt falls back")
    store.removeObject(forKey: PanelCardLayout.defaultsKey)
    check(PanelCardLayout.load(store: store) == .default, "missing falls back")
    let patched = PanelCardLayout(order: [.daily, .quota], hidden: [])
    check(patched.order == [.daily, .quota] + PanelCardID.allCases.filter { $0 != .daily && $0 != .quota },
          "missing cards appended in default order")
    let duplicated = PanelCardLayout(order: [.daily, .daily, .tools], hidden: [])
    check(duplicated.order == [.daily, .tools] + PanelCardID.allCases.filter { $0 != .daily && $0 != .tools },
          "duplicates collapsed")
    check(PanelCardLayout.decoded(from: Data()) == nil, "empty payload rejected")
    let unknown = try! JSONSerialization.data(withJSONObject: ["order": ["daily", "bogus"], "hidden": []])
    check(PanelCardLayout.decoded(from: unknown) == nil, "unknown id rejected")
    print("PASS: layoutModel")
default:
    fputs("FAIL: unknown visual fixture\n", stderr); exit(1)
}
