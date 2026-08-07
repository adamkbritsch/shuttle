import Foundation

/// Transfers that land on this Mac.
///
/// The relay cannot write here, so when the destination is the Mac the app has to
/// do the moving itself: ask `/v1/manifest` what a thing is made of, then pull each
/// file with `/v1/fetch` and write it to disk.
///
/// Deliberately a mirror of the relay's job model rather than something new — same
/// states, same conflict actions, same one-at-a-time queue — because `TransfersPane`
/// renders both and two different shapes would show up as two different UIs.
///
/// **The honest limitation:** these live in this process. A relay job survives the
/// app quitting and the laptop closing; one of these does not. `LocalJob.note` says
/// so, and anything interrupted is reported as failed rather than quietly dropped.
@MainActor
final class LocalTransfers: NSObject, ObservableObject {
    /// Newest first, like the relay's own list.
    @Published private(set) var jobs: [LocalJob] = []

    private let api: RelayAPI
    private var running = false
    /// Ids are negative so they can never collide with a relay job id in the merged
    /// list, and so a glance at one tells you which engine owns it.
    private var nextID = -1
    private var cancelled = Set<Int>()
    private var task: URLSessionDataTask?

    init(api: RelayAPI) {
        self.api = api
        super.init()
    }

    var active: [LocalJob] { jobs.filter { $0.state == .queued || $0.state == .running } }
    var finished: [LocalJob] { jobs.filter { $0.state != .queued && $0.state != .running } }

    // ---------- queueing ----------

    /// Queue one source (file or folder) into a local directory.
    ///
    /// Returns the job, or nil when an identical one is already waiting — the same
    /// dedupe rule the relay applies, for the same reason: double-clicking Send
    /// should not transfer a thing twice.
    @discardableResult
    func send(src: String, srcName: String, destDir: String,
              destName: String? = nil,
              onConflict: ConflictAction? = nil) -> LocalJob? {
        let name = destName ?? srcName
        let landing = (destDir as NSString).appendingPathComponent(name)
        guard !active.contains(where: { $0.src == src && $0.dest == landing }) else {
            return nil
        }
        let job = LocalJob(id: nextID, src: src, srcName: srcName,
                           dest: landing, destDir: destDir,
                           onConflict: onConflict)
        nextID -= 1
        jobs.insert(job, at: 0)
        Task { await drain() }
        return job
    }

    /// Would this land on something? Answered BEFORE queueing, which is what lets
    /// the existing `ConflictSheet` handle a local send with no changes: the relay
    /// answers the same question with a 409 from `POST /v1/jobs`.
    ///
    /// Only the top-level name is checked, matching the relay — a folder merging
    /// into an existing folder is reported once, not once per file inside it.
    func clash(for srcName: String, in destDir: String,
               destName: String? = nil) -> ConflictReport? {
        let name = destName ?? srcName
        let landing = (destDir as NSString).appendingPathComponent(name)
        let fm = FileManager.default
        guard fm.fileExists(atPath: landing) else { return nil }
        let a = try? fm.attributesOfItem(atPath: landing)
        return ConflictReport(
            destName: name,
            conflicts: [Conflict(path: name,
                                 srcSize: 0, srcMtime: 0,
                                 destSize: (a?[.size] as? NSNumber)?.int64Value ?? 0,
                                 destMtime: (a?[.modificationDate] as? Date)?
                                     .timeIntervalSince1970 ?? 0)],
            truncated: false)
    }

    func cancel(_ id: Int) {
        cancelled.insert(id)
        if let i = jobs.firstIndex(where: { $0.id == id }) {
            if jobs[i].state == .running {
                task?.cancel()
            } else if jobs[i].state == .queued {
                jobs[i].state = .cancelled
                jobs[i].finishedAt = Date().timeIntervalSince1970
            }
        }
    }

    func dismiss(_ id: Int) { jobs.removeAll { $0.id == id && $0.state != .running } }

    func retry(_ id: Int) {
        guard let old = jobs.first(where: { $0.id == id }) else { return }
        send(src: old.src, srcName: old.srcName, destDir: old.destDir,
             destName: (old.dest as NSString).lastPathComponent,
             onConflict: old.onConflict)
    }

    // ---------- the worker ----------

