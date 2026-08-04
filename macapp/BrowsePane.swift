import SwiftUI

/// One side of the browse area: an editable path bar, the file table, and a status
/// line. Mirrors FileZilla's `CView` — header, list, status bar — minus the
/// recursive-operation footer, which has no referent here.
///
/// `search` is nil for the seedbox pane, and that is the whole safety story for
/// this shared view: with it nil the code path is exactly what it was before
/// search existed. Only the NAS side can be searched, because only it is a local
/// disk — the seedbox is rclone over FTP, where a recursive walk would be
/// thousands of round trips.
///
/// The tree/list divider is NOT nested here: SplitTree owns every split, so RootView
/// composes the tree pane and this pane as siblings.
struct BrowsePane: View {
    @ObservedObject var browse: BrowseStore
    let title: String
    var connected: Bool = true
    var onAddToQueue: ([Entry]) -> Void = { _ in }
    var destinationName: String = ""
    var onRename: (Entry) -> Void = { _ in }
    var onDelete: ([Entry]) -> Void = { _ in }
    var onNewFolder: () -> Void = { }
    var onQueueRenamed: (Entry, String) -> Void = { _, _ in }
    var onBulkRename: ([Entry]) -> Void = { _ in }
    /// Destination side only; nil leaves this pane exactly as it was.
    var search: SearchStore? = nil
    var onPickResult: (Entry) -> Void = { _ in }

    private var searching: Bool { search?.active == true }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PathBar(browse: browse, title: title, search: search)
            Divider().overlay(Theme.hairline)
            content
            Divider().overlay(Theme.hairline)
            if let search, search.active {
                SearchStatusLine(text: search.statusText)
            } else {
                ListStatusLine(browse: browse, connected: connected)
            }
        }
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.cardFill)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        )
    }

    @ViewBuilder
    private var content: some View {
        if let search, search.active {
            results(search)
        } else if let error = browse.error, browse.entries.isEmpty {
            failure(error)
        } else {
            ZStack(alignment: .top) {
                FileTable(browse: browse,
                          paneKey: browse.mode == .seedbox ? "source" : "dest",
                          onAddToQueue: onAddToQueue,
                          destinationName: destinationName,
                          onRename: onRename,
                          onDelete: onDelete,
                          onNewFolder: onNewFolder,
                          onQueueRenamed: onQueueRenamed,
                          onBulkRename: onBulkRename)
                if let error = browse.error {
                    Text(error)
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .padding(.horizontal, 10).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Theme.cardFill)
                }
                if browse.loading && browse.entries.isEmpty {
                    ProgressView().controlSize(.small)
                        .frame(maxWidth: .infinity).padding(.top, 24)
                }
            }
        }
    }

    /// Search mode. Every branch here is an EMPTY STATE rather than an error
    /// treatment, except a genuine relay failure — "no matches" is an answer, not
    /// a fault, and dressing it up as one would be wrong.
    @ViewBuilder
    private func results(_ search: SearchStore) -> some View {
        if search.running && search.results.isEmpty {
            VStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Searching \(search.scopeLabel)…")
                    .font(.system(size: 11.5)).foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if !search.canRun {
            centered("Type at least \(SearchStore.minQuery) characters, then press Return",
                     symbol: "magnifyingglass")
        } else if search.results.isEmpty, let error = search.error {
            failure(error)
        } else if search.results.isEmpty, search.ran {
            centered(search.timedOut
                     ? "The search timed out before it finished. Press Return to try again — the second one is usually fast."
                     : "No matches for “\(search.trimmed)”",
                     symbol: "magnifyingglass")
        } else if search.results.isEmpty {
            centered("Press Return to search \(search.scopeLabel)", symbol: "magnifyingglass")
        } else {
            SearchResultsList(results: search.results, onPick: onPickResult)
        }
    }

    /// A failed listing must offer a way out. Without this the pane was a dead end:
    /// the only recovery was the menu bar or relaunching.
    private func failure(_ text: String) -> some View {
        VStack(spacing: 9) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(Color(nsColor: .systemOrange))
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 18)
            HStack(spacing: 8) {
                Button("Try Again") { Task { await browse.reload() } }
                if browse.canGoUp {
                    Button("Go Up") { Task { await browse.goUp() } }
                }
            }
            .controlSize(.small)
            .padding(.top, 2)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func centered(_ text: String, symbol: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 22, weight: .light))
                .foregroundStyle(.tertiary)
            Text(text)
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 18)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

/// FileZilla's `CViewHeader`: a label plus an editable combo of the last 20
/// directories. Typing a path and pressing Return jumps straight there, which beats
/// clicking down a tree when you already know the release name.
private struct PathBar: View {
    @ObservedObject var browse: BrowseStore
    let title: String
    var search: SearchStore? = nil

    @State private var draft = ""
    @State private var editing = false
    @State private var filterOpen = false
    @FocusState private var focused: Bool
    @FocusState private var filterFocused: Bool

    var body: some View {
        if let search, search.active {
            SearchBar(search: search)
        } else {
            browsing
        }
    }

