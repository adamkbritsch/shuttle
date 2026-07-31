import Foundation

/// Result enums rather than `throws`: the sibling apps' convention (see MagnetSender).
/// Callers get one exhaustive switch and no do/catch, and the server's own error text
/// is carried through verbatim — the relay's guards write good messages and this app
/// should not paraphrase them.
enum ProbeResult { case ok(Health); case unauthorized; case unreachable(String) }
enum BrowseResult { case listing(Listing); case refused(String); case unauthorized; case unreachable(String) }
enum TargetsResult { case targets([Target]); case unauthorized; case unreachable(String) }
enum JobsResult { case page(JobsPage); case unchanged; case unauthorized; case unreachable(String) }
enum ActionResult { case ok(String); case refused(String); case unauthorized; case unreachable(String) }
/// `conflict` carries the relay's 409: it refused, and wants an on_conflict policy.
enum EnqueueResult { case ok(String); case conflict(ConflictReport); case refused(String); case unauthorized; case unreachable(String) }
enum LogResult { case text(String); case unreachable(String) }
enum StatResultOutcome { case stat(StatResult); case refused(String); case unreachable(String) }
enum SeedboxResult { case config(SeedboxConfig); case unreachable(String) }
enum SeedboxSaveResult { case saved(SeedboxConfig, SeedboxProbe?); case failed(String); case unreachable(String) }
enum SettingsResult { case settings(RelaySettings); case refused(String); case unreachable(String) }
enum RenameResult { case renamed(String); case deferred(String); case refused(String); case unauthorized; case unreachable(String) }
enum VerifyOutcome { case result(VerifyResult); case refused(String); case unreachable(String) }

