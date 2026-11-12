import Foundation
import CryptoKit

struct QuotaCycleSnapshot {
    let state: QuotaCycleState
    let isLoading: Bool
    let isSaved: Bool
}

// All state and I/O belong to queue. The lock guards activation synchronously, including
// a second check after scheduling UI delivery, so stale callbacks cannot leak accounts.
final class QuotaCycleCoordinator {
    typealias Scheduler = (@escaping () -> Void) -> Void
    private struct Partition {
        var state = QuotaCycleState()
        var canWrite = true
        var saved = true
        var lastSavedAt: Date?
        var savedSemantic: QuotaCycleState?
    }
    private let queue = DispatchQueue(label: "com.local.codex-usage.quota-history", qos: .utility)
    private let lock = NSLock()
    private let store: QuotaCycleStore
    private let schedule: Scheduler
    private let deliver: (QuotaCycleSnapshot) -> Void
    private let reducer = QuotaCycleReducer(policy: QuotaCyclePolicy())
    private var activeKey: String?
    private var activeGeneration = 0
    private var activation = 0
    private var partitions: [String: Partition] = [:] // queue only

    init(root: URL, writer: @escaping QuotaCycleStore.Writer,
         schedule: @escaping Scheduler = { DispatchQueue.main.async(execute: $0) },
         deliver: @escaping (QuotaCycleSnapshot) -> Void) {
        store = QuotaCycleStore(root: root, writer: writer)
        self.schedule = schedule; self.deliver = deliver
    }
    static func accountKey(_ identity: String?) -> String? {
        guard let identity = identity, identity.hasPrefix("account:"),
              let separator = identity.firstIndex(of: "|"),
              separator > identity.index(identity.startIndex, offsetBy: 8),
              identity.index(after: separator) < identity.endIndex else { return nil }
        return SHA256.hash(data: Data(("quota-cycle-v1|" + identity).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    static func operationHash(_ key: String) -> String {
        SHA256.hash(data: Data(("quota-redemption-v1|" + key).utf8)).map { String(format: "%02x", $0) }.joined()
    }
    private func accepts(_ key: String?, _ generation: Int, _ token: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return activeKey == key && activeGeneration == generation && activation == token
    }
    private func publish(_ snapshot: QuotaCycleSnapshot, key: String?, generation: Int, token: Int) {
        schedule { [weak self] in
            guard let self = self, self.accepts(key, generation, token) else { return }
            self.deliver(snapshot)
        }
    }
    private func partition(_ key: String) -> Partition {
        if let existing = partitions[key] { return existing }
        var result = Partition()
        do { result.state = try store.load(accountKey: key); result.savedSemantic = semantic(result.state) }
        catch { result.canWrite = false; result.saved = false }
        partitions[key] = result
        return result
    }
    private func semantic(_ value: QuotaCycleState) -> QuotaCycleState {
        var result = value
        result.previous = nil; result.lastRequestStartedAt = nil
        if var current = result.current { current.lastObservedAt = current.firstObservedAt; result.current = current }
        return result
    }
    private func save(_ value: inout Partition, key: String, at: Date, force: Bool = false) {
        guard value.canWrite else { return }
        let normalized = semantic(value.state)
        let heartbeat = value.lastSavedAt.map { at.timeIntervalSince($0) >= reducer.policy.heartbeatInterval } ?? true
        guard force || normalized != value.savedSemantic || heartbeat || !value.saved else { return }
        do {
            try store.save(value.state, accountKey: key)
            value.lastSavedAt = at; value.savedSemantic = normalized; value.saved = true
        } catch { value.saved = false }
    }
    func activate(accountIdentity: String?, generation: Int) {
        let key = Self.accountKey(accountIdentity)
        lock.lock()
        let changedAccount = key != activeKey
        if changedAccount { activation += 1 }
        activeKey = key; activeGeneration = generation; let token = activation
        lock.unlock()
        guard let key = key else {
            publish(QuotaCycleSnapshot(state: QuotaCycleState(), isLoading: false, isSaved: true), key: nil, generation: generation, token: token)
            return
        }
        if changedAccount { publish(QuotaCycleSnapshot(state: QuotaCycleState(), isLoading: true, isSaved: true), key: key, generation: generation, token: token) }
        queue.async {
            let p = self.partition(key)
            self.publish(QuotaCycleSnapshot(state: p.state, isLoading: false, isSaved: p.saved), key: key, generation: generation, token: token)
        }
    }
    func observe(_ sample: QuotaObservation, identity: String, generation: Int) {
        guard let key = Self.accountKey(identity) else { return }
        lock.lock(); let token = activation; lock.unlock()
        guard accepts(key, generation, token) else { return }
        queue.async {
            guard self.accepts(key, generation, token) else { return }
            var p = self.partition(key)
            let before = p.state
            self.reducer.ingest(sample, into: &p.state)
            guard before != p.state else { return }
            self.save(&p, key: key, at: sample.observedAt)
            self.partitions[key] = p
            self.publish(QuotaCycleSnapshot(state: p.state, isLoading: false, isSaved: p.saved), key: key, generation: generation, token: token)
        }
    }
    // A confirmed operation remains a fact for its original partition after a switch.
    func recordRedemption(_ evidence: QuotaRedemptionEvidence, identity: String, generation: Int) {
        guard let key = Self.accountKey(identity) else { return }
        lock.lock(); let token = activation; lock.unlock()
        queue.async {
            var p = self.partition(key)
            let before = p.state
            self.reducer.record(evidence, into: &p.state)
            guard before != p.state else { return }
            self.save(&p, key: key, at: evidence.responseAt, force: true)
            self.partitions[key] = p
            self.publish(QuotaCycleSnapshot(state: p.state, isLoading: false, isSaved: p.saved), key: key, generation: generation, token: token)
        }
    }
    // Test synchronization only; no real sleeps or network.
    func drain(_ completion: @escaping () -> Void) { queue.async(execute: completion) }
}
