import Foundation
import SwiftUI

struct Toast: Equatable {
    let text: String
    let isError: Bool
}

/// Connection state + the transfer list.
@MainActor
final class RelayStore: ObservableObject {
    enum Reason: Equatable { case unauthorized; case unreachable(String) }
    enum Status: Equatable { case probing; case live(Health); case offline(Reason) }

    @Published private(set) var status: Status = .probing
    @Published private(set) var active: [Job] = []
    @Published private(set) var recent: [Job] = []
    @Published private(set) var targets: [Target] = []
    @Published private(set) var toast: Toast?
    @Published private(set) var maxConcurrent = 1
    @Published private(set) var maxConcurrentCeiling = 8
    @Published private(set) var seedbox = SeedboxConfig.empty

    let api: RelayAPI
    @Published var baseURL: String {
        didSet {
            UserDefaults.standard.set(baseURL, forKey: "relay.base")
            Task { await api.setBase(baseURL) }
        }
    }

    private var timer: Timer?
    private var nextPollAt = Date.distantPast
    private var toastClear: DispatchWorkItem?
    private var polling = false
    private var pollAgain = false

    /// Finished transfers are shown only for the CURRENT app session.
    ///
    /// The relay keeps every job forever in SQLite — that history is genuinely
    /// useful on the server and is what /verify and the logs read from — but in the
    /// window it just accumulates, so "Successful transfers" climbed past 40 and
    /// stopped meaning anything. Filtering by launch time resets the two history
    /// tabs on relaunch without deleting anything on the NAS.
    private let launchedAt = Date().timeIntervalSince1970

    init() {
        let saved = UserDefaults.standard.string(forKey: "relay.base") ?? RelayAPI.defaultBase
        baseURL = saved
        api = RelayAPI(base: saved)
    }

    // ---------- lifecycle ----------

    /// Awaits the token BEFORE the first request. Without this, every request during
    /// the Keychain's slow first read would go out with no Authorization header and
    /// 401 — so a perfectly good install's first impression would be "token rejected".
    func start() async {
        let t = await TokenStore.token()
        await api.setToken(t)
        guard t != nil else { status = .offline(.unauthorized); return }
        await refreshStatus()
        if case .live = status {
            await loadTargets()
            await poll(force: true)
        }
    }

    func refreshStatus() async {
        switch await api.probe() {
        case .ok(let h): status = .live(h)
        case .unauthorized: status = .offline(.unauthorized)
        case .unreachable(let why): status = .offline(.unreachable(why))
        }
    }

    func loadTargets() async {
        if case .targets(let t) = await api.targets() { targets = t }
        await loadSeedbox()
        if case .settings(let s) = await api.settings() {
            maxConcurrent = s.maxConcurrent
            maxConcurrentCeiling = s.maxConcurrentCeiling
        }
    }

    func loadSeedbox() async {
        if case .config(let c) = await api.seedbox() { seedbox = c }
    }

    /// True when the relay saved AND proved the connection.
    func saveSeedbox(protocolName: String, host: String, port: Int, user: String,
                     password: String, root: String) async -> Bool {
        switch await api.setSeedbox(protocolName: protocolName, host: host, port: port,
                                    user: user, password: password, root: root) {
        case .saved(let cfg, let probe):
            seedbox = cfg
            let n = probe?.entries ?? 0
            show("Seedbox connected — \(n) item\(n == 1 ? "" : "s") at the root", isError: false)
            return true
        case .failed(let why), .unreachable(let why):
            show(why, isError: true)
            return false
        }
    }

    func setMaxConcurrent(_ n: Int) async {
        switch await api.setMaxConcurrent(n) {
        case .settings(let s):
            maxConcurrent = s.maxConcurrent
            maxConcurrentCeiling = s.maxConcurrentCeiling
            show(s.maxConcurrent == 1 ? "One transfer at a time"
                                      : "Up to \(s.maxConcurrent) at a time", isError: false)
        case .refused(let why), .unreachable(let why):
            show(why, isError: true)
        }
    }

    /// Returns true when the rename actually happened, so the caller knows whether to
    /// reload the listing (a deferred one changes nothing on disk yet).
    func rename(path: String, newName: String) async -> Bool {
        switch await api.rename(path: path, newName: newName) {
        case .renamed(let n): show("Renamed to \(n)", isError: false); return true
        case .deferred(let msg): show(msg, isError: false); return false
        case .refused(let why), .unreachable(let why): show(why, isError: true); return false
        }
    }

