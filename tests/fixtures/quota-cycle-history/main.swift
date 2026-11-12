import Foundation
func check(_ value: @autoclosure () -> Bool, _ message: String) {
    guard value() else { fputs("FAIL: \(message)\n", stderr); exit(1) }
}
let t = Date(timeIntervalSince1970: 1_800_000_000)
func sample(_ seconds: Double, _ used: Double, _ reset: Double = 604800, plan: String? = "plus") -> QuotaObservation {
    QuotaObservation(requestStartedAt: t.addingTimeInterval(seconds - 1), observedAt: t.addingTimeInterval(seconds), usedPercent: used, resetAt: t.addingTimeInterval(reset), planType: plan)
}
let reducer = QuotaCycleReducer(policy: QuotaCyclePolicy())
var state = QuotaCycleState()
switch CommandLine.arguments[1] {
case "firstObservation":
    reducer.ingest(sample(0, 43), into: &state)
    check(state.current?.lastObservedUsedPercent == 43, "used percentage")
    check(state.current?.remainingAtLastObservation == 57, "remaining")
    check(state.current?.startKind == .inferred && state.closed.isEmpty, "inferred only")
case "sameWindow":
    reducer.ingest(sample(0, 30), into: &state)
    let id = state.current!.id
    for (time, used, reset) in [(10.0, 31.0, 604830.0), (20, 32, 604680), (30, 32, 604920)] {
        reducer.ingest(sample(time, used, reset), into: &state)
    }
    reducer.ingest(sample(30, 40), into: &state)
    reducer.ingest(sample(25, 90), into: &state)
    for value in [Double.nan, Double.infinity, -1, 101] { reducer.ingest(sample(40, value), into: &state) }
    check(state.current?.id == id && state.closed.isEmpty, "stable cycle")
    check(state.current?.expectedResetAt == sample(0, 30).resetAt, "original deadline")
    check(state.current?.lastObservedUsedPercent == 32, "reject duplicate, old and invalid")
case "earlyReset":
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    check(state.closed.isEmpty, "candidate must not split")
    reducer.ingest(sample(120, 3, 605800), into: &state)
    check(state.closed.count == 1, "confirmed transition splits")
    check(state.closed.first?.end == .earlyUnknown && state.closed.first?.lastObservedUsedPercent == 72, "old evidence")
    check(state.current?.lastObservedUsedPercent == 3, "new evidence")
case "transitions":
    reducer.ingest(sample(604700, 0), into: &state)
    reducer.ingest(sample(604810, 0, 1209600), into: &state)
    check(state.closed.isEmpty, "natural requires another independent observation")
    reducer.ingest(sample(604830, 0, 1209600), into: &state)
    check(state.closed.first?.end == .natural, "natural zero to zero")
    state = QuotaCycleState()
    reducer.ingest(sample(0, 70), into: &state)
    reducer.ingest(sample(1900000, 1, 2419200), into: &state)
    check(state.closed.count == 1 && state.closed.first?.end == .gap && state.current?.startKind == .afterGap, "long gap does not invent cycles")
    state = QuotaCycleState()
    reducer.ingest(sample(0, 99.6), into: &state)
    check(state.current?.wasObservedFull == false, "rounded full is not full")
    reducer.ingest(sample(10, 20, 600000), into: &state)
    check(state.closed.isEmpty && state.pendingTransition != nil, "deadline rollback is uncertain")
case "reviewBoundaries":
    reducer.ingest(sample(604700, 0), into: &state)
    reducer.ingest(sample(604810, 0), into: &state)
    reducer.ingest(sample(604820, 0, 1209600), into: &state)
    check(state.closed.isEmpty, "old expired reset must await confirmation")
    reducer.ingest(sample(604840, 0, 1209600), into: &state)
    check(state.closed.first?.end == .natural, "expired old reset must not block natural transition")
    check(state.closed.first?.boundaryLower == sample(604810, 0).observedAt && state.closed.first?.boundaryUpper == sample(604820, 0).observedAt, "boundary interval")
    state = QuotaCycleState()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    reducer.ingest(sample(120, 1, 605800), into: &state)
    check(state.closed.isEmpty, "declining new window is not stable")
case "candidates":
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    check(state.closed.isEmpty, "replay cannot confirm")
    reducer.ingest(sample(120, 73), into: &state)
    check(state.closed.isEmpty && state.current?.lastObservedUsedPercent == 73 && state.anomalies.count == 1, "rollback retains anomaly")
    state = QuotaCycleState()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    reducer.ingest(sample(290, 3, 605800), into: &state)
    check(state.closed.isEmpty, "timeout cannot confirm")
    state = QuotaCycleState()
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800, plan: "pro"), into: &state)
    reducer.ingest(sample(120, 3, 605800, plan: "pro"), into: &state)
    check(state.closed.isEmpty && state.pendingTransition?.reason == .planChange, "plan change remains uncertain")
