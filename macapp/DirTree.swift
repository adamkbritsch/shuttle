import SwiftUI

/// Lazily-expanding directory tree.
///
/// The whole design is dictated by one measured number: a cold listing on the NAS's
/// FUSE mount costs **1.15–1.40s**, a cold grandchild 2.3–2.5s, and `--dir-cache-time
/// 30s` means re-listing 35 seconds later costs the full price again. Eight parallel
/// expansions took 5.45s wall AND degraded every individual response to 5.45s;
/// 24-way concurrency tripped `api.py`'s `BoundedSemaphore(8)` into hard
/// `503 busy` with no client retry.
///
/// So: **one in-flight listing ever**, a FIFO queue, an indefinite cache, and no
/// prefetching of any kind. Aggregate throughput is ~1.8x worse than fanning out;
/// perceived latency is ~4x better and it structurally cannot trip the 503.
@MainActor
final class TreeStore: ObservableObject {
    /// Directory children by path. A missing key means "never loaded" — that
    /// distinction is what drives the chevron and the spinner.
    @Published private(set) var children: [String: [Entry]] = [:]
    @Published private(set) var loading: Set<String> = []
    @Published private(set) var failed: [String: String] = [:]
    @Published var expanded: Set<String> = []

    private let api: RelayAPI
    private var queue: [String] = []
    private var working = false

    init(api: RelayAPI) { self.api = api }

    func isLoaded(_ path: String) -> Bool { children[path] != nil }

    /// Toggling open enqueues a load if this node has never been listed. Deliberately
    /// does NOT re-list a cached node: the only invalidation is an explicit refresh.
    func toggle(_ path: String) {
        if expanded.contains(path) {
            expanded.remove(path)
        } else {
            expanded.insert(path)
            if children[path] == nil { enqueue(path) }
        }
    }

    func refresh(_ path: String) {
        children[path] = nil
        failed[path] = nil
        enqueue(path)
    }

    /// Drops everything. Used when the pane's root changes.
    func reset() {
        children = [:]; loading = []; failed = [:]; expanded = []
        queue = []
    }

    private func enqueue(_ path: String) {
        guard !queue.contains(path), !loading.contains(path) else { return }
        queue.append(path)
        Task { await drain() }
    }

    private func drain() async {
        guard !working else { return }        // serial: exactly one in flight, ever
        working = true
        defer { working = false }
        while !queue.isEmpty {
            let path = queue.removeFirst()
            if children[path] != nil { continue }
            loading.insert(path)
            switch await api.browse(path, limit: 5000) {
            case .listing(let l):
                // Only directories belong in a tree.
                children[path] = l.entries.filter(\.isDir)
                failed[path] = nil
            case .refused(let why), .unreachable(let why):
                failed[path] = why
            case .unauthorized:
                failed[path] = "Token rejected"
            }
            loading.remove(path)
        }
    }
}

