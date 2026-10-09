import Cocoa
import Foundation
import SQLite3
import CoreFoundation
import Darwin

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
        try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
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
//   额度  GET https://chatgpt.com/backend-api/wham/usage（每 60s，Bearer 凭证来自 ~/.codex/auth.json）
//   充值卡 GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits（每 5 分钟，认证头同款）
//   Tibo 重置动态 GET https://aihot.news/api/v1/codex-resets/recent（每 5 分钟，AIHOT 公开接口，匿名只读不经凭据）
//   token 统计：本地增量扫描 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl（每 5 分钟）
//   外部用量：Codex CLI 之外消费 OpenAI 系模型（gpt* 等）的 token——本地增量扫描
//     ~/.proma（agent-sessions / sdk-config/sessions 两代目录均在写入且互不重复、
//     sdk-config/projects 为最早一代）与 ~/.claude/projects 的 Claude SDK 风格 JSONL，
//     加 ~/.hermes/state.db 的 session_model_usage 累计行快照差分（只读打开）
// 凭证红线：access_token / refresh_token / id_token 只存在于内存，绝不写入日志、
//   status.json、scan-state.json 或提交；~/.codex/ 只读，唯一例外是 401 刷新成功后
//   按 PLAN §2 原子写回 auth.json 本身。

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
                           idToken: id, email: id.flatMap(jwtEmail)))
    }

    static func sameAuth(_ a: Tokens, _ b: Tokens) -> Bool {
        a.accessToken == b.accessToken && a.refreshToken == b.refreshToken && a.idToken == b.idToken
    }

    /// Re-read and merge into the newest document. A Codex CLI rotation during refresh wins.
    static func writeBack(at path: String = authPath, expected: Tokens, accessToken: String,
                          refreshToken: String?, idToken: String?) throws -> (access: String, wrote: Bool) {
        guard let data = FileManager.default.contents(atPath: path),
              var obj = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              var tokens = obj["tokens"] as? [String: Any],
              let latestAccess = tokens["access_token"] as? String, !latestAccess.isEmpty else {
            throw NSError(domain: "CodexUsage.Auth", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "auth.json missing tokens.access_token"])
        }
        let latest = Tokens(accessToken: latestAccess,
                            refreshToken: tokens["refresh_token"] as? String,
                            idToken: tokens["id_token"] as? String,
                            email: (tokens["id_token"] as? String).flatMap(jwtEmail))
        guard sameAuth(expected, latest) else { return (latestAccess, false) }
        tokens["access_token"] = accessToken
        if let r = refreshToken, !r.isEmpty { tokens["refresh_token"] = r }
        if let i = idToken, !i.isEmpty { tokens["id_token"] = i }
        obj["tokens"] = tokens
        obj["last_refresh"] = Fmt.isoFrac.string(from: Date())
        let updated = try JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted, .sortedKeys])
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
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let profile = obj["https://api.openai.com/profile"] as? [String: Any],
              let email = profile["email"] as? String, !email.isEmpty else {
            return nil
        }
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
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    var planType: String?
    var resetCredits: Int?
    var email: String?
    var fiveHourError: String?
    var sevenDayError: String?
    var error: String?
}

/// 充值卡（官方名：额度重置卡）明细端点返回的一张有效卡
struct ResetCard {
    var expires: Date    // 过期时间（expires_at）
    var name: String     // 展示名：title 含 "Full reset" → "全额重置卡"，否则用原文
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
    var estimateThrough: Date?  // 预估窗口结束时间（用于「窗口已过，待确认」标注）
    var occurredAt: Date?       // confirmedAt ?? updatedAt ?? createdAt
    var link: String            // 点击跳转：最新原帖 URL，缺省落 AIHOT 事件页
}

/// fetchTiboResets 的三态结果：200 新内容 / 304 内容未变（服务端自证数据仍有效）/ 失败
enum TiboFetchOutcome {
    case fresh([TiboEvent], checkedAt: Date?)
    case unchanged
    case failure(String)
}

struct UsageData {
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
    var extToday: ExternalTokenScanner.Stats?    // 外部用量（OpenAI 模型 · 非 Codex CLI）
    var ext7d: ExternalTokenScanner.Stats?
    var ext30d: ExternalTokenScanner.Stats?
    var quotaError: String?
    var tokensError: String?
    var fiveHourError: String?
    var sevenDayError: String?
    var updatedAt: Date = Date()
}

enum QuotaMerge {
    static func preferred(_ fresh: QuotaWindow?, old: QuotaWindow?) -> QuotaWindow? {
        fresh ?? old
    }
}

