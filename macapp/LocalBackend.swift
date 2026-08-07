import Foundation

/// This Mac, as a filesystem a pane can browse and act on.
///
/// Everything here is `FileManager` and Spotlight, so it is instant and works with
/// the relay unreachable. It answers the relay's own outcome types (`BrowseResult`,
/// `MoveOutcome`, …) because the views were written against those — matching the
/// shape is what makes the Mac pane free rather than a second UI.
///
/// Two deliberate departures from the relay's behaviour, both in the safer
/// direction:
///
/// - **Delete goes to the Trash**, not `unlink`. The NAS side is depth-guarded by
///   `guards.py` so a slip cannot reach a whole volume; browsing the Mac is
///   unrestricted by choice, and recoverability is what replaces that guard.
/// - **A handful of paths refuse to be deleted at all** — see `undeletable`. Not a
///   browsing restriction; it only stops the slip you cannot undo.
@MainActor
final class LocalBackend: FileBackend {
    let kind: BackendKind = .mac
    var root: String { "/" }
    var label: String { "this Mac" }
    var shortLabel: String { "This Mac" }
    var needsRelay: Bool { false }
    var pathKey: String { "browse.path.mac" }
    var actionableBase: String { "/" }
    var pickAFolderHint: String { "Pick a folder first — / itself is not a destination" }

    /// No volume ceiling: `FileManager` copies across volumes when it has to, so a
    /// move can go all the way up. It still stops at `/`, which is not a folder you
    /// file things into.
    func moveParent(of path: String) -> String? {
        let up = (path as NSString).deletingLastPathComponent
        return up == "/" || up == path ? nil : up
    }

    private let fm = FileManager.default

    /// Deleting any of these is unrecoverable or breaks the machine, and no
    /// legitimate use of this app involves it. Everything else is fair game, which
    /// is what "browse anywhere" was chosen to mean.
    private var undeletable: Set<String> {
        ["/", "/System", "/Users", "/Applications", "/Volumes",
         NSHomeDirectory()]
    }

    // ---------- listing ----------

    /// Hidden files stay hidden, matching Finder's default. Showing every dotfile
    /// at `/` or `~` would bury the folders you are actually aiming at.
    func browse(_ path: String, limit: Int?) async -> BrowseResult {
        let cap = limit ?? 5000
        let url = URL(fileURLWithPath: path)
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return .refused("There is nothing at \(path)")
        }
        guard isDir.boolValue else { return .refused("\(path) is a file, not a folder") }

