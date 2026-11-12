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
struct QuotaCycleState: Codable, Equatable {
    var schemaVersion = 1
    var closed: [QuotaCycleRecord] = []
    var current: QuotaCycleRecord?
    var previous: QuotaObservation?
    var lastRequestStartedAt: Date?
}
struct QuotaCycleReducer {
    let policy: QuotaCyclePolicy
    func ingest(_ sample: QuotaObservation, into state: inout QuotaCycleState) {
        guard sample.isValid, state.lastRequestStartedAt.map({ sample.requestStartedAt > $0 }) ?? true else { return }
        state.lastRequestStartedAt = sample.requestStartedAt
        guard var current = state.current else {
            state.current = QuotaCycleRecord(id: UUID(), startKind: .inferred, inferredStartAt: sample.resetAt.addingTimeInterval(-604800), firstObservedAt: sample.observedAt, expectedResetAt: sample.resetAt, lastObservedAt: sample.observedAt, lastObservedUsedPercent: sample.usedPercent, boundaryLower: nil, boundaryUpper: nil, end: nil, incomplete: true, evidence: [sample])
            state.previous = sample
            return
        }
        if abs(sample.resetAt.timeIntervalSince(current.expectedResetAt)) <= policy.resetJitter && sample.usedPercent >= current.lastObservedUsedPercent {
            current.lastObservedAt = sample.observedAt
            current.lastObservedUsedPercent = sample.usedPercent
            current.evidence.append(sample)
            state.current = current
            state.previous = sample
        }
    }
}