// MARK: - 额度接口（wham/usage）+ 401 兜底刷新
//
// 实测（2026-09-26）返回旧格式 rate_limit.primary_window / secondary_window，
// 新格式 usage.limits[] 也一并兼容（与 CodexMeter 的 quota.ts 一致；同 code 新格式优先）。
// reset_at 兼容 epoch 秒 / epoch 毫秒（>10^10）/ ISO8601 字符串 / 缺失（用 reset_after_seconds 兜底）。
// 401 时才尝试刷新（距上次刷新尝试 >5 分钟，防刷新风暴）：POST auth.openai.com/oauth/token，
// 成功后原子写回 auth.json 并用新凭证重试一次额度请求。
// 充值卡明细另走 GET wham/rate-limit-reset-credits（认证头完全同款；401 不做兜底刷新，
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
    private static var lastRefreshAttempt: Date?

    // Tibo 动态（AIHOT）：上次响应的 ETag，带 If-None-Match 轮询（接口要求同端点 ≥60s 间隔，5 分钟周期满足）
    private static let tiboLock = NSLock()
    private static var tiboETag: String?

    static func fetchQuota(completion: @escaping (QuotaData) -> Void) {
        guard let auth = CodexAuth.load() else {
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
                    guard refreshErr == nil, let fresh = CodexAuth.load() else {
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

    /// 认证 GET（额度与充值卡明细共用，header 与 wham/usage 完全同款）
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
        if let last = lastRefreshAttempt, now.timeIntervalSince(last) < refreshMinInterval {
            refreshLock.unlock()
            completion("刷新冷却中，5 分钟内已尝试过"); return
        }
        lastRefreshAttempt = now
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
        var errors = ["5h": "missing or invalid 5H used_percent", "7d": "missing or invalid 7D used_percent"]

        // 旧格式（当前实际返回）：rate_limit.primary_window → 5h，secondary_window → 7d，
        // used_percent 直接是已用百分比；limit_window_seconds 用于校验窗口类型
        if let rl = obj["rate_limit"] as? [String: Any] {
            for (key, fallback) in [("primary_window", "5h"), ("secondary_window", "7d")] {
                guard let w = rl[key] as? [String: Any] else { continue }
                let seconds = CodexNumber.finite(w["limit_window_seconds"]) ?? 0
                var code = fallback
                if abs(seconds - 18000) <= 60 { code = "5h" }
                else if abs(seconds - 604800) <= 3600 { code = "7d" }
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

        if let v = byCode["5h"] { out.fiveHour = QuotaWindow(usedPercent: v.used, reset: v.reset) }
        else { out.fiveHourError = errors["5h"] }
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

    /// 充值卡（额度重置卡）明细：GET wham/rate-limit-reset-credits（认证头与 wham/usage 同款）。
    /// 401 不做兜底刷新（避免新增写 auth.json 的路径），失败由调用方降级展示。
    static func fetchResetCards(completion: @escaping ([ResetCard]?, String?) -> Void) {
        guard let auth = CodexAuth.load() else {
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
            cards.append(ResetCard(expires: exp, name: name))
        }
        return (cards.sorted { $0.expires < $1.expires }, nil)
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

    /// 解析（严格性对齐充值卡）：events 容器缺失/类型错 → 整体失败；单条缺 title/status
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
            let postLink = nonEmpty(((e["posts"] as? [[String: Any]])?.first)?["url"] as? String)
            events.append(TiboEvent(
                id: (e["id"] as? String) ?? "",
                type: (e["type"] as? String) ?? "",
                status: status,
                title: title,
                estimateLabel: nonEmpty(estimate?["label"] as? String),
                estimateThrough: estimate.flatMap { Fmt.parseDateValue($0["through"]) },
                occurredAt: Fmt.parseDateValue(e["confirmedAt"])
                    ?? Fmt.parseDateValue(e["updatedAt"])
                    ?? Fmt.parseDateValue(e["createdAt"]),
                link: postLink ?? nonEmpty(e["url"] as? String) ?? ""
            ))
        }
        return (events, Fmt.parseDateValue(obj["checkedAt"]), nil)
    }
}

// MARK: - Tibo 重置动态菜单区块（AIHOT codex-resets）

enum TiboDisplay {
    /// 区块行（纯函数，离线回归覆盖）：预告中（announced）全部在前——有预估窗口就只显示
    /// 「预估 <窗口文案>」（无预估时回退事件标题）；预估窗口已过但未确认 → 追加
    /// 「（窗口已过，待确认）」（schedule 不随时间自动完成）；已确认（confirmed）只展示
    /// 最近一条。空列表 → 占位行。
    static func rows(_ events: [TiboEvent], now: Date) -> [(text: String, link: String)] {
        guard !events.isEmpty else { return [("暂无重置动态", "")] }
        var out: [(text: String, link: String)] = []
        for e in events.filter({ $0.status == "announced" }).sorted(by: timeDesc) {
            var s = e.estimateLabel.map { "预估 \($0)" } ?? e.title
            if let through = e.estimateThrough, through < now { s += "（窗口已过，待确认）" }
            out.append((text: s, link: e.link))
        }
        if let latest = events.filter({ $0.status != "announced" }).sorted(by: timeDesc).first {
            let day = latest.occurredAt.map { Fmt.day($0) } ?? ""
            out.append((text: "✅ " + (day.isEmpty ? "" : day + " ") + latest.title, link: latest.link))
        }
        return out
    }

    private static func timeDesc(_ a: TiboEvent, _ b: TiboEvent) -> Bool {
        (a.occurredAt ?? .distantPast) > (b.occurredAt ?? .distantPast)
    }
}

// MARK: - 本地会话 token 统计（增量扫描 ~/.codex/sessions）
//
// 扫描 sessions/YYYY/MM/DD/rollout-*.jsonl，仅近 30 天的会话文件。
// 每个文件取最后一条 type=="event_msg" 且 payload.type=="token_count" 事件的
// payload.info.total_token_usage（会话累计值）：input_tokens / output_tokens / total_tokens。
// 会话日期 = 文件名前缀 rollout-YYYY-MM-DDTHH-MM-SS-（本地时区）。
// 增量策略：scan-state.json 记录每文件 {size, mtime, 当日聚合}；未变化文件只做一次 stat
// 沿用上次结果，变化的文件重读（只取最后一条，字节级反查避免逐行 JSON 解析），
// 已删除文件从索引剔除；31 天前的旧条目清理，保证状态文件不随历史无限增长。

enum TokenScanner {
    struct FileEntry: Codable {
        var size: Int64
        var mtime: Double
        var day: String       // 会话日期 yyyy-MM-dd（文件名前缀）
        var input: Double
        var output: Double
        var total: Double
    }
    struct State: Codable { var files: [String: FileEntry] = [:] }
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
    }

    static let sessionsRoot = NSHomeDirectory() + "/.codex/sessions"
    static let statePath = NSHomeDirectory()
        + "/Library/Application Support/CodexUsage/scan-state.json"
    private static let lock = NSLock()
    private static var cache: State?
    private static let dayFmt: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"   // 本地时区，与文件名日期口径一致
        return f
    }()

    static func scan() -> Result {
        lock.lock(); defer { lock.unlock() }
        var st = loadState()
        let now = Date()
        let todayKey = dayFmt.string(from: now)
        let cutoff7 = dayFmt.string(from: now.addingTimeInterval(-7 * 86400))
        let cutoff30 = dayFmt.string(from: now.addingTimeInterval(-30 * 86400))
        let cutoff31 = dayFmt.string(from: now.addingTimeInterval(-31 * 86400))

        var seen = Set<String>()
        var enumed = false
        if let enumm = FileManager.default.enumerator(
            at: URL(fileURLWithPath: sessionsRoot),
            includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]) {
            enumed = true
            for case let url as URL in enumm {
                let name = url.lastPathComponent
                guard name.hasPrefix("rollout-"), name.hasSuffix(".jsonl") else { continue }
                let path = url.path
                seen.insert(path)
                guard let day = dayFromFilename(name), day >= cutoff30 else { continue }
                guard let vals = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = vals.fileSize else { continue }
                let mtime = vals.contentModificationDate?.timeIntervalSince1970 ?? 0
                // 文件未变化：沿用上次结果（绝大多数文件走这里）
                if let e = st.files[path], e.size == Int64(size), e.mtime == mtime { continue }
                guard let data = FileManager.default.contents(atPath: path) else { continue }
                let u = lastTokenUsage(in: data) ?? (0.0, 0.0, 0.0)
                st.files[path] = FileEntry(size: Int64(size), mtime: mtime, day: day,
                                           input: u.0, output: u.1, total: u.2)
            }
        }
        if enumed {
            // 枚举成功才清理：目录临时不可用时保留旧索引，避免误清
            for path in Array(st.files.keys) where !seen.contains(path) {
                st.files.removeValue(forKey: path)     // 已删除文件：剔除其贡献
            }
            for path in Array(st.files.keys) where st.files[path]!.day < cutoff31 {
                st.files.removeValue(forKey: path)     // 31 天前旧条目：不再可能贡献窗口
            }
        }
        cache = st
        saveState(st)

        guard enumed else { return Result(error: "无法枚举 \(sessionsRoot)") }
        var r = Result()
        for e in st.files.values {
            if e.day == todayKey { add(&r.today, e) }
            if e.day >= cutoff7 { add(&r.seven, e) }
            if e.day >= cutoff30 { add(&r.thirty, e) }
        }
        return r
    }

    /// rollout-2026-09-26T19-35-37-<uuid>.jsonl → "2026-09-26"
    private static func dayFromFilename(_ name: String) -> String? {
        guard name.count >= 18 else { return nil }
        let day = String(name.dropFirst("rollout-".count).prefix(10))
        guard dayFmt.date(from: day) != nil else { return nil }
        return day
    }

    private static func add(_ s: inout Stats, _ e: FileEntry) {
        guard e.total > 0 else { return }   // 无 token_count 记录的空会话不计文件数（数值本就为 0）
        s.input += e.input; s.output += e.output; s.total += e.total; s.files += 1
    }

    /// 取文件中最后一条 token_count 的 total_token_usage。
    /// 字节级反查 "total_token_usage"（每条 token_count 事件必含该键），命中后展开所在行
    /// 再做 JSON 校验，避免逐行 JSON 解析大文件；校验不过则继续向前找。
    private static func lastTokenUsage(in data: Data) -> (Double, Double, Double)? {
        let needle = Data("\"total_token_usage\"".utf8)
        var searchEnd = data.endIndex
        while let r = data.range(of: needle, options: [.backwards],
                                 in: data.startIndex..<searchEnd) {
            defer { searchEnd = r.lowerBound }
            let lineStart = data[data.startIndex..<r.lowerBound]
                .lastIndex(of: UInt8(0x0A)).map { data.index(after: $0) }
                ?? data.startIndex
            let lineEnd = data[r.upperBound...].firstIndex(of: UInt8(0x0A))
                ?? data.endIndex
            let line = data.subdata(in: lineStart..<lineEnd)
            guard let obj = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  obj["type"] as? String == "event_msg",
                  let payload = obj["payload"] as? [String: Any],
                  payload["type"] as? String == "token_count",
                  let info = payload["info"] as? [String: Any],
                  let usage = info["total_token_usage"] as? [String: Any] else {
                continue
            }
            let i = (usage["input_tokens"] as? NSNumber)?.doubleValue ?? 0
            let o = (usage["output_tokens"] as? NSNumber)?.doubleValue ?? 0
            let t = (usage["total_tokens"] as? NSNumber)?.doubleValue ?? 0
            return (i, o, t)
        }
        return nil
    }

    private static func loadState() -> State {
        if let s = cache { return s }
        if let data = FileManager.default.contents(atPath: statePath),
           let s = try? JSONDecoder().decode(State.self, from: data) {
            cache = s
            return s
        }
        let s = State()
        cache = s
        return s
    }

    private static func saveState(_ s: State) {
        guard let data = try? JSONEncoder().encode(s) else { return }
        try? FileManager.default.createDirectory(
            atPath: (statePath as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try? data.write(to: URL(fileURLWithPath: statePath), options: [.atomic])
    }
}

// MARK: - 外部用量（OpenAI 模型 · 非 Codex CLI，本地扫描）
//
// 统计 Codex CLI 之外消费 OpenAI 系模型的 token，两个来源（与 KimiUsage 的
// 「API 客户端」同构，参考其 TokenAggregator）：
//   1) Claude SDK 风格 JSONL：Proma（agent-sessions 与 sdk-config/sessions 两代目录
//      2026-10 实测均在写入且内容零重复，sdk-config/projects 为最早一代）+
//      ~/.claude/projects（Claude Code 本机，可经 ccswitch/Proma 接 OpenAI 模型）。
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
    }
    struct Result {
        var today = Stats()
        var seven = Stats()
        var thirty = Stats()
    }

    /// 按文件增量扫描状态：offset 为已消费字节数，days 为按日聚合 [input, output]
    struct FileState: Codable {
        var offset: UInt64 = 0
        var days: [String: [Double]] = [:]
    }
    /// hermes 快照：rows 存上次各累计行的值，days 存按 last_seen 归日的差分历史
    struct HermesState: Codable {
        var rows: [String: [Double]] = [:]
        var days: [String: [Double]] = [:]
    }
    struct State: Codable {
        var files: [String: FileState] = [:]
        var hermes: HermesState?
    }

    static let fileRoots = [
        NSHomeDirectory() + "/.proma/agent-sessions",
        NSHomeDirectory() + "/.proma/sdk-config/sessions",
        NSHomeDirectory() + "/.proma/sdk-config/projects",
        NSHomeDirectory() + "/.claude/projects",
    ]
    static let hermesDBPath = NSHomeDirectory() + "/.hermes/state.db"
    static let defaultStatePath = NSHomeDirectory()
        + "/Library/Application Support/CodexUsage/external-scan-state.json"

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
                     now: Date = Date()) -> Result {
        var st = loadState(at: statePath)
        let cutoff = now.addingTimeInterval(-retainSeconds)
        let cutoffKey = dayFmt.string(from: cutoff)
        scanFiles(roots: roots, cutoff: cutoff, cutoffKey: cutoffKey, into: &st)
        if let db = hermesDB {
            scanHermes(path: db, cutoffKey: cutoffKey, into: &st)
        }
        saveState(st, at: statePath)
        return buckets(st, now: now)
    }

    /// 全解析符号链接的绝对路径（realpath(3)）；路径不存在时原样返回
    private static func realPath(_ p: String) -> String {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        guard realpath(p, &buf) != nil else { return p }
        return String(cString: buf)
    }

    /// 增量扫描 roots 下的 jsonl：未变化文件只 stat，追加文件只读新增字节；
    /// 已被删除的文件从状态中剔除（枚举失败的 root 不动，避免目录临时不可用时误清）
    private static func scanFiles(roots: [String], cutoff: Date, cutoffKey: String,
                                  into st: inout State) {
        var seen = Set<String>()
        var enumedRoots: [String] = []

        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: URL(fileURLWithPath: root),
                includingPropertiesForKeys: [.fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles])
            else { continue }
            // 枚举器产出的 url.path 是 realpath 形式（/var → /private/var，URL 的
            // resolvingSymlinksInPath 不解析根级符号链接），前缀清理必须同口径，
            // 否则永不匹配、已删文件清不掉
            enumedRoots.append(realPath(root))

            for case let url as URL in enumerator where url.pathExtension == "jsonl" {
                let path = url.path
                seen.insert(path)
                guard let vals = try? url.resourceValues(
                        forKeys: [.fileSizeKey, .contentModificationDateKey]),
                      let size = vals.fileSize
                else { continue }
                let sizeU = UInt64(size)
                var fs = st.files[path] ?? FileState()
                // 文件只增不改：大小未变直接跳过（绝大多数文件走这里）
                if fs.offset == sizeU { st.files[path] = fs; continue }
                // 首次见到且 31 天未修改：旧内容不可能贡献近 30 天数据，记录大小后跳过
                if fs.offset == 0, fs.days.isEmpty,
                   let mtime = vals.contentModificationDate, mtime < cutoff {
                    fs.offset = sizeU; st.files[path] = fs; continue
                }
                // 截断/轮换：该文件的旧聚合已不可信，清零重扫
                if sizeU < fs.offset { fs = FileState() }

                guard let fh = try? FileHandle(forReadingFrom: url) else { continue }
                fh.seek(toFileOffset: fs.offset)
                let data = fh.readDataToEndOfFile()
                try? fh.close()
                // 只消费到最后一个完整换行：正在被写入的残缺行留给下次
                guard let lastNL = data.lastIndex(of: UInt8(ascii: "\n")) else { continue }
                let consumed = fs.offset + UInt64(lastNL + 1)
                if let text = String(data: data[..<lastNL], encoding: .utf8) {
                    parseLines(text, cutoffKey: cutoffKey, into: &fs)
                }
                fs.offset = consumed
                fs.days = fs.days.filter { $0.key >= cutoffKey }
                st.files[path] = fs
            }
        }

        // 先快照再删：迭代中变更字典可能跳过条目（TokenScanner 同款写法）
        let vanished = st.files.keys.filter { path in
            !seen.contains(path) && enumedRoots.contains(where: { path.hasPrefix($0 + "/") })
        }
        for path in vanished {
            st.files.removeValue(forKey: path)
        }
    }

    /// 解析一批完整行，把 OpenAI 系模型的 usage 按日累加进 days。
    /// 时间字段：_createdAt(ms, Proma) / timestamp(ISO8601, Claude SDK) / time(ms, 兜底)；
    /// usage 位置：event.usage / 顶层 usage / message.usage（与 KimiUsage 同序）；
    /// input 含 cache read/write（与 hermes 来源口径一致）。
    static func parseLines(_ text: String, cutoffKey: String, into st: inout FileState) {
        for line in text.split(separator: "\n", omittingEmptySubsequences: true)
        where line.contains("\"usage\"") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Proma result 行的 modelUsage / 顶层 usage 是全会话累计汇总，
            // 逐条 assistant 行已含每次调用，跳过汇总行避免双算
            if obj["modelUsage"] != nil { continue }
            let t: Date
            if let ms = CodexNumber.finite(obj["_createdAt"]) {
                t = Date(timeIntervalSince1970: ms / 1000)
            } else if let ts = Fmt.iso(obj["timestamp"] as? String) {
                t = ts
            } else if let ms = CodexNumber.finite(obj["time"]) {
                t = Date(timeIntervalSince1970: ms / 1000)
            } else { continue }
            let usage = (obj["event"] as? [String: Any])?["usage"] as? [String: Any]
                ?? obj["usage"] as? [String: Any]
                ?? (obj["message"] as? [String: Any])?["usage"] as? [String: Any]
            guard let usage = usage else { continue }
            let model = (obj["message"] as? [String: Any])?["model"] as? String
                ?? obj["model"] as? String
            guard isOpenAIModel(model) else { continue }
            var input: Double = 0
            for k in ["input_tokens", "cache_read_input_tokens", "cache_creation_input_tokens",
                      "input", "cacheRead", "cacheWrite"] {
                if let v = CodexNumber.finite(usage[k]) { input += v }
            }
            var output: Double = 0
            for k in ["output", "output_tokens"] {
                if let v = CodexNumber.finite(usage[k]) { output += v }
            }
            let dayKey = dayFmt.string(from: t)
            if dayKey >= cutoffKey {
                var day = st.days[dayKey] ?? [0, 0]
                day[0] += input
                day[1] += output
                st.days[dayKey] = day
            }
        }
    }

    /// hermes 用量库（sqlite，只读打开，绝不写入）。累计行与上次快照做差，
    /// delta 按 last_seen 归日；计数变小说明上游重置，rebase 不倒扣。
    private static func scanHermes(path: String, cutoffKey: String, into st: inout State) {
        var db: OpaquePointer?
        guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK, let db = db
        else { _ = db.map { sqlite3_close($0) }; return }
        defer { sqlite3_close(db) }
        // 行身份键与 KimiUsage 一致：同一 (session,model) 可因 task/billing 拆成多行
        let sql = """
            SELECT session_id, model, billing_provider, billing_base_url, billing_mode, task,
                   input_tokens, output_tokens, cache_read_tokens, cache_write_tokens, last_seen
            FROM session_model_usage
            """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var hs = st.hermes ?? HermesState()
        var alive = Set<String>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            func col(_ i: Int32) -> String {
                sqlite3_column_text(stmt, i).map { String(cString: $0) } ?? ""
            }
            let model = col(1)
            guard isOpenAIModel(model) else { continue }
            let key = (0...5).map { col(Int32($0)) }.joined(separator: "|")
            alive.insert(key)
            // 与文件来源口径一致：input 含 cache read/write
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
            }
        }
        // 会话被 hermes 删除（ON DELETE CASCADE）的行：移出快照，停止差分
        hs.rows = hs.rows.filter { alive.contains($0.key) }
        hs.days = hs.days.filter { $0.key >= cutoffKey }
        st.hermes = hs
    }

    /// 按日聚合 → 今日/近7天/近30天（边界与 TokenScanner 一致：dayKey >= 起算日）
    private static func buckets(_ st: State, now: Date) -> Result {
        let todayKey = dayFmt.string(from: now)
        let d7Key = dayFmt.string(from: now.addingTimeInterval(-7 * 86400))
        let d30Key = dayFmt.string(from: now.addingTimeInterval(-30 * 86400))
        var allDays: [String: [Double]] = [:]
        for (_, f) in st.files {
            for (day, v) in f.days {
                var a = allDays[day] ?? [0, 0]
                a[0] += v[0]; a[1] += v[1]
                allDays[day] = a
            }
        }
        if let hd = st.hermes?.days {
            for (day, v) in hd {
                var a = allDays[day] ?? [0, 0]
                a[0] += v[0]; a[1] += v[1]
                allDays[day] = a
            }
        }
        var r = Result()
        for (day, v) in allDays where day >= d30Key {
            r.thirty.input += v[0]; r.thirty.output += v[1]
            if day >= d7Key { r.seven.input += v[0]; r.seven.output += v[1] }
            if day >= todayKey { r.today.input += v[0]; r.today.output += v[1] }
        }
        return r
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
        try? FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        // 与 AtomicJSONFile.replace 同思路：临时文件 + 原子 rename，避免半写状态
        let dir = (path as NSString).deletingLastPathComponent
        let tmp = dir + "/." + (path as NSString).lastPathComponent + ".tmp"
        if (try? data.write(to: URL(fileURLWithPath: tmp), options: [.atomic])) != nil {
            _ = try? FileManager.default.replaceItemAt(
                URL(fileURLWithPath: path), withItemAt: URL(fileURLWithPath: tmp))
        }
    }
}