/// The recursive tree view.
///
/// `DisclosureGroup(isExpanded:)` rather than `OutlineGroup`: OutlineGroup's
/// `children:` KeyPath needs the child array to already exist and gives no
/// expand callback, so there is nowhere to hang the lazy load. A `Binding<Bool>`
/// whose setter enqueues is exactly the hook needed.
struct DirTreeView: View {
    @ObservedObject var tree: TreeStore
    @ObservedObject var browse: BrowseStore
    /// The path this tree is rooted at.
    let root: String
    /// Source side only: queue this folder for transfer.
    var onAddToQueue: (Entry) -> Void = { _ in }
    /// The destination a queued folder would land in, for the menu wording.
    var destinationName: String = ""
    var onRename: (Entry) -> Void = { _ in }
    var onDelete: (Entry) -> Void = { _ in }
    var onNewFolder: (String) -> Void = { _ in }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                node(path: root, name: (root as NSString).lastPathComponent, depth: 0)
            }
            .padding(.vertical, 4)
        }
        .onAppear {
            if !tree.isLoaded(root) { tree.toggle(root) }
            else { tree.expanded.insert(root) }
        }
        .onChange(of: root) { _, new in
            tree.reset()
            tree.toggle(new)
        }
    }

    /// AnyView, not `some View`: this function calls itself, and an opaque return
    /// type cannot be defined in terms of itself.
    private func node(path: String, name: String, depth: Int) -> AnyView {
        AnyView(nodeBody(path: path, name: name, depth: depth))
    }

    @ViewBuilder
    private func nodeBody(path: String, name: String, depth: Int) -> some View {
        let isOpen = tree.expanded.contains(path)
        let kids = tree.children[path]
        // A directory whose listing came back with no subdirectories loses its
        // chevron, so it stops offering an expansion that would do nothing.
        let mayExpand = kids == nil || !(kids?.isEmpty ?? true)

        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 4) {
                if mayExpand {
                    Image(systemName: "chevron.right")
                        .font(.system(size: 8, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .rotationEffect(.degrees(isOpen ? 90 : 0))
                        .frame(width: 10)
                        .onTapGesture { tree.toggle(path) }
                } else {
                    Color.clear.frame(width: 10, height: 1)
                }
                Image(systemName: isOpen ? "folder.fill" : "folder")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.folderGold)
                Text(name.isEmpty ? "/" : name)
                    .font(.system(size: 11.5,
                                  weight: browse.path == path ? .semibold : .regular))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 2)
            }
            .padding(.leading, CGFloat(depth) * 12 + 8)
            .padding(.trailing, 6)
            .frame(height: 19)
            .background(browse.path == path ? Theme.accentSoft : .clear)
            .contentShape(Rectangle())
            // A single click navigates the file list, matching FileZilla's tree.
            .onTapGesture { Task { await browse.go(to: path) } }
            .contextMenu {
                if browse.mode == .seedbox {
                    Button(destinationName.isEmpty
                           ? "Add Folder to Queue"
                           : "Add Folder to Queue  →  \(destinationName)") {
                        onAddToQueue(Entry(name: name, path: path, isDir: true,
                                           size: nil, mtime: nil))
                    }
                    Divider()
                }
                Button(browse.mode == .seedbox ? "Open in List" : "Set as Destination") {
                    Task { await browse.go(to: path) }
                }
                Button(isOpen ? "Collapse" : "Expand") { tree.toggle(path) }
                if browse.mode == .destinations {
                    Button("Rename…") {
                        onRename(Entry(name: name, path: path, isDir: true,
                                       size: nil, mtime: nil))
                    }
                    Button("New Folder…") { onNewFolder(path) }
                    Divider()
                    Button("Delete…", role: .destructive) {
                        onDelete(Entry(name: name, path: path, isDir: true,
                                       size: nil, mtime: nil))
                    }
                }
                Divider()
                Button("Refresh") { tree.refresh(path) }
                Button("Copy Path") {
                    let pb = NSPasteboard.general
                    pb.clearContents()
                    pb.setString(path, forType: .string)
                }
            }

            if isOpen {
                if tree.loading.contains(path) {
                    // One honest row. No skeletons, no shimmer, no fake content.
                    HStack(spacing: 5) {
                        ProgressView().controlSize(.small).scaleEffect(0.6)
                        Text("Listing…").font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    .padding(.leading, CGFloat(depth + 1) * 12 + 8)
                    .frame(height: 19)
                } else if let why = tree.failed[path] {
                    HStack(spacing: 5) {
                        Image(systemName: "exclamationmark.triangle").font(.system(size: 9))
                        Text(why).font(.system(size: 11)).lineLimit(1)
                    }
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .padding(.leading, CGFloat(depth + 1) * 12 + 8)
                    .frame(height: 19)
                } else if let kids {
                    ForEach(kids) { child in
                        node(path: child.path, name: child.name, depth: depth + 1)
                    }
                }
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isOpen)
    }
}