    private var browsing: some View {
        HStack(spacing: 8) {
            ChromeButton(symbol: "chevron.left", help: "Enclosing folder (⌘↑)",
                         enabled: browse.canGoUp) {
                Task { await browse.goUp() }
            }
            Text(title)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                .fixedSize()

            TextField("", text: $draft)
                .textFieldStyle(.plain)
                .font(.system(size: 11.5, design: .monospaced))
                .focused($focused)
                .onSubmit { commit() }
                .onChange(of: focused) { _, now in
                    editing = now
                    if !now { draft = browse.path }        // abandon an unsubmitted edit
                }
                .padding(.horizontal, 7)
                .frame(height: 21)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(editing ? Theme.pillFillHover : Theme.pillFill)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(editing ? Theme.accent.opacity(0.70) : .clear,
                                      lineWidth: 1)
                )

            if !browse.recentDirs.isEmpty {
                Menu {
                    // Alphabetical for display, like FileZilla's sorted MRU, while the
                    // underlying list stays newest-first for eviction.
                    ForEach(browse.recentDirs.sorted(), id: \.self) { p in
                        Button(p) { Task { await browse.go(to: p) } }
                    }
                } label: {
                    Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold))
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Recent folders")
            }

            if let search {
                ChromeButton(symbol: "magnifyingglass", help: "Search \(search.scopeLabel) (⌘F)") {
                    search.active = true
                }
            }

            // Filter. Client-side over the page already fetched, so typing never
            // triggers a listing -- a cold one costs over a second.
            //
            // Collapsed to an icon like Search, because a permanent 96pt field left
            // the path field almost nothing at the 330pt minimum pane width. It
            // expands on click and stays expanded while it holds text: a filter
            // hides rows, so it must never be possible to have one applied with no
            // visible sign of it.
            if filterOpen || !browse.filter.isEmpty {
                HStack(spacing: 4) {
                    Image(systemName: "line.3.horizontal.decrease")
                        .font(.system(size: 9, weight: .semibold))
                        .foregroundStyle(.tertiary)
                    TextField("Filter", text: $browse.filter)
                        .textFieldStyle(.plain)
                        .font(.system(size: 11))
                        .frame(width: 96)
                        .focused($filterFocused)
                    Button {
                        browse.filter = ""
                        filterOpen = false
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.system(size: 9))
                    }
                    .buttonStyle(.plain).foregroundStyle(.tertiary)
                }
                .padding(.horizontal, 6).frame(height: 21)
                .background(RoundedRectangle(cornerRadius: 6, style: .continuous).fill(Theme.pillFill))
                .onAppear { filterFocused = true }
            } else {
                ChromeButton(symbol: "line.3.horizontal.decrease",
                             help: "Filter this folder") {
                    filterOpen = true
                }
            }

            if browse.loading {
                ProgressView().controlSize(.small).scaleEffect(0.65)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .onAppear { draft = browse.path }
        .onChange(of: browse.path) { _, new in
            if !editing { draft = new }
            filterOpen = false          // reload() clears the filter itself
        }
    }

    private func commit() {
        let p = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !p.isEmpty, p != browse.path else { draft = browse.path; return }
        focused = false
        Task { await browse.go(to: p) }
    }
}

/// The destination pane's footer: what will happen, and the button that does it.
/// Remaining space on the chosen destination volume, so the number that would
/// otherwise arrive as a rejection ("not enough space") is visible beforehand.
struct FreeSpaceLabel: View {
    @ObservedObject var store: RelayStore
    let destPath: String

    var body: some View {
        if let t = target, let free = t.freeBytes {
            Text("\(humanBytes(free)) free")
                .font(.system(size: 10.5))
                .foregroundStyle(free < 20_000_000_000 ? Color(nsColor: .systemOrange) : .secondary)
        }
    }

    private var target: Target? {
        store.targets.first { destPath == $0.path || destPath.hasPrefix($0.path + "/") }
    }
}

struct SendBar: View {
    var store: RelayStore?
    let sources: [Entry]
    let destination: String
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(label)
                        .font(.system(size: 11.5, weight: sources.isEmpty ? .regular : .medium))
                        .foregroundStyle(sources.isEmpty ? .secondary : .primary)
                        .lineLimit(1).truncationMode(.middle)
                    // The resolved destination, so there is never ambiguity about
                    // where something lands.
                    HStack(spacing: 8) {
                        Text("into \(destination)")
                            .font(.system(size: 10.5, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(1).truncationMode(.head)
                        if let store { FreeSpaceLabel(store: store, destPath: destination) }
                    }
                }
                Spacer()
                Button(action: action) {
                    Text("Send to NAS").font(.system(size: 12, weight: .medium))
                }
                // The one primary action in the window, so it carries the icon's
                // blue as a filled button rather than a bezelled default one.
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!enabled)
            }
            .padding(.horizontal, 10)
            .padding(.top, 8)
        }
    }

    private var label: String {
        switch sources.count {
        case 0: return "Select something on the left"
        case 1: return sources[0].name
        default: return "\(sources.count) items"
        }
    }
}