    func startPolling() {
        guard timer == nil else { return }
        let t = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in await self?.tick() }
        }
        // Tolerance lets macOS coalesce this wakeup with others already scheduled
        // instead of waking the CPU on its own account once a second forever. The
        // cadence below is in seconds, so a third of a second of slop costs nothing
        // visible and measurably reduces timer wakeups.
        t.tolerance = 0.3
        // .common so polling continues while a menu or sheet is up.
        RunLoop.main.add(t, forMode: .common)
        timer = t
    }

    func stopPolling() { timer?.invalidate(); timer = nil }

    private func tick() async {
        guard Date() >= nextPollAt else { return }
        await poll()
    }

    /// One timer, variable cadence: 1s while something is transferring, 5s idle,
    /// +5s when the app is in the background. No rescheduling.
    ///
    /// An occlusion-driven backoff was tried here and REMOVED. Measured against the
    /// relay it did not fire in the ordinary "behind another window" case — AppKit
    /// only reports a window non-visible when it is fully covered, minimised or
    /// hidden — and when the app WAS hidden it made things worse, not better:
    /// 39 polls in 69s (median gap 2.0s) against 7 in 71s without it, because the
    /// visibility notification fires repeatedly and each one reset the schedule.
    private func reschedule() {
        var delay = active.isEmpty ? 5.0 : 1.0
        if !NSApplication.shared.isActive { delay += 5.0 }
        nextPollAt = Date().addingTimeInterval(delay)
    }



    /// Serialised. The 1s timer can fire again while a slow poll is still in the
    /// air, and two in flight at once race to publish `active`/`recent` — the older
    /// answer can land second and briefly resurrect a transfer that just finished.
    /// A forced poll arriving mid-flight is remembered rather than dropped, because
    /// its whole purpose is to reflect a change the user just made.
    func poll(force: Bool = false) async {
        if polling {
            if force { pollAgain = true }
            return
        }
        polling = true
        await performPoll(force: force)
        polling = false
        if pollAgain {
            pollAgain = false
            await poll(force: true)
        }
    }

    private func performPoll(force: Bool) async {
        if force { await api.clearETag() }
        switch await api.jobs() {
        case .unchanged:
            // The whole point of the ETag: publish NOTHING, so @Published does not
            // churn and SwiftUI does not rebuild the list every second.
            break
        case .page(let p):
            // `active` is deliberately NOT filtered: a transfer that was already
            // running when the app started is still running now and must be visible.
            if p.active != active { active = p.active }
            let session = p.recent.filter { ($0.finishedAt ?? 0) >= launchedAt }
            if session != recent { recent = session }
            if case .offline = status { await refreshStatus() }
        case .unauthorized:
            status = .offline(.unauthorized)
        case .unreachable(let why):
            status = .offline(.unreachable(why))
        }
        reschedule()
    }

    // ---------- actions ----------

    /// Returns the relay's conflict report when it refused, so the caller can ask.
    /// Nil means the job was queued (or failed for some other reason, already shown).
    @discardableResult
    func send(src: String, destDir: String,
              onConflict: ConflictAction? = nil,
              destName: String? = nil) async -> ConflictReport? {
        var pending: ConflictReport?
        switch await api.enqueue(src: src, destDir: destDir,
                                 onConflict: onConflict, destName: destName) {
        case .ok(let msg): show(msg, isError: false)
        case .conflict(let report): pending = report
        case .refused(let why): show(why, isError: true)
        case .unauthorized: status = .offline(.unauthorized); show("Token rejected", isError: true)
        case .unreachable(let why): show(why, isError: true)
        }
        // Poll regardless of outcome: an enqueue that raced a relay restart may well
        // have been committed before the connection dropped, so "it failed" is not
        // evidence that nothing happened.
        await poll(force: true)
        return pending
    }

    func statFor(_ path: String) async -> StatResult? {
        if case .stat(let s) = await api.stat(path) { return s }
        return nil
    }

    /// True when it actually went, so the caller knows whether to reload a listing.
    func delete(_ path: String) async -> Bool { await write(await api.delete(path)) }
    func mkdir(parent: String, name: String) async -> Bool {
        await write(await api.mkdir(parent: parent, name: name))
    }
    func retry(_ id: Int) async -> Bool { await write(await api.retry(id)) }

    private func write(_ r: ActionResult) async -> Bool {
        var ok = false
        switch r {
        case .ok(let m): show(m, isError: false); ok = true
        case .refused(let why): show(why, isError: true)
        case .unauthorized: status = .offline(.unauthorized); show("Token rejected", isError: true)
        case .unreachable(let why): show(why, isError: true)
        }
        await poll(force: true)
        return ok
    }

    func cancel(_ id: Int) async { await act(id, "cancel") }
    func dismiss(_ id: Int) async { await act(id, "dismiss") }

    private func act(_ id: Int, _ action: String) async {
        switch await api.act(id, action) {
        case .ok(let msg): if action == "cancel" { show("j\(id): \(msg)", isError: false) }
        case .refused(let why): show(why, isError: true)
        case .unauthorized: status = .offline(.unauthorized)
        case .unreachable(let why): show(why, isError: true)
        }
        await poll(force: true)
    }

    func show(_ text: String, isError: Bool) {
        toast = Toast(text: text, isError: isError)
        toastClear?.cancel()
        let w = DispatchWorkItem { [weak self] in self?.toast = nil }
        toastClear = w
        DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: w)
    }

    func saveToken(_ t: String) async {
        TokenStore.save(t)
        await api.setToken(t.isEmpty ? nil : t)
        await refreshStatus()
        if case .live = status {
            await loadTargets()
            await poll(force: true)
            show("Connected", isError: false)
        }
    }
}

