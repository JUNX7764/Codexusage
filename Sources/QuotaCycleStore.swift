import Foundation

// Called only by the coordinator's serial queue; it never reads credentials.
final class QuotaCycleStore {
    typealias Writer = (Data, URL) throws -> Void
    enum StoreError: Error { case invalidKey, invalidState, unsupportedVersion, unsafePath }
    private let root: URL
    private let writer: Writer
    init(root: URL, writer: @escaping Writer) { self.root = root; self.writer = writer }

    private func path(_ key: String) throws -> URL {
        guard key.count == 64, key.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) else { throw StoreError.invalidKey }
        return root.appendingPathComponent(key, isDirectory: true).appendingPathComponent("history-v1.json")
    }
    private func finite(_ date: Date?) -> Bool { date.map { $0.timeIntervalSince1970.isFinite } ?? true }
    private func valid(_ state: QuotaCycleState) -> Bool {
        guard state.schemaVersion == 1 || state.schemaVersion == 2 || state.schemaVersion == 3, finite(state.lastRequestStartedAt),
              state.previous?.isValid ?? true, state.anomalies.allSatisfy(\.isValid) else { return false }
        if let previous = state.previous {
            guard let current = state.current, state.lastRequestStartedAt == previous.requestStartedAt,
                  previous.observedAt >= current.lastObservedAt else { return false }
        } else if state.current != nil || state.lastRequestStartedAt != nil { return false }
        let records = state.closed + (state.current.map { [$0] } ?? [])
        guard Set(records.map(\.id)).count == records.count,
              state.closed.allSatisfy({ $0.end != nil }), state.current?.end == nil else { return false }
        for r in records {
            guard [r.firstObservedAt, r.lastObservedAt, r.expectedResetAt].allSatisfy({ finite($0) }),
                  finite(r.inferredStartAt), finite(r.boundaryLower), finite(r.boundaryUpper),
                  r.firstObservedAt <= r.lastObservedAt, r.lastObservedUsedPercent.isFinite,
                  (0...100).contains(r.lastObservedUsedPercent), !r.evidence.isEmpty,
                  r.evidence.allSatisfy(\.isValid),
                  zip(r.evidence, r.evidence.dropFirst()).allSatisfy({ $0.observedAt <= $1.observedAt && $0.requestStartedAt < $1.requestStartedAt }),
                  r.evidence.first!.observedAt == r.firstObservedAt,
                  r.evidence.last!.observedAt <= r.lastObservedAt,
                  r.evidence.last!.usedPercent == r.lastObservedUsedPercent,
                  (r.startKind == .inferred) == (r.inferredStartAt != nil),
                  (r.end == nil && r.boundaryLower == nil && r.boundaryUpper == nil) ||
                    (r.end != nil && r.boundaryLower != nil && r.boundaryUpper != nil),
                  r.boundaryLower.map({ $0 >= r.lastObservedAt }) ?? true,
                  (r.boundaryLower == nil || r.boundaryUpper == nil || r.boundaryLower! <= r.boundaryUpper!) else { return false }
        }
        guard zip(records, records.dropFirst()).allSatisfy({ $0.firstObservedAt <= $1.firstObservedAt }),
              Set(state.redemptions.map(\.operationHash)).count == state.redemptions.count,
              state.redemptions.allSatisfy({ event in event.operationHash.count == 64 && event.operationHash.utf8.allSatisfy({ (48...57).contains($0) || (97...102).contains($0) }) && finite(event.originalRequestedAt) && finite(event.responseAt) && (event.originalRequestedAt.map { $0 <= event.responseAt } ?? true) }) else { return false }
        if let pending = state.pendingTransition {
            guard pending.first.isValid, pending.baselineCycleID == state.current?.id,
                  pending.first.observedAt >= state.current!.lastObservedAt,
                  state.previous.map({ pending.first.requestStartedAt <= $0.requestStartedAt }) ?? false else { return false }
        }
        return true
    }
    private func rejectSymlink(_ url: URL) throws {
        if let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]), values.isSymbolicLink == true {
            throw StoreError.unsafePath
        }
    }
    func load(accountKey: String) throws -> QuotaCycleState {
        let url = try path(accountKey)
        try rejectSymlink(root)
        try rejectSymlink(url.deletingLastPathComponent())
        try rejectSymlink(url)
        guard FileManager.default.fileExists(atPath: url.path) else { return QuotaCycleState() }
        let values = try url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
        guard values.isSymbolicLink != true, values.isRegularFile == true else { throw StoreError.unsafePath }
        let data = try Data(contentsOf: url)
        let decoded = try JSONDecoder().decode(QuotaCycleState.self, from: data)
        switch decoded.schemaVersion {
        case 3:
            guard valid(decoded) else { throw StoreError.invalidState }
            return decoded
        case 1, 2:
            // v1/v2 存量：沿用旧保护语义先拒绝损坏文件（invalidState，分区只读、字节不改写），再执行迁移；
            // 剔除口径对 v2（上一轮迁移产物，可能含 observedTransition/gap 零用量 stub）同样适用。
            guard valid(decoded) else { throw StoreError.invalidState }
            return migrate(decoded)
        default:
            throw StoreError.unsupportedVersion
        }
    }
    // v1/v2→v3 迁移：滑动 resetAt 缺陷曾把每次采样都关成伪周期（afterGap/gap、单证据、0% 用量），
    // 并把滑动-idle 期的异常样本逐条堆积；早期版本还把零用量 stub（observedTransition/gap）单独入史。
    // 迁移只做剔除与压缩（只删不改、保序），不重放历史；pendingTransition 作废，其余字段原样保留。
    // 输入已通过 valid()，而删除、压缩替换、置 nil 均不改写剩余记录，校验不变式必然保持，故迁移
    // 结果无需二次校验、不设回退分支（损坏存量已在上方守卫抛出 invalidState）。coordinator 下一次
    // save 自然以 v3 落盘。
    private func migrate(_ v1: QuotaCycleState) -> QuotaCycleState {
        var migrated = v1
        migrated.schemaVersion = 3
        migrated.closed = v1.closed.filter { !Self.isSlidingPseudoCycle($0) }
        migrated.anomalies = QuotaCycleReducer.compressedAnomalies(v1.anomalies, policy: QuotaCyclePolicy())
        migrated.pendingTransition = nil
        return migrated
    }
    // 剔除签名：gap 关闭、证据至多一条且用量为 0（含 afterGap 伪周期与 observedTransition 零用量
    // stub）。有意的口径取舍：单证据零用量的 gap 关闭窗口一律剔除、不区分开始来源——真实重置边界
    // 已由前一周期的自然到期保留，全程零用量的窗口不以独立周期入史；合法的「缺口链」窗口（缺口
    // >15min 后以 0% 返回且此后再无新观测）与此同形态，一并剔除，属于接受的粒度损失。
    private static func isSlidingPseudoCycle(_ record: QuotaCycleRecord) -> Bool {
        record.end == .gap && record.evidence.count <= 1 && record.lastObservedUsedPercent == 0
    }
    func save(_ state: QuotaCycleState, accountKey: String) throws {
        let url = try path(accountKey)
        guard valid(state) else { throw StoreError.invalidState }
        // Never overwrite an unrecognized or damaged file, even after a failed load.
        _ = try load(accountKey: accountKey)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: root.path)
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try writer(encoder.encode(state), url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
