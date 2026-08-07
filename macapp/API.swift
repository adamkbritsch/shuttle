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
/// `busy` is the relay's 503 when a search is already running. Deliberately its own
/// case and NOT `.refused`: the user is typing, not doing something wrong, so it
/// must be possible to keep the previous results on screen and say nothing.
enum SearchOutcome { case results(SearchResults); case busy; case refused(String); case unauthorized; case unreachable(String) }
/// `made` vs `joined`: the relay says whether it created the folder or found one
/// already there, so the app can say which rather than implying it made one.
enum MkdirOutcome { case made(String); case joined(String); case refused(String); case unreachable(String) }
/// `clash` is the relay's 409, carrying the name that is taken so the app can ask
/// overwrite-or-rename instead of just reporting a failure.
enum MoveOutcome { case moved(String); case clash(name: String, existing: String); case refused(String); case unreachable(String) }

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
    /// Longer than the relay's own 25s search deadline, on purpose: the server
    /// stopping early and SAYING so (`timed_out`) is far more useful than the
    /// client giving up first and reporting a bare timeout. 40s would be needlessly
    /// patient for something measured at 0.45s warm.
    /// Must clear the SLOWER of the two sides. The remote walk is one rclone
    /// recursive listing over FTP, measured at 18.9-20.8s with no warm case, and
    /// the relay allows it 120s. 30s would have failed a remote search that was
    /// working perfectly.
    static let searchTimeout: TimeInterval = 60
    /// Its own budget, well past `searchTimeout`, because a manifest is two slow
    /// things stacked: an `rclone lsjson --recursive` on the seedbox (measured at
    /// 18.9s for 737 entries, and it never warms) plus however long the tailnet
    /// takes. On a network that blocks UDP, Tailscale falls back to DERP over 443
    /// and every round trip gets slower -- which is precisely the network this
    /// whole path exists to work on, so the budget has to assume it.
    static let manifestTimeout: TimeInterval = 240

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

    // ---------- reading bytes out, for transfers this app performs itself ----------

    /// What a path is made of, so a local transfer knows its file list and total.
    func manifest(_ path: String) async -> ManifestOutcome {
        guard let r = request("v1/manifest?path=\(escape(path))",
                              timeout: RelayAPI.manifestTimeout) else {
            return .unreachable("Bad base URL")
        }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            guard let m = try? Wire.decoder.decode(Manifest.self, from: data) else {
                return .refused("Could not read that manifest")
            }
            return .manifest(m)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    /// One file's bytes as a stream of chunks.
    ///
    /// Not `session.data(for:)`: that buffers the whole response in memory, and a
    /// 24 GB film would take the machine down. Not `session.bytes(for:)` either —
    /// that is an `AsyncSequence` of single BYTES, and the per-element overhead
    /// makes it useless at this size. So a delegate that hands over whole chunks as
    /// they arrive, bridged to an `AsyncThrowingStream`.
    nonisolated func fetchStream(_ path: String) -> AsyncThrowingStream<Data, Error> {
        AsyncThrowingStream { continuation in
            Task {
                guard let r = await self.fetchRequest(path) else {
                    continuation.finish(throwing: RelayFetchError.badURL)
                    return
                }
                let pump = ChunkPump(continuation: continuation)
                let cfg = URLSessionConfiguration.ephemeral
                cfg.urlCache = nil
                // No overall ceiling: a big file legitimately takes hours. The
                // per-chunk timeout below is what catches a dead connection.
                cfg.timeoutIntervalForResource = .greatestFiniteMagnitude
                cfg.timeoutIntervalForRequest = 120
                let s = URLSession(configuration: cfg, delegate: pump, delegateQueue: nil)
                let task = s.dataTask(with: r)
                continuation.onTermination = { _ in
                    task.cancel()
                    s.invalidateAndCancel()
                }
                pump.session = s
                task.resume()
            }
        }
    }

    /// The request `fetchStream` sends. Separate because building it needs the
    /// actor's `base` and `token`, while the streaming itself must not be isolated
    /// to the actor — one download would otherwise block every poll.
    func fetchRequest(_ path: String) -> URLRequest? {
        var r = request("v1/fetch?path=\(escape(path))", timeout: 120)
        r?.timeoutInterval = 120
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

    /// Whole-NAS recursive name search. Destination side only — the seedbox is
    /// rclone over FTP, where this walk would be thousands of round trips.
    func search(_ query: String, side: String, limit: Int? = nil) async -> SearchOutcome {
        var q = "v1/search?q=\(escape(query))&side=\(side)"
        if let limit { q += "&limit=\(limit)" }
        guard let r = request(q, timeout: RelayAPI.searchTimeout) else {
            return .unreachable("Bad base URL")
        }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode == 401 { return .unauthorized }
            if http.statusCode == 503 { return .busy }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            guard let out = try? Wire.decoder.decode(SearchResults.self, from: data) else {
                return .refused("Could not read those results")
            }
            return .results(out)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    /// Relocate one item inside a drop target. One call per item, like delete.
    func move(_ path: String, into destDir: String,
              newName: String? = nil, overwrite: Bool = false) async -> MoveOutcome {
        var body: [String: String] = ["path": path, "dest_dir": destDir]
        if let newName { body["new_name"] = newName }
        if overwrite { body["overwrite"] = "1" }
        guard let r = request("v1/move", method: "POST", body: body) else {
            return .unreachable("Bad base URL")
        }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if http.statusCode == 409 {
                return .clash(name: obj?["name"] as? String ?? "",
                              existing: obj?["existing"] as? String ?? "")
            }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            return .moved(obj?["moved"] as? String ?? destDir)
        } catch { return .unreachable(RelayAPI.describe(error)) }
    }

    /// Unlike `mkdir`, this reads the response: "did you make it or join it?" is
    /// the whole point when the caller is filing things into a folder.
    func mkdirJoining(parent: String, name: String) async -> MkdirOutcome {
        guard let r = request("v1/mkdir", method: "POST",
                              body: ["parent": parent, "name": name, "exist_ok": "1"]) else {
            return .unreachable("Bad base URL")
        }
        do {
            let (data, resp) = try await session.data(for: r)
            guard let http = resp as? HTTPURLResponse else { return .unreachable("No response") }
            if http.statusCode >= 400 {
                return .refused(serverMessage(data) ?? "Relay answered \(http.statusCode)")
            }
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            let path = obj?["path"] as? String ?? ""
            return (obj?["created"] as? Bool ?? true) ? .made(path) : .joined(path)
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
                 destName: String? = nil,
                 replace: String? = nil) async -> EnqueueResult {
        var body: [String: String] = ["src": src, "dest_dir": destDir]
        if let onConflict { body["on_conflict"] = onConflict.rawValue }
        if let destName { body["dest_name"] = destName }
        // The relay validates this at enqueue and only acts on it after the copy
        // has landed AND verified, so a refusal arrives before any bytes move.
        if let replace { body["replace"] = replace }
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
            // The relay refuses to queue the same copy twice and hands back the
            // existing job instead, so say that rather than implying a second one
            // started — the queue will show one row either way.
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
            if (obj?["duplicate"] as? Bool) == true {
                return .ok("\(name) is already in the queue")
            }
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


enum RelayFetchError: Error, LocalizedError {
    case badURL
    case http(Int, String)

    var errorDescription: String? {
        switch self {
        case .badURL: return "Bad base URL"
        case .http(let code, let msg):
            return msg.isEmpty ? "Relay answered \(code)" : msg
        }
    }
}

/// Bridges `URLSessionDataDelegate`'s chunk callbacks to an `AsyncThrowingStream`.
///
/// A class rather than a closure because URLSession retains its delegate for the
/// life of the session and hands back three separate callbacks — the response (to
/// check the status before any bytes are trusted), each chunk, and completion.
private final class ChunkPump: NSObject, URLSessionDataDelegate, @unchecked Sendable {
    private let continuation: AsyncThrowingStream<Data, Error>.Continuation
    /// Held so it can be torn down on completion; a session with a delegate leaks
    /// until it is invalidated.
    var session: URLSession?
    private var failure: Error?

    init(continuation: AsyncThrowingStream<Data, Error>.Continuation) {
        self.continuation = continuation
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask,
                    didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        guard let http = response as? HTTPURLResponse, http.statusCode < 400 else {
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            // Refuse the body: an error response is JSON, and letting it through
            // would write the relay's error message into the file as if it were
            // content.
            failure = RelayFetchError.http(code, "")
            completionHandler(.cancel)
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        continuation.yield(data)
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let failure {
            continuation.finish(throwing: failure)
        } else if let error {
            continuation.finish(throwing: error)
        } else {
            continuation.finish()
        }
        self.session?.finishTasksAndInvalidate()
        self.session = nil
    }
}
