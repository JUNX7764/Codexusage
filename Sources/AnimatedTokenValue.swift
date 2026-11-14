import Foundation

// 数值过渡的纯状态：320ms 三次 ease-out，交互切换时从当前显示值重定向（不排队、不归零）。
// 首次显示、缺数恢复、非有限值与「减少动态效果」都直接到位；调用方用 systemUptime 驱动，不用墙上时钟。
struct TokenValueTransition {
    static let duration: TimeInterval = 0.320
    private(set) var display: Double?
    private(set) var target: Double?
    private(set) var isAnimating = false
    private var from: Double = 0
    private var startedAt: TimeInterval = 0

    mutating func set(_ raw: Double?, at now: TimeInterval, animated: Bool) {
        _ = advance(at: now)
        guard let value = raw, value.isFinite, value >= 0 else {
            display = nil; target = nil; isAnimating = false
            return
        }
        target = value
        guard animated, let current = display, current != value else {
            display = value; isAnimating = false
            return
        }
        from = current
        startedAt = now
        isAnimating = true
    }

    @discardableResult
    mutating func advance(at now: TimeInterval) -> Double? {
        guard isAnimating, let target = target else { return display }
        let t = min(1, max(0, (now - startedAt) / Self.duration))
        display = from + (target - from) * (1 - pow(1 - t, 3))
        if t >= 1 {
            display = target
            isAnimating = false
        }
        return display
    }
}
