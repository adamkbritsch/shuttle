import SwiftUI
import UniformTypeIdentifiers

// MARK: - Column helpers

extension Entry {
    /// One formatter for the whole app. `Entry.detail` used to build a DateFormatter
    /// per row per render — invisible in a 20-row List, a real cost in a Table that
    /// can hold thousands.
    static let stamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f
    }()

    var sizeLabel: String {
        // FileZilla leaves the size cell blank for directories; so does this.
        guard !isDir, let size else { return "" }
        return humanBytes(size)
    }

    var stampLabel: String {
        guard let mtime else { return "" }
        return Entry.stamp.string(from: Date(timeIntervalSince1970: mtime))
    }

    var kindLabel: String {
        if isDir { return "Folder" }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return "File" }
        if let t = UTType(filenameExtension: ext), let d = t.localizedDescription {
            return d
        }
        return ext.uppercased() + " file"
    }

    /// Sort keys. Directories carry -1 so they never interleave by size.
    var sortSize: Int64 { isDir ? -1 : (size ?? 0) }
    var sortDate: Double { mtime ?? 0 }
    var sortName: NaturalName { NaturalName(name) }
    var sortKind: NaturalName { NaturalName(kindLabel) }
}

/// A name that sorts the way Finder sorts, wrapped so it can still be reached
/// through a KeyPathComparator and keep the table's comparator array homogeneous.
///
/// Swift's `<` on String compares Unicode scalars, which is wrong twice over for
/// filenames. Measured on a real episode listing:
///
///   plain `<`      Episode 1 | Episode 10 | Episode 11 | Episode 2 | Episode 20 | Episode 3
///   this           Episode 1 | Episode 2 | Episode 3 | Episode 10 | Episode 11 | Episode 20
///
/// It also folds case, so `ep01`, `EP02` and `Ep10` group together instead of every
/// lowercase name being stranded after every uppercase one. `.numeric` alone fixes the
/// digits but not the case; localizedStandardCompare is what Finder itself uses.
struct NaturalName: Comparable {
    let value: String
    init(_ value: String) { self.value = value }

    static func < (a: NaturalName, b: NaturalName) -> Bool {
        a.value.localizedStandardCompare(b.value) == .orderedAscending
    }

    static func == (a: NaturalName, b: NaturalName) -> Bool {
        a.value.localizedStandardCompare(b.value) == .orderedSame
    }
}

// MARK: - The table

/// FileZilla-style file list: sortable, resizable, reorderable columns, with
/// directories pinned above files and a ".." row pinned above everything.
struct FileTable: View {
    @ObservedObject var browse: BrowseStore
    /// Distinguishes the two panes' persisted column layouts.
    let paneKey: String
    /// Source pane only: queue these for transfer. Empty on the destination side.
    var onAddToQueue: ([Entry]) -> Void = { _ in }
    /// The destination the source pane would send to, for the menu item's wording.
    var destinationName: String = ""
    /// NAS side only: ask to rename this item.
    var onRename: (Entry) -> Void = { _ in }
    var onDelete: ([Entry]) -> Void = { _ in }
    var onNewFolder: () -> Void = { }
    var onQueueRenamed: (Entry, String) -> Void = { _, _ in }
    var onBulkRename: ([Entry]) -> Void = { _ in }

    @State private var sortOrder = [KeyPathComparator(\Entry.sortName)]
    @State private var customization = TableColumnCustomization<Entry>()
    @State private var loadedCustomization = false

    private var defaultsKey: String { "table.columns.\(paneKey)" }

    /// Directories first, then the user's chosen sort. FileZilla's
    /// "Prioritize directories" default, and it also stops a header click from
    /// fighting api.py's own dirs-first ordering.
    /// FileZilla pins ".." to row 0. It has to live INSIDE the table (rendering it
    /// above the table put it above the column header, which looked detached), so it
    /// is synthesised here and forced first past any sort order.
    private var parentEntry: Entry? {
        guard browse.canGoUp else { return nil }
        let up = (browse.path as NSString).deletingLastPathComponent
        return Entry(name: "..", path: up.isEmpty ? "/" : up,
                     isDir: true, size: nil, mtime: nil)
    }