        let rows: [Entry]
        do {
            rows = try await Self.readDirectory(url)
        } catch {
            return .refused(Self.explain(error, doing: "list that folder"))
        }
        let sorted = rows.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        let page = Array(sorted.prefix(cap))
        return .listing(Listing(path: path,
                                parent: path == "/" ? nil : (path as NSString).deletingLastPathComponent,
                                entries: page,
                                total: sorted.count,
                                limit: cap,
                                truncated: sorted.count > page.count))
    }

    /// Off the main actor: a folder with thousands of entries costs a `stat` each,
    /// and the pane should not hitch while that runs.
    private nonisolated static func readDirectory(_ url: URL) async throws -> [Entry] {
        try await Task.detached(priority: .userInitiated) {
            let keys: [URLResourceKey] = [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey]
            let kids = try FileManager.default.contentsOfDirectory(
                at: url, includingPropertiesForKeys: keys,
                options: [.skipsHiddenFiles])
            return kids.map { child -> Entry in
                let v = try? child.resourceValues(forKeys: Set(keys))
                let dir = v?.isDirectory ?? false
                return Entry(name: child.lastPathComponent,
                             path: child.path,
                             isDir: dir,
                             // Directories report no size, exactly as the relay's
                             // listing does — a folder's size is what `stat` is for.
                             size: dir ? nil : Int64(v?.fileSize ?? 0),
                             mtime: v?.contentModificationDate?.timeIntervalSince1970)
            }
        }.value
    }

    // ---------- stat ----------

    /// Recursive size and file count, the same question `GET /v1/stat` answers, and
    /// used for the same things: the delete sheet's total and the replace sheet's
    /// before/after.
    func stat(_ path: String) async -> StatResultOutcome {
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: path, isDirectory: &isDir) else {
            return .refused("There is nothing at \(path)")
        }
        if !isDir.boolValue {
            let size = (try? URL(fileURLWithPath: path)
                .resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            return .stat(StatResult(path: path, isDir: false, files: 1, bytes: Int64(size)))
        }
        let (files, bytes) = await Self.measure(path)
        return .stat(StatResult(path: path, isDir: true, files: files, bytes: bytes))
    }

    private nonisolated static func measure(_ path: String) async -> (Int, Int64) {
        await Task.detached(priority: .userInitiated) { () -> (Int, Int64) in
            var files = 0
            var bytes: Int64 = 0
            let url = URL(fileURLWithPath: path)
            let e = FileManager.default.enumerator(
                at: url, includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
                options: [])
            while let next = e?.nextObject() as? URL {
                let v = try? next.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
                if v?.isRegularFile == true {
                    files += 1
                    bytes += Int64(v?.fileSize ?? 0)
                }
            }
            return (files, bytes)
        }.value
    }

    // ---------- mutations ----------

    func mkdir(parent: String, name: String) async -> ActionResult {
        switch make(parent: parent, name: name, joining: false) {
        case .made(let p):    return .ok("Created \((p as NSString).lastPathComponent)")
        case .joined(let p):  return .ok("Created \((p as NSString).lastPathComponent)")
        case .refused(let w): return .refused(w)
        case .unreachable(let w): return .refused(w)
        }
    }

    func mkdirJoining(parent: String, name: String) async -> MkdirOutcome {
        make(parent: parent, name: name, joining: true)
    }

    private func make(parent: String, name: String, joining: Bool) -> MkdirOutcome {
        guard let bad = Self.badName(name) else {
            let path = (parent as NSString).appendingPathComponent(name)
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir) {
                guard joining else { return .refused("“\(name)” already exists here") }
                guard isDir.boolValue else {
                    return .refused("“\(name)” is a file, so nothing can be filed into it")
                }
                return .joined(path)
            }
            do {
                try fm.createDirectory(atPath: path, withIntermediateDirectories: false)
                return .made(path)
            } catch {
                return .refused(Self.explain(error, doing: "create that folder"))
            }
        }
        return .refused(bad)
    }

    /// The Mac has no equivalent of the relay's deferred rename — nothing here is
    /// writing into the folder behind your back — so this only ever answers
    /// `.renamed`.
    func rename(path: String, newName: String) async -> RenameResult {
        if let bad = Self.badName(newName) { return .refused(bad) }
        let dest = ((path as NSString).deletingLastPathComponent as NSString)
            .appendingPathComponent(newName)
        if dest == path { return .renamed(dest) }
        guard !fm.fileExists(atPath: dest) else {
            return .refused("“\(newName)” already exists here")
        }
        do {
            try fm.moveItem(atPath: path, toPath: dest)
            return .renamed(dest)
        } catch {
            return .refused(Self.explain(error, doing: "rename that"))
        }
    }

    /// To the Trash, not `unlink`. See the type comment.
    func delete(_ path: String) async -> ActionResult {
        let clean = (path as NSString).standardizingPath
        if undeletable.contains(clean) {
            return .refused("“\(clean)” is not something this app will delete")
        }
        guard fm.fileExists(atPath: path) else { return .refused("There is nothing at \(path)") }
        do {
            try fm.trashItem(at: URL(fileURLWithPath: path), resultingItemURL: nil)
            return .ok("Moved to Trash")
        } catch {
            return .refused(Self.explain(error, doing: "move that to the Trash"))
        }
    }

    /// Unlike the relay's move — `os.rename`, refused across drop targets because
    /// it would fail EXDEV — `FileManager` copies across volumes when it has to.
    /// So this is not volume-bounded, and the Move sheet lets you leave the volume
    /// on the Mac side.
    func move(_ path: String, into destDir: String,
              newName: String?, overwrite: Bool) async -> MoveOutcome {
        let name = newName ?? (path as NSString).lastPathComponent
        if let bad = Self.badName(name) { return .refused(bad) }
        let dest = (destDir as NSString).appendingPathComponent(name)

        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: destDir, isDirectory: &isDir), isDir.boolValue else {
            return .refused("\(destDir) is not a folder")
        }
        if dest == path { return .moved(dest) }
        // Moving a folder inside itself would lose it. `os.rename` refuses this and
        // so does FileManager, but the message would be a code number.
        if (dest + "/").hasPrefix(path + "/") {
            return .refused("A folder cannot be moved inside itself")
        }
        if fm.fileExists(atPath: dest) {
            guard overwrite else {
                return .clash(name: name, existing: dest)
            }
            do { try fm.removeItem(atPath: dest) }
            catch { return .refused(Self.explain(error, doing: "replace that")) }
        }
        do {
            try fm.moveItem(atPath: path, toPath: dest)
            return .moved(dest)
        } catch {
            return .refused(Self.explain(error, doing: "move that"))
        }
    }

    // ---------- free space ----------

    func freeBytes(for path: String) -> Int64? {
        let v = try? URL(fileURLWithPath: path).resourceValues(
            forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return v?.volumeAvailableCapacityForImportantUsage
    }

    // ---------- search ----------

    /// Spotlight, not a walk. The index already exists and answers in milliseconds,
    /// where walking from `/` would take minutes and duplicate work the OS has
    /// already done. The cost is Spotlight's own blind spots — anything on a volume
    /// with indexing switched off will not be found, which the status line says.
    func search(_ query: String, limit: Int?) async -> SearchOutcome {
        let cap = limit ?? 500
        let started = Date()
        let hits = await Self.spotlight(query)
        let elapsed = Int(Date().timeIntervalSince(started) * 1000)
        let page = Array(hits.prefix(cap))
        return .results(SearchResults(query: query,
                                      entries: page,
                                      total: hits.count,
                                      limit: cap,
                                      truncated: hits.count > page.count,
                                      timedOut: false,
                                      elapsedMs: elapsed))
    }

    private static func spotlight(_ query: String) async -> [Entry] {
        await withCheckedContinuation { (cont: CheckedContinuation<[Entry], Never>) in
            let q = NSMetadataQuery()
            q.predicate = NSPredicate(format: "kMDItemFSName LIKE[cd] %@", "*\(query)*")
            q.searchScopes = [NSMetadataQueryLocalComputerScope]
            q.sortDescriptors = [NSSortDescriptor(key: NSMetadataItemFSNameKey, ascending: true)]

            // The observer keeps itself alive until it fires, then tears the whole
            // thing down. Without holding `q`, ARC would release the query mid-flight
            // and the notification would never arrive.
            var token: NSObjectProtocol?
            token = NotificationCenter.default.addObserver(
                forName: .NSMetadataQueryDidFinishGathering,
                object: q, queue: .main
            ) { _ in
                q.stop()
                if let token { NotificationCenter.default.removeObserver(token) }
                var out: [Entry] = []
                out.reserveCapacity(q.resultCount)
                for i in 0..<q.resultCount {
                    guard let item = q.result(at: i) as? NSMetadataItem,
                          let path = item.value(forAttribute: NSMetadataItemPathKey) as? String
                    else { continue }
                    let isDir = (item.value(forAttribute: NSMetadataItemContentTypeKey)
                                 as? String) == "public.folder"
                    let size = item.value(forAttribute: NSMetadataItemFSSizeKey) as? NSNumber
                    let mtime = item.value(forAttribute: NSMetadataItemFSContentChangeDateKey) as? Date
                    out.append(Entry(name: (path as NSString).lastPathComponent,
                                     path: path,
                                     isDir: isDir,
                                     size: isDir ? nil : size?.int64Value,
                                     mtime: mtime?.timeIntervalSince1970))
                }
                cont.resume(returning: out)
            }
            q.start()
        }
    }

    // ---------- shared ----------

    /// The same three refusals `guards.py` makes, so a bad name is rejected with the
    /// same words whichever side you are on. Returns nil when the name is fine.
    static func badName(_ name: String) -> String? {
        if name.isEmpty { return "A name cannot be empty" }
        if name == "." || name == ".." { return "“\(name)” is not a name" }
        if name.contains("/") { return "A name cannot contain a slash" }
        return nil
    }

    /// `FileManager` errors surface as "The operation couldn’t be completed",
    /// which tells you nothing. Name the two that actually happen.
    static func explain(_ error: Error, doing what: String) -> String {
        let ns = error as NSError
        switch ns.code {
        case NSFileWriteNoPermissionError, NSFileReadNoPermissionError:
            return "No permission to \(what) — macOS may need to grant Shuttle access to that folder"
        case NSFileWriteOutOfSpaceError:
            return "Not enough room to \(what)"
        default:
            return "Could not \(what): \(ns.localizedDescription)"
        }
    }
}
