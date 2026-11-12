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
        guard state.schemaVersion == 1, finite(state.lastRequestStartedAt),
              state.previous?.isValid ?? true, state.anomalies.allSatisfy(\.isValid) else { return false }
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
                  r.boundaryLower.map({ $0 >= r.lastObservedAt }) ?? true,
                  (r.boundaryLower == nil || r.boundaryUpper == nil || r.boundaryLower! <= r.boundaryUpper!) else { return false }
        }
        guard zip(records, records.dropFirst()).allSatisfy({ $0.firstObservedAt <= $1.firstObservedAt }),
              Set(state.redemptions.map(\.operationHash)).count == state.redemptions.count,
              state.redemptions.allSatisfy({ event in !event.operationHash.isEmpty && finite(event.originalRequestedAt) && finite(event.responseAt) && (event.originalRequestedAt.map { $0 <= event.responseAt } ?? true) }) else { return false }
        if let pending = state.pendingTransition {
            guard pending.first.isValid, pending.baselineCycleID == state.current?.id else { return false }
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
        guard decoded.schemaVersion == 1 else { throw StoreError.unsupportedVersion }
        guard valid(decoded) else { throw StoreError.invalidState }
        return decoded
    }
    func save(_ state: QuotaCycleState, accountKey: String) throws {
        let url = try path(accountKey)
        guard valid(state) else { throw StoreError.invalidState }
        // Never overwrite an unrecognized or damaged file, even after a failed load.
        _ = try load(accountKey: accountKey)
        let fm = FileManager.default
        try fm.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.deletingLastPathComponent().path)
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        try writer(encoder.encode(state), url)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
