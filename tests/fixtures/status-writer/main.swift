import Foundation

let writing = DispatchSemaphore(value: 0)
let resume = DispatchSemaphore(value: 0)
var events: [Int] = []
let writer = StatusSnapshotWriter { data in
    precondition(!Thread.isMainThread)
    let snapshot = try JSONSerialization.jsonObject(with: data) as! [String: Int]
    let value = snapshot["generation"]!
    if events.isEmpty {
        writing.signal()
        precondition(resume.wait(timeout: .now() + 5) == .success)
    }
    events.append(value)
    if events == [1, 3] { throw CocoaError(.fileWriteUnknown) }
}
writer.submit(["generation": 1])
precondition(writing.wait(timeout: .now() + 5) == .success)
writer.submit(["generation": 2])
writer.submit(["generation": 3])
resume.signal()
writer.waitForWrites()
writer.submit(["generation": 3])
writer.waitForWrites()
writer.submit(["generation": 3])
writer.waitForWrites()
precondition(events == [1, 3, 3], "busy snapshots, retry, or write deduplication failed")

// Volatile key deduplication + heartbeat + semantic change immediate write
var clock = Date(timeIntervalSince1970: 1_700_000_000)
let clockLock = NSLock()
func currentClock() -> Date { clockLock.lock(); defer { clockLock.unlock() }; return clock }
func advanceClock(_ seconds: TimeInterval) { clockLock.lock(); clock = clock.addingTimeInterval(seconds); clockLock.unlock() }

var persisted: [[String: String]] = []
let volatileWriter = StatusSnapshotWriter(volatileKeys: ["lastAttemptAt"], heartbeatInterval: 300, now: currentClock) { data in
    precondition(!Thread.isMainThread)
    let obj = try JSONSerialization.jsonObject(with: data) as! [String: String]
    persisted.append(obj)
}

// 1. Initial write persists full snapshot including volatile key
volatileWriter.submit(["line1": "5H 80%", "lastAttemptAt": "2026-11-25T00:00:00Z"])
volatileWriter.waitForWrites()
precondition(persisted.count == 1 && persisted[0]["lastAttemptAt"] == "2026-11-25T00:00:00Z", "initial volatile write failed")

// 2. Snapshots differing only in lastAttemptAt within heartbeat window do NOT write
advanceClock(10)
volatileWriter.submit(["line1": "5H 80%", "lastAttemptAt": "2026-11-25T00:00:10Z"])
volatileWriter.waitForWrites()
advanceClock(280)
volatileWriter.submit(["line1": "5H 80%", "lastAttemptAt": "2026-11-25T00:04:50Z"])
volatileWriter.waitForWrites()
precondition(persisted.count == 1, "volatile-only changes triggered redundant disk writes")

// 3. After heartbeat interval elapses, write occurs with latest lastAttemptAt
advanceClock(15)
volatileWriter.submit(["line1": "5H 80%", "lastAttemptAt": "2026-11-25T00:05:05Z"])
volatileWriter.waitForWrites()
precondition(persisted.count == 2 && persisted[1]["lastAttemptAt"] == "2026-11-25T00:05:05Z", "heartbeat write did not fire")

// 4. Semantic field change within heartbeat window writes immediately
advanceClock(10)
volatileWriter.submit(["line1": "5H 75%", "lastAttemptAt": "2026-11-25T00:05:15Z"])
volatileWriter.waitForWrites()
precondition(persisted.count == 3 && persisted[2]["line1"] == "5H 75%" && persisted[2]["lastAttemptAt"] == "2026-11-25T00:05:15Z",
             "semantic change did not write immediately")
