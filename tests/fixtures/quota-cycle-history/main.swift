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
default: exit(2)
}