    private var rows: [Entry] {
        let ordered = browse.visibleEntries.sorted(using: sortOrder)
        // Partitioned, not sorted a second time. The old second `sorted` returned
        // false for same-kind pairs and relied on that preserving the first sort's
        // order — but Swift's sort is introsort and is NOT documented as stable, so
        // that only held because small arrays fall back to insertion sort. `filter`
        // does guarantee order, and it is O(n) rather than another O(n log n) pass
        // over a comparator that is now considerably more expensive.
        let sorted = ordered.filter(\.isDir) + ordered.filter { !$0.isDir }
        return (parentEntry.map { [$0] } ?? []) + sorted
    }

    private func isParent(_ e: Entry) -> Bool { e.name == ".." }

    var body: some View {
        VStack(spacing: 0) {
            Table(rows, selection: $browse.selection,
                  sortOrder: $sortOrder, columnCustomization: $customization) {
                TableColumn("Filename", sortUsing: KeyPathComparator(\Entry.sortName)) { e in
                    HStack(spacing: 6) {
                        Image(systemName: isParent(e) ? "arrow.turn.left.up" : e.symbol)
                            .font(.system(size: 11.5))
                            .foregroundStyle(isParent(e)
                                             ? Color.secondary
                                             : (e.isDir ? Theme.folderGold : Theme.fileGrey))
                        Text(e.name)
                            .font(.system(size: 12.5,
                                          design: isParent(e) ? .monospaced : .default))
                            .lineLimit(1)
                            // Middle rather than tail: on a release name the tail
                            // carries the codec and group, which is exactly the part
                            // you are scanning for.
                            .truncationMode(.middle)
                    }
                }
                .width(min: 140, ideal: 300)
                // Permanently first and visible, like FileZilla's `fixed` column flag.
                .disabledCustomizationBehavior([.visibility, .reorder])
                .customizationID("name")

                TableColumn("Filesize", sortUsing: KeyPathComparator(\Entry.sortSize)) { e in
                    Text(e.sizeLabel)
                        .font(.system(size: 11.5, design: .monospaced))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .width(min: 62, ideal: 78, max: 160)
                .alignment(.trailing)
                .customizationID("size")

                TableColumn("Filetype", sortUsing: KeyPathComparator(\Entry.sortKind)) { e in
                    Text(e.kindLabel).font(.system(size: 11.5)).lineLimit(1)
                }
                .width(min: 70, ideal: 120)
                // Hidden by default: it is what lets a pane stay usable at 330pt.
                .defaultVisibility(.hidden)
                .customizationID("kind")

                TableColumn("Last modified", sortUsing: KeyPathComparator(\Entry.sortDate)) { e in
                    Text(e.stampLabel).font(.system(size: 11.5, design: .monospaced)).lineLimit(1)
                }
                .width(min: 112, ideal: 132)
                .customizationID("modified")
            }
            // Alternating backgrounds are OFF entirely. They paint their banding across
            // the whole scroll area, not just occupied rows, so a short listing showed
            // a stack of grey phantom rows below the real ones that read as a broken
            // skeleton loader. Finder still stripes; Transmit and ForkLift do not, and
            // without it the pane reads as one clean surface. Hover and selection
            // carry row tracking on their own.
            .tableStyle(.inset(alternatesRowBackgrounds: false))
            .scrollContentBackground(.hidden)
            .background(Theme.listFill)
            .overlay {
                if browse.entries.isEmpty && !browse.loading {
                    emptyState
                }
            }
            .contextMenu(forSelectionType: String.self) { paths in
                // Right-clicking a row outside the selection passes just that row,
                // which is FileZilla's behaviour too. Bulk rename needs the SAME set
                // in drawing order, so it is resolved separately rather than
                // reordering everything else.
                rowMenu(for: resolve(paths), ordered: resolveOrdered(paths))
            } primaryAction: { paths in
                // FileZilla's two double-click actions, both of them:
                // "Dir doubleclick action = Enter directory" and
                // "File doubleclick action = add to queue".
                if paths.count == 1, let p = paths.first,
                   p == parentEntry?.path, browse.canGoUp {
                    Task { await browse.goUp() }
                    return
                }
                let items = resolve(paths)
                if items.count == 1, let e = items.first, e.isDir {
                    Task { await browse.open(e) }
                    return
                }
                // Files queue. Source side only: the destination pane's contents
                // are already home and there is nowhere to send them. A mixed
                // selection queues the files and leaves the folders — opening one
                // of several would not be a meaningful answer either.
                let files = items.filter { !$0.isDir }
                if !files.isEmpty, browse.mode == .seedbox {
                    onAddToQueue(files)
                }
            }
            .onAppear(perform: loadCustomization)
            .onChange(of: customization) { _, new in save(new) }
            // Right-clicking empty space below the rows, like FileZilla.
            .contextMenu { backgroundMenu }
        }
    }

    /// Resolves against the REAL entries, so ".." can never end up in a selection
    /// or be handed to the enqueue path.
    private func resolve(_ paths: Set<String>) -> [Entry] {
        browse.visibleEntries.filter { paths.contains($0.path) }
    }

    /// The selection in the order the table is currently DRAWING it, which is what
    /// sequential numbering has to follow — number by `resolve`'s order and the items
    /// come out numbered by the relay's listing order, not the one on screen.
    ///
    /// Deliberately additive: `resolve` keeps its own order because Send's
    /// predictability is defined against it. The `!isParent` filter is not optional —
    /// `rows` carries the synthesised ".." entry, which must never reach a rename.
    private func resolveOrdered(_ paths: Set<String>) -> [Entry] {
        rows.filter { !isParent($0) && paths.contains($0.path) }
    }

    private var emptyState: some View {
        VStack(spacing: 7) {
            Image(systemName: "folder")
                .font(.system(size: 24, weight: .light))
                .foregroundStyle(.tertiary)
            Text("This folder is empty")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
            if browse.mode == .destinations {
                Text("Send something here from the left")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.001))
    }

    /// The parent folder's name carrying this file's extension, or nil when there
    /// is nothing useful to take. Nil for a file sitting directly in the source
    /// root, where the parent is the root itself and naming a film after it would
    /// be worse than leaving it alone.
    private func parentFolderName(for entry: Entry) -> String? {
        let parent = (entry.path as NSString).deletingLastPathComponent
        guard parent != browse.rootPath, parent != "/" else { return nil }
        let folder = (parent as NSString).lastPathComponent
        guard !folder.isEmpty, folder != "." else { return nil }
        let ext = (entry.name as NSString).pathExtension
        return ext.isEmpty ? folder : folder + "." + ext
    }

    /// Whether the rows in this pane are deep enough for the relay to act on them.
    ///
    /// The same rule DirTreeView applies by node depth, expressed in the pane's own
    /// terms: the rows are one level below `browse.path`, so they are actionable
    /// exactly when the pane itself is at least one level inside its root.
    ///
    /// Destination: `/queue` is the LIST of drop targets, not a target, so its rows
    /// are whole media volumes — validate_rename and validate_delete refuse them
    /// ("that is a volume, not something inside one") and validate_mkdir refuses
    /// `/queue` as a parent. Source: the relay refuses anything shallower than an
    /// individual release (MIN_SRC_DEPTH = 2 under /seedbox), so at the seedbox root
    /// the rows are library levels rather than releases. Both boundaries were checked
    /// against the live relay, not read off the guard source.
    private var rowsAreActionable: Bool {
        let base = browse.mode == .seedbox ? "/seedbox" : "/queue"
        guard browse.path.hasPrefix(base) else { return false }
        return !browse.path.dropFirst(base.count).split(separator: "/").isEmpty
    }

    @ViewBuilder
    private func rowMenu(for items: [Entry], ordered: [Entry] = []) -> some View {
        if items.isEmpty {
            backgroundMenu
        } else {
            if browse.mode == .seedbox, rowsAreActionable {
                Button(addLabel(items)) { onAddToQueue(items) }
                // Movies whose useful metadata lives on the folder, not the file:
                // Some.Film.2024.2160p.BluRay-GROUP/movie.mkv. Offered for one file
                // at a time — two files in the same folder would both want the same
                // name — and only when there is a real parent to take a name from.
                if items.count == 1, let e = items.first, !e.isDir,
                   let renamed = parentFolderName(for: e) {
                    Button("Rename to Parent Folder Name") {
                        onQueueRenamed(e, renamed)
                    }
                }
                Divider()
            }
            if items.count == 1, let e = items.first, e.isDir {
                Button(browse.mode == .seedbox ? "Enter Directory" : "Set as Destination") {
                    Task { await browse.open(e) }
                }
            }
            // Rename and Delete now work on BOTH sides. The seedbox mount is
            // read-only, so the relay performs those over rclone against the remote
            // instead of through the filesystem; the depth rule is the same one that
            // governs what may be copied, so a whole level of the library is still
            // refused. New Folder stays destination-only — the relay has no seedbox
            // mkdir and offering it would be a guaranteed error.
            //
            // Gated separately below, because they need different things: one item
            // gets the plain rename sheet while several get the bulk one (which
            // derives a distinct name per item), and deleting is happy with any
            // number.
            if rowsAreActionable {
                if items.count == 1, let e = items.first {
                    Button("Rename…") { onRename(e) }
                } else if items.count > 1 {
                    Button("Rename \(items.count) Items…") { onBulkRename(ordered) }
                }
                if browse.mode == .destinations {
                    Button("New Folder…") { onNewFolder() }
                }
                Divider()
                Button(items.count == 1
                       ? "Delete…"
                       : "Delete \(items.count) Items…", role: .destructive) {
                    onDelete(items)
                }
            }
            if items.count == 1 { Divider() }
            Button(items.count == 1 ? "Copy Path" : "Copy \(items.count) Paths") {
                copy(items.map(\.path))
            }
            Divider()
            backgroundMenu
        }
    }

    @ViewBuilder
    private var backgroundMenu: some View {
        Button("Refresh") { Task { await browse.reload() } }
        if browse.canGoUp {
            Button("Enclosing Folder") { Task { await browse.goUp() } }
        }
        Button("Copy Current Path") { copy([browse.path]) }
    }

    private func addLabel(_ items: [Entry]) -> String {
        let what: String
        if items.count == 1 {
            what = items[0].isDir ? "Folder" : "File"
        } else {
            what = "\(items.count) Items"
        }
        return destinationName.isEmpty
            ? "Add \(what) to Queue"
            : "Add \(what) to Queue  →  \(destinationName)"
    }

    private func copy(_ paths: [String]) {
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(paths.joined(separator: "\n"), forType: .string)
    }

    // TableColumnCustomization is Codable but @AppStorage cannot hold it directly,
    // so it round-trips through JSON in UserDefaults under a per-pane key.
    private func loadCustomization() {
        guard !loadedCustomization else { return }
        loadedCustomization = true
        guard let data = UserDefaults.standard.data(forKey: defaultsKey),
              let v = try? JSONDecoder().decode(TableColumnCustomization<Entry>.self, from: data)
        else { return }
        customization = v
    }

    private func save(_ v: TableColumnCustomization<Entry>) {
        guard let data = try? JSONEncoder().encode(v) else { return }
        UserDefaults.standard.set(data, forKey: defaultsKey)
    }
}

// MARK: - Status line

/// FileZilla's CFilelistStatusBar, phrasing included. The inconsistent punctuation
/// (a trailing period on some variants and not others) is FileZilla's own; it is
/// reproduced deliberately.
struct ListStatusLine: View {
    @ObservedObject var browse: BrowseStore
    let connected: Bool

