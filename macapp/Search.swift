import SwiftUI

/// Whole-NAS search: state and the results list.
///
/// Deliberately its own store rather than fields on `BrowseStore`. Two reasons.
/// `BrowseStore` is about ONE directory and this is about all of them, and — the
/// trap that decided it — `BrowseStore.filter` is cleared by every successful
/// `reload()`, so anything living beside it would be wiped by the very navigation
/// a search result triggers.
///
/// `BrowsePane` takes this as an OPTIONAL and gets nil for the seedbox side, so
/// that pane's code path is provably unchanged: the seedbox is rclone over FTP,
/// where this walk would be thousands of round trips instead of one.
@MainActor
final class SearchStore: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [Entry] = []
    @Published private(set) var total = 0
    @Published private(set) var truncated = false
    @Published private(set) var timedOut = false
    @Published private(set) var running = false
    @Published private(set) var error: String?
    /// A search has actually completed, so "no results" can be told apart from
    /// "nothing has been searched for yet".
    @Published private(set) var ran = false
    /// Whether the pane is in search mode. Separate from `query.isEmpty` so ⌘F can
    /// open an empty field.
    @Published var active = false

    /// Matches the relay's own minimum. Enforced here too so a stray keystroke
    /// never spends a walk.
    static let minQuery = 2

    /// "nas" or "seedbox". Both sides are searchable, but they are entirely
    /// different operations underneath: the NAS is a local walk (~0.45s warm), the
    /// seedbox is one rclone recursive listing over FTP (~19s, never warm).
    let side: String
    private let api: RelayAPI
    /// Same idiom as `BrowseStore.reload()`: an answer that arrives after a newer
    /// query started is dropped rather than published. With a cold walk measured
    /// past 25s, out-of-order answers are ordinary rather than theoretical.
    private var generation = 0

    init(api: RelayAPI, side: String) { self.api = api; self.side = side }

    var isSeedbox: Bool { side == "seedbox" }
    var scopeLabel: String { isSeedbox ? "the seedbox" : "all volumes" }
    var trimmed: String { query.trimmingCharacters(in: .whitespaces) }
    var canRun: Bool { trimmed.count >= SearchStore.minQuery }

    /// Runs on submit, never per keystroke. The walk is ~0.45s warm but has been
    /// measured past 25s cold, so firing one from a debounce timer would spend
    /// half a minute on a query the user never finished typing.
    func run() async {
        let q = trimmed
        guard q.count >= SearchStore.minQuery else { return }
        generation &+= 1
        let mine = generation
        running = true
        error = nil

        let outcome = await api.search(q, side: side)
        guard mine == generation else { return }   // a newer search owns the pane
        running = false

        switch outcome {
        case .results(let r):
            results = r.entries
            total = r.total
            truncated = r.truncated
            timedOut = r.timedOut
            ran = true
        case .busy:
            // Not a failure. A previous search is still draining on the relay;
            // keep whatever is on screen rather than blanking it.
            error = "A search is already running — try again in a moment"
        case .refused(let why):   fail(why)
        case .unauthorized:       fail("Token rejected")
        case .unreachable(let why): fail(why)
        }
    }

    private func fail(_ why: String) {
        error = why
        results = []
        total = 0
        truncated = false
        timedOut = false
        ran = true
    }

    /// Leaves search mode but KEEPS the results, so jumping to a result and
    /// pressing ⌘F again does not pay for a second walk.
    func dismiss() { active = false }

    func clear() {
        query = ""
        results = []
        total = 0
        truncated = false
        timedOut = false
        error = nil
        ran = false
        generation &+= 1        // abandon anything in flight
    }

    /// What the status line says. Mirrors `ListStatusLine`'s voice: state the
    /// limit rather than quietly implying the first page is everything.
    var statusText: String {
        if running { return "Searching \(scopeLabel)…" }
        if let error { return error }
        guard ran else { return "" }
        if timedOut {
            return "Search timed out — \(total.formatted()) matches found so far"
        }
        if total == 0 { return "No matches." }
        if truncated {
            return "\(total.formatted()) matches (showing first \(results.count))"
        }
        return "\(total.formatted()) match\(total == 1 ? "" : "es")."
    }
}