// MARK: - 菜单栏堆叠两行文字渲染（与 GlmUsage 同款）

enum StackImage {
    static func make(line1: String, line2: String) -> NSImage {
        let font = NSFont.monospacedDigitSystemFont(ofSize: 9.0, weight: .semibold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: NSColor.black
        ]
        let s1 = NSAttributedString(string: line1, attributes: attrs)
        let s2 = NSAttributedString(string: line2, attributes: attrs)
        let w = max(ceil(s1.size().width), ceil(s2.size().width)) + 2
        let img = NSImage(size: NSSize(width: w, height: 21), flipped: false) { _ in
            s1.draw(at: NSPoint(x: 1, y: 10.5))
            s2.draw(at: NSPoint(x: 1, y: 0.5))
            return true
        }
        img.isTemplate = true   // 自动适配深色/浅色菜单栏
        return img
    }
}

// MARK: - 格式化

enum Fmt {
    /// 剩余百分比（整数，100 − used_percent，夹在 0-100）
    static func remainingPct(_ usedPercent: Double?) -> String {
        guard let u = usedPercent else { return "--" }
        let r = Int((100 - u).rounded())
        return "\(max(0, min(100, r)))%"
    }
    static func remainingInt(_ w: QuotaWindow?) -> Int {
        guard let u = w?.usedPercent else { return -1 }
        return max(0, min(100, Int((100 - u).rounded())))
    }
    static func time(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "HH:mm"
        return f.string(from: d)
    }
    static func dayTime(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd HH:mm"
        return f.string(from: d)
    }
    static func day(_ d: Date?) -> String {
        guard let d = d else { return "" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        f.dateFormat = "MM-dd"
        return f.string(from: d)
    }
    /// 充值卡到期提示（本地时区）：今天内 → "今天 HH:mm"；明天 → "明天 HH:mm"；否则完整日期
    static func expires(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "zh_CN")
        let cal = Calendar.current
        if cal.isDateInToday(d) {
            f.dateFormat = "'今天' HH:mm"
        } else if cal.isDateInTomorrow(d) {
            f.dateFormat = "'明天' HH:mm"
        } else {
            f.dateFormat = "yyyy-MM-dd HH:mm"
        }
        return f.string(from: d)
    }
    /// token 数量缩写（B/M/K）：9,999 以内原样 / 123.4K / 1.23M / 1.23B（末尾多余的 .0 去掉）
    static func tokensAbbr(_ v: Double?) -> String {
        guard let v = v else { return "--" }
        if v >= 1_000_000_000 { return trim(v / 1_000_000_000, 2) + "B" }
        if v >= 1_000_000 { return trim(v / 1_000_000, 2) + "M" }
        if v >= 10_000 { return trim(v / 10_000, 1) + "K" }
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

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var usage = UsageData()
    private var cycle = 0
    private let refreshGate = RefreshGate()
    // token 扫描每 N 个刷新周期做一次（额度仍每 60s 刷新）
    private let tokenEveryCycles = 5
    // 数据过期阈值：额度 10 分钟、token 统计 30 分钟——超过该时长未成功刷新即在 UI 标 ⚠
    // （与 GlmUsage 的静默保留旧数据不同，这是刻意改进：过期数据必须可见）
    private let quotaStaleAfter: TimeInterval = 600
    private let tokensStaleAfter: TimeInterval = 1800
    private let tiboStaleAfter: TimeInterval = 1800
    private var fiveHourLastOK: Date?
    private var sevenDayLastOK: Date?
    private var tokensLastOK: Date?
    private var resetCardsLastOK: Date?
    private var tiboLastOK: Date?
    private var extLastOK: Date?
    private var lastAttemptAt = Date()
    private let launchAgentLabel = "com.local.codex-usage"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[CodexUsage] launched, creating status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        rebuildMenu()
        renderBar()
        refresh(tokens: true, manual: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.cycle += 1
            self.refresh(tokens: CodexRefreshSchedule.slowItemsDue(cycle: self.cycle,
                every: self.tokenEveryCycles, manual: false))
        }
        timer?.tolerance = 6
    }

