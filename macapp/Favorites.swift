import SwiftUI

/// Saved locations, per filesystem.
///
/// The curated counterpart to search. Search answers "where is this?" and pays a
/// walk for the answer; most navigation is not that question at all, it is going
/// back to the same handful of folders. The path bar's recents menu already covers
/// the automatic version of this (an MRU of the last 20), so what it does NOT do
/// is the point: keep something because you said to, and keep it whether or not
/// you were there today.
///
/// Deliberately shaped like `SearchStore`. Both own a pane mode, both survive the
/// `reload()` that wipes `BrowseStore.filter`, and both hand a picked row back to
/// the same navigate-and-highlight path — so mirroring it is what keeps a favorite
/// and a search hit behaving identically.
struct Favorite: Codable, Identifiable, Equatable {
    let path: String
    let name: String
    let isDir: Bool

    var id: String { path }

    /// Favorites store no size or mtime on purpose: they would be a snapshot from
    /// whenever the thing was starred, and a stale size shown confidently is worse
    /// than no size at all.
    var entry: Entry {
        Entry(name: name, path: path, isDir: isDir, size: nil, mtime: nil)
    }
}

@MainActor
final class FavoritesStore: ObservableObject {
    /// Whether the pane is in favorites mode. Same idea as `SearchStore.active`,
    /// and the two are mutually exclusive — see `RootView.enterMode`.
    @Published var active = false
    @Published private(set) var items: [Favorite] = []
    private(set) var backend: FileBackend

    init(backend: FileBackend) {
        self.backend = backend
        items = Self.load(backend.kind)
    }

    /// Keyed by KIND, never by pane role.
    ///
    /// `FileBackend.pathKey` uses source/dest because it remembers where a *pane*
    /// was looking. A favorite belongs to a *filesystem*, and either pane can now
    /// show any of the three — so a role-keyed list would hand the NAS's favorites
    /// to the remote server the moment the pickers were swapped.
    private static func key(_ kind: BackendKind) -> String { "favorites.\(kind.rawValue)" }

    private static func load(_ kind: BackendKind) -> [Favorite] {
        guard let data = UserDefaults.standard.data(forKey: key(kind)),
              let list = try? JSONDecoder().decode([Favorite].self, from: data)
        else { return [] }
        return list
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(items) else { return }
        UserDefaults.standard.set(data, forKey: Self.key(backend.kind))
    }

    /// Point at another filesystem. The list is that filesystem's, so it is
    /// reloaded rather than carried over.
    func switchTo(_ next: FileBackend) {
        guard next.kind != backend.kind else { return }
        backend = next
        items = Self.load(next.kind)
        active = false
    }

    /// Leaves favorites mode. Keeps the list, which is the whole point of it.
    func dismiss() { active = false }

    var scopeLabel: String { backend.kind == .nas ? "the NAS" : backend.label }

    /// Alphabetical, by the same natural comparison the file table uses, so
    /// `Season 2` precedes `Season 10`. Path breaks ties, so two folders with the
    /// same name keep a stable order rather than shuffling between launches.
    var sorted: [Favorite] {
        items.sorted {
            let byName = $0.name.localizedStandardCompare($1.name)
            return byName == .orderedSame ? $0.path < $1.path : byName == .orderedAscending
        }
    }

    func contains(_ path: String) -> Bool { items.contains { $0.path == path } }

    func add(_ entry: Entry) {
        guard !contains(entry.path) else { return }
        items.append(Favorite(path: entry.path, name: entry.name, isDir: entry.isDir))
        save()
    }

    /// Adds a path with no Entry to hand — the background menu favouriting the
    /// folder the pane is currently showing.
    func addPath(_ path: String) {
        guard !contains(path), path != "/" else { return }
        items.append(Favorite(path: path,
                              name: (path as NSString).lastPathComponent,
                              isDir: true))
        save()
    }

    func remove(_ path: String) {
        items.removeAll { $0.path == path }
        save()
    }

    /// Follow a path that moved.
    ///
    /// A favorite is a path, and a path is not stable — renaming the thing, or
    /// renaming any FOLDER above it, silently orphans the entry. Rewriting the
    /// prefix keeps the bookmark pointing at the same thing, which is what someone
    /// who saved it meant.
    ///
    /// Descendants matter as much as the item itself: renaming `Season 1` has to
    /// carry every episode favourited inside it, so the match is "equal to, or
    /// underneath" rather than just equal.
    func rename(from old: String, to new: String) {
        guard old != new else { return }
        var changed = false
        items = items.map { fav in
            guard fav.path == old || fav.path.hasPrefix(old + "/") else { return fav }
            changed = true
            let moved = new + fav.path.dropFirst(old.count)
            return Favorite(path: moved,
                            // Only the renamed item itself takes a new name; a
                            // descendant keeps its own and just sits somewhere else.
                            name: fav.path == old
                                ? (new as NSString).lastPathComponent : fav.name,
                            isDir: fav.isDir)
        }
        if changed { save() }
    }

