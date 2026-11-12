import Foundation

struct QuotaObservation: Codable, Equatable {
    let requestStartedAt: Date
    let observedAt: Date
    let usedPercent: Double
    let resetAt: Date
    let planType: String?
    var isValid: Bool {
        requestStartedAt <= observedAt && usedPercent.isFinite && (0...100).contains(usedPercent)
            && [requestStartedAt, observedAt, resetAt].allSatisfy { $0.timeIntervalSince1970.isFinite }
    }
}
enum QuotaCycleEnd: String, Codable { case natural, redeemed, earlyUnknown, gap, unconfirmed }
enum QuotaCycleStart: String, Codable { case inferred, observedTransition, redeemed, afterGap }
struct QuotaCycleRecord: Codable, Equatable, Identifiable {
    let id: UUID
    var startKind: QuotaCycleStart
    var inferredStartAt: Date?
    var firstObservedAt: Date
    var expectedResetAt: Date
    var lastObservedAt: Date
    var lastObservedUsedPercent: Double
    var boundaryLower: Date?
    var boundaryUpper: Date?
    var end: QuotaCycleEnd?
    var incomplete: Bool
    var evidence: [QuotaObservation]
    var remainingAtLastObservation: Double { max(0, min(100, 100 - lastObservedUsedPercent)) }
    var wasObservedFull: Bool { lastObservedUsedPercent == 100 }
}
enum QuotaRedemptionStatus: String, Codable { case requested, reset, alreadyRedeemed, unknown, nothingToReset, noCredit }
struct QuotaRedemptionEvidence: Codable, Equatable {
    let operationHash: String
    let originalRequestedAt: Date?
    let responseAt: Date
    let status: QuotaRedemptionStatus
    let baselineCycleID: UUID?
}
struct QuotaCyclePolicy {
    var resetJitter: TimeInterval = 120
    var meaningfulDrop: Double = 1
    var confirmationMinDelay: TimeInterval = 10
    var confirmationMaxDelay: TimeInterval = 180
    var maximumContinuousGap: TimeInterval = 15 * 60
    var heartbeatInterval: TimeInterval = 5 * 60
}
enum QuotaPendingReason: String, Codable { case early, anomaly, planChange }
struct QuotaPendingTransition: Codable, Equatable {
    let baselineCycleID: UUID
    let first: QuotaObservation
    let reason: QuotaPendingReason
}
struct QuotaCycleState: Codable, Equatable {
    var schemaVersion = 1
    var closed: [QuotaCycleRecord] = []
    var current: QuotaCycleRecord?
    var previous: QuotaObservation?
    var lastRequestStartedAt: Date?
    var pendingTransition: QuotaPendingTransition?
    var redemptions: [QuotaRedemptionEvidence] = []
    var anomalies: [QuotaObservation] = []
}
struct QuotaCycleReducer {
    let policy: QuotaCyclePolicy
    private func makeCycle(_ sample: QuotaObservation, kind: QuotaCycleStart) -> QuotaCycleRecord {
        QuotaCycleRecord(id: UUID(), startKind: kind,
            inferredStartAt: kind == .inferred ? sample.resetAt.addingTimeInterval(-604800) : nil,
            firstObservedAt: sample.observedAt, expectedResetAt: sample.resetAt,
            lastObservedAt: sample.observedAt, lastObservedUsedPercent: sample.usedPercent,
            boundaryLower: nil, boundaryUpper: nil, end: nil, incomplete: kind == .inferred || kind == .afterGap,
            evidence: [sample])
    }
    private func close(_ state: inout QuotaCycleState, first: QuotaObservation, reason: QuotaCycleEnd, kind: QuotaCycleStart) {
        guard var old = state.current else { return }
        old.end = reason
        old.boundaryLower = old.lastObservedAt
        old.boundaryUpper = first.observedAt
        state.closed.append(old)
        state.current = makeCycle(first, kind: kind)
        state.pendingTransition = nil
    }
    func record(_ event: QuotaRedemptionEvidence, into state: inout QuotaCycleState) {
        guard !event.operationHash.isEmpty, event.responseAt.timeIntervalSince1970.isFinite,
              event.originalRequestedAt.map({ $0.timeIntervalSince1970.isFinite && $0 <= event.responseAt }) ?? true else { return }
        if let index = state.redemptions.firstIndex(where: { $0.operationHash == event.operationHash }) {
            let old = state.redemptions[index]
            // An idempotency response cannot replace a previously observed fresh reset.
            if old.status == .reset { return }
            guard event.responseAt >= old.responseAt else { return }
            state.redemptions[index] = QuotaRedemptionEvidence(operationHash: event.operationHash,
                originalRequestedAt: old.originalRequestedAt ?? event.originalRequestedAt,
                responseAt: event.responseAt, status: event.status,
                baselineCycleID: old.baselineCycleID ?? event.baselineCycleID)
        } else { state.redemptions.append(event) }
    }
    func ingest(_ sample: QuotaObservation, into state: inout QuotaCycleState) {
        guard sample.isValid, state.lastRequestStartedAt.map({ sample.requestStartedAt > $0 }) ?? true,
              state.previous.map({ sample.observedAt >= $0.observedAt }) ?? true else { return }
        state.lastRequestStartedAt = sample.requestStartedAt
        guard var current = state.current, let previous = state.previous else {
            state.current = makeCycle(sample, kind: .inferred)
            state.previous = sample
            return
        }
        let changed = abs(sample.resetAt.timeIntervalSince(current.expectedResetAt)) > policy.resetJitter
        let samePlan = current.evidence.last?.planType == sample.planType
        if samePlan, let redemption = state.redemptions.last(where: {
            $0.status == .reset && $0.baselineCycleID == current.id &&
            $0.originalRequestedAt != nil && sample.requestStartedAt >= $0.responseAt
        }), redemption.originalRequestedAt! >= current.firstObservedAt,
           (changed || current.lastObservedUsedPercent - sample.usedPercent >= policy.meaningfulDrop),
           sample.observedAt.timeIntervalSince(current.lastObservedAt) <= policy.maximumContinuousGap {
            close(&state, first: sample, reason: .redeemed, kind: .redeemed)
            state.previous = sample
            return
        }
        if changed && samePlan && sample.observedAt.timeIntervalSince(current.lastObservedAt) > policy.maximumContinuousGap {
            close(&state, first: sample, reason: .gap, kind: .afterGap)
            state.previous = sample
            return
        }
        if changed && !samePlan {
            state.anomalies.append(sample)
            state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: sample, reason: .planChange)
            state.previous = sample
            return
        }
        if let pending = state.pendingTransition, pending.reason == .early {
            let delay = sample.observedAt.timeIntervalSince(pending.first.observedAt)
            let stable = abs(sample.resetAt.timeIntervalSince(pending.first.resetAt)) <= policy.resetJitter
            if stable && delay >= policy.confirmationMinDelay && delay <= policy.confirmationMaxDelay && sample.usedPercent < current.lastObservedUsedPercent && samePlan {
                close(&state, first: pending.first, reason: .earlyUnknown, kind: .observedTransition)
                current = state.current!
                current.lastObservedAt = sample.observedAt
                current.lastObservedUsedPercent = sample.usedPercent
                current.evidence.append(sample)
                state.current = current
                state.previous = sample
                return
            }
            if delay > policy.confirmationMaxDelay || !stable { state.pendingTransition = nil }
            else { state.previous = sample; return }
        }
        if changed && sample.resetAt > current.expectedResetAt && previous.observedAt <= current.expectedResetAt && sample.observedAt >= current.expectedResetAt && samePlan {
            close(&state, first: sample, reason: .natural, kind: .observedTransition)
        } else if changed && sample.resetAt > current.expectedResetAt && sample.observedAt < current.expectedResetAt && current.lastObservedUsedPercent - sample.usedPercent >= policy.meaningfulDrop && samePlan {
            state.anomalies.append(sample)
            state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: sample, reason: .early)
        } else if changed || sample.usedPercent < current.lastObservedUsedPercent {
            state.anomalies.append(sample)
            state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: sample, reason: .anomaly)
        } else {
            state.pendingTransition = nil
            current.lastObservedAt = sample.observedAt
            current.lastObservedUsedPercent = sample.usedPercent
            current.evidence.append(sample)
            state.current = current
        }
        state.previous = sample
    }
}
