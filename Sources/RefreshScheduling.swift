import Foundation

/// Owned by AppDelegate on the main thread. Keep the five-minute cadence even if
/// a quota request overlaps a deadline. Several missed deadlines coalesce.
struct RefreshSchedule {
    enum Work: Equatable { case quota, full }
    private let interval: TimeInterval = 300
    private var nextDue: Date?
    private var lastTick: Date?
    private var active = false
    private var pendingFull = false

    mutating func request(manual: Bool, now: Date) -> Work? {
        if let last = lastTick, now < last { nextDue = nil }
        lastTick = now
        let due = nextDue.map { now >= $0 } ?? true
        if due {
            let previous = nextDue ?? now
            let intervals = floor(now.timeIntervalSince(previous) / interval) + 1
            nextDue = previous.addingTimeInterval(intervals * interval)
        }
        let full = manual || due
        if active {
            pendingFull = pendingFull || full
            return nil
        }
        active = true
        return full ? .full : .quota
    }

    mutating func finish() -> Work? {
        if pendingFull {
            pendingFull = false
            return .full
        }
        active = false
        return nil
    }
}

/// Coalesces immutable snapshots received while storage is busy. Encoding, I/O
/// and successful-write deduplication are owned by the serial writer queue.
/// Optional `volatileKeys` (e.g. `lastAttemptAt`) are excluded from the deduplication
/// digest so idle polls do not rewrite disk; a full snapshot is still persisted
/// whenever any non-volatile field changes or `heartbeatInterval` elapses.
final class StatusSnapshotWriter {
    typealias Snapshot = [String: Any]
    private let queue = DispatchQueue(label: "com.local.codex-usage.status", qos: .utility)
    private let lock = NSLock()
    private var pending: Snapshot?
    private var running = false
    private var savedDigest: Data?
    private var lastWrittenAt: Date?
    private let volatileKeys: Set<String>
    private let heartbeatInterval: TimeInterval
    private let now: () -> Date
    private let write: (Data) throws -> Void

    init(volatileKeys: Set<String> = [],
         heartbeatInterval: TimeInterval = 300,
         now: @escaping () -> Date = Date.init,
         write: @escaping (Data) throws -> Void) {
        self.volatileKeys = volatileKeys
        self.heartbeatInterval = heartbeatInterval
        self.now = now
        self.write = write
    }

    func submit(_ snapshot: Snapshot) {
        lock.lock()
        pending = snapshot
        let start = !running
        running = true
        lock.unlock()
        if start { queue.async { self.drainPending() } }
    }

    private func drainPending() {
        while true {
            lock.lock()
            guard let snapshot = pending else {
                running = false
                lock.unlock()
                return
            }
            pending = nil
            lock.unlock()
            do {
                let digest: Data
                let preEncoded: Data?
                if volatileKeys.isEmpty {
                    let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted])
                    digest = data
                    preEncoded = data
                } else {
                    var semantic = snapshot
                    for key in volatileKeys { semantic.removeValue(forKey: key) }
                    digest = try JSONSerialization.data(withJSONObject: semantic, options: [.sortedKeys])
                    preEncoded = nil
                }
                let timestamp = now()
                let heartbeatDue = !volatileKeys.isEmpty && (lastWrittenAt.map {
                    let elapsed = timestamp.timeIntervalSince($0)
                    return elapsed >= heartbeatInterval || elapsed < 0
                } ?? true)
                if digest != savedDigest || heartbeatDue {
                    let data = try preEncoded ?? JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted])
                    try write(data)
                    savedDigest = digest
                    lastWrittenAt = timestamp
                }
            } catch {
                NSLog("[CodexUsage] status write failed: %@", error.localizedDescription)
            }
        }
    }

    func waitForWrites() { queue.sync {} }
}