    func toggle(_ entry: Entry) {
        contains(entry.path) ? remove(entry.path) : add(entry)
    }

    var statusText: String {
        if items.isEmpty { return "No favorites on \(scopeLabel) yet." }
        return "\(items.count) favorite\(items.count == 1 ? "" : "s") on \(scopeLabel)."
    }
}


/// One location, as a row.
///
/// Extracted from `SearchResultsList` so a favorite and a search hit are the same
/// two lines in the same geometry — they answer the same question ("where is
/// this?") and reading differently would imply they were different kinds of thing.
struct LocationRow: View {
    let entry: Entry
    /// Favorites carry no size, deliberately; see `Favorite.entry`.
    var showSize = true

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: entry.symbol)
                .font(.system(size: 11.5))
                .foregroundStyle(entry.isDir ? Theme.folderGold : Theme.fileGrey)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 12.5, weight: .medium))
                    // Middle, because the tail of a release name carries the codec
                    // and group — the part you are scanning for.
                    .lineLimit(1).truncationMode(.middle)
                Text(Self.parentPath(entry))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    // Head, because the tail identifies the folder and the
                    // /queue/MediaVolume3 prefix is the disposable part.
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            if showSize {
                Text(entry.sizeLabel)
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 1)
    }

    static func parentPath(_ entry: Entry) -> String {
        let p = (entry.path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
}


/// The saved list. A plain `List`, not `FileTable`, for the same reason
/// `SearchResultsList` is: these rows come from all over the tree, so every one of
/// the five things FileTable derives from `browse.path` would be describing the
/// wrong folder — including the delete gate.
struct FavoritesList: View {
    let items: [Favorite]
    let onPick: (Favorite) -> Void
    let onRemove: (Favorite) -> Void

    var body: some View {
        List(items) { fav in
            LocationRow(entry: fav.entry, showSize: false)
                .contentShape(Rectangle())
                // Single click, matching the tree and the search results: the list
                // is navigation-only, so select-then-open would be ceremony over a
                // choice that carries no other meaning.
                .onTapGesture { onPick(fav) }
                .contextMenu {
                    Button("Go to Enclosing Folder") { onPick(fav) }
                    Button("Copy Path") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(fav.path, forType: .string)
                    }
                    Divider()
                    Button("Remove from Favorites", role: .destructive) { onRemove(fav) }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.listFill)
    }
}


/// The favorites half of the pane, including its empty state.
///
/// Observes the store directly for the same reason `SearchPane` does: SwiftUI
/// treats an unchanged class reference as unchanged, so a parent holding this as a
/// plain property would never re-render when only the contents changed.
struct FavoritesPane: View {
    @ObservedObject var favorites: FavoritesStore
    let onPick: (Favorite) -> Void

    var body: some View {
        if favorites.items.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "star")
                    .font(.system(size: 22, weight: .light))
                    .foregroundStyle(Color.secondary.opacity(0.7))
                // maxWidth is load-bearing, not styling. `fixedSize(vertical:)`
                // means "give me my ideal height at whatever width I am offered",
                // and during sizing a container can offer a very narrow width --
                // at which point a long string wraps to dozens of lines, reports a
                // huge ideal height, and that height propagates up as a MINIMUM.
                // This pane lives in an NSSplitView inside a window with
                // fullSizeContentView, so that minimum grew the window past the
                // screen and pushed it off the bottom. Bounding the width bounds
                // the wrap, and therefore the height.
                Text("No favorites yet. Right-click a folder and choose "
                     + "Add to Favorites, or press ⌘D.")
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 260)
                    .padding(.horizontal, 18)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            FavoritesList(items: favorites.sorted,
                          onPick: onPick,
                          onRemove: { favorites.remove($0.path) })
        }
    }
}


/// The path bar in favorites mode. Replaces the row rather than sitting beside it,
/// exactly as `SearchBar` does and for the same reason: at `Theme.paneMinWidth`
/// there is no room, and in this mode the path field, recents and filter all
/// describe a folder you are not currently in.
struct FavoritesBar: View {
    @ObservedObject var favorites: FavoritesStore
    let onClose: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("FAVORITES")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()
            Text(favorites.scopeLabel)
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            Spacer()
            Button(action: onClose) {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Close favorites (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .onExitCommand(perform: onClose)
        .background(
            Button("", action: onClose)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)
        )
    }
}


/// Same geometry and voice as `ListStatusLine` and `SearchStatusLine`.
struct FavoritesStatusLine: View {
    @ObservedObject var favorites: FavoritesStore

    var body: some View {
        HStack {
            Text(favorites.statusText)
                .font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.statusLineHeight)
    }
}