    /// One at a time. Two concurrent pulls would share the same seedbox uplink and
    /// finish no sooner together than in sequence, while making both progress bars
    /// meaningless.
    private func drain() async {
        guard !running else { return }
        running = true
        defer { running = false }

        while let next = jobs.last(where: { $0.state == .queued }) {
            guard !cancelled.contains(next.id) else {
                update(next.id) { $0.state = .cancelled; $0.finishedAt = Date().timeIntervalSince1970 }
                continue
            }
            await run(next.id)
        }
    }

    private func run(_ id: Int) async {
        guard let job = jobs.first(where: { $0.id == id }) else { return }
        update(id) { $0.state = .running; $0.startedAt = Date().timeIntervalSince1970 }

        // 1. What is this made of?
        let manifest: Manifest
        switch await api.manifest(job.src) {
        case .manifest(let m): manifest = m
        case .refused(let why), .unreachable(let why):
            return finish(id, .failed, error: why)
        }
        guard !manifest.files.isEmpty else {
            return finish(id, .failed, error: "Nothing to transfer")
        }
        update(id) { $0.bytesTotal = manifest.bytes; $0.filesTotal = manifest.files.count }

        // 2. Where does each file go? A folder keeps its shape underneath the
        //    destination; a single file lands under the name it was given.
        let fm = FileManager.default
        var done: Int64 = 0
        for (i, file) in manifest.files.enumerated() {
            if cancelled.contains(id) { return finish(id, .cancelled, error: nil) }

            let target = manifest.isDir
                ? (job.dest as NSString).appendingPathComponent(file.rel)
                : job.dest
            let remote = manifest.isDir
                ? (job.src as NSString).appendingPathComponent(file.rel)
                : job.src

            do {
                try fm.createDirectory(
                    atPath: (target as NSString).deletingLastPathComponent,
                    withIntermediateDirectories: true)
            } catch {
                return finish(id, .failed, error: LocalBackend.explain(error, doing: "make that folder"))
            }

            switch Self.decide(job.onConflict, target: target, incoming: file.size) {
            case .skip:
                done += file.size
                update(id) { $0.bytesDone = done; $0.filesDone = i + 1 }
                continue
            case .stop(let why):
                return finish(id, .failed, error: why)
            case .proceed(let finalPath):
                let base = done
                // One retry on a transport failure, and only on a transport failure.
                // This path is meant to work from networks that block a direct
                // seedbox connection, which in practice also means captive portals
                // and DERP-relayed links that drop a connection now and then. Losing
                // a whole release to one dropped socket would be the common case
                // rather than the rare one. A refusal is NOT retried -- it would fail
                // identically the second time.
                var outcome = await fetch(remote, to: finalPath, jobID: id) { got in
                    self.update(id) { $0.bytesDone = base + got }
                }
                if case .failed = outcome, !cancelled.contains(id) {
                    update(id) { $0.bytesDone = base }
                    outcome = await fetch(remote, to: finalPath, jobID: id) { got in
                        self.update(id) { $0.bytesDone = base + got }
                    }
                }
                if case .failed(let why) = outcome {
                    return finish(id, cancelled.contains(id) ? .cancelled : .failed, error: why)
                }
                done += file.size
                update(id) { $0.bytesDone = done; $0.filesDone = i + 1 }
            }
        }
        finish(id, .done, error: nil)
    }

    private enum Decision { case proceed(String); case skip; case stop(String) }

    /// The five `ConflictAction` cases against `FileManager` attributes, rather than
    /// the rclone flags the relay maps them to. Same meanings, so `ConflictSheet`
    /// needs no local variant.
    private static func decide(_ action: ConflictAction?,
                               target: String, incoming: Int64) -> Decision {
        let fm = FileManager.default
        guard fm.fileExists(atPath: target) else { return .proceed(target) }

        let attrs = try? fm.attributesOfItem(atPath: target)
        let existingSize = (attrs?[.size] as? NSNumber)?.int64Value ?? -1
        let existingDate = attrs?[.modificationDate] as? Date ?? .distantPast

        switch action {
        case .none:
            // "Ask" is answered before queueing — see `clash(for:)`. Reaching here
            // means a file appeared underneath a folder transfer after it started,
            // and skipping is the only answer that cannot destroy anything.
            return .skip
        case .overwrite:      return .proceed(target)
        case .skip:           return .skip
        case .overwriteNewer:
            // "Newer" means the incoming one. Its mtime is not in the manifest, so
            // the only honest reading is "the copy being made now is newer than a
            // file already sitting there" — true whenever the existing one predates
            // this transfer.
            return existingDate < Date() ? .proceed(target) : .skip
        case .overwriteSize:
            return existingSize != incoming ? .proceed(target) : .skip
        case .overwriteSizeOrNewer:
            return existingSize != incoming || existingDate < Date() ? .proceed(target) : .skip
        case .rename:
            return .proceed(Self.freeName(beside: target))
        }
    }