    // 拉取数据：额度走网络（回调内含 401 兜底刷新），token 扫描与充值卡明细走每 5 分钟周期
    private func refresh(tokens: Bool, manual: Bool = false) {
        guard refreshGate.begin(manual: manual) else { return }
        performRefresh(tokens: tokens || manual)
    }

    private func performRefresh(tokens: Bool) {
        lastAttemptAt = Date()
        renderBar()
        rebuildMenu()
        let group = DispatchGroup()
        group.enter()
        Fetcher.fetchQuota { [weak self] r in
            DispatchQueue.main.async {
                self?.applyQuota(r)
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
            // 充值卡（额度重置卡）：与 token 统计同周期；失败不触发额度 ⚠ 过期标注
            group.enter()
            Fetcher.fetchResetCards { [weak self] cards, err in
                DispatchQueue.main.async {
                    self?.applyResetCards(cards, err)
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
            if self.refreshGate.finish() { self.performRefresh(tokens: true) }
        }
    }

    // 本次新拉到的值非 nil 才算成功、才推进 lastOK；失败时保留旧数据 + 错误行
    private func applyQuota(_ r: QuotaData) {
        let now = Date()
        fiveHourLastOK = CodexFreshness.updated(fiveHourLastOK, succeeded: r.fiveHour != nil, at: now)
        sevenDayLastOK = CodexFreshness.updated(sevenDayLastOK, succeeded: r.sevenDay != nil, at: now)
        usage.fiveHour = QuotaMerge.preferred(r.fiveHour, old: usage.fiveHour)
        usage.sevenDay = QuotaMerge.preferred(r.sevenDay, old: usage.sevenDay)
        usage.planType = r.planType ?? usage.planType
        usage.resetCredits = r.resetCredits ?? usage.resetCredits
        usage.fiveHourError = r.fiveHour == nil ? (r.fiveHourError ?? r.error) : nil
        usage.sevenDayError = r.sevenDay == nil ? (r.sevenDayError ?? r.error) : nil
        usage.quotaError = r.error
        usage.email = r.email ?? usage.email
        usage.updatedAt = Date()
        renderBar()
        rebuildMenu()
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
        usage.updatedAt = Date()
        renderBar()
        rebuildMenu()
    }

    // 外部用量：纯本地扫描，无网络失败面，结果总是全量可信快照
    private func applyExternal(_ r: ExternalTokenScanner.Result) {
        extLastOK = CodexFreshness.updated(extLastOK, succeeded: true, at: Date())
        usage.extToday = r.today
        usage.ext7d = r.seven
        usage.ext30d = r.thirty
        usage.updatedAt = Date()
        renderBar()
        rebuildMenu()
    }

    // 充值卡：成功则更新并清错误；瞬时失败保留上次数据、仅记录错误
    // （有旧数据时菜单仍展示未过期的旧卡；卡数据状态与额度窗口互相独立）
    private func applyResetCards(_ cards: [ResetCard]?, _ err: String?) {
        let r = CodexFreshness.apply(fresh: cards, failure: err,
            old: usage.resetCards, oldLastOK: resetCardsLastOK, oldError: usage.resetCardsError, now: Date())
        usage.resetCards = r.value
        resetCardsLastOK = r.lastOK
        usage.resetCardsError = r.error
        usage.updatedAt = Date()
        renderBar()
        rebuildMenu()
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
        usage.updatedAt = Date()
        renderBar()
        rebuildMenu()
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
    private func renderBar() {
        let line1 = (fiveHourStale ? "⚠ " : "") + "5H \(Fmt.remainingPct(usage.fiveHour?.usedPercent))"
        let line2 = (sevenDayStale ? "⚠ " : "") + "7D \(Fmt.remainingPct(usage.sevenDay?.usedPercent))"
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = "Codex 用量 · 5H成功 \(fiveHourLastOK.map { Fmt.time($0) } ?? "--")"
            + " · 7D成功 \(sevenDayLastOK.map { Fmt.time($0) } ?? "--")"
            + " · Token 最后成功 \(tokensLastOK.map { Fmt.time($0) } ?? "--")"
            + " · 外部最后成功 \(extLastOK.map { Fmt.time($0) } ?? "--")"
            + " · 充值卡最后成功 \(resetCardsLastOK.map { Fmt.time($0) } ?? "--")"
            + " · Tibo 最后成功 \(tiboLastOK.map { Fmt.time($0) } ?? "--")"
        writeStatus(line1: line1, line2: line2)
    }

    // 自诊断：把渲染内容写到本地，便于排查（绝不写任何凭证值）
    private func writeStatus(line1: String, line2: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/CodexUsage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func iso(_ d: Date?) -> String { d.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
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
            "resetCardsLastSuccess": iso(resetCardsLastOK),
            "resetCardsStale": resetCardsStale,
            "fiveHourStale": fiveHourStale,
            "sevenDayStale": sevenDayStale,
            "tokensStale": tokensStale,
            "fiveHourError": usage.fiveHourError ?? "",
            "sevenDayError": usage.sevenDayError ?? "",
            "quotaError": usage.quotaError ?? "",
            "tokensError": usage.tokensError ?? "",
            "lastAttemptAt": iso(lastAttemptAt)
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: URL(fileURLWithPath: dir + "/status.json"))
        }
    }

    // 下拉面板（PLAN §4 自上而下）
    private func rebuildMenu() {
        let menu = NSMenu()

        func info(_ title: String) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
            item.isEnabled = false
            return item
        }

        menu.addItem(info("Codex 用量"
            + (usage.planType.map { "（\($0.uppercased()) 套餐）" } ?? "")))
        if let email = usage.email, !email.isEmpty {
            menu.addItem(info(email))
        }
        menu.addItem(.separator())

        func windowLine(_ label: String, _ w: QuotaWindow?, isFive: Bool) -> String {
            let last = isFive ? fiveHourLastOK : sevenDayLastOK
            let stale = isFive ? fiveHourStale : sevenDayStale
            let error = isFive ? usage.fiveHourError : usage.sevenDayError
            var s = "\(label)："
            if let w = w {
                s += "剩余 \(Fmt.remainingPct(w.usedPercent))"
                if let r = w.reset { s += "（重置 \(Fmt.dayTime(r))）" }
            } else { s += "暂无数据" }
            if stale { s += " · ⚠️ 已过期" }
            if let error = error { s += " · 刷新失败：\(error)" }
            if let last = last, stale || error != nil { s += " · 最后成功 \(Fmt.dayTime(last))" }
            return s
        }
        menu.addItem(info(windowLine("5 小时窗口", usage.fiveHour, isFive: true)))
        menu.addItem(info(windowLine("7 天窗口", usage.sevenDay, isFive: false)))

        // 充值卡（额度重置卡）：独立成区两侧加横条（沿用原"重置卡：×N"的分区）；
        // 有效卡按过期时间升序，≤72 小时临期加 ⚠️ 前缀（展示格式与 GlmUsage 逐行对齐）
        func cardLine(_ name: String, _ d: Date) -> String {
            let warn = d.timeIntervalSinceNow <= 72 * 3600
            return (warn ? "⚠️ " : "  ") + "\(name) · \(Fmt.expires(d)) 过期"
        }
        var cardLines: [String] = []
        if let storedCards = usage.resetCards {
            let cards = CodexFreshness.availableCards(storedCards, now: Date())
            if cards.isEmpty {
                cardLines = ["充值卡（额度重置）：暂无可用"]
            } else {
                cardLines = ["充值卡（额度重置）：×\(cards.count)"]
                cardLines += cards.map { cardLine($0.name, $0.expires) }
            }
        } else if let e = usage.resetCardsError {
            // 明细失败：wham/usage 的 available_count > 0 时兜底显示数量，否则整区报错
            if let n = usage.resetCredits, n > 0 {
                cardLines = ["充值卡（额度重置）：×\(n)（明细获取失败）"]
            } else {
                let short = e.count > 60 ? String(e.prefix(60)) + "…" : e
                cardLines = ["充值卡获取失败：\(short)（Codex 登录态可能过期，运行 codex login 后重试）"]
            }
        }
        if resetCardsStale {
            cardLines.append("⚠️ 充值卡数据已过期 · 最后成功 \(resetCardsLastOK.map { Fmt.dayTime($0) } ?? "--")")
        }
        if let e = usage.resetCardsError, usage.resetCards != nil {
            cardLines.append("充值卡刷新失败：\(e) · 最后成功 \(resetCardsLastOK.map { Fmt.dayTime($0) } ?? "--")")
        }
        if !cardLines.isEmpty {
            menu.addItem(.separator())
            for l in cardLines { menu.addItem(info(l)) }
        }
        menu.addItem(.separator())

        // Tibo 重置动态（数据源 AIHOT）：事件行点击跳最新原帖；预估窗口文案来自接口，
        // 语义是原帖预告的估计（时间经过不自动完成），因此呈现为「预估/待确认」而非倒计时
        var tiboItems: [NSMenuItem] = []
        if let events = usage.tiboEvents {
            tiboItems.append(info("Tibo 重置动态"))
            for row in TiboDisplay.rows(events, now: Date()) {
                let item = NSMenuItem(title: row.text, action: nil, keyEquivalent: "")
                if let url = URL(string: row.link) {
                    item.action = #selector(openLink(_:))
                    item.target = self
                    item.representedObject = url
                } else {
                    item.isEnabled = false
                }
                tiboItems.append(item)
            }
            if tiboStale {
                tiboItems.append(info("⚠️ Tibo 动态已过期 · 最后成功 \(tiboLastOK.map { Fmt.dayTime($0) } ?? "--")"))
            }
            if let e = usage.tiboError {
                tiboItems.append(info("Tibo 刷新失败：\(e) · 最后成功 \(tiboLastOK.map { Fmt.dayTime($0) } ?? "--")"))
            }
        } else if let e = usage.tiboError {
            let short = e.count > 60 ? String(e.prefix(60)) + "…" : e
            tiboItems.append(info("Tibo 重置动态获取失败：\(short)"))
        }
        if !tiboItems.isEmpty {
            for i in tiboItems { menu.addItem(i) }
            menu.addItem(.separator())
        }

        if usage.tokensToday == nil && usage.tokens7d == nil && usage.tokens30d == nil {
            menu.addItem(info("Token 用量：暂无数据"))
        } else {
            menu.addItem(info("Token 今天 \(Fmt.tokensAbbr(usage.tokensToday?.total))"
                + " · 7 天 \(Fmt.tokensAbbr(usage.tokens7d?.total))"
                + " · 30 天 \(Fmt.tokensAbbr(usage.tokens30d?.total))"))
            var tokenDetails: [(label: String, s: TokenScanner.Stats)] = []
            if let s = usage.tokensToday { tokenDetails.append(("今日", s)) }
            if let s = usage.tokens7d { tokenDetails.append(("近 7 天", s)) }
            if let s = usage.tokens30d { tokenDetails.append(("近 30 天", s)) }
            for (i, d) in tokenDetails.enumerated() {
                let branch = i < tokenDetails.count - 1 ? "├" : "└"
                menu.addItem(info("  \(branch) \(d.label)：input \(Fmt.tokensAbbr(d.s.input))"
                    + " / output \(Fmt.tokensAbbr(d.s.output))"))
            }
        }

        if tokensStale {
            menu.addItem(info("⚠ tokens 过期（最后成功 \(tokensLastOK.map { Fmt.dayTime($0) } ?? "--")）"))
        }
        if let e = usage.tokensError { menu.addItem(info("Token 统计失败：\(e)")) }

        // 外部用量（OpenAI 模型 · 非 Codex CLI）：Proma / Claude Code / hermes 里的
        // gpt* 等 OpenAI 系模型 token，与上方 Codex CLI 本机会话口径互补、不混算
        if usage.extToday != nil || usage.ext7d != nil || usage.ext30d != nil {
            menu.addItem(info("外部用量（非Codex）今天 \(Fmt.tokensAbbr(usage.extToday?.total))"
                + " · 7 天 \(Fmt.tokensAbbr(usage.ext7d?.total))"
                + " · 30 天 \(Fmt.tokensAbbr(usage.ext30d?.total))"))
            var extDetails: [(label: String, s: ExternalTokenScanner.Stats)] = []
            if let s = usage.extToday { extDetails.append(("今日", s)) }
            if let s = usage.ext7d { extDetails.append(("近 7 天", s)) }
            if let s = usage.ext30d { extDetails.append(("近 30 天", s)) }
            for (i, d) in extDetails.enumerated() {
                let branch = i < extDetails.count - 1 ? "├" : "└"
                menu.addItem(info("  \(branch) \(d.label)：input \(Fmt.tokensAbbr(d.s.input))"
                    + " / output \(Fmt.tokensAbbr(d.s.output))"))
            }
            if extStale {
                menu.addItem(info("⚠ 外部用量已过期（最后成功 \(extLastOK.map { Fmt.dayTime($0) } ?? "--")）"))
            }
        }

        if let e = usage.quotaError {
            menu.addItem(info("额度错误：\(e)"))
        }

        menu.addItem(.separator())
        menu.addItem(info("最近尝试刷新 \(Fmt.time(lastAttemptAt))"))
        menu.addItem(.separator())
        let refreshItem = NSMenuItem(title: "立即刷新", action: #selector(onRefresh), keyEquivalent: "r")
        refreshItem.target = self
        menu.addItem(refreshItem)

        let loginItem = NSMenuItem(title: "开机自启", action: #selector(onToggleLogin), keyEquivalent: "")
        loginItem.target = self
        loginItem.state = isLoginItemEnabled() ? .on : .off
        menu.addItem(loginItem)

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "退出", action: #selector(onQuit), keyEquivalent: "q")
        quit.target = self
        menu.addItem(quit)

        statusItem.menu = menu
    }

    @objc private func onRefresh() { refresh(tokens: true, manual: true) }

    @objc private func openLink(_ sender: NSMenuItem) {
        if let url = sender.representedObject as? URL { NSWorkspace.shared.open(url) }
    }

    // MARK: 开机自启（LaunchAgent，与 GlmUsage/KimiUsage 同款）

    private var launchAgentPath: String {
        NSHomeDirectory() + "/Library/LaunchAgents/\(launchAgentLabel).plist"
    }

    private func isLoginItemEnabled() -> Bool {
        FileManager.default.fileExists(atPath: launchAgentPath)
    }

    @objc private func onToggleLogin() {
        if isLoginItemEnabled() {
            try? FileManager.default.removeItem(atPath: launchAgentPath)
        } else {
            let exec = Bundle.main.executablePath ?? ""
            let plist = """
            <?xml version="1.0" encoding="UTF-8"?>
            <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
            <plist version="1.0">
            <dict>
                <key>Label</key><string>\(launchAgentLabel)</string>
                <key>ProgramArguments</key>
                <array><string>\(exec)</string></array>
                <key>RunAtLoad</key><true/>
                <key>KeepAlive</key><true/>
            </dict>
            </plist>
            """
            try? plist.write(toFile: launchAgentPath, atomically: true, encoding: .utf8)
        }
        rebuildMenu()
    }

    @objc private func onQuit() { NSApp.terminate(nil) }
}

// MARK: - 入口（支持 --once 命令行自检）

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
            let now = Date(timeIntervalSince1970: 1_800_000_000)

            try expect(CodexNumber.finite(Double.nan) == nil, "NaN accepted as a quota value")
            try expect(CodexNumber.finite(Double.infinity) == nil, "infinity accepted as a quota value")
            try expect(CodexNumber.finite(true) == nil, "boolean accepted as a quota value")
            try expect(CodexNumber.nonnegativeInteger(Double(Int.max)) == nil
                       && CodexNumber.nonnegativeInteger(1e100) == nil
                       && CodexNumber.nonnegativeInteger(1.5) == nil,
                       "out-of-range or fractional card count was accepted")
            try expect(CodexNumber.nonnegativeInteger(0) == 0,
                       "valid zero card count was rejected")

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
                       "60s/300s/manual refresh schedule is incorrect")

            let cardPayload: [String: Any] = ["credits": [
                ["status": "available", "expires_at": now.addingTimeInterval(3_600).timeIntervalSince1970,
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
                                  "through": "2026-09-30T03:00:00.000+08:00"],
                     "posts": [["url": "https://x.com/thsottiaux/status/2103963215885701493"]],
                     "url": "https://aihot.news/codex-reset"],
                    ["id": "t2", "type": "reset_credit", "status": "confirmed",
                     "title": "重置卡已发放",
                     "createdAt": "2026-09-26T08:07:13.000+08:00",
                     "confirmedAt": "2026-09-27T02:17:54.000+08:00",
                     "posts": [], "url": "https://aihot.news/codex-reset"],
                    ["id": "t3", "status": "announced"],   // 缺 title：单条脏数据，跳过
                    ["id": "t4", "type": "direct_reset", "status": "announced",
                     "title": "预告但未给窗口", "createdAt": "2026-09-20T00:00:00.000+08:00",
                     "posts": [], "url": "https://aihot.news/codex-reset"]
                ]
            ]
            let tiboParsed = Fetcher.parseTiboResets(tiboPayload)
            guard let tiboEvents = tiboParsed.events else {
                throw Failure(description: "valid tibo payload failed: \(tiboParsed.error ?? "unknown")")
            }
            try expect(tiboEvents.count == 3, "malformed tibo event was not skipped")
            try expect(tiboEvents[0].estimateLabel?.contains("9月29日") == true
                       && tiboEvents[0].estimateThrough != nil,
                       "tibo estimate window did not parse")
            try expect(tiboEvents[0].link.hasPrefix("https://x.com/"),
                       "tibo post link did not win over page url")
            try expect(tiboEvents[1].occurredAt == Fmt.isoFrac.date(from: "2026-09-27T02:17:54.000+08:00"),
                       "tibo confirmedAt did not win over createdAt")
            try expect(tiboEvents[1].link == "https://aihot.news/codex-reset",
                       "tibo page url fallback was lost")
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

            // 展示行：预告行只显示「预估 <窗口>」（无预估回退标题，不带事件标题）；
            // 窗口未过不标「待确认」、已过必须标；已确认取最近一条
            guard let duringWindow = Fmt.isoFrac.date(from: "2026-09-29T12:00:00.000+08:00"),
                  let afterWindow = Fmt.isoFrac.date(from: "2026-10-01T12:00:00.000+08:00") else {
                throw Failure(description: "tibo display fixture dates failed to parse")
            }
            let rowsDuring = TiboDisplay.rows(tiboEvents, now: duringWindow)
            try expect(rowsDuring.count == 3
                       && rowsDuring[0].text == "预估 北京时间 9月29日 03:00–9月30日 03:00",
                       "announced tibo row with estimate did not render estimate-only text")
            try expect(!rowsDuring[0].text.contains("Tibo 预告将重置额度"),
                       "announced tibo row still carried the event title")
            try expect(rowsDuring[1].text == "预告但未给窗口",
                       "announced tibo row without estimate did not fall back to title")
            try expect(!rowsDuring[0].text.contains("待确认"),
                       "pending marker shown while estimate window still open")
            try expect(rowsDuring[2].text.hasPrefix("✅") && rowsDuring[2].text.contains("重置卡已发放"),
                       "confirmed tibo row missing marker or title")
            let rowsAfter = TiboDisplay.rows(tiboEvents, now: afterWindow)
            try expect(rowsAfter[0].text.contains("窗口已过，待确认"),
                       "expired tibo estimate window was not marked pending")
            try expect(TiboDisplay.rows([], now: duringWindow).first?.text == "暂无重置动态",
                       "empty tibo events did not render the placeholder")

            // 三态合并：fresh 推进成功时间；unchanged(304) 保留旧值但推进成功时间；failure 保留旧值旧时间
            let tiboOldOK = now.addingTimeInterval(-1_000)
            let tiboFreshR = TiboFreshness.apply(outcome: .fresh(tiboEvents, checkedAt: tiboParsed.checkedAt),
                old: nil, oldCheckedAt: nil, oldLastOK: nil, oldError: nil, now: now)
            try expect(tiboFreshR.value?.count == 3 && tiboFreshR.lastOK == now && tiboFreshR.error == nil,
                       "fresh tibo outcome did not advance state")
            let tiboUnchangedR = TiboFreshness.apply(outcome: .unchanged,
                old: tiboEvents, oldCheckedAt: tiboParsed.checkedAt, oldLastOK: tiboOldOK, oldError: nil, now: now)
            try expect(tiboUnchangedR.value?.count == 3 && tiboUnchangedR.lastOK == now
                       && tiboUnchangedR.checkedAt == tiboParsed.checkedAt,
                       "304 tibo outcome cleared data or did not advance last-success")
            let tiboFailR = TiboFreshness.apply(outcome: .failure("HTTP 500"),
                old: tiboEvents, oldCheckedAt: nil, oldLastOK: tiboOldOK, oldError: nil, now: now)
            try expect(tiboFailR.value?.count == 3 && tiboFailR.lastOK == tiboOldOK && tiboFailR.error == "HTTP 500",
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

            // 行解析：_createdAt(ms)/timestamp(ISO8601) 双格式、cache 计入 input、
            // 非 OpenAI 模型剔除、modelUsage 汇总行跳过、缺时间/坏 usage 跳过。
            // 基准取「本地正午」，任何时区下 ±数小时偏移都不跨日。
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
            try expect(fs.days.count == 1 && fs.days[extDayKey] == [370, 70],
                       "external parse did not aggregate OpenAI usage only (got \(fs.days))")

            // 增量扫描端到端（临时 roots + 临时状态文件，不碰真实 ~/.proma / ~/.claude）：
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
                 extLine("gpt-5.6-sol", extBase.addingTimeInterval(-6 * 86400), inTok: 1000, outTok: 100)]
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
                       "external 7d window wrong (got \(s1.seven.input))")
            try expect(s1.thirty.input == 11100 && s1.thirty.output == 1110,
                       "external 30d window wrong (old-file skip or nested enumeration failed)")