    var body: some View {
        HStack {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.statusLineHeight)
    }

    var text: String {
        guard connected else { return "Not connected." }

        let selected = browse.selectedEntries
        if !selected.isEmpty {
            let d = selected.filter(\.isDir).count
            let f = selected.count - d
            let bytes = selected.reduce(Int64(0)) { $0 + ($1.isDir ? 0 : ($1.size ?? 0)) }
            if f == 0 {
                return "Selected \(Self.dirs(d))."
            } else if d == 0 {
                return "Selected \(Self.files(f)). Total size: \(humanBytes(bytes))"
            }
            return "Selected \(Self.files(f)) and \(Self.dirs(d)). Total size: \(humanBytes(bytes))"
        }

        if let total = browse.truncatedTotal {
            // Past the limit the breakdown would be wrong, so say so rather than lie.
            return "\(total) items (showing first \(browse.entries.count))"
        }
        if browse.entries.isEmpty { return "Empty directory." }

        let d = browse.dirCount, f = browse.fileCount
        if f == 0 { return Self.dirs(d) }                       // no trailing period
        if d == 0 { return "\(Self.files(f)). Total size: \(humanBytes(browse.byteTotal))" }
        return "\(Self.files(f)) and \(Self.dirs(d)). Total size: \(humanBytes(browse.byteTotal))"
    }

    static func files(_ n: Int) -> String { "\(n) file\(n == 1 ? "" : "s")" }
    static func dirs(_ n: Int) -> String { "\(n) director\(n == 1 ? "y" : "ies")" }
}
