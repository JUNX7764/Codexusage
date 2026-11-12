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
case "redemption":
    reducer.ingest(sample(0, 72), into: &state)
    let id = state.current!.id
    let event = QuotaRedemptionEvidence(operationHash: "hash", originalRequestedAt: t.addingTimeInterval(5), responseAt: t.addingTimeInterval(10), status: .reset, baselineCycleID: id)
    reducer.record(event, into: &state)
    reducer.record(event, into: &state)
    reducer.record(QuotaRedemptionEvidence(operationHash: "hash", originalRequestedAt: nil, responseAt: t.addingTimeInterval(11), status: .alreadyRedeemed, baselineCycleID: id), into: &state)
    check(state.redemptions.count == 1 && state.closed.isEmpty, "dedup, no fabricated cycle")
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
default: exit(2)
}
