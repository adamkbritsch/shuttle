import Foundation
import SwiftUI

struct Toast: Equatable {
    let text: String
    let isError: Bool
}

/// Connection state + the transfer list.
/// One "a transfer just landed" signal. See `RelayStore.landedIn` for why it is
/// not simply the list of folders.
struct Landing: Equatable {
    var seq = 0
    var dirs: [String] = []
}

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

    /// Destination folders a transfer has just finished writing into. The panes
    /// watch this and reload only if they are showing one of them.
    ///
    /// Carries a sequence number because SwiftUI compares by VALUE: two transfers
    /// finishing into the same folder — the ordinary case, a season of episodes —
    /// would publish an identical array, and the second landing would silently
    /// never refresh anything.
    @Published private(set) var landedIn = Landing()

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
        case .unauthorized:
            status = .offline(.unauthorized); show("Token rejected", isError: true); return false
        case .refused(let why), .unreachable(let why): show(why, isError: true); return false
        }
    }

    /// What a bulk rename actually did. `renamed` decides whether the caller reloads:
    /// a deferred rename has changed nothing on disk yet.
    struct BulkRenameOutcome {
        var renamed = 0
        var deferred = 0
        var failures: [String] = []
        var aborted = false
    }

    /// Runs a batch of renames in the order the plan gives them, and emits exactly
    /// ONE toast for the lot.
    ///
    /// Calls `api.rename` directly rather than `rename(path:newName:)` above, which
    /// toasts per call — twenty renames would fire twenty toasts, each replacing the
    /// last, so the only one you would ever read is whichever finished last.
    ///
    /// Sequential, and that is required rather than merely tidy: `plan.steps` is
    /// ordered so a name is freed before the next step wants it, which concurrency
    /// would destroy.
    func renameMany(_ steps: [BulkRenameStep]) async -> BulkRenameOutcome {
        var out = BulkRenameOutcome()
        for step in steps {
            switch await api.rename(path: step.path, newName: step.newName) {
            case .renamed:
                out.renamed += 1
            case .deferred:
                out.deferred += 1
            case .refused(let why):
                // One refusal must not stop the rest: a single item being written
                // into by a transfer should not block the other nineteen.
                out.failures.append(why)
            case .unauthorized:
                // The token is wrong, so every remaining call is wrong the same way.
                // Stop, and put the app offline rather than reporting N refusals that
                // all mean "check Settings".
                status = .offline(.unauthorized)
                out.failures.append("Token rejected")
                out.aborted = true
                show("Token rejected", isError: true)
                return out
            case .unreachable(let why):
                // The relay is gone. Every remaining call would burn its own timeout,
                // so stop rather than making the user wait 8s x N to be told the same
                // thing repeatedly.
                out.failures.append(why)
                out.aborted = true
                show(why, isError: true)
                return out
            }
        }

        let total = steps.count
        if out.failures.isEmpty {
            if out.deferred > 0 {
                let unit = out.deferred == 1 ? "transfer finishes" : "transfers finish"
                show(out.renamed > 0
                     ? "Renamed \(out.renamed) — \(out.deferred) will be renamed when their \(unit)"
                     : "\(out.deferred) will be renamed when their \(unit)", isError: false)
            } else {
                show("Renamed \(out.renamed) item\(out.renamed == 1 ? "" : "s")", isError: false)
            }
        } else {
            // The first failure verbatim, not a list: the toast is capped at two
            // lines, and the pane itself reports the rest (see below).
            show("Renamed \(out.renamed) of \(total) — \(out.failures[0])", isError: true)
        }
        return out
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
            // A job that was active and no longer is has just landed something on
            // disk. That is a FACT the app already knows, a second before the user
            // would think to press refresh — so publish it and let the panes react.
            // Signal-driven, not a timer: a timer would either be too slow to be
            // useful or refresh constantly for nothing.
            let wasActive = Set(active.map(\.id))
            let stillActive = Set(p.active.map(\.id))
            let finished = p.recent.filter {
                wasActive.contains($0.id) && !stillActive.contains($0.id)
            }
            if !finished.isEmpty {
                landedIn = Landing(seq: landedIn.seq &+ 1,
                                   dirs: finished.map(\.destDir))
            }
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
              destName: String? = nil,
              replace: String? = nil) async -> ConflictReport? {
        var pending: ConflictReport?
        switch await api.enqueue(src: src, destDir: destDir,
                                 onConflict: onConflict, destName: destName,
                                 replace: replace) {
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
    /// -> the folder's path, and whether it had to be created. Nil means refused;
    /// the message has already been shown.
    func folderFor(parent: String, name: String) async -> (path: String, created: Bool)? {
        switch await api.mkdirJoining(parent: parent, name: name) {
        case .made(let p):   return (p, true)
        case .joined(let p): return (p, false)
        case .refused(let why): show(why, isError: true); return nil
        case .unreachable(let why): show(why, isError: true); return nil
        }
    }

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
    /// Not private: the row menu needs it to tell a file sitting in a release
    /// folder from one loose at the source root, where the "parent" carries no
    /// information about the film.
    var rootPath: String { mode == .seedbox ? "/seedbox/downloads" : "/queue" }

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
    ///
    /// Branches on reload's own outcome rather than on `entries.isEmpty`: once a
    /// failed refresh started PRESERVING the previous rows, a remembered folder that
    /// had been deleted left entries non-empty, so this never fired and the pane sat
    /// on a directory that no longer exists.
    func restoreOrFallback() async {
        let ok = await reload()
        if !ok, path != rootPath {
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

    /// Reads `visibleEntries`, not `entries`: the Table's selection is our own Set
    /// and nothing prunes it when a row leaves the filter (typing deliberately never
    /// triggers a listing), so selecting five and then filtering down to two used to
    /// send all five. That contradicted the comment above and is the kind of surprise
    /// that copies files you did not ask for.
    var selectedEntries: [Entry] { visibleEntries.filter { selection.contains($0.path) } }

    // Status-line inputs. Client-side, which is what FileZilla does too.
    var dirCount: Int { entries.filter(\.isDir).count }
    var fileCount: Int { entries.filter { !$0.isDir }.count }
    var byteTotal: Int64 { entries.reduce(0) { $0 + ($1.isDir ? 0 : ($1.size ?? 0)) } }

    /// Bumped by every reload, so an answer that arrives after a newer request
    /// started can be dropped instead of published.
    ///
    /// There is no in-flight guard here, deliberately — unlike `poll()`, a second
    /// reload is usually the user navigating and must not be ignored. But the rows
    /// stay clickable while a listing is in the air, so clicking folder A and then
    /// folder B lets A's slower answer land second and publish A's rows while `path`
    /// says B. A pane that disagrees with its own path bar is worse than one that
    /// blanks, and it also stamped `loadedPath` with the wrong directory, which is
    /// what the preserve-on-failure rule below keys off.
    private var reloadGeneration = 0

    /// Returns whether the listing actually succeeded, so callers do not have to
    /// infer it from `entries.isEmpty` — which stopped being a reliable proxy once a
    /// failed refresh started preserving the previous rows.
    @discardableResult
    func reload() async -> Bool {
        reloadGeneration &+= 1
        let mine = reloadGeneration
        // Captured, because `path` is mutable and this function suspends: `go(to:)`
        // sets it and calls straight in here, so by the time the answer lands it may
        // already describe a different directory.
        let requested = path

        loading = true
        error = nil
        // 5000 is api.py's own BROWSE_LIMIT_MAX. Asking for it keeps the status
        // line's file/directory breakdown honest past the default 1000.
        let result = await api.browse(requested, limit: 5000)

        // Something newer is already in flight; it owns the pane now.
        guard mine == reloadGeneration else { return false }
        loading = false

        // A refresh that fails must not replace a perfectly good listing with
        // nothing. Losing the relay for one poll used to blank the pane, and the
        // recovery was to navigate away and back. Only a listing for a DIFFERENT
        // directory clears the rows, because then what is on screen really is wrong.
        func fail(_ why: String) {
            error = why
            if loadedPath != requested {
                entries = []
                truncatedTotal = nil
            }
        }

        var ok = false
        switch result {
        case .listing(let l):
            entries = l.entries
            truncatedTotal = l.truncated ? l.total : nil
            loadedPath = requested
            // Cleared on success too, not only on entry: an overlapping reload that
            // failed would otherwise leave its banner sitting over a good listing,
            // and both the filter reset and the path persistence below are gated on
            // `error` being nil.
            error = nil
            ok = true
        case .refused(let why): fail(why)
        case .unauthorized: fail("Token rejected")
        case .unreachable(let why): fail(why)
        }
        selection = selection.filter { p in entries.contains { $0.path == p } }
        // Only reset the filter when the rows actually changed underneath it.
        if ok { filter = "" }
        noteRecent(requested)
        if ok { UserDefaults.standard.set(requested, forKey: pathKey) }
        return ok
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

    /// `revealing` selects one entry after the listing lands — how a search result
    /// is shown in its real folder. A defaulted parameter so every existing caller
    /// (path bar, recents menu, tree, delete recovery) is untouched.
    func go(to p: String, revealing reveal: String? = nil) async {
        path = p
        selection = []
        let ok = await reload()
        // AFTER the reload, and only on success: reload() prunes `selection` to
        // entries that exist, so setting it first would be wiped -- and a failed
        // listing must not leave a selection pointing at rows nobody can see.
        if ok, let reveal, entries.contains(where: { $0.path == reveal }) {
            selection = [reveal]
        }
    }
}
