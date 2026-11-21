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
        if lastTick.map({ now < $0 }) == true { nextDue = nil }
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
final class StatusSnapshotWriter {
    typealias Snapshot = [String: Any]
    private let queue = DispatchQueue(label: "com.local.codex-usage.status", qos: .utility)
    private let lock = NSLock()
    private var pending: Snapshot?
    private var running = false
    private var saved: Data?
    private let write: (Data) throws -> Void

    init(write: @escaping (Data) throws -> Void) { self.write = write }

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
                let data = try JSONSerialization.data(withJSONObject: snapshot, options: [.sortedKeys, .prettyPrinted])
                if data != saved {
                    try write(data)
                    saved = data
                }
            } catch {
                NSLog("[CodexUsage] status write failed: %@", error.localizedDescription)
            }
        }
    }

    func waitForWrites() { queue.sync {} }
}