case "redemption":
    reducer.ingest(sample(0, 72), into: &state)
    let id = state.current!.id
    let event = QuotaRedemptionEvidence(operationHash: "hash", originalRequestedAt: t.addingTimeInterval(5), responseAt: t.addingTimeInterval(10), status: .reset, baselineCycleID: id)
    reducer.record(event, into: &state)
    reducer.record(event, into: &state)
    reducer.record(QuotaRedemptionEvidence(operationHash: "hash", originalRequestedAt: nil, responseAt: t.addingTimeInterval(11), status: .alreadyRedeemed, baselineCycleID: id), into: &state)
    check(state.redemptions.count == 1 && state.redemptions[0].status == .reset && state.closed.isEmpty, "dedup preserves reset, no fabricated cycle")
    reducer.ingest(sample(10, 2, 605800), into: &state)
    check(state.closed.isEmpty, "request before response is not post-redemption")
    reducer.ingest(sample(20, 2, 605800), into: &state)
    check(state.closed.count == 1 && state.closed.first?.end == .redeemed, "new sample confirms redemption")
case "redemptionSafety":
    for status: QuotaRedemptionStatus in [.unknown, .nothingToReset, .noCredit, .alreadyRedeemed] {
        var s = QuotaCycleState()
        reducer.ingest(sample(0, 70), into: &s)
        reducer.record(QuotaRedemptionEvidence(operationHash: "operation", originalRequestedAt: nil, responseAt: t.addingTimeInterval(10), status: status, baselineCycleID: s.current!.id), into: &s)
        reducer.ingest(sample(20, 2, 605800), into: &s)
        check(s.closed.isEmpty, "unconfirmed status must not mark redemption")
    }
    reducer.ingest(sample(0, 70), into: &state)
    let event = QuotaRedemptionEvidence(operationHash: "op", originalRequestedAt: t.addingTimeInterval(5), responseAt: t.addingTimeInterval(10), status: .reset, baselineCycleID: state.current!.id)
    reducer.record(event, into: &state)
    reducer.ingest(sample(20, 70), into: &state)
    check(state.closed.isEmpty, "no 7d change means no cycle")
    reducer.ingest(sample(30, 2), into: &state)
    check(state.closed.first?.end == .redeemed, "same deadline and drop can confirm")
case "anomalies":
    reducer.ingest(sample(0, 70), into: &state)
    reducer.ingest(sample(10, 69.5), into: &state)
    check(state.closed.isEmpty && state.pendingTransition?.reason == .anomaly, "same deadline correction retained")
    state = QuotaCycleState()
    reducer.ingest(sample(0, 70), into: &state)
    reducer.ingest(sample(10, 70, 605800), into: &state)
    check(state.closed.isEmpty && state.pendingTransition?.reason == .anomaly, "deadline change alone uncertain")
    state = QuotaCycleState()
    reducer.ingest(sample(0, 70), into: &state)
    reducer.ingest(sample(10, 2, 604900), into: &state)
    check(state.closed.isEmpty && state.pendingTransition?.reason == .anomaly, "jitter and drop alone uncertain")