/// One browser, two instances: the seedbox side and the destination side.
@MainActor
final class BrowseStore: ObservableObject {
    enum Mode { case seedbox, destinations }

    @Published private(set) var path: String
    @Published private(set) var entries: [Entry] = []
    /// Narrows what the table shows. Purely client-side over the page already
    /// fetched -- it never re-queries, so it cannot cost a cold listing.
    @Published var filter = ""
    @Published private(set) var loading = false
    @Published private(set) var error: String?
    @Published var selection = Set<String>()
    /// Most-recently-visited directories for the path bar's dropdown, newest first,
    /// capped at 20 — FileZilla's CViewHeader keeps exactly 20.
    @Published private(set) var recentDirs: [String] = []
    @Published private(set) var truncatedTotal: Int?
    /// Path of the last listing that actually succeeded.
    private var loadedPath: String?

    let mode: Mode
    private let api: RelayAPI
    private weak var store: RelayStore?

    private var pathKey: String { "browse.path.\(mode == .seedbox ? "source" : "dest")" }
    private var rootPath: String { mode == .seedbox ? "/seedbox/downloads" : "/queue" }

    init(mode: Mode, api: RelayAPI, store: RelayStore) {
        self.mode = mode
        self.api = api
        self.store = store
        // Reopen where you left off. Relaunching and landing back at the volume list
        // when you were three folders deep is a small thing that gets old fast.
        let saved = UserDefaults.standard.string(forKey:
            "browse.path.\(mode == .seedbox ? "source" : "dest")")
        path = saved ?? (mode == .seedbox ? "/seedbox/downloads" : "/queue")
    }

    /// Falls back to the pane's root if the remembered path has gone away.
    func restoreOrFallback() async {
        await reload()
        if entries.isEmpty, error != nil, path != rootPath {
            await go(to: rootPath)
        }
    }

    var canGoUp: Bool {
        mode == .seedbox ? path != "/seedbox" && path != "/" : path != "/queue"
    }

    /// Selected rows, in the order they appear in the listing rather than in
    /// selection order, so a multi-item send is predictable.
    /// Entries after the filter. Everything user-facing reads THIS, so a hidden row
    /// can never be selected, sent, renamed or deleted by accident.
    var visibleEntries: [Entry] {
        let q = filter.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return entries }
        return entries.filter { $0.name.lowercased().contains(q) }
    }

    var selectedEntries: [Entry] { entries.filter { selection.contains($0.path) } }

    // Status-line inputs. Client-side, which is what FileZilla does too.
    var dirCount: Int { entries.filter(\.isDir).count }
    var fileCount: Int { entries.filter { !$0.isDir }.count }
    var byteTotal: Int64 { entries.reduce(0) { $0 + ($1.isDir ? 0 : ($1.size ?? 0)) } }

    func reload() async {
        loading = true
        error = nil
        defer { loading = false }
        // 5000 is api.py's own BROWSE_LIMIT_MAX. Asking for it keeps the status
        // line's file/directory breakdown honest past the default 1000.
        // A refresh that fails must not replace a perfectly good listing with
        // nothing. Losing the relay for one poll used to blank the pane, and the
        // recovery was to navigate away and back. Only a listing for a DIFFERENT
        // directory clears the rows, because then what is on screen really is wrong.
        func fail(_ why: String) {
            error = why
            if loadedPath != path {
                entries = []
                truncatedTotal = nil
            }
        }

        switch await api.browse(path, limit: 5000) {
        case .listing(let l):
            entries = l.entries
            truncatedTotal = l.truncated ? l.total : nil
            loadedPath = path
        case .refused(let why): fail(why)
        case .unauthorized: fail("Token rejected")
        case .unreachable(let why): fail(why)
        }
        selection = selection.filter { p in entries.contains { $0.path == p } }
        // Only reset the filter when the rows actually changed underneath it.
        if error == nil { filter = "" }
        noteRecent(path)
        if error == nil { UserDefaults.standard.set(path, forKey: pathKey) }
    }

    private func noteRecent(_ p: String) {
        guard !p.isEmpty else { return }
        var list = recentDirs.filter { $0 != p }
        list.insert(p, at: 0)
        if list.count > 20 { list.removeLast(list.count - 20) }
        recentDirs = list
    }

    func open(_ entry: Entry) async {
        guard entry.isDir else { return }
        path = entry.path
        selection = []
        await reload()
    }

    func goUp() async {
        guard canGoUp else { return }
        path = (path as NSString).deletingLastPathComponent
        if path.isEmpty { path = "/" }
        selection = []
        await reload()
    }

    func go(to p: String) async {
        path = p
        selection = []
        await reload()
    }
}
