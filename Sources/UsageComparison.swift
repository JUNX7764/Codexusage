import Foundation

enum UsageComparison {
    enum Value: Equatable {
        case insufficient, unchanged, fromZero(Double), percent(Double)
        var text: String {
            switch self {
            case .insufficient: return "数据不足"
            case .unchanged: return "持平"
            case .fromZero(let value): return "由 0 增至 " + Fmt.tokensAbbr(value)
            case .percent(let value): return String(format: "%@%.0f%%", value > 0 ? "+" : (value < 0 ? "−" : ""), abs(value))
            }
        }
    }
    static func compare(_ current: Double, _ prior: Double) -> Value {
        guard current.isFinite, prior.isFinite, current >= 0, prior >= 0 else { return .insufficient }
        if prior == 0 { return current == 0 ? .unchanged : .fromZero(current) }
        if current == prior { return .unchanged }
        return .percent((current - prior) / prior * 100)
    }
    /// The source date is a calendar label; UTC is used only for date arithmetic.
    static func descriptions(snapshot: OfficialUsageSnapshot?, semanticsConfirmed: Bool) -> (String, String) {
        let source = "来源：官方账号用量"
        let caveat = semanticsConfirmed ? "" : "；源日期时区及缺失日期含义尚未确认"
        guard let end = snapshot?.days.keys.sorted().last else {
            let text = source + "；暂无源日期" + caveat
            return (text, text)
        }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        guard let date = formatter.date(from: end), formatter.string(from: date) == end else {
            let text = source + "；源日期无效" + caveat
            return (text, text)
        }
        func day(_ offset: Int) -> String {
            formatter.string(from: date.addingTimeInterval(-Double(offset) * 86400))
        }
        return ("\(source)；\(day(0)) 对比 \(day(1))\(caveat)",
                "\(source)；\(day(6)) 至 \(day(0)) 对比 \(day(13)) 至 \(day(7))\(caveat)")
    }
    static func calculate(snapshot: OfficialUsageSnapshot?, semanticsConfirmed: Bool, now: Date) -> (Value, Value) {
        guard semanticsConfirmed, let snapshot = snapshot, now.timeIntervalSince(snapshot.fetchedAt) <= 1800,
              now >= snapshot.fetchedAt, let end = snapshot.days.keys.sorted().last else { return (.insufficient, .insufficient) }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(secondsFromGMT: 0)!
        f.calendar = Calendar(identifier: .gregorian); f.dateFormat = "yyyy-MM-dd"; f.isLenient = false
        guard let date = f.date(from: end), f.string(from: date) == end else { return (.insufficient, .insufficient) }
        let values = (0..<14).map { snapshot.days[f.string(from: date.addingTimeInterval(-Double($0) * 86400))] }
        let daily: Value = values[0].flatMap { current in values[1].map { compare(current, $0) } } ?? .insufficient
        guard values.allSatisfy({ $0 != nil }) else { return (daily, .insufficient) }
        let current = values[0..<7].compactMap { $0 }.reduce(0,+)
        let prior = values[7..<14].compactMap { $0 }.reduce(0,+)
        return (daily, compare(current, prior))
    }
}