    /// `name.mkv` -> `name (1).mkv`, the way Finder does it.
    private static func freeName(beside path: String) -> String {
        let ns = path as NSString
        let dir = ns.deletingLastPathComponent
        let ext = ns.pathExtension
        let stem = (ns.lastPathComponent as NSString).deletingPathExtension
        var n = 1
        while true {
            let candidate = ext.isEmpty ? "\(stem) (\(n))" : "\(stem) (\(n)).\(ext)"
            let full = (dir as NSString).appendingPathComponent(candidate)
            if !FileManager.default.fileExists(atPath: full) { return full }
            n += 1
        }
    }

    private enum FetchOutcome { case ok; case failed(String) }

    /// Writes to `<target>.part` and moves into place only on success, so an
    /// interrupted transfer can never be mistaken for a complete file — the one
    /// thing that would matter later, when something plays half a movie.
    private func fetch(_ remote: String, to target: String, jobID: Int,
                       progress: @escaping (Int64) -> Void) async -> FetchOutcome {
        let part = target + ".part"
        FileManager.default.createFile(atPath: part, contents: nil)
        guard let handle = FileHandle(forWritingAtPath: part) else {
            return .failed("Could not create \((part as NSString).lastPathComponent)")
        }
        defer { try? handle.close() }

        do {
            var written: Int64 = 0
            for try await chunk in await api.fetchStream(remote) {
                if cancelled.contains(jobID) {
                    try? FileManager.default.removeItem(atPath: part)
                    return .failed("Cancelled")
                }
                try handle.write(contentsOf: chunk)
                written += Int64(chunk.count)
                progress(written)
            }
            try handle.close()
            // Replace rather than fail: `decide` already said this may be written,
            // and the existing file at this point is a previous version, not news.
            if FileManager.default.fileExists(atPath: target) {
                try FileManager.default.removeItem(atPath: target)
            }
            try FileManager.default.moveItem(atPath: part, toPath: target)
            return .ok
        } catch {
            try? FileManager.default.removeItem(atPath: part)
            if cancelled.contains(jobID) { return .failed("Cancelled") }
            return .failed(LocalBackend.explain(error, doing: "write that file"))
        }
    }

    // ---------- bookkeeping ----------

    private func update(_ id: Int, _ edit: (inout LocalJob) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        edit(&jobs[i])
    }

    private func finish(_ id: Int, _ state: LocalJob.State, error: String?) {
        update(id) {
            $0.state = state
            $0.error = error
            $0.finishedAt = Date().timeIntervalSince1970
        }
        cancelled.remove(id)
    }
}

/// One transfer onto this Mac.
struct LocalJob: Identifiable, Equatable {
    enum State: String { case queued, running, done, failed, cancelled }

    let id: Int
    let src: String
    let srcName: String
    /// Where it lands, in full.
    let dest: String
    let destDir: String
    let onConflict: ConflictAction?

    var state: State = .queued
    var bytesDone: Int64 = 0
    var bytesTotal: Int64 = 0
    var filesDone = 0
    var filesTotal = 0
    var error: String?
    var startedAt: Double?
    var finishedAt: Double?

    var name: String { (dest as NSString).lastPathComponent }
    var pct: Double {
        bytesTotal > 0 ? min(1, Double(bytesDone) / Double(bytesTotal)) : 0
    }
    /// Shown on every local row. See the type comment on `LocalTransfers`.
    var note: String { "on this Mac — stops if Shuttle quits" }
}

/// What `/v1/manifest` answers: a path flattened to the files it contains.
struct Manifest: Decodable, Equatable {
    struct File: Decodable, Equatable {
        let rel: String
        let size: Int64
    }
    let path: String
    let isDir: Bool
    let files: [File]
    let bytes: Int64

    enum CodingKeys: String, CodingKey {
        case path, files, bytes
        case isDir = "is_dir"
    }
}

enum ManifestOutcome { case manifest(Manifest); case refused(String); case unreachable(String) }
