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
enum QuotaPendingReason: String, Codable { case early, natural, anomaly, planChange, gap }
struct QuotaPendingTransition: Codable, Equatable {
    let baselineCycleID: UUID
    let first: QuotaObservation
    let reason: QuotaPendingReason
}
struct QuotaCycleState: Codable, Equatable {
    var schemaVersion = 3
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
        state.anomalies = Self.compressedAnomalies(state.anomalies + [sample], policy: policy)
    }
    // 滑动 resetAt 期间服务端返回 observedAt+7d，相邻采样 resetAt 漂移 ~130s：同用量、同套餐且漂移
    // 未超过最大连续缺口的连续异常属于同一次滑动-idle，仅保留最新一条；真实的 reset 跳变（Δ 大）
    // 或用量/套餐变化仍逐条保留。reducer 与 v1→v2 存量迁移共用。
    static func compressedAnomalies(_ anomalies: [QuotaObservation], policy: QuotaCyclePolicy) -> [QuotaObservation] {
        var result: [QuotaObservation] = []
        for sample in anomalies {
            if let last = result.last, last.usedPercent == sample.usedPercent, last.planType == sample.planType,
               abs(last.resetAt.timeIntervalSince(sample.resetAt)) <= policy.maximumContinuousGap {
                result[result.count - 1] = sample
            } else { result.append(sample) }
        }
        return result
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
        let elapsed = sample.observedAt.timeIntervalSince(previous.observedAt)
        let resetDrift = sample.resetAt.timeIntervalSince(previous.resetAt)
        // A moving seven-day deadline is not a boundary. Compare successive samples,
        // including short polling intervals that are smaller than resetJitter.
        let sliding = elapsed > 0 && elapsed <= policy.maximumContinuousGap &&
            abs(resetDrift - elapsed) <= 3 && previous.planType == sample.planType &&
            previous.usedPercent == sample.usedPercent && resetDrift > 0
        if sliding && (state.pendingTransition == nil || state.pendingTransition?.reason == .anomaly || state.pendingTransition?.reason == .gap) {
            current.expectedResetAt = sample.resetAt
            current.lastObservedAt = sample.observedAt
            current.lastObservedUsedPercent = sample.usedPercent
            if state.pendingTransition?.reason == .anomaly || state.pendingTransition?.reason == .gap {
                state.pendingTransition = nil
            }
            state.current = current
            state.previous = sample
            return
        }
        let samePlan = current.evidence.last?.planType == sample.planType
        if samePlan, let redemption = state.redemptions.last(where: {
            $0.status == .reset && $0.baselineCycleID == current.id &&
            $0.originalRequestedAt != nil && sample.requestStartedAt >= $0.responseAt &&
            sample.requestStartedAt.timeIntervalSince($0.responseAt) <= policy.confirmationMaxDelay &&
            sample.requestStartedAt < current.expectedResetAt
        }), redemption.originalRequestedAt! >= current.firstObservedAt,
           (changed || current.lastObservedUsedPercent - sample.usedPercent >= policy.meaningfulDrop),
           sample.observedAt.timeIntervalSince(current.lastObservedAt) <= policy.maximumContinuousGap {
            close(&state, first: sample, reason: .redeemed, kind: .redeemed)
            state.previous = sample
            return
        }
        // .gap 二段确认：观测缺口候选须下一个稳定采样证实（resetAt 稳定、确认窗口 10~180s）才真正关闭。
        // 滑动 resetAt 期间每个新采样的 reset 都在漂移，候选被逐轮替换，永不关闭——与 GLM 的
        // pending 替换语义一致，修复「每 15 分钟关闭一轮伪周期」的缺陷。
        // 注意：delay 上限（confirmationMaxDelay）与轮询节奏（~120-130s）硬耦合——reset 已稳定但
        // 轮询持续 >180s 时，候选在「清除→重武装」中循环、gap 永不关闭（无伪周期，仅关闭延迟）；
        // 若未来调整轮询间隔，需同步评估确认窗口上下限。
        if let pending = state.pendingTransition, pending.reason == .gap {
            let stable = abs(sample.resetAt.timeIntervalSince(pending.first.resetAt)) <= policy.resetJitter
                && sample.planType == pending.first.planType
            let delay = sample.observedAt.timeIntervalSince(pending.first.observedAt)
            if stable && delay >= policy.confirmationMinDelay && delay <= policy.confirmationMaxDelay && samePlan {
                if current.evidence.allSatisfy({ $0.usedPercent == 0 }) {
                    // 口径：全程 0% 的窗口不产生历史柱——真实重置边界已由前一周期的自然到期保留，
                    // 锚定即「缺口后首次观测」；与迁移剔除签名同一取舍。丢弃旧 current（不压入 closed），
                    // 以锚定样本重启当前窗口，避免「真实重置 → idle 滑动 → 首次用量重锚定」每周复现
                    // observedTransition/gap 0% 碎片柱。
                    state.current = makeCycle(pending.first, kind: .afterGap)
                    state.pendingTransition = nil
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
                close(&state, first: pending.first, reason: .gap, kind: .afterGap)
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
            if stable && delay < policy.confirmationMinDelay { state.previous = sample; return }
            // 不稳定（reset 继续漂移或套餐变化）或超过确认窗口：清除候选，让下方最新样本重新武装。
            state.pendingTransition = nil
        }
        // 观测缺口只武装候选，不再以冻结的 lastObservedAt 为基准即时关闭。
        if changed && samePlan && sample.observedAt.timeIntervalSince(current.lastObservedAt) > policy.maximumContinuousGap {
            state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: sample, reason: .gap)
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
