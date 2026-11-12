import Cocoa
import Foundation
import SQLite3
import CoreFoundation
import Darwin
import CryptoKit

enum CodexNumber {
    static func finite(_ value: Any?) -> Double? {
        if let text = value as? String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty, let number = Double(trimmed), number.isFinite else { return nil }
            return number
        }
        guard let number = value as? NSNumber,
              CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
        let result = number.doubleValue
        return result.isFinite ? result : nil
    }

    static func nonnegativeInteger(_ value: Any?) -> Int? {
        guard let number = finite(value), number >= 0,
              number.rounded(.towardZero) == number else { return nil }
        return Int(exactly: number)
    }
}

enum AtomicJSONFile {
    static func replace(_ data: Data, at path: String) throws {
        let directory = (path as NSString).deletingLastPathComponent
        // 目录缺失时显式收权到仅所有者（凭据与状态文件都不应给其他用户留读面）
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let existingMode = (try? FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)
            .map { Int16(truncating: $0) }
        let requested = existingMode ?? 0o600
        let safeMode = requested & 0o600 == 0 ? 0o600 : requested & 0o600
        let temp = directory + "/." + (path as NSString).lastPathComponent + "." + UUID().uuidString + ".tmp"
        let fd = open(temp, O_WRONLY | O_CREAT | O_EXCL, mode_t(0o600))
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        var fdOpen = true
        var shouldRemove = true
        defer {
            if fdOpen { _ = close(fd) }
            if shouldRemove { _ = unlink(temp) }
        }
        var offset = 0
        try data.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            while offset < data.count {
                let count = write(fd, base.advanced(by: offset), data.count - offset)
                if count < 0 {
                    if errno == EINTR { continue }
                    throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
                }
                guard count > 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(EIO)) }
                offset += count
            }
        }
        guard fchmod(fd, mode_t(safeMode)) == 0, fsync(fd) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard close(fd) == 0 else {
            fdOpen = false
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        fdOpen = false
        guard rename(temp, path) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        shouldRemove = false
    }
}

final class RefreshGate {
    private let lock = NSLock()
    private var active = false
    private var queuedManual = false

    func begin(manual: Bool) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard !active else { if manual { queuedManual = true }; return false }
        active = true
        return true
    }

    func finish() -> Bool {
        lock.lock(); defer { lock.unlock() }
        if queuedManual { queuedManual = false; return true }
        active = false
        return false
    }
}

enum CodexFreshness {
    static func updated(_ previous: Date?, succeeded: Bool, at: Date) -> Date? {
        succeeded ? at : previous
    }

    static func isStale(lastSuccess: Date?, hasData: Bool, now: Date, after: TimeInterval) -> Bool {
        guard hasData else { return false }
        guard let lastSuccess = lastSuccess else { return true }
        return now.timeIntervalSince(lastSuccess) > after
    }

    static func availableCards(_ cards: [ResetCard], now: Date) -> [ResetCard] {
        cards.filter { $0.expires > now }.sorted { $0.expires < $1.expires }
    }

    /// 纯函数：fresh 成功 → 新值+新成功时间+清错误；仅失败 → 保留旧值/旧成功时间+记录错误；
    /// 两者皆无 → 原样返回。调用处对结果做顺序赋值——不要把 self 的多个子字段同时作为
    /// inout 实参传入一个调用（同一存储属性的并发独占访问会触发 Swift 运行时崩溃）。
    static func apply<T>(fresh: T?, failure: String?, old: T?, oldLastOK: Date?, oldError: String?,
                         now: Date) -> (value: T?, lastOK: Date?, error: String?) {
        if let fresh = fresh {
            return (fresh, now, nil)
        }
        if let failure = failure {
            return (old, oldLastOK, failure)
        }
        return (old, oldLastOK, oldError)
    }
}

enum CodexRefreshSchedule {
    static func slowItemsDue(cycle: Int, every: Int = 5, manual: Bool) -> Bool {
        manual || (every > 0 && cycle % every == 0)
    }
}

/// Tibo 动态的三态合并（与 CodexFreshness.apply 同约定，多一个 304 分支）：
/// fresh → 新值 + 推进成功时间 + 清错误；unchanged（304）→ 保留旧值但推进成功时间
/// （服务端确认内容未变，数据仍有效）；failure → 保留旧值与旧成功时间 + 记录错误。
enum TiboFreshness {
    static func apply(outcome: TiboFetchOutcome, old: [TiboEvent]?, oldCheckedAt: Date?,
                      oldLastOK: Date?, oldError: String?,
                      now: Date) -> (value: [TiboEvent]?, checkedAt: Date?, lastOK: Date?, error: String?) {
        switch outcome {
        case .fresh(let events, let checkedAt): return (events, checkedAt, now, nil)
        case .unchanged: return (old, oldCheckedAt, now, nil)
        case .failure(let error): return (old, oldCheckedAt, oldLastOK, error)
        }
    }
}

// MARK: - CodexUsage：监控 OpenAI Codex 订阅（ChatGPT Plus 的 Codex 额度）的菜单栏工具
//
// 架构与同机 GlmUsage 完全同构（单文件 / 纯 Foundation + AppKit / 无外部依赖）。
// 数据源：
//   额度  GET https://chatgpt.com/backend-api/wham/usage（每 10s，Bearer 凭证来自 ~/.codex/auth.json）
//   重置卡 GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits（每 5 分钟，认证头同款）
//   Tibo 重置动态 GET https://aihot.news/api/v1/codex-resets/recent（每 5 分钟，AIHOT 公开接口，匿名只读不经凭据）
//   token 统计：本地增量扫描 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl（每 5 分钟）
//   外部用量：Codex CLI 之外消费 OpenAI 系模型（gpt* 等）的 token——本地增量扫描
//     ~/.proma/agent-sessions（与 Token Monitor 的 proma 来源同款，回合级口径；
//     sdk-config/sessions 是同一批会话更细粒度的运行时日志，多记子请求/续写调用，
//     两者都扫会双算、只扫 sdk 又与 Token Monitor 对不上，均不取）、
//     ~/.proma/sdk-config/projects（最早一代）与 ~/.claude/projects 的
//     Claude SDK 风格 JSONL，加 ~/.hermes/state.db 的 session_model_usage
//     累计行快照差分（只读打开）。input 含 cache read——与 Token Monitor 的
//     totalTokens 口径一致（其值 = input + cacheRead + output，实测对账吻合）
// 凭证红线：access_token / refresh_token / id_token 只存在于内存，绝不写入日志、
//   status.json、scan-state.json 或提交；~/.codex/ 只读，唯一例外是 401 刷新成功后
//   经 AtomicJSONFile 原子合并写回 auth.json 本身（Codex CLI 轮换优先）。

// MARK: - Codex CLI 凭证读取（只读 ~/.codex/auth.json）
//
// Codex CLI 自己负责 OAuth 刷新并写回该文件，因此每次拉额度前都重新读取，
// 绝大多数情况无需本应用自己刷新。email 从 id_token（JWT）payload 的
// "https://api.openai.com/profile" claim 解出，仅用于菜单展示，失败即跳过。

enum CodexAuth {
    static let authPath = NSHomeDirectory() + "/.codex/auth.json"

    struct Tokens {
        var accessToken: String
        var refreshToken: String?
        var idToken: String?
        var email: String?
        var accountID: String? = nil
    }
    /// 当前认证字段快照；写回时必须重新读取最新 JSON，不能复用旧文档。
    struct Snapshot {
        var tokens: Tokens
    }

    static func load(at path: String = authPath) -> Snapshot? {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            return nil
        }
        let refresh = tokens["refresh_token"] as? String
        let id = tokens["id_token"] as? String
        return Snapshot(
            tokens: Tokens(accessToken: access, refreshToken: refresh,
                           idToken: id, email: id.flatMap(jwtEmail), accountID: tokens["account_id"] as? String))
    }

    /// API key authentication is distinct from a ChatGPT subscription.
    static func usesAPIKey(at path: String = authPath) -> Bool {
        guard let data = FileManager.default.contents(atPath: path),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return false }
        let mode = (obj["auth_mode"] as? String)?.lowercased()
        if mode == "apikey" || mode == "api_key" { return true }
        if mode != nil { return false }
        return (obj["OPENAI_API_KEY"] as? String).map { !$0.isEmpty } ?? false
    }

    // Only use stable identity when both the user and workspace can be identified.
    // Otherwise the in-memory access token is a conservative boundary, never persisted.
    static func identity(_ snapshot: Snapshot?) -> String? {
        guard let tokens = snapshot?.tokens else { return nil }
        func claims(_ jwt: String?) -> [String: Any] {
            guard let jwt = jwt, jwt.split(separator: ".").count > 1 else { return [:] }
            var part = String(jwt.split(separator: ".")[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
            part += String(repeating: "=", count: (4 - part.count % 4) % 4)
            guard let data = Data(base64Encoded: part),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return [:] }
            return obj
        }
        let id = claims(tokens.idToken), access = claims(tokens.accessToken)
        let auth = access["https://api.openai.com/auth"] as? [String: Any] ?? [:]
        let subject = (id["sub"] as? String) ?? (access["sub"] as? String)
        let account = tokens.accountID ?? (auth["chatgpt_account_id"] as? String)
        if let subject = subject, !subject.isEmpty, let account = account, !account.isEmpty {
            return "account:" + subject + "|" + account
        }
        // 使用 accessToken 的 SHA256 摘要前缀作为兜底标识，避免 token 明文传入标识链
        let tokenData = Data((tokens.accessToken).utf8)
        let digest = SHA256.hash(data: tokenData)
        let hex = digest.prefix(8).map { String(format: "%02x", $0) }.joined()
        return "token-hash:" + hex
    }

    static func sameAuth(_ a: Tokens, _ b: Tokens) -> Bool {
        a.accessToken == b.accessToken && a.refreshToken == b.refreshToken && a.idToken == b.idToken
            && a.accountID == b.accountID
    }

    /// Re-read and merge into the newest document. A Codex CLI rotation during refresh wins.
    static func writeBack(at path: String = authPath, expected: Tokens, accessToken: String,
                          refreshToken: String?, idToken: String?) throws -> (access: String, wrote: Bool) {
        func readLatest() throws -> (obj: [String: Any], tokens: [String: Any], latest: Tokens) {
            guard let data = FileManager.default.contents(atPath: path),
                  let obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let tokens = obj["tokens"] as? [String: Any],
                  let latestAccess = tokens["access_token"] as? String, !latestAccess.isEmpty else {
                throw NSError(domain: "CodexUsage.Auth", code: 1,
                              userInfo: [NSLocalizedDescriptionKey: "auth.json missing tokens.access_token"])
            }
            let latest = Tokens(accessToken: latestAccess,
                                refreshToken: tokens["refresh_token"] as? String,
                                idToken: tokens["id_token"] as? String,
                                email: (tokens["id_token"] as? String).flatMap(jwtEmail),
                                accountID: tokens["account_id"] as? String)
            return (obj, tokens, latest)
        }
        let first = try readLatest()
        guard sameAuth(expected, first.latest) else { return (first.latest.accessToken, false) }
        var obj = first.obj
        var tokens = first.tokens
        tokens["access_token"] = accessToken
        if let r = refreshToken, !r.isEmpty { tokens["refresh_token"] = r }
        if let i = idToken, !i.isEmpty { tokens["id_token"] = i }
        obj["tokens"] = tokens
        obj["last_refresh"] = Fmt.isoFrac.string(from: Date())
        let updated = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
        // rename 前对磁盘最新值复检一次：把「序列化期间 Codex CLI 完成轮换」的竞态窗口
        // 从毫秒级压到微秒级；复检不一致时放弃写入、保留 CLI 的最新凭据
        let second = try readLatest()
        guard sameAuth(first.latest, second.latest) else { return (second.latest.accessToken, false) }
        try AtomicJSONFile.replace(updated, at: path)
        return (accessToken, true)
    }

    /// JWT 第二段 Base64URL 解码 → payload claim "https://api.openai.com/profile".email
    private static func jwtEmail(_ jwt: String) -> String? {
        let parts = jwt.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        var seg = String(parts[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        seg += String(repeating: "=", count: (4 - seg.count % 4) % 4)
        guard let data = Data(base64Encoded: seg),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let profile = obj["https://api.openai.com/profile"] as? [String: Any]
        guard let email = (profile?["email"] as? String) ?? (obj["email"] as? String), !email.isEmpty else { return nil }
        return email
    }
}

// MARK: - 用量数据模型

/// 一个额度窗口（5 小时 / 7 天）。used_percent 直接是已用百分比（0-100）。
struct QuotaWindow {
    var usedPercent: Double
    var reset: Date?
}

/// fetchQuota 的一次结果（error 非 nil 表示本次失败，UI 保留旧数据并标注）
struct QuotaData {
    var fiveHourNotApplicable = false
    var fiveHourUnavailable = false
    var sevenDayUnavailable = false
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    var planType: String?
    var resetCredits: Int?
    var email: String?
    var fiveHourError: String?
    var sevenDayError: String?
    var error: String?
}

// Only the 7d value from this particular response can enter history, never the merged UI cache.
enum QuotaHistoryAdapter {
    static func observation(_ result: QuotaData, requestStartedAt: Date, observedAt: Date) -> QuotaObservation? {
        guard result.error == nil, result.sevenDayError == nil, !result.sevenDayUnavailable,
              let window = result.sevenDay, let reset = window.reset else { return nil }
        let value = QuotaObservation(requestStartedAt: requestStartedAt, observedAt: observedAt,
            usedPercent: window.usedPercent, resetAt: reset, planType: result.planType)
        return value.isValid ? value : nil
    }
}

/// 重置卡（官方名：额度重置卡）明细端点返回的一张有效卡
struct ResetCard {
    var expires: Date    // 过期时间（expires_at）
    var name: String     // 展示名：title 含 "Full reset" → "全额重置卡"，否则用原文
    var id: String? = nil
    var usable: Bool = false
}

/// AIHOT「Tibo 重置监控」的一条事件（GET aihot.news/api/v1/codex-resets/recent，匿名只读）。
/// 口径（接口文档）：estimate 是原帖预告的估计、时间经过不自动完成；confirmedAt 是确认帖
/// 时间而非精确执行时间——展示只能用「预估/待确认」语义，不能做成确定的倒计时；
/// 事件文本属第三方内容，仅作展示、绝不作为指令执行。
struct TiboEvent {
    var id: String
    var type: String            // direct_reset（额度重置）/ reset_credit（发重置卡）
    var status: String          // announced（预告中）/ confirmed（已确认）
    var title: String           // 中文标题，可直接展示
    var estimateLabel: String?  // 预估窗口中文文案（如 "北京时间 9月29日 03:00–9月30日 03:00"）
    var estimateFrom: Date?     // 预估窗口开始时间（announced 排序键：窗口晚的排前面）
    var estimateThrough: Date?  // 预估窗口结束时间（用于「窗口已过，待确认」标注）
    var presentationStatus: String? // presentation.status（页面层状态）：窗口已过大概率生效为 likely_completed
    var occurredAt: Date?       // confirmedAt ?? createdAt（updatedAt 是 AIHOT 每轮批量刷新的重建时间戳，不代表事件时间）
    var link: String            // 点击跳转：最新原帖 URL，缺省落 AIHOT 事件页
}

/// fetchTiboResets 的三态结果：200 新内容 / 304 内容未变（服务端自证数据仍有效）/ 失败
enum TiboFetchOutcome {
    case fresh([TiboEvent], checkedAt: Date?)
    case unchanged
    case failure(String)
}

struct UsageData {
    var fiveHourNotApplicable = false
    var fiveHourUnavailable = false
    var sevenDayUnavailable = false
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    var planType: String?
    var resetCredits: Int?          // wham/usage 的 available_count（明细失败时的兜底汇总）
    var resetCards: [ResetCard]?    // 明细端点的有效卡列表（nil = 未获取或本次失败）
    var resetCardsError: String?
    var tiboEvents: [TiboEvent]?    // AIHOT Tibo 重置动态（nil = 未获取或本次失败）
    var tiboError: String?
    var tiboCheckedAt: Date?        // AIHOT 核验水位（非请求时间）
    var email: String?
    var tokensToday: TokenScanner.Stats?
    var tokens7d: TokenScanner.Stats?
    var tokens30d: TokenScanner.Stats?
    var externalTools: [String: [ExternalTokenScanner.Stats]] = [:]
    var sourceStatus: [String: UsageSourceStatus] = [:]
    var official: OfficialUsageSnapshot?
    var officialError: String?
    var extToday: ExternalTokenScanner.Stats?    // 外部用量（OpenAI 模型 · 非 Codex CLI）
    var ext7d: ExternalTokenScanner.Stats?
    var ext30d: ExternalTokenScanner.Stats?
    var quotaError: String?
    var tokensError: String?
    var extError: String?           // 外部用量已安装来源全部不可读
    var fiveHourError: String?
    var sevenDayError: String?
}

enum AccountIsolation {
    static func clear(_ usage: inout UsageData) {
        usage.fiveHourNotApplicable = false
        usage.fiveHourUnavailable = false; usage.sevenDayUnavailable = false
        usage.fiveHour = nil; usage.sevenDay = nil; usage.planType = nil
        usage.resetCredits = nil; usage.resetCards = nil; usage.email = nil
        usage.quotaError = nil; usage.fiveHourError = nil; usage.sevenDayError = nil
        usage.resetCardsError = nil
        usage.official = nil; usage.officialError = nil
    }
    static func accepts(capturedGeneration: Int, currentGeneration: Int,
                        capturedIdentity: String?, currentIdentity: String?) -> Bool {
        capturedGeneration == currentGeneration && capturedIdentity == currentIdentity
    }
}

enum QuotaMerge {
    static func preferred(_ fresh: QuotaWindow?, old: QuotaWindow?) -> QuotaWindow? {
        fresh ?? old
    }
    static func fiveHour(_ response: QuotaData, old: QuotaWindow?, oldLastOK: Date?,
                         wasNotApplicable: Bool, now: Date) -> (QuotaWindow?, Date?, Bool) {
        if response.fiveHourNotApplicable { return (nil, nil, true) }
        if let value = response.fiveHour { return (value, now, false) }
        if response.error == nil && response.fiveHourError != nil { return (old, oldLastOK, false) }
        return (old, oldLastOK, wasNotApplicable)
    }
}

// MARK: - 额度接口（wham/usage）+ 401 兜底刷新
//
// 实测（2026-09-26）返回旧格式 rate_limit.primary_window / secondary_window，
// 新格式 usage.limits[] 也一并兼容（与 CodexMeter 的 quota.ts 一致；同 code 新格式优先）。
// reset_at 兼容 epoch 秒 / epoch 毫秒（>10^10）/ ISO8601 字符串 / 缺失（用 reset_after_seconds 兜底）。
// 401 时才尝试刷新（距上次刷新尝试 >5 分钟，防刷新风暴）：POST auth.openai.com/oauth/token，
// 成功后原子写回 auth.json 并用新凭证重试一次额度请求。
// 重置卡明细另走 GET wham/rate-limit-reset-credits（认证头完全同款；401 不做兜底刷新，
// 避免新增写 auth.json 的路径，失败由调用方降级展示）。

enum Fetcher {
    static let usageURL = "https://chatgpt.com/backend-api/wham/usage"
    static let resetCreditsURL = "https://chatgpt.com/backend-api/wham/rate-limit-reset-credits"
    static let tiboURL = "https://aihot.news/api/v1/codex-resets/recent"
    static let refreshURL = "https://auth.openai.com/oauth/token"
    // Codex CLI 公开 client_id（与官方 CLI 相同，非密钥）
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let refreshMinInterval: TimeInterval = 300

    private static let refreshLock = NSLock()
    private static var lastRefreshAttempt: [String: Date] = [:]

    // Tibo 动态（AIHOT）：上次响应的 ETag，带 If-None-Match 轮询（接口要求同端点 ≥60s 间隔，5 分钟周期满足）
    private static let tiboLock = NSLock()
    private static var tiboETag: String?

    static func fetchQuota(auth: CodexAuth.Snapshot? = CodexAuth.load(), completion: @escaping (QuotaData) -> Void) {
        guard let auth = auth else {
            var e = QuotaData()
            e.error = "未找到 Codex 凭证（~/.codex/auth.json）"
            e.fiveHourError = e.error
            e.sevenDayError = e.error
            completion(e)
            return
        }
        requestUsage(usageURL, token: auth.tokens.accessToken) { obj, status, netErr in
            if status == 401 {
                attemptRefresh(auth: auth) { refreshErr in
                    guard refreshErr == nil, let fresh = CodexAuth.load(),
                          CodexAuth.identity(fresh) == CodexAuth.identity(auth) else {
                        var e = QuotaData(email: auth.tokens.email)
                        e.error = refreshErr.map { "HTTP 401（\($0)）" }
                            ?? "HTTP 401（刷新后无可用凭证）"
                        completion(e)
                        return
                    }
                    requestUsage(usageURL, token: fresh.tokens.accessToken) { obj2, status2, err2 in
                        completion(finish(obj2, status: status2, err: err2, email: fresh.tokens.email))
                    }
                }
            } else {
                completion(finish(obj, status: status, err: netErr, email: auth.tokens.email))
            }
        }
    }

    static func finish(_ obj: [String: Any]?, status: Int?, err: String?,
                               email: String?) -> QuotaData {
        if status == 200, let obj = obj {
            return parseUsage(obj, now: Date(), email: email)
        }
        var e = QuotaData(email: email)
        if let err = err { e.error = err } else { e.error = "HTTP \(status ?? 0)" }
        e.fiveHourError = e.error
        e.sevenDayError = e.error
        return e
    }

    /// 认证 GET（额度与重置卡明细共用，header 与 wham/usage 完全同款）
    private static func requestUsage(_ urlStr: String, token: String,
                                     completion: @escaping ([String: Any]?, Int?, String?) -> Void) {
        guard let url = URL(string: urlStr) else {
            completion(nil, nil, "bad url"); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        req.setValue("CodexUsage/1.0", forHTTPHeaderField: "User-Agent")
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode
            if let err = err {
                completion(nil, status, err.localizedDescription); return
            }
            guard let status = status else {
                completion(nil, nil, "no response"); return
            }
            if status != 200 {
                completion(nil, status, nil); return
            }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(nil, status, "bad response"); return
            }
            completion(obj, status, nil)
        }.resume()
    }

    /// 401 兜底刷新。返回 nil 表示成功，否则返回失败原因（绝不包含任何 token 值）。
    private static func attemptRefresh(auth: CodexAuth.Snapshot,
                                       completion: @escaping (String?) -> Void) {
        guard let current = CodexAuth.load() else {
            completion("auth.json 读取失败"); return
        }
        if !CodexAuth.sameAuth(auth.tokens, current.tokens) {
            // Codex CLI already rotated credentials after the failed request; caller will reload and retry.
            completion(nil); return
        }
        refreshLock.lock()
        let now = Date()
        let refreshIdentity = CodexAuth.identity(current) ?? "unknown"
        if let last = lastRefreshAttempt[refreshIdentity], now.timeIntervalSince(last) < refreshMinInterval {
            refreshLock.unlock()
            completion("刷新冷却中，5 分钟内已尝试过"); return
        }
        lastRefreshAttempt[refreshIdentity] = now
        refreshLock.unlock()

        guard let rt = current.tokens.refreshToken, !rt.isEmpty else {
            completion("auth.json 中无 refresh_token"); return
        }
        guard let url = URL(string: refreshURL) else {
            completion("bad url"); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let enc = rt.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? rt
        req.httpBody = "grant_type=refresh_token&client_id=\(clientID)&refresh_token=\(enc)"
            .data(using: .utf8)
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
            guard err == nil, status == 200, let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let access = obj["access_token"] as? String, !access.isEmpty else {
                completion(err?.localizedDescription ?? "刷新请求 HTTP \(status)")
                return
            }
            do {
                let write = try CodexAuth.writeBack(expected: current.tokens, accessToken: access,
                    refreshToken: obj["refresh_token"] as? String, idToken: obj["id_token"] as? String)
                if write.wrote { NSLog("[CodexUsage] OAuth credentials atomically updated") }
                else { NSLog("[CodexUsage] Codex CLI changed credentials during refresh; kept latest auth.json") }
                completion(nil)
            } catch {
                NSLog("[CodexUsage] OAuth credential write failed: %@", error.localizedDescription)
                completion("写回 auth.json 失败")
            }
        }.resume()
    }

    /// 兼容新旧两种额度格式；同一 code 新格式（usage.limits）优先
    static func parseUsage(_ obj: [String: Any], now: Date, email: String?) -> QuotaData {
        var out = QuotaData(email: email)
        out.planType = (obj["plan_type"] as? String) ?? (obj["planType"] as? String)
        if let raw = (obj["rate_limit_reset_credits"] as? [String: Any])?["available_count"] {
            out.resetCredits = CodexNumber.nonnegativeInteger(raw)
        }
        var byCode: [String: (used: Double, reset: Date?)] = [:]
        var errors = ["5h": "暂未提供", "7d": "暂未提供"]
        var sawFiveHourField = false
        var sawSevenDayField = false

        // 旧格式（当前实际返回）：rate_limit.primary_window → 5h，secondary_window → 7d，
        // used_percent 直接是已用百分比；limit_window_seconds 用于校验窗口类型
        if let rl = obj["rate_limit"] as? [String: Any] {
            for (key, fallback) in [("primary_window", "5h"), ("secondary_window", "7d")] {
                guard let w = rl[key] as? [String: Any] else { continue }
                var code = fallback
                if let rawSeconds = w["limit_window_seconds"] {
                    guard let seconds = CodexNumber.finite(rawSeconds) else {
                        errors[fallback] = "invalid \(fallback.uppercased()) window duration"
                        if fallback == "5h" { sawFiveHourField = true } else { sawSevenDayField = true }
                        continue
                    }
                    if abs(seconds - 18000) <= 60 { code = "5h" }
                    else if abs(seconds - 604800) <= 3600 { code = "7d" }
                    else {
                        errors[fallback] = "invalid \(fallback.uppercased()) window duration"
                        if fallback == "5h" { sawFiveHourField = true } else { sawSevenDayField = true }
                        continue
                    }
                }
                if code == "5h" { sawFiveHourField = true } else { sawSevenDayField = true }
                if let used = CodexNumber.finite(w["used_percent"]), (0...100).contains(used) {
                    byCode[code] = (used, resetDate(w, now: now))
                    errors[code] = ""
                } else {
                    errors[code] = "invalid \(code.uppercased()) used_percent"
                }
            }
        }
        // 新格式：usage.limits[]，percentUsed = used/limit×100（同 code 覆盖旧格式）
        let usageNode = (obj["usage"] as? [String: Any]) ?? obj
        if let limits = usageNode["limits"] as? [[String: Any]] {
            for e in limits {
                guard let code = e["window"] as? String, code == "5h" || code == "7d" else { continue }
                if code == "5h" { sawFiveHourField = true } else { sawSevenDayField = true }
                guard let used = CodexNumber.finite(e["used"]), used >= 0,
                      let limit = CodexNumber.finite(e["limit"]), limit > 0,
                      used <= limit else {
                    if byCode[code] == nil { errors[code] = "invalid \(code.uppercased()) used/limit" }
                    continue
                }
                byCode[code] = (used / limit * 100, resetDate(e, now: now))
                errors[code] = ""
            }
        }

        // Pro capability fallback is deliberately restricted to a valid, explicitly timed
        // 7-day legacy window and an absent/null other window. Unknown or malformed
        // structures are not evidence that the 5-hour window is inapplicable.
        if let rl = obj["rate_limit"] as? [String: Any],
           ["pro", "prolite"].contains((out.planType ?? "").lowercased()),
           !sawFiveHourField, byCode["5h"] == nil, byCode["7d"] != nil {
            let windows = [rl["primary_window"], rl["secondary_window"]]
            let present = windows.compactMap { $0 as? [String: Any] }
            if present.count == 1, let seconds = CodexNumber.finite(present[0]["limit_window_seconds"]),
               abs(seconds - 604800) <= 3600,
               let used = CodexNumber.finite(present[0]["used_percent"]), (0...100).contains(used),
               windows.allSatisfy({ $0 == nil || $0 is NSNull || $0 is [String: Any] }) {
                out.fiveHourNotApplicable = true
            }
        }
        out.fiveHourUnavailable = !sawFiveHourField && !out.fiveHourNotApplicable
        out.sevenDayUnavailable = !sawSevenDayField
        if let v = byCode["5h"] { out.fiveHour = QuotaWindow(usedPercent: v.used, reset: v.reset) }
        else if !out.fiveHourNotApplicable { out.fiveHourError = errors["5h"] }
        if let v = byCode["7d"] { out.sevenDay = QuotaWindow(usedPercent: v.used, reset: v.reset) }
        else { out.sevenDayError = errors["7d"] }
        if out.fiveHour == nil && out.sevenDay == nil {
            out.error = [out.fiveHourError, out.sevenDayError].compactMap { $0 }.joined(separator: "; ")
        }
        return out
    }

    private static func resetDate(_ w: [String: Any], now: Date) -> Date? {
        if let d = Fmt.parseDateValue(w["reset_at"] ?? w["resetAt"] ?? w["resets_at"]) { return d }
        let after = CodexNumber.finite(w["reset_after_seconds"] ?? w["reset_after"]) ?? 0
        return after > 0 ? now.addingTimeInterval(after) : nil
    }

    /// 重置卡（额度重置卡）明细：GET wham/rate-limit-reset-credits（认证头与 wham/usage 同款）。
    /// 401 不做兜底刷新（避免新增写 auth.json 的路径），失败由调用方降级展示。
    static func fetchResetCards(auth: CodexAuth.Snapshot? = CodexAuth.load(), completion: @escaping ([ResetCard]?, String?) -> Void) {
        guard let auth = auth else {
            completion(nil, "未找到 Codex 凭证（~/.codex/auth.json）"); return
        }
        requestUsage(resetCreditsURL, token: auth.tokens.accessToken) { obj, status, err in
            if let err = err { completion(nil, err); return }
            guard status == 200, let obj = obj else {
                completion(nil, "HTTP \(status ?? 0)"); return
            }
            let parsed = parseResetCards(obj, now: Date())
            completion(parsed.cards, parsed.error)
        }
    }

    /// 明细解析（与 CodexMeter parseResetCreditsPayload 口径一致）：容器字段兼容
    /// credits / reset_credits / resetCredits / data；有效卡 = status 为空或不在已失效
    /// 集合，且 expires_at > now；按过期时间升序；title 含 "Full reset" → "全额重置卡"。
    static func parseResetCards(_ obj: [String: Any], now: Date) -> (cards: [ResetCard]?, error: String?) {
        let invalid: Set<String> = ["redeemed", "used", "consumed", "expired", "unavailable"]
        let container = obj["credits"] ?? obj["reset_credits"] ?? obj["resetCredits"] ?? obj["data"]
        guard let container = container else { return (nil, "missing card list") }
        guard let list = container as? [[String: Any]] else { return (nil, "invalid card list") }
        var cards: [ResetCard] = []
        for c in list {
            let status = ((c["status"] as? String) ?? "").lowercased()
            guard !invalid.contains(status) else { continue }
            guard let exp = Fmt.parseDateValue(c["expires_at"] ?? c["expiresAt"]) else {
                return (nil, "invalid card expiration")
            }
            guard exp > now else { continue }
            let title = (c["title"] as? String) ?? ""
            let name = title.contains("Full reset") ? "全额重置卡"
                : (title.isEmpty ? "额度重置卡" : title)
            let id = (c["id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            let usable = status == "available" && (c["reset_type"] as? String) == "codex_rate_limits"
                && (c["is_supported_by_plan"] as? Bool) != false && !(id ?? "").isEmpty
            cards.append(ResetCard(expires: exp, name: name, id: id, usable: usable))
        }
        return (cards.sorted { $0.expires < $1.expires }, nil)
    }

    enum ResetUseResult: Equatable {
        case success, alreadyRedeemed, nothingToReset, noCredit, unknown
        var acknowledgesRedemption: Bool { self == .success || self == .alreadyRedeemed }
    }

    static func resetUseRequest(auth: CodexAuth.Snapshot, cardID: String, key: String) -> URLRequest? {
        guard !cardID.isEmpty, !key.isEmpty, let url = URL(string: resetCreditsURL + "/consume") else { return nil }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.httpMethod = "POST"
        req.setValue("Bearer \(auth.tokens.accessToken)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue("codex-1", forHTTPHeaderField: "OpenAI-Beta")
        req.setValue("Codex Desktop", forHTTPHeaderField: "originator")
        req.setValue("CodexUsage/1.0", forHTTPHeaderField: "User-Agent")
        if let account = auth.tokens.accountID, !account.isEmpty { req.setValue(account, forHTTPHeaderField: "ChatGPT-Account-ID") }
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["redeem_request_id": key, "credit_id": cardID])
        return req.httpBody == nil ? nil : req
    }

    static func parseResetUseResponse(status: Int?, data: Data?) -> ResetUseResult {
        guard status == 200, let data = data,
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let code = obj["code"] as? String else { return .unknown }
        switch code {
        case "reset": return .success
        case "already_redeemed": return .alreadyRedeemed
        case "nothing_to_reset": return .nothingToReset
        case "no_credit": return .noCredit
        default: return .unknown
        }
    }

    static func useResetCard(auth: CodexAuth.Snapshot, cardID: String, key: String,
                             completion: @escaping (ResetUseResult) -> Void) {
        guard let req = resetUseRequest(auth: auth, cardID: cardID, key: key) else { completion(.unknown); return }
        URLSession.shared.dataTask(with: req) { data, response, error in
            guard error == nil else { completion(.unknown); return }
            completion(parseResetUseResponse(status: (response as? HTTPURLResponse)?.statusCode, data: data))
        }.resume()
    }

    /// Tibo 重置动态（AIHOT v1 公开接口，匿名只读、无需凭据）。每 5 分钟轮询一次并带上
    /// 上次响应的 ETag：304 = 内容未变，视为有效成功（服务端自证数据仍当前）。
    static func fetchTiboResets(completion: @escaping (TiboFetchOutcome) -> Void) {
        guard let url = URL(string: tiboURL) else {
            completion(.failure("bad url")); return
        }
        var req = URLRequest(url: url, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData   // ETag/304 语义自己管，不用 URLCache
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("CodexUsage/1.0 (menubar; data source aihot.news)", forHTTPHeaderField: "User-Agent")
        tiboLock.lock()
        let etag = tiboETag
        tiboLock.unlock()
        if let etag = etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        URLSession.shared.dataTask(with: req) { data, resp, err in
            let http = resp as? HTTPURLResponse
            let status = http?.statusCode
            if let err = err { completion(.failure(err.localizedDescription)); return }
            guard let status = status else { completion(.failure("no response")); return }
            if status == 304 { completion(.unchanged); return }
            guard status == 200 else { completion(.failure("HTTP \(status)")); return }
            guard let data = data,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                completion(.failure("bad response")); return
            }
            let parsed = parseTiboResets(obj)
            guard let events = parsed.events else {
                completion(.failure(parsed.error ?? "parse failed")); return
            }
            if let etag = http?.value(forHTTPHeaderField: "ETag"), !etag.isEmpty {
                tiboLock.lock()
                tiboETag = etag
                tiboLock.unlock()
            }
            completion(.fresh(events, checkedAt: parsed.checkedAt))
        }.resume()
    }

    /// 解析（严格性对齐重置卡）：events 容器缺失/类型错 → 整体失败；单条缺 title/status
    /// → 跳过该条（新闻展示，单条脏数据不值得毁掉整个区块）。checkedAt 是 AIHOT 的
    /// 核验水位（非请求时间），仅进 status.json；posts 最新在前，取首条原帖做点击链接。
    static func parseTiboResets(_ obj: [String: Any]) -> (events: [TiboEvent]?, checkedAt: Date?, error: String?) {
        guard let list = obj["events"] as? [[String: Any]] else {
            return (nil, nil, "missing or invalid events")
        }
        func nonEmpty(_ s: String?) -> String? { (s?.isEmpty ?? true) ? nil : s }
        var events: [TiboEvent] = []
        for e in list {
            guard let title = nonEmpty(e["title"] as? String),
                  let status = nonEmpty(e["status"] as? String) else { continue }
            let estimate = e["estimate"] as? [String: Any]
            let presentation = e["presentation"] as? [String: Any]
            let postLink = nonEmpty(((e["posts"] as? [[String: Any]])?.first)?["url"] as? String)
            events.append(TiboEvent(
                id: (e["id"] as? String) ?? "",
                type: (e["type"] as? String) ?? "",
                status: status,
                title: title,
                estimateLabel: nonEmpty(estimate?["label"] as? String),
                estimateFrom: estimate.flatMap { Fmt.parseDateValue($0["from"]) },
                estimateThrough: estimate.flatMap { Fmt.parseDateValue($0["through"]) },
                presentationStatus: nonEmpty(presentation?["status"] as? String),
                occurredAt: Fmt.parseDateValue(e["confirmedAt"])
                    ?? Fmt.parseDateValue(e["createdAt"]),
                link: postLink ?? nonEmpty(e["url"] as? String) ?? ""
            ))
        }
        return (events, Fmt.parseDateValue(obj["checkedAt"]), nil)
    }
}

// MARK: - Tibo 重置动态菜单区块（AIHOT codex-resets）

enum TiboDisplay {
    /// 区块行（纯函数，离线回归覆盖）：预告中（announced）按预估窗口开始时间倒序只
    /// 展示最近 1 条（AIHOT 确认只发新事件、不翻旧 status，不能等它翻转；缺窗口回退
    /// occurredAt；不能按 occurredAt 排——排序看窗口不看记录时间）——其中 presentation
    /// 标记 likely_completed（窗口已过、大概率已生效，AIHOT 页面按「已生效」渲染）的
    /// 预告不再展示，与页面「当前没有等待生效的重置」口径一致；有预估窗口就只显示
    /// 「预估 <窗口文案>」（无预估时回退事件标题）；预估窗口已过但未确认 → 追加
    /// 「（窗口已过，待确认）」（schedule 不随时间自动完成）；已确认（confirmed）只展示
    /// 最近一条。空列表 → 占位行。
    static func rows(_ events: [TiboEvent], now: Date) -> [(text: String, link: String, confirmed: Bool)] {
        guard !events.isEmpty else { return [("暂无重置动态", "", false)] }
        var out: [(text: String, link: String, confirmed: Bool)] = []
        for e in events.filter({ $0.status == "announced" && $0.presentationStatus != "likely_completed" })
            .sorted(by: windowDesc).prefix(1) {
            var s = e.estimateLabel.map { "预估 \($0)" } ?? e.title
            if let through = e.estimateThrough, through < now { s += "（窗口已过，待确认）" }
            out.append((text: s, link: e.link, confirmed: false))
        }
        if let latest = events.filter({ $0.status != "announced" }).sorted(by: timeDesc).first {
            let day = latest.occurredAt.map { Fmt.day($0) } ?? ""
            out.append((text: (day.isEmpty ? "" : day + " ") + latest.title, link: latest.link, confirmed: true))
        }
        return out
    }

    /// announced 排序键：预估窗口开始时间（缺窗口回退 occurredAt）
    private static func windowDesc(_ a: TiboEvent, _ b: TiboEvent) -> Bool {
        (a.estimateFrom ?? a.occurredAt ?? .distantPast) > (b.estimateFrom ?? b.occurredAt ?? .distantPast)
    }

    private static func timeDesc(_ a: TiboEvent, _ b: TiboEvent) -> Bool {
        (a.occurredAt ?? .distantPast) > (b.occurredAt ?? .distantPast)
    }
}

// MARK: - 本地会话 token 统计（增量扫描 ~/.codex/sessions）
//
// 扫描 rollout-*.jsonl 和 .jsonl.zst；累计 token 按事件本地日期做差分。
// 缺少时间的旧事件回退到文件名日期；明文追加按 offset 分块读取，压缩档变化时重解。
// 未变化文件复用缓存，明文和同名归档并存时只计一次；冷文件在文件名及修改日都过窗时跳过。

struct ModelTokenUsage {
    var input = 0.0
    var output = 0.0
    var total = 0.0
}

enum TokenScanner {
    struct FileEntry: Codable {
        var size: Int64 = 0
        var mtime: Double = 0
        var offset: UInt64 = 0
        var previous: [Double] = [0, 0, 0]
        var currentModel: String?
        var days: [String: [Double]] = [:]
        var daysByModel: [String: [String: [Double]]] = [:]
    }
    // Model dimensions require one rebuild; aggregate totals keep the original accounting rules.
    struct State: Codable { var version: Int = 3; var files: [String: FileEntry] = [:] }
    struct Result {
        var today = Stats()
        var seven = Stats()
        var thirty = Stats()
        var error: String?
    }
    struct Stats {
        var input = 0.0
        var output = 0.0
        var total = 0.0
        var files = 0
        var models: [String: ModelTokenUsage] = [:]
    }

    static let sessionsRoot = NSHomeDirectory() + "/.codex/sessions"
    static let defaultStatePath = NSHomeDirectory()
        + "/Library/Application Support/CodexUsage/scan-state.json"
    private static let lock = NSLock()
    private static var cache: State?
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"   // 事件本地日；旧数据无时间时回退文件名
        return f
    }()

    static func scan(root: String = sessionsRoot,
                     statePath: String = defaultStatePath,
                     now: Date = Date()) -> Result {
        lock.lock(); defer { lock.unlock() }
        var st = loadState(at: statePath)
        // 窗口口径：含今天共 7 / 30 个日历日（起算日 = 今天 −6 / −29 天）
        let todayKey = dayFmt.string(from: now)
        let calendar = Calendar.current
        let cutoff7 = dayFmt.string(from: calendar.date(byAdding: .day, value: -6, to: now)!)
        let cutoff30 = dayFmt.string(from: calendar.date(byAdding: .day, value: -29, to: now)!)
        var seen = Set<String>()
        var enumed = false
        var enumFailed = false
        if let enumm = FileManager.default.enumerator(
            at: URL(fileURLWithPath: root),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles],
            errorHandler: { _, _ in enumFailed = true; return true }) {
            enumed = true
            for case let url as URL in enumm {
                let name = url.lastPathComponent
                guard name.hasPrefix("rollout-"),
                      name.hasSuffix(".jsonl") || name.hasSuffix(".jsonl.zst"),
                      let fallbackDay = dayFromFilename(name) else { continue }
                let path = url.path
                let compressed = name.hasSuffix(".zst")
                // During compression both representations may coexist; count the live file once.
                if compressed && FileManager.default.fileExists(atPath: String(path.dropLast(4))) { continue }
                seen.insert(path)
                guard let vals = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = vals.fileSize else { continue }
                let mtime = vals.contentModificationDate?.timeIntervalSince1970 ?? 0
                let cached = st.files[path]
                let valid = cached.map { entry in
                    entry.previous.count == 3 && entry.days.values.allSatisfy { $0.count == 3 }
                        && entry.daysByModel.values.allSatisfy { models in
                            models.values.allSatisfy { $0.count == 3 }
                        }
                        && (compressed || entry.offset <= UInt64(max(0, entry.size)))
                } ?? true
                if !valid { st.files.removeValue(forKey: path) }
                let old = valid ? cached : nil
                // An old filename may still be active: only skip when its mtime is also outside the window.
                if old == nil && fallbackDay < cutoff30 && mtime > 0 &&
                    dayFmt.string(from: Date(timeIntervalSince1970: mtime)) < cutoff30 { continue }
                if let e = old, e.size == Int64(size), e.mtime == mtime { continue }
                var entry = old ?? FileEntry()
                let append = !compressed && old != nil && Int64(size) > entry.size
                if !append { entry = FileEntry() }
                let needle = Data("\"total_token_usage\"".utf8)
                let contextNeedle = Data("\"turn_context\"".utf8)
                var pending = Data()
                var consumed: UInt64 = 0
                func parseLine(_ line: Data) {
                    guard line.range(of: needle) != nil || line.range(of: contextNeedle) != nil,
                          let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                          let payload = obj["payload"] as? [String: Any] else { return }
                    if obj["type"] as? String == "turn_context" {
                        if let model = (payload["model"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                           !model.isEmpty {
                            entry.currentModel = model
                        }
                        return
                    }
                    guard obj["type"] as? String == "event_msg",
                          payload["type"] as? String == "token_count",
                          let info = payload["info"] as? [String: Any],
                          let usage = info["total_token_usage"] as? [String: Any],
                          let input = CodexNumber.finite(usage["input_tokens"]), input >= 0,
                          let output = CodexNumber.finite(usage["output_tokens"]), output >= 0,
                          let total = CodexNumber.finite(usage["total_tokens"]), total >= 0 else { return }
                    let values = [input, output, total]
                    let day = Fmt.parseDateValue(obj["timestamp"]).map { dayFmt.string(from: $0) } ?? fallbackDay
                    let deltas = values.indices.map { max(0, values[$0] - entry.previous[$0]) }
                    var bucket = entry.days[day] ?? [0, 0, 0]
                    for i in 0..<3 { bucket[i] += deltas[i] }
                    entry.days[day] = bucket
                    let model = entry.currentModel ?? "未知模型"
                    var models = entry.daysByModel[day] ?? [:]
                    var modelBucket = models[model] ?? [0, 0, 0]
                    for i in 0..<3 { modelBucket[i] += deltas[i] }
                    models[model] = modelBucket
                    entry.daysByModel[day] = models
                    entry.previous = values
                }
                func consume(_ chunk: Data) {
                    var start = chunk.startIndex
                    while let newline = chunk[start...].firstIndex(of: 10) {
                        pending.append(contentsOf: chunk[start..<newline])
                        parseLine(pending)
                        consumed += UInt64(pending.count + 1)
                        pending.removeAll(keepingCapacity: true)
                        start = chunk.index(after: newline)
                    }
                    pending.append(contentsOf: chunk[start...])
                }
                var readOK = true
                if compressed {
                    if let bytes = zstdDecompress(path: path) {
                        consume(bytes)
                        if !pending.isEmpty { parseLine(pending); consumed += UInt64(pending.count) }
                    } else { readOK = false }
                } else if let handle = FileHandle(forReadingAtPath: path) {
                    do {
                        try handle.seek(toOffset: entry.offset)
                        while let chunk = try handle.read(upToCount: 256 * 1024), !chunk.isEmpty { consume(chunk) }
                        try handle.close()
                    } catch { try? handle.close(); readOK = false }
                } else { readOK = false }
                guard readOK else { continue }
                // Pending bytes are intentionally reread when the writer finishes that line.
                entry.offset += consumed
                entry.size = Int64(size); entry.mtime = mtime
                entry.days = entry.days.filter { $0.key >= cutoff30 }
                entry.daysByModel = entry.daysByModel.filter { $0.key >= cutoff30 }
                st.files[path] = entry
            }
        }
        // 枚举部分失败（子目录暂不可读）时不清理未见面：保留旧条目避免误删仍在窗口内的贡献，
        // 目录恢复可读后下一轮自然收敛（ExternalTokenScanner 同口径）
        if enumed && !enumFailed {
            for path in Array(st.files.keys) where !seen.contains(path) { st.files.removeValue(forKey: path) }
        }
        if statePath == defaultStatePath { cache = st }
        saveState(st, to: statePath)
        guard enumed else { return Result(error: "无法枚举 \(root)") }
        var r = Result()
        for e in st.files.values {
            var today = [0.0, 0.0, 0.0], seven = today, thirty = today
            for (day, values) in e.days where day <= todayKey && values.count == 3 {
                for i in 0..<3 {
                    if day == todayKey { today[i] += values[i] }
                    if day >= cutoff7 { seven[i] += values[i] }
                    if day >= cutoff30 { thirty[i] += values[i] }
                }
            }
            add(&r.today, today); add(&r.seven, seven); add(&r.thirty, thirty)
            for (day, models) in e.daysByModel where day <= todayKey {
                for (model, values) in models {
                    if day == todayKey { addModel(&r.today.models, name: model, values: values) }
                    if day >= cutoff7 { addModel(&r.seven.models, name: model, values: values) }
                    if day >= cutoff30 { addModel(&r.thirty.models, name: model, values: values) }
                }
            }
        }
        return r
    }

    private static func dayFromFilename(_ name: String) -> String? {
        guard name.count >= 18 else { return nil }
        let day = String(name.dropFirst("rollout-".count).prefix(10))
        return dayFmt.date(from: day) == nil ? nil : day
    }

    private static func add(_ s: inout Stats, _ values: [Double]) {
        guard values.count == 3, values[2] > 0 else { return }
        s.input += values[0]; s.output += values[1]; s.total += values[2]; s.files += 1
    }

    private static func addModel(_ models: inout [String: ModelTokenUsage], name: String, values: [Double]) {
        guard values.count == 3, values[2] > 0 else { return }
        var stats = models[name] ?? ModelTokenUsage()
        stats.input += values[0]; stats.output += values[1]; stats.total += values[2]
        models[name] = stats
    }

    /// 解压 .jsonl.zst 全量到内存后逐行处理；任何失败返回 nil，
    /// 按「本文件本轮无法读取」处理（不写状态条目，
    /// 修复或删除该归档后下轮扫描自动收敛）。
    ///
    /// 解码走 vendor/zstddeclib.c（上游 zstd v1.5.7 单文件解码源，BSD-3-Clause）
    /// 进程内完成——系统 Compression 框架不含 zstd 算法，依赖外部 zstd 命令则把
    /// 环境负担转嫁给用户；内置解码对任何用户环境都成立。输出缓冲优先用帧头声明
    /// 的内容大小精确分配；
    /// 声明未知时按压缩体 8 倍起步，空间不足时扩容；损坏数据立即退出，
    /// 单文件解码上限 256 MiB，防止异常归档造成过大的内存占用。
    static func zstdDecompress(path: String) -> Data? {
        guard let raw = FileManager.default.contents(atPath: path), !raw.isEmpty else { return nil }
        return raw.withUnsafeBytes { src in
            guard let srcPtr = src.bindMemory(to: UInt8.self).baseAddress else { return nil }
            let limit = 256 << 20
            let declared = cu_zstd_content_size(srcPtr, raw.count)
            if declared > UInt64(limit) { return nil }
            var capacity = declared > 0 ? Int(declared) : min(max(raw.count, 1 << 17), limit / 8) * 8
            while capacity <= limit {
                var out = Data(count: capacity)
                let written = out.withUnsafeMutableBytes { dst in
                    cu_zstd_decompress(srcPtr, raw.count,
                                       dst.bindMemory(to: UInt8.self).baseAddress!, capacity)
                }
                if written == Int(bitPattern: UInt.max) {
                    if capacity == limit { return nil }
                    capacity = min(capacity * 4, limit)
                    continue
                }
                guard written > 0, written <= capacity else { return nil }
                out.count = written
                return out
            }
            return nil
        }
    }

    private static func loadState(at path: String) -> State {
        if path == defaultStatePath, let s = cache { return s }
        if let data = FileManager.default.contents(atPath: path),
           let s = try? JSONDecoder().decode(State.self, from: data), s.version == 3 {
            return s
        }
        return State()
    }

    private static func saveState(_ s: State, to path: String) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        // 复用凭据链的原子写：UUID 临时名 + rename + 仅所有者权限
        // （状态文件含会话绝对路径与逐文件聚合，不应给其他用户留读面）
        do {
            try AtomicJSONFile.replace(data, at: path)
        } catch {
            NSLog("[CodexUsage] TokenScanner saveState failed at %@: %@", path, error.localizedDescription)
        }
    }
}

// MARK: - 外部用量（OpenAI 模型 · 非 Codex CLI，本地扫描）
//
// 统计 Codex CLI 之外消费 OpenAI 系模型的 token，两个来源（与 KimiUsage 的
// 「API 客户端」同构，参考其 TokenAggregator）：
//   1) Claude SDK 风格 JSONL：Proma agent-sessions（2026-10 实测与 Token Monitor
//      的 proma 来源一致，今日 sol 逐分位对账吻合；sdk-config/sessions 为并行双写
//      的运行时细粒度日志——重会话多记 ~30% 子请求/续写调用，取口径一致性、不扫；
//      其 08-26 前的独有历史在 30 天窗口外，无损失）+ sdk-config/projects（最早一代）
//      + ~/.claude/projects（Claude Code 本机，可经 ccswitch/Proma 接 OpenAI 模型）。
//      逐条 assistant 行 message.usage 计入；Proma result 行的 modelUsage/顶层 usage
//      是全会话累计汇总，跳过避免双算。甄别只看 model 字段（isOpenAIModel）。
//   2) hermes：~/.hermes/state.db 的 session_model_usage 是 (session,model,…) 级
//      累计行，只读查询后与持久化快照做差，delta 按行 last_seen 归日；首次运行把
//      存量累计值归入各自 last_seen 当天（自动回填近 30 天窗口）。
// 增量策略与 TokenScanner 同思路：offset 记已消费字节、未变化文件只 stat、追加只读
// 新增字节、只消费到最后一个完整换行；31 天外日聚合清理；~/.proma、~/.claude、
// ~/.hermes 全程只读，绝不写入。

enum ExternalTokenScanner {
    struct Stats {
        var input = 0.0
        var output = 0.0
        var total: Double { input + output }
        var models: [String: ModelTokenUsage] = [:]
    }
    struct Result {
        var today = Stats()
        var seven = Stats()
        var thirty = Stats()
        /// 已安装来源全部不可读（目录存在但枚举失败 / state.db 存在但查询失败）时置错；
        /// 未安装任何来源（目录/库均不存在）不算失败——没装对应工具时该来源自然为 0
        var error: String?
        var tools: [String: [Stats]] = [:]
        var sourceStatus: [String: UsageSourceStatus] = [:]
    }

    /// 按文件增量扫描状态：offset 为已消费字节数，days 为按日聚合 [input, output]
    struct FileState: Codable {
        var offset: UInt64 = 0
        var mtime: Double?
        var days: [String: [Double]] = [:]
        var daysByModel: [String: [String: [Double]]] = [:]
    }
    /// hermes 快照：rows 存上次各累计行的值，days 存按 last_seen 归日的差分历史
    struct HermesState: Codable {
        var rows: [String: [Double]] = [:]
        var days: [String: [Double]] = [:]
        var daysByModel: [String: [String: [Double]]] = [:]
    }
    struct State: Codable {
        var files: [String: FileState] = [:]
        var hermes: HermesState?
    }

    static let fileRoots = [
        // Proma 只扫 agent-sessions：与 Token Monitor 的 proma 来源一致（对账基准）；
        // sdk-config/sessions 是同一批会话更细粒度的运行时双写（重会话多记子请求/
        // 续写调用），两者都扫会双算、只扫 sdk 会与 Token Monitor 对不上
        NSHomeDirectory() + "/.proma/agent-sessions",
        NSHomeDirectory() + "/.proma/sdk-config/projects",
        NSHomeDirectory() + "/.claude/projects",
    ]
    static let hermesDBPath = NSHomeDirectory() + "/.hermes/state.db"
    // 文件名带版本号：口径/来源变更后弃用旧缓存强制重建（v2 目录去重、v3 含 cache、
    // v4 proma 源切 agent-sessions 对齐 Token Monitor、v5 增加模型维度）
    static let defaultStatePath = NSHomeDirectory()
        + "/Library/Application Support/CodexUsage/external-scan-state-v5.json"

    // 与 TokenScanner.scan 同款互斥：状态读改写不是原子的，防止未来调用方并发进入
    private static let lock = NSLock()

    // 只关心近 30 天窗口，日聚合保留 31 天余量
    private static let retainSeconds: TimeInterval = 31 * 86400

    static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"   // 本地时区，与 TokenScanner 口径一致
        return f
    }()

    /// 甄别 OpenAI 系模型（只看 model 字符串，本机外部工具实测值见 --self-test）：
    /// gpt*（gpt-5.6-sol / gpt-6.1-sol / gpt2）、codex*、chatgpt*（chatgpt-4o-latest）、
    /// o+数字（o1 / o3 / o4-mini）。非 OpenAI（glm/k3/mimo/claude/qwen/deepseek/ark…）
    /// 与缺失 model 一律不计——外部工具混接多家 API，宁可漏记不可错记。
    static func isOpenAIModel(_ model: String?) -> Bool {
        guard let m = model?.lowercased(), !m.isEmpty else { return false }
        if m.hasPrefix("gpt") || m.hasPrefix("codex") || m.hasPrefix("chatgpt") { return true }
        guard m.hasPrefix("o"), m.count > 1 else { return false }
        return m[m.index(after: m.startIndex)].isNumber
    }

    /// 全量刷新入口（GUI 每 5 分钟与 token 统计同周期调用；--once 单次）。
    /// roots/hermesDB/statePath/now 均可注入，--self-test 用临时目录做封闭回归。
    static func scan(roots: [String] = fileRoots,
                     hermesDB: String? = hermesDBPath,
                     statePath: String = defaultStatePath,
                     now: Date = Date(),
                     hermesFailAfterRows: Int? = nil) -> Result {
        lock.lock(); defer { lock.unlock() }
        var st = loadState(at: statePath)
        // Collapse old aliases before aggregation; keep the most advanced snapshot.
        var canonicalFiles: [String: FileState] = [:]
        for (path, entry) in st.files {
            let key = realPath(path)
            if canonicalFiles[key] == nil || entry.offset > canonicalFiles[key]!.offset { canonicalFiles[key] = entry }
        }
        st.files = canonicalFiles
        let cutoff = Calendar.current.date(byAdding: .day, value: -31, to: now) ?? now.addingTimeInterval(-retainSeconds)
        let cutoffKey = dayFmt.string(from: cutoff)
        let files = scanFiles(roots: roots, cutoff: cutoff, cutoffKey: cutoffKey, into: &st)
        var hermesOK: Bool?   // nil = 未安装（state.db 不存在），不算失败
        if let db = hermesDB, FileManager.default.fileExists(atPath: db) {
            hermesOK = scanHermes(path: db, cutoffKey: cutoffKey, into: &st, failAfterRows: hermesFailAfterRows)
        }
        saveState(st, at: statePath)
        var r = buckets(st, now: now)
        // File cache already stores contributions by path; derive tool totals without
        // rescanning or splitting pre-existing aggregate totals by guesswork.
        let sourceNames = ["Proma", "Proma", "Claude Code"]
        let canonicalRoots = roots.map(realPath)
        var parts: [String: State] = [:]
        for (path, state) in st.files {
            guard let owner = UsageAttribution.owner(path: realPath(path), roots: canonicalRoots) else { continue }
            let name = owner < sourceNames.count ? sourceNames[owner] : "Other"
            var part = parts[name] ?? State(); part.files[path] = state; parts[name] = part
        }
        for (name, part) in parts {
            let values = buckets(part, now: now)
            r.tools[name] = [values.today, values.seven, values.thirty]
        }
        for (index, root) in roots.enumerated() {
            let name = index < sourceNames.count ? sourceNames[index] : "Other"
            let status = files.status[root] ?? .absent
            let oldStatus = r.sourceStatus[name]
            if status == .failed || oldStatus == .failed { r.sourceStatus[name] = .failed }
            else if status == .available || oldStatus == .available { r.sourceStatus[name] = .available }
            else { r.sourceStatus[name] = .absent }
            if r.tools[name] == nil, status == .available { r.tools[name] = [Stats(), Stats(), Stats()] }
        }
        if let hermes = st.hermes {
            var part = State(); part.hermes = hermes
            let values = buckets(part, now: now)
            r.tools["Hermes"] = [values.today, values.seven, values.thirty]
        }
        r.sourceStatus["Hermes"] = hermesOK == true ? .available : (hermesOK == false ? .failed : .absent)
        // 失败面：有已安装来源但无一可读 → 置错（调用方保留旧值、不推进成功时间）；
        // 部分来源失败仍按成功处理（增量状态保留旧贡献，下轮自愈）
        let anySource = files.installed > 0 || hermesOK != nil
        let anySuccess = files.enumerated > 0 || hermesOK == true
        if anySource && !anySuccess {
            r.error = "外部会话目录 / hermes state.db 均不可读"
        }
        return r
    }

    /// 全解析符号链接的绝对路径（realpath(3)）；路径不存在时原样返回
    private static func realPath(_ p: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(p, &buf) != nil else { return p }
        return String(cString: buf)
    }

    /// 增量扫描 roots 下的 jsonl：未变化文件只 stat，追加文件只读新增字节；
    /// 已被删除的文件从状态中剔除（枚举失败的 root 不动，避免目录临时不可用时误清）。
    /// 返回 (已安装 root 数, 成功枚举 root 数)：目录不存在 = 未安装，不计入失败面。
    private static func scanFiles(roots: [String], cutoff: Date, cutoffKey: String,
                                  into st: inout State) -> (installed: Int, enumerated: Int, status: [String: UsageSourceStatus]) {
        var seen = Set<String>()
        var enumedRoots: [String] = []
        var installed = 0
        var status: [String: UsageSourceStatus] = [:]

        for root in roots {
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: root, isDirectory: &isDir) else { status[root] = .absent; continue }
            installed += 1
            status[root] = .failed
            // 不是目录（异常）或枚举失败都算该 root 不可读；未枚举成功不入 enumedRoots
            var rootFailed = false
            guard isDir.boolValue, let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in rootFailed = true; return true })
            else { continue }
            // 枚举器产出的 url.path 是 realpath 形式（/var → /private/var，URL 的
            // resolvingSymlinksInPath 不解析根级符号链接），前缀清理必须同口径，
            // 否则永不匹配、已删文件清不掉
            enumedRoots.append(realPath(root))

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let path = realPath(url.path)
                guard seen.insert(path).inserted else { continue }
                guard let vals = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = vals.fileSize
                else { rootFailed = true; continue }
                let sizeU = UInt64(size)
                let mtimeU = vals.contentModificationDate?.timeIntervalSince1970 ?? 0
                var fs = st.files[path] ?? FileState()
                // 文件只增不改：大小与 mtime 均未变才跳过（绝大多数文件走这里）
                if fs.offset == sizeU, let cached = fs.mtime, cached == mtimeU {
                    st.files[path] = fs; continue
                }
                // 首次见到且 31 天未修改：旧内容不可能贡献近 30 天数据，记录大小后跳过
                if fs.offset == 0, fs.days.isEmpty,
                   let mtime = vals.contentModificationDate, mtime < cutoff {
                    fs.offset = sizeU; fs.mtime = mtimeU; st.files[path] = fs; continue
                }
                // 截断/轮换：该文件的旧聚合已不可信，清零重扫
                if sizeU < fs.offset { fs = FileState() }
                // 同字节数整文件重写：offset 已追平但 mtime 与上次记录不同 → 旧聚合不可信，
                // 清零重扫（mtime 缺失为 0 时无法判断，保持旧行为避免每轮重扫）
                if fs.offset == sizeU, fs.mtime != nil, mtimeU != 0 { fs = FileState() }

                guard let fh = try? FileHandle(forReadingFrom: url) else { rootFailed = true; continue }
                fh.seek(toFileOffset: fs.offset)
                // 与 TokenScanner 同款分块读 + 行缓冲：首见的大文件不再整份载入内存；
                // 只消费到最后一个完整换行，正在被写入的残缺行留给下次
                var pending = Data()
                var consumed = fs.offset
                var readError = false
                while true {
                    let chunk: Data
                    do {
                        // nil / empty = 已到文件末尾（offset 追平属正常状态）；抛错才置失败
                        guard let read = try fh.read(upToCount: 256 * 1024) else { break }
                        chunk = read
                    } catch { readError = true; break }
                    if chunk.isEmpty { break }
                    var start = chunk.startIndex
                    while let nl = chunk[start...].firstIndex(of: 10) {
                        pending.append(contentsOf: chunk[start..<nl])
                        if let line = String(data: pending, encoding: .utf8) {
                            parseLine(line, cutoffKey: cutoffKey, into: &fs)
                        }
                        consumed += UInt64(pending.count) + 1
                        pending.removeAll(keepingCapacity: true)
                        start = chunk.index(after: nl)
                    }
                    pending.append(contentsOf: chunk[start...])
                }
                try? fh.close()
                if readError { rootFailed = true; continue }
                if consumed > fs.offset {
                    fs.offset = consumed
                    fs.mtime = mtimeU
                    fs.days = fs.days.filter { $0.key >= cutoffKey }
                    fs.daysByModel = fs.daysByModel.filter { $0.key >= cutoffKey }
                    st.files[path] = fs
                } else if fs.mtime != mtimeU {
                    // EOF 无新字节：补记 mtime 完成 v5 旧缓存条目迁移，
                    // 否则缺失 mtime 的条目每轮扫描都要空 open 一次
                    fs.mtime = mtimeU
                    st.files[path] = fs
                }
            }
            status[root] = rootFailed ? .failed : .available
            if rootFailed { enumedRoots.removeAll { $0 == realPath(root) } }
        }

        // 先快照再删：迭代中变更字典可能跳过条目（TokenScanner 同款写法）
        let vanished = st.files.keys.filter { path in
            !seen.contains(path) && enumedRoots.contains(where: { path.hasPrefix($0 + "/") })
        }
        for path in vanished {
            st.files.removeValue(forKey: path)
        }
        return (installed, enumedRoots.count, status)
    }

    /// 解析一批完整行，把 OpenAI 系模型的 usage 按日累加进 days。
    /// 时间字段：_createdAt(ms, Proma) / timestamp(ISO8601, Claude SDK) / time(ms, 兜底)；
    /// usage 位置：event.usage / 顶层 usage / message.usage（与 KimiUsage 同序）；
    /// input 含 cache read/write：对齐外部中转/用量 monitor 的总量口径
    ///（cache_read 是长会话每轮上下文全额重读，量级远大于净 input，别误当虚高）。
    static func parseLines(_ text: String, cutoffKey: String, into st: inout FileState) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            parseLine(String(line), cutoffKey: cutoffKey, into: &st)
        }
    }

    /// 解析单行；分块读取时逐行调用，避免把整个新增长度一次性转成 String
    static func parseLine(_ line: String, cutoffKey: String, into st: inout FileState) {
        guard line.contains("\"usage\""),
              let data = line.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return }
        // Proma result 行的 modelUsage / 顶层 usage 是全会话累计汇总，
        // 逐条 assistant 行已含每次调用，跳过汇总行避免双算
        if obj["modelUsage"] != nil { return }
        let t: Date
        if let ms = CodexNumber.finite(obj["_createdAt"]) {
            t = Date(timeIntervalSince1970: ms / 1000)
        } else if let ts = Fmt.iso(obj["timestamp"] as? String) {
            t = ts
        } else if let ms = CodexNumber.finite(obj["time"]) {
            t = Date(timeIntervalSince1970: ms / 1000)
        } else { return }
        let usage = (obj["event"] as? [String: Any])?["usage"] as? [String: Any]
            ?? obj["usage"] as? [String: Any]
            ?? (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
        guard let usage = usage else { return }
        let model = (obj["message"] as? [String: Any])?["model"] as? String
            ?? obj["model"] as? String
        guard let model = model, isOpenAIModel(model) else { return }
        // input 键名有 snake_case 与 camelCase 两套，分别来自不同产方；同一 usage 只出
        // 一套——任一主键 finite 命中即整套生效，缺失才回退别名，防止两套同名含义双算
        let inputKeys = ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]
        let inputAliases = ["input", "cacheRead", "cacheWrite"]
        var input: Double = 0
        for k in inputKeys.contains(where: { CodexNumber.finite(usage[$0]) != nil }) ? inputKeys : inputAliases {
            if let v = CodexNumber.finite(usage[k]) { input += v }
        }
        var output: Double = 0
        if let v = CodexNumber.finite(usage["output_tokens"]) { output = v }
        else if let v = CodexNumber.finite(usage["output"]) { output = v }
        let dayKey = dayFmt.string(from: t)
        if dayKey >= cutoffKey {
            var day = st.days[dayKey] ?? [0, 0]
            day[0] += input
            day[1] += output
            st.days[dayKey] = day
            var models = st.daysByModel[dayKey] ?? [:]
            var modelDay = models[model] ?? [0, 0]
            modelDay[0] += input
            modelDay[1] += output
            models[model] = modelDay
            st.daysByModel[dayKey] = models
        }
    }

    /// hermes 用量库（sqlite，只读打开，绝不写入）。累计行与上次快照做差，
    /// delta 按 last_seen 归日；计数变小说明上游重置，rebase 不倒扣。
    /// 返回是否成功读取（库文件不存在由调用方先行排除，不算失败）。
    private static func scanHermes(path: String, cutoffKey: String, into st: inout State, failAfterRows: Int?) -> Bool {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db
        else { _ = db.map { sqlite3_close($0) }; return false }
        // 上游 hermes 写入中（WAL/锁）时等待而非整轮置败；只读打开绝不写入
        sqlite3_busy_timeout(db, 2000)
        defer { sqlite3_close(db) }
        // 行身份键与 KimiUsage 一致：同一 (session,model) 可因 task/billing 拆成多行；
        // input 含 cache read/write（与文件来源同口径，对齐中转/monitor 总量）
        let sql = """
            SELECT session_id, model, billing_provider, billing_base_url, billing_mode, task,
                   input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen
            FROM session_model_usage
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        var hs = st.hermes ?? HermesState()
        var alive = Set<String>()
        var rowsRead = 0
        var stepResult = sqlite3_step(stmt)
        while stepResult == SQLITE_ROW {
            defer {
                rowsRead += 1
                stepResult = rowsRead == failAfterRows ? SQLITE_IOERR : sqlite3_step(stmt)
            }
            func col(_ i: Int32) -> String {
                sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            }
            let model = col(1)
            guard isOpenAIModel(model) else { continue }
            let key = (0...5).map { col(Int32($0)) }.joined(separator: "|")
            alive.insert(key)
            let cumIn = Double(sqlite3_column_int64(stmt, 6))
                + Double(sqlite3_column_int64(stmt, 8))
                + Double(sqlite3_column_int64(stmt, 9))
            let cumOut = Double(sqlite3_column_int64(stmt, 7))
            let lastSeen = sqlite3_column_double(stmt, 10)
            let old = hs.rows[key] ?? [0, 0]
            var dIn = cumIn - old[0], dOut = cumOut - old[1]
            if dIn < 0 || dOut < 0 { dIn = max(dIn, 0); dOut = max(dOut, 0) }
            hs.rows[key] = [cumIn, cumOut]
            guard dIn > 0 || dOut > 0, lastSeen > 0 else { continue }
            let dayKey = dayFmt.string(from: Date(timeIntervalSince1970: lastSeen))
            if dayKey >= cutoffKey {
                var day = hs.days[dayKey] ?? [0, 0]
                day[0] += dIn; day[1] += dOut
                hs.days[dayKey] = day
                var models = hs.daysByModel[dayKey] ?? [:]
                var modelDay = models[model] ?? [0, 0]
                modelDay[0] += dIn; modelDay[1] += dOut
                models[model] = modelDay
                hs.daysByModel[dayKey] = models
            }
        }
        guard stepResult == SQLITE_DONE else { return false }
        // 会话被 hermes 删除（ON DELETE CASCADE）的行：移出快照，停止差分
        hs.rows = hs.rows.filter { alive.contains($0.key) }
        hs.days = hs.days.filter { $0.key >= cutoffKey }
        hs.daysByModel = hs.daysByModel.filter { $0.key >= cutoffKey }
        st.hermes = hs
        return true
    }

    /// 按日聚合 → 今日/近7天/近30天（含今天共 7/30 个日历日，与 TokenScanner 一致）
    private static func buckets(_ st: State, now: Date) -> Result {
        let todayKey = dayFmt.string(from: now)
        let calendar = Calendar.current
        let d7Key = dayFmt.string(from: calendar.date(byAdding: .day, value: -6, to: now)!)
        let d30Key = dayFmt.string(from: calendar.date(byAdding: .day, value: -29, to: now)!)
        var allDays: [String: [Double]] = [:]
        var allModels: [String: [String: [Double]]] = [:]
        func mergeModels(_ source: [String: [String: [Double]]]) {
            for (day, models) in source {
                var target = allModels[day] ?? [:]
                for (model, values) in models {
                    var a = target[model] ?? [0, 0]
                    a[0] += values[0]; a[1] += values[1]
                    target[model] = a
                }
                allModels[day] = target
            }
        }
        for (_, f) in st.files {
            for (day, v) in f.days {
                var a = allDays[day] ?? [0, 0]
                a[0] += v[0]; a[1] += v[1]
                allDays[day] = a
            }
            mergeModels(f.daysByModel)
        }
        if let hermes = st.hermes {
            for (day, v) in hermes.days {
                var a = allDays[day] ?? [0, 0]
                a[0] += v[0]; a[1] += v[1]
                allDays[day] = a
            }
            mergeModels(hermes.daysByModel)
        }
        var r = Result()
        for (day, v) in allDays where day >= d30Key && day <= todayKey {
            r.thirty.input += v[0]; r.thirty.output += v[1]
            if day >= d7Key { r.seven.input += v[0]; r.seven.output += v[1] }
            if day >= todayKey { r.today.input += v[0]; r.today.output += v[1] }
        }
        for (day, models) in allModels where day >= d30Key && day <= todayKey {
            for (model, values) in models {
                addModel(&r.thirty.models, name: model, values: values)
                if day >= d7Key { addModel(&r.seven.models, name: model, values: values) }
                if day >= todayKey { addModel(&r.today.models, name: model, values: values) }
            }
        }
        return r
    }

    private static func addModel(_ models: inout [String: ModelTokenUsage], name: String, values: [Double]) {
        guard values.count == 2, values[0] + values[1] > 0 else { return }
        var stats = models[name] ?? ModelTokenUsage()
        stats.input += values[0]; stats.output += values[1]; stats.total += values[0] + values[1]
        models[name] = stats
    }

    private static func loadState(at path: String) -> State {
        if let data = FileManager.default.contents(atPath: path),
           let s = try? JSONDecoder().decode(State.self, from: data) {
            return s
        }
        return State()
    }

    private static func saveState(_ s: State, at path: String) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        // 复用凭据链的原子写：UUID 临时名 + rename + 仅所有者权限（与 TokenScanner 同口径）
        do {
            try AtomicJSONFile.replace(data, at: path)
        } catch {
            NSLog("[CodexUsage] ExternalTokenScanner saveState failed at %@: %@", path, error.localizedDescription)
        }
    }
}

// MARK: - 菜单栏堆叠两行文字渲染

/// 按界面展示的剩余百分比整数分档；标签与中间档继续使用系统文本色。
enum RemainingColorTier: Equatable {
    case green, normal, orange, red

    init(remaining: Int?) {
        guard let remaining = remaining else { self = .normal; return }
        switch remaining {
        case 80...: self = .green
        case 40..<80: self = .normal
        case 20..<40: self = .orange
        default: self = .red
        }
    }

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    func color(for appearance: NSAppearance) -> NSColor {
        let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
        switch self {
        case .green: return Self.rgb(dark ? 0x96CDA7 : 0x3E8660)
        case .normal: return .labelColor
        case .orange: return Self.rgb(dark ? 0xE5A37D : 0xB46539)
        case .red: return Self.rgb(dark ? 0xF08B94 : 0xC8404A)
        }
    }

    /// 动态颜色：不钉死绘制外观，由系统在每条菜单栏绘制时按该栏外观解析——
    /// 双屏两条栏底色不同（扩展屏全屏深色栏 + 主屏浅色栏）也能各自正确
    func color() -> NSColor {
        NSColor(name: nil) { appearance in self.color(for: appearance) }
    }
}

enum StackImage {
    struct Line {
        let label: String
        let value: String
        let remaining: Int?
    }

    private static func attributed(_ line: Line, font: NSFont) -> NSAttributedString {
        let result = NSMutableAttributedString(string: line.label + " ", attributes: [
            .font: font,
            .foregroundColor: NSColor.labelColor
        ])
        // 无数据时"--"用 tertiaryLabelColor，与正常值区分
        let valueColor: NSColor = line.value == "--"
            ? NSColor(name: nil) { _ in NSColor.tertiaryLabelColor }
            : RemainingColorTier(remaining: line.remaining).color()
        result.append(NSAttributedString(string: line.value, attributes: [
            .font: font,
            .foregroundColor: valueColor
        ]))
        return result
    }

    static func make(line1: Line, line2: Line?, appearance: NSAppearance? = nil) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 10.0, weight: .semibold)
        let s1 = attributed(line1, font: font)
        let s2 = line2.map { attributed($0, font: font) }
        let w = max(ceil(s1.size().width), ceil(s2?.size().width ?? 0)) + 2
        let draw = {
            s1.draw(at: NSPoint(x: 1, y: s2 == nil ? 5.5 : 10.5))
            s2?.draw(at: NSPoint(x: 1, y: 0.5))
        }
        let img = NSImage(size: NSSize(width: w, height: 21), flipped: false) { _ in
            // 正常时不钉死绘制外观，由系统按每条菜单栏各自解析动态颜色，兼容双屏不同底色。
            // 显式外观仅供离线像素测试使用，生产渲染始终跟随菜单栏自身外观。
            if let appearance = appearance {
                appearance.performAsCurrentDrawingAppearance(draw)
            } else {
                draw()
            }
            return true
        }
        img.isTemplate = false   // 保留百分比的柔彩色
        img.cacheMode = .never   // 小图直接重绘，避免菜单栏外观变化后复用旧颜色位图
        return img
    }
}

// MARK: - 格式化

enum Fmt {
    /// 剩余百分比（整数，100 − used_percent，夹在 0-100）
    static func remaining(_ usedPercent: Double?) -> Int? {
        guard let u = usedPercent else { return nil }
        let r = Int((100 - u).rounded())
        return max(0, min(100, r))
    }
    static func remainingPct(_ usedPercent: Double?) -> String {
        guard let r = remaining(usedPercent) else { return "--" }
        return "\(r)%"
    }
    static func remainingInt(_ w: QuotaWindow?) -> Int {
        remaining(w?.usedPercent) ?? -1
    }
    // 展示用 formatter 全部静态缓存：菜单每轮重建要调十几次，新建 DateFormatter 开销大
    private static func zhFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = format
        return f
    }
    private static let timeFmt = zhFormatter("HH:mm")
    private static let dayTimeFmt = zhFormatter("MM-dd HH:mm")
    private static let quotaResetFmt = zhFormatter("MM-dd EEE HH:mm")
    private static let dayOnlyFmt = zhFormatter("MM-dd")
    private static let expiresTodayFmt = zhFormatter("'今天' HH:mm")
    private static let expiresTomorrowFmt = zhFormatter("'明天' HH:mm")
    private static let expiresFullFmt = zhFormatter("yyyy-MM-dd HH:mm")

    static func time(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return timeFmt.string(from: d)
    }
    static func dayTime(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return dayTimeFmt.string(from: d)
    }
    static func quotaReset(_ d: Date) -> String {
        quotaResetFmt.string(from: d)
    }
    static func day(_ d: Date?) -> String {
        guard let d = d else { return "" }
        return dayOnlyFmt.string(from: d)
    }
    /// 重置卡到期提示（本地时区）：今天内 → "今天 HH:mm"；明天 → "明天 HH:mm"；否则完整日期
    static func expires(_ d: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(d) { return expiresTodayFmt.string(from: d) }
        if cal.isDateInTomorrow(d) { return expiresTomorrowFmt.string(from: d) }
        return expiresFullFmt.string(from: d)
    }
    /// 第三方内容（AIHOT 事件）的链接只允许 http/https 打开，其他 scheme 一律拒绝
    static func webURL(_ s: String) -> URL? {
        guard let url = URL(string: s), let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return url
    }
    /// token 数量缩写（B/M/K）：9,999 以内原样 / 123.4K / 1.23M / 1.23B（末尾多余的 .0 去掉）
    static func tokensAbbr(_ v: Double?) -> String {
        guard let v = v else { return "--" }
        if v >= 1_000_000_000 { return trim(v / 1_000_000_000, 2) + "B" }
        if v >= 1_000_000 { return trim(v / 1_000_000, 2) + "M" }
        if v >= 10_000 { return trim(v / 1_000, 1) + "K" }
        return String(format: "%.0f", v)
    }
    private static func trim(_ x: Double, _ digits: Int) -> String {
        var s = String(format: "%.\(digits)f", x)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }
    static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let isoPlain = ISO8601DateFormatter()
    /// status.json / 诊断用的无毫秒 ISO8601（缓存实例，供 writeStatus 每轮刷新复用）
    static func isoStamp(_ d: Date?) -> String { d.map { isoPlain.string(from: $0) } ?? "" }
    /// ISO8601 字符串（带/不带毫秒）→ Date；外部会话 timestamp 字段用
    static func iso(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }
    private static let isoNoZone: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    /// reset_at 兼容：epoch 秒 / epoch 毫秒（>10^10）/ ISO8601 字符串
    static func parseDateValue(_ v: Any?) -> Date? {
        if v is NSNumber {
            guard let s = CodexNumber.finite(v), s > 0 else { return nil }
            return Date(timeIntervalSince1970: s > 10_000_000_000 ? s / 1000 : s)
        }
        if let str = v as? String, !str.isEmpty {
            if let d = isoFrac.date(from: str) { return d }
            if let d = isoPlain.date(from: str) { return d }
            if let d = isoNoZone.date(from: str) { return d }
        }
        return nil
    }
}


// 从应用直接启动更新子进程，保留 TCC 的责任应用归属。
// nohup 与独立的临时脚本确保应用退出换包后，子进程仍能完成更新或回滚。
// 进度在下拉面板内原位展示（更新按钮变进度行），不再弹独立窗口、不抢占焦点：
// 任务与 UI 解耦，关闭面板不影响更新，重开面板时根据这里的状态恢复进度行；
// 失败另用 alert 兜底，因为那一刻面板可能已经关闭。
final class UpdateProgressController: NSObject {
    static let shared = UpdateProgressController()
    static let didChangeNotification = Notification.Name("CodexUsage.UpdateProgress.didChange")

    enum Phase: Equatable {
        case idle, preparing, downloading, verifying, staging, installing, finished, failed
    }

    private(set) var phase: Phase = .idle
    private(set) var fraction: Double = 0   // 仅 downloading 阶段有意义，0–100
    /// 进行中（含安装重启阶段）；失败/结束后恢复为可点击的更新按钮
    var isActive: Bool { [.preparing, .downloading, .verifying, .staging, .installing].contains(phase) }
    var statusLine: String {
        switch phase {
        case .idle: return ""
        case .preparing: return "正在准备更新…"
        case .downloading: return "正在下载更新… \(Int(fraction))%"
        case .verifying: return "正在校验更新…"
        case .staging: return "正在准备安装…"
        case .installing: return "正在安装并重启…"
        case .finished: return "更新完成，正在重启…"
        case .failed: return "更新失败"
        }
    }
    /// 安装阶段的重启预告：用户需要知道应用即将自己退出，不是异常消失
    var detailLine: String? {
        phase == .installing ? "应用将自动退出并重启，无需手动操作" : nil
    }

    private var timer: Timer?
    private var directory: URL?

    func start(script: String, targetTag: String, appPath: String) {
        guard !isActive else { return }   // 进度行已替换按钮，这里再兜底防重入
        do {
            let dir = FileManager.default.temporaryDirectory.appendingPathComponent("usage-update-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            directory = dir
            let copiedScript = dir.appendingPathComponent("update.sh")
            try FileManager.default.copyItem(atPath: script, toPath: copiedScript.path)
            let wrapper = dir.appendingPathComponent("run.sh")
            let wrapperText = """
            #!/bin/bash
            cd "$1" || exit 1
            export UPDATE_PROGRESS_FILE="$1/progress"
            /bin/bash "$1/update.sh" "$2" "$3" > "$1/log" 2>&1
            result=$?
            # 先写临时文件再 mv：轮询方读到空 result 不会误判为失败
            printf '%s' "$result" > "$1/.result.tmp"
            /bin/mv "$1/.result.tmp" "$1/result"
            if [ "$result" -ne 0 ] && /usr/bin/grep -q '4/5' "$1/log"; then
                detail=$(/usr/bin/grep '!!' "$1/log" | /usr/bin/tail -1)
                /usr/bin/osascript - "${detail:-更新未完成，请查看日志。}" "$1/log" <<'APPLESCRIPT' >/dev/null 2>&1
            on run argv
                display dialog ((item 1 of argv) & return & return & "日志：" & (item 2 of argv)) with title "更新失败" buttons {"好"} default button 1 with icon caution
            end run
            APPLESCRIPT
            fi
            if [ "$result" -eq 0 ]; then /bin/sleep 5; /bin/rm -rf "$1"; fi
            exit "$result"
            """
            try wrapperText.write(to: wrapper, atomically: true, encoding: .utf8)
            phase = .preparing
            fraction = 0
            notify()
            let launch = Process()
            launch.executableURL = URL(fileURLWithPath: "/usr/bin/nohup")
            launch.arguments = ["/bin/bash", wrapper.path, dir.path, targetTag, appPath]
            launch.currentDirectoryURL = dir
            launch.standardInput = FileHandle.nullDevice
            launch.standardOutput = FileHandle.nullDevice; launch.standardError = FileHandle.nullDevice
            try launch.run()
            timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in self?.refresh() }
        } catch {
            finishError("无法启动更新，请稍后重试。")
        }
    }

    private func notify() {
        NotificationCenter.default.post(name: Self.didChangeNotification, object: self)
    }

    private func setPhase(_ newPhase: Phase, fraction newFraction: Double? = nil) {
        let changed = phase != newPhase || (newFraction.map { $0 != fraction } ?? false)
        phase = newPhase
        if let newFraction = newFraction { fraction = newFraction }
        if changed { notify() }
    }

    private func refresh() {
        guard let dir = directory else { return }
        let log = (try? String(contentsOf: dir.appendingPathComponent("log"), encoding: .utf8)) ?? ""
        if log.contains("4/5") || log.contains("5/5") { setPhase(.installing) }
        else if log.contains("3/5") { setPhase(.staging) }
        else if log.contains("2/5") { setPhase(.verifying) }
        else if log.contains("下载 v") {
            var value: Double?
            if let text = try? String(contentsOf: dir.appendingPathComponent("progress"), encoding: .utf8),
               let regex = try? NSRegularExpression(pattern: #"([0-9]+(?:\.[0-9]+)?)%"#),
               let match = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).last,
               let range = Range(match.range(at: 1), in: text) {
                value = Double(text[range])
            }
            setPhase(.downloading, fraction: value)   // 百分比尚未写出时保留旧值
        }
        if let result = try? String(contentsOf: dir.appendingPathComponent("result"), encoding: .utf8) {
            let code = result.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !code.isEmpty else { return }   // result 尚未写完整，下轮再读
            timer?.invalidate(); timer = nil
            if code == "0" {
                // 正常路径下旧进程已被脚本替换重启，走不到这里；兜底停止轮询
                setPhase(.finished)
            } else if log.contains("4/5") || log.contains("5/5") {
                // 停机/换包阶段失败由 wrapper 弹系统对话框兜底（那一刻本进程可能已被替换），
                // 这里只恢复面板按钮状态，不再重复弹模态框
                directory = nil
                setPhase(.failed)
            } else {
                let detail = log.components(separatedBy: .newlines).last(where: { $0.contains("!!") }) ?? "更新未完成，请查看日志。"
                finishError(detail.replacingOccurrences(of: "!! ", with: ""))
            }
        }
    }

    private func finishError(_ detail: String) {
        timer?.invalidate(); timer = nil
        phase = .failed
        notify()   // 先恢复面板里的更新按钮，再模态弹窗
        let alert = NSAlert(); alert.messageText = "更新失败"; alert.informativeText = detail
        if let dir = directory { alert.informativeText += "\n\n日志：\(dir.appendingPathComponent("log").path)" }
        alert.addButton(withTitle: "好"); alert.runModal()
        directory = nil
    }

    /// 视觉预览专用：不启动子进程，仅呈现进行中的进度行。
    func simulateForPreview(phase previewPhase: Phase, fraction previewFraction: Double) {
        phase = previewPhase
        fraction = previewFraction
    }
}

/// 下拉面板内的更新进度行：原位替换「新版本可用」按钮。
/// 自身订阅进度通知刷新文本与进度条，避免每 0.25s 重建整个面板；
/// 面板关闭后重开，rebuildContent 会新建本行并同步到当前进度。
final class UpdateProgressRowView: NSView {
    private let status = PanelUI.label("", size: 12, weight: .semibold, wrapping: false)
    private let detail = PanelUI.label("", size: 10, color: .secondaryLabelColor)
    private let bar = NSProgressIndicator()
    private var observer: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        translatesAutoresizingMaskIntoConstraints = false
        bar.style = .bar
        bar.translatesAutoresizingMaskIntoConstraints = false
        let stack = PanelUI.stack(spacing: 6)
        PanelUI.addFullWidth(status, to: stack)
        PanelUI.addFullWidth(bar, to: stack)
        PanelUI.addFullWidth(detail, to: stack)
        addSubview(stack)
        PanelUI.pin(stack, to: self)
        observer = NotificationCenter.default.addObserver(
            forName: UpdateProgressController.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.sync() }
        sync()
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    deinit {
        if let observer = observer { NotificationCenter.default.removeObserver(observer) }
    }

    private func sync() {
        let controller = UpdateProgressController.shared
        status.stringValue = controller.statusLine
        detail.stringValue = controller.detailLine ?? ""
        detail.isHidden = controller.detailLine == nil
        if controller.phase == .downloading {
            if bar.isIndeterminate { bar.stopAnimation(nil) }
            bar.isIndeterminate = false
            bar.minValue = 0; bar.maxValue = 100
            bar.doubleValue = controller.fraction
        } else {
            if !bar.isIndeterminate { bar.isIndeterminate = true }
            bar.startAnimation(nil)
        }
    }
}

// MARK: - 版本与更新检查（成熟项目惯例，Sparkle 生态同款语义：只认 GitHub Release，
// 不认 main 分支 commit——日常 push 与用户无关，发布了更高版本才提示。
// build.sh 打包时写 Info.plist 自定义键；就地更新脚本随包内置，见 Resources/update.sh）

/// 构建版本：build.sh 打包时写入产物 Info.plist 自定义键（CUBuildVersion，git describe），
/// 运行时读 Bundle。仓库模板没有该键 → 非 build.sh 产物（直接 swiftc 的裸二进制）为 unknown，
/// 此时更新检查自然禁用、菜单显示「版本 unknown」。不生成第二个 .swift：多文件编译下
/// 只有 main.swift 允许 top-level 代码，本文件的命令行入口依赖 top-level。
enum BuildInfo {
    static let version = (Bundle.main.infoDictionary?["CUBuildVersion"] as? String) ?? "unknown"
}

/// 更新判定的纯逻辑：Release 版本号比较（--self-test 覆盖）。
/// 提示的唯一触发条件是「GitHub 发布了更高版本的 Release」；commit hash 回答的是
/// 「分支动没动」，不代表存在可安装的新版本。
enum UpdateCheck {
    static let apiURL = URL(string: "https://api.github.com/repos/JUNX7764/Codexusage/releases?per_page=20")!
    static let releasesPage = URL(string: "https://github.com/JUNX7764/Codexusage/releases")!
    /// GitHub 匿名限额 60 次/小时/IP，30 分钟一查仅 2 次/小时；ETag/304 条件请求不耗配额
    static let interval: TimeInterval = 30 * 60

    /// 版本号归一化：v1.0.1 / v1.0.1-3-gabc / v1.0.1-dirty → [1, 0, 1]；
    /// 破折号后缀（预发布/dirty/git describe 尾巴）丢弃，任一段非数字视为无法比较
    static func normalized(_ v: String) -> [Int]? {
        var core = v.trimmingCharacters(in: .whitespaces).lowercased()
        guard !core.isEmpty else { return nil }
        if core.hasPrefix("v") { core.removeFirst() }
        if let dash = core.firstIndex(of: "-") { core = String(core[..<dash]) }
        guard !core.isEmpty else { return nil }
        var parts: [Int] = []
        for seg in core.split(separator: ".") {
            guard let n = Int(seg), n >= 0 else { return nil }
            parts.append(n)
        }
        return parts.isEmpty ? nil : parts
    }

    /// 已装版本是否低于远端 Release 版本。任一侧无法解析（unknown / 裸二进制 / 非法 tag）
    /// = 不提示；逐段数值比较（1.10 > 1.9），短侧补 0（1.2 == 1.2.0）
    static func isOutdated(local: String, remote: String) -> Bool {
        guard var l = normalized(local), var r = normalized(remote) else { return false }
        if l.count < r.count { l.append(contentsOf: repeatElement(0, count: r.count - l.count)) }
        if r.count < l.count { r.append(contentsOf: repeatElement(0, count: l.count - r.count)) }
        for i in 0..<l.count where l[i] != r[i] {
            return l[i] < r[i]
        }
        return false
    }

    /// GitHub 按创建时间倒序返回 Release；空 Release 或附件上传不完整时跳过，
    /// 与 update.sh 选择同一个「最近可安装版本」，避免提示后下载 404。
    static func latestDownloadableRelease(in releases: [[String: Any]]) -> (tag: String, notes: String)? {
        for release in releases {
            guard let tag = release["tag_name"] as? String,
                  tag.range(of: "^v?[0-9]+(\\.[0-9]+)+$", options: .regularExpression) != nil,
                  release["draft"] as? Bool != true, release["prerelease"] as? Bool != true
            else { continue }
            let assets = release["assets"] as? [[String: Any]] ?? []
            let names = Set(assets.compactMap { $0["name"] as? String })
            if names.contains("CodexUsage.zip") && names.contains("CodexUsage.zip.sha256") {
                return (tag, release["body"] as? String ?? "")
            }
        }
        return nil
    }

    static func latestDownloadableTag(in releases: [[String: Any]]) -> String? {
        latestDownloadableRelease(in: releases)?.tag
    }

    static func displayNotes(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return "本版本暂未提供详细更新说明" }
        return trimmed.components(separatedBy: .newlines).map { line in
            var value = line
            if let range = value.range(of: #"^#{1,6}\s+"#, options: .regularExpression) { value.removeSubrange(range) }
            if let range = value.range(of: #"^\s*[-*]\s+"#, options: .regularExpression) { value.replaceSubrange(range, with: "• ") }
            return value.replacingOccurrences(of: "**", with: "")
        }.joined(separator: "\n")
    }
}

/// 更新检查状态：低频匿名请求 GitHub，失败静默保留旧结论（不打扰主刷新，也不弹任何东西）。
/// 状态只在主线程读写（回调统一 dispatch 回主线程），无需加锁。
final class UpdateChecker {
    enum Result { case current, available, failed, unknownVersion }
    static let shared = UpdateChecker()
    private(set) var available = false
    private(set) var availableTag: String?
    private(set) var releaseNotes = ""
    private var etag: String?
    private var lastCheck: Date?
    private var inFlight = false
    private var lastResult: Result = .failed
    private var completions: [(Result) -> Void] = []

    func check(force: Bool = false, completion: @escaping (Result) -> Void = { _ in }) {
        if inFlight { completions.append(completion); return }
        if !force, let last = lastCheck, Date().timeIntervalSince(last) < UpdateCheck.interval {
            completion(lastResult)
            return
        }
        completions.append(completion)
        inFlight = true
        var req = URLRequest(url: UpdateCheck.apiURL, timeoutInterval: 15)
        req.cachePolicy = .reloadIgnoringLocalCacheData
        req.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        req.setValue("CodexUsage/1.0 (menubar; update check)", forHTTPHeaderField: "User-Agent")
        if let etag = etag { req.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        URLSession.shared.dataTask(with: req) { [weak self] data, resp, err in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.inFlight = false
                self.lastCheck = Date()
                let http = resp as? HTTPURLResponse
                var result: Result = .failed
                if err == nil, http?.statusCode == 304, self.etag != nil {
                    result = UpdateCheck.normalized(BuildInfo.version) == nil ? .unknownVersion : (self.available ? .available : .current)
                } else if err == nil, let data = data, http?.statusCode == 200,
                          let releases = (try? JSONSerialization.jsonObject(with: data)) as? [[String: Any]] {
                    if UpdateCheck.normalized(BuildInfo.version) == nil {
                        result = .unknownVersion
                    } else if let release = UpdateCheck.latestDownloadableRelease(in: releases) {
                        let tag = release.tag
                        self.releaseNotes = release.notes
                        self.available = UpdateCheck.isOutdated(local: BuildInfo.version, remote: tag)
                        self.availableTag = self.available ? tag : nil
                        result = self.available ? .available : .current
                    } else {
                        // 没有附件齐全的 Release：检查本身成功，结论为无可安装更新
                        self.available = false
                        self.availableTag = nil
                        self.releaseNotes = ""
                        result = .current
                    }
                    self.etag = http?.value(forHTTPHeaderField: "ETag")
                }
                self.lastResult = result
                let callbacks = self.completions
                self.completions.removeAll()
                callbacks.forEach { $0(result) }
            }
        }.resume()
    }
}

// MARK: - 自定义下拉面板（typed model + 原生 AppKit 组件）

struct UsagePanelModel {
    enum NoticeLevel {
        case info, warning, error
    }
    struct Notice {
        var text: String
        var level: NoticeLevel
    }
    struct Quota {
        var title: String
        var resetText: String
        var remaining: Int?
        var notices: [Notice]
    }
    struct ResetRow {
        var name: String
        var expires: String
        var warning: Bool
    }
    struct ResetSection {
        var count: Int?
        var emptyText: String?
        var rows: [ResetRow]
        var notices: [Notice]
        var useTitle: String? = nil
        var useEnabled: Bool = false
    }
    struct TiboRow {
        var text: String
        var confirmed: Bool   // 已确认发放，渲染时显示 checkmark.circle.fill
        var item: NSMenuItem?
    }
    struct TiboSection {
        var rows: [TiboRow]
        var notices: [Notice]
    }
    struct TokenModel {
        var name: String
        var total: String
        var input: String
        var output: String
    }
    struct TokenBucket {
        var summaryLabel: String
        var detailLabel: String
        var total: String
        var input: String
        var output: String
        var models: [TokenModel]
        var hasData: Bool
    }
    struct TokenSection {
        var title: String
        var accent: PanelAccent
        var buckets: [TokenBucket]
        var notices: [Notice]
    }

    var updateItem: NSMenuItem?
    var title: String
    var plan: String?
    var email: String?
    var quotas: [Quota]
    var resetCards: ResetSection?
    var tibo: TiboSection?
    var codexTokens: TokenSection
    var official: OfficialUsageSnapshot?
    var officialError: String?
    var quotaHistory: QuotaCycleSnapshot
    var quotaHistoryAvailable: Bool
    var officialTodayFill: Double?   // 官方日桶缺今日时以与用量情况同口径的本机合并今日用量补足（Codex+外部）
    var tools: [[(name: String, total: Double?, input: Double?, output: Double?, status: UsageSourceStatus)]]
    var notices: [Notice]
    var lastAttempt: String
    var version: String
    var refreshItem: NSMenuItem
    var loginItem: NSMenuItem
    var quitItem: NSMenuItem
}

enum TokenModelList {
    static func visible(_ models: [String: ModelTokenUsage]) -> [(name: String, stats: ModelTokenUsage)] {
        models.filter { $0.value.total > 0 }
            .sorted { lhs, rhs in
                lhs.value.total != rhs.value.total ? lhs.value.total > rhs.value.total : lhs.key < rhs.key
            }
            .map { (name: $0.key, stats: $0.value) }
    }
}

enum PanelAccent {
    case codex, external

    private static func rgb(_ hex: UInt32) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xff) / 255,
                green: CGFloat((hex >> 8) & 0xff) / 255,
                blue: CGFloat(hex & 0xff) / 255,
                alpha: 1)
    }

    var color: NSColor {
        NSColor(name: nil) { appearance in
            let dark = appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            switch self {
            case .codex: return RemainingColorTier.orange.color(for: appearance)
            case .external: return Self.rgb(dark ? 0x86BDE8 : 0x2B6F9E)
            }
        }
    }

    var symbol: String {
        switch self {
        case .codex: return "square.stack.3d.up.fill"
        case .external: return "square.stack.3d.up"
        }
    }
}

private enum PanelUI {
    static let separatorHeight: CGFloat = 1

    static func stack(orientation: NSUserInterfaceLayoutOrientation = .vertical,
                      alignment: NSLayoutConstraint.Attribute = .width,
                      spacing: CGFloat = 8) -> NSStackView {
        let stack = NSStackView()
        stack.orientation = orientation
        stack.alignment = alignment
        stack.spacing = spacing
        stack.translatesAutoresizingMaskIntoConstraints = false
        return stack
    }

    static func addFullWidth(_ view: NSView, to stack: NSStackView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
    }

    static func pin(_ view: NSView, to container: NSView) {
        NSLayoutConstraint.activate([
            view.topAnchor.constraint(equalTo: container.topAnchor),
            view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            view.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])
    }

    static func label(_ text: String, size: CGFloat = 12,
                      weight: NSFont.Weight = .regular,
                      color: NSColor = .labelColor,
                      wrapping: Bool = true,
                      monospacedDigits: Bool = false) -> NSTextField {
        let label = NSTextField(wrappingLabelWithString: text)
        label.font = monospacedDigits
            ? NSFont.monospacedDigitSystemFont(ofSize: size, weight: weight)
            : NSFont.systemFont(ofSize: size, weight: weight)
        label.textColor = color
        label.maximumNumberOfLines = wrapping ? 0 : 1
        label.cell?.lineBreakMode = wrapping ? .byWordWrapping : .byTruncatingTail
        label.translatesAutoresizingMaskIntoConstraints = false
        label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        return label
    }

    static func symbol(_ name: String, size: CGFloat = 16,
                       color: NSColor = .secondaryLabelColor) -> NSImageView {
        let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)
        let view = NSImageView(image: image ?? NSImage())
        view.contentTintColor = color
        view.symbolConfiguration = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.required, for: .horizontal)
        return view
    }

    static func spacer() -> NSView {
        let view = NSView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.setContentHuggingPriority(.init(1), for: .horizontal)
        view.setContentCompressionResistancePriority(.init(1), for: .horizontal)
        return view
    }

    static func separator() -> NSBox {
        let line = NSBox()
        line.boxType = .separator
        line.translatesAutoresizingMaskIntoConstraints = false
        line.heightAnchor.constraint(equalToConstant: separatorHeight).isActive = true
        return line
    }

    static func notices(_ notices: [UsagePanelModel.Notice]) -> [NSView] {
        notices.map { notice in
            let color: NSColor
            switch notice.level {
            case .info: color = .secondaryLabelColor
            case .warning: color = PanelAccent.codex.color
            case .error: color = .systemRed
            }
            return label(notice.text, size: 11, color: color)
        }
    }
}

enum PanelBackgroundStyle: String, CaseIterable {
    case solid, liquidGlass, classicMaterial
    static let defaultsKey = "panelBackgroundStyle"
    var menuTitle: String {
        switch self { case .solid: return "纯色"; case .liquidGlass: return "液态玻璃"; case .classicMaterial: return "经典毛玻璃" }
    }
    static func parse(_ raw: String?) -> Self { Self(rawValue: raw ?? "") ?? .solid }
    func effective(liquidSupported: Bool, reduceTransparency: Bool) -> Self {
        if reduceTransparency { return .solid }
        return self == .liquidGlass && !liquidSupported ? .classicMaterial : self
    }
}

final class PanelSolidBackgroundView: NSView {
    var opacity: CGFloat = 1 { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(opacity).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class PanelActionButton: NSButton {
    enum Style {
        case plain, prominent, checkbox, subtleAccent
    }

    var menuItem: NSMenuItem?
    var style: Style = .plain { didSet { needsDisplay = true } }
    private var hovered = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            switch style {
            case .prominent:
                let color = PanelAccent.codex.color
                layer?.backgroundColor = color.withAlphaComponent(hovered ? 0.78 : 1).cgColor
            case .plain:
                layer?.backgroundColor = (hovered
                    ? NSColor.labelColor.withAlphaComponent(0.08)
                    : NSColor.clear).cgColor
            case .subtleAccent:
                layer?.backgroundColor = PanelAccent.codex.color.withAlphaComponent(hovered ? 0.28 : 0.18).cgColor
            case .checkbox:
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
}

private enum PanelSurface {
    static var fill: NSColor { NSColor.labelColor.withAlphaComponent(0.035) }
    static var comparisonFill: NSColor { NSColor.labelColor.withAlphaComponent(0.06) }
}

private final class PanelComparisonStack: NSStackView {
    override var wantsUpdateLayer: Bool { true }
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        orientation = .horizontal; alignment = .centerY; spacing = 4
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true; layer?.cornerRadius = 6
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance { layer?.backgroundColor = PanelSurface.comparisonFill.cgColor }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance(); needsDisplay = true
    }
}

class PanelCardView: NSView {
    let contentStack = PanelUI.stack(spacing: 4)

    init(padding: CGFloat = 12) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.borderWidth = 0.5
        addSubview(contentStack)
        NSLayoutConstraint.activate([
            contentStack.topAnchor.constraint(equalTo: topAnchor, constant: padding),
            contentStack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: padding),
            contentStack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -padding),
            contentStack.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -padding)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = PanelSurface.fill.cgColor
            layer?.borderColor = NSColor.labelColor.withAlphaComponent(0.09).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

/// Only explicit plan names are classified; quota values never identify a subscription.
private struct SubscriptionBadge {
    let title: String
    let rgb: UInt32

    static func resolve(_ raw: String?, apiKey: Bool = false) -> SubscriptionBadge {
        if apiKey { return SubscriptionBadge(title: "API Key", rgb: 0x64748B) }
        let key = (raw ?? "").trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            .replacingOccurrences(of: "_", with: " ").replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        switch key {
        case "api key", "apikey": return .init(title: "API Key", rgb: 0x64748B)
        case "free": return .init(title: "Free", rgb: 0x949BA6)
        case "go": return .init(title: "Go", rgb: 0x16A6A1)
        case "plus": return .init(title: "Plus", rgb: 0x2887E8)
        case "pro 100": return .init(title: "Pro 100", rgb: 0x8B5CF6)
        case "pro 200": return .init(title: "Pro 200", rgb: 0xE2A23A)
        case "pro 500": return .init(title: "Pro 500", rgb: 0xE46B45)
        case "pro", "prolite", "pro 5x", "pro 20x", "pro5x", "pro20x":
            return .init(title: "Pro", rgb: 0x8B5CF6)
        case "business standard": return .init(title: "Business Standard", rgb: 0x3976B9)
        case "business premium": return .init(title: "Business Premium", rgb: 0x256F78)
        case "enterprise": return .init(title: "Enterprise", rgb: 0x38465F)
        case "edu": return .init(title: "Edu", rgb: 0x578E68)
        default: return .init(title: "Unknown", rgb: 0x9CA3AF)
        }
    }

    var color: NSColor {
        NSColor(srgbRed: CGFloat((rgb >> 16) & 255) / 255,
                green: CGFloat((rgb >> 8) & 255) / 255,
                blue: CGFloat(rgb & 255) / 255, alpha: 1)
    }
}

/// 套餐徽标：layer 背景随当前绘制外观解析（与 PanelCardView 同款），深浅色切换即时响应
private final class PlanBadgeLabel: NSTextField {
    var planColor: NSColor = .secondaryLabelColor
    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            let dark = effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
            layer?.backgroundColor = planColor.withAlphaComponent(dark ? 0.22 : 0.14).cgColor
            textColor = planColor.blended(withFraction: dark ? 0.38 : 0.30,
                                          of: dark ? .white : .black) ?? planColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class PanelHeaderView: NSView {
    init(model: UsagePanelModel, backgroundTarget: AnyObject? = nil, backgroundAction: Selector? = nil) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 12)
        let icon = NSImageView(image: NSApp.applicationIconImage)
        icon.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            icon.widthAnchor.constraint(equalToConstant: 32),
            icon.heightAnchor.constraint(equalToConstant: 32)
        ])
        row.addArrangedSubview(icon)
        let titles = PanelUI.stack(spacing: 2)
        titles.alignment = .leading
        let titleRow = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 7)
        let title = PanelUI.label(model.title, size: 15, weight: .semibold, wrapping: false)
        titleRow.addArrangedSubview(title)
        if let plan = model.plan, !plan.isEmpty {
            let subscription = SubscriptionBadge.resolve(plan)
            let badge = PlanBadgeLabel(wrappingLabelWithString: " " + subscription.title + " ")
            badge.planColor = subscription.color
            badge.font = .systemFont(ofSize: 10, weight: .semibold)
            badge.maximumNumberOfLines = 1
            badge.cell?.lineBreakMode = .byTruncatingTail
            badge.translatesAutoresizingMaskIntoConstraints = false
            badge.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
            badge.wantsLayer = true; badge.layer?.cornerRadius = 5
            badge.toolTip = plan; titleRow.addArrangedSubview(badge)
        }
        titleRow.addArrangedSubview(PanelUI.spacer())
        PanelUI.addFullWidth(titleRow, to: titles)
        if let email = model.email, !email.isEmpty {
            let emailLabel = PanelUI.label(email, size: 11, color: .secondaryLabelColor)
            PanelUI.addFullWidth(emailLabel, to: titles)
        }
        row.addArrangedSubview(titles)
        row.addArrangedSubview(PanelUI.spacer())
        if let target = backgroundTarget, let action = backgroundAction {
            let image = NSImage(systemSymbolName: "paintpalette", accessibilityDescription: "背景样式")?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular))
            let button = NSButton(image: image ?? NSImage(), target: target, action: action)
            button.isBordered = false; button.contentTintColor = .secondaryLabelColor
            button.toolTip = "背景样式"; button.setAccessibilityLabel("背景样式")
            button.widthAnchor.constraint(equalToConstant: 24).isActive = true
            button.heightAnchor.constraint(equalToConstant: 24).isActive = true
            row.addArrangedSubview(button)
        }
        addSubview(row)
        PanelUI.pin(row, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

enum UsageBarMetrics {
    static let height: CGFloat = 8
    static let cornerRadius = height / 2
}

final class QuotaProgressView: NSView {
    var remaining: Int? { didSet { needsLayout = true; needsDisplay = true } }
    private let fill = CALayer()

    init(remaining: Int?) {
        self.remaining = remaining
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        wantsLayer = true
        layer?.cornerRadius = UsageBarMetrics.cornerRadius
        layer?.masksToBounds = true
        fill.cornerRadius = UsageBarMetrics.cornerRadius
        layer?.addSublayer(fill)
        heightAnchor.constraint(equalToConstant: UsageBarMetrics.height).isActive = true
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override var wantsUpdateLayer: Bool { true }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.12).cgColor
            fill.backgroundColor = RemainingColorTier(remaining: remaining).color(for: effectiveAppearance).cgColor
        }
    }
    override func layout() {
        super.layout()
        let value = CGFloat(max(0, min(100, remaining ?? 0))) / 100
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        fill.frame = CGRect(x: 0, y: 0, width: bounds.width * value, height: bounds.height)
        CATransaction.commit()
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
}

final class QuotaWindowView: NSView {
    init(model: UsagePanelModel.Quota, compact: Bool = false) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let root = PanelUI.stack(spacing: 4)
        let main = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        let shortTitle = model.title.replacingOccurrences(of: "窗口", with: "")
        let title = PanelUI.label(shortTitle, size: 12, weight: .semibold, wrapping: false)
        title.setContentCompressionResistancePriority(.required, for: .horizontal)
        title.widthAnchor.constraint(equalToConstant: 43).isActive = true
        main.addArrangedSubview(title)
        let remainingColor = NSColor(name: nil) { appearance in
            RemainingColorTier(remaining: model.remaining).color(for: appearance)
        }
        let remaining = PanelUI.label(model.remaining.map { "\($0)%" } ?? "--",
            size: 14, weight: .semibold, color: remainingColor,
            wrapping: false, monospacedDigits: true)
        // 保留两位百分比时的对齐宽度；100% 按实际文字宽度扩展，避免百分号被截断。
        remaining.widthAnchor.constraint(greaterThanOrEqualToConstant: 40).isActive = true
        remaining.setContentHuggingPriority(.required, for: .horizontal)
        remaining.setContentCompressionResistancePriority(.required, for: .horizontal)
        main.addArrangedSubview(remaining)
        let progress = QuotaProgressView(remaining: model.remaining)
        progress.widthAnchor.constraint(greaterThanOrEqualToConstant: 32).isActive = true
        progress.setContentHuggingPriority(.defaultLow, for: .horizontal)
        main.addArrangedSubview(progress)
        let reset = PanelUI.label(model.resetText, size: 12, weight: .semibold,
            wrapping: false, monospacedDigits: true)
        reset.alignment = .right
        reset.setContentHuggingPriority(.required, for: .horizontal)
        reset.setContentCompressionResistancePriority(.required, for: .horizontal)
        main.addArrangedSubview(reset)
        PanelUI.addFullWidth(main, to: root)
        for notice in PanelUI.notices(model.notices) {
            PanelUI.addFullWidth(notice, to: root)
        }
        addSubview(root)
        PanelUI.pin(root, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class QuotaCardSectionView: PanelCardView {
    init(quotas: [UsagePanelModel.Quota]) {
        super.init(padding: 8)
        contentStack.spacing = 6
        let header = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        header.heightAnchor.constraint(equalToConstant: 24).isActive = true
        header.addArrangedSubview(PanelUI.symbol("stopwatch", size: 14, color: PanelAccent.codex.color))
        header.addArrangedSubview(PanelUI.label("用量进度", size: 12, weight: .semibold, wrapping: false))
        header.addArrangedSubview(PanelUI.spacer())
        let resetHeading = PanelUI.label("重置时间", size: 10, color: .secondaryLabelColor, wrapping: false)
        header.addArrangedSubview(resetHeading)
        PanelUI.addFullWidth(header, to: contentStack)
        for quota in quotas {
            let row = QuotaWindowView(model: quota)
            row.heightAnchor.constraint(equalToConstant: 24).isActive = true
            PanelUI.addFullWidth(row, to: contentStack)
        }
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class ResetCardSectionView: PanelCardView {
    init(model: UsagePanelModel.ResetSection, target: AnyObject, action: Selector) {
        super.init(padding: 8)
        let header = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        header.addArrangedSubview(PanelUI.symbol("calendar", size: 14, color: PanelAccent.codex.color))
        header.addArrangedSubview(PanelUI.label("重置卡", size: 12, weight: .semibold, wrapping: false))
        if let count = model.count {
            header.addArrangedSubview(PanelUI.label("×\(count)", size: 12, weight: .semibold,
                color: PanelAccent.codex.color, wrapping: false, monospacedDigits: true))
        } else if let empty = model.emptyText {
            header.addArrangedSubview(PanelUI.label(empty, size: 11, color: .secondaryLabelColor, wrapping: false))
        }
        header.addArrangedSubview(PanelUI.spacer())
        if let title = model.useTitle {
            let button = PanelActionButton(frame: .zero)
            button.style = .subtleAccent
            button.title = title
            button.target = target
            button.action = action
            button.wantsLayer = true
            button.layer?.cornerRadius = 6
            button.isBordered = false
            button.focusRingType = .none
            button.image = NSImage(systemSymbolName: "ticket.fill", accessibilityDescription: nil)?
                .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .medium))
            button.imagePosition = .imageLeft
            button.font = NSFont.systemFont(ofSize: 11, weight: .medium)
            button.contentTintColor = .secondaryLabelColor
            button.heightAnchor.constraint(equalToConstant: 20).isActive = true
            button.widthAnchor.constraint(greaterThanOrEqualToConstant: 86).isActive = true
            button.isEnabled = model.useEnabled
            button.setAccessibilityLabel(title)
            header.addArrangedSubview(button)
        }
        contentStack.addArrangedSubview(header)
        for rowModel in model.rows {
            let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
            let color: NSColor = rowModel.warning ? PanelAccent.codex.color : .labelColor
            // 即将到期只用语义色区分，不加 ⚠ 前缀：长卡名（如"完全重置（每周 + 5 小时）"）会因此换行。
            // 卡名单行+尾部截断：这行余量仅 ~17pt，老版本 macOS 字体度量偏宽会把卡名挤到换行
            // （2026-11-12 Intel 用户实测），截断兜底保证任何系统上布局不破
            let name = PanelUI.label(rowModel.name, size: 12, color: color, wrapping: false)
            row.addArrangedSubview(name)
            row.addArrangedSubview(PanelUI.spacer())
            // 日期用次要色，"过期"标签单独用橙色加粗，主次分明
            let expiresText = rowModel.expires.hasSuffix(" 过期")
                ? String(rowModel.expires.dropLast(3)) : rowModel.expires
            let dateLabel = PanelUI.label(expiresText, size: 11,
                color: .secondaryLabelColor, wrapping: false, monospacedDigits: true)
            dateLabel.setContentHuggingPriority(.required, for: .horizontal)
            dateLabel.setContentCompressionResistancePriority(.required, for: .horizontal)
            row.addArrangedSubview(dateLabel)
            if rowModel.expires.hasSuffix(" 过期") {
                let badge = PanelUI.label("过期", size: 10, weight: .medium,
                    color: PanelAccent.codex.color, wrapping: false)
                badge.setContentHuggingPriority(.required, for: .horizontal)
                row.addArrangedSubview(badge)
            }
            contentStack.addArrangedSubview(row)
        }
        for notice in PanelUI.notices(model.notices) {
            PanelUI.addFullWidth(notice, to: contentStack)
        }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class PanelDisclosureButton: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { performClick(nil) } else { super.keyDown(with: event) }
    }
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let parent = superview else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: parent)) ? self : nil
    }
}

private enum PanelSectionHeading {
    static func make(title: String, symbol: String, color: NSColor, expanded: Bool,
                     target: AnyObject, action: Selector, accessory: NSView? = nil,
                     toolTip: String? = nil) -> NSStackView {
        let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        row.heightAnchor.constraint(equalToConstant: 24).isActive = true
        let iconBox = NSView()
        iconBox.translatesAutoresizingMaskIntoConstraints = false
        let icon = PanelUI.symbol(symbol, size: 14, color: color)
        iconBox.addSubview(icon)
        NSLayoutConstraint.activate([
            iconBox.widthAnchor.constraint(equalToConstant: 20),
            iconBox.heightAnchor.constraint(equalToConstant: 20),
            icon.centerXAnchor.constraint(equalTo: iconBox.centerXAnchor),
            icon.centerYAnchor.constraint(equalTo: iconBox.centerYAnchor)
        ])
        row.addArrangedSubview(iconBox)
        let label = PanelDisclosureButton(title: title, target: target, action: action)
        label.isBordered = false
        label.font = .systemFont(ofSize: 12, weight: .semibold)
        label.contentTintColor = .labelColor
        label.toolTip = toolTip
        let accessibility = "\(expanded ? "收起" : "展开")\(title)"
        label.setAccessibilityLabel(accessibility)
        row.addArrangedSubview(label)
        row.addArrangedSubview(PanelUI.spacer())
        if let accessory = accessory { row.addArrangedSubview(accessory) }
        let baseImage = NSImage(systemSymbolName: expanded ? "chevron.up" : "chevron.down", accessibilityDescription: nil)!
        let image = baseImage.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 12, weight: .regular)) ?? baseImage
        let toggle = PanelDisclosureButton(image: image, target: target, action: action)
        toggle.isBordered = false
        toggle.contentTintColor = .secondaryLabelColor
        toggle.setAccessibilityLabel(accessibility)
        toggle.widthAnchor.constraint(equalToConstant: 24).isActive = true
        toggle.heightAnchor.constraint(equalToConstant: 24).isActive = true
        row.addArrangedSubview(toggle)
        return row
    }
}

private final class ToolPeriodButton: NSButton {
    private let selectedPeriod: Bool
    private var hovered = false { didSet { needsDisplay = true } }
    override var acceptsFirstResponder: Bool { true }
    override var wantsUpdateLayer: Bool { true }
    init(title: String, index: Int, selected: Bool, target: AnyObject, action: Selector) {
        selectedPeriod = selected
        super.init(frame: .zero)
        self.title = title; tag = index; self.target = target; self.action = action
        isBordered = false; wantsLayer = true; layer?.cornerRadius = 5
        translatesAutoresizingMaskIntoConstraints = false
        font = .systemFont(ofSize: 10, weight: selected ? .semibold : .regular)
        contentTintColor = selected ? PanelAccent.codex.color : .secondaryLabelColor
        setAccessibilityRole(.radioButton)
        setAccessibilityLabel("工具明细，\(title)")
        setAccessibilityValue(selected ? 1 : 0)
        widthAnchor.constraint(equalToConstant: index == 2 ? 42 : 37).isActive = true
        heightAnchor.constraint(equalToConstant: 24).isActive = true
    }
    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if selectedPeriod {
                layer?.backgroundColor = PanelAccent.codex.color.withAlphaComponent(0.14).cgColor
            } else if hovered {
                layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06).cgColor
            } else {
                layer?.backgroundColor = NSColor.clear.cgColor
            }
        }
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { performClick(nil) } else { super.keyDown(with: event) }
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

final class UsagePanelController: NSObject, NSPopoverDelegate {
    var onCheckUpdate: (() -> Void)?
    var onConfirmUpdate: ((String, String) -> Void)?
    private var updateConfirmation: (tag: String, notes: String)?
    private var backgroundStyle = PanelBackgroundStyle.parse(UserDefaults.standard.string(forKey: PanelBackgroundStyle.defaultsKey))
    private var workspaceObserver: NSObjectProtocol?
    var onUseReset: (() -> Void)?
    private var codexExpanded = true
    private var externalExpanded = false
    private var dailyExpanded = true
    private let quotaHistoryUI = QuotaCycleUIState()
    private var quotaHistoryReopenExpected: (UUID?, Int)?
    private var toolPeriod = 0
    private var savedScrollOrigin = NSPoint.zero
    private var expandedCodexBuckets: Set<Int> = []
    private var updateMessage: String?
    private var updateMessageDismissal: DispatchWorkItem?
    var previewWidth: CGFloat?
    var isOpen: Bool { popover.isShown }
    var previewWindowNumber: Int { contentController.view.window?.windowNumber ?? 0 }

    private let popover = NSPopover()
    private let contentController = NSViewController()
    private let effect = NSVisualEffectView()
    private let solid = PanelSolidBackgroundView()
    private let headerContainer = NSView()
    private let footerContainer = NSView()
    private let scrollView = NSScrollView()
    private let stack = PanelUI.stack(spacing: 8)
    private var model: UsagePanelModel?
    private var localMonitor: Any?
    private var globalMonitor: Any?
    private weak var anchorButton: NSStatusBarButton?
    private static let maximumWidth: CGFloat = 330
    private var panelWidth = UsagePanelController.maximumWidth

    override init() {
        super.init()
        configureContent()
        if let argument = CommandLine.arguments.first(where: { $0.hasPrefix("--visual-preview-background=") }) {
            backgroundStyle = PanelBackgroundStyle.parse(String(argument.dropFirst("--visual-preview-background=".count)))
        }
        workspaceObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.applyBackgroundStyle() }
        popover.contentViewController = contentController
        popover.behavior = .transient
        popover.animates = false
        popover.delegate = self
        if CommandLine.arguments.contains("--visual-preview-dark") {
            popover.appearance = NSAppearance(named: .darkAqua)
        }
    }

    deinit {
        if let workspaceObserver { NSWorkspace.shared.notificationCenter.removeObserver(workspaceObserver) }
        if let localMonitor = localMonitor { NSEvent.removeMonitor(localMonitor) }
        if let globalMonitor = globalMonitor { NSEvent.removeMonitor(globalMonitor) }
    }

    private func configureContent() {
        let container = NSView(frame: NSRect(x: 0, y: 0, width: panelWidth, height: 320))
        contentController.view = container
        container.wantsLayer = true
        container.layer?.cornerRadius = 16
        container.layer?.masksToBounds = true

        effect.frame = container.bounds
        effect.autoresizingMask = [.width, .height]
        effect.material = .popover
        effect.blendingMode = .behindWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = 16
        effect.layer?.masksToBounds = true
        container.addSubview(effect)

        solid.frame = container.bounds
        solid.autoresizingMask = [.width, .height]
        solid.wantsLayer = true
        solid.layer?.cornerRadius = 16
        solid.layer?.masksToBounds = true
        container.addSubview(solid)

        for view in [headerContainer, footerContainer] {
            view.translatesAutoresizingMaskIntoConstraints = false
        }
        scrollView.translatesAutoresizingMaskIntoConstraints = false
        scrollView.drawsBackground = false
        scrollView.borderType = .noBorder
        scrollView.hasVerticalScroller = true
        scrollView.autohidesScrollers = true
        scrollView.scrollerStyle = .overlay
        scrollView.verticalScrollElasticity = .allowed
        scrollView.horizontalScrollElasticity = .none

        container.addSubview(headerContainer)
        container.addSubview(scrollView)
        container.addSubview(footerContainer)
        NSLayoutConstraint.activate([
            headerContainer.topAnchor.constraint(equalTo: container.topAnchor),
            headerContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            headerContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.topAnchor.constraint(equalTo: headerContainer.bottomAnchor),
            scrollView.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            scrollView.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            scrollView.bottomAnchor.constraint(equalTo: footerContainer.topAnchor),
            footerContainer.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            footerContainer.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            footerContainer.bottomAnchor.constraint(equalTo: container.bottomAnchor)
        ])

        stack.alignment = .centerX
        stack.edgeInsets = NSEdgeInsets(top: 8, left: 16, bottom: 8, right: 16)
        scrollView.documentView = stack
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: scrollView.contentView.topAnchor),
            stack.leadingAnchor.constraint(equalTo: scrollView.contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: scrollView.contentView.trailingAnchor)
        ])
    }

    func update(model: UsagePanelModel) {
        self.model = model
        quotaHistoryUI.hover = nil
        quotaHistoryUI.browser.update(model.quotaHistory.state.closed + (model.quotaHistory.state.current.map { [$0] } ?? []))
        // 阅读版本说明期间保留滚动位置；数据更新仍写入模型，关闭说明后刷新显示。
        if isOpen && updateConfirmation == nil { refreshPanelLayout() }
    }

    private func clear(container: NSView) {
        for view in container.subviews { view.removeFromSuperview() }
    }

    private func installChrome(model: UsagePanelModel) {
        clear(container: headerContainer)
        clear(container: footerContainer)

        let header = PanelHeaderView(model: model, backgroundTarget: self, backgroundAction: #selector(showBackgroundStyleMenu(_:)))
        let headerLine = PanelUI.separator()
        headerContainer.addSubview(header)
        headerContainer.addSubview(headerLine)
        NSLayoutConstraint.activate([
            header.topAnchor.constraint(equalTo: headerContainer.topAnchor, constant: 12),
            header.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            header.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            headerLine.topAnchor.constraint(equalTo: header.bottomAnchor, constant: 12),
            headerLine.leadingAnchor.constraint(equalTo: headerContainer.leadingAnchor, constant: 16),
            headerLine.trailingAnchor.constraint(equalTo: headerContainer.trailingAnchor, constant: -16),
            headerLine.bottomAnchor.constraint(equalTo: headerContainer.bottomAnchor)
        ])

        let footerLine = PanelUI.separator()
        let footer = PanelFooterView(model: model, updateMessage: updateMessage, target: self, buttonFactory: makeActionButton)
        footerContainer.addSubview(footerLine)
        footerContainer.addSubview(footer)
        NSLayoutConstraint.activate([
            footerLine.topAnchor.constraint(equalTo: footerContainer.topAnchor),
            footerLine.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: 16),
            footerLine.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -16),
            footer.topAnchor.constraint(equalTo: footerLine.bottomAnchor, constant: 8),
            footer.leadingAnchor.constraint(equalTo: footerContainer.leadingAnchor, constant: 16),
            footer.trailingAnchor.constraint(equalTo: footerContainer.trailingAnchor, constant: -16),
            footer.bottomAnchor.constraint(equalTo: footerContainer.bottomAnchor, constant: -12)
        ])
    }

    private func addContentRow(_ view: NSView) {
        stack.addArrangedSubview(view)
        view.widthAnchor.constraint(equalToConstant: panelWidth - 32).isActive = true
    }

    private func rebuildContent() {
        guard let model = model else { return }
        installChrome(model: model)
        for row in stack.arrangedSubviews {
            stack.removeArrangedSubview(row)
            row.removeFromSuperview()
        }
        // 更新进行中：原按钮位置换成进度行（重开面板也在此恢复）；空闲时才显示更新按钮
        if UpdateProgressController.shared.isActive {
            addContentRow(UpdateProgressRowView())
        } else if let confirmation = updateConfirmation {
            addContentRow(makeUpdateConfirmation(tag: confirmation.tag, notes: confirmation.notes))
        } else if let update = model.updateItem {
            let button = makeActionButton(update, .prominent)
            button.heightAnchor.constraint(equalToConstant: 30).isActive = true
            addContentRow(button)
        }
        addContentRow(QuotaCardSectionView(quotas: model.quotas))
        if let reset = model.resetCards {
            addContentRow(ResetCardSectionView(model: reset, target: self, action: #selector(requestUseReset)))
        }
        if let tibo = model.tibo {
            addContentRow(makeTiboSection(tibo))
        }
        addContentRow(makeCardSection(TokenSectionView(model: model.codexTokens, expanded: codexExpanded,
            expandedBuckets: expandedCodexBuckets, target: self, action: #selector(toggleCodex),
            bucketAction: #selector(toggleCodexBucket(_:)))))
        addContentRow(makeCardSection(makeDailySection(model)))
        addContentRow(makeCardSection(makeQuotaHistorySection(model)))
        addContentRow(makeCardSection(makeToolSection(model)))
        for notice in PanelUI.notices(model.notices) { addContentRow(notice) }
        stack.needsLayout = true
    }

    private func makeCardSection(_ content: NSView) -> PanelCardView {
        let card = PanelCardView(padding: 8)
        PanelUI.addFullWidth(content, to: card.contentStack)
        return card
    }

    private func makeQuotaHistorySection(_ model: UsagePanelModel) -> NSView {
        let root = PanelUI.stack(spacing: 6)
        let heading = PanelSectionHeading.make(title: "额度周期回顾", symbol: "chart.bar.fill",
            color: PanelAccent.codex.color, expanded: quotaHistoryUI.expanded, target: self,
            action: #selector(toggleQuotaHistory), toolTip: "根据额度实际观测轮次记录；开始和结束可能不精确")
        PanelUI.addFullWidth(heading, to: root)
        if quotaHistoryUI.expanded {
            PanelUI.addFullWidth(QuotaCycleHistoryView(snapshot: model.quotaHistory, available: model.quotaHistoryAvailable, state: quotaHistoryUI,
                now: CommandLine.arguments.contains(where: { $0.hasPrefix("--visual-preview") }) ? Date(timeIntervalSince1970: 1_793_897_600) : Date()), to: root)
        }
        return root
    }
    func resetQuotaHistoryAccount() { quotaHistoryUI.reset() }
    @objc private func toggleQuotaHistory() { quotaHistoryUI.expanded.toggle(); refreshPanelLayout() }

    private func makeDailySection(_ model: UsagePanelModel) -> NSView {
        let root = PanelUI.stack(spacing: 6)
        let heading = PanelSectionHeading.make(title: "用量简析", symbol: "chart.bar.fill",
            color: PanelAccent.codex.color, expanded: dailyExpanded, target: self,
            action: #selector(toggleDaily), toolTip: "官方账号累计和每日 Token；覆盖范围与源时区尚未确认")
        PanelUI.addFullWidth(heading, to: root)
        guard dailyExpanded else { return root }
        let total = PanelUI.label(Fmt.tokensAbbr(model.official?.lifetime), size: 19, weight: .semibold, monospacedDigits: true)
        // PRD 5.1：悬停可读未缩写总数、来源与最近成功查询时间
        if let snapshot = model.official, let lifetime = snapshot.lifetime {
            total.toolTip = String(format: "%.0f Token · 来源：官方账号用量 · 最后成功 %@", lifetime, Fmt.time(snapshot.fetchedAt))
        } else {
            total.toolTip = "暂无累计数据"
        }
        let totalRow = PanelUI.stack(orientation: .horizontal, alignment: .firstBaseline, spacing: 7)
        totalRow.heightAnchor.constraint(equalToConstant: 28).isActive = true
        totalRow.addArrangedSubview(total)
        totalRow.addArrangedSubview(PanelUI.label("累计 Token", size: 10, color: .secondaryLabelColor, wrapping: false))
        totalRow.addArrangedSubview(PanelUI.spacer())
        PanelUI.addFullWidth(totalRow, to: root)
        PanelUI.addFullWidth(DailyUsageChart(snapshot: model.official, scannedToday: model.officialTodayFill), to: root)
        let comparison = PanelComparisonStack()
        let compared = UsageComparison.evaluate(snapshot: model.official, now: Date(), todayFill: model.officialTodayFill)
        func comparisonColor(_ value: UsageComparison.Value) -> NSColor {
            if case .percent(let amount) = value { return amount < 0 ? RemainingColorTier.green.color() : PanelAccent.codex.color }
            if case .fromZero = value { return PanelAccent.codex.color }
            return .secondaryLabelColor
        }
        let left = PanelUI.label("日环比  " + compared.0.value.text, size: 11, color: comparisonColor(compared.0.value), wrapping: false)
        let right = PanelUI.label("7日环比  " + compared.1.value.text, size: 11, color: comparisonColor(compared.1.value), wrapping: false)
        left.toolTip = compared.0.description; right.toolTip = compared.1.description
        left.setAccessibilityHelp(compared.0.description); right.setAccessibilityHelp(compared.1.description)
        left.alignment = .center; right.alignment = .center
        left.setContentHuggingPriority(.init(1), for: .horizontal)
        right.setContentHuggingPriority(.init(1), for: .horizontal)
        comparison.addArrangedSubview(left)
        let separator = NSBox(); separator.boxType = .separator; separator.translatesAutoresizingMaskIntoConstraints = false
        separator.widthAnchor.constraint(equalToConstant: 1).isActive = true; separator.heightAnchor.constraint(equalToConstant: 18).isActive = true
        comparison.addArrangedSubview(separator); comparison.addArrangedSubview(right)
        left.widthAnchor.constraint(equalTo: right.widthAnchor).isActive = true
        comparison.heightAnchor.constraint(equalToConstant: 32).isActive = true
        PanelUI.addFullWidth(comparison, to: root)
        if let error = model.officialError { PanelUI.addFullWidth(PanelUI.label(error, size: 10, color: .secondaryLabelColor), to: root) }
        if let snapshot = model.official, Date().timeIntervalSince(snapshot.fetchedAt) > UsageFreshness.staleSeconds {
            PanelUI.addFullWidth(PanelUI.label("数据已过期 · 最后成功 \(Fmt.dayTime(snapshot.fetchedAt))", size: 10, color: .secondaryLabelColor), to: root)
        }
        return root
    }

    private func makeToolSection(_ model: UsagePanelModel) -> NSView {
        let root = PanelUI.stack(spacing: 4)
        let periods: NSStackView? = externalExpanded ? PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 4) : nil
        if let periods = periods {
            for (index, label) in ["今天", "7天", "30天"].enumerated() {
                periods.addArrangedSubview(ToolPeriodButton(title: label, index: index, selected: index == toolPeriod,
                                                           target: self, action: #selector(selectToolPeriod(_:))))
            }
        }
        let header = PanelSectionHeading.make(title: "工具明细", symbol: "list.bullet",
            color: PanelAccent.codex.color, expanded: externalExpanded, target: self,
            action: #selector(toggleExternal), accessory: periods)
        PanelUI.addFullWidth(header, to: root)
        guard externalExpanded else { return root }
        let items = model.tools[toolPeriod]
        let total = items.reduce(0.0) { $0 + ($1.total ?? 0) }
        if !items.contains(where: { ($0.total ?? 0) > 0 }) {
            PanelUI.addFullWidth(PanelUI.label("该周期暂无可统计用量", size: 11, color: .secondaryLabelColor), to: root)
        }
        for (itemIndex, item) in items.enumerated() where (item.total ?? 0) > 0 || item.status == .failed {
            // 每个工具用不同颜色，方便一眼区分占比
            let toolColors: [NSColor] = [
                PanelAccent.codex.color,
                PanelAccent.external.color,
                NSColor.systemTeal,
                NSColor.systemPurple,
            ]
            let barColor = toolColors[itemIndex % toolColors.count]
            let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
            let name = PanelUI.label(item.name, size: 11, wrapping: false); name.widthAnchor.constraint(equalToConstant: 76).isActive = true
            row.addArrangedSubview(name)
            let bar = UsageShareBar(fraction: total > 0 ? (item.total ?? 0) / total : 0, color: barColor)
            row.addArrangedSubview(bar)
            let value = PanelUI.label(Fmt.tokensAbbr(item.total), size: 11, wrapping: false, monospacedDigits: true); value.alignment = .right; value.widthAnchor.constraint(equalToConstant: 52).isActive = true
            row.addArrangedSubview(value)
            let share = total > 0 ? Int(round((item.total ?? 0) / total * 100)) : 0
            row.toolTip = "占比 \(share)% · 输入 \(Fmt.tokensAbbr(item.input)) · 输出 \(Fmt.tokensAbbr(item.output)) · \(item.status.text)"
            PanelUI.addFullWidth(row, to: root)
        }
        return root
    }
    @objc private func selectToolPeriod(_ sender: NSButton) {
        guard (0..<3).contains(sender.tag) else { return }
        let restoreFocus = sender.window?.firstResponder === sender
        toolPeriod = sender.tag
        refreshPanelLayout()
        if restoreFocus {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            if let button = descendants(stack).compactMap({ $0 as? ToolPeriodButton }).first(where: { $0.tag == toolPeriod }) {
                button.window?.makeFirstResponder(button)
            }
        }
    }

    func showUpdateConfirmation(tag: String, notes: String) {
        updateConfirmation = (tag, notes)
        refreshPanelLayout()
    }

    private func makeUpdateConfirmation(tag: String, notes: String) -> NSView {
        let content = PanelUI.stack(spacing: 7)
        PanelUI.addFullWidth(PanelUI.label("发现新版本 \(tag)", size: 13, weight: .semibold), to: content)
        PanelUI.addFullWidth(PanelUI.label("当前版本 \(BuildInfo.version)", size: 11, color: .secondaryLabelColor), to: content)
        PanelUI.addFullWidth(PanelUI.label("本次更新", size: 12, weight: .semibold), to: content)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: panelWidth - 32, height: 100))
        text.isEditable = false; text.isSelectable = true; text.drawsBackground = false
        text.font = NSFont.systemFont(ofSize: 12); text.textColor = .labelColor
        text.textContainerInset = NSSize(width: 0, height: 2)
        text.textContainer?.widthTracksTextView = true
        text.isVerticallyResizable = true; text.isHorizontallyResizable = false
        let displayedNotes = UpdateCheck.displayNotes(notes)
        let styledNotes = NSMutableAttributedString(string: displayedNotes, attributes: [
            .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.labelColor
        ])
        let noteText = displayedNotes as NSString
        for line in displayedNotes.components(separatedBy: "\n") where ["新增", "优化", "修复"].contains(line.trimmingCharacters(in: .whitespaces)) {
            let range = noteText.range(of: line)
            if range.location != NSNotFound { styledNotes.addAttribute(.font, value: NSFont.systemFont(ofSize: 12, weight: .semibold), range: range) }
        }
        text.textStorage?.setAttributedString(styledNotes)
        let notesScroll = NSScrollView()
        notesScroll.translatesAutoresizingMaskIntoConstraints = false
        notesScroll.drawsBackground = false; notesScroll.hasVerticalScroller = true
        notesScroll.autohidesScrollers = true; notesScroll.documentView = text
        let notesBox = NSBox()
        notesBox.translatesAutoresizingMaskIntoConstraints = false
        notesBox.boxType = .custom
        notesBox.borderWidth = 1
        notesBox.borderColor = .separatorColor
        notesBox.fillColor = NSColor.controlBackgroundColor.withAlphaComponent(0.35)
        notesBox.cornerRadius = 7
        notesBox.contentViewMargins = .zero
        notesBox.addSubview(notesScroll)
        NSLayoutConstraint.activate([
            notesScroll.topAnchor.constraint(equalTo: notesBox.topAnchor, constant: 7),
            notesScroll.bottomAnchor.constraint(equalTo: notesBox.bottomAnchor, constant: -7),
            notesScroll.leadingAnchor.constraint(equalTo: notesBox.leadingAnchor, constant: 9),
            notesScroll.trailingAnchor.constraint(equalTo: notesBox.trailingAnchor, constant: -9)
        ])
        let measured = (text.string as NSString).boundingRect(
            with: NSSize(width: panelWidth - 62, height: 10000),
            options: [.usesLineFragmentOrigin, .usesFontLeading],
            attributes: [.font: NSFont.systemFont(ofSize: 12)]).height
        notesBox.heightAnchor.constraint(equalToConstant: min(134, max(48, ceil(measured) + 22))).isActive = true
        PanelUI.addFullWidth(notesBox, to: content)
        PanelUI.addFullWidth(PanelUI.label("安装完成后，应用将自动重启。", size: 11, color: .secondaryLabelColor), to: content)
        let buttons = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 5)
        buttons.addArrangedSubview(PanelUI.spacer())
        let cancel = NSButton(title: "取消", target: self, action: #selector(cancelUpdateConfirmation))
        let install = NSButton(title: "下载并安装", target: self, action: #selector(confirmUpdate))
        for button in [cancel, install] { button.bezelStyle = .rounded; buttons.addArrangedSubview(button) }
        PanelUI.addFullWidth(buttons, to: content)
        return content
    }

    @objc private func cancelUpdateConfirmation() { updateConfirmation = nil; refreshPanelLayout() }
    @objc private func confirmUpdate() {
        guard let confirmation = updateConfirmation else { return }
        updateConfirmation = nil
        onConfirmUpdate?(confirmation.tag, confirmation.notes)
        refreshPanelLayout()
    }

    func verifyBackgroundForPreview() -> Bool {
        let original = backgroundStyle
        defer { backgroundStyle = original; applyBackgroundStyle() }
        // Preview mode never persists the selected value.
        for style in PanelBackgroundStyle.allCases {
            if style == .liquidGlass && !Self.supportsLiquidGlass { continue }
            let item = NSMenuItem(); item.representedObject = style.rawValue
            selectBackgroundStyle(item)
            let expected = style.effective(liquidSupported: Self.supportsLiquidGlass,
                reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
            guard backgroundStyle == style, solid.isHidden == (expected != .solid),
                  effect.isHidden == (expected != .classicMaterial) else { return false }
        }
        return true
    }

    func verifyConfirmationForPreview() -> Bool {
        var calls: [String] = []
        onConfirmUpdate = { tag, _ in calls.append(tag) }
        showUpdateConfirmation(tag: "v99.0.0", notes: "测试说明")
        guard calls.isEmpty, updateConfirmation != nil else { return false }
        cancelUpdateConfirmation()
        guard calls.isEmpty, updateConfirmation == nil else { return false }
        showUpdateConfirmation(tag: "v99.0.0", notes: "测试说明")
        confirmUpdate()
        guard calls == ["v99.0.0"], updateConfirmation == nil else { return false }
        showUpdateConfirmation(tag: "v99.0.0", notes: Array(repeating: "测试说明", count: 50).joined(separator: "\n"))
        func findTextScroll(_ view: NSView) -> NSScrollView? {
            if let scroll = view as? NSScrollView, scroll.documentView is NSTextView { return scroll }
            for subview in view.subviews { if let found = findTextScroll(subview) { return found } }
            return nil
        }
        contentController.view.layoutSubtreeIfNeeded()
        guard let notes = findTextScroll(stack), let document = notes.documentView,
              document.frame.height > notes.contentView.bounds.height else { return false }
        notes.contentView.scroll(to: NSPoint(x: 0, y: document.frame.height - notes.contentView.bounds.height))
        guard notes.contentView.bounds.origin.y > 0 else { return false }
        if let model = model { update(model: model) }
        guard notes.contentView.bounds.origin.y > 0 else { return false }
        popoverDidClose(Notification(name: NSPopover.didCloseNotification))
        return updateConfirmation == nil && calls.count == 1
    }

    private static var supportsLiquidGlass: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }
    private func applyBackgroundStyle() {
        let effective = backgroundStyle.effective(liquidSupported: Self.supportsLiquidGlass,
            reduceTransparency: NSWorkspace.shared.accessibilityDisplayShouldReduceTransparency)
        solid.isHidden = effective != .solid
        effect.isHidden = effective != .classicMaterial
    }
    @objc private func showBackgroundStyleMenu(_ sender: NSButton) {
        let menu = NSMenu(); menu.autoenablesItems = false
        for style in PanelBackgroundStyle.allCases {
            let unavailable = style == .liquidGlass && !Self.supportsLiquidGlass
            let item = NSMenuItem(title: unavailable ? "液态玻璃（需 macOS 26+）" : style.menuTitle,
                                  action: #selector(selectBackgroundStyle(_:)), keyEquivalent: "")
            item.target = self; item.representedObject = style.rawValue
            item.state = style == backgroundStyle ? .on : .off
            item.isEnabled = !unavailable
            menu.addItem(item)
        }
        let hadMonitors = localMonitor != nil || globalMonitor != nil
        if hadMonitors { removeMonitors() }
        menu.popUp(positioning: nil, at: NSPoint(x: sender.bounds.maxX, y: -6), in: sender)
        if hadMonitors && isOpen { installMonitors() }
    }
    @objc private func selectBackgroundStyle(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String, let style = PanelBackgroundStyle(rawValue: raw),
              style != .liquidGlass || Self.supportsLiquidGlass else { return }
        backgroundStyle = style
        if !CommandLine.arguments.contains(where: { $0.hasPrefix("--visual-preview") }) {
            UserDefaults.standard.set(style.rawValue, forKey: PanelBackgroundStyle.defaultsKey)
        }
        applyBackgroundStyle()
    }

    private func refreshPanelLayout() {
        // 就地重建时保持滚动位置并禁用隐式动画：每 10s 后台刷新重建面板内容不打扰阅读（KimiUsage 同款）
        let previousOrigin = scrollView.contentView.bounds.origin
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        rebuildContent()
        if let button = anchorButton, let window = button.window, isOpen {
            layoutPanel(anchoredTo: button, buttonWindow: window)
            let clip = scrollView.contentView
            let desired = NSRect(origin: previousOrigin, size: clip.bounds.size)
            clip.scroll(to: clip.constrainBoundsRect(desired).origin)
            scrollView.reflectScrolledClipView(clip)
        }
        CATransaction.commit()
    }
    @objc private func toggleCodex() { codexExpanded.toggle(); refreshPanelLayout() }
    @objc private func toggleExternal() { externalExpanded.toggle(); refreshPanelLayout() }
    @objc private func toggleDaily() { dailyExpanded.toggle(); refreshPanelLayout() }
    @objc private func toggleCodexBucket(_ sender: NSButton) {
        expandedCodexBuckets = toggledBucket(sender.tag, expanded: expandedCodexBuckets)
        refreshPanelLayout()
    }
    private func toggledBucket(_ index: Int, expanded: Set<Int>) -> Set<Int> {
        guard (0..<3).contains(index) else { return expanded }
        var result = expanded
        if result.contains(index) { result.remove(index) } else { result.insert(index) }
        return result
    }
    @objc fileprivate func requestUpdateCheck() { onCheckUpdate?() }
    @objc fileprivate func requestUseReset() { onUseReset?() }
    func setUpdateMessage(_ message: String?, dismissAfter: TimeInterval? = nil) {
        updateMessageDismissal?.cancel()
        updateMessageDismissal = nil
        updateMessage = message
        refreshPanelLayout()
        if message != nil, let delay = dismissAfter {
            let dismissal = DispatchWorkItem { [weak self] in self?.setUpdateMessage(nil) }
            updateMessageDismissal = dismissal
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: dismissal)
        }
    }

    private func makeTiboSection(_ model: UsagePanelModel.TiboSection) -> NSView {
        let card = PanelCardView(padding: 8)
        let header = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        header.addArrangedSubview(PanelUI.label("Tibo 重置动态", size: 12, weight: .semibold, wrapping: false))
        header.addArrangedSubview(PanelUI.spacer())
        PanelUI.addFullWidth(header, to: card.contentStack)
        for row in model.rows {
            // confirmed 行：checkmark.circle.fill + 文字横排，与面板 SF Symbol 体系一致
            if row.confirmed {
                let rowStack = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 5)
                let icon = PanelUI.symbol("checkmark.circle.fill", size: 12, color: .systemGreen)
                rowStack.addArrangedSubview(icon)
                if let item = row.item {
                    let btn = makeActionButton(item, .plain, title: row.text)
                    rowStack.addArrangedSubview(btn)
                } else {
                    rowStack.addArrangedSubview(PanelUI.label(row.text, size: 12))
                }
                PanelUI.addFullWidth(rowStack, to: card.contentStack)
            } else {
                let view: NSView
                if let item = row.item {
                    view = makeActionButton(item, .plain, title: row.text)
                } else {
                    view = PanelUI.label(row.text, size: 12)
                }
                PanelUI.addFullWidth(view, to: card.contentStack)
            }
        }
        for notice in PanelUI.notices(model.notices) {
            PanelUI.addFullWidth(notice, to: card.contentStack)
        }
        return card
    }

    private func makeActionButton(_ item: NSMenuItem, _ style: PanelActionButton.Style,
                                  title overrideTitle: String? = nil) -> PanelActionButton {
        let button = PanelActionButton()
        button.menuItem = item
        button.style = style
        button.target = self
        button.action = #selector(performAction(_:))
        button.translatesAutoresizingMaskIntoConstraints = false
        button.wantsLayer = true
        button.layer?.cornerRadius = 6
        button.alignment = style == .prominent ? .center : .left
        button.keyEquivalent = item.keyEquivalent
        button.keyEquivalentModifierMask = []
        button.toolTip = item.toolTip
        button.focusRingType = .none
        let title = overrideTitle ?? item.title
        let prominent = style == .prominent
        let textColor: NSColor = prominent
            ? NSColor(name: nil) { appearance in
                appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .black : .white
            }
            : .labelColor
        button.attributedTitle = NSAttributedString(string: title, attributes: [
            .font: NSFont.systemFont(ofSize: 12, weight: prominent ? .semibold : .regular),
            .foregroundColor: textColor
        ])
        if style == .checkbox {
            button.setButtonType(.switch)
            button.isBordered = false
            button.state = item.state
            button.contentTintColor = PanelAccent.codex.color
        } else {
            button.setButtonType(.momentaryChange)
            button.isBordered = false
            (button.cell as? NSButtonCell)?.highlightsBy = []
            button.cell?.wraps = true
            button.cell?.lineBreakMode = .byWordWrapping
            button.heightAnchor.constraint(greaterThanOrEqualToConstant: style == .plain ? 26 : 30).isActive = true
        }
        return button
    }

    @objc private func performAction(_ sender: PanelActionButton) {
        guard let item = sender.menuItem, let action = item.action else { return }
        // 只有「退出」先收起面板；刷新/开机自启等保持面板打开，动作结果就地可见
        if action == #selector(AppDelegate.onQuit) { close() }
        DispatchQueue.main.async {
            _ = NSApp.sendAction(action, to: item.target, from: item)
        }
    }

    /// 视觉回归专用：真实滚动到底部并确认 clip view 位置发生变化。
    func scrollToEndForPreview() -> Bool {
        contentController.view.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        guard let document = scrollView.documentView else { return false }
        let clip = scrollView.contentView
        let maxY = max(0, document.frame.height - clip.bounds.height)
        guard maxY > 0 else { return false }
        let targetY = -maxY
        clip.scroll(to: NSPoint(x: 0, y: targetY))
        scrollView.reflectScrolledClipView(clip)
        return abs(clip.bounds.origin.y - targetY) < 1
    }

    func expandToolsForPreview() { externalExpanded = true }
    func collapseDailyForPreview() { dailyExpanded = false }
    func expandAllTokenBucketsForPreview() {
        expandedCodexBuckets = [0, 1, 2]
        refreshPanelLayout()
    }

    /// 七个业务模块均使用原生卡片，展开／折叠只改变卡片内容，不改变模块顺序。
    func verifyCardLayoutForPreview() -> Bool {
        stack.layoutSubtreeIfNeeded()
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        let cards = stack.arrangedSubviews.compactMap { $0 as? PanelCardView }
        let hasSectionSeparator = stack.arrangedSubviews.contains { ($0 as? NSBox)?.boxType == .separator }
        let dailyButtons = descendants(cards.count > 4 ? cards[4] : NSView()).compactMap { $0 as? PanelDisclosureButton }
            .filter { $0.action == #selector(toggleDaily) }
        let historyButtons = descendants(cards.count > 5 ? cards[5] : NSView()).compactMap { $0 as? PanelDisclosureButton }
            .filter { $0.action == #selector(toggleQuotaHistory) }
        let toolButtons = descendants(cards.count > 6 ? cards[6] : NSView()).compactMap { $0 as? PanelDisclosureButton }
            .filter { $0.action == #selector(toggleExternal) }
        let hasFooterSeparator = footerContainer.subviews.contains { ($0 as? NSBox)?.boxType == .separator }
        let hasConsistentSpacing = zip(cards, cards.dropFirst()).allSatisfy { previous, card in
            abs(previous.frame.minY - card.frame.maxY - stack.spacing) < 0.01
        }
        guard cards.count == 7, !hasSectionSeparator, hasFooterSeparator,
              stack.spacing == 8, hasConsistentSpacing,
              cards[0] is QuotaCardSectionView, cards[1] is ResetCardSectionView,
              descendants(cards[0]).compactMap({ $0 as? QuotaWindowView }).count == model?.quotas.count,
              descendants(cards[3]).contains(where: { $0 is TokenSectionView }),
              dailyButtons.count == 2, historyButtons.count == 2, toolButtons.count == 2 else {
            print("CODEX_CARD_LAYOUT structureFailed cards=\(cards.count) separators=\(hasSectionSeparator) footer=\(hasFooterSeparator) spacing=\(hasConsistentSpacing)")
            return false
        }
        if quotaHistoryUI.expanded && (cards[5].frame.height > 210 || cards[5].frame.height < 180) {
            print("CODEX_CARD_LAYOUT quota height=\(cards[5].frame.height)"); return false
        }
        return cards.enumerated().allSatisfy { index, card in
            card.layoutSubtreeIfNeeded()
            let content = card.contentStack.frame
            let valid = card.frame.height > 0
                && abs(card.frame.width - (panelWidth - 32)) < 0.01
                && abs(card.frame.minX - 16) < 0.01
                && abs(content.minX - 8) < 0.01
                && abs(content.maxX - (card.bounds.width - 8)) < 0.01
                && abs(content.height - (card.bounds.height - 16)) < 0.01
                && card.layer?.cornerRadius == 12
                && card.layer?.borderWidth == 0.5
            if !valid { print("CODEX_CARD_LAYOUT index=\(index) frame=\(card.frame) content=\(content) radius=\(card.layer?.cornerRadius ?? -1) border=\(card.layer?.borderWidth ?? -1)") }
            return valid
        }
    }

    func scrollQuotaHistoryForPreview() {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        if let view = descendants(stack).compactMap({ $0 as? QuotaCycleHistoryView }).first {
            var card: NSView? = view
            while card != nil && !(card is PanelCardView) { card = card?.superview }
            if let card = card { card.scrollToVisible(card.bounds) } else { view.scrollToVisible(view.bounds) }
        }
    }

    func verifyQuotaHistoryEventsForPreview() -> Bool {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        guard let chart = descendants(stack).compactMap({ $0 as? QuotaCycleChart }).first,
              let window = chart.window, quotaHistoryUI.browser.records.count >= 13 else { return false }
        chart.scrollToVisible(chart.bounds); chart.updateTrackingAreas()
        let visible = quotaHistoryUI.browser.visible
        guard visible.count == 6, chart.bounds.width >= 200,
              (chart.accessibilityChildren()?.count ?? 0) == 6 else { return false }
        let column = (chart.bounds.width - 22) / 6
        let location = chart.convert(NSPoint(x: 22 + column * 4.5, y: 30), to: nil)
        guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 81, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: location, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 82, clickCount: 1, pressure: 0) else { return false }
        window.sendEvent(down); window.sendEvent(up)
        guard quotaHistoryUI.browser.selectedCycleID == visible[4].id else { print("QUOTA_EVENT click failed loc=\(location) chart=\(chart.frame) clip=\(scrollView.contentView.bounds) hit=\(String(describing: window.contentView?.hitTest(location))) selected=\(String(describing: quotaHistoryUI.browser.selectedCycleID)) expected=\(visible[4].id)"); return false }
        let hoverPoint = chart.convert(NSPoint(x: 22 + column * 2.5, y: 30), to: nil)
        guard let move = NSEvent.mouseEvent(with: .mouseMoved, location: hoverPoint, modifierFlags: [], timestamp: 0,
              windowNumber: window.windowNumber, context: nil, eventNumber: 83, clickCount: 0, pressure: 0) else { return false }
        window.sendEvent(move)
        guard quotaHistoryUI.hover == visible[2].id else { print("QUOTA_EVENT hover failed"); return false }
        let blankPoint = chart.convert(NSPoint(x: 5, y: 30), to: nil)
        guard let blank = NSEvent.mouseEvent(with: .mouseMoved, location: blankPoint, modifierFlags: [], timestamp: 0,
              windowNumber: window.windowNumber, context: nil, eventNumber: 84, clickCount: 0, pressure: 0) else { return false }
        window.sendEvent(blank)
        guard quotaHistoryUI.hover == nil, quotaHistoryUI.browser.selectedCycleID == visible[4].id else { print("QUOTA_EVENT hover restore failed"); return false }
        guard window.makeFirstResponder(chart), let left = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: "\u{f702}", charactersIgnoringModifiers: "\u{f702}", isARepeat: false, keyCode: 123) else { return false }
        for _ in 0..<6 { window.sendEvent(left) }
        guard quotaHistoryUI.browser.olderPage == 1, let chosen = quotaHistoryUI.browser.selectedCycleID else { print("QUOTA_EVENT key failed"); return false }
        if let model = model { update(model: model) }
        guard quotaHistoryUI.browser.selectedCycleID == chosen, quotaHistoryUI.browser.olderPage == 1 else { return false }
        func click(_ view: NSView) -> Bool {
            view.scrollToVisible(view.bounds)
            let point = view.convert(NSPoint(x: view.bounds.midX, y: view.bounds.midY), to: nil)
            guard let down = NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 91, clickCount: 1, pressure: 1),
              let up = NSEvent.mouseEvent(with: .leftMouseUp, location: point, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, eventNumber: 92, clickCount: 1, pressure: 0) else { return false }
            window.sendEvent(down); window.sendEvent(up); return true
        }
        guard let more = descendants(stack).compactMap({ $0 as? NSButton }).first(where: { $0.title == "更早记录" }),
              click(more), quotaHistoryUI.browser.visibleLimit == min(24, quotaHistoryUI.browser.records.count) else { print("QUOTA_EVENT more failed"); return false }
        guard let earlier = descendants(stack).compactMap({ $0 as? NSButton }).first(where: { $0.accessibilityLabel() == "更早的额度周期" }),
              click(earlier), quotaHistoryUI.browser.olderPage == 2 else { print("QUOTA_EVENT earlier failed"); return false }
        func heading() -> PanelDisclosureButton? {
            descendants(stack).compactMap { $0 as? PanelDisclosureButton }.first { $0.action == #selector(toggleQuotaHistory) }
        }
        let pageSelection = quotaHistoryUI.browser.selectedCycleID
        guard let close = heading(), click(close), !quotaHistoryUI.expanded,
              descendants(stack).compactMap({ $0 as? QuotaCycleChart }).isEmpty,
              let open = heading(), click(open), quotaHistoryUI.expanded,
              quotaHistoryUI.browser.selectedCycleID == pageSelection, quotaHistoryUI.browser.olderPage == 2 else { print("QUOTA_EVENT collapse failed"); return false }
        resetQuotaHistoryAccount()
        guard quotaHistoryUI.browser.selectedCycleID == nil, quotaHistoryUI.browser.records.isEmpty else { return false }
        if let model = model { update(model: model) }
        guard quotaHistoryUI.browser.selectedCycleID == quotaHistoryUI.browser.records.last?.id else { return false }
        return true
    }

    /// 面板事件回归：核对模型行、工具周期和简析开合状态。
    func verifyTokenBucketInteractionsForPreview() -> Bool {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        func rows() -> [TokenBucketRow] {
            descendants(stack).compactMap { $0 as? TokenBucketRow }.filter { $0.action == #selector(toggleCodexBucket(_:)) }.sorted { $0.tag < $1.tag }
        }
        guard rows().count == 3, rows().allSatisfy({ $0.verifyHoverForPreview() }) else { return false }
        guard let window = rows()[0].window, window.makeFirstResponder(rows()[0]),
              let space = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0,
                windowNumber: window.windowNumber, context: nil, characters: " ", charactersIgnoringModifiers: " ", isARepeat: false, keyCode: 49) else { return false }
        window.sendEvent(space)
        guard expandedCodexBuckets == [0] else { return false }
        for index in 1..<3 { rows()[index].performClick(nil) }
        guard expandedCodexBuckets == [0, 1, 2] else { return false }
        rows()[1].performClick(nil)
        guard expandedCodexBuckets == [0, 2], let model = model else { return false }
        update(model: model)
        guard expandedCodexBuckets == [0, 2] else { return false }
        toggleExternal()
        func periods() -> [ToolPeriodButton] { descendants(stack).compactMap { $0 as? ToolPeriodButton }.sorted { $0.tag < $1.tag } }
        guard externalExpanded, periods().count == 3 else { return false }
        periods()[2].performClick(nil)
        guard toolPeriod == 2, externalExpanded, expandedCodexBuckets == [0, 2], periods()[2].accessibilityValue() as? Int == 1 else { return false }
        guard window.makeFirstResponder(periods()[1]) else { return false }
        window.sendEvent(space)
        guard toolPeriod == 1, externalExpanded, expandedCodexBuckets == [0, 2] else { return false }
        toggleExternal()
        guard !externalExpanded, periods().isEmpty, toolPeriod == 1 else { return false }
        toggleExternal()
        guard externalExpanded, periods().count == 3, periods()[1].accessibilityValue() as? Int == 1 else { return false }
        func dailyButtons() -> [PanelDisclosureButton] {
            descendants(stack).compactMap { $0 as? PanelDisclosureButton }.filter { $0.action == #selector(toggleDaily) }
        }
        guard dailyButtons().count == 2 else { return false }
        dailyButtons()[0].performClick(nil)
        guard !dailyExpanded, descendants(stack).compactMap({ $0 as? DailyUsageChart }).isEmpty else { return false }
        update(model: model)
        guard !dailyExpanded, toolPeriod == 1, externalExpanded, expandedCodexBuckets == [0, 2],
              dailyButtons().count == 2, verifyCardLayoutForPreview() else { return false }
        guard window.makeFirstResponder(dailyButtons()[1]) else { return false }
        window.sendEvent(space)
        return dailyExpanded && descendants(stack).compactMap({ $0 as? DailyUsageChart }).count == 1
    }

    func prepareQuotaReopenForPreview() {
        quotaHistoryUI.browser.earlier()
        if let last = quotaHistoryUI.browser.visible.last { quotaHistoryUI.browser.select(last.id) }
        quotaHistoryReopenExpected = (quotaHistoryUI.browser.selectedCycleID, quotaHistoryUI.browser.olderPage)
    }
    func verifyQuotaReopenForPreview() -> Bool {
        guard let expected = quotaHistoryReopenExpected else { return true }
        quotaHistoryReopenExpected = nil
        return quotaHistoryUI.browser.selectedCycleID == expected.0 && quotaHistoryUI.browser.olderPage == expected.1
    }
    func prepareReopenStateForPreview() { if dailyExpanded { toggleDaily() } }
    func verifyReopenStateForPreview() -> Bool {
        let intact = !dailyExpanded && externalExpanded && toolPeriod == 1
            && expandedCodexBuckets == [0, 2] && verifyCardLayoutForPreview()
        if !dailyExpanded { toggleDaily() }
        return intact
    }

    func verifyChartInteractionsForPreview() -> Bool {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        guard let chart = descendants(stack).compactMap({ $0 as? DailyUsageChart }).first,
              let window = chart.window else { return false }
        chart.scrollToVisible(chart.bounds)
        chart.updateTrackingAreas()
        func move(_ index: Int) -> Bool {
            let point = chart.convert(NSPoint(x: chart.bounds.width * (CGFloat(index) + 0.5) / 30, y: 45), to: nil)
            guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
                    windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) else { return false }
            chart.mouseMoved(with: event)
            return chart.selectedIndexForPreview == index && chart.hoverWithinBoundsForPreview
        }
        guard move(0), chart.selectedTextForPreview.contains("暂无数据"),
              move(1), chart.selectedTextForPreview.contains("0 Token"),
              move(2), chart.selectedTextForPreview.contains("无活动记录"),
              move(29), chart.selectedTextForPreview.contains("Token") else { return false }
        guard window.makeFirstResponder(chart), let key = NSEvent.keyEvent(with: .keyDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: window.windowNumber, context: nil,
                characters: "\u{F702}", charactersIgnoringModifiers: "\u{F702}", isARepeat: false, keyCode: 123) else { return false }
        window.sendEvent(key)
        return chart.selectedIndexForPreview == 28
    }

    /// 固定假数据截图：显示指定日列的浮层并检查其不越界。
    func showChartHoverForPreview(index: Int) -> Bool {
        func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
        guard (0..<30).contains(index), let chart = descendants(stack).compactMap({ $0 as? DailyUsageChart }).first,
              let window = chart.window else { return false }
        chart.scrollToVisible(chart.bounds)
        let point = chart.convert(NSPoint(x: chart.bounds.width * (CGFloat(index) + 0.5) / 30, y: 23), to: nil)
        guard let event = NSEvent.mouseEvent(with: .mouseMoved, location: point, modifierFlags: [], timestamp: 0,
            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 0, pressure: 0) else { return false }
        chart.mouseMoved(with: event)
        return chart.selectedIndexForPreview == index && chart.hoverWithinBoundsForPreview
    }

    /// 截取完整系统窗口，包含 Popover 箭头与阴影。
    func savePreviewImage(to path: String) -> Bool {
        guard let window = contentController.view.window else { return false }
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-x", "-l", String(window.windowNumber), path]
        do { try task.run(); task.waitUntilExit(); return task.terminationStatus == 0 && FileManager.default.fileExists(atPath: path) }
        catch { return false }
    }

    /// 在真实 Popover 上逐步检查尺寸、锚点和窗口/视图身份。
    func verifyPopoverGeometryForPreview(outputDirectory: String) {
        func fail(_ message: String) { fputs("CodexUsage popover geometry: FAIL \(message)\n", stderr); exit(1) }
        guard popover.isShown, let window = contentController.view.window,
              let button = anchorButton, let buttonWindow = button.window else { return fail("opening") }
        let controller = popover.contentViewController
        let document = scrollView.documentView
        let top = window.frame.maxY
        let buttonRect = buttonWindow.convertToScreen(button.convert(button.bounds, to: nil))
        var height = window.frame.height
        func rows() -> [TokenBucketRow] {
            func descendants(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap { descendants($0) } }
            return descendants(stack).compactMap { $0 as? TokenBucketRow }.filter { $0.action == #selector(toggleCodexBucket(_:)) }.sorted { $0.tag < $1.tag }
        }
        func snapshot(_ name: String) {
            guard savePreviewImage(to: "\(outputDirectory)/\(name).png") else { return fail("screenshot \(name)") }
        }
        func check(_ name: String, direction: CGFloat) {
            guard popover.isShown, contentController.view.window === window,
                  popover.contentViewController === controller, scrollView.documentView === document else { return fail("identity \(name)") }
            let frame = window.frame
            guard abs(frame.maxY - top) < 1, frame.minX <= buttonRect.midX, frame.maxX >= buttonRect.midX else { return fail("anchor \(name)") }
            guard (frame.height - height) * direction > 0.5 else { return fail("height \(name): \(height) -> \(frame.height)") }
            if let screen = buttonWindow.screen { guard frame.minX >= screen.frame.minX - 1 && frame.maxX <= screen.frame.maxX + 1 else { return fail("screen edge") } }
            print("CODEX_POPOVER_GEOMETRY \(name) height=\(frame.height) top=\(frame.maxY) window=\(window.windowNumber)")
            height = frame.height
        }
        print("CODEX_POPOVER_GEOMETRY initial height=\(height) top=\(top) window=\(window.windowNumber)")
        snapshot("before")
        guard let row = rows().first else { return fail("row missing") }
        row.performClick(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            check("expanded", direction: 1); snapshot("expanded")
            guard let row = rows().first else { return fail("expanded row missing") }
            row.performClick(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                check("collapsed", direction: -1); snapshot("collapsed")
                print("CodexUsage popover geometry: PASS")
                exit(0)
            }
        }
    }

    func verifyNonzeroScrollForPreview() -> Bool {
        guard let model = model else { return false }
        let didScroll = scrollToEndForPreview()
        print("CODEX_POPOVER_SCROLL setup=\(didScroll) offset=\(scrollView.contentView.bounds.origin.y) document=\(stack.frame.height) viewport=\(scrollView.contentView.bounds.height)")
        guard didScroll else { return false }
        let before = scrollView.contentView.bounds.origin.y
        guard abs(before) > 1 else { return false }
        update(model: model)
        scrollView.layoutSubtreeIfNeeded()
        let after = scrollView.contentView.bounds.origin.y
        guard abs(after - before) < 1 && isOpen else { return false }
        let clip = scrollView.contentView
        func row(_ view: NSView) -> TokenBucketRow? {
            if let button = view as? TokenBucketRow, button.action == #selector(toggleCodexBucket(_:)), button.tag == 0 { return button }
            for child in view.subviews { if let found = row(child) { return found } }
            return nil
        }
        guard let bucket = row(stack) else { return false }
        bucket.performClick(nil)
        let expanded = clip.bounds.origin.y
        guard abs(expanded - after) < 1, isOpen, let bucket = row(stack) else { return false }
        bucket.performClick(nil)
        let collapsed = clip.bounds.origin.y
        print("CODEX_POPOVER_SCROLL before=\(before) refresh=\(after) expanded=\(expanded) collapsed=\(collapsed)")
        return abs(collapsed - before) < 1 && isOpen
    }

    func toggle(anchoredTo button: NSStatusBarButton) {
        if isOpen { close() } else { show(anchoredTo: button) }
    }

    private func show(anchoredTo button: NSStatusBarButton) {
        applyBackgroundStyle()
        guard let buttonWindow = button.window else { return }
        anchorButton = button
        rebuildContent()
        layoutPanel(anchoredTo: button, buttonWindow: buttonWindow)
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        contentController.view.window?.makeFirstResponder(nil)
        if popover.isShown { installMonitors() }
        let clip = scrollView.contentView
        clip.scroll(to: clip.constrainBoundsRect(NSRect(origin: savedScrollOrigin, size: clip.bounds.size)).origin)
        scrollView.reflectScrolledClipView(clip)
    }

    private func layoutPanel(anchoredTo button: NSStatusBarButton, buttonWindow: NSWindow) {
        let screen = buttonWindow.screen ?? NSScreen.main ?? NSScreen.screens[0]
        let visible = screen.visibleFrame
        let desiredWidth = min(previewWidth ?? Self.maximumWidth, visible.width - 24)
        if desiredWidth != panelWidth {
            panelWidth = desiredWidth
            rebuildContent()
        }
        contentController.view.frame.size.width = desiredWidth
        contentController.view.layoutSubtreeIfNeeded()
        stack.layoutSubtreeIfNeeded()
        let chromeHeight = headerContainer.fittingSize.height + footerContainer.fittingSize.height
        let fittingHeight = max(chromeHeight + stack.fittingSize.height, 240)
        let maximumHeight = max(240, visible.height * 0.85)
        let desiredSize = NSSize(width: panelWidth, height: min(fittingHeight, maximumHeight))
        contentController.preferredContentSize = desiredSize
        popover.contentSize = desiredSize
        contentController.view.layoutSubtreeIfNeeded()
        scrollView.layoutSubtreeIfNeeded()
    }

    private func installMonitors() {
        removeMonitors()
        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            let location = NSEvent.mouseLocation
            DispatchQueue.main.async {
                guard let self = self else { return }
                if let button = self.anchorButton, let window = button.window,
                   window.convertToScreen(button.convert(button.bounds, to: nil)).contains(location) { return }
                self.close()
            }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .keyDown]) { [weak self] event in
            guard let self = self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 53 { self.close(); return nil }
                return event
            }
            if event.window === self.contentController.view.window || event.window === self.anchorButton?.window { return event }
            self.close()
            return event
        }
    }

    private func removeMonitors() {
        if let monitor = localMonitor { NSEvent.removeMonitor(monitor); localMonitor = nil }
        if let monitor = globalMonitor { NSEvent.removeMonitor(monitor); globalMonitor = nil }
    }

    func close() {
        popover.performClose(nil)
    }

    func popoverDidClose(_ notification: Notification) {
        savedScrollOrigin = scrollView.contentView.bounds.origin
        updateConfirmation = nil
        removeMonitors()
        anchorButton = nil
    }

}

private final class TokenDetailRow: NSView {
    let isModelDetail: Bool
    private(set) var columnLabels: [NSTextField] = []

    init(values: [String], header: Bool, accent: PanelAccent, modelDetail: Bool = false) {
        isModelDetail = modelDetail
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let row = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 4)
        row.distribution = .fillEqually
        for (index, value) in values.enumerated() {
            let size: CGFloat = header ? 10 : (modelDetail ? (index == 0 ? 9 : 10) : 11)
            let label = PanelUI.label(value, size: size,
                weight: header || modelDetail ? .regular : (index == 0 ? .regular : .semibold),
                color: header || modelDetail ? .secondaryLabelColor : (index == 1 ? accent.color : .labelColor),
                wrapping: false, monospacedDigits: !header && index > 0)
            label.alignment = index == 0 ? .left : .right
            if modelDetail && index == 0 {
                label.maximumNumberOfLines = 1
                label.lineBreakMode = .byTruncatingMiddle
                label.toolTip = value
            }
            row.addArrangedSubview(label)
            columnLabels.append(label)
        }
        addSubview(row)
        NSLayoutConstraint.activate([
            row.topAnchor.constraint(equalTo: topAnchor, constant: 2),
            row.leadingAnchor.constraint(equalTo: leadingAnchor),
            row.trailingAnchor.constraint(equalTo: trailingAnchor),
            row.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -2)
        ])
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class TokenBucketRow: NSButton {
    override var acceptsFirstResponder: Bool { true }
    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 || event.keyCode == 36 { performClick(nil) } else { super.keyDown(with: event) }
    }
    let cells: TokenDetailRow
    private var hovered = false { didSet { needsDisplay = true } }
    override var wantsUpdateLayer: Bool { true }

    init(bucket: UsagePanelModel.TokenBucket, accent: PanelAccent, expanded: Bool,
         tag: Int, target: AnyObject, action: Selector) {
        cells = TokenDetailRow(values: [(expanded ? "⌄ " : "› ") + bucket.summaryLabel, bucket.total, bucket.input, bucket.output],
            header: false, accent: accent)
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        title = ""
        isBordered = false
        isEnabled = true
        wantsLayer = true
        layer?.cornerRadius = 5
        self.tag = tag
        self.target = target
        self.action = action
        addSubview(cells)
        NSLayoutConstraint.activate([
            cells.topAnchor.constraint(equalTo: topAnchor),
            cells.leadingAnchor.constraint(equalTo: leadingAnchor),
            cells.trailingAnchor.constraint(equalTo: trailingAnchor),
            cells.bottomAnchor.constraint(equalTo: bottomAnchor)
        ])
        let summary = "\(bucket.detailLabel)，总量 \(bucket.total)，输入 \(bucket.input)，输出 \(bucket.output)"
        toolTip = bucket.models.isEmpty ? "暂无模型明细" : (expanded ? "收起模型明细" : "展开模型明细")
        setAccessibilityLabel(summary + (bucket.models.isEmpty ? "，无模型明细" : "，\(expanded ? "收起" : "展开")模型明细"))
    }

    override func updateLayer() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            layer?.backgroundColor = NSColor.labelColor.withAlphaComponent(hovered && isEnabled ? 0.08 : 0).cgColor
        }
    }
    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        needsDisplay = true
    }
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        for area in trackingAreas { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { hovered = true }
    override func mouseExited(with event: NSEvent) { hovered = false }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard isEnabled, let parent = superview else { return super.hitTest(point) }
        return bounds.contains(convert(point, from: parent)) ? self : nil
    }

    func verifyHoverForPreview() -> Bool {
        updateTrackingAreas()
        hovered = true; updateLayer()
        let highlighted = layer?.backgroundColor?.alpha ?? 0
        hovered = false; updateLayer()
        let cleared = layer?.backgroundColor?.alpha ?? 0
        return highlighted > 0 && cleared == 0 && !trackingAreas.isEmpty
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

private final class TokenSectionView: NSView {
    init(model: UsagePanelModel.TokenSection, expanded: Bool, expandedBuckets: Set<Int>,
         target: AnyObject, action: Selector, bucketAction: Selector) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let root = PanelUI.stack(spacing: 4)
        let header = PanelSectionHeading.make(title: model.title, symbol: model.accent.symbol,
            color: model.accent.color, expanded: expanded, target: target, action: action)
        PanelUI.addFullWidth(header, to: root)
        if expanded {
            let tableHeader = TokenDetailRow(values: ["周期", "总量", "输入", "输出"], header: true, accent: model.accent)
            PanelUI.addFullWidth(tableHeader, to: root)
            for (index, bucket) in model.buckets.enumerated() {
                let row = TokenBucketRow(bucket: bucket, accent: model.accent,
                    expanded: expandedBuckets.contains(index), tag: index, target: target, action: bucketAction)
                PanelUI.addFullWidth(row, to: root)
                if expandedBuckets.contains(index) {
                    if bucket.models.isEmpty {
                        PanelUI.addFullWidth(PanelUI.label(bucket.hasData ? "本周期暂无用量" : "本周期数据尚未读取", size: 10, color: .secondaryLabelColor), to: root)
                    }
                    for (modelIndex, tokenModel) in bucket.models.enumerated() {
                        let detail = TokenDetailRow(values: [tokenModel.name, tokenModel.total,
                            tokenModel.input, tokenModel.output], header: false,
                            accent: model.accent, modelDetail: true)
                        PanelUI.addFullWidth(detail, to: root)
                        if modelIndex == bucket.models.count - 1 { root.setCustomSpacing(8, after: detail) }
                    }
                }
            }
        }
        for notice in PanelUI.notices(model.notices) { PanelUI.addFullWidth(notice, to: root) }
        addSubview(root)
        PanelUI.pin(root, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}

/// 版本号按钮：hover 显示指向光标，暗示可点击检查更新。
/// cursor rect 必须在 resetCursorRects() 内注册（在别处调用是 no-op）。
private final class PanelVersionButton: NSButton {
    override func resetCursorRects() { addCursorRect(bounds, cursor: .pointingHand) }
}

private final class PanelFooterView: NSView {
    init(model: UsagePanelModel, updateMessage: String?, target: UsagePanelController,
         buttonFactory: (NSMenuItem, PanelActionButton.Style, String?) -> PanelActionButton) {
        super.init(frame: .zero)
        translatesAutoresizingMaskIntoConstraints = false
        let root = PanelUI.stack(spacing: 8)
        let meta = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 8)
        meta.addArrangedSubview(PanelUI.label(model.lastAttempt, size: 11, color: .secondaryLabelColor, wrapping: false))
        meta.addArrangedSubview(PanelUI.spacer())
        let version = PanelVersionButton(title: model.version, target: target, action: #selector(UsagePanelController.requestUpdateCheck))
        version.isBordered = false
        version.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular)
        version.contentTintColor = .secondaryLabelColor
        version.toolTip = "点击检查更新"
        version.setAccessibilityLabel("\(model.version)，点击检查更新")
        version.focusRingType = .none
        meta.addArrangedSubview(version)
        root.addArrangedSubview(meta)
        if let message = updateMessage {
            // 含"失败"/"错误"/"无法"关键词用红色，其余用次要色
            let isError = message.contains("失败") || message.contains("错误") || message.contains("无法")
            let msgColor: NSColor = isError ? .systemRed : .secondaryLabelColor
            let label = PanelUI.label(message, size: 11, color: msgColor)
            root.addArrangedSubview(label)
        }

        let actions = PanelUI.stack(orientation: .horizontal, alignment: .centerY, spacing: 6)
        let refresh = buttonFactory(model.refreshItem, .prominent, nil)
        refresh.widthAnchor.constraint(equalToConstant: 76).isActive = true
        actions.addArrangedSubview(refresh)
        actions.addArrangedSubview(buttonFactory(model.loginItem, .checkbox, nil))
        actions.addArrangedSubview(PanelUI.spacer())
        let quit = buttonFactory(model.quitItem, .plain, nil)
        quit.widthAnchor.constraint(equalToConstant: 40).isActive = true
        actions.addArrangedSubview(quit)
        root.addArrangedSubview(actions)
        addSubview(root)
        PanelUI.pin(root, to: self)
    }
    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
}


// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private let panelController = UsagePanelController()
    private var timer: Timer?
    private var updateTimer: Timer?
    private var usage = UsageData()
    private var cycle = 0
    private let refreshGate = RefreshGate()
    private let visualPreview = CommandLine.arguments.contains { $0.hasPrefix("--visual-preview") }
    // token 扫描每 N 个刷新周期做一次（主循环 10s × 30 = 5 分钟；额度每轮都刷）
    private let tokenEveryCycles = 30
    // 数据过期阈值：额度 10 分钟、token 统计 30 分钟——超过该时长未成功刷新即在 UI 标 ⚠
    // （与 GlmUsage 的静默保留旧数据不同，这是刻意改进：过期数据必须可见）
    private let quotaStaleAfter: TimeInterval = 600
    private let tokensStaleAfter: TimeInterval = UsageFreshness.staleSeconds
    private let tiboStaleAfter: TimeInterval = UsageFreshness.staleSeconds
    private var fiveHourLastOK: Date?
    private var sevenDayLastOK: Date?
    private var tokensLastOK: Date?
    private var resetCardsLastOK: Date?
    private var tiboLastOK: Date?
    private var extLastOK: Date?
    private var resetUseInFlight = false
    private let pendingResetKey = "pendingResetRedemptionV1"
    private var accountIdentity: String?
    private var accountGeneration = 0
    private var quotaHistoryCoordinator: QuotaCycleCoordinator?
    private var quotaHistorySnapshot = QuotaCycleSnapshot(state: QuotaCycleState(), isLoading: false, isSaved: true)
    private var lastAttemptAt = Date()
    private let launchAgentLabel = "com.local.codex-usage"
    // 深浅主题切换重画（GlmUsage 同款）：菜单栏是彩色非模板图，不随系统明暗自动变色。
    // setImage 也会再次触发 KVO 通知，用明暗主题快照去重防止 renderBar↔KVO 反馈循环。
    private var statusItemAppearanceObs: NSKeyValueObservation?
    private var barThemeDark: Bool?
    // 菜单栏可因深色壁纸、双屏或全屏而与 App 外观合法地不同，不能用 App 外观覆盖菜单栏。
    // 每 5s 对账，不一致时仅重建不缓存的动态颜色图片，不切换 isVisible、不钉死绘制外观。
    private var appearancePollTimer: Timer?
    // status.json 去重：内容不变时跳过原子写，避免每 5-10s 无意义的 fsync+rename
    private var lastStatusData: Data?
    private var updateProgressObserver: NSObjectProtocol?
    private var updateProgressWasActive = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[CodexUsage] launched, creating status item")
        if CommandLine.arguments.contains("--visual-preview-dark") {
            NSApp.appearance = NSAppearance(named: .darkAqua)
        }
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePanel)
        panelController.onCheckUpdate = { [weak self] in self?.manualUpdateCheck() }
        panelController.onConfirmUpdate = { [weak self] tag, notes in self?.startConfirmedUpdate(tag: tag, notes: notes) }
        panelController.onUseReset = { [weak self] in self?.beginUseReset() }
        quotaHistoryCoordinator = QuotaHistoryStartup.make(visualPreview: visualPreview) {
            let historyRoot = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent("Library/Application Support/CodexUsage/quota-history", isDirectory: true)
            return QuotaCycleCoordinator(root: historyRoot, writer: { data, url in
                try AtomicJSONFile.replace(data, at: url.path)
            }, deliver: { [weak self] snapshot in
                guard let self = self else { return }
                self.quotaHistorySnapshot = snapshot
                self.rebuildMenu() // no renderBar / status.json write
            })
        }
        if visualPreview {
            configureVisualPreview()
            return
        }
        rebuildMenu()
        renderBar()
        // 面板内更新进度：状态翻转时重建内容（按钮↔进度行），进度百分比由进度行自刷；
        // 菜单栏 toolTip 同步更新状态，面板关闭时更新也在后台继续
        updateProgressObserver = NotificationCenter.default.addObserver(
            forName: UpdateProgressController.didChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in self?.updateProgressDidChange() }
        refresh(tokens: true, manual: true)
        attachBarAppearanceObserver()
        appearancePollTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            self?.reconcileBarAppearance()
        }
        appearancePollTimer?.tolerance = 1
        timer = Timer.scheduledTimer(withTimeInterval: 10, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.cycle += 1
            self.refresh(tokens: CodexRefreshSchedule.slowItemsDue(cycle: self.cycle,
                every: self.tokenEveryCycles, manual: false))
        }
        timer?.tolerance = 3
        // 更新检查：启动 20 秒后首查（避开启动网络高峰），此后每 30 分钟；
        // 打开菜单也会触发一次（同一 interval 节流，不增加请求频率）
        updateTimer = Timer.scheduledTimer(withTimeInterval: UpdateCheck.interval, repeats: true) { [weak self] _ in
            self?.checkForUpdate()
        }
        updateTimer?.tolerance = 60
        DispatchQueue.main.asyncAfter(deadline: .now() + 20) { [weak self] in self?.checkForUpdate() }
    }

    /// 本地视觉验收：固定数据、无网络/定时器，也不覆盖真实 status.json。
    /// 默认展示绿/红；normal 展示当前色/橙；full 展示 100%；states / empty 覆盖异常与空数据。
    private func configureVisualPreview() {
        let arguments = CommandLine.arguments
        if arguments.contains(where: { $0.hasPrefix("--visual-preview-quota-history") }) && !arguments.contains("--visual-preview-empty") {
            let count = arguments.contains("--visual-preview-quota-history=25") ? 25 :
                (arguments.contains("--visual-preview-quota-history=1") ? 1 : (arguments.contains("--visual-preview-quota-history=6") ? 6 : 13))
            quotaHistorySnapshot = QuotaCyclePreviewFixture.make(count: count)
            if arguments.contains("--visual-preview-quota-history-unstable") {
                quotaHistorySnapshot = QuotaCycleSnapshot(state: QuotaCycleState(), isLoading: false, isSaved: true)
            } else if arguments.contains("--visual-preview-quota-history-loading") {
                quotaHistorySnapshot = QuotaCycleSnapshot(state: QuotaCycleState(), isLoading: true, isSaved: true)
            } else if arguments.contains("--visual-preview-quota-history-unsaved") {
                quotaHistorySnapshot = QuotaCycleSnapshot(state: quotaHistorySnapshot.state, isLoading: false, isSaved: false)
            } else if arguments.contains("--visual-preview-quota-history-pending"), let current = quotaHistorySnapshot.state.current, let first = current.evidence.first {
                var state = quotaHistorySnapshot.state
                state.pendingTransition = QuotaPendingTransition(baselineCycleID: current.id, first: first, reason: .planChange)
                quotaHistorySnapshot = QuotaCycleSnapshot(state: state, isLoading: false, isSaved: true)
            }
        }
        let normal = arguments.contains("--visual-preview-normal")
        if arguments.contains("--visual-preview-narrow") {
            panelController.previewWidth = 320
        }
        let now = Date()
        usage.fiveHour = QuotaWindow(usedPercent: normal ? 40 : 10, reset: now + 18_000)
        usage.sevenDay = QuotaWindow(usedPercent: normal ? 80 : 90, reset: now + 604_800)
        if arguments.contains("--visual-preview-full") {
            usage.fiveHour = QuotaWindow(usedPercent: 0, reset: now + 18_000)
            usage.sevenDay = QuotaWindow(usedPercent: 0, reset: now + 604_800)
        }
        // 更新进度行预览：updating 为下载中 62%；updating-install 为安装重启阶段（含重启预告）
        if arguments.contains("--visual-preview-updating-install") {
            UpdateProgressController.shared.simulateForPreview(phase: .installing, fraction: 100)
        } else if arguments.contains("--visual-preview-updating") {
            UpdateProgressController.shared.simulateForPreview(phase: .downloading, fraction: 62)
        }
        usage.planType = "plus"
        usage.email = "preview@example.com"
        usage.resetCards = [
            ResetCard(expires: now + 172_800, name: "全额重置卡", id: "preview-1", usable: true),
            ResetCard(expires: now + 28 * 86_400, name: "全额重置卡"),
            ResetCard(expires: now + 29 * 86_400, name: "全额重置卡")
        ]
        if arguments.contains("--visual-preview-long") {
            usage.resetCards = (0..<100).map {
                ResetCard(expires: now + TimeInterval($0 + 3) * 86_400, name: "全额重置卡 \($0 + 1)")
            }
        }
        usage.tiboEvents = [
            TiboEvent(id: "preview-announced", type: "direct_reset", status: "announced",
                title: "Codex 额度重置预告", estimateLabel: "北京时间 11月4日 15:00–20:00",
                estimateFrom: now + 86_400, estimateThrough: now + 90_000,
                presentationStatus: nil, occurredAt: nil, link: "https://aihot.news/codex-reset"),
            TiboEvent(id: "preview-confirmed", type: "reset_credit", status: "confirmed",
                title: "重置卡已发放", estimateLabel: nil, estimateFrom: nil, estimateThrough: nil,
                presentationStatus: nil, occurredAt: now - 86_400, link: "https://aihot.news/codex-reset")
        ]
        usage.tokensToday = TokenScanner.Stats(input: 1_200_000, output: 300_000, total: 1_500_000, files: 3, models: [
            "gpt-5.5-codex": ModelTokenUsage(input: 700_000, output: 180_000, total: 880_000),
            "gpt-5.5": ModelTokenUsage(input: 500_000, output: 120_000, total: 620_000)
        ])
        usage.tokens7d = TokenScanner.Stats(input: 8_000_000, output: 2_000_000, total: 10_000_000, files: 20, models: [
            "gpt-5.5-codex": ModelTokenUsage(input: 5_000_000, output: 1_200_000, total: 6_200_000),
            "gpt-5.5": ModelTokenUsage(input: 3_000_000, output: 800_000, total: 3_800_000)
        ])
        usage.tokens30d = TokenScanner.Stats(input: 24_000_000, output: 6_000_000, total: 30_000_000, files: 60, models: [
            "gpt-5.5-codex": ModelTokenUsage(input: 14_000_000, output: 3_600_000, total: 17_600_000),
            "gpt-5.5": ModelTokenUsage(input: 10_000_000, output: 2_400_000, total: 12_400_000)
        ])
        usage.extToday = ExternalTokenScanner.Stats(input: 3_350_000, output: 20_000, models: [
            "gpt-5.6-sol": ModelTokenUsage(input: 2_000_000, output: 12_000, total: 2_012_000),
            "gpt-5.5": ModelTokenUsage(input: 1_350_000, output: 8_000, total: 1_358_000)
        ])
        usage.ext7d = ExternalTokenScanner.Stats(input: 64_710_000, output: 230_000, models: [
            "gpt-5.6-sol": ModelTokenUsage(input: 40_000_000, output: 150_000, total: 40_150_000),
            "gpt-5.5": ModelTokenUsage(input: 24_710_000, output: 80_000, total: 24_790_000)
        ])
        usage.ext30d = ExternalTokenScanner.Stats(input: 653_870_000, output: 3_480_000, models: [
            "gpt-5.6-sol": ModelTokenUsage(input: 400_000_000, output: 2_000_000, total: 402_000_000),
            "gpt-5.5": ModelTokenUsage(input: 253_870_000, output: 1_480_000, total: 255_350_000)
        ])
        let demoFormatter = DateFormatter(); demoFormatter.locale = Locale(identifier: "en_US_POSIX"); demoFormatter.timeZone = .current; demoFormatter.dateFormat = "yyyy-MM-dd"
        var demoDays: [String: Double] = [:]
        for day in 0..<30 {
            let date = Calendar.current.date(byAdding: .day, value: -day, to: now)!
            let value: Double = day == 0 ? 118 : (day == 1 ? 100 : (day < 7 ? 88 : 100))
            demoDays[demoFormatter.string(from: date)] = value * 100_000
        }
        if arguments.contains("--visual-preview-events") || arguments.contains("--visual-preview-hover-fixture") {
            let ordered = demoDays.keys.sorted(); demoDays.removeValue(forKey: ordered[0]); demoDays[ordered[1]] = 0
            demoDays.removeValue(forKey: ordered[2])
            demoDays.removeValue(forKey: ordered[29])   // 今日改由本机扫描补足：预览描边未结束柱
        }
        usage.official = OfficialUsageSnapshot(lifetime: 3_180_000_000, days: demoDays, fetchedAt: Date(),
            sparsePolicy: arguments.contains("--visual-preview-events") || arguments.contains("--visual-preview-hover-fixture") ? .officialActivity : .unknown)
        usage.externalTools["Proma"] = [usage.extToday!, usage.ext7d!, usage.ext30d!]
        usage.sourceStatus = ["Codex": .available, "Proma": .available, "Claude Code": .absent, "Hermes": .absent]
        if arguments.contains("--visual-preview-pro") { usage.planType = "pro"; usage.fiveHour = nil; usage.fiveHourNotApplicable = true }
        fiveHourLastOK = now
        sevenDayLastOK = now
        tokensLastOK = now
        resetCardsLastOK = now
        tiboLastOK = now
        extLastOK = now
        lastAttemptAt = now

        if arguments.contains("--visual-preview-empty") {
            usage.fiveHour = nil
            usage.sevenDay = nil
            usage.resetCards = []
            usage.tiboEvents = []
            usage.tokensToday = nil
            usage.tokens7d = nil
            usage.tokens30d = nil
            usage.extToday = nil
            usage.ext7d = nil
            usage.ext30d = nil
            usage.official = nil; usage.externalTools = [:]
        } else if arguments.contains("--visual-preview-states") {
            usage.fiveHour = QuotaWindow(usedPercent: 65, reset: now + 18_000)
            usage.sevenDay = nil
            usage.fiveHourError = "网络请求超时"
            usage.sevenDayError = "凭证已过期"
            usage.quotaError = "额度服务暂不可用"
            usage.resetCardsError = "明细接口暂不可用"
            usage.tiboError = "AIHOT 暂不可用"
            usage.tokensError = "会话目录读取失败"
            usage.extError = "外部会话来源不可读"
            fiveHourLastOK = now - 3_600
            sevenDayLastOK = nil
            tokensLastOK = now - 3_600
            resetCardsLastOK = now - 3_600
            tiboLastOK = now - 3_600
            extLastOK = now - 3_600
        }
        if arguments.contains("--visual-preview-empty-failure") {
            usage.tokensError = "会话目录读取失败"
            usage.sourceStatus["Proma"] = .failed
            usage.externalTools = [:]
        }
        if arguments.contains("--visual-preview-models") {
            panelController.expandAllTokenBucketsForPreview()
        }
        if arguments.contains("--visual-preview-tools") { panelController.expandToolsForPreview() }
        if arguments.contains("--visual-preview-daily-collapsed") { panelController.collapseDailyForPreview() }

        rebuildMenu()
        renderBar()
        if arguments.contains("--visual-preview-update-notes") || arguments.contains("--visual-preview-update-notes-long") {
            let sample = "## 新增\n- 支持切换面板背景样式\n\n## 优化\n- 可在安装前查看更新内容"
            panelController.showUpdateConfirmation(tag: "v9.9.9", notes: arguments.contains("--visual-preview-update-notes-long") ? Array(repeating: sample, count: 8).joined(separator: "\n") : sample)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self, let button = self.statusItem.button else { return }
            self.panelController.toggle(anchoredTo: button)
            if arguments.contains("--visual-preview-background-test") {
                guard self.panelController.verifyBackgroundForPreview() else {
                    fputs("CodexUsage background test: FAIL\n", stderr); exit(1)
                }
                print("CodexUsage background test: PASS"); exit(0)
            }
            if arguments.contains("--visual-preview-confirm-test") {
                guard self.panelController.verifyConfirmationForPreview() else {
                    fputs("CodexUsage confirmation test: FAIL\n", stderr); exit(1)
                }
                print("CodexUsage confirmation test: PASS"); exit(0)
            }
            let outputPrefix = "--visual-preview-output="
            if let argument = arguments.first(where: { $0.hasPrefix(outputPrefix) }) {
                let path = String(argument.dropFirst(outputPrefix.count))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                    if arguments.contains(where: { $0.hasPrefix("--visual-preview-quota-history") }) { self.panelController.scrollQuotaHistoryForPreview() }
                    if arguments.contains("--visual-preview-scroll-end") {
                        _ = self.panelController.scrollToEndForPreview()
                    }
                    let hoverPrefix = "--visual-preview-hover-index="
                    if let arg = arguments.first(where: { $0.hasPrefix(hoverPrefix) }) {
                        guard let index = Int(arg.dropFirst(hoverPrefix.count)), self.panelController.showChartHoverForPreview(index: index) else {
                            fputs("CodexUsage visual preview: invalid or out-of-bounds chart overlay\n", stderr); exit(1)
                        }
                    }
                    guard self.panelController.savePreviewImage(to: path) else {
                        fputs("CodexUsage visual preview: failed to save image\n", stderr)
                        exit(1)
                    }
                    print("CodexUsage visual preview image: \(path)")
                    exit(0)
                }
            } else if let argument = arguments.first(where: { $0.hasPrefix("--visual-preview-popover-test=") }) {
                let directory = String(argument.dropFirst("--visual-preview-popover-test=".count))
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                    self.panelController.verifyPopoverGeometryForPreview(outputDirectory: directory)
                }
            } else if arguments.contains("--visual-preview-events") {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    self.runVisualPanelEventTest()
                }
            }
        }
    }

    /// 实际经 NSEvent 分发验证 Esc 与面板外点击，而非直接调用 close() 冒充通过。
    private func runVisualPanelEventTest() {
        func fail(_ message: String) {
            fputs("CodexUsage visual event test: FAIL: \(message)\n", stderr)
            exit(1)
        }
        if !panelController.isOpen, let button = statusItem.button {
            panelController.toggle(anchoredTo: button)
        }
        guard panelController.isOpen else { return fail("preview panel did not open") }
        guard panelController.verifyCardLayoutForPreview() else { return fail("card layout or spacing failed") }
        guard let statusButton = statusItem.button else { return fail("status button missing") }
        statusButton.performClick(nil)
        guard !panelController.isOpen else { return fail("status button did not close panel") }
        statusButton.performClick(nil)
        guard panelController.isOpen else { return fail("status button did not reopen panel") }
        if CommandLine.arguments.contains("--visual-preview-long")
            && !panelController.verifyNonzeroScrollForPreview() {
            return fail("long content did not scroll")
        }
        guard panelController.verifyTokenBucketInteractionsForPreview() else {
            return fail("token bucket expansion, collapse, or refresh state failed")
        }
        guard panelController.verifyCardLayoutForPreview() else { return fail("card layout changed after interactions") }
        guard panelController.verifyChartInteractionsForPreview() else { return fail("chart hover or keyboard navigation failed") }
        if CommandLine.arguments.contains(where: { $0.hasPrefix("--visual-preview-quota-history") }) && quotaHistorySnapshot.state.closed.count >= 12 {
            guard panelController.verifyQuotaHistoryEventsForPreview() else { return fail("quota history event interaction failed") }
            print("CodexUsage quota history event test: PASS (mouse selection/hover, keyboard paging, load earlier, collapse, refresh/account reset)")
            panelController.prepareQuotaReopenForPreview()
        }
        panelController.prepareReopenStateForPreview()
        guard let escape = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: panelController.previewWindowNumber, context: nil, characters: "\u{1b}",
            charactersIgnoringModifiers: "\u{1b}", isARepeat: false, keyCode: 53) else {
            return fail("could not create Escape event")
        }
        NSApp.postEvent(escape, atStart: false)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            guard let self = self else { return }
            guard !self.panelController.isOpen else { return fail("Escape did not close panel") }
            guard let button = self.statusItem.button else { return fail("status button missing") }
            self.panelController.toggle(anchoredTo: button)
            guard self.panelController.isOpen else { return fail("panel did not reopen") }
            guard self.panelController.verifyReopenStateForPreview() else { return fail("section or period state lost after reopen") }
            guard self.panelController.verifyQuotaReopenForPreview() else { return fail("quota history selection or page lost after reopen") }
            guard let outside = NSEvent.mouseEvent(with: .leftMouseDown, location: .zero,
                modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                eventNumber: 0, clickCount: 1, pressure: 1) else {
                return fail("could not create outside click event")
            }
            NSApp.postEvent(outside, atStart: false)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                guard !self.panelController.isOpen else { return fail("outside click did not close panel") }
                self.panelController.toggle(anchoredTo: button)
                guard let refresh = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: self.panelController.previewWindowNumber, context: nil, characters: "r",
                    charactersIgnoringModifiers: "r", isARepeat: false, keyCode: 15) else {
                    return fail("could not create refresh key event")
                }
                NSApp.postEvent(refresh, atStart: false)
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    guard self.panelController.isOpen else { return fail("refresh action closed the panel") }
                    print("CodexUsage visual event test: PASS (card layout, status button toggle, model rows, tool periods, chart movement handler/keyboard, Escape, outside click, refresh keeps panel open)")
                    exit(0)
                }
            }
        }
    }

    // 拉取数据：额度走网络（回调内含 401 兜底刷新），token 扫描与重置卡明细走每 5 分钟周期
    private func refresh(tokens: Bool, manual: Bool = false) {
        guard !visualPreview else { return }
        guard refreshGate.begin(manual: manual) else { return }
        performRefresh(tokens: tokens || manual)
    }

    private func performRefresh(tokens: Bool) {
        synchronizeAccount()
        let generation = accountGeneration
        let identity = accountIdentity
        let auth = CodexAuth.load()
        guard CodexAuth.identity(auth) == identity else {
            synchronizeAccount()
            updateUI()
            if refreshGate.finish() { performRefresh(tokens: true) }
            return
        }
        lastAttemptAt = Date()
        updateUI()
        let group = DispatchGroup()
        let quotaRequestStartedAt = Date()
        group.enter()
        Fetcher.fetchQuota(auth: auth) { [weak self] r in
            DispatchQueue.main.async {
                if let self = self {
                    if self.acceptAccountResponse(generation: generation, identity: identity) {
                        self.applyQuota(r)
                        if let identity = identity, let sample = QuotaHistoryAdapter.observation(r, requestStartedAt: quotaRequestStartedAt, observedAt: Date()) {
                            self.quotaHistoryCoordinator?.observe(sample, identity: identity, generation: generation)
                        }
                    }
                }
                group.leave()
            }
        }
        if tokens {
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                // Codex CLI 本机会话与外部用量（Proma/Claude Code/hermes）都是纯本地扫描，
                // 串在同一 utility 块里，互不争抢也只进出一个 group 名额
                let r = TokenScanner.scan()
                let e = ExternalTokenScanner.scan()
                DispatchQueue.main.async {
                    self?.applyTokens(r)
                    self?.applyExternal(e)
                    group.leave()
                }
            }
            group.enter()
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let result = OfficialUsageReader.read(expected: auth)
                DispatchQueue.main.async {
                    if let self = self, self.acceptAccountResponse(generation: generation, identity: identity) {
                        switch result {
                        case .success(let snapshot): self.usage.official = snapshot; self.usage.officialError = nil
                        case .failure(.unavailable): self.usage.officialError = "网络不可用"
                        case .failure(.unsupported): self.usage.officialError = "当前账号或环境不支持"
                        case .failure(.timeout): self.usage.officialError = "查询超时"
                        case .failure(.invalid): self.usage.officialError = "查询失败"
                        case .failure(.unauthorized): self.usage.officialError = "账号认证失效，等待额度刷新后重试"
                        case .failure(.identityMismatch): self.usage.officialError = "无法确认账号一致"
                        }
                    }
                    group.leave()
                }
            }
            // 重置卡（额度重置卡）：与 token 统计同周期；失败不触发额度 ⚠ 过期标注
            group.enter()
            Fetcher.fetchResetCards(auth: auth) { [weak self] cards, err in
                DispatchQueue.main.async {
                    if let self = self, self.acceptAccountResponse(generation: generation, identity: identity) {
                        self.applyResetCards(cards, err)
                    }
                    group.leave()
                }
            }
            // Tibo 重置动态（AIHOT 公开接口，匿名只读）：同周期；失败只降级本区块
            group.enter()
            Fetcher.fetchTiboResets { [weak self] outcome in
                DispatchQueue.main.async {
                    self?.applyTibo(outcome)
                    group.leave()
                }
            }
        }
        group.notify(queue: .main) { [weak self] in
            guard let self = self else { return }
            // 各 apply 回调只更新数据，渲染统一在这里做一次：
            // 菜单重建与 status.json 写入每轮刷新各一次，而不是每个数据源一次
            self.updateUI()
            if self.refreshGate.finish() { self.performRefresh(tokens: true) }
        }
    }

    private func synchronizeAccount() {
        let current = CodexAuth.identity(CodexAuth.load())
        guard current != accountIdentity else { return }
        accountIdentity = current
        accountGeneration += 1
        panelController.resetQuotaHistoryAccount()
        quotaHistorySnapshot = QuotaCycleSnapshot(state: QuotaCycleState(), isLoading: QuotaCycleCoordinator.accountKey(current) != nil, isSaved: true)
        quotaHistoryCoordinator?.activate(accountIdentity: current, generation: accountGeneration)
        AccountIsolation.clear(&usage)
        fiveHourLastOK = nil; sevenDayLastOK = nil; resetCardsLastOK = nil
    }

    private func acceptAccountResponse(generation: Int, identity: String?) -> Bool {
        synchronizeAccount()
        return AccountIsolation.accepts(capturedGeneration: generation, currentGeneration: accountGeneration,
                                        capturedIdentity: identity, currentIdentity: accountIdentity)
    }

    /// 菜单栏图标 + 下拉菜单的统一渲染入口；面板打开时也就地重建（refreshPanelLayout 保持滚动位置、无动画闪断）
    private func updateUI() {
        renderBar()
        rebuildMenu()
    }

    @objc private func togglePanel() {
        guard let button = statusItem.button else { return }
        panelController.toggle(anchoredTo: button)
        if panelController.isOpen {
            refresh(tokens: false)
            checkForUpdate()   // 节流共享 30 分钟 interval，不增加 GitHub 请求频率
        }
    }


    // 本次新拉到的值非 nil 才算成功、才推进 lastOK；失败时保留旧数据 + 错误行
    private func applyQuota(_ r: QuotaData) {
        let now = Date()
        let five = QuotaMerge.fiveHour(r, old: usage.fiveHour, oldLastOK: fiveHourLastOK,
                                        wasNotApplicable: usage.fiveHourNotApplicable, now: now)
        usage.fiveHour = five.0; fiveHourLastOK = five.1; usage.fiveHourNotApplicable = five.2
        sevenDayLastOK = CodexFreshness.updated(sevenDayLastOK, succeeded: r.sevenDay != nil, at: now)
        usage.fiveHourUnavailable = r.fiveHourUnavailable
        usage.sevenDayUnavailable = r.sevenDayUnavailable
        usage.sevenDay = QuotaMerge.preferred(r.sevenDay, old: usage.sevenDay)
        usage.planType = r.error == nil ? r.planType : (r.planType ?? usage.planType)
        usage.resetCredits = r.resetCredits ?? usage.resetCredits
        usage.fiveHourError = usage.fiveHourNotApplicable ? nil : (r.fiveHour == nil ? (r.fiveHourError ?? r.error) : nil)
        usage.sevenDayError = r.sevenDay == nil ? (r.sevenDayError ?? r.error) : nil
        usage.quotaError = r.error
        usage.email = r.email ?? usage.email
    }

    private func applyTokens(_ r: TokenScanner.Result) {
        tokensLastOK = CodexFreshness.updated(tokensLastOK, succeeded: r.error == nil, at: Date())
        if let e = r.error {
            usage.tokensError = e
        } else {
            usage.tokensToday = r.today
            usage.tokens7d = r.seven
            usage.tokens30d = r.thirty
            usage.tokensError = nil
        }
    }

    // 外部用量：成功则全量替换快照；已安装来源全部不可读时保留旧值、不推进 lastOK
    // （30 分钟后现有 ⚠ 过期标注自动亮起），并显示错误行
    private func applyExternal(_ r: ExternalTokenScanner.Result) {
        usage.sourceStatus = r.sourceStatus
        if let e = r.error {
            usage.extError = e
        } else {
            extLastOK = CodexFreshness.updated(extLastOK, succeeded: true, at: Date())
            usage.externalTools = r.tools
            usage.extToday = r.today
            usage.ext7d = r.seven
            usage.ext30d = r.thirty
            usage.extError = nil
        }
    }

    // 重置卡：成功则更新并清错误；瞬时失败保留上次数据、仅记录错误
    // （有旧数据时菜单仍展示未过期的旧卡；卡数据状态与额度窗口互相独立）
    private func applyResetCards(_ cards: [ResetCard]?, _ err: String?) {
        let r = CodexFreshness.apply(fresh: cards, failure: err,
            old: usage.resetCards, oldLastOK: resetCardsLastOK, oldError: usage.resetCardsError, now: Date())
        usage.resetCards = r.value
        resetCardsLastOK = r.lastOK
        usage.resetCardsError = r.error
    }

    // Tibo 动态：304 = 内容未变但服务端确认有效（推进成功时间）；失败保留旧数据与旧成功时间。
    // 纯函数返回结果后顺序赋值（不把 usage 的多个子字段同时作 inout 实参）
    private func applyTibo(_ outcome: TiboFetchOutcome) {
        let r = TiboFreshness.apply(outcome: outcome, old: usage.tiboEvents,
            oldCheckedAt: usage.tiboCheckedAt, oldLastOK: tiboLastOK, oldError: usage.tiboError, now: Date())
        usage.tiboEvents = r.value
        usage.tiboCheckedAt = r.checkedAt
        tiboLastOK = r.lastOK
        usage.tiboError = r.error
    }

    // 过期判定：距最后成功超过阈值即过期；有数据但 lastOK 为 nil（异常情况）也视为过期。
    // 无数据不算过期——菜单里本就显示"暂无数据"，无需再标注。
    private func isStale(_ lastOK: Date?, hasData: Bool, after: TimeInterval) -> Bool {
        CodexFreshness.isStale(lastSuccess: lastOK, hasData: hasData, now: Date(), after: after)
    }
    private var fiveHourStale: Bool {
        isStale(fiveHourLastOK, hasData: usage.fiveHour != nil, after: quotaStaleAfter)
    }
    private var sevenDayStale: Bool {
        isStale(sevenDayLastOK, hasData: usage.sevenDay != nil, after: quotaStaleAfter)
    }
    private var tokensStale: Bool {
        isStale(tokensLastOK,
                hasData: usage.tokensToday != nil || usage.tokens7d != nil || usage.tokens30d != nil,
                after: tokensStaleAfter)
    }
    private var resetCardsStale: Bool {
        isStale(resetCardsLastOK, hasData: usage.resetCards != nil, after: 900)
    }
    private var tiboStale: Bool {
        isStale(tiboLastOK, hasData: usage.tiboEvents != nil, after: tiboStaleAfter)
    }
    private var extStale: Bool {
        isStale(extLastOK,
                hasData: usage.extToday != nil || usage.ext7d != nil || usage.ext30d != nil,
                after: tokensStaleAfter)
    }

    // 菜单栏显示：5H / 7D 两行堆叠（剩余口径）；额度过期时第一行前缀 ⚠
    private func attachBarAppearanceObserver() {
        statusItemAppearanceObs = statusItem.button?.observe(\.effectiveAppearance) { [weak self] _, _ in
            DispatchQueue.main.async { self?.renderBarIfThemeChanged() }
        }
    }

    private func isDark(_ appearance: NSAppearance) -> Bool {
        appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua
    }

    /// 外观不一致既可能是按钮粘滞，也可能是深色壁纸或双屏的正常状态。
    /// 因此只重建不缓存的动态颜色图片，让实际菜单栏绘制上下文决定颜色。
    /// 只调 renderBarImage()，不触发 status.json 写入。
    private func reconcileBarAppearance() {
        guard let button = statusItem?.button else { return }
        let appDark = isDark(NSApp.effectiveAppearance)
        let buttonDark = isDark(button.effectiveAppearance)
        if buttonDark != appDark {
            renderBarImage()
        } else {
            renderBarIfThemeChanged()
        }
    }

    /// 仅当按钮解析出的明暗主题与上次渲染快照不同时才重画（防止 setImage↔KVO 循环）
    private func renderBarIfThemeChanged() {
        guard let button = statusItem?.button else { return }
        let dark = isDark(button.effectiveAppearance)
        guard dark != barThemeDark else { return }
        renderBarImage()
    }

    /// 进度行自己刷新文本与百分比；这里只在「进行中」状态翻转时重建面板内容（按钮↔进度行），
    /// 并刷新菜单栏 toolTip。失败时面板若开着，额外给一条可重试的提示。
    private func updateProgressDidChange() {
        let active = UpdateProgressController.shared.isActive
        if active != updateProgressWasActive {
            updateProgressWasActive = active
            rebuildMenu()
            if !active, UpdateProgressController.shared.phase == .failed {
                panelController.setUpdateMessage("更新失败，详见弹窗提示", dismissAfter: 8)
            }
            renderBar()
        } else if UpdateProgressController.shared.isActive {
            // 下载进行中的百分比通知：只刷新 toolTip（含进度行文本），不重绘菜单栏图片、不重写 status.json
            statusItem.button?.toolTip = barToolTip()
        }
    }

    /// 菜单栏悬停提示：各来源最后成功时间 + 进行中的更新阶段
    private func barToolTip() -> String {
        var text = "Codex 用量"
            + (usage.fiveHourNotApplicable ? "" : " · 5H成功 \(fiveHourLastOK.map { Fmt.time($0) } ?? "--")")
            + " · 7D成功 \(sevenDayLastOK.map { Fmt.time($0) } ?? "--")"
            + " · Token 最后成功 \(tokensLastOK.map { Fmt.time($0) } ?? "--")"
            + " · 外部最后成功 \(extLastOK.map { Fmt.time($0) } ?? "--")"
            + " · 重置卡最后成功 \(resetCardsLastOK.map { Fmt.time($0) } ?? "--")"
            + " · Tibo 最后成功 \(tiboLastOK.map { Fmt.time($0) } ?? "--")"
        if UpdateProgressController.shared.isActive {
            text += " · \(UpdateProgressController.shared.statusLine)"
        }
        return text
    }

    /// 菜单栏图片 + toolTip 渲染，不写磁盘。供外观对账定时器（每 5s）直接调用。
    private func renderBarImage() {
        let fiveRemaining = Fmt.remaining(usage.fiveHour?.usedPercent)
        let sevenRemaining = Fmt.remaining(usage.sevenDay?.usedPercent)
        let line1 = StackImage.Line(label: (fiveHourStale ? "⚠ 5H" : "5H"),
                                    value: Fmt.remainingPct(usage.fiveHour?.usedPercent),
                                    remaining: fiveRemaining)
        let line2 = StackImage.Line(label: (sevenDayStale ? "⚠ 7D" : "7D"),
                                    value: Fmt.remainingPct(usage.sevenDay?.usedPercent),
                                    remaining: sevenRemaining)
        let appearance = statusItem.button?.effectiveAppearance ?? NSApp.effectiveAppearance
        barThemeDark = isDark(appearance)
        statusItem.button?.image = usage.fiveHourNotApplicable
            ? StackImage.make(line1: line2, line2: nil) : StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = barToolTip()
    }

    /// 完整渲染：图片 + toolTip + 写 status.json（内容去重，不变则跳过磁盘写）。
    /// 数据刷新路径（updateUI）调用此函数；外观对账路径只调 renderBarImage()。
    private func renderBar() {
        renderBarImage()
        guard !visualPreview else { return }
        let fiveRemaining = Fmt.remaining(usage.fiveHour?.usedPercent)
        let sevenRemaining = Fmt.remaining(usage.sevenDay?.usedPercent)
        let line1Label = fiveHourStale ? "⚠ 5H" : "5H"
        let line2Label = sevenDayStale ? "⚠ 7D" : "7D"
        let line1Value = Fmt.remainingPct(usage.fiveHour?.usedPercent)
        let line2Value = Fmt.remainingPct(usage.sevenDay?.usedPercent)
        writeStatus(
            line1: usage.fiveHourNotApplicable ? "\(line2Label) \(line2Value)" : "\(line1Label) \(line1Value)",
            line2: usage.fiveHourNotApplicable ? "" : "\(line2Label) \(line2Value)"
        )
        _ = fiveRemaining; _ = sevenRemaining // 保留供未来 writeStatus 直接使用
    }

    // 自诊断：把渲染内容写到本地，便于排查（绝不写任何凭证值）
    private func writeStatus(line1: String, line2: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/CodexUsage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        func iso(_ d: Date?) -> String { Fmt.isoStamp(d) }
        let cardsNow = CodexFreshness.availableCards(usage.resetCards ?? [], now: Date())
        let info: [String: Any] = [
            "line1": line1,
            "line2": line2,
            "planType": usage.planType ?? "",
            "fiveHourRemaining": Fmt.remainingInt(usage.fiveHour),
            "sevenDayRemaining": Fmt.remainingInt(usage.sevenDay),
            "fiveHourReset": usage.fiveHour?.reset.map { Fmt.dayTime($0) } ?? "",
            "sevenDayReset": usage.sevenDay?.reset.map { Fmt.dayTime($0) } ?? "",
            "resetCredits": usage.resetCredits ?? -1,
            "resetCards": cardsNow.map { iso($0.expires) },
            "resetCardsError": usage.resetCardsError ?? "",
            "tiboLines": TiboDisplay.rows(usage.tiboEvents ?? [], now: Date()).map { $0.text },
            "tiboCheckedAt": iso(usage.tiboCheckedAt),
            "tiboLastSuccess": iso(tiboLastOK),
            "tiboStale": tiboStale,
            "tiboError": usage.tiboError ?? "",
            "quotaLastSuccess": ["fiveHour": iso(fiveHourLastOK), "sevenDay": iso(sevenDayLastOK)],
            "tokensLastSuccess": iso(tokensLastOK),
            "externalTokensToday": Fmt.tokensAbbr(usage.extToday?.total),
            "externalTokens7d": Fmt.tokensAbbr(usage.ext7d?.total),
            "externalTokens30d": Fmt.tokensAbbr(usage.ext30d?.total),
            "externalTokensLastSuccess": iso(extLastOK),
            "externalTokensStale": extStale,
            "externalTokensError": usage.extError ?? "",
            "resetCardsLastSuccess": iso(resetCardsLastOK),
            "resetCardsStale": resetCardsStale,
            "fiveHourStale": usage.fiveHourNotApplicable ? false : fiveHourStale,
            "fiveHourNotApplicable": usage.fiveHourNotApplicable,
            "sevenDayStale": sevenDayStale,
            "tokensStale": tokensStale,
            "fiveHourError": usage.fiveHourError ?? "",
            "sevenDayError": usage.sevenDayError ?? "",
            "quotaError": usage.quotaError ?? "",
            "tokensError": usage.tokensError ?? "",
            "lastAttemptAt": iso(lastAttemptAt),
            "version": BuildInfo.version,
            "updateAvailable": UpdateChecker.shared.available
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            // 内容不变时跳过原子写，避免每 5-10s 无意义的 fsync+rename
            if data == lastStatusData { return }
            lastStatusData = data
            // 与扫描状态文件同口径：仅所有者可读（内容含会话路径与统计聚合）
            do {
                try AtomicJSONFile.replace(data, at: dir + "/status.json")
            } catch {
                NSLog("[CodexUsage] writeStatus failed: %@", error.localizedDescription)
            }
        }
    }

    // 下拉面板（六卡片自上而下，见 docs/project/11-usage-insights-prd.md §3）：
    // typed model 与网络/扫描数据在同一渲染入口组装
    private func rebuildMenu() {
        func notice(_ text: String, _ level: UsagePanelModel.NoticeLevel = .info) -> UsagePanelModel.Notice {
            UsagePanelModel.Notice(text: text, level: level)
        }

        var updateItem: NSMenuItem?
        let showPreviewUpdate = visualPreview && CommandLine.arguments.contains("--visual-preview-update")
        if UpdateChecker.shared.available || showPreviewUpdate {
            let item = NSMenuItem(title: "⬆ 新版本可用，点击更新", action: #selector(onUpdateApp), keyEquivalent: "")
            item.target = self
            updateItem = item
        }

        func quota(_ label: String, _ window: QuotaWindow?, isFive: Bool) -> UsagePanelModel.Quota {
            let last = isFive ? fiveHourLastOK : sevenDayLastOK
            let stale = isFive ? fiveHourStale : sevenDayStale
            let error = isFive ? usage.fiveHourError : usage.sevenDayError
            let unavailable = isFive ? usage.fiveHourUnavailable : usage.sevenDayUnavailable
            var resetText = "暂无数据"
            if let window = window {
                resetText = window.reset.map { Fmt.quotaReset($0) } ?? "时间未知"
            }
            var notices: [UsagePanelModel.Notice] = []
            if stale {
                var text = "⚠ 已过期"
                if let last = last { text += " · 最后成功 \(Fmt.dayTime(last))" }
                notices.append(notice(text, .warning))
            }
            if let error = error {
                var text = unavailable ? error : "刷新失败：\(error)"
                if !stale, let last = last { text += " · 最后成功 \(Fmt.dayTime(last))" }
                notices.append(notice(text, unavailable ? .info : .error))
            }
            return UsagePanelModel.Quota(title: label, resetText: resetText,
                remaining: Fmt.remaining(window?.usedPercent), notices: notices)
        }
        var quotas: [UsagePanelModel.Quota] = []
        if !usage.fiveHourNotApplicable { quotas.append(quota("5 小时窗口", usage.fiveHour, isFive: true)) }
        quotas.append(quota("7 天窗口", usage.sevenDay, isFive: false))

        var resetSection: UsagePanelModel.ResetSection?
        if let storedCards = usage.resetCards {
            let cards = CodexFreshness.availableCards(storedCards, now: Date())
            let rows = cards.map { card in
                UsagePanelModel.ResetRow(name: card.name,
                    expires: "\(Fmt.expires(card.expires)) 过期",
                    warning: card.expires.timeIntervalSinceNow <= 72 * 3600)
            }
            resetSection = UsagePanelModel.ResetSection(
                count: cards.isEmpty ? nil : cards.count,
                emptyText: cards.isEmpty ? "暂无可用" : nil,
                rows: rows, notices: [])
        } else if let error = usage.resetCardsError {
            if let count = usage.resetCredits, count > 0 {
                resetSection = UsagePanelModel.ResetSection(count: count, emptyText: nil,
                    rows: [], notices: [notice("明细获取失败：\(error)", .error)])
            } else {
                let short = error.count > 60 ? String(error.prefix(60)) + "…" : error
                resetSection = UsagePanelModel.ResetSection(count: nil, emptyText: nil, rows: [],
                    notices: [notice("重置卡获取失败：\(short)（Codex 登录态可能过期，运行 codex login 后重试）", .error)])
            }
        }
        let pendingReset = visualPreview ? nil : UserDefaults.standard.dictionary(forKey: pendingResetKey)
        if resetSection == nil && pendingReset != nil {
            resetSection = UsagePanelModel.ResetSection(count: nil, emptyText: nil, rows: [], notices: [])
        }
        if resetSection != nil {
            let pending = pendingReset
            if pending != nil {
                resetSection?.useTitle = "核对上次使用"
                resetSection?.useEnabled = !visualPreview && !resetUseInFlight
                    && pending?["identity"] as? String == accountIdentity
                resetSection?.notices.append(notice("上次结果未知，重试可能消耗一张卡。", .warning))
            } else if let cards = usage.resetCards,
                      cards.contains(where: { $0.usable && $0.expires > Date() }) {
                resetSection?.useTitle = resetUseInFlight ? "使用中…" : "使用重置卡"
                resetSection?.useEnabled = !resetUseInFlight && !resetCardsStale
                    && usage.resetCardsError == nil && (visualPreview || accountIdentity?.hasPrefix("account:") == true)
            }
            if resetCardsStale {
                resetSection?.notices.append(notice(
                    "⚠️ 重置卡数据已过期 · 最后成功 \(resetCardsLastOK.map { Fmt.dayTime($0) } ?? "--")", .warning))
            }
            if let error = usage.resetCardsError, usage.resetCards != nil {
                resetSection?.notices.append(notice(
                    "重置卡刷新失败：\(error) · 最后成功 \(resetCardsLastOK.map { Fmt.dayTime($0) } ?? "--")", .error))
            }
        }

        var tiboSection: UsagePanelModel.TiboSection?
        if let events = usage.tiboEvents {
            let rows = TiboDisplay.rows(events, now: Date()).map { row -> UsagePanelModel.TiboRow in
                guard let url = Fmt.webURL(row.link) else {
                    return UsagePanelModel.TiboRow(text: row.text, confirmed: row.confirmed, item: nil)
                }
                let item = NSMenuItem(title: row.text, action: #selector(openLink(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = url
                return UsagePanelModel.TiboRow(text: row.text, confirmed: row.confirmed, item: item)
            }
            tiboSection = UsagePanelModel.TiboSection(rows: rows, notices: [])
        } else if let error = usage.tiboError {
            let short = error.count > 60 ? String(error.prefix(60)) + "…" : error
            tiboSection = UsagePanelModel.TiboSection(rows: [],
                notices: [notice("Tibo 重置动态获取失败：\(short)", .error)])
        }
        if tiboSection != nil {
            if tiboStale {
                tiboSection?.notices.append(notice(
                    "⚠️ Tibo 动态已过期 · 最后成功 \(tiboLastOK.map { Fmt.dayTime($0) } ?? "--")", .warning))
            }
            if let error = usage.tiboError, usage.tiboEvents != nil {
                tiboSection?.notices.append(notice(
                    "Tibo 刷新失败：\(error) · 最后成功 \(tiboLastOK.map { Fmt.dayTime($0) } ?? "--")", .error))
            }
        }

        func bucket(_ summary: String, _ detail: String,
                    total: Double?, input: Double?, output: Double?,
                    models: [String: ModelTokenUsage]? = nil) -> UsagePanelModel.TokenBucket {
            let modelRows = TokenModelList.visible(models ?? [:]).map {
                UsagePanelModel.TokenModel(name: $0.name, total: Fmt.tokensAbbr($0.stats.total),
                    input: Fmt.tokensAbbr($0.stats.input), output: Fmt.tokensAbbr($0.stats.output))
            }
            return UsagePanelModel.TokenBucket(summaryLabel: summary, detailLabel: detail,
                total: Fmt.tokensAbbr(total), input: Fmt.tokensAbbr(input),
                output: Fmt.tokensAbbr(output), models: modelRows, hasData: total != nil)
        }
        func merged(_ label: String, _ local: TokenScanner.Stats?, _ external: ExternalTokenScanner.Stats?) -> UsagePanelModel.TokenBucket {
            guard let totals = LocalUsageMerge.combine(local, external) else { return bucket(label, label, total: nil, input: nil, output: nil) }
            return bucket(label, label, total: totals.total, input: totals.input, output: totals.output, models: totals.models)
        }
        let codexBuckets = [merged("今天", usage.tokensToday, usage.extToday),
            merged("近 7 天", usage.tokens7d, usage.ext7d), merged("近 30 天", usage.tokens30d, usage.ext30d)]
        var codexNotices: [UsagePanelModel.Notice] = []
        if usage.tokensToday == nil && usage.tokens7d == nil && usage.tokens30d == nil {
            codexNotices.append(notice("暂无数据"))
        }
        if tokensStale {
            codexNotices.append(notice(
                "⚠ Codex用量已过期（最后成功 \(tokensLastOK.map { Fmt.dayTime($0) } ?? "--")）", .warning))
        }
        if let error = usage.tokensError {
            codexNotices.append(notice("Codex用量统计失败：\(error)", .error))
        }
        if let error = usage.extError { codexNotices.append(notice("部分数据 · 外部统计失败：\(error)", .warning)) }
        else if usage.tokensToday == nil || usage.extToday == nil || usage.sourceStatus.values.contains(.failed)
                    || usage.sourceStatus.contains(where: { name, status in
                        status == .absent && (usage.externalTools[name]?.contains(where: { $0.total > 0 }) ?? false)
                    }) {
            codexNotices.append(notice("部分数据 · 有来源尚未读取或读取失败", .warning))
        }
        let codexSection = UsagePanelModel.TokenSection(title: "用量情况", accent: .codex,
            buckets: codexBuckets, notices: codexNotices)

        var globalNotices: [UsagePanelModel.Notice] = []
        if let error = usage.quotaError {
            globalNotices.append(notice("额度错误：\(error)", .error))
        }

        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(onRefresh), keyEquivalent: "r")
        refreshItem.target = self
        let loginItem = NSMenuItem(title: "开机自启", action: #selector(onToggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = visualPreview ? .on : (isLoginItemEnabled() ? .on : .off)
        let quitItem = NSMenuItem(title: "退出", action: #selector(onQuit), keyEquivalent: "q")
        quitItem.target = self

        let displayVersion = BuildInfo.version
        let model = UsagePanelModel(
            updateItem: updateItem,
            title: "Codex 用量", plan: (!visualPreview && CodexAuth.usesAPIKey()) ? "API Key" : (usage.planType ?? "Unknown"),
            email: usage.email,
            quotas: quotas,
            resetCards: resetSection,
            tibo: tiboSection,
            codexTokens: codexSection,
            official: usage.official, officialError: usage.officialError,
            quotaHistory: quotaHistorySnapshot,
            quotaHistoryAvailable: (visualPreview && !CommandLine.arguments.contains("--visual-preview-quota-history-unstable")) || QuotaCycleCoordinator.accountKey(accountIdentity) != nil,
            officialTodayFill: LocalUsageMerge.combine(usage.tokensToday, usage.extToday)?.total,
            tools: (0..<3).map { period in
                let codex = [usage.tokensToday, usage.tokens7d, usage.tokens30d][period]
                var rows: [(name: String, total: Double?, input: Double?, output: Double?, status: UsageSourceStatus)] = []
                if let value = codex { rows.append(("Codex", value.total, value.input, value.output, usage.tokensError == nil ? .available : .failed)) }
                else if usage.tokensError != nil { rows.append(("Codex", nil, nil, nil, .failed)) }
                for name in ["Proma", "Claude Code", "Hermes"] {
                    if let values = usage.externalTools[name], values.count == 3 {
                        let value = values[period]
                        rows.append((name, value.total, value.input, value.output, usage.sourceStatus[name] ?? .pending))
                    } else if usage.sourceStatus[name] == .failed { rows.append((name, nil, nil, nil, .failed)) }
                }
                let order = ["Codex": 0, "Proma": 1, "Claude Code": 2, "Hermes": 3]
                return rows.sorted {
                    let left = $0.total ?? -1, right = $1.total ?? -1
                    return left == right ? (order[$0.name] ?? 99) < (order[$1.name] ?? 99) : left > right
                }
            },
            notices: globalNotices,
            lastAttempt: "最近尝试刷新 \(Fmt.time(lastAttemptAt))",
            version: "版本 \(displayVersion)",
            refreshItem: refreshItem,
            loginItem: loginItem,
            quitItem: quitItem)
        panelController.update(model: model)
    }

    private func beginUseReset() {
        guard !visualPreview, !resetUseInFlight else { return }
        synchronizeAccount()
        guard let auth = CodexAuth.load(), let identity = CodexAuth.identity(auth),
              identity == accountIdentity, identity.hasPrefix("account:") else {
            panelController.setUpdateMessage("无法确认当前账户，请重新登录后再试", dismissAfter: 5); return
        }
        let defaults = UserDefaults.standard
        let pending = defaults.dictionary(forKey: pendingResetKey)
        let cardID: String
        let key: String
        let detail: String
        if let pending = pending {
            guard pending["identity"] as? String == identity,
                  let oldID = pending["cardID"] as? String, !oldID.isEmpty,
                  let oldKey = pending["key"] as? String, !oldKey.isEmpty else {
                panelController.setUpdateMessage("另一账户有待确认的用卡请求，请切回原账户核对", dismissAfter: 7); return
            }
            cardID = oldID; key = oldKey
            detail = "上次使用结果未知。将使用原请求重试；如果上次未成功，此次可能消耗一张卡。"
        } else {
            guard !resetCardsStale, usage.resetCardsError == nil,
                  let cards = usage.resetCards else { return }
            let eligible = cards.filter { $0.usable && $0.expires > Date() }
            guard let card = eligible.min(by: { $0.expires < $1.expires }), let id = card.id else { return }
            cardID = id; key = UUID().uuidString
            detail = "剩余 \(eligible.count) 张，优先使用 \(Fmt.expires(card.expires)) 到期的卡。\n使用后立即重置对应额度，操作不可撤销。"
        }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = pending == nil ? "使用一张重置卡？" : "核对上次用卡结果？"
        alert.informativeText = detail
        alert.alertStyle = .warning
        alert.addButton(withTitle: pending == nil ? "使用" : "核对")
        alert.addButton(withTitle: "取消")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        // Confirmation may have been open while the user switched accounts.
        guard CodexAuth.identity(CodexAuth.load()) == identity else {
            synchronizeAccount(); updateUI(); return
        }
        let requestedAt: Date? = pending == nil ? Date() : pending?["createdAt"] as? Date
        let baselineID = pending == nil ? quotaHistorySnapshot.state.current?.id :
            (pending?["baselineCycleID"] as? String).flatMap(UUID.init(uuidString:))
        if pending == nil {
            var values: [String: Any] = ["identity": identity, "cardID": cardID, "key": key, "createdAt": requestedAt!]
            if let baselineID = baselineID { values["baselineCycleID"] = baselineID.uuidString }
            defaults.set(values, forKey: pendingResetKey)
            guard defaults.synchronize() else {
                panelController.setUpdateMessage("无法保存请求状态，未使用重置卡", dismissAfter: 7); return
            }
        }
        let operationHash = QuotaCycleCoordinator.operationHash(key)
        let operationGeneration = accountGeneration
        if pending == nil {
            quotaHistoryCoordinator?.recordRedemption(QuotaRedemptionEvidence(operationHash: operationHash,
                originalRequestedAt: requestedAt, responseAt: requestedAt!, status: .requested,
                baselineCycleID: baselineID), identity: identity, generation: operationGeneration)
        }
        resetUseInFlight = true
        rebuildMenu()
        Fetcher.useResetCard(auth: auth, cardID: cardID, key: key) { [weak self] result in
            DispatchQueue.main.async {
                guard let self = self else { return }
                self.resetUseInFlight = false
                let status: QuotaRedemptionStatus
                switch result {
                case .success: status = .reset
                case .alreadyRedeemed: status = .alreadyRedeemed
                case .nothingToReset: status = .nothingToReset
                case .noCredit: status = .noCredit
                case .unknown: status = .unknown
                }
                self.quotaHistoryCoordinator?.recordRedemption(QuotaRedemptionEvidence(operationHash: operationHash,
                    originalRequestedAt: requestedAt, responseAt: Date(), status: status,
                    baselineCycleID: baselineID), identity: identity, generation: operationGeneration)
                if result != .unknown { defaults.removeObject(forKey: self.pendingResetKey); defaults.synchronize() }
                let message: String
                switch result {
                case .success, .alreadyRedeemed: message = "重置卡已使用，正在刷新额度"
                case .nothingToReset: message = "当前没有可重置的额度窗口"
                case .noCredit: message = "该重置卡已不可用，请核对卡数"
                case .unknown: message = "使用结果未知，请核对上次使用；不要重复发起新请求"
                }
                self.synchronizeAccount()
                if self.accountIdentity == identity {
                    self.accountGeneration += 1 // Discard card/quota reads started before redemption finished.
                    self.quotaHistoryCoordinator?.activate(accountIdentity: identity, generation: self.accountGeneration)
                    self.usage.resetCards = nil
                    self.resetCardsLastOK = nil
                    self.panelController.setUpdateMessage(message, dismissAfter: result == .unknown ? 15 : 6)
                }
                self.updateUI()
                self.refresh(tokens: true, manual: true)
                if result.acknowledgesRedemption {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                        self?.refresh(tokens: true, manual: true)
                    }
                }
            }
        }
    }

    @objc private func onRefresh() { refresh(tokens: true, manual: true) }

    // 更新检查完成后无条件重建菜单：横幅出现/消失都靠它自愈（刷新周期 ≤10s 也会兜底重建）
    private func checkForUpdate() {
        guard !visualPreview else { return }
        UpdateChecker.shared.check { [weak self] _ in self?.updateUI() }
    }

    private func manualUpdateCheck() {
        guard !visualPreview else {
            panelController.setUpdateMessage("预览模式：未联网检查更新", dismissAfter: 3)
            return
        }
        panelController.setUpdateMessage("正在检查更新…")
        UpdateChecker.shared.check(force: true) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .current: self.panelController.setUpdateMessage("当前已是最新版本", dismissAfter: 3)
            case .available: self.panelController.setUpdateMessage("发现新版本，请点击上方更新提示", dismissAfter: 3)
            case .failed: self.panelController.setUpdateMessage("检查失败，请稍后重试", dismissAfter: 3)
            case .unknownVersion: self.panelController.setUpdateMessage("当前版本未知，无法比较", dismissAfter: 3)
            }
            self.rebuildMenu()
        }
    }

    @objc private func openLink(_ sender: NSMenuItem) {
        guard !visualPreview else { return }
        if let url = sender.representedObject as? URL,
           let scheme = url.scheme?.lowercased(), scheme == "http" || scheme == "https" {
            NSWorkspace.shared.open(url)
        }
    }

    /// App Translocation：从下载目录直接运行的应用被挂载到只读临时位置
    private var isTranslocated: Bool {
        Bundle.main.bundleURL.standardizedFileURL.path.contains("/AppTranslocation/")
    }

    @objc private func onUpdateApp() {
        if visualPreview {
            panelController.showUpdateConfirmation(tag: "v9.9.9", notes: "## 新增\n- 支持切换面板背景样式\n\n## 优化\n- 可在安装前查看更新内容")
            return
        }
        guard !UpdateProgressController.shared.isActive,
              let tag = UpdateChecker.shared.availableTag else { return }
        panelController.showUpdateConfirmation(tag: tag, notes: UpdateChecker.shared.releaseNotes)
    }

    private func startConfirmedUpdate(tag: String, notes: String) {
        if visualPreview {
            panelController.setUpdateMessage("预览模式：不会下载安装", dismissAfter: 4)
            return
        }
        guard !UpdateProgressController.shared.isActive,
              UpdateChecker.shared.availableTag == tag, UpdateChecker.shared.releaseNotes == notes else {
            panelController.setUpdateMessage("版本信息已变更，请重新查看更新", dismissAfter: 5)
            return
        }
        // 原地更新必然失败：发起更新前拦截并给出安装指引，而不是让脚本在暂存阶段报错。
        if isTranslocated {
            let alert = NSAlert()
            alert.messageText = "无法原地更新"
            alert.informativeText = "CodexUsage 正在从临时位置运行（App Translocation），无法原地替换。\n请退出应用，把 CodexUsage.app 拖入「应用程序」文件夹后从那里打开。"
            alert.addButton(withTitle: "好")
            alert.runModal()
            return
        }
        guard let script = Bundle.main.path(forResource: "update", ofType: "sh") else {
            NSWorkspace.shared.open(UpdateCheck.releasesPage); return
        }
        UpdateProgressController.shared.start(script: script, targetTag: tag, appPath: Bundle.main.bundleURL.standardizedFileURL.path)
    }

    // MARK: 开机自启（LaunchAgent，与 GlmUsage/KimiUsage 同款）

    private var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    private func isLoginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func onToggleLogin() {
        guard !visualPreview else { return }
        if isLoginItemEnabled() {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        } else {
            // Translocation 下可执行文件位于只读临时挂载：写进 plist 重启后指向失效路径，
            // 与更新同款拦截，提示先安装到「应用程序」再开启
            if isTranslocated {
                let alert = NSAlert()
                alert.messageText = "无法开启开机自启"
                alert.informativeText = "CodexUsage 正在从临时位置运行（App Translocation）。\n请退出应用，把 CodexUsage.app 拖入「应用程序」文件夹后从那里打开，再开启自启。"
                alert.addButton(withTitle: "好")
                alert.runModal()
                updateUI()
                return
            }
            let exec = Bundle.main.executablePath ?? ""
            // KeepAlive 仅在非正常退出（崩溃/被 kill）时重启：菜单「退出」走 exit 0，launchd 不再复活进程
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array><string>\(exec)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key>
                <dict><key>SuccessfulExit</key><false/></dict>
            </dict>
            </plist>
            """
            do {
                try plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
            } catch {
                NSLog("[CodexUsage] Failed to write LaunchAgent plist at %@: %@", launchAgentPath, error.localizedDescription)
                let alert = NSAlert()
                alert.messageText = "开启开机自启失败"
                alert.informativeText = "无法写入 LaunchAgent 配置文件，请检查「~/Library/LaunchAgents」目录权限。\n\n\(error.localizedDescription)"
                alert.addButton(withTitle: "好")
                alert.runModal()
            }
        }
        updateUI()
    }

    @objc func onQuit() { NSApp.terminate(nil) }
}

// MARK: - 入口（支持 --once 命令行自检）

final class ProfileFixtureProtocol: URLProtocol {
    static var status = 200
    static var body = Data()
    static var delay: TimeInterval = 0
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let status = Self.status, body = Self.body, delay = Self.delay
        if delay > 0 { Thread.sleep(forTimeInterval: delay) }
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: nil)!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: body)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

enum CodexOfflineRegression {
    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    private static func expect(_ value: @autoclosure () -> Bool, _ message: String) throws {
        if !value() { throw Failure(description: message) }
    }

    static func run() -> Int32 {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("CodexUsage-self-test-\(UUID().uuidString)", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            defer { try? FileManager.default.removeItem(at: root) }
            // Official reader uses mock responses and a temporary auth directory only.
            let fakeHome = root.appendingPathComponent("fake-home")
            try FileManager.default.createDirectory(at: fakeHome, withIntermediateDirectories: true)
            let payload = try JSONSerialization.data(withJSONObject: ["email": "fixture@example.invalid", "sub": "fixture-subject"])
            let encoded = payload.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
            let authObject: [String: Any] = ["tokens": ["access_token": "fake-access", "id_token": "x.\(encoded).x", "account_id": "fixture-workspace"]]
            let authData = try JSONSerialization.data(withJSONObject: authObject)
            try authData.write(to: fakeHome.appendingPathComponent("auth.json"))
            let expectedAuth = CodexAuth.load(at: fakeHome.appendingPathComponent("auth.json").path)
            try expect(expectedAuth?.tokens.email == "fixture@example.invalid", "root email claim not parsed")
            guard let request = OfficialUsageReader.request(expected: expectedAuth) else { throw Failure(description: "valid auth request rejected") }
            try expect(request.url == OfficialUsageReader.endpoint && request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "fixture-workspace", "workspace header missing")
            let nativeFixture: [String: Any] = ["stats": ["lifetime_tokens": 42, "daily_usage_buckets": [["start_date": "2026-11-05", "tokens": 42]]]]
            let native = OfficialUsageReader.parse(nativeFixture)
            try expect(native?.lifetime == 42 && native?.days["2026-11-05"] == 42, "native profile parsing failed")
            let mockConfig = URLSessionConfiguration.ephemeral
            mockConfig.protocolClasses = [ProfileFixtureProtocol.self]
            ProfileFixtureProtocol.body = try JSONSerialization.data(withJSONObject: nativeFixture)
            ProfileFixtureProtocol.status = 200; ProfileFixtureProtocol.delay = 0
            if case .success(let snapshot) = OfficialUsageReader.read(expected: expectedAuth, authPath: fakeHome.appendingPathComponent("auth.json").path, configuration: mockConfig) {
                try expect(snapshot.lifetime == 42, "mock profile result wrong")
            } else { throw Failure(description: "mock profile failed") }
            ProfileFixtureProtocol.status = 401
            if case .failure(.unauthorized) = OfficialUsageReader.read(expected: expectedAuth, authPath: fakeHome.appendingPathComponent("auth.json").path, configuration: mockConfig) {} else { throw Failure(description: "401 was not surfaced") }
            ProfileFixtureProtocol.status = 200; ProfileFixtureProtocol.body = Data(repeating: 120, count: 2 * 1024 * 1024 + 1)
            if case .failure = OfficialUsageReader.read(expected: expectedAuth, authPath: fakeHome.appendingPathComponent("auth.json").path, configuration: mockConfig) {} else { throw Failure(description: "oversize response accepted") }
            ProfileFixtureProtocol.body = Data(); ProfileFixtureProtocol.delay = 0.3
            if case .failure(.timeout) = OfficialUsageReader.read(expected: expectedAuth, timeout: 0.05, authPath: fakeHome.appendingPathComponent("auth.json").path, configuration: mockConfig) {} else { throw Failure(description: "profile timeout not handled") }
            ProfileFixtureProtocol.delay = 0
            let changedWorkspace: [String: Any] = ["tokens": ["access_token": "fake-access", "id_token": "x.\(encoded).x", "account_id": "other-workspace"]]
            try JSONSerialization.data(withJSONObject: changedWorkspace).write(to: fakeHome.appendingPathComponent("auth.json"))
            if case .failure(.identityMismatch) = OfficialUsageReader.read(expected: expectedAuth, authPath: fakeHome.appendingPathComponent("auth.json").path) {} else { throw Failure(description: "workspace switch accepted") }
            try authData.write(to: fakeHome.appendingPathComponent("auth.json"))
            let wrongHome = root.appendingPathComponent("wrong-home").path
            if case .failure(.identityMismatch) = OfficialUsageReader.read(expected: expectedAuth, authPath: wrongHome + "/auth.json") {} else { throw Failure(description: "different credential home accepted") }
            try expect(OfficialUsageReader.parse(["summary": [:], "dailyUsageBuckets": [["startDate":"2026-02-30", "tokens":1]]]) == nil, "invalid official date accepted")
            try expect(UsageAttribution.owner(path: "/data/a/file.jsonl", roots: ["/data", "/data/a", "/data/a"]) == 1, "duplicate or overlapping roots attributed twice")

            try expect(UsageComparison.compare(0, 0) == .unchanged && UsageComparison.compare(10, 0) == .fromZero(10), "zero-base comparison wrong")
            let compareNow = Date()
            let compareFmt = DateFormatter(); compareFmt.locale = Locale(identifier: "en_US_POSIX")
            compareFmt.timeZone = .current; compareFmt.dateFormat = "yyyy-MM-dd"
            func compareKey(_ offset: Int) -> String {
                compareFmt.string(from: Calendar.current.date(byAdding: .day, value: -offset, to: compareNow)!)
            }
            // 今日 118、昨日 100、前 5 日 88、更早 7 日 100：日环比 +18%、周环比 −6%
            let complete = OfficialUsageSnapshot(lifetime: nil, days: Dictionary(uniqueKeysWithValues: (0..<14).map { i in
                (compareKey(i), Double(i == 0 ? 118 : (i == 1 ? 100 : (i < 7 ? 88 : 100))))
            }), fetchedAt: compareNow)
            let comparisons = UsageComparison.evaluate(snapshot: complete, now: compareNow)
            try expect(comparisons.0.value.text == "+18%" && comparisons.1.value.text == "−6%", "complete comparison mismatch")
            try expect(comparisons.0.description.contains("\(compareKey(0)) 对比 \(compareKey(1))（今日未结束）")
                       && comparisons.0.description.contains("官方账号用量"), "daily range or source incorrect")
            try expect(comparisons.1.description.contains("\(compareKey(6)) 至 \(compareKey(0))")
                       && comparisons.1.description.contains("\(compareKey(13)) 至 \(compareKey(7))")
                       && comparisons.1.description.contains("两组7日总量比较")
                       && comparisons.1.description.contains("（最近7日总量−前7日总量）÷前7日总量×100%"), "weekly range or formula incorrect")
            // 官方缺今日桶：以本机扫描补今日；界面文案不标注补足来源；官方已含今日时不覆盖
            let openEnd = OfficialUsageSnapshot(lifetime: nil, days: complete.days.filter { $0.key != compareKey(0) }, fetchedAt: compareNow)
            let filled = UsageComparison.evaluate(snapshot: openEnd, now: compareNow, todayFill: 57)
            try expect(filled.0.value.text == "−43%" && !filled.0.description.contains("本机扫描"), "scanned-today fill missing")
            try expect(filled.1.value != .insufficient && !filled.1.description.contains("本机扫描"), "weekly fill flagged source")
            try expect(UsageComparison.evaluate(snapshot: complete, now: compareNow, todayFill: 999).0.value.text == "+18%", "fill overrode official today")
            let unfilled = UsageComparison.evaluate(snapshot: openEnd, now: compareNow)
            try expect(unfilled.0.value == .insufficient && unfilled.0.description.contains("缺少日期：\(compareKey(0))"), "missing today without fill not flagged")
            var yearComponents = DateComponents(); yearComponents.year = 2026; yearComponents.month = 1; yearComponents.day = 2; yearComponents.hour = 12
            let yearNow = Calendar.current.date(from: yearComponents)!
            let yearBoundary = OfficialUsageSnapshot(lifetime: nil, days: ["2026-01-02": 1], fetchedAt: yearNow)
            let boundary = UsageComparison.evaluate(snapshot: yearBoundary, now: yearNow)
            try expect(boundary.0.description.contains("2026-01-02 对比 2026-01-01")
                       && boundary.1.description.contains("2025-12-27 至 2026-01-02")
                       && boundary.1.description.contains("2025-12-20 至 2025-12-26"), "cross-year dates incorrect")
            let noDate = UsageComparison.evaluate(snapshot: nil, now: compareNow)
            try expect(noDate.0.value == .insufficient && noDate.0.description.contains("尚未取得"), "missing source not explained")
            let stale = UsageComparison.evaluate(snapshot: complete, now: compareNow.addingTimeInterval(1801))
            try expect(stale.1.value == .insufficient && stale.1.description.contains("已过期"), "stale comparison allowed")
            var missingDays = complete
            missingDays.days.removeValue(forKey: compareKey(11))
            let unknownSparse = UsageComparison.evaluate(snapshot: missingDays, now: compareNow)
            try expect(unknownSparse.0.value == comparisons.0.value && unknownSparse.1.value == .insufficient
                       && unknownSparse.1.description.contains(compareKey(11)), "unknown sparse date or independent windows wrong")
            missingDays.sparsePolicy = .officialActivity
            let officialSparse = UsageComparison.evaluate(snapshot: missingDays, now: compareNow)
            try expect(officialSparse.0.value == comparisons.0.value && officialSparse.1.value != .insufficient
                       && officialSparse.1.description.contains("按 0"), "official sparse date not counted as zero")
            try expect(missingDays.day(compareKey(11)) == .inferredZero && missingDays.day(compareKey(14)) == .missing
                       && missingDays.day(compareKey(-1)) == .missing, "sparse date bounds wrong")
            var outside = missingDays; outside.days.removeValue(forKey: compareKey(13))
            let outsideResult = UsageComparison.evaluate(snapshot: outside, now: compareNow)
            try expect(outsideResult.0.value == comparisons.0.value && outsideResult.1.value == .insufficient
                       && outsideResult.1.description.contains(compareKey(13)), "out-of-range date was invented")
            var explicitZero = complete; explicitZero.days[compareKey(1)] = 0
            try expect(UsageComparison.evaluate(snapshot: explicitZero, now: compareNow).0.value == .fromZero(118), "zero-base comparison incorrect")
            let emptyOfficial = OfficialUsageReader.parse(["stats": ["lifetime_tokens": 42, "daily_usage_buckets": []]])
            try expect(emptyOfficial?.day("2026-11-05") == .missing, "empty official days were fabricated")
            try expect(OfficialUsageReader.parse(["metadata": ["stats_error": "failure"], "stats": ["daily_usage_buckets": [["start_date": "2026-11-05", "tokens": 1]]]]) == nil,
                       "failed stats exposed sparse policy")
            let nativeSparse = OfficialUsageReader.parse(["stats": ["daily_usage_buckets": [["start_date": "2026-11-03", "tokens": 0], ["start_date": "2026-11-05", "tokens": 5]]]])
            try expect(nativeSparse?.day("2026-11-03") == .reported(0) && nativeSparse?.day("2026-11-04") == .inferredZero && nativeSparse?.day("2026-11-02") == .missing,
                       "native sparse, explicit zero, or range semantics incorrect")

            let now = Date(timeIntervalSince1970: 1_800_000_000)
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = .current
            let weekdays = ["周日", "周一", "周二", "周三", "周四", "周五", "周六"]
            for (offset, weekday) in weekdays.enumerated() {
                let date = calendar.date(from: DateComponents(year: 2026, month: 11, day: 8 + offset, hour: 6, minute: 15))!
                let expected = String(format: "11-%02d %@ 06:15", 8 + offset, weekday)
                try expect(Fmt.quotaReset(date) == expected, "quota reset weekday or local time is incorrect")
                try expect(Fmt.dayTime(date) == String(format: "11-%02d 06:15", 8 + offset),
                           "machine-readable date format changed")
            }
            try expect(Fmt.tokensAbbr(20_000) == "20K" && Fmt.tokensAbbr(300_000) == "300K"
                       && Fmt.tokensAbbr(1_500_000) == "1.5M" && Fmt.tokensAbbr(nil) == "--",
                       "token abbreviation scale or missing value is incorrect")
            let visibleModels = TokenModelList.visible([
                "gpt-zero": ModelTokenUsage(),
                "gpt-a": ModelTokenUsage(input: 80, output: 20, total: 100),
                "gpt-b": ModelTokenUsage(input: 150, output: 50, total: 200)
            ])
            try expect(visibleModels.map { $0.name } == ["gpt-b", "gpt-a"],
                       "model details are not sorted by usage with zero rows filtered")

            try expect(CodexNumber.finite(Double.nan) == nil, "NaN accepted as a quota value")
            try expect(CodexNumber.finite(Double.infinity) == nil, "infinity accepted as a quota value")
            try expect(CodexNumber.finite(true) == nil, "boolean accepted as a quota value")
            try expect(CodexNumber.nonnegativeInteger(Double(Int.max)) == nil
                       && CodexNumber.nonnegativeInteger(1e100) == nil
                       && CodexNumber.nonnegativeInteger(1.5) == nil,
                       "out-of-range or fractional card count was accepted")
            try expect(CodexNumber.nonnegativeInteger(0) == 0,
                       "valid zero card count was rejected")

            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let card = PanelCardView(); let strip = PanelComparisonStack()
                card.appearance = NSAppearance(named: appearanceName); strip.appearance = NSAppearance(named: appearanceName)
                card.updateLayer(); strip.updateLayer()
                try expect(card.layer?.backgroundColor != nil && strip.layer?.backgroundColor != nil
                           && card.layer?.backgroundColor != strip.layer?.backgroundColor,
                           "comparison strip lacks subtle contrast inside card")
            }

            let tiers: [(Int?, RemainingColorTier)] = [
                (nil, .normal), (0, .red), (19, .red), (20, .orange), (39, .orange),
                (40, .normal), (79, .normal), (80, .green), (100, .green)
            ]
            for (remaining, expected) in tiers {
                try expect(RemainingColorTier(remaining: remaining) == expected,
                           "wrong menu bar color tier for \(remaining.map(String.init) ?? "nil")")
            }
            let previewLine = StackImage.Line(label: "5H", value: "90%", remaining: 90)
            for name in [NSAppearance.Name.aqua, .darkAqua] {
                let appearance = NSAppearance(named: name)!
                // 菜单栏图片已全面动态取色；此处分外观验证解析结果与渲染仍然成立
                let green = RemainingColorTier.green.color(for: appearance).usingColorSpace(.sRGB)
                try expect(green.map { $0.greenComponent > $0.redComponent
                                      && $0.greenComponent > $0.blueComponent } == true,
                           "green tier did not resolve to green for \(name.rawValue)")
                let image = StackImage.make(line1: previewLine, line2: previewLine, appearance: appearance)
                try expect(!image.isTemplate && image.cacheMode == .never
                           && image.size.width > 0 && image.tiffRepresentation != nil,
                           "menu bar uncached color image did not render for \(name.rawValue)")
            }

            // 外观重绘必须真正改变文字颜色：浅色外观画深字，深色外观画浅字。
            func neutralInkCount(_ image: NSImage, white: Bool) -> Int {
                guard let data = image.tiffRepresentation,
                      let bitmap = NSBitmapImageRep(data: data) else { return 0 }
                var count = 0
                for y in 0..<bitmap.pixelsHigh {
                    for x in 0..<bitmap.pixelsWide {
                        guard let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.sRGB),
                              color.alphaComponent > 0.8 else { continue }
                        let channels = [color.redComponent, color.greenComponent, color.blueComponent]
                        let brightness = (channels[0] + channels[1] + channels[2]) / 3
                        let grayscale = channels.allSatisfy { abs($0 - brightness) < 0.02 }
                        if grayscale && (white ? brightness > 0.8 : brightness < 0.2) { count += 1 }
                    }
                }
                return count
            }
            let neutralLine = StackImage.Line(label: "5H", value: "50%", remaining: 50)
            let lightImage = StackImage.make(line1: neutralLine, line2: neutralLine,
                                             appearance: NSAppearance(named: .aqua)!)
            let darkImage = StackImage.make(line1: neutralLine, line2: neutralLine,
                                            appearance: NSAppearance(named: .darkAqua)!)
            try expect(neutralInkCount(lightImage, white: false) > 0,
                       "light appearance override did not draw dark menu bar text")
            try expect(neutralInkCount(darkImage, white: true) > 0,
                       "dark appearance override did not draw light menu bar text")

            var previewCreatedStore = false
            let previewHistory = QuotaHistoryStartup.make(visualPreview: true) {
                previewCreatedStore = true
                return QuotaCycleCoordinator(root: root.appendingPathComponent("preview-must-not-exist"),
                    writer: { _, _ in throw Failure(description: "preview writer called") }, deliver: { _ in })
            }
            try expect(previewHistory == nil && !previewCreatedStore &&
                       !FileManager.default.fileExists(atPath: root.appendingPathComponent("preview-must-not-exist").path),
                       "preview created history storage")
            let previewState = QuotaCycleUIState()
            let fixtureSnapshot = QuotaCyclePreviewFixture.make(count: 13)
            previewState.browser.update(fixtureSnapshot.state.closed + [fixtureSnapshot.state.current!])
            let unsavedView = QuotaCycleHistoryView(snapshot: QuotaCycleSnapshot(state: fixtureSnapshot.state, isLoading: false, isSaved: false), available: true, state: previewState)
            try expect(unsavedView.previewText.contains("历史未保存") && unsavedView.previewText.contains("最后观测"), "history save failure was not exposed")
            let emptyState = QuotaCycleUIState()
            let loadingView = QuotaCycleHistoryView(snapshot: QuotaCycleSnapshot(state: QuotaCycleState(), isLoading: true, isSaved: true), available: true, state: emptyState)
            try expect(loadingView.previewText.contains("正在读取历史"), "history loading state missing")
            let unstableView = QuotaCycleHistoryView(snapshot: QuotaCycleSnapshot(state: QuotaCycleState(), isLoading: false, isSaved: true), available: false, state: emptyState)
            try expect(unstableView.previewText.contains("无法确认稳定账户"), "unstable account loading state incorrect")
            let waiting = fixtureSnapshot.state.current!
            let waitingDetail = QuotaCycleHistoryView.detail(waiting, pending: nil, now: waiting.expectedResetAt.addingTimeInterval(1))
            try expect(waitingDetail.0.contains("等待重置确认"), "expired reset was shown as active")
            let redeemedFixture = fixtureSnapshot.state.closed.first { $0.end == .redeemed }!
            let redeemedText = QuotaCycleHistoryView.detail(redeemedFixture, pending: nil, now: now)
            let endLabel = QuotaCycleHistoryView.date(redeemedFixture.boundaryUpper!, format: "MM/dd")
            try expect(redeemedText.0.contains(endLabel) && redeemedText.0.contains("主动用卡") && redeemedText.0.contains("–"),
                       "historical cycle did not show start and ending boundary")
            let currentText = QuotaCycleHistoryView.detail(waiting, pending: nil, now: waiting.firstObservedAt)
            try expect(currentText.0.contains("至今") && currentText.0.contains(QuotaCycleHistoryView.date(waiting.expectedResetAt, format: "MM/dd")),
                       "current cycle did not show start and expected end")
            let fullDetail = QuotaCycleHistoryView.fullDescription(redeemedFixture, pending: nil, now: now)
            let preciseFormat = "yyyy/MM/dd HH:mm"
            try expect(fullDetail.contains(QuotaCycleHistoryView.date(redeemedFixture.boundaryLower!, format: preciseFormat)) &&
                       fullDetail.contains(QuotaCycleHistoryView.date(redeemedFixture.boundaryUpper!, format: preciseFormat)),
                       "cycle tooltip and accessibility omitted boundary interval")
            try expect(QuotaCycleChart.isCurrent(waiting, snapshot: fixtureSnapshot) &&
                       !QuotaCycleChart.isCurrent(redeemedFixture, snapshot: fixtureSnapshot),
                       "current marker was tied to selection instead of current cycle")
            var wideBoundary = redeemedFixture
            wideBoundary.boundaryUpper = wideBoundary.boundaryLower!.addingTimeInterval(2 * 86400)
            let wideText = QuotaCycleHistoryView.detail(wideBoundary, pending: nil, now: now)
            try expect(wideText.0.contains(QuotaCycleHistoryView.date(wideBoundary.boundaryLower!, format: "MM/dd")) &&
                       wideText.0.contains(QuotaCycleHistoryView.date(wideBoundary.boundaryUpper!, format: "MM/dd")) &&
                       wideText.0.contains("间"), "multi-day boundary falsely collapsed to a point")
            let planChange = fixtureSnapshot.state.closed.first { $0.end == .unconfirmed }!
            let planDetail = QuotaCycleHistoryView.detail(planChange, pending: nil)
            try expect(planDetail.0.contains("套餐/额度变更") && !planDetail.1.contains("到期未用"), "plan change mislabeled as waste")
            var historyFixture = QuotaData()
            historyFixture.sevenDay = QuotaWindow(usedPercent: 35, reset: now.addingTimeInterval(1000))
            try expect(QuotaHistoryAdapter.observation(historyFixture, requestStartedAt: now, observedAt: now) != nil,
                       "valid fresh 7d not accepted by history adapter")
            historyFixture.error = "failed"
            try expect(QuotaHistoryAdapter.observation(historyFixture, requestStartedAt: now, observedAt: now) == nil,
                       "failed response entered history")
            historyFixture.error = nil
            historyFixture.sevenDay = nil
            try expect(QuotaHistoryAdapter.observation(historyFixture, requestStartedAt: now, observedAt: now) == nil,
                       "missing 7d must not use prior cached window")
            historyFixture.sevenDay = QuotaWindow(usedPercent: 35, reset: nil)
            try expect(QuotaHistoryAdapter.observation(historyFixture, requestStartedAt: now, observedAt: now) == nil,
                       "missing reset entered history")
            let missing = Fetcher.parseUsage([:], now: now, email: nil)
            try expect(missing.fiveHour == nil && missing.fiveHourError != nil, "missing 5H was not rejected")
            try expect(missing.sevenDay == nil && missing.sevenDayError != nil, "missing 7D was not rejected")
            try expect(missing.error != nil, "empty quota response was reported successful")

            let partial = Fetcher.parseUsage([
                "rate_limit": [
                    "primary_window": ["used_percent": "NaN"],
                    "secondary_window": ["used_percent": 35]
                ]
            ], now: now, email: nil)
            try expect(partial.fiveHour == nil && partial.fiveHourError != nil, "invalid 5H became zero")
            try expect(partial.sevenDay?.usedPercent == 35 && partial.sevenDayError == nil,
                       "valid 7D was discarded with invalid 5H")

            let reverse = Fetcher.parseUsage([
                "usage": ["limits": [
                    ["window": "5h", "used": 0, "limit": 100],
                    ["window": "7d", "used": Double.nan, "limit": 100]
                ]],
                "rate_limit_reset_credits": ["available_count": true]
            ], now: now, email: nil)
            try expect(reverse.fiveHour?.usedPercent == 0, "valid zero-use value was rejected")
            try expect(reverse.sevenDay == nil && reverse.sevenDayError != nil, "invalid 7D was treated as zero")
            try expect(reverse.resetCredits == nil, "boolean reset-card count was accepted")
            for badCount: Any in [Double(Int.max), 1e100, 1.5, true] {
                let parsed = Fetcher.parseUsage(["rate_limit_reset_credits": ["available_count": badCount]],
                                                now: now, email: nil)
                try expect(parsed.resetCredits == nil, "invalid available_count was converted unsafely")
            }
            let legacy = Fetcher.parseUsage(["rate_limit": [
                "primary_window": ["used_percent": 15, "limit_window_seconds": 18_000],
                "secondary_window": ["used_percent": 64, "limit_window_seconds": 604_800]
            ]], now: now, email: nil)
            try expect(legacy.fiveHour?.usedPercent == 15 && legacy.sevenDay?.usedPercent == 64,
                       "valid legacy windows did not parse")

            let badgeCases: [(String?, String, UInt32)] = [
                ("free", "Free", 0x949BA6), ("go", "Go", 0x16A6A1), ("plus", "Plus", 0x2887E8),
                ("pro_100", "Pro 100", 0x8B5CF6), ("pro 200", "Pro 200", 0xE2A23A),
                ("pro-500", "Pro 500", 0xE46B45), ("pro_5x", "Pro", 0x8B5CF6),
                ("pro_20x", "Pro", 0x8B5CF6), ("prolite", "Pro", 0x8B5CF6),
                ("business_standard", "Business Standard", 0x3976B9),
                ("business_premium", "Business Premium", 0x256F78),
                ("enterprise", "Enterprise", 0x38465F), ("edu", "Edu", 0x578E68),
                ("unrecognized", "Unknown", 0x9CA3AF), (nil, "Unknown", 0x9CA3AF)
            ]
            for (raw, title, rgb) in badgeCases {
                let badge = SubscriptionBadge.resolve(raw)
                try expect(badge.title == title && badge.rgb == rgb, "incorrect subscription badge for \(raw ?? "nil")")
            }
            try expect(SubscriptionBadge.resolve("pro", apiKey: true).title == "API Key", "API key confused with subscription")
            let authFixture = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: authFixture) }
            for (json, expected) in [("{\"auth_mode\":\"apikey\",\"OPENAI_API_KEY\":\"test\"}", true),
                                     ("{\"OPENAI_API_KEY\":\"test\"}", true),
                                     ("{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":\"test\"}", false),
                                     ("{\"OPENAI_API_KEY\":null}", false)] {
                try Data(json.utf8).write(to: authFixture)
                try expect(CodexAuth.usesAPIKey(at: authFixture.path) == expected, "API key authentication detection failed")
            }
            for appearanceName in [NSAppearance.Name.aqua, .darkAqua] {
                let badge = PlanBadgeLabel(wrappingLabelWithString: " Pro ")
                badge.wantsLayer = true; badge.planColor = SubscriptionBadge.resolve("pro").color
                badge.appearance = NSAppearance(named: appearanceName); badge.updateLayer()
                try expect(badge.layer?.backgroundColor != nil && badge.textColor != nil, "subscription badge colors missing")
            }

            // Synthetic compatibility fixtures; these are not captured Pro responses.
            for plan in ["pro", "prolite"] {
                let one = Fetcher.parseUsage(["plan_type": plan, "rate_limit": [
                    "primary_window": NSNull(),
                    "secondary_window": ["used_percent": 45, "limit_window_seconds": 604800]
                ]], now: now, email: nil)
                try expect(one.fiveHourNotApplicable && one.fiveHourError == nil && one.sevenDay != nil,
                           "recognized single-window plan not handled")
                let invalid = Fetcher.parseUsage(["plan_type": plan, "rate_limit": [
                    "primary_window": ["used_percent": "bad", "limit_window_seconds": 18000],
                    "secondary_window": ["used_percent": 45, "limit_window_seconds": 604800]
                ]], now: now, email: nil)
                try expect(!invalid.fiveHourNotApplicable && invalid.fiveHourError != nil,
                           "invalid 5H hidden by plan")
                let valid = Fetcher.parseUsage(["plan_type": plan, "rate_limit": [
                    "primary_window": ["used_percent": 10, "limit_window_seconds": 18000],
                    "secondary_window": ["used_percent": 45, "limit_window_seconds": 604800]
                ]], now: now, email: nil)
                try expect(!valid.fiveHourNotApplicable && valid.fiveHour != nil,
                           "valid 5H hidden by plan")
            }
            let unknownPlan = Fetcher.parseUsage(["plan_type": "unknown", "rate_limit": [
                "secondary_window": ["used_percent": 45, "limit_window_seconds": 604800]
            ]], now: now, email: nil)
            try expect(!unknownPlan.fiveHourNotApplicable && unknownPlan.fiveHourError == "暂未提供",
                       "unknown capability interpreted as not applicable")

            let previousWindow = QuotaWindow(usedPercent: 20, reset: nil)
            var notApplicable = QuotaData(); notApplicable.fiveHourNotApplicable = true
            let single = QuotaMerge.fiveHour(notApplicable, old: previousWindow, oldLastOK: now, wasNotApplicable: false, now: now)
            try expect(single.0 == nil && single.1 == nil && single.2, "single-window transition retained 5H data")
            var failure = QuotaData(); failure.error = "network"; failure.fiveHourError = "network"
            let retained = QuotaMerge.fiveHour(failure, old: single.0, oldLastOK: single.1, wasNotApplicable: single.2, now: now)
            try expect(retained.2 && retained.0 == nil, "request failure changed capability")
            var restored = QuotaData(); restored.fiveHour = previousWindow
            let dual = QuotaMerge.fiveHour(restored, old: retained.0, oldLastOK: retained.1, wasNotApplicable: retained.2, now: now)
            try expect(!dual.2 && dual.0 != nil && dual.1 == now, "5H did not recover after plan switch")

            let localFixture = TokenScanner.Stats(input: 100, output: 20, total: 120, files: 1,
                models: ["gpt-x": ModelTokenUsage(input: 100, output: 20, total: 120)])
            let extFixture = ExternalTokenScanner.Stats(input: 30, output: 10,
                models: ["gpt-x": ModelTokenUsage(input: 30, output: 10, total: 40)])
            let totalFixture = LocalUsageMerge.combine(localFixture, extFixture)
            try expect(totalFixture?.total == 160 && totalFixture?.models["gpt-x"]?.total == 160,
                       "same-model aggregation failed to close")
            try expect(LocalUsageMerge.combine(nil, nil) == nil, "missing sources treated as zero")

            let badDuration = Fetcher.parseUsage(["plan_type": "pro", "rate_limit": [
                "primary_window": ["used_percent": 10, "limit_window_seconds": 12345],
                "secondary_window": ["used_percent": 45, "limit_window_seconds": 604800]
            ]], now: now, email: nil)
            try expect(badDuration.fiveHour == nil && !badDuration.fiveHourNotApplicable && badDuration.fiveHourError != nil,
                       "unknown window duration was accepted or hidden")

            let old5 = QuotaWindow(usedPercent: 20, reset: nil)
            try expect(QuotaMerge.preferred(nil, old: old5)?.usedPercent == 20,
                       "failed window did not retain its previous value")
            let last = now.addingTimeInterval(-100)
            try expect(CodexFreshness.updated(last, succeeded: false, at: now) == last,
                       "failed refresh advanced last-success time")
            try expect(CodexFreshness.isStale(lastSuccess: last, hasData: true, now: now, after: 50),
                       "retained old data was not stale")

            let gate = RefreshGate()
            try expect(gate.begin(manual: false), "initial refresh gate did not open")
            try expect(!gate.begin(manual: false), "overlapping timer refresh started")
            try expect(!gate.begin(manual: true) && !gate.begin(manual: true), "manual overlap started immediately")
            try expect(gate.finish(), "manual requests did not coalesce to one follow-up")
            try expect(!gate.begin(manual: false), "gate did not remain active for queued follow-up")
            try expect(!gate.finish() && gate.begin(manual: false), "gate was not released after follow-up")
            try expect(!CodexRefreshSchedule.slowItemsDue(cycle: 4, manual: false)
                       && CodexRefreshSchedule.slowItemsDue(cycle: 5, manual: false)
                       && CodexRefreshSchedule.slowItemsDue(cycle: 1, manual: true),
                       "slow-item cycle or manual refresh schedule is incorrect")

            let cardPayload: [String: Any] = ["credits": [
                ["id": "fixture-card", "reset_type": "codex_rate_limits", "status": "available", "expires_at": now.addingTimeInterval(3_600).timeIntervalSince1970,
                 "title": "Full reset (Weekly + 5 hr)"],
                ["status": "available", "expires_at": now.addingTimeInterval(-1).timeIntervalSince1970,
                 "title": "expired by time"],
                ["status": "used", "expires_at": now.addingTimeInterval(86_400).timeIntervalSince1970,
                 "title": "already used"]
            ]]
            let cardsResult = Fetcher.parseResetCards(cardPayload, now: now)
            guard let cards = cardsResult.cards else {
                throw Failure(description: "valid card list failed: \(cardsResult.error ?? "unknown")")
            }
            try expect(cards.count == 1 && cards[0].name == "全额重置卡", "expired/used reset cards counted as available")
            try expect(cards[0].usable && cards[0].id == "fixture-card", "eligible card lost its ID")
            let fixtureAuth = CodexAuth.Snapshot(tokens: CodexAuth.Tokens(accessToken: "fixture-token", refreshToken: nil, idToken: nil, email: nil, accountID: "fixture-account"))
            guard let request = Fetcher.resetUseRequest(auth: fixtureAuth, cardID: "fixture-card", key: "fixture-key"),
                  let body = request.httpBody,
                  let payload = try JSONSerialization.jsonObject(with: body) as? [String: String] else {
                throw Failure(description: "reset request construction failed")
            }
            try expect(request.httpMethod == "POST" && request.url?.absoluteString.hasSuffix("/wham/rate-limit-reset-credits/consume") == true
                       && payload["credit_id"] == "fixture-card" && payload["redeem_request_id"] == "fixture-key"
                       && request.value(forHTTPHeaderField: "ChatGPT-Account-ID") == "fixture-account", "reset request contract changed")
            func resetResponse(_ code: String) -> Data { Data("{\"code\":\"\(code)\"}".utf8) }
            try expect(Fetcher.parseResetUseResponse(status: 200, data: resetResponse("reset")) == .success
                       && Fetcher.parseResetUseResponse(status: 200, data: resetResponse("already_redeemed")) == .alreadyRedeemed
                       && Fetcher.parseResetUseResponse(status: 200, data: resetResponse("nothing_to_reset")) == .nothingToReset
                       && Fetcher.parseResetUseResponse(status: 200, data: resetResponse("no_credit")) == .noCredit
                       && Fetcher.parseResetUseResponse(status: 500, data: resetResponse("reset")) == .unknown
                       && Fetcher.parseResetUseResponse(status: 200, data: resetResponse("future")) == .unknown
                       && Fetcher.parseResetUseResponse(status: nil, data: nil) == .unknown, "reset response safety classification changed")
            let unknownCard = Fetcher.parseResetCards(["credits": [["id": "future", "status": "available", "reset_type": "other", "expires_at": now.addingTimeInterval(3600).timeIntervalSince1970]]], now: now)
            try expect(unknownCard.cards?.first?.usable == false, "unknown card type became usable")
            try expect(CodexFreshness.availableCards(cards + [
                ResetCard(expires: now.addingTimeInterval(-1), name: "stale cache")
            ], now: now).count == 1, "expired cached card counted as usable")
            let missingCards = Fetcher.parseResetCards(["error": "upstream"], now: now)
            try expect(missingCards.cards == nil && missingCards.error != nil,
                       "missing card container was accepted as an empty success")
            let wrongCards = Fetcher.parseResetCards(["credits": [:]], now: now)
            try expect(wrongCards.cards == nil && wrongCards.error != nil,
                       "wrong-type card container was accepted as an empty success")
            let malformedCard = Fetcher.parseResetCards(["credits": [["expires_at": true]]], now: now)
            try expect(malformedCard.cards == nil && malformedCard.error != nil,
                       "invalid card expiration was treated as an expired card")
            let emptyCards = Fetcher.parseResetCards(["credits": []], now: now)
            try expect(emptyCards.cards?.isEmpty == true && emptyCards.error == nil,
                       "valid empty card list was rejected")

            let priorCardsOK = now.addingTimeInterval(-1_000)
            let cardsR = CodexFreshness.apply(fresh: missingCards.cards, failure: missingCards.error,
                old: cards, oldLastOK: priorCardsOK, oldError: nil, now: now)
            try expect(cardsR.value?.count == 1 && cardsR.lastOK == priorCardsOK && cardsR.error != nil,
                       "failed card response cleared old cards or advanced last-success")

            // Tibo 重置动态（AIHOT codex-resets）：解析严格性、展示行、三态合并
            let tiboPayload: [String: Any] = [
                "checkedAt": "2026-09-29T11:25:32.988+08:00",
                "events": [
                    ["id": "t1", "type": "direct_reset", "status": "announced",
                     "title": "Tibo 预告将重置额度",
                     "createdAt": "2026-09-27T05:41:35.000+08:00",
                     "estimate": ["label": "北京时间 9月29日 03:00–9月30日 03:00",
                                  "from": "2026-09-29T03:00:00.000+08:00",
                                  "through": "2026-09-30T03:00:00.000+08:00"],
                     "posts": [["url": "https://x.com/thsottiaux/status/2103963215885701493"]],
                     "url": "https://aihot.news/codex-reset"],
                    ["id": "t2", "type": "reset_credit", "status": "confirmed",
                     "title": "重置卡已发放",
                     "createdAt": "2026-09-26T08:07:13.000+08:00",
                     "updatedAt": "2026-10-29T00:59:04.000+08:00",
                     "posts": [], "url": "https://aihot.news/codex-reset"],
                    ["id": "t3", "status": "announced"],   // 缺 title：单条脏数据，跳过
                    ["id": "t4", "type": "direct_reset", "status": "announced",
                     "title": "预告但未给窗口", "createdAt": "2026-09-20T00:00:00.000+08:00",
                     "posts": [], "url": "https://aihot.news/codex-reset"],
                    // 窗口比 t1 早但 createdAt 比 t1 晚：钉死「按窗口排而非按记录时间排」
                    ["id": "t5", "type": "direct_reset", "status": "announced",
                     "title": "更早窗口的预告", "createdAt": "2026-09-28T00:00:00.000+08:00",
                     "estimate": ["label": "北京时间 9月28日 03:00–9月29日 23:00",
                                  "from": "2026-09-28T03:00:00.000+08:00",
                                  "through": "2026-09-29T23:00:00.000+08:00"],
                     "posts": [], "url": "https://aihot.news/codex-reset"],
                    // 第 4 条预告：超出 3 条上限，记录时间也最早，展示时必须被截断
                    ["id": "t6", "type": "direct_reset", "status": "announced",
                     "title": "超出上限的预告", "createdAt": "2026-09-19T00:00:00.000+08:00",
                     "posts": [], "url": "https://aihot.news/codex-reset"],
                    // presentation=likely_completed：窗口已过大概率已生效（AIHOT 页面按
                    // 「已生效」渲染），窗口再晚也不占预告行
                    ["id": "t7", "type": "direct_reset", "status": "announced",
                     "title": "已过窗口的旧预告", "createdAt": "2026-09-30T06:00:00.000+08:00",
                     "presentation": ["status": "likely_completed"],
                     "estimate": ["label": "北京时间 9月30日 03:00–10月1日 03:00",
                                  "from": "2026-09-30T03:00:00.000+08:00",
                                  "through": "2026-10-01T03:00:00.000+08:00"],
                     "posts": [], "url": "https://aihot.news/codex-reset"],
                    // confirmedAt 最新的真确认压过重置卡，占住确认行
                    ["id": "t8", "type": "direct_reset", "status": "confirmed",
                     "title": "Codex 额度重置已完成",
                     "createdAt": "2026-09-29T09:00:00.000+08:00",
                     "confirmedAt": "2026-09-29T10:00:00.000+08:00",
                     "posts": [], "url": "https://aihot.news/codex-reset"]
                ]
            ]
            let tiboParsed = Fetcher.parseTiboResets(tiboPayload)
            guard let tiboEvents = tiboParsed.events else {
                throw Failure(description: "valid tibo payload failed: \(tiboParsed.error ?? "unknown")")
            }
            try expect(tiboEvents.count == 7, "malformed tibo event was not skipped")
            try expect(tiboEvents[0].estimateLabel?.contains("9月29日") == true
                       && tiboEvents[0].estimateFrom != nil
                       && tiboEvents[0].estimateThrough != nil,
                       "tibo estimate window did not parse")
            try expect(tiboEvents[0].link.hasPrefix("https://x.com/"),
                       "tibo post link did not win over page url")
            try expect(tiboEvents[1].occurredAt == Fmt.isoFrac.date(from: "2026-09-26T08:07:13.000+08:00"),
                       "tibo occurredAt must fall back to createdAt, never the batch-refreshed updatedAt")
            try expect(tiboEvents[1].link == "https://aihot.news/codex-reset",
                       "tibo page url fallback was lost")
            try expect(tiboEvents[5].presentationStatus == "likely_completed",
                       "tibo presentation.status was dropped")
            try expect(tiboParsed.checkedAt != nil, "tibo checkedAt watermark was dropped")
            let noTibo = Fetcher.parseTiboResets(["error": "upstream"])
            try expect(noTibo.events == nil && noTibo.error != nil,
                       "missing tibo events container was accepted")
            let badTibo = Fetcher.parseTiboResets(["events": [:]])
            try expect(badTibo.events == nil && badTibo.error != nil,
                       "wrong-type tibo events container was accepted")
            let emptyTibo = Fetcher.parseTiboResets(["events": []])
            try expect(emptyTibo.events?.isEmpty == true && emptyTibo.error == nil,
                       "valid empty tibo event list was rejected")

            // 展示行：预告行只显示「预估 <窗口>」，announced 按窗口开始时间倒序只取
            // 最近 1 条（无预估回退标题，不带事件标题）；窗口未过不标「待确认」、已过
            // 必须标；已确认取最近一条
            guard let duringWindow = Fmt.isoFrac.date(from: "2026-09-29T12:00:00.000+08:00"),
                  let afterWindow = Fmt.isoFrac.date(from: "2026-10-01T12:00:00.000+08:00") else {
                throw Failure(description: "tibo display fixture dates failed to parse")
            }
            let rowsDuring = TiboDisplay.rows(tiboEvents, now: duringWindow)
            try expect(rowsDuring.count == 2
                       && rowsDuring[0].text == "预估 北京时间 9月29日 03:00–9月30日 03:00",
                       "latest-window announced tibo row did not render estimate-only text")
            try expect(!rowsDuring[0].text.contains("Tibo 预告将重置额度"),
                       "announced tibo row still carried the event title")
            try expect(!rowsDuring[0].text.contains("待确认"),
                       "pending marker shown while estimate window still open")
            try expect(rowsDuring[1].confirmed && rowsDuring[1].text.contains("额度重置已完成")
                       && !rowsDuring[1].text.contains("重置卡已发放"),
                       "confirmed tibo row must show the latest real confirm, not reset_credit")
            try expect(!rowsDuring.contains { $0.text.contains("已过窗口的旧预告")
                                               || $0.text.contains("10月1日") },
                       "likely_completed announcement rendered as a pending row")
            try expect(!rowsDuring.contains { $0.text.contains("9月28日")
                                               || $0.text.contains("超出上限的预告")
                                               || $0.text.contains("预告但未给窗口") },
                       "non-latest announced rows were not dropped to a single row")
            // 钉排序与回退：数组里 t5 在前也必须取窗口更晚的 t1；单独的无预估预告回退标题
            let shuffledAnnounced = [tiboEvents[3], tiboEvents[0]]
            try expect(TiboDisplay.rows(shuffledAnnounced, now: duringWindow)[0].text
                           == "预估 北京时间 9月29日 03:00–9月30日 03:00",
                       "announced pick not by latest estimate window")
            try expect(TiboDisplay.rows([tiboEvents[2]], now: duringWindow)[0].text == "预告但未给窗口",
                       "announced tibo row without estimate did not fall back to title")
            let rowsAfter = TiboDisplay.rows(tiboEvents, now: afterWindow)
            try expect(rowsAfter[0].text.contains("窗口已过，待确认"),
                       "expired tibo estimate window was not marked pending")
            try expect(TiboDisplay.rows([], now: duringWindow).first?.text == "暂无重置动态",
                       "empty tibo events did not render the placeholder")

            // 三态合并：fresh 推进成功时间；unchanged(304) 保留旧值但推进成功时间；failure 保留旧值旧时间
            let tiboOldOK = now.addingTimeInterval(-1_000)
            let tiboFreshR = TiboFreshness.apply(outcome: .fresh(tiboEvents, checkedAt: tiboParsed.checkedAt),
                old: nil, oldCheckedAt: nil, oldLastOK: nil, oldError: nil, now: now)
            try expect(tiboFreshR.value?.count == 7 && tiboFreshR.lastOK == now && tiboFreshR.error == nil,
                       "fresh tibo outcome did not advance state")
            let tiboUnchangedR = TiboFreshness.apply(outcome: .unchanged,
                old: tiboEvents, oldCheckedAt: tiboParsed.checkedAt, oldLastOK: tiboOldOK, oldError: nil, now: now)
            try expect(tiboUnchangedR.value?.count == 7 && tiboUnchangedR.lastOK == now
                       && tiboUnchangedR.checkedAt == tiboParsed.checkedAt,
                       "304 tibo outcome cleared data or did not advance last-success")
            let tiboFailR = TiboFreshness.apply(outcome: .failure("HTTP 500"),
                old: tiboEvents, oldCheckedAt: nil, oldLastOK: tiboOldOK, oldError: nil, now: now)
            try expect(tiboFailR.value?.count == 7 && tiboFailR.lastOK == tiboOldOK && tiboFailR.error == "HTTP 500",
                       "failed tibo outcome cleared old events or advanced last-success")

            // 外部用量（OpenAI 模型 · 非 Codex CLI）：甄别谓词（正负例均取自本机外部工具实测模型名）
            try expect(ExternalTokenScanner.isOpenAIModel("gpt-5.6-sol")
                       && ExternalTokenScanner.isOpenAIModel("GPT-6.1-SOL")
                       && ExternalTokenScanner.isOpenAIModel("gpt-5.5")
                       && ExternalTokenScanner.isOpenAIModel("codex-mini-latest")
                       && ExternalTokenScanner.isOpenAIModel("chatgpt-4o-latest")
                       && ExternalTokenScanner.isOpenAIModel("o3")
                       && ExternalTokenScanner.isOpenAIModel("o4-mini"),
                       "OpenAI-family model names were rejected")
            try expect(!ExternalTokenScanner.isOpenAIModel("glm-5.2")
                       && !ExternalTokenScanner.isOpenAIModel("k3-256k")
                       && !ExternalTokenScanner.isOpenAIModel("kimi-k3")
                       && !ExternalTokenScanner.isOpenAIModel("claude-sonnet-5")
                       && !ExternalTokenScanner.isOpenAIModel("minimax-m3")
                       && !ExternalTokenScanner.isOpenAIModel("deepseek-v4-flash")
                       && !ExternalTokenScanner.isOpenAIModel("qwen3.8-max")
                       && !ExternalTokenScanner.isOpenAIModel("ark-code-latest")
                       && !ExternalTokenScanner.isOpenAIModel("mimo-v2.5-pro")
                       && !ExternalTokenScanner.isOpenAIModel("opus")
                       && !ExternalTokenScanner.isOpenAIModel("auto")
                       && !ExternalTokenScanner.isOpenAIModel("")
                       && !ExternalTokenScanner.isOpenAIModel(nil),
                       "non-OpenAI or missing model names were accepted")

            // 行解析：_createdAt(ms)/timestamp(ISO8601) 双格式、cache 计入 input
            //（对齐中转/monitor 总量口径）、非 OpenAI 模型剔除、modelUsage 汇总行跳过、
            // 缺时间/坏 usage 跳过。基准取「本地正午」，任何时区下 ±数小时偏移都不跨日。
            guard let extBase = ExternalTokenScanner.dayFmt.date(from: "2026-10-09")?
                .addingTimeInterval(12 * 3600) else {
                throw Failure(description: "external scan fixture base date failed to parse")
            }
            let extMS = extBase.timeIntervalSince1970 * 1000
            let localISO: String = {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZZZZZ"
                return f.string(from: extBase)
            }()
            var fs = ExternalTokenScanner.FileState()
            ExternalTokenScanner.parseLines([
                "{\"type\":\"assistant\",\"_createdAt\":\(extMS),\"message\":{\"model\":\"gpt-5.6-sol\",\"usage\":{\"input_tokens\":100,\"cache_read_input_tokens\":50,\"cache_creation_input_tokens\":20,\"output_tokens\":30}}}",
                "{\"type\":\"assistant\",\"_createdAt\":\(extMS),\"message\":{\"model\":\"glm-5.2\",\"usage\":{\"input_tokens\":999,\"output_tokens\":999}}}",
                "{\"type\":\"result\",\"_createdAt\":\(extMS),\"modelUsage\":{\"gpt-5.6-sol\":{}},\"usage\":{\"input\":700,\"output\":70}}",
                "{\"type\":\"assistant\",\"timestamp\":\"\(localISO)\",\"message\":{\"model\":\"gpt-6.1-sol\",\"usage\":{\"input_tokens\":200,\"output_tokens\":40}}}",
                "{\"type\":\"assistant\",\"message\":{\"model\":\"gpt-5.6-sol\",\"usage\":{\"input_tokens\":500,\"output_tokens\":50}}}",
                "{\"type\":\"assistant\",\"_createdAt\":\(extMS),\"message\":{\"model\":\"gpt-5.6-sol\",\"usage\":\"bad\"}}"
            ].joined(separator: "\n"), cutoffKey: "2000-01-01", into: &fs)
            let extDayKey = ExternalTokenScanner.dayFmt.string(from: extBase)
            // 100+50(cache_read)+20(cache_creation)+200，cache 计入 input
            try expect(fs.days.count == 1 && fs.days[extDayKey] == [370, 70],
                       "external parse did not aggregate OpenAI usage only (got \(fs.days))")
            try expect(fs.daysByModel[extDayKey]?["gpt-5.6-sol"] == [170, 30]
                       && fs.daysByModel[extDayKey]?["gpt-6.1-sol"] == [200, 40]
                       && fs.daysByModel[extDayKey]?.count == 2,
                       "external per-model aggregation wrong (got \(fs.daysByModel))")

            // 本地会话统计端到端（临时 sessions 根 + 临时状态文件，不碰真实 ~/.codex）：
            // 窗口分桶 + codex 压缩归档 .jsonl.zst 必须计入 30 天窗口（2026-10 实况：
            // 7 天外的会话全是 .zst，漏掉它们 30 天=7 天）；环境无 zstd 时降级为明文
            // 文件仅覆盖窗口逻辑，并打印提示
            let sesRoot = root.path + "/codex-sessions"
            let sesState = root.path + "/ses-scan-state.json"
            func sesStamp(_ d: Date) -> String {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy-MM-dd'T'HH-mm-ss"
                return f.string(from: d)
            }
            func sesDayDir(_ d: Date) -> String {
                let f = DateFormatter()
                f.locale = Locale(identifier: "en_US_POSIX")
                f.dateFormat = "yyyy/MM/dd"
                return f.string(from: d)
            }
            func sesUsage(_ input: Int) -> String {
                "{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":"
                    + "{\"total_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":1,"
                    + "\"total_tokens\":\(input + 1)}}}}\n"
            }
            // .zst 夹具：① 内嵌真实 zstd CLI 生成的 .zst 帧（base64，与 Codex 归档
            // 同源 zstandard 格式）——始终可用，直接进扫描根覆盖 .zst 统计路径；
            // ② 系统 zstd 命令现压一个夹具（覆盖另一压缩参数组合）——命令缺失则跳过，
            // 解码侧不依赖它
            let sesOld = now.addingTimeInterval(-10 * 86400)   // 30 天内、7 天外
            let sesNew = now.addingTimeInterval(-2 * 86400)    // 7 天内
            for d in [sesOld, sesNew] {
                try FileManager.default.createDirectory(
                    atPath: sesRoot + "/" + sesDayDir(d), withIntermediateDirectories: true)
            }
            try sesUsage(499).write(toFile: sesRoot + "/" + sesDayDir(sesNew)
                + "/rollout-\(sesStamp(sesNew))-aaaa.jsonl", atomically: true, encoding: .utf8)
            // 内嵌真实帧：内容为 input 2999 / output 1 / total 3000 的 token_count 行
            let embeddedFrame = Data(base64Encoded:
                "KLUv/SSPHQMA0sUTGJApbS0Z12AkEl97m2Cpu98CaigcG8vtJ4CUUiqlDOxbAW59GWME9uVGaTyxY3Hb5zhWNaTxOmcr4SQelO2F0wM59HqxiMOJCbwdEcJPAgYAXnEY8ATnUD9HA+oGQ6Hyj2drig==")!
            try embeddedFrame.write(to: URL(fileURLWithPath: sesRoot + "/" + sesDayDir(sesOld)
                + "/rollout-\(sesStamp(sesOld))-cccc.jsonl.zst"))
            // 系统 zstd 命令夹具（编码侧可选，解码侧不依赖）
            func zstdCompress(src: String, dst: String) -> Bool {
                let bin = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd",
                           "/opt/local/bin/zstd", "/usr/bin/zstd"]
                    .first { FileManager.default.isExecutableFile(atPath: $0) }
                guard let bin = bin else { return false }
                let p = Process()
                p.executableURL = URL(fileURLWithPath: bin)
                p.arguments = ["-q", "-f", "-o", dst, "--", src]
                p.standardError = FileHandle.nullDevice
                do { try p.run(); p.waitUntilExit() } catch { return false }
                return p.terminationStatus == 0
            }
            let oldPlain = root.path + "/old-session.jsonl"
            try sesUsage(2999).write(toFile: oldPlain, atomically: true, encoding: .utf8)
            let zstOK = zstdCompress(src: oldPlain,
                                     dst: sesRoot + "/" + sesDayDir(sesOld)
                                         + "/rollout-\(sesStamp(sesOld))-bbbb.jsonl.zst")
            if !zstOK {
                print("CodexUsage --self-test: note: no system zstd CLI, second .zst fixture skipped "
                      + "(embedded real frame still covers the decode path)")
            }
            let t1 = TokenScanner.scan(root: sesRoot, statePath: sesState, now: now)
            try expect(t1.seven.total == 500 && t1.seven.files == 1,
                       "tokens 7d window wrong (got \(t1.seven.total)/\(t1.seven.files))")
            // 30 天窗口 = 明文 500 + 内嵌真实帧 3000 + （系统 zstd 夹具 3000）
            let expect30 = zstOK ? 6500.0 : 3500.0
            let expectFiles = zstOK ? 3 : 2
            try expect(t1.thirty.total == expect30 && t1.thirty.files == expectFiles,
                       "tokens 30d window wrong — .zst archived sessions missed "
                       + "(got \(t1.thirty.total)/\(t1.thirty.files))")
            let t2 = TokenScanner.scan(root: sesRoot, statePath: sesState, now: now)
            try expect(t2.thirty.total == expect30 && t2.thirty.files == expectFiles,
                       "tokens incremental rescan double-counted or dropped entries")
            try expect(t2.seven.models["未知模型"]?.total == 500
                       && t2.thirty.models["未知模型"]?.total == expect30,
                       "legacy records without model metadata were not grouped as unknown")

            // A session can switch models between turns. Deltas follow the active turn_context,
            // including when a later incremental append switches back to an earlier model.
            let modelRoot = root.path + "/model-session"
            try FileManager.default.createDirectory(atPath: modelRoot, withIntermediateDirectories: true)
            let modelFile = modelRoot + "/rollout-\(sesStamp(now))-models.jsonl"
            let modelState = root.path + "/model-state.json"
            let modelStamp = Fmt.isoFrac.string(from: now)
            func modelContext(_ model: String) -> String {
                "{\"timestamp\":\"\(modelStamp)\",\"type\":\"turn_context\",\"payload\":{\"model\":\"\(model)\"}}\n"
            }
            func modelUsage(_ input: Int) -> String {
                "{\"timestamp\":\"\(modelStamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(input),\"output_tokens\":1,\"total_tokens\":\(input + 1)}}}}\n"
            }
            let initialModels = modelContext("gpt-5.5-codex") + modelUsage(99)
                + modelContext("gpt-5.5") + modelUsage(249)
            try initialModels.write(toFile: modelFile, atomically: true, encoding: .utf8)
            let models1 = TokenScanner.scan(root: modelRoot, statePath: modelState, now: now)
            try expect(models1.today.total == 250
                       && models1.today.models["gpt-5.5-codex"]?.total == 100
                       && models1.today.models["gpt-5.5"]?.total == 150,
                       "initial per-model turn attribution wrong (got \(models1.today.models))")
            let modelHandle = FileHandle(forWritingAtPath: modelFile)!
            modelHandle.seekToEndOfFile()
            modelHandle.write(Data((modelContext("gpt-5.5-codex") + modelUsage(399)).utf8))
            try modelHandle.close()
            let models2 = TokenScanner.scan(root: modelRoot, statePath: modelState, now: now)
            try expect(models2.today.total == 400
                       && models2.today.models["gpt-5.5-codex"]?.total == 250
                       && models2.today.models["gpt-5.5"]?.total == 150
                       && models2.today.models.values.reduce(0) { $0 + $1.total } == models2.today.total,
                       "incremental model switch attribution wrong (got \(models2.today.models))")

            // One session crosses midnight: cumulative 100 yesterday, then 140 today.
            let crossRoot = root.path + "/cross-session"
            try FileManager.default.createDirectory(atPath: crossRoot, withIntermediateDirectories: true)
            let crossFile = crossRoot + "/rollout-2000-01-01T00-00-00-cross.jsonl"
            let yesterday = Calendar.current.date(byAdding: .day, value: -1, to: now)!
            func event(_ value: Int, _ date: Date) -> String {
                let stamp = Fmt.isoFrac.string(from: date)
                return "{\"timestamp\":\"\(stamp)\",\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":\(value),\"output_tokens\":0,\"total_tokens\":\(value)}}}}\n"
            }
            try event(100, yesterday).write(toFile: crossFile, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: crossFile)
            let crossState = root.path + "/cross-state.json"
            _ = TokenScanner.scan(root: crossRoot, statePath: crossState, now: now)
            let fh = FileHandle(forWritingAtPath: crossFile)!
            fh.seekToEndOfFile()
            fh.write(Data("{\"type\":\"event_msg\",\"payload\":{\"type\":\"token_count\",\"info\":{\"total_token_usage\":{\"input_tokens\":100}}}}\n".utf8))
            fh.write(Data(event(140, now).utf8)); try fh.close()
            try FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: crossFile)
            let cross = TokenScanner.scan(root: crossRoot, statePath: crossState, now: now)
            try expect(cross.today.total == 40 && cross.seven.total == 140 && cross.thirty.total == 140 && cross.seven.files == 1,
                       "cross-midnight cumulative delta misattributed")
            // Old cache schema is rebuilt from events, not reused as a creation-day total.
            let legacyState = root.path + "/legacy-scan-state.json"
            try "{\"files\":{}}".write(toFile: legacyState, atomically: true, encoding: .utf8)
            let migrated = TokenScanner.scan(root: crossRoot, statePath: legacyState, now: now)
            try expect(migrated.today.total == 40 && migrated.thirty.total == 140,
                       "legacy cache migration did not rebuild event buckets")
            // Both archive and original can exist while compression completes.
            let duplicate = crossFile + ".zst"
            try embeddedFrame.write(to: URL(fileURLWithPath: duplicate))
            let overlap = TokenScanner.scan(root: crossRoot, statePath: crossState, now: now)
            try expect(overlap.thirty.total == 140 && overlap.thirty.files == 1,
                       "compressed and plain overlap was counted twice")
            let invalidState = root.path + "/invalid-v2-state.json"
            let malformedCache: [String: Any] = ["version": 2, "files": [crossFile:
                ["size": 1, "mtime": 0, "offset": 0, "previous": [100], "days": ["2000-01-01": [1]]]]]
            try JSONSerialization.data(withJSONObject: malformedCache).write(to: URL(fileURLWithPath: invalidState))
            let repaired = TokenScanner.scan(root: crossRoot, statePath: invalidState, now: now)
            try expect(repaired.today.total == 40 && repaired.thirty.total == 140,
                       "malformed v2 cache did not rebuild safely")
            let crossAgain = TokenScanner.scan(root: crossRoot, statePath: crossState, now: now)
            try expect(crossAgain.today.total == 40 && crossAgain.thirty.total == 140,
                       "cross-midnight cache rescan changed totals")

            // 损坏 .zst：解不开的归档本轮跳过且不写状态条目，不阻塞其余会话统计
            let badRoot = root.path + "/codex-sessions-badzst"
            for d in [sesOld, sesNew] {
                try FileManager.default.createDirectory(
                    atPath: badRoot + "/" + sesDayDir(d), withIntermediateDirectories: true)
            }
            try Data([0x28, 0xB5, 0x2F, 0xFD, 0x01, 0x00, 0xAA, 0xBB]).write(
                to: URL(fileURLWithPath: badRoot + "/" + sesDayDir(sesOld)
                    + "/rollout-\(sesStamp(sesOld))-bad.jsonl.zst"))
            try sesUsage(777).write(toFile: badRoot + "/" + sesDayDir(sesNew)
                + "/rollout-\(sesStamp(sesNew))-good.jsonl", atomically: true, encoding: .utf8)
            let br = TokenScanner.scan(root: badRoot, statePath: root.path + "/bad-scan-state.json", now: now)
            try expect(br.thirty.total == 778 && br.thirty.files == 1,
                       "corrupt .zst archive was not skipped cleanly "
                       + "(got \(br.thirty.total)/\(br.thirty.files))")

            // 大文件分块读取：候选事件位于文件开头和结尾时均应正确统计
            let tailRoot = root.path + "/codex-sessions-tail"
            try FileManager.default.createDirectory(
                atPath: tailRoot + "/" + sesDayDir(sesNew), withIntermediateDirectories: true)
            let padding = String(repeating:
                "{\"pad\":\"xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx\"}\n",
                count: 17_000)   // ~1.3MB，超过单个读取块
            try (padding + sesUsage(1234)).write(
                toFile: tailRoot + "/" + sesDayDir(sesNew)
                    + "/rollout-\(sesStamp(sesNew))-cccc.jsonl", atomically: true, encoding: .utf8)
            try (sesUsage(2222) + padding).write(
                toFile: tailRoot + "/" + sesDayDir(sesNew)
                    + "/rollout-\(sesStamp(sesNew))-dddd.jsonl", atomically: true, encoding: .utf8)
            let tr = TokenScanner.scan(root: tailRoot, statePath: root.path + "/tail-scan-state.json", now: now)
            try expect(tr.thirty.total == 1235 + 2223 && tr.thirty.files == 2,
                       "tail-read or full-file fallback returned wrong totals (got \(tr.thirty.total))")

            // 外部用量增量扫描端到端（临时 roots + 临时状态文件，不碰真实 ~/.proma / ~/.claude）：
            // 窗口分桶、嵌套枚举、首见旧文件跳过、追加增量、删除剔除、截断重扫
            let extRootA = root.path + "/proma-a"
            let extRootB = root.path + "/claude-b"
            try FileManager.default.createDirectory(atPath: extRootA, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(atPath: extRootB + "/nested", withIntermediateDirectories: true)
            func extLine(_ model: String, _ at: Date, inTok: Double, outTok: Double) -> String {
                "{\"type\":\"assistant\",\"_createdAt\":\(at.timeIntervalSince1970 * 1000),"
                    + "\"message\":{\"model\":\"\(model)\",\"usage\":{"
                    + "\"input_tokens\":\(Int(inTok)),\"output_tokens\":\(Int(outTok))}}}"
            }
            let fileA = extRootA + "/a.jsonl"
            let fileB = extRootB + "/nested/b.jsonl"   // 嵌套目录也必须枚举到
            let fileC = extRootA + "/old.jsonl"
            try [extLine("gpt-5.6-sol", extBase, inTok: 100, outTok: 10),
                 extLine("gpt-5.6-sol", extBase.addingTimeInterval(-6 * 86400), inTok: 1000, outTok: 100),
                 // −7 天：含今天共 7 天的窗口不含此行（钉口径），30 天窗口仍计入
                 extLine("gpt-5.6-sol", extBase.addingTimeInterval(-7 * 86400), inTok: 5000, outTok: 500)]
                .joined(separator: "\n").appending("\n")
                .write(toFile: fileA, atomically: true, encoding: .utf8)
            try extLine("gpt-5.6-sol", extBase.addingTimeInterval(-29 * 86400), inTok: 10000, outTok: 1000)
                .appending("\n").write(toFile: fileB, atomically: true, encoding: .utf8)
            // 内容是今天但 mtime 在 40 天前：首见旧文件跳过，不计入
            try extLine("gpt-5.5", extBase, inTok: 99999, outTok: 9999).appending("\n")
                .write(toFile: fileC, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes(
                [.modificationDate: extBase.addingTimeInterval(-40 * 86400)], ofItemAtPath: fileC)

            let extRoots = [extRootA, extRootB]
            let extStatePath = root.path + "/ext-scan-state.json"
            let s1 = ExternalTokenScanner.scan(roots: extRoots, hermesDB: nil,
                                               statePath: extStatePath, now: extBase)
            try expect(s1.today.input == 100 && s1.today.output == 10,
                       "external today window wrong (got \(s1.today.input)/\(s1.today.output))")
            try expect(s1.seven.input == 1100 && s1.seven.output == 110,
                       "external 7d window wrong or −7d row leaked into 7-calendar-day window "
                       + "(got \(s1.seven.input))")
            try expect(s1.thirty.input == 16100 && s1.thirty.output == 1610,
                       "external 30d window wrong (old-file skip or nested enumeration failed)")
            try expect(s1.today.models["gpt-5.6-sol"]?.total == 110
                       && s1.seven.models["gpt-5.6-sol"]?.total == 1210
                       && s1.thirty.models["gpt-5.6-sol"]?.total == 17710,
                       "external per-model window totals do not match aggregate totals")

            let aliasRoot = root.path + "/proma-alias"
            try FileManager.default.createSymbolicLink(atPath: aliasRoot, withDestinationPath: extRootA)
            let dedup = ExternalTokenScanner.scan(roots: [extRootA, aliasRoot, extRootA + "/nested"], hermesDB: nil,
                statePath: root.path + "/alias-state.json", now: extBase)
            let oneRoot = ExternalTokenScanner.scan(roots: [extRootA], hermesDB: nil,
                statePath: root.path + "/one-root-state.json", now: extBase)
            try expect(dedup.thirty.total == oneRoot.thirty.total, "aliased source counted twice")
            try expect(dedup.tools.values.reduce(0) { $0 + $1[2].total } == dedup.thirty.total,
                       "tool attribution does not add to source total")

            let handleA = try FileHandle(forWritingTo: URL(fileURLWithPath: fileA))
            _ = try handleA.seekToEnd()
            handleA.write(Data(extLine("gpt-5.6-sol", extBase, inTok: 100, outTok: 10)
                .appending("\n").utf8))
            try handleA.close()
            let s2 = ExternalTokenScanner.scan(roots: extRoots, hermesDB: nil,
                                               statePath: extStatePath, now: extBase)
            try expect(s2.today.input == 200 && s2.seven.input == 1200 && s2.thirty.input == 16200,
                       "external incremental append was double-counted or missed")

            try FileManager.default.removeItem(atPath: fileB)
            let s3 = ExternalTokenScanner.scan(roots: extRoots, hermesDB: nil,
                                               statePath: extStatePath, now: extBase)
            try expect(s3.thirty.input == 6200,
                       "deleted external session file still contributed to the 30d window "
                       + "(got \(s3.thirty.input), state persisted: \(FileManager.default.contents(atPath: extStatePath) != nil))")

            try extLine("gpt-5.6-sol", extBase, inTok: 30, outTok: 3).appending("\n")
                .write(toFile: fileA, atomically: true, encoding: .utf8)
            let s4 = ExternalTokenScanner.scan(roots: extRoots, hermesDB: nil,
                                               statePath: extStatePath, now: extBase)
            try expect(s4.today.input == 30 && s4.seven.input == 30 && s4.thirty.input == 30,
                       "truncated external file did not rebase its aggregation")

            // 外部用量失败面：已安装来源全部不可读 → error；未安装（路径不存在）不算失败；
            // 部分来源可读仍按成功（增量状态保留旧贡献，下轮自愈）
            let notADir = root.path + "/not-a-dir"
            try Data("x".utf8).write(to: URL(fileURLWithPath: notADir))
            let badScan = ExternalTokenScanner.scan(roots: [notADir], hermesDB: nil,
                                                    statePath: root.path + "/ext-bad-state.json", now: extBase)
            try expect(badScan.error != nil, "unreadable installed root was reported as success")
            let absentScan = ExternalTokenScanner.scan(roots: [root.path + "/does-not-exist"], hermesDB: nil,
                                                       statePath: root.path + "/ext-absent-state.json", now: extBase)
            try expect(absentScan.error == nil, "not-installed source was reported as failure")
            let notDB = root.path + "/not-a-db"
            try Data("plain text".utf8).write(to: URL(fileURLWithPath: notDB))
            let badHermes = ExternalTokenScanner.scan(roots: [], hermesDB: notDB,
                                                      statePath: root.path + "/ext-badhermes-state.json", now: extBase)
            try expect(badHermes.error != nil, "corrupt hermes db was reported as success")
            let partialScan = ExternalTokenScanner.scan(roots: [extRootA, notADir], hermesDB: nil,
                                                        statePath: root.path + "/ext-partial-state.json", now: extBase)
            try expect(partialScan.error == nil && partialScan.thirty.input == 30,
                       "partially readable sources were reported as total failure")

            // hermes 差分（临时 sqlite 夹具）：首扫按 last_seen 回填、累计行增长入当日、
            // 计数重置 rebase 不倒扣、行删除移出快照但保留历史差分
            let hdbPath = root.path + "/hermes-fixture.db"
            var hdbPtr: OpaquePointer?
            guard sqlite3_open_v2(hdbPath, &hdbPtr,
                                  SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE, nil) == SQLITE_OK,
                  let hdb = hdbPtr else {
                throw Failure(description: "hermes fixture db could not be created")
            }
            defer { sqlite3_close(hdb) }
            func hexec(_ sql: String) throws {
                var err: UnsafeMutablePointer<CChar>?
                guard sqlite3_exec(hdb, sql, nil, nil, &err) == SQLITE_OK else {
                    let msg = err.map { String(cString: $0) } ?? "unknown"
                    sqlite3_free(err)
                    throw Failure(description: "hermes fixture exec failed: \(msg)")
                }
            }
            try hexec("""
                CREATE TABLE session_model_usage (
                    session_id TEXT, model TEXT, billing_provider TEXT, billing_base_url TEXT,
                    billing_mode TEXT, task TEXT, input_tokens INTEGER, output_tokens INTEGER,
                    cache_read_tokens INTEGER, cache_write_tokens INTEGER, last_seen REAL);
                """)
            try hexec("INSERT INTO session_model_usage VALUES ('s1', 'gpt-6.1-sol', 'p', 'u', 'm', 't', 1000, 100, 0, 0, \(extBase.timeIntervalSince1970 - 3600));")
            try hexec("INSERT INTO session_model_usage VALUES ('s2', 'glm-5.2', 'p', 'u', 'm', 't', 5000, 500, 0, 0, \(extBase.timeIntervalSince1970 - 3600));")
            let hStatePath = root.path + "/ext-hermes-state.json"
            let h1 = ExternalTokenScanner.scan(roots: [], hermesDB: hdbPath,
                                               statePath: hStatePath, now: extBase)
            try expect(h1.today.input == 1000 && h1.today.output == 100 && h1.thirty.input == 1000,
                       "hermes first scan did not backfill OpenAI rows by last_seen (got \(h1.today.input))")
            try expect(h1.today.models["gpt-6.1-sol"]?.total == 1100
                       && h1.today.models.count == 1,
                       "hermes model attribution included a non-OpenAI model or lost usage")
            try hexec("UPDATE session_model_usage SET input_tokens = 2500, last_seen = \(extBase.timeIntervalSince1970 - 1800) WHERE session_id = 's1'")
            let h2 = ExternalTokenScanner.scan(roots: [], hermesDB: hdbPath,
                                               statePath: hStatePath, now: extBase)
            // 回填 1000（base-3600）+ 差分 1500（base-1800）同属今天 → 2500
            try expect(h2.today.input == 2500 && h2.today.output == 100,
                       "hermes cumulative diff did not land in the right day bucket (got \(h2.today.input))")
            let hFault = ExternalTokenScanner.scan(roots: [], hermesDB: hdbPath,
                statePath: hStatePath, now: extBase, hermesFailAfterRows: 1)
            try expect(hFault.error != nil && hFault.today.input == 2500,
                       "failed sqlite step changed the committed snapshot")
            try hexec("UPDATE session_model_usage SET input_tokens = 2600 WHERE session_id = 's1'")
            let hRecovered = ExternalTokenScanner.scan(roots: [], hermesDB: hdbPath,
                statePath: hStatePath, now: extBase)
            try expect(hRecovered.today.input == 2600, "sqlite recovery double-counted")
            try hexec("UPDATE session_model_usage SET input_tokens = 10 WHERE session_id = 's1'")
            let h3 = ExternalTokenScanner.scan(roots: [], hermesDB: hdbPath,
                                               statePath: hStatePath, now: extBase)
            try expect(h3.today.input == 2600 && h3.today.output == 100,
                       "hermes counter reset produced negative or inflated usage")
            try hexec("DELETE FROM session_model_usage WHERE session_id = 's1'")
            let h4 = ExternalTokenScanner.scan(roots: [], hermesDB: hdbPath,
                                               statePath: hStatePath, now: extBase)
            try expect(h4.today.input == 2600 && h4.thirty.input == 2600,
                       "deleted hermes row changed historical aggregation")

            // Stable account identity survives token rotation; different workspace and
            // incomplete identities are conservative boundaries.
            func jwt(_ claims: [String: Any]) throws -> String {
                let data = try JSONSerialization.data(withJSONObject: claims)
                return "x." + data.base64EncodedString().replacingOccurrences(of: "+", with: "-")
                    .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "") + ".x"
            }
            let idJWT = try jwt(["sub": "user-a"])
            func authIdentity(_ token: String, _ account: String?) -> String? {
                CodexAuth.identity(CodexAuth.Snapshot(tokens: CodexAuth.Tokens(
                    accessToken: token, refreshToken: nil, idToken: idJWT, email: nil, accountID: account)))
            }
            try expect(authIdentity("old", "workspace-a") == authIdentity("new", "workspace-a"),
                       "same-account token rotation changed identity")
            try expect(authIdentity("old", "workspace-a") != authIdentity("old", "workspace-b")
                       && authIdentity("old", nil) != authIdentity("new", nil),
                       "workspace or incomplete identity was mixed")

            var isolated = UsageData()
            isolated.planType = "old"; isolated.email = "old@example.test"; isolated.resetCredits = 1
            isolated.fiveHour = QuotaWindow(usedPercent: 50, reset: nil)
            isolated.resetCards = [ResetCard(expires: now, name: "old")]
            isolated.quotaError = "old error"; isolated.resetCardsError = "old error"
            AccountIsolation.clear(&isolated)
            try expect(isolated.planType == nil && isolated.email == nil && isolated.resetCredits == nil
                       && isolated.fiveHour == nil && isolated.resetCards == nil
                       && isolated.quotaError == nil && isolated.resetCardsError == nil,
                       "account switch retained account-bound data")
            try expect(!AccountIsolation.accepts(capturedGeneration: 1, currentGeneration: 2,
                       capturedIdentity: "a", currentIdentity: "b")
                       && !AccountIsolation.accepts(capturedGeneration: 1, currentGeneration: 3,
                       capturedIdentity: "a", currentIdentity: "a"),
                       "late response accepted after account switch")

            let authPath = root.appendingPathComponent("auth.json").path
            func authDocument(_ access: String, _ refresh: String, _ id: String, _ marker: String) -> [String: Any] {
                ["auth_mode": "chatgpt", "marker": marker,
                 "tokens": ["access_token": access, "refresh_token": refresh,
                            "id_token": id, "account_id": "fake-account"]]
            }
            let initialData = try JSONSerialization.data(withJSONObject: authDocument("old-a", "old-r", "old-i", "before"))
            try initialData.write(to: URL(fileURLWithPath: authPath))
            try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: authPath)
            guard let expected = CodexAuth.load(at: authPath) else {
                throw Failure(description: "temporary auth file could not be read")
            }

            // Simulate the Codex CLI rotating all auth fields while our request is in flight.
            let clientData = try JSONSerialization.data(withJSONObject: authDocument("client-a", "client-r", "client-i", "client-change"))
            try clientData.write(to: URL(fileURLWithPath: authPath), options: .atomic)
            let beforeConflict = try Data(contentsOf: URL(fileURLWithPath: authPath))
            let conflict = try CodexAuth.writeBack(at: authPath, expected: expected.tokens,
                accessToken: "stale-response", refreshToken: "stale-refresh", idToken: "stale-id")
            try expect(!conflict.wrote && conflict.access == "client-a", "CLI credential rotation was overwritten")
            let afterConflict = try Data(contentsOf: URL(fileURLWithPath: authPath))
            try expect(beforeConflict == afterConflict, "conflict path changed the latest auth document")
            guard let latest = CodexAuth.load(at: authPath) else {
                throw Failure(description: "latest temporary auth file could not be read")
            }
            try expect(!CodexAuth.sameAuth(expected.tokens, latest.tokens),
                       "pre-request freshness check missed rotated authentication fields")

            let success = try CodexAuth.writeBack(at: authPath, expected: latest.tokens,
                accessToken: "rotated-a", refreshToken: "rotated-r", idToken: "rotated-i")
            try expect(success.wrote && success.access == "rotated-a", "credential refresh did not save")
            let saved = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: authPath))) as! [String: Any]
            let savedTokens = saved["tokens"] as! [String: Any]
            try expect(saved["marker"] as? String == "client-change", "new unrelated auth document data was lost")
            try expect(savedTokens["account_id"] as? String == "fake-account", "unrelated token field was lost")
            try expect(savedTokens["access_token"] as? String == "rotated-a"
                       && savedTokens["refresh_token"] as? String == "rotated-r"
                       && savedTokens["id_token"] as? String == "rotated-i", "rotated auth fields were not saved")
            let permissions = try FileManager.default.attributesOfItem(atPath: authPath)[.posixPermissions] as! NSNumber
            try expect(permissions.intValue & 0o077 == 0, "auth file gained group/other permissions")

            let failedTarget = root.appendingPathComponent("directory-target").path
            try FileManager.default.createDirectory(atPath: failedTarget, withIntermediateDirectories: false)
            try Data("marker".utf8).write(to: URL(fileURLWithPath: failedTarget).appendingPathComponent("marker"))
            var writeFailed = false
            do { try AtomicJSONFile.replace(Data("new".utf8), at: failedTarget) }
            catch { writeFailed = true }
            try expect(writeFailed, "atomic credential write failure was swallowed")
            let tempFiles = try FileManager.default.contentsOfDirectory(atPath: root.path)
                .filter { $0.hasSuffix(".tmp") }
            try expect(tempFiles.isEmpty, "failed write left a temporary credential file")

            // 更新检查：Release 版本号比较（v 前缀与 describe/dirty 尾巴剥离、逐段数值、短侧补 0、无法解析不提示）
            try expect(!UpdateCheck.isOutdated(local: "v1.0.1", remote: "v1.0.1"), "same release flagged outdated")
            try expect(UpdateCheck.isOutdated(local: "v1.0.0-1-g95952a1", remote: "v1.0.1"), "newer release not detected")
            try expect(!UpdateCheck.isOutdated(local: "v1.0.1", remote: "v1.0.0"), "older release flagged outdated")
            try expect(UpdateCheck.isOutdated(local: "v1.9", remote: "v1.10"), "segments compared as numbers, not strings")
            try expect(!UpdateCheck.isOutdated(local: "v1.10", remote: "v1.9"), "segments compared as numbers, not strings")
            try expect(!UpdateCheck.isOutdated(local: "v1.2", remote: "v1.2.0"), "shorter version not zero-padded")
            try expect(!UpdateCheck.isOutdated(local: "v1.0.0-dirty", remote: "v1.0.0"), "dirty suffix not stripped")
            try expect(UpdateCheck.isOutdated(local: "v1.0.0", remote: "v1.0.1-beta"), "prerelease suffix not stripped")
            try expect(!UpdateCheck.isOutdated(local: "unknown", remote: "v9.9.9"), "unknown local version flagged outdated")
            try expect(!UpdateCheck.isOutdated(local: "v1.0.0", remote: "unknown"), "unknown remote version flagged outdated")
            try expect(!UpdateCheck.isOutdated(local: "", remote: "v1.0.0"), "empty local version flagged outdated")
            try expect(!UpdateCheck.isOutdated(local: "abc", remote: "1.2"), "non-numeric local version flagged outdated")

            // 更新检查与脚本都只认附件完整的 Release；最新空 Release 不遮挡最近可安装版本
            let completeRelease: [String: Any] = [
                "tag_name": "v1.0.8", "draft": false, "prerelease": false,
                "assets": [["name": "CodexUsage.zip"], ["name": "CodexUsage.zip.sha256"]],
            ]
            let emptyRelease: [String: Any] = [
                "tag_name": "v1.0.9", "draft": false, "prerelease": false, "assets": [],
            ]
            let zipOnlyRelease: [String: Any] = [
                "tag_name": "v1.0.10", "draft": false, "prerelease": false,
                "assets": [["name": "CodexUsage.zip"]],
            ]
            try expect(UpdateCheck.latestDownloadableTag(in: [emptyRelease, completeRelease]) == "v1.0.8",
                       "empty latest release hid downloadable release")
            try expect(UpdateCheck.latestDownloadableTag(in: [zipOnlyRelease]) == nil,
                       "release without SHA256 accepted")
            try expect(UpdateCheck.latestDownloadableTag(in: [emptyRelease]) == nil,
                       "release without assets accepted")
            var prerelease = completeRelease
            prerelease["prerelease"] = true
            try expect(UpdateCheck.latestDownloadableTag(in: [prerelease, completeRelease]) == "v1.0.8",
                       "prerelease not skipped")

            try expect(UpdateCheck.displayNotes("  ") == "本版本暂未提供详细更新说明", "empty update notes")
            try expect(UpdateCheck.displayNotes("## 新增\n- **新功能**") == "新增\n• 新功能", "update notes formatting")
            var notedRelease = completeRelease; notedRelease["body"] = "测试说明"
            let selected = UpdateCheck.latestDownloadableRelease(in: [emptyRelease, notedRelease])
            try expect(selected?.tag == "v1.0.8" && selected?.notes == "测试说明", "notes must match downloadable release")
            try expect(PanelBackgroundStyle.parse(nil) == .solid && PanelBackgroundStyle.parse("bad") == .solid, "background default")
            try expect(PanelBackgroundStyle.liquidGlass.effective(liquidSupported: false, reduceTransparency: false) == .classicMaterial, "legacy glass fallback")
            try expect(PanelBackgroundStyle.liquidGlass.effective(liquidSupported: true, reduceTransparency: true) == .solid, "reduced transparency fallback")

            // 第三方链接白名单：仅 http/https 允许打开
            try expect(Fmt.webURL("https://x.com/a") != nil && Fmt.webURL("http://aihot.news") != nil,
                       "http/https tibo link was rejected")
            try expect(Fmt.webURL("javascript:alert(1)") == nil && Fmt.webURL("file:///etc/passwd") == nil
                       && Fmt.webURL("") == nil,
                       "non-web tibo link scheme was accepted")

            print("CodexUsage --self-test: PASS (strict/partial quota parsing, independent freshness, menu bar color tiers/light-dark images, card expiry, tibo reset parsing/display/merge, token scan windows/per-model attribution/model switching/.zst archives/real-frame decode/tail-read, external usage model/parse/per-model scan/hermes-diff/failure-surface/7-30-calendar-day windows, refresh gate/schedule, temp auth merge/permissions/failure, update check release version compare/assets, tibo link scheme allowlist)")
            return 0
        } catch {
            fputs("CodexUsage --self-test: FAIL: \(error)\n", stderr)
            return 1
        }
    }
}

if CommandLine.arguments.contains("--self-test") {
    exit(CodexOfflineRegression.run())
}

func onceMode() {
    let group = DispatchGroup()
    // 各结果单一写者；wait 超时返回时打印线程可能与迟到回调并发访问，统一经锁保护
    let onceLock = NSLock()
    var quotaVar: QuotaData?
    var scanVar: TokenScanner.Result?
    var cardsVar: [ResetCard]?
    var cardsErrVar: String?
    var tiboVar: TiboFetchOutcome?
    var extVar: ExternalTokenScanner.Result?
    group.enter()
    Fetcher.fetchQuota { r in
        onceLock.lock(); quotaVar = r; onceLock.unlock()
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let result = TokenScanner.scan()
        onceLock.lock(); scanVar = result; onceLock.unlock()
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        let result = ExternalTokenScanner.scan()
        onceLock.lock(); extVar = result; onceLock.unlock()
        group.leave()
    }
    group.enter()
    Fetcher.fetchResetCards { c, e in
        onceLock.lock(); cardsVar = c; cardsErrVar = e; onceLock.unlock()
        group.leave()
    }
    group.enter()
    Fetcher.fetchTiboResets { outcome in
        onceLock.lock(); tiboVar = outcome; onceLock.unlock()
        group.leave()
    }
    _ = group.wait(timeout: .now() + 60)
    onceLock.lock()
    let quota = quotaVar
    let scan = scanVar
    let cards = cardsVar
    let cardsErr = cardsErrVar
    let ext = extVar
    let tibo = tiboVar
    onceLock.unlock()

    if let q = quota {
        print("plan_type: \(q.planType ?? "?")")
        print("menubar: 5H \(Fmt.remainingPct(q.fiveHour?.usedPercent)) / 7D \(Fmt.remainingPct(q.sevenDay?.usedPercent))")
        func line(_ label: String, _ w: QuotaWindow?) -> String {
            guard let w = w else { return "\(label): --" }
            var s = "\(label): remaining=\(Fmt.remainingPct(w.usedPercent)) used=\(Int(w.usedPercent.rounded()))%"
            if let r = w.reset { s += " reset=\(Fmt.dayTime(r))" }
            return s
        }
        print(line("5h", q.fiveHour))
        print(line("7d", q.sevenDay))
        if let rc = q.resetCredits { print("reset credits: \(rc)") }
        if let e = q.error { print("quota error: \(e)") }
    } else {
        print("quota: no result (timeout)")
    }

    // 重置卡（额度重置卡）：每张有效卡的过期时间（本地时区）
    if let cs = cards {
        print("reset cards: \(cs.count) valid")
        for c in cs { print("  \(c.name) · \(Fmt.expires(c.expires)) 过期") }
    }
    if let e = cardsErr { print("reset cards error: \(e)") }

    // Tibo 重置动态（AIHOT 公开接口）：第三方资讯源，只打印结果、不计入退出码
    if let outcome = tibo {
        switch outcome {
        case .fresh(let events, let checkedAt):
            print("tibo resets: \(events.count) events (AIHOT 核验 \(checkedAt.map { Fmt.dayTime($0) } ?? "--"))")
            for row in TiboDisplay.rows(events, now: Date()) { print("  " + row.text) }
        case .unchanged:
            print("tibo resets: unchanged (304)")
        case .failure(let e):
            print("tibo error: \(e)")
        }
    } else {
        print("tibo: no result (timeout)")
    }

    if let s = scan {
        func t(_ x: TokenScanner.Stats) -> String {
            "total=\(Fmt.tokensAbbr(x.total)) input=\(Fmt.tokensAbbr(x.input))"
                + " output=\(Fmt.tokensAbbr(x.output)) files=\(x.files)"
        }
        print("tokens today: \(t(s.today))")
        print("tokens 7d:   \(t(s.seven))")
        print("tokens 30d:  \(t(s.thirty))")
        if let e = s.error { print("tokens error: \(e)") }
    } else {
        print("tokens: no result (timeout)")
    }

    // 外部用量（OpenAI 模型 · 非 Codex CLI）：纯本地扫描，只打印、不计入退出码
    if let e = ext {
        func t(_ x: ExternalTokenScanner.Stats) -> String {
            "total=\(Fmt.tokensAbbr(x.total)) input=\(Fmt.tokensAbbr(x.input))"
                + " output=\(Fmt.tokensAbbr(x.output))"
        }
        print("external today: \(t(e.today))")
        print("external 7d:    \(t(e.seven))")
        print("external 30d:   \(t(e.thirty))")
    } else {
        print("external: no result (timeout)")
    }

    let ok = quota != nil && quota?.error == nil
        && (quota?.fiveHour != nil || quota?.sevenDay != nil)
        && scan != nil && scan?.error == nil
    exit(ok ? 0 : 1)
}

if CommandLine.arguments.contains("--official-usage-check") {
    switch OfficialUsageReader.read(expected: CodexAuth.load()) {
    case .success(let snapshot):
        let codex = TokenScanner.scan()
        let external = ExternalTokenScanner.scan()
        let fill = LocalUsageMerge.combine(codex.error == nil ? codex.today : nil,
                                           external.error == nil ? external.today : nil)?.total
        let comparison = UsageComparison.evaluate(snapshot: snapshot, now: Date(), todayFill: fill)
        print("official usage: success; dailyComparisonReady=\(comparison.0.value != .insufficient); weeklyComparisonReady=\(comparison.1.value != .insufficient) (values withheld)")
        exit(0)
    case .failure(let failure): print("official usage: \(failure)"); exit(1)
    }
}

if CommandLine.arguments.contains("--once") {
    onceMode()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