case "store":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let key = String(repeating: "a", count: 64)
    let store = QuotaCycleStore(root: root) { data, url in try data.write(to: url, options: .atomic) }
    reducer.ingest(sample(0, 43), into: &state)
    do {
        try store.save(state, accountKey: key)
        let loaded = try store.load(accountKey: key)
        check(loaded == state, "roundtrip")
        var pendingState = state
        reducer.ingest(sample(100, 2, 605800), into: &pendingState)
        try store.save(pendingState, accountKey: key)
        let pendingReload = try store.load(accountKey: key)
        check(pendingReload.pendingTransition == pendingState.pendingTransition, "pending survives restart")
        try store.save(state, accountKey: key)
        var ended = QuotaCycleState()
        reducer.ingest(sample(604700, 0), into: &ended)
        reducer.ingest(sample(604810, 0, 1209600), into: &ended)
        reducer.ingest(sample(604830, 0, 1209600), into: &ended)
        let endedKey = String(repeating: "c", count: 64)
        try store.save(ended, accountKey: endedKey)
        let endedReload = try store.load(accountKey: endedKey)
        check(endedReload.closed.first?.end == .natural, "confirmed cycle survives validation and reload")
        let other = try store.load(accountKey: String(repeating: "b", count: 64))
        check(other.current == nil, "partition")
        let path = root.appendingPathComponent(key).appendingPathComponent("history-v1.json")
        let bytes = try Data(contentsOf: path)
        let mode = (try FileManager.default.attributesOfItem(atPath: path.path)[.posixPermissions] as! NSNumber).intValue
        let dirMode = (try FileManager.default.attributesOfItem(atPath: path.deletingLastPathComponent().path)[.posixPermissions] as! NSNumber).intValue
        check(mode & 0o777 == 0o600 && dirMode & 0o777 == 0o700, "permissions")
        let failing = QuotaCycleStore(root: root) { _, _ in throw NSError(domain: "injected", code: 1) }
        do { try failing.save(state, accountKey: key); check(false, "writer must fail") } catch {}
        let afterFailure = try Data(contentsOf: path)
        check(afterFailure == bytes, "writer failure preserves file")
        var duplicate = state
        duplicate.closed = [state.current!, state.current!]
        duplicate.closed[0].end = .natural; duplicate.closed[1].end = .natural
        do { try store.save(duplicate, accountKey: key); check(false, "duplicate IDs") } catch {}
        var invalid = state
        invalid.current?.lastObservedUsedPercent = 101
        do { try store.save(invalid, accountKey: key); check(false, "invalid percent") } catch {}
        var json = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        var corrupt = json
        var badCurrent = corrupt["current"] as! [String: Any]
        badCurrent["lastObservedUsedPercent"] = 101
        corrupt["current"] = badCurrent
        let invalidBytes = try JSONSerialization.data(withJSONObject: corrupt)
        try invalidBytes.write(to: path)
        do { _ = try store.load(accountKey: key); check(false, "invalid decoded number") } catch {}
        do { try store.save(state, accountKey: key); check(false, "invalid file must not be overwritten") } catch {}
        let protected = try Data(contentsOf: path)
        check(protected == invalidBytes, "corrupt file preserved")
        corrupt = json
        var closed = corrupt["current"] as! [String: Any]
        closed["end"] = "natural"
        corrupt["closed"] = [closed]
        try JSONSerialization.data(withJSONObject: corrupt).write(to: path)
        do { _ = try store.load(accountKey: key); check(false, "duplicate decoded IDs") } catch {}
        try bytes.write(to: path)
        json["schemaVersion"] = 2
        let future = try JSONSerialization.data(withJSONObject: json)
        try future.write(to: path)
        do { _ = try store.load(accountKey: key); check(false, "future schema") } catch {}
        do { try store.save(state, accountKey: key); check(false, "do not overwrite future file") } catch {}
        let unchanged = try Data(contentsOf: path)
        check(unchanged == future, "future file remains")
        do { try store.save(state, accountKey: "../escape"); check(false, "reject path") } catch {}
    } catch { check(false, "store error: \(error)") }
