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
enum QuotaCycleStart: String, Codable { case inferred, observedTransition, redeemed, afterGap, afterPlanChange }
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
enum QuotaPendingReason: String, Codable { case early, natural, anomaly, planChange }
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
            boundaryLower: nil, boundaryUpper: nil, end: nil, incomplete: kind == .inferred || kind == .afterGap || kind == .afterPlanChange,
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
    private func appendAnomaly(_ sample: QuotaObservation, into state: inout QuotaCycleState) {
        if let last = state.anomalies.last, last.usedPercent == sample.usedPercent &&
            last.planType == sample.planType && abs(last.resetAt.timeIntervalSince(sample.resetAt)) <= policy.resetJitter { return }
        state.anomalies.append(sample)
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
        guard var current = state.current, state.previous != nil else {
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
            if let pending = state.pendingTransition, pending.reason == .planChange {
                let delay = sample.observedAt.timeIntervalSince(pending.first.observedAt)
                let stable = pending.first.planType != nil && sample.planType == pending.first.planType &&
                    abs(sample.resetAt.timeIntervalSince(pending.first.resetAt)) <= policy.resetJitter &&
                    sample.usedPercent >= pending.first.usedPercent
                if stable && delay >= policy.confirmationMinDelay && delay <= policy.confirmationMaxDelay {
                    close(&state, first: pending.first, reason: .unconfirmed, kind: .afterPlanChange)
                    current = state.current!
                    current.lastObservedAt = sample.observedAt
                    current.lastObservedUsedPercent = sample.usedPercent
                    if sample.usedPercent != pending.first.usedPercent { current.evidence.append(sample) }
                    state.current = current
                    state.previous = sample
                    return
                }
                if stable && delay < policy.confirmationMinDelay { state.previous = sample; return }
            }
            appendAnomaly(sample, into: &state)
            state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: sample, reason: .planChange)
            state.previous = sample
            return
        }
        if let pending = state.pendingTransition, pending.reason == .early || pending.reason == .natural {
            let delay = sample.observedAt.timeIntervalSince(pending.first.observedAt)
            let stable = abs(sample.resetAt.timeIntervalSince(pending.first.resetAt)) <= policy.resetJitter
            if stable && delay >= policy.confirmationMinDelay && delay <= policy.confirmationMaxDelay && sample.usedPercent >= pending.first.usedPercent && (pending.reason == .natural || sample.usedPercent < current.lastObservedUsedPercent) && samePlan {
                close(&state, first: pending.first, reason: pending.reason == .natural ? .natural : .earlyUnknown, kind: .observedTransition)
                current = state.current!
                current.lastObservedAt = sample.observedAt
                current.lastObservedUsedPercent = sample.usedPercent
                if sample.usedPercent != pending.first.usedPercent || sample.planType != pending.first.planType {
                    current.evidence.append(sample)
                }
                state.current = current
                state.previous = sample
                return
            }
            if stable && sample.usedPercent < pending.first.usedPercent {
                appendAnomaly(sample, into: &state)
                state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: sample, reason: pending.reason)
                state.previous = sample
                return
            }
            if delay > policy.confirmationMaxDelay || !stable { state.pendingTransition = nil }
            else { state.previous = sample; return }
        }
        if changed && sample.resetAt > current.expectedResetAt && sample.observedAt >= current.expectedResetAt && samePlan {
            state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: sample, reason: .natural)
        } else if changed && sample.resetAt > current.expectedResetAt && sample.observedAt < current.expectedResetAt && current.lastObservedUsedPercent - sample.usedPercent >= policy.meaningfulDrop && samePlan {
            appendAnomaly(sample, into: &state)
            state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: sample, reason: .early)
        } else if changed || sample.usedPercent < current.lastObservedUsedPercent {
            appendAnomaly(sample, into: &state)
            state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: sample, reason: .anomaly)
        } else {
            state.pendingTransition = nil
            current.lastObservedAt = sample.observedAt
            current.lastObservedUsedPercent = sample.usedPercent
            if let last = current.evidence.last, last.usedPercent == sample.usedPercent,
               last.planType == sample.planType,
               abs(last.resetAt.timeIntervalSince(sample.resetAt)) <= policy.resetJitter {
                // Keep the original evidence; lastObservedAt tracks the heartbeat.
            } else { current.evidence.append(sample) }
            state.current = current
        }
        state.previous = sample
    }
}

// UI state stays outside the persisted history and is keyed by stable cycle IDs.
struct QuotaCycleBrowser {
    private(set) var records: [QuotaCycleRecord] = []
    private(set) var visibleLimit = 12
    private(set) var olderPage = 0
    private(set) var selectedCycleID: UUID?
    private var pageAnchor: UUID?
    var visible: [QuotaCycleRecord] {
        guard !records.isEmpty else { return [] }
        let upper: Int
        if let anchor = pageAnchor, let index = records.firstIndex(where: { $0.id == anchor }) { upper = index + 1 }
        else { upper = max(0, records.count - olderPage * 6) }
        let lowerLimit = max(0, records.count - visibleLimit)
        return Array(records[max(lowerLimit, upper - 6)..<max(lowerLimit, upper)])
    }
    mutating func update(_ newRecords: [QuotaCycleRecord]) {
        if pageAnchor != nil && newRecords.count > records.count { visibleLimit += newRecords.count - records.count }
        records = newRecords
        if let id = selectedCycleID, !records.contains(where: { $0.id == id }) { selectedCycleID = nil }
        if selectedCycleID == nil { selectedCycleID = records.last?.id }
        if let id = pageAnchor, !records.contains(where: { $0.id == id }) { pageAnchor = nil; olderPage = 0 }
    }
    mutating func select(_ id: UUID) { if records.contains(where: { $0.id == id }) { selectedCycleID = id } }
    mutating func earlier() {
        guard let first = visible.first, let index = records.firstIndex(where: { $0.id == first.id }), index > max(0, records.count - visibleLimit) else { return }
        pageAnchor = records[index - 1].id; olderPage += 1
    }
    mutating func newer() {
        guard olderPage > 0, let last = visible.last, let index = records.firstIndex(where: { $0.id == last.id }) else { return }
        let next = min(records.count - 1, index + 6)
        olderPage -= 1
        pageAnchor = olderPage == 0 ? nil : records[next].id
    }
    mutating func loadEarlier() { visibleLimit = min(records.count, visibleLimit + 12) }
}
