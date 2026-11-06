import Foundation

struct OfficialUsageSnapshot {
    enum SparsePolicy { case unknown, officialActivity }
    enum Day: Equatable { case reported(Double), inferredZero, missing }
    var lifetime: Double?
    var days: [String: Double]
    var fetchedAt: Date
    var sparsePolicy: SparsePolicy = .unknown

    /// The official client renders absent dates as zero. Restrict that behavior to
    /// the range bounded by actual returned dates; never extrapolate beyond it.
    func day(_ date: String) -> Day {
        if let value = days[date] { return .reported(value) }
        guard sparsePolicy == .officialActivity, let first = days.keys.min(), let last = days.keys.max(),
              date >= first, date <= last else { return .missing }
        return .inferredZero
    }
}

enum OfficialUsageReader {
    enum Failure: Error { case unavailable, unsupported, timeout, invalid, identityMismatch, unauthorized }
    static let endpoint = URL(string: "https://chatgpt.com/backend-api/wham/profiles/me")!

    // The profile backend uses snake_case; app-server exposes the same fields in camelCase.
    static func parse(_ result: [String: Any], now: Date = Date()) -> OfficialUsageSnapshot? {
        if let metadata = result["metadata"] as? [String: Any], let error = metadata["stats_error"], !(error is NSNull) { return nil }
        guard let stats = (result["stats"] as? [String: Any]) ?? (result["summary"] as? [String: Any]) else { return nil }
        let lifetime = CodexNumber.finite(stats["lifetime_tokens"] ?? stats["lifetimeTokens"]).flatMap { $0 >= 0 && $0.rounded(.towardZero) == $0 ? $0 : nil }
        let buckets = (stats["daily_usage_buckets"] as? [[String: Any]]) ?? (result["dailyUsageBuckets"] as? [[String: Any]])
        var days: [String: Double] = [:]
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.calendar = Calendar(identifier: .gregorian)
        formatter.timeZone = TimeZone(secondsFromGMT: 0)!; formatter.dateFormat = "yyyy-MM-dd"; formatter.isLenient = false
        if let buckets = buckets {
            for bucket in buckets {
                guard let key = (bucket["start_date"] ?? bucket["startDate"]) as? String, key.count == 10,
                      let date = formatter.date(from: key), formatter.string(from: date) == key,
                      let value = CodexNumber.finite(bucket["tokens"]), value >= 0, value.rounded(.towardZero) == value, days[key] == nil else { return nil }
                days[key] = value
            }
        }
        guard lifetime != nil || !days.isEmpty else { return nil }
        return OfficialUsageSnapshot(lifetime: lifetime, days: days, fetchedAt: now,
                                     sparsePolicy: buckets != nil && !days.isEmpty ? .officialActivity : .unknown)
    }

    static func request(expected: CodexAuth.Snapshot?) -> URLRequest? {
        guard let expected = expected, let identity = CodexAuth.identity(expected), identity.hasPrefix("account:"),
              let accountID = expected.tokens.accountID, !accountID.isEmpty, identity.hasSuffix("|" + accountID) else { return nil }
        var request = URLRequest(url: endpoint, timeoutInterval: 15)
        request.httpMethod = "GET"
        request.setValue("Bearer " + expected.tokens.accessToken, forHTTPHeaderField: "Authorization")
        request.setValue(accountID, forHTTPHeaderField: "ChatGPT-Account-ID")
        request.setValue("CodexUsage/1.0", forHTTPHeaderField: "User-Agent")
        return request
    }

    static func read(expected: CodexAuth.Snapshot?, timeout: TimeInterval = 15,
                     authPath: String = CodexAuth.authPath,
                     configuration: URLSessionConfiguration = .ephemeral) -> Result<OfficialUsageSnapshot, Failure> {
        guard let expected = expected, let identity = CodexAuth.identity(expected),
              let request = request(expected: expected),
              let before = CodexAuth.load(at: authPath), CodexAuth.sameAuth(expected.tokens, before.tokens),
              CodexAuth.identity(before) == identity else { return .failure(.identityMismatch) }
        let delegate = BoundedProfileDelegate()
        configuration.timeoutIntervalForRequest = timeout; configuration.timeoutIntervalForResource = timeout
        let session = URLSession(configuration: configuration, delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request); task.resume()
        let waited = delegate.finished.wait(timeout: .now() + timeout)
        if waited != .success { task.cancel(); session.invalidateAndCancel(); return .failure(.timeout) }
        session.finishTasksAndInvalidate()
        guard let after = CodexAuth.load(at: authPath), CodexAuth.sameAuth(expected.tokens, after.tokens),
              CodexAuth.identity(after) == identity else { return .failure(.identityMismatch) }
        guard delegate.error == nil, !delegate.overflow else { return .failure(.unavailable) }
        if delegate.status == 401 { return .failure(.unauthorized) }
        if delegate.status == 403 || delegate.status == 404 { return .failure(.unsupported) }
        guard delegate.status == 200,
              let object = (try? JSONSerialization.jsonObject(with: delegate.data)) as? [String: Any],
              let result = parse(object) else { return .failure(.invalid) }
        return .success(result)
    }
}

private final class BoundedProfileDelegate: NSObject, URLSessionDataDelegate, URLSessionTaskDelegate {
    let finished = DispatchSemaphore(value: 0)
    var data = Data()
    var error: Error?
    var overflow = false
    var status = 0
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        status = (response as? HTTPURLResponse)?.statusCode ?? 0
        completionHandler(response.expectedContentLength > 2 * 1024 * 1024 ? .cancel : .allow)
    }
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        if self.data.count + data.count > 2 * 1024 * 1024 { overflow = true; dataTask.cancel(); return }
        self.data.append(data)
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        self.error = error; finished.signal()
    }
}