case "coordinator":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let lock = NSLock()
    var pending: [() -> Void] = []
    var snapshots: [QuotaCycleSnapshot] = []
    var writes = 0
    let coordinator = QuotaCycleCoordinator(root: root, writer: { data, url in
        writes += 1; try data.write(to: url, options: .atomic)
    }, schedule: { action in lock.lock(); pending.append(action); lock.unlock() }, deliver: { snapshots.append($0) })
    func drain() {
        let signal = DispatchSemaphore(value: 0)
        coordinator.drain { signal.signal() }
        check(signal.wait(timeout: .now() + 5) == .success, "coordinator drain")
    }
    func deliver() {
        lock.lock(); let jobs = pending; pending = []; lock.unlock()
        for job in jobs { job() }
    }
    let a = "account:a|workspace", b = "account:b|workspace"
    coordinator.activate(accountIdentity: a, generation: 1); drain()
    coordinator.observe(sample(0, 91), identity: a, generation: 1); drain()
    coordinator.activate(accountIdentity: b, generation: 2); drain(); deliver()
    check(snapshots.allSatisfy { $0.state.current == nil }, "old account load/data never delivered")
    snapshots = []
    coordinator.observe(sample(0, 20), identity: a, generation: 1)
    coordinator.observe(sample(0, 30), identity: b, generation: 2); drain(); deliver()
    check(snapshots.last?.state.current?.lastObservedUsedPercent == 30, "accepted current account")
    let initialWrites = writes
    for i in 1...20 { coordinator.observe(sample(Double(i * 10), 30), identity: b, generation: 2) }
    drain(); deliver()
    check(writes == initialWrites, "repeated polls do not write")
    coordinator.observe(sample(310, 30), identity: b, generation: 2); drain(); deliver()
    check(writes == initialWrites + 1, "heartbeat write (initial=\(initialWrites), writes=\(writes), saved=\(snapshots.last?.isSaved as Any))")
    check(snapshots.last?.state.current?.evidence.count == 1, "duplicate evidence suppressed")
    snapshots = []
    coordinator.activate(accountIdentity: b, generation: 3); drain(); deliver()
    check(!snapshots.contains(where: { $0.isLoading }) && snapshots.last?.state.current?.lastObservedUsedPercent == 30, "same identity generation preserves state")
    coordinator.observe(sample(320, 40), identity: b, generation: 2); drain(); deliver()
    check(snapshots.last?.state.current?.lastObservedUsedPercent == 30, "old generation refused")
    let operation = QuotaRedemptionEvidence(operationHash: QuotaCycleCoordinator.operationHash("test"), originalRequestedAt: t.addingTimeInterval(315), responseAt: t.addingTimeInterval(316), status: .reset, baselineCycleID: snapshots.last?.state.current?.id)
    coordinator.recordRedemption(operation, identity: b, generation: 3)
    coordinator.activate(accountIdentity: b, generation: 4); drain(); deliver()
    check(snapshots.last?.state.redemptions.count == 1 && snapshots.last?.state.current?.lastObservedUsedPercent == 30, "generation preserves redemption and current state")
    let before = writes
    coordinator.activate(accountIdentity: "token:unstable", generation: 5)
    coordinator.observe(sample(400, 90), identity: "token:unstable", generation: 5); drain(); deliver()
    check(writes == before, "unstable identity cannot write")
case "browser":
    for count in [0, 1, 5, 6, 7, 12, 13, 25] {
        var records: [QuotaCycleRecord] = []
        for i in 0..<count {
            var s = QuotaCycleState(); reducer.ingest(sample(Double(i * 1000), 10), into: &s)
            records.append(s.current!)
        }
        var browser = QuotaCycleBrowser(); browser.update(records)
        check(browser.visible.count == min(6, count), "latest page")
        if count > 6 {
            browser.earlier()
            check(browser.visible.last?.id == records[count - 7].id, "earlier page anchor")
            let fixed = browser.visible.map(\.id)
            var s = QuotaCycleState(); reducer.ingest(sample(30000, 50), into: &s)
            browser.update(records + [s.current!])
            check(browser.visible.map(\.id) == fixed, "historical page stable after refresh")
            browser.newer()
            check(browser.visible.last?.id == s.current!.id, "newer reaches latest")
        }
    }
case "coordinatorFailure":
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var fail = true
    var writes = 0
    var latest: QuotaCycleSnapshot?
    let c = QuotaCycleCoordinator(root: root, writer: { data, url in
        writes += 1
        if fail { throw NSError(domain: "failure", code: 1) }
        try data.write(to: url, options: .atomic)
    }, schedule: { $0() }, deliver: { latest = $0 })
    func wait() { let sem = DispatchSemaphore(value: 0); c.drain { sem.signal() }; check(sem.wait(timeout: .now() + 5) == .success, "wait") }
    let identity = "account:failure|workspace"
    c.activate(accountIdentity: identity, generation: 1); wait()
    c.observe(sample(0, 5), identity: identity, generation: 1); wait()
    check(latest?.isSaved == false && latest?.state.current != nil, "failed writer keeps in-memory state")
    fail = false
    c.observe(sample(10, 5), identity: identity, generation: 1); wait()
    check(latest?.isSaved == true && writes == 2, "later retry recovers")
    let key = QuotaCycleCoordinator.accountKey(identity)!
    let path = root.appendingPathComponent(key).appendingPathComponent("history-v1.json")
    let bad = Data("not JSON".utf8); try! bad.write(to: path)
    let c2 = QuotaCycleCoordinator(root: root, writer: { _, _ in check(false, "corrupt partition must never be overwritten") }, schedule: { $0() }, deliver: { latest = $0 })
    func wait2() { let sem = DispatchSemaphore(value: 0); c2.drain { sem.signal() }; check(sem.wait(timeout: .now() + 5) == .success, "wait2") }
    c2.activate(accountIdentity: identity, generation: 2); wait2()
    c2.observe(sample(20, 10), identity: identity, generation: 2); wait2()
    check(latest?.isSaved == false && (try! Data(contentsOf: path)) == bad, "corrupt file preserved")
default: exit(2)
}
