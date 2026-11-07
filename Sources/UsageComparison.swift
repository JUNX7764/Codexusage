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
    struct Item {
        let value: Value
        let description: String
    }
    static func compare(_ current: Double, _ prior: Double) -> Value {
        guard current.isFinite, prior.isFinite, current >= 0, prior >= 0 else { return .insufficient }
        if prior == 0 { return current == 0 ? .unchanged : .fromZero(current) }
        if current == prior { return .unchanged }
        return .percent((current - prior) / prior * 100)
    }
    /// 以本地今日为 D：日环比 = 今日（未结束）对比昨日；周环比 = 最近 7 日（含今日）对比此前 7 日。
    /// 官方日桶尚未包含当日时，今日取 `todayFill`（本机扫描今日用量）；界面文案不区分补足来源。
    static func evaluate(snapshot: OfficialUsageSnapshot?, now: Date, todayFill: Double? = nil) -> (Item, Item) {
        let source = "来源：官方账号用量"
        let weeklyFormula = "两组7日总量比较：（最近7日总量−前7日总量）÷前7日总量×100%"
        func unavailable(_ reason: String) -> (Item, Item) {
            let daily = Item(value: .insufficient, description: source + "；" + reason)
            let weekly = Item(value: .insufficient, description: source + "；" + reason + "；" + weeklyFormula)
            return (daily, weekly)
        }
        guard let snapshot = snapshot else { return unavailable("尚未取得数据") }
        guard !snapshot.days.isEmpty else { return unavailable("尚未取得每日数据") }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current; formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        let dates = (0..<14).map {
            formatter.string(from: Calendar.current.date(byAdding: .day, value: -$0, to: now)!)
        }
        let dailyRange = "\(dates[0]) 对比 \(dates[1])（今日未结束）"
        let weeklyRange = "\(dates[6]) 至 \(dates[0]) 对比 \(dates[13]) 至 \(dates[7])（今日未结束）；\(weeklyFormula)"
        let age = now.timeIntervalSince(snapshot.fetchedAt)
        let ageReason: String? = age < 0 ? "查询时间异常" : (age > 1800 ? "查询结果已过期" : nil)
        func item(_ range: String, indexes: Range<Int>, current: Range<Int>, prior: Range<Int>) -> Item {
            let prefix = source + "；" + range
            if let ageReason = ageReason { return Item(value: .insufficient, description: prefix + "；" + ageReason) }
            func value(_ index: Int) -> Double? {
                switch snapshot.day(dates[index]) {
                case .reported(let amount): return amount
                case .inferredZero: return 0
                case .missing: return index == 0 ? todayFill : nil
                }
            }
            let missing = indexes.filter { value($0) == nil }.map { dates[$0] }
            guard missing.isEmpty else { return Item(value: .insufficient, description: prefix + "；缺少日期：" + missing.joined(separator: "、")) }
            func total(_ range: Range<Int>) -> Double {
                range.reduce(0.0) { sum, index in sum + (value(index) ?? 0) }
            }
            let value = compare(total(current), total(prior))
            let inferred = indexes.contains { snapshot.day(dates[$0]) == .inferredZero }
            let note = value == .insufficient ? "；数值无效" : (inferred ? "；范围内无活动记录日期按 0 计" : "")
            return Item(value: value, description: prefix + note)
        }
        return (item(dailyRange, indexes: 0..<2, current: 0..<1, prior: 1..<2),
                item(weeklyRange, indexes: 0..<14, current: 0..<7, prior: 7..<14))
    }
}
