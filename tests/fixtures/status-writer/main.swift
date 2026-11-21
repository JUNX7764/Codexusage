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
