import Foundation

enum UsageSourceStatus {
    case absent, available, failed, pending
    var text: String {
        switch self {
        case .absent: return "未发现"
        case .available: return "已读取"
        case .failed: return "读取失败"
        case .pending: return "未读取"
        }
    }
}

/// 本机扫描 / 外部来源 / 官方查询结果共用的 30 分钟过期阈值：
/// 超过该时长未成功刷新即在 UI 标注过期（面板、比较与菜单栏口径一致）
enum UsageFreshness {
    static let staleSeconds: TimeInterval = 1800
}

enum UsageAttribution {
    // Most-specific root owns an overlapping path; equal roots keep their first owner.
    static func owner(path: String, roots: [String]) -> Int? {
        let matches = roots.indices.filter { path.hasPrefix(roots[$0].hasSuffix("/") ? roots[$0] : roots[$0] + "/") }
        return matches.sorted { roots[$0].count == roots[$1].count ? $0 < $1 : roots[$0].count > roots[$1].count }.first
    }
}

struct LocalUsageTotals {
    let input: Double
    let output: Double
    let total: Double
    let models: [String: ModelTokenUsage]
}

enum LocalUsageMerge {
    static func combine(_ local: TokenScanner.Stats?, _ external: ExternalTokenScanner.Stats?) -> LocalUsageTotals? {
        guard local != nil || external != nil else { return nil }
        var models = local?.models ?? [:]
        for (name, value) in external?.models ?? [:] {
            var item = models[name] ?? ModelTokenUsage()
            item.input += value.input; item.output += value.output; item.total += value.total
            models[name] = item
        }
        return LocalUsageTotals(input: (local?.input ?? 0) + (external?.input ?? 0),
                                output: (local?.output ?? 0) + (external?.output ?? 0),
                                total: (local?.total ?? 0) + (external?.total ?? 0), models: models)
    }
}

/// Preserve the local calendar day used by the scanner, including across timezone changes.
enum LocalScanDay {
    static func key(_ date: Date, timeZone: TimeZone = .current) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let day = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", day.year!, day.month!, day.day!)
    }
}

struct TodayUsage {
    let local: TokenScanner.Stats?
    let external: ExternalTokenScanner.Stats?
    let externalDayMatches: Bool
    let complete: Bool
    var total: Double? {
        guard complete, local != nil || external != nil else { return nil }
        return (local?.total ?? 0) + (external?.total ?? 0)
    }
}

extension UsageData {
    /// 计划②「完整合计显示缺失」的字面口径：参与合计的来源有当天可信值即可计入。
    /// fresh 部分扫描结果与当日早前成功扫描的保留值都是同日可信值，失败状态不清空今日；
    /// 跨日保留值由 sampleDay 与 day 的比对自动排除（「只用同日数据」）。
    func today(on day: String) -> TodayUsage {
        let local = localSampleDay == day && localStatus != .absent ? tokensToday : nil
        let externalMatches = externalSampleDay == day
        let external = externalMatches ? extToday : nil
        let localReady = localStatus == .absent || local != nil
        let externalReady = externalMatches && external != nil
            && !sourceStatus.values.contains(.pending)
        return TodayUsage(local: local, external: external, externalDayMatches: externalMatches,
                          complete: localReady && externalReady)
    }
}
