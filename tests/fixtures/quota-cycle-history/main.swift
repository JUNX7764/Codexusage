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
case "candidates":
    reducer.ingest(sample(0, 72), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    reducer.ingest(sample(100, 2, 605800), into: &state)
    check(state.closed.isEmpty, "replay cannot confirm")
    reducer.ingest(sample(120, 73), into: &state)
    check(state.closed.isEmpty && state.current?.lastObservedUsedPercent == 73, "rollback")
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
default: exit(2)
}
