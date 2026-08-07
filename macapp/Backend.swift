import Foundation

/// Which filesystem a pane is looking at.
///
/// `seedbox` and `nas` both live behind the relay; `mac` is the machine the app is
/// running on. The distinction that matters is not "remote vs local" but **who
/// performs the operation** — for the first two the relay does, and validates it
/// with `guards.py`; for the third this process does, with `FileManager`.
enum BackendKind: String, Equatable {
    case seedbox, nas, mac
}

/// One filesystem a pane can browse and act on.
///
/// This exists so the destination pane can be pointed at the Mac without touching
/// the views. `BrowseStore`, `TreeStore` and `SearchStore` used to hold a
/// `RelayAPI` and call it directly, which meant every feature — rename, delete,
/// move, New Folder, the tree, the status line — was wired to the relay by
/// construction. Routing them through this instead means a second implementation
/// gets all of that for free, and the ~20 call sites stay as they are.
///
/// The return types are deliberately the relay's own outcome enums rather than
/// something new. They already model everything a local filesystem needs to say
/// (`refused` carries a message, `clash` carries the colliding name), and reusing
/// them is what lets `ConflictSheet`, `MoveClashSheet` and the rest stay
/// backend-agnostic.
@MainActor
protocol FileBackend: AnyObject {
    var kind: BackendKind { get }
    /// The path above which a pane may not go. `/queue` for the NAS, `/` for the Mac.
    var root: String { get }
    /// Sentence form, for prose: "Searching **the seedbox**…".
    var label: String { get }
    /// Title form, for buttons and toggles: "**NAS**", "**This Mac**".
    var shortLabel: String { get }
    /// False for the Mac. Panes on a backend that does not need the relay stay
    /// usable while the relay is unreachable, instead of being covered by the
    /// offline overlay.
    var needsRelay: Bool { get }
    /// Where `UserDefaults` remembers this backend's last directory. Distinct per
    /// backend so toggling NAS -> Mac -> NAS returns you to the NAS folder you
    /// were in, not to its root.
    var pathKey: String { get }

    func browse(_ path: String, limit: Int?) async -> BrowseResult
    func search(_ query: String, limit: Int?) async -> SearchOutcome
    func stat(_ path: String) async -> StatResultOutcome
    func mkdir(parent: String, name: String) async -> ActionResult
    func mkdirJoining(parent: String, name: String) async -> MkdirOutcome
    func rename(path: String, newName: String) async -> RenameResult
    func delete(_ path: String) async -> ActionResult
    func move(_ path: String, into destDir: String,
              newName: String?, overwrite: Bool) async -> MoveOutcome
    /// Free bytes on the volume holding `path`, or nil if it cannot be determined.
    func freeBytes(for path: String) -> Int64?

    /// The path the row menu measures depth from, which is NOT always `root`: the
    /// seedbox's root is `/seedbox/downloads` but its rows become actionable one
    /// level above that, matching the relay's own `MIN_SRC_DEPTH`.
    var actionableBase: String { get }
    /// What to say when someone tries to send into the root itself.
    var pickAFolderHint: String { get }
    /// How far up the Move sheet may browse. Nil at the ceiling.
    func moveParent(of path: String) -> String?
}

extension FileBackend {
    /// Is this path at least one level below the root? The rule the row menu uses
    /// to decide whether Rename/Delete/Move are offered at all — a volume is not
    /// something you rename.
    func isInsideRoot(_ path: String) -> Bool {
        guard path.hasPrefix(root) else { return false }
        let rest = path.dropFirst(root.count)
        return !rest.split(separator: "/").isEmpty
    }
}

/// The relay-backed filesystems: the seedbox and the NAS.
///
/// A pass-through, deliberately. Every method forwards to the `RelayAPI` call the
/// stores used to make directly, with the same arguments, so both existing panes
/// behave exactly as before.
@MainActor
final class RelayBackend: FileBackend {
    let kind: BackendKind
    private let api: RelayAPI
    /// Free space arrives on `GET /v1/targets` rather than a per-path endpoint, so
    /// the relay's answer is cached here by `RelayStore.loadTargets` and read back
    /// synchronously. Kept on the backend rather than looked up in `RelayStore` so
    /// that `FreeSpaceLabel` can ask whichever backend a pane happens to be on.
    var targets: [Target] = []

    init(kind: BackendKind, api: RelayAPI) {
        self.kind = kind
        self.api = api
    }

    var root: String { kind == .seedbox ? "/seedbox/downloads" : "/queue" }
    var label: String { kind == .seedbox ? "the seedbox" : "the NAS" }
    var shortLabel: String { kind == .seedbox ? "Seedbox" : "NAS" }
    var needsRelay: Bool { true }
    var pathKey: String { "browse.path.\(kind == .seedbox ? "source" : "dest")" }
    var actionableBase: String { kind == .seedbox ? "/seedbox" : "/queue" }
    var pickAFolderHint: String {
        "Pick a destination folder first — /queue itself is the list of volumes"
    }

    /// Stops at the volume: `/queue/MediaVolume3` is as far as a move can go,
    /// because the relay's move is `os.rename` and crossing a drop target would
    /// fail EXDEV.
    func moveParent(of path: String) -> String? {
        let up = (path as NSString).deletingLastPathComponent
        guard up.hasPrefix("/queue/"), up != "/queue" else { return nil }
        return up
    }

    func browse(_ path: String, limit: Int?) async -> BrowseResult {
        await api.browse(path, limit: limit)
    }

    func search(_ query: String, limit: Int?) async -> SearchOutcome {
        await api.search(query, side: kind == .seedbox ? "seedbox" : "nas", limit: limit)
    }

    func stat(_ path: String) async -> StatResultOutcome { await api.stat(path) }

    func mkdir(parent: String, name: String) async -> ActionResult {
        await api.mkdir(parent: parent, name: name)
    }

    func mkdirJoining(parent: String, name: String) async -> MkdirOutcome {
        await api.mkdirJoining(parent: parent, name: name)
    }

    func rename(path: String, newName: String) async -> RenameResult {
        await api.rename(path: path, newName: newName)
    }

    func delete(_ path: String) async -> ActionResult { await api.delete(path) }

    func move(_ path: String, into destDir: String,
              newName: String?, overwrite: Bool) async -> MoveOutcome {
        await api.move(path, into: destDir, newName: newName, overwrite: overwrite)
    }

    /// Longest-prefix match, not first-match: `/queue/Media` and `/queue/Media2`
    /// would both prefix-match a path under the latter, and the shorter one would
    /// report the wrong volume's free space.
    func freeBytes(for path: String) -> Int64? {
        targets
            .filter { path == $0.path || path.hasPrefix($0.path + "/") }
            .max { $0.path.count < $1.path.count }?
            .freeBytes
    }
}
