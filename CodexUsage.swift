import Cocoa
import Foundation

// MARK: - CodexUsage：监控 OpenAI Codex 订阅（ChatGPT Plus 的 Codex 额度）的菜单栏工具
//
// 架构与同机 GlmUsage 完全同构（单文件 / 纯 Foundation + AppKit / 无外部依赖）。
// 数据源：
//   额度  GET https://chatgpt.com/backend-api/wham/usage（每 60s，Bearer 凭证来自 ~/.codex/auth.json）
//   充值卡 GET https://chatgpt.com/backend-api/wham/rate-limit-reset-credits（每 5 分钟，认证头同款）
//   token 统计：本地增量扫描 ~/.codex/sessions/YYYY/MM/DD/rollout-*.jsonl（每 5 分钟）
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
    /// tokens + 原始 JSON（401 刷新成功后写回时保留全部字段用），仅存活于内存
    struct Snapshot {
        var tokens: Tokens
        var raw: [String: Any]
    }

    static func load() -> Snapshot? {
        guard let data = FileManager.default.contents(atPath: authPath),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tokens = obj["tokens"] as? [String: Any],
              let access = tokens["access_token"] as? String, !access.isEmpty else {
            return nil
        }
        let refresh = tokens["refresh_token"] as? String
        let id = tokens["id_token"] as? String
        return Snapshot(
            tokens: Tokens(accessToken: access, refreshToken: refresh,
                           idToken: id, email: id.flatMap(jwtEmail)),
            raw: obj)
    }

    /// 401 刷新成功后原子写回：保留原 JSON 全部字段，仅更新 access/refresh/id_token
    /// （响应缺失则保留原值）与 last_refresh。原子写 = 先写同目录 .tmp 再 rename()。
    static func writeBack(raw: [String: Any], accessToken: String,
                          refreshToken: String?, idToken: String?) -> Bool {
        var obj = raw
        var tokens = (obj["tokens"] as? [String: Any]) ?? [:]
        tokens["access_token"] = accessToken
        if let r = refreshToken, !r.isEmpty { tokens["refresh_token"] = r }
        if let i = idToken, !i.isEmpty { tokens["id_token"] = i }
        obj["tokens"] = tokens
        obj["last_refresh"] = Fmt.isoFrac.string(from: Date())
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.prettyPrinted])
        else { return false }
        let tmp = authPath + ".tmp"
        // 保持原文件权限（凭证文件通常 0600），读取失败按 0600 兜底
        let perms = ((try? FileManager.default.attributesOfItem(atPath: authPath))?[.posixPermissions] as? NSNumber)
            ?? NSNumber(value: 0o600)
        guard FileManager.default.createFile(atPath: tmp, contents: data,
                                             attributes: [.posixPermissions: perms]) else {
            return false
        }
        if rename(tmp, authPath) != 0 {
            try? FileManager.default.removeItem(atPath: tmp)
            return false
        }
        return true
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
    var error: String?
}

/// 充值卡（官方名：额度重置卡）明细端点返回的一张有效卡
struct ResetCard {
    var expires: Date    // 过期时间（expires_at）
    var name: String     // 展示名：title 含 "Full reset" → "全额重置卡"，否则用原文
}

struct UsageData {
    var fiveHour: QuotaWindow?
    var sevenDay: QuotaWindow?
    var planType: String?
    var resetCredits: Int?          // wham/usage 的 available_count（明细失败时的兜底汇总）
    var resetCards: [ResetCard]?    // 明细端点的有效卡列表（nil = 未获取或本次失败）
    var resetCardsError: String?
    var email: String?
    var tokensToday: TokenScanner.Stats?
    var tokens7d: TokenScanner.Stats?
    var tokens30d: TokenScanner.Stats?
    var quotaError: String?
    var tokensError: String?
    var updatedAt: Date = Date()
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
    static let refreshURL = "https://auth.openai.com/oauth/token"
    // Codex CLI 公开 client_id（与官方 CLI 相同，非密钥）
    static let clientID = "app_EMoamEEZ73f0CkXaXp7hrann"
    static let refreshMinInterval: TimeInterval = 300