            let handleA = try FileHandle(forWritingTo: URL(fileURLWithPath: fileA))
            _ = try handleA.seekToEnd()
            handleA.write(Data(extLine("gpt-5.6-sol", extBase, inTok: 100, outTok: 10)
                .appending("\n").utf8))
            try handleA.close()
            let s2 = ExternalTokenScanner.scan(roots: extRoots, hermesDB: nil,
                                               statePath: extStatePath, now: extBase)
            try expect(s2.today.input == 200 && s2.seven.input == 1200 && s2.thirty.input == 11200,
                       "external incremental append was double-counted or missed")

            try FileManager.default.removeItem(atPath: fileB)
            let s3 = ExternalTokenScanner.scan(roots: extRoots, hermesDB: nil,
                                               statePath: extStatePath, now: extBase)
            try expect(s3.thirty.input == 1200,
                       "deleted external session file still contributed to the 30d window "
                       + "(got \(s3.thirty.input), state persisted: \(FileManager.default.contents(atPath: extStatePath) != nil))")

            try extLine("gpt-5.6-sol", extBase, inTok: 30, outTok: 3).appending("\n")
                .write(toFile: fileA, atomically: true, encoding: .utf8)
            let s4 = ExternalTokenScanner.scan(roots: extRoots, hermesDB: nil,
                                               statePath: extStatePath, now: extBase)
            try expect(s4.today.input == 30 && s4.seven.input == 30 && s4.thirty.input == 30,
                       "truncated external file did not rebase its aggregation")

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
            try hexec("UPDATE session_model_usage SET input_tokens = 2500, last_seen = \(extBase.timeIntervalSince1970 - 1800) WHERE session_id = 's1'")
            let h2 = ExternalTokenScanner.scan(roots: [], hermesDB: hdbPath,
                                               statePath: hStatePath, now: extBase)
            // 回填 1000（base-3600）+ 差分 1500（base-1800）同属今天 → 2500
            try expect(h2.today.input == 2500 && h2.today.output == 100,
                       "hermes cumulative diff did not land in the right day bucket (got \(h2.today.input))")
            try hexec("UPDATE session_model_usage SET input_tokens = 10 WHERE session_id = 's1'")
            let h3 = ExternalTokenScanner.scan(roots: [], hermesDB: hdbPath,
                                               statePath: hStatePath, now: extBase)
            try expect(h3.today.input == 2500 && h3.today.output == 100,
                       "hermes counter reset produced negative or inflated usage")
            try hexec("DELETE FROM session_model_usage WHERE session_id = 's1'")
            let h4 = ExternalTokenScanner.scan(roots: [], hermesDB: hdbPath,
                                               statePath: hStatePath, now: extBase)
            try expect(h4.today.input == 2500 && h4.thirty.input == 2500,
                       "deleted hermes row changed historical aggregation")

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

            print("CodexUsage --self-test: PASS (strict/partial quota parsing, independent freshness, card expiry, tibo reset parsing/display/merge, external usage model/parse/scan/hermes-diff, refresh gate/schedule, temp auth merge/permissions/failure)")
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

    // 充值卡（额度重置卡）：每张有效卡的过期时间（本地时区）
    if let cs = cards {
        print("reset cards: \(cs.count) valid")
        for c in cs { print("  \(c.name) · \(Fmt.expires(c.expires)) 过期") }
    }
    if let e = cardsErr { print("reset cards error: \(e)") }

    // Tibo 重置动态（AIHOT 公开接口）：第三方资讯源，只打印结果、不计入退出码
    if let outcome = tiboVar {
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

if CommandLine.arguments.contains("--once") {
    onceMode()
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)   // 不显示 Dock 图标
let delegate = AppDelegate()
app.delegate = delegate
app.run()
