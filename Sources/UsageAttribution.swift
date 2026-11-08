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