    private static let refreshLock = NSLock()
    private static var lastRefreshAttempt: Date?

    static func fetchQuota(completion: @escaping (QuotaData) -> Void) {
        guard let auth = CodexAuth.load() else {
            var e = QuotaData()
            e.error = "未找到 Codex 凭证（~/.codex/auth.json）"
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

    private static func finish(_ obj: [String: Any]?, status: Int?, err: String?,
                               email: String?) -> QuotaData {
        if status == 200, let obj = obj {
            return parseUsage(obj, now: Date(), email: email)
        }
        var e = QuotaData(email: email)
        if let err = err { e.error = err } else { e.error = "HTTP \(status ?? 0)" }
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
        refreshLock.lock()
        let now = Date()
        if let last = lastRefreshAttempt, now.timeIntervalSince(last) < refreshMinInterval {
            refreshLock.unlock()
            completion("刷新冷却中，5 分钟内已尝试过"); return
        }
        lastRefreshAttempt = now
        refreshLock.unlock()

        guard let rt = auth.tokens.refreshToken, !rt.isEmpty else {
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
            let ok = CodexAuth.writeBack(raw: auth.raw, accessToken: access,
                                         refreshToken: obj["refresh_token"] as? String,
                                         idToken: obj["id_token"] as? String)
            completion(ok ? nil : "写回 auth.json 失败")
        }.resume()
    }

    /// 兼容新旧两种额度格式；同一 code 新格式（usage.limits）优先
    private static func parseUsage(_ obj: [String: Any], now: Date, email: String?) -> QuotaData {
        var out = QuotaData(email: email)
        out.planType = (obj["plan_type"] as? String) ?? (obj["planType"] as? String)
        if let rc = (obj["rate_limit_reset_credits"] as? [String: Any])?["available_count"] as? NSNumber {
            out.resetCredits = rc.intValue
        }
        var byCode: [String: (used: Double, reset: Date?)] = [:]

        // 旧格式（当前实际返回）：rate_limit.primary_window → 5h，secondary_window → 7d，
        // used_percent 直接是已用百分比；limit_window_seconds 用于校验窗口类型
        if let rl = obj["rate_limit"] as? [String: Any] {
            for (key, fallback) in [("primary_window", "5h"), ("secondary_window", "7d")] {
                guard let w = rl[key] as? [String: Any] else { continue }
                let seconds = (w["limit_window_seconds"] as? NSNumber)?.doubleValue ?? 0
                var code = fallback
                if abs(seconds - 18000) <= 60 { code = "5h" }
                else if abs(seconds - 604800) <= 3600 { code = "7d" }
                let used = (w["used_percent"] as? NSNumber)?.doubleValue ?? 0
                byCode[code] = (used, resetDate(w, now: now))
            }
        }
        // 新格式：usage.limits[]，percentUsed = used/limit×100（同 code 覆盖旧格式）
        let usageNode = (obj["usage"] as? [String: Any]) ?? obj
        if let limits = usageNode["limits"] as? [[String: Any]] {
            for e in limits {
                guard let code = e["window"] as? String, code == "5h" || code == "7d" else { continue }
                let used = (e["used"] as? NSNumber)?.doubleValue ?? 0
                let limit = (e["limit"] as? NSNumber)?.doubleValue ?? 0
                guard limit > 0 else { continue }
                byCode[code] = (used / limit * 100, resetDate(e, now: now))
            }
        }

        if let v = byCode["5h"] { out.fiveHour = QuotaWindow(usedPercent: v.used, reset: v.reset) }
        if let v = byCode["7d"] { out.sevenDay = QuotaWindow(usedPercent: v.used, reset: v.reset) }
        if out.fiveHour == nil && out.sevenDay == nil { out.error = "unexpected payload" }
        return out
    }

    private static func resetDate(_ w: [String: Any], now: Date) -> Date? {
        if let d = Fmt.parseDateValue(w["reset_at"] ?? w["resetAt"] ?? w["resets_at"]) { return d }
        let after = ((w["reset_after_seconds"] as? NSNumber)
            ?? (w["reset_after"] as? NSNumber))?.doubleValue ?? 0
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
            completion(parseResetCards(obj, now: Date()), nil)
        }
    }

    /// 明细解析（与 CodexMeter parseResetCreditsPayload 口径一致）：容器字段兼容
    /// credits / reset_credits / resetCredits / data；有效卡 = status 为空或不在已失效
    /// 集合，且 expires_at > now；按过期时间升序；title 含 "Full reset" → "全额重置卡"。
    private static func parseResetCards(_ obj: [String: Any], now: Date) -> [ResetCard] {
        let invalid: Set<String> = ["redeemed", "used", "consumed", "expired", "unavailable"]
        let container = obj["credits"] ?? obj["reset_credits"] ?? obj["resetCredits"] ?? obj["data"]
        guard let list = container as? [[String: Any]] else { return [] }
        var cards: [ResetCard] = []
        for c in list {
            let status = ((c["status"] as? String) ?? "").lowercased()
            guard !invalid.contains(status) else { continue }
            guard let exp = Fmt.parseDateValue(c["expires_at"] ?? c["expiresAt"]),
                  exp > now else { continue }
            let title = (c["title"] as? String) ?? ""
            let name = title.contains("Full reset") ? "全额重置卡"
                : (title.isEmpty ? "额度重置卡" : title)
            cards.append(ResetCard(expires: exp, name: name))
        }
        return cards.sorted { $0.expires < $1.expires }
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
    private static let isoNoZone: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return f
    }()
    /// reset_at 兼容：epoch 秒 / epoch 毫秒（>10^10）/ ISO8601 字符串
    static func parseDateValue(_ v: Any?) -> Date? {
        if let n = v as? NSNumber {
            let s = n.doubleValue
            guard s > 0 else { return nil }
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
    // token 扫描每 N 个刷新周期做一次（额度仍每 60s 刷新）
    private let tokenEveryCycles = 5
    // 数据过期阈值：额度 10 分钟、token 统计 30 分钟——超过该时长未成功刷新即在 UI 标 ⚠
    // （与 GlmUsage 的静默保留旧数据不同，这是刻意改进：过期数据必须可见）
    private let quotaStaleAfter: TimeInterval = 600
    private let tokensStaleAfter: TimeInterval = 1800
    private var quotaLastOK: Date?
    private var tokensLastOK: Date?
    private let launchAgentLabel = "com.local.codex-usage"

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSLog("[CodexUsage] launched, creating status item")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.isVisible = true
        rebuildMenu()
        renderBar()
        refresh(tokens: true)
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            guard let self = self else { return }
            self.cycle += 1
            self.refresh(tokens: self.cycle % self.tokenEveryCycles == 0)
        }
    }

    // 拉取数据：额度走网络（回调内含 401 兜底刷新），token 扫描与充值卡明细走每 5 分钟周期
    private func refresh(tokens: Bool) {
        Fetcher.fetchQuota { [weak self] r in
            DispatchQueue.main.async { self?.applyQuota(r) }
        }
        if tokens {
            DispatchQueue.global(qos: .utility).async { [weak self] in
                let r = TokenScanner.scan()
                DispatchQueue.main.async { self?.applyTokens(r) }
            }
            // 充值卡（额度重置卡）：与 token 统计同周期；失败不触发额度 ⚠ 过期标注
            Fetcher.fetchResetCards { [weak self] cards, err in
                DispatchQueue.main.async { self?.applyResetCards(cards, err) }
            }
        }
    }

    // 本次新拉到的值非 nil 才算成功、才推进 lastOK；失败时保留旧数据 + 错误行
    private func applyQuota(_ r: QuotaData) {
        if r.error == nil, r.fiveHour != nil || r.sevenDay != nil {
            quotaLastOK = Date()
            usage.fiveHour = r.fiveHour ?? usage.fiveHour
            usage.sevenDay = r.sevenDay ?? usage.sevenDay
            usage.planType = r.planType ?? usage.planType
            usage.resetCredits = r.resetCredits ?? usage.resetCredits
            usage.quotaError = nil
        } else {
            usage.quotaError = r.error ?? "unexpected payload"
        }
        usage.email = r.email ?? usage.email
        usage.updatedAt = Date()
        renderBar()
        rebuildMenu()
    }

    private func applyTokens(_ r: TokenScanner.Result) {
        if let e = r.error {
            usage.tokensError = e
        } else {
            tokensLastOK = Date()
            usage.tokensToday = r.today
            usage.tokens7d = r.seven
            usage.tokens30d = r.thirty
            usage.tokensError = nil
        }
        usage.updatedAt = Date()
        renderBar()
        rebuildMenu()
    }

    // 充值卡：成功则更新并清错误；瞬时失败保留上次数据、仅记录错误
    // （有旧数据时菜单仍展示旧卡；不触碰 quotaLastOK，不影响额度 ⚠ 过期标注）
    private func applyResetCards(_ cards: [ResetCard]?, _ err: String?) {
        if let cards = cards {
            usage.resetCards = cards
            usage.resetCardsError = nil
        } else if let err = err {
            usage.resetCardsError = err
        }
        usage.updatedAt = Date()
        renderBar()
        rebuildMenu()
    }

    // 过期判定：距最后成功超过阈值即过期；有数据但 lastOK 为 nil（异常情况）也视为过期。
    // 无数据不算过期——菜单里本就显示"暂无数据"，无需再标注。
    private func isStale(_ lastOK: Date?, hasData: Bool, after: TimeInterval) -> Bool {
        guard hasData else { return false }
        guard let t = lastOK else { return true }
        return Date().timeIntervalSince(t) > after
    }
    private var quotaStale: Bool {
        isStale(quotaLastOK, hasData: usage.fiveHour != nil || usage.sevenDay != nil,
                after: quotaStaleAfter)
    }
    private var tokensStale: Bool {
        isStale(tokensLastOK,
                hasData: usage.tokensToday != nil || usage.tokens7d != nil || usage.tokens30d != nil,
                after: tokensStaleAfter)
    }

    // 菜单栏显示：5H / 7D 两行堆叠（剩余口径）；额度过期时第一行前缀 ⚠
    private func renderBar() {
        let line1 = (quotaStale ? "⚠ " : "") + "5H \(Fmt.remainingPct(usage.fiveHour?.usedPercent))"
        let line2 = "7D \(Fmt.remainingPct(usage.sevenDay?.usedPercent))"
        statusItem.button?.image = StackImage.make(line1: line1, line2: line2)
        statusItem.button?.title = ""
        // toolTip 显示最后成功时间而非渲染时间：断网时能直接看出数据有多旧
        statusItem.button?.toolTip = "Codex 用量 · 额度最后成功 \(quotaLastOK.map { Fmt.time($0) } ?? "--")"
            + " · Token 最后成功 \(tokensLastOK.map { Fmt.time($0) } ?? "--")"
        writeStatus(line1: line1, line2: line2)
    }

    // 自诊断：把渲染内容写到本地，便于排查（绝不写任何凭证值）
    private func writeStatus(line1: String, line2: String) {
        let dir = NSHomeDirectory() + "/Library/Application Support/CodexUsage"
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        func iso(_ d: Date?) -> String { d.map { ISO8601DateFormatter().string(from: $0) } ?? "" }
        let info: [String: Any] = [
            "line1": line1,
            "line2": line2,
            "planType": usage.planType ?? "",
            "fiveHourRemaining": Fmt.remainingInt(usage.fiveHour),
            "sevenDayRemaining": Fmt.remainingInt(usage.sevenDay),
            "fiveHourReset": usage.fiveHour?.reset.map { Fmt.dayTime($0) } ?? "",
            "sevenDayReset": usage.sevenDay?.reset.map { Fmt.dayTime($0) } ?? "",
            "resetCredits": usage.resetCredits ?? -1,
            "resetCards": (usage.resetCards ?? []).map { iso($0.expires) },
            "resetCardsError": usage.resetCardsError ?? "",
            "quotaLastSuccess": iso(quotaLastOK),
            "tokensLastSuccess": iso(tokensLastOK),
            "quotaStale": quotaStale,
            "tokensStale": tokensStale,
            "quotaError": usage.quotaError ?? "",
            "tokensError": usage.tokensError ?? "",
            "updatedAt": ISO8601DateFormatter().string(from: Date())
        ]
        if let data = try? JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted]) {
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

        func windowLine(_ label: String, _ w: QuotaWindow?) -> String {
            guard let w = w else { return "\(label)：暂无数据" }
            var s = "\(label)：剩余 \(Fmt.remainingPct(w.usedPercent))"
            if let r = w.reset { s += "（重置 \(Fmt.dayTime(r))）" }
            return s
        }
        menu.addItem(info(windowLine("5 小时窗口", usage.fiveHour)))
        menu.addItem(info(windowLine("7 天窗口", usage.sevenDay)))

        // 充值卡（额度重置卡）：独立成区两侧加横条（沿用原"重置卡：×N"的分区）；
        // 有效卡按过期时间升序，≤72 小时临期加 ⚠️ 前缀（展示格式与 GlmUsage 逐行对齐）
        func cardLine(_ name: String, _ d: Date) -> String {
            let warn = d.timeIntervalSinceNow <= 72 * 3600
            return (warn ? "⚠️ " : "  ") + "\(name) · \(Fmt.expires(d)) 过期"
        }
        var cardLines: [String] = []
        if let cards = usage.resetCards {
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
        if !cardLines.isEmpty {
            menu.addItem(.separator())
            for l in cardLines { menu.addItem(info(l)) }
        }
        menu.addItem(.separator())

        if let e = usage.tokensError {
            menu.addItem(info("Token 统计失败：\(e)"))
        } else if usage.tokensToday == nil && usage.tokens7d == nil && usage.tokens30d == nil {
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

        // 数据过期提示（本工具对 GlmUsage/KimiUsage 的刻意改进）
        if quotaStale {
            menu.addItem(info("⚠ 额度数据过期（最后成功 \(quotaLastOK.map { Fmt.dayTime($0) } ?? "--")）"))
        }
        if tokensStale {
            menu.addItem(info("⚠ tokens 过期（最后成功 \(tokensLastOK.map { Fmt.dayTime($0) } ?? "--")）"))
        }
        if let e = usage.quotaError {
            menu.addItem(info("额度错误：\(e)"))
        }
        if let e = usage.tokensError {
            menu.addItem(info("Token 错误：\(e)"))
        }

        menu.addItem(.separator())
        menu.addItem(info("更新于 \(Fmt.time(usage.updatedAt))"))
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

    @objc private func onRefresh() { refresh(tokens: true) }

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

func onceMode() {
    let group = DispatchGroup()
    var quota: QuotaData?
    var scan: TokenScanner.Result?
    var cards: [ResetCard]?
    var cardsErr: String?
    group.enter()
    Fetcher.fetchQuota { r in
        quota = r
        group.leave()
    }
    group.enter()
    DispatchQueue.global(qos: .userInitiated).async {
        scan = TokenScanner.scan()
        group.leave()
    }
    group.enter()
    Fetcher.fetchResetCards { c, e in
        cards = c
        cardsErr = e
        group.leave()
    }
    _ = group.wait(timeout: .now() + 60)

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