actor RelayAPI {
    private let session: URLSession
    private var base: URL
    private var token: String?
    private var jobsETag: String?

    /// Empty by default: there is no address that is right for everyone, and a
    /// stranger's clone should say "set this up" rather than fail against someone
    /// else's tailnet. Set it in Settings, or bake one in at build time with
    /// SHUTTLE_RELAY_HOST=... ./macapp/build.sh
    static let defaultBase = Bundle.main.object(forInfoDictionaryKey: "SHRelayBase")
        as? String ?? ""

    init(base: String = RelayAPI.defaultBase) {
        self.base = RelayAPI.normalize(base) ?? URL(string: RelayAPI.defaultBase + "/")!
        let cfg = URLSessionConfiguration.ephemeral
        // A cold FUSE subdirectory listing on the NAS measures ~1.2s, so a 4s budget
        // would time out on a legitimately slow browse.
        cfg.timeoutIntervalForRequest = RelayAPI.browseTimeout
        cfg.httpShouldSetCookies = false
        cfg.httpCookieStorage = nil
        // Load-bearing: with a URLCache in play, URLSession does its own revalidation
        // and can hand back a synthesized 200 from cache, which silently kills the
        // manual If-None-Match / 304 scheme below — it would look like it works while
        // never actually exercising the 304 path.
        cfg.urlCache = nil
        cfg.requestCachePolicy = .reloadIgnoringLocalCacheData
        session = URLSession(configuration: cfg)
    }

    static func normalize(_ s: String) -> URL? {
        var t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while t.hasSuffix("/") { t.removeLast() }
        guard !t.isEmpty else { return nil }
        return URL(string: t + "/")
    }

    func setBase(_ s: String) {
        if let u = RelayAPI.normalize(s) { base = u; jobsETag = nil }
    }

    func setToken(_ t: String?) {
        token = (t?.isEmpty ?? true) ? nil : t
    }

    func clearETag() { jobsETag = nil }

    // ---------- plumbing ----------

    /// Polling endpoints must stay snappy; browsing must be patient. A cold
    /// directory listing crosses a FUSE mount to the seedbox and was measured at
    /// 1.2s for a warm subdirectory but well past 8s for a cold one — the app
    /// showed "Timed out" on a listing that was merely slow.
    static let pollTimeout: TimeInterval = 8
    static let browseTimeout: TimeInterval = 40

    private func request(_ path: String, method: String = "GET",
                         body: [String: String]? = nil,
                         etag: String? = nil,
                         timeout: TimeInterval = RelayAPI.pollTimeout) -> URLRequest? {
        guard let url = URL(string: path, relativeTo: base) else { return nil }
        var r = URLRequest(url: url)
        r.httpMethod = method
        r.timeoutInterval = timeout
        r.cachePolicy = .reloadIgnoringLocalCacheData
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        if let body {
            r.setValue("application/json", forHTTPHeaderField: "Content-Type")
            r.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        return r
    }

    private func serverMessage(_ data: Data) -> String? {
        (try? Wire.decoder.decode(APIError.self, from: data))?.error
    }

    /// Humanised NSURLError text. -1022 gets a specific message because a missing
    /// Info.plist ATS exception is by far the most likely first-run failure and the
    /// default description explains nothing.
    static func describe(_ error: Error) -> String {
        let ns = error as NSError
        guard ns.domain == NSURLErrorDomain else { return ns.localizedDescription }
        switch ns.code {
        case NSURLErrorTimedOut: return "Timed out — the seedbox listing is taking unusually long"
        case NSURLErrorCannotConnectToHost: return "The NAS refused the connection"
        case NSURLErrorCannotFindHost: return "Host not found"
        case NSURLErrorNotConnectedToInternet: return "No network"
        case NSURLErrorNetworkConnectionLost: return "Connection dropped"
        case NSURLErrorAppTransportSecurityRequiresSecureConnection:
            return "Blocked by App Transport Security — the Info.plist exception for this host is missing"
        default: return ns.localizedDescription
        }
    }

    private func escape(_ s: String) -> String {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~/")
        return s.addingPercentEncoding(withAllowedCharacters: allowed) ?? s
    }

    // ---------- endpoints ----------

    func probe() async -> ProbeResult {
        guard let r = request("healthz") else { return .unreachable("Bad base URL") }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode == 401 { return .unauthorized }
            guard http.statusCode == 200 else {
                return .unreachable("Relay answered \(http.statusCode)")
            }
            guard let h = try? Wire.decoder.decode(Health.self, from: data), h.ok else {
                // A bare 200 with the wrong body is not the relay — captive portal, say.
                return .unreachable("Something else answered on that port")
            }
            return .ok(h)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func browse(_ path: String, limit: Int? = nil) async -> BrowseResult {
        var q = "v1/browse?path=\(escape(path))"
        if let limit { q += "&limit=\(limit)" }
        guard let r = request(q, timeout: RelayAPI.browseTimeout) else {
            return .unreachable("Bad base URL")
        }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            guard let l = try? Wire.decoder.decode(Listing.self, from: data) else {
                return .refused("Could not read that listing")
            }
            return .listing(l)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func targets() async -> TargetsResult {
        guard let r = request("v1/targets") else { return .unreachable("Bad base URL") }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode == 401 { return .unauthorized }
            guard http.statusCode == 200,
                  let t = try? Wire.decoder.decode(TargetsPage.self, from: data) else {
                return .unreachable("Relay answered \(http.statusCode)")
            }
            return .targets(t.targets)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func jobs() async -> JobsResult {
        guard let r = request("v1/jobs", etag: jobsETag) else {
            return .unreachable("Bad base URL")
        }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode == 304 { return .unchanged }
            guard http.statusCode == 200,
                  let p = try? Wire.decoder.decode(JobsPage.self, from: data) else {
                return .unreachable("Relay answered \(http.statusCode)")
            }
            if let tag = http.value(forHTTPHeaderField: "ETag") { jobsETag = tag }
            return .page(p)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    /// `onConflict` nil means "ask": the relay scans the destination and answers 409
    /// with the clashing files instead of silently overwriting them.
    func enqueue(src: String, destDir: String,
                 onConflict: ConflictAction? = nil,
                 destName: String? = nil) async -> EnqueueResult {
        var body: [String: String] = ["src": src, "dest_dir": destDir]
        if let onConflict { body["on_conflict"] = onConflict.rawValue }
        if let destName { body["dest_name"] = destName }
        guard let r = request("v1/jobs", method: "POST", body: body) else {
            return .unreachable("Bad base URL")
        }
        jobsETag = nil                    // force the next poll to return a body
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode == 409 {
                if let report = try? JSONDecoder().decode(ConflictReport.self, from: data) {
                    return .conflict(report)
                }
                return .refused(serverMessage(data) ?? "Target files already exist")
            }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            let name = destName ?? (src as NSString).lastPathComponent
            return .ok("Copying \(name)")
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func seedbox() async -> SeedboxResult {
        guard let r = request("v1/seedbox") else { return .unreachable("Bad base URL") }
        do {
            let (data, _) = try await session.data(for: r)
            guard let cfg = try? JSONDecoder().decode(SeedboxConfig.self, from: data) else {
                return .unreachable("Unexpected reply")
            }
            return .config(cfg)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    /// The relay saves AND tests in one call — it is the machine that has to reach
    /// the seedbox, so a test from this Mac would prove nothing.
    func setSeedbox(protocolName: String, host: String, port: Int, user: String,
                    password: String, root: String) async -> SeedboxSaveResult {
        var body: [String: String] = ["protocol": protocolName, "host": host,
                                      "port": String(port), "user": user, "root": root]
        if !password.isEmpty { body["password"] = password }
        guard let r = request("v1/seedbox", method: "POST", body: body) else {
            return .unreachable("Bad base URL")
        }
        do {
            let (data, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, let ok = try? JSONDecoder().decode(SeedboxSaveResponse.self, from: data) {
                return .saved(ok.seedbox, ok.probe)
            }
            return .failed(serverMessage(data) ?? "Relay answered \(code)")
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func stat(_ path: String) async -> StatResultOutcome {
        guard let r = request("v1/stat?path=" + (path.addingPercentEncoding(
                withAllowedCharacters: .urlQueryAllowed) ?? path)) else {
            return .unreachable("Bad base URL")
        }
        do {
            let (data, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 200, let s = try? JSONDecoder().decode(StatResult.self, from: data) {
                return .stat(s)
            }
            return .refused(serverMessage(data) ?? "Relay answered \(code)")
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func delete(_ path: String) async -> ActionResult {
        await simplePost("v1/delete", ["path": path], ok: "Deleted")
    }

    func mkdir(parent: String, name: String) async -> ActionResult {
        await simplePost("v1/mkdir", ["parent": parent, "name": name],
                         ok: "Created \(name)")
    }

    func retry(_ id: Int) async -> ActionResult {
        await simplePost("v1/jobs/\(id)/retry", [:], ok: "Queued again")
    }

    /// Shared shape for the small write endpoints: POST, treat any 4xx/5xx as a
    /// refusal carrying the relay's own message, and force the next poll.
    private func simplePost(_ p: String, _ body: [String: String],
                            ok: String) async -> ActionResult {
        guard let r = request(p, method: "POST", body: body) else {
            return .unreachable("Bad base URL")
        }
        jobsETag = nil
        do {
            let (data, resp) = try await session.data(for: r)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 { return .unauthorized }
            if code >= 400 { return .refused(serverMessage(data) ?? "Relay answered \(code)") }
            return .ok(ok)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func act(_ id: Int, _ action: String) async -> ActionResult {
        guard let r = request("v1/jobs/\(id)/\(action)", method: "POST") else {
            return .unreachable("Bad base URL")
        }
        jobsETag = nil
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            return .ok(msg ?? action)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func rename(path: String, newName: String) async -> RenameResult {
        guard var r = request("v1/rename", method: "POST") else {
            return .unreachable("Bad base URL")
        }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["path": path,
                                                                 "new_name": newName])
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (obj?["deferred"] as? Bool) == true {
                return .deferred(obj?["message"] as? String
                                 ?? "will be renamed when the transfer finishes")
            }
            return .renamed(newName)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func settings() async -> SettingsResult {
        guard let r = request("v1/settings") else { return .unreachable("Bad base URL") }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            guard let v = try? Wire.decoder.decode(RelaySettings.self, from: data) else {
                return .refused("Could not read the settings")
            }
            return .settings(v)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func setMaxConcurrent(_ n: Int) async -> SettingsResult {
        guard var r = request("v1/settings", method: "POST") else {
            return .unreachable("Bad base URL")
        }
        r.setValue("application/json", forHTTPHeaderField: "Content-Type")
        r.httpBody = try? JSONSerialization.data(withJSONObject: ["max_concurrent": n])
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            guard let v = try? Wire.decoder.decode(RelaySettings.self, from: data) else {
                return .refused("Could not read the settings")
            }
            return .settings(v)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func log(_ id: Int) async -> LogResult {
        guard let r = request("v1/jobs/\(id)/log") else { return .unreachable("Bad base URL") }
        do {
            let (data, _) = try await session.data(for: r)
            return .text(String(data: data, encoding: .utf8) ?? "(unreadable)")
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    func verify(_ id: Int) async -> VerifyOutcome {
        guard let r = request("v1/jobs/\(id)/verify") else { return .unreachable("Bad base URL") }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            guard let v = try? Wire.decoder.decode(VerifyResult.self, from: data) else {
                return .refused("Could not read the verify result")
            }
            return .result(v)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }
}