/// The results list. A plain `List`, not `FileTable`.
///
/// `FileTable` derives five separate things from `browse.path` — the synthesised
/// `..` row, the New Folder/Rename/Delete gate, the background menu, the empty
/// state, and selection resolution. Results come from all over the tree, so every
/// one of those would be describing the wrong folder. The gate is the dangerous
/// one: it would enable Delete on a result using the depth of whatever folder the
/// pane happened to be showing.
struct SearchResultsList: View {
    let results: [Entry]
    let onPick: (Entry) -> Void

    var body: some View {
        List(results) { entry in
            row(entry)
                .contentShape(Rectangle())
                // Single click picks, matching the tree's single-click navigation.
                // The list is find-only, so a select-then-open dance would be
                // ceremony over a choice that carries no other meaning.
                .onTapGesture { onPick(entry) }
                .contextMenu {
                    Button("Go to Enclosing Folder") { onPick(entry) }
                    Button("Copy Path") {
                        let pb = NSPasteboard.general
                        pb.clearContents()
                        pb.setString(entry.path, forType: .string)
                    }
                }
                .listRowInsets(EdgeInsets(top: 2, leading: 8, bottom: 2, trailing: 8))
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
        .background(Theme.listFill)
    }

    /// The two-line shape `JobRow` already uses: what it is, then where it is.
    private func row(_ entry: Entry) -> some View {
        HStack(spacing: 7) {
            Image(systemName: entry.symbol)
                .font(.system(size: 11.5))
                .foregroundStyle(entry.isDir ? Theme.folderGold : Theme.fileGrey)
            VStack(alignment: .leading, spacing: 1) {
                Text(entry.name)
                    .font(.system(size: 12.5, weight: .medium))
                    // Middle, because the tail of a release name carries the
                    // codec and group — the part you are scanning for.
                    .lineLimit(1).truncationMode(.middle)
                Text(parentPath(entry))
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    // Head, because the tail identifies the folder and the
                    // /queue/MediaVolume3 prefix is the disposable part.
                    .lineLimit(1).truncationMode(.head)
            }
            Spacer(minLength: 6)
            Text(entry.sizeLabel)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 1)
    }

    private func parentPath(_ entry: Entry) -> String {
        let p = (entry.path as NSString).deletingLastPathComponent
        return p.isEmpty ? "/" : p
    }
}

/// The status line while searching. Same geometry and voice as `ListStatusLine`,
/// which describes one folder and cannot describe a whole-tree result set.
struct SearchStatusLine: View {
    let text: String

    var body: some View {
        HStack {
            Text(text).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(height: Theme.statusLineHeight)
    }
}

/// The path bar in search mode.
///
/// Replaces the path field, recents menu and filter rather than sitting beside
/// them: at `Theme.paneMinWidth` (330pt) there is no room for another field, and
/// in search mode all three are meaningless anyway — you are not in a folder, and
/// there is no listing to narrow.
struct SearchBar: View {
    @ObservedObject var search: SearchStore

    /// The text lives here, not in the store, and is committed on Return. Search
    /// runs on submit, so per-keystroke @Published churn would re-render the whole
    /// window for nothing.
    @State private var draft = ""
    @FocusState private var focused: Bool

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(Theme.accent)
            Text("SEARCH")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

            TextField("Search \(search.scopeLabel)", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5))
                .focused($focused)
                .onSubmit(commit)
                .padding(.horizontal, 7)
                .frame(height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Theme.pillFillHover)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.accent.opacity(0.70), lineWidth: 1)
                )

            if search.running {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            }
            Button {
                exitSearch()
            } label: {
                Image(systemName: "xmark.circle.fill").font(.system(size: 11))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.tertiary)
            .help("Close search (Esc)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .onAppear { draft = search.query; focused = true }
        // Esc leaves search mode. Belt and braces: a focused TextField may consume
        // the key before onExitCommand on an ancestor would see it.
        .onExitCommand(perform: exitSearch)
        .background(
            Button("", action: exitSearch)
                .keyboardShortcut(.escape, modifiers: [])
                .opacity(0).frame(width: 0, height: 0)
        )
    }

    private func commit() {
        search.query = draft
        Task { await search.run() }
    }

    private func exitSearch() {
        focused = false
        search.dismiss()
    }
}
