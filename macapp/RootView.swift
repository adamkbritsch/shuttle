import SwiftUI

struct RootView: View {
    @StateObject private var store = RelayStore()
    @StateObject private var seedbox: BrowseStore
    @StateObject private var dest: BrowseStore

    @StateObject private var splits = SplitTreeHandle()
    @StateObject private var sourceTree: TreeStore
    @StateObject private var destTree: TreeStore
    /// One search per side. They look identical and are not: the NAS is a local
    /// walk, the seedbox is one rclone recursive listing over FTP that takes ~19s
    /// every time. Separate stores so a slow remote search cannot blank the NAS
    /// results, and so each remembers its own query.
    @StateObject private var search: SearchStore
    @StateObject private var sourceSearch: SearchStore
    @State private var showSettings = false
    @State private var tab: TransfersPane.Tab = .queued
    @State private var booted = false
    @State private var renaming: Entry?
    @State private var renameDraft = ""
    /// The relay refused an enqueue and is waiting to be told what to do.
    @State private var conflict: PendingConflict?
    /// Set by "always use this action", so the rest of a multi-item send stops asking.
    @State private var conflictPolicy: ConflictAction?
    @State private var deleting: PendingDelete?
    @State private var deleteStat: StatResult?
    @State private var bulkRenaming: PendingBulkRename?
    /// The pane an open Rename/Delete sheet is acting on. Both now work on either
    /// side, so reloading `dest` unconditionally would refresh the wrong list and
    /// leave the seedbox still showing something that has just been removed.
    @State private var actionPane: BrowseStore?
    @State private var actionTree: TreeStore?
    /// Which side the user last acted on, so a global shortcut acts where they are
    /// looking. Selection and navigation are the only two ways to "be" in a pane.
    @State private var activePane: BrowseStore.Mode = .seedbox
    /// The row a picked search result asked the table to show.
    @State private var revealPath: String?
    /// A NAS item armed to be replaced. Deliberately NOT BrowseStore.selection —
    /// navigation clears that and reload prunes it, and this has to survive the
    /// user going off to find the source. It is the app's only state that outlives
    /// a sheet, which is why SendBar shows it the whole time it is set.
    @State private var replacing: Entry?
    @State private var replaceStat: StatResult?
    @State private var replaceSourceStat: StatResult?
    /// The seedbox item that will do the replacing. Held explicitly because it can
    /// come from a right-clicked row, which is not necessarily the selection.
    @State private var replaceSource: Entry?
    @State private var confirmingReplace: Bool = false
    @State private var newFolderParent: String?
    @State private var newFolderName = ""
    /// Which transfer ⌘⌫ cancels.
    @State private var selectedTransfer: Int?

    init() {
        let s = RelayStore()
        _store = StateObject(wrappedValue: s)
        _seedbox = StateObject(wrappedValue: BrowseStore(mode: .seedbox, api: s.api, store: s))
        _dest = StateObject(wrappedValue: BrowseStore(mode: .destinations, api: s.api, store: s))
        _sourceTree = StateObject(wrappedValue: TreeStore(api: s.api))
        _destTree = StateObject(wrappedValue: TreeStore(api: s.api))
        _search = StateObject(wrappedValue: SearchStore(api: s.api, side: "nas"))
        _sourceSearch = StateObject(wrappedValue: SearchStore(api: s.api, side: "seedbox"))
    }

    var body: some View {
        VStack(spacing: 0) {
            TopBar(store: store, onSettings: { showSettings = true },
                   onRefresh: { Task { await refreshAll() } })
            Divider().overlay(Theme.hairline)
            content
        }
        .background(Color(nsColor: .windowBackgroundColor))
        // One tint for the whole tree: buttons, progress bars, focus rings and
        // menu highlights all inherit it, so the icon's blue shows up everywhere
        // interactive without each call site naming a colour.
        .tint(Theme.accent)
        .sheet(isPresented: $showSettings) { SettingsSheet(store: store) { showSettings = false } }
        .sheet(item: $conflict) { pending in
            ConflictSheet(report: pending.report,
                          sourceName: (pending.src as NSString).lastPathComponent,
                          destinationPath: pending.destDir,
                          onCancel: {
                              conflict = nil
                              store.show("Transfer cancelled — nothing was overwritten",
                                         isError: false)
                          },
                          onConfirm: { action, applyToAll, newName in
                              conflict = nil
                              if applyToAll, action != .rename { conflictPolicy = action }
                              Task { await resolve(pending, action: action, newName: newName) }
                          })
        }
        .sheet(item: $deleting) { pending in
            DeleteSheet(items: pending.items, stat: deleteStat,
                        onCancel: { deleting = nil; deleteStat = nil },
                        onConfirm: {
                            let paths = pending.items.map(\.path)
                            deleting = nil; deleteStat = nil
                            Task {
                                var any = false
                                var gone: [String] = []
                                // Sequential, not concurrent: the relay refuses a
                                // delete that overlaps a running transfer, and a
                                // clear first refusal beats several racing ones.
                                for p in paths where await store.delete(p) {
                                    any = true
                                    gone.append(p)
                                }
                                if any {
                                    // The tree can delete the directory the pane is
                                    // VIEWING, or an ancestor of it; the file list can
                                    // only ever delete a child, which is why this did
                                    // not arise before. Reloading a path that no longer
                                    // exists would leave the old rows on screen —
                                    // reload deliberately KEEPS a good listing when a
                                    // refresh fails — so the pane would show the
                                    // contents of a folder that is gone. Move up to the
                                    // nearest surviving parent instead.
                                    let pane = actingPane, tree = actingTree
                                    if let dead = gone.first(where: {
                                        pane.path == $0 || pane.path.hasPrefix($0 + "/")
                                    }) {
                                        await pane.go(to: (dead as NSString).deletingLastPathComponent)
                                    } else {
                                        await pane.reload()
                                    }
                                    if let first = paths.first {
                                        tree.refresh((first as NSString).deletingLastPathComponent)
                                    }
                                }
                            }
                        })
        }
        .sheet(item: $bulkRenaming) { pending in
            BulkRenameSheet(items: pending.items,
                            existingNames: pending.existingNames,
                            listingTruncated: pending.truncated,
                            onCancel: { bulkRenaming = nil },
                            onApply: { plan in
                                let steps = plan.steps
                                let parent = pending.items.first.map {
                                    ($0.path as NSString).deletingLastPathComponent
                                }
                                bulkRenaming = nil
                                Task {
                                    let out = await store.renameMany(steps)
                                    // Deferred renames have changed nothing on disk,
                                    // so reloading would just redraw the old names.
                                    guard out.renamed > 0 else { return }
                                    await actingPane.reload()
                                    if let parent { actingTree.refresh(parent) }
                                    // No failure report is needed: reload() prunes the
                                    // selection to entries that still exist, so it
                                    // collapses to exactly the rows that did NOT get
                                    // renamed — still selected, ready to try again.
                                }
                            })
        }
        .sheet(isPresented: Binding(get: { newFolderParent != nil },
                                    set: { if !$0 { newFolderParent = nil } })) {
            NewFolderSheet(parent: newFolderParent ?? "", name: $newFolderName,
                           onCancel: { newFolderParent = nil },
                           onConfirm: { name in
                               let parent = newFolderParent ?? ""
                               newFolderParent = nil
                               Task {
                                   if await store.mkdir(parent: parent, name: name) {
                                       await dest.reload()
                                       destTree.refresh(parent)
                                   }
                               }
                           })
        }
        .sheet(isPresented: $confirmingReplace) {
            if let target = replacing, let source = replaceSource {
                ReplaceSheet(target: target, source: source,
                             targetStat: replaceStat, sourceStat: replaceSourceStat,
                             onCancel: { confirmingReplace = false },
                             onConfirm: { confirmingReplace = false; sendReplacement() })
            }
        }
        .sheet(item: $renaming) { entry in
            RenameSheet(entry: entry, name: $renameDraft,
                        onCancel: { renaming = nil },
                        onConfirm: { newName in
                            let path = entry.path
                            renaming = nil
                            Task {
                                let didRename = await store.rename(path: path, newName: newName)
                                // A deferred rename changes nothing on disk yet, so
                                // reloading would just redraw the old name.
                                if didRename {
                                    await actingPane.reload()
                                    actingTree.refresh((path as NSString).deletingLastPathComponent)
                                }
                            }
                        })
        }
        .task {
            guard !booted else { return }
            booted = true
            // The Keychain's first read can cost seconds after a rebuild; start()
            // awaits the token before the first request, and the window is already
            // on screen by then so the cost is invisible.
            await store.start()
            if case .live = store.status {
                await seedbox.restoreOrFallback()
                await dest.restoreOrFallback()
            }
            store.startPolling()
        }
        .onReceive(NotificationCenter.default.publisher(for: .shuttleSettings)) { _ in showSettings = true }
        .modifier(MenuBridge(flags: menuFlags,
                             sourceSelection: seedbox.selection, sourcePath: seedbox.path,
                             destSelection: dest.selection, destPath: dest.path,
                             activePane: $activePane,
                             onFind: { (activePane == .seedbox ? sourceSearch : search).active = true }))
        .onReceive(NotificationCenter.default.publisher(for: .shuttleRefresh)) { _ in
            Task { await refreshAll() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .shuttleSend)) { _ in trySend() }
        .onReceive(NotificationCenter.default.publisher(for: .shuttleUp)) { _ in
            // Whichever pane you last touched, not always the source. The
            // destination pane's own up-button advertises this shortcut in its
            // tooltip, and pressing it used to move the OTHER pane.
            let pane = activePane == .seedbox ? seedbox : dest
            guard pane.canGoUp else {
                store.show("Already at the top of that side", isError: false)
                return
            }
            Task { await pane.goUp() }
        }
        // A selection that is only ever SET goes stale the moment the job it points
        // at finishes: the row stays highlighted in the Successful tab, implying it
        // is still actionable, and the shortcut reports "select a transfer first"
        // when one plainly is selected. Drop it as soon as it leaves the active list.
        //
        // A lone transfer is NOT auto-selected any more. It used to be, so that ⌘⌫
        // had an unambiguous target — but selection is drawn as a filled accent row,
        // so the single-transfer case (which is most of the time) sat there looking
        // permanently highlighted when the user had never clicked it. The shortcut
        // keeps that convenience without the paint: see `cancelTarget`.
        .onChange(of: store.active) { _, now in
            if let id = selectedTransfer, !now.contains(where: { $0.id == id }) {
                selectedTransfer = nil
            }
        }
        // Selection is scoped to the queue: highlighting a row in Failed or
        // Successful would suggest the shortcut applies there, and it does not.
        .onChange(of: tab) { _, _ in selectedTransfer = nil }
        .onReceive(NotificationCenter.default.publisher(for: .shuttleCancel)) { _ in
            // Cancel what is SELECTED. This used to cancel store.active.first, so
            // with several transfers queued the shortcut stopped whichever happened
            // to sort first -- a destructive action on an item the user never
            // pointed at. With nothing selected it now does nothing and says so.
            guard let id = cancelTarget else {
                store.show(store.active.isEmpty
                           ? "Nothing is transferring"
                           : "Select a transfer first, then press ⌘⌫", isError: false)
                return
            }
            guard store.active.contains(where: { $0.id == id }) else {
                // Selected, but already finished -- "select one first" would be
                // flatly wrong here.
                store.show("That transfer has already finished", isError: false)
                return
            }
            Task { await store.cancel(id) }
        }
        // Pane toggles go through isCollapsed, never by rebuilding the hierarchy.
        .onReceive(NotificationCenter.default.publisher(for: .shuttleToggleSourceTree)) { _ in
            splits.toggle("source.split", pane: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shuttleToggleDestTree)) { _ in
            splits.toggle("dest.split", pane: 0)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shuttleToggleQueue)) { _ in
            splits.toggle("main.rows", pane: 1)
        }
        .onReceive(NotificationCenter.default.publisher(for: .shuttleResetLayout)) { _ in
            SplitTreeHandle.forgetLayout(keys: Theme.splitKeys)
            for k in ["table.columns.source", "table.columns.dest"] {
                UserDefaults.standard.removeObject(forKey: k)
            }
            store.show("Layout reset — relaunch to apply", isError: false)
        }
    }

    private var content: some View {
        ZStack(alignment: .bottom) {
            // The split tree stays mounted in EVERY status, and the offline and
            // probing UI is drawn OVER it rather than replacing it.
            //
            // Swapping it out tore down the whole AppKit split hierarchy, so
            // reconnecting rebuilt it and re-ran the restore. That was bad on its
            // own, but it also changed the root's constraints enough for a tiled
            // window to leave its tile and grow -- measured going offline:
            // 865x1014 -> 865x1353, origin dropped to y=-269, below the screen.
            // The rebuilt tree then restored into that taller window and the
            // transfers pane swallowed every extra point. Keeping the tree mounted
            // means losing the relay cannot move a divider or resize the window.
            //
            // Every boundary below is a real, draggable, persisted NSSplitView
            // divider. SwiftUI's HSplitView/VSplitView cannot do this: they have
            // no autosave name, no divider binding, and no holding-priority
            // equivalent, so nothing about their geometry survives a relaunch.
            SplitTree(root: splitLayout, hitSlop: Theme.dividerHitSlop, handle: splits)

            statusOverlay

            if let toast = store.toast {
                Text(toast.text)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(.white)
                    .lineLimit(2)
                    .padding(.horizontal, 14).padding(.vertical, 9)
                    .background(
                        Capsule().fill(toast.isError
                                       ? Color(nsColor: .systemRed)
                                       : Color(nsColor: .systemGreen))
                    )
                    .padding(.bottom, 22)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeInOut(duration: 0.2), value: store.toast)
    }

    /// Covers the panes while there is no relay. Opaque, because the panes behind it
    /// still hold the last listing and a half-visible stale file list reads as live.
    @ViewBuilder
    private var statusOverlay: some View {
        switch store.status {
        case .live:
            EmptyView()
        case .probing:
            centered {
                ProgressView().controlSize(.small)
                Text("Reaching the relay…").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            .background(Color(nsColor: .windowBackgroundColor))
        case .offline(let reason):
            OfflineView(reason: reason, base: store.baseURL,
                        onRetry: { Task { await retry() } },
                        onSettings: { showSettings = true })
                .background(Color(nsColor: .windowBackgroundColor))
        }
    }

    // MARK: - Layout

    /// The pane hierarchy. Rebuilt every body pass; SplitTree pushes the fresh leaf
    /// views into the existing hosting views positionally, so the AppKit split
    /// hierarchy is built once and never torn down.
    ///
    /// The leaf SHAPE must stay constant between passes — hiding a pane goes through
    /// `isCollapsed`, never by omitting a SplitChild, or leaf updates stop silently.
    private var splitLayout: SplitNode {
        .split(axis: .rows, key: "main.rows", children: [
            SplitChild(SplitPaneSpec(min: Theme.browseMin,
                                     holdingPriority: Theme.Hold.absorbs),
                       .split(axis: .columns, key: "main.browse", children: [
                        // Equal priorities give FileZilla's gravity 0.5: the two
                        // panes share growth instead of one pinning to its minimum.
                        SplitChild(SplitPaneSpec(min: Theme.paneMinWidth,
                                                 holdingPriority: Theme.Hold.absorbs),
                                   column(key: "source.split", search: sourceSearch, browse: seedbox,
                                          tree: sourceTree, title: "SEEDBOX",
                                          treeRoot: "/seedbox",
                                          // Starts collapsed so the seedbox tree's
                                          // cold listing cost is never paid unasked.
                                          startsCollapsed: true) { EmptyView() }),
                        SplitChild(SplitPaneSpec(min: Theme.paneMinWidth,
                                                 holdingPriority: Theme.Hold.absorbs),
                                   column(key: "dest.split", search: search, browse: dest,
                                          tree: destTree, title: "DESTINATION",
                                          treeRoot: "/queue",
                                          // NAS volumes are a small, near-static set.
                                          startsCollapsed: false) {
                                            SendBar(store: store,
                                                    sources: seedbox.selectedEntries,
                                                    destination: dest.path,
                                                    enabled: canSend,
                                                    action: trySend,
                                                    replacing: replacing,
                                                    replaceEnabled: canReplace,
                                                    onReplace: confirmReplace,
                                                    onCancelReplace: cancelReplace)
                                          }),
                       ])),
            SplitChild(SplitPaneSpec(min: Theme.queueMin,
                                     canCollapse: true,
                                     holdingPriority: Theme.Hold.holdsFirmly,
                                     seed: Theme.queueSeed)) {
                TransfersPane(store: store, tab: $tab, selected: $selectedTransfer)
            },
        ])
    }

    /// One side's tree/list split. The tree pane can collapse (that is how the View
    /// menu hides it) but is NEVER omitted from the hierarchy: SplitTree pushes leaf
    /// views positionally, so a changing leaf count would silently stop all updates.
    private func column(key: String,
                        search: SearchStore,
                        browse: BrowseStore,
                        tree: TreeStore,
                        title: String,
                        treeRoot: String,
                        startsCollapsed: Bool,
                        @ViewBuilder footer: @escaping () -> some View) -> SplitNode {
        .split(axis: .rows, key: key, children: [
            SplitChild(SplitPaneSpec(min: Theme.treeMin,
                                     canCollapse: true,
                                     // 251 HOLDS: the list below absorbs growth while
                                     // the tree keeps its height. Measured; the
                                     // intuitive assignment is backwards.
                                     holdingPriority: Theme.Hold.holds,
                                     startsCollapsed: startsCollapsed,
                                     seed: Theme.treeSeed)) {
                treePane(tree: tree, browse: browse, root: treeRoot)
            },
            SplitChild(SplitPaneSpec(min: Theme.listMin,
                                     holdingPriority: Theme.Hold.absorbs)) {
                VStack(spacing: 0) {
                    BrowsePane(browse: browse, title: title,
                               onAddToQueue: { enqueue($0) },
                               destinationName: destinationLabel,
                               onRename: { beginRename($0, in: browse, tree: tree) },
                               onDelete: { beginDelete($0, in: browse, tree: tree) },
                               onNewFolder: { beginNewFolder(dest.path) },
                               onQueueRenamed: { e, name in enqueue([e], as: name) },
                               onBulkRename: { beginBulkRename($0, in: browse, tree: tree) },
                               onReplace: { beginReplace($0) },
                               replacingName: replacing?.name,
                               onReplaceWith: { confirmReplace(with: $0) },
                               search: search,
                               searchActive: search.active,
                               onPickResult: { pickResult($0, in: browse, tree: tree) },
                               reveal: revealPath)
                    footer()
                }
            },
        ])
    }

    private func treePane(tree: TreeStore, browse: BrowseStore, root: String) -> some View {
        DirTreeView(tree: tree, browse: browse, root: root,
                    onAddToQueue: { enqueue([$0]) },
                    destinationName: destinationLabel,
                    onRename: { beginRename($0, in: browse, tree: tree) },
                    onDelete: { beginDelete([$0], in: browse, tree: tree) },
                    onNewFolder: { beginNewFolder($0) })
            .background(
                RoundedRectangle(cornerRadius: 7, style: .continuous).fill(Theme.listFill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .strokeBorder(Theme.hairline, lineWidth: 1)
            )
    }

    /// A destination must be a real folder inside a drop target. `/queue` itself is
    /// the list of targets, not a target, so it is not a valid destination.
    private var canSend: Bool {
        !seedbox.selectedEntries.isEmpty && dest.path != "/queue" && dest.path.hasPrefix("/queue/")
    }

    private var actingPane: BrowseStore { actionPane ?? dest }
    private var actingTree: TreeStore { actionTree ?? destTree }

    /// A search result is find-only, so picking one is purely navigation.
    ///
    /// A folder IS the place you were looking for, so go inside it. A file is not,
    /// so go to its folder and select it there — which is what `revealing:` is for.
    /// Search mode closes but the results are kept, so ⌘F brings them straight back
    /// without paying for a second walk.
    private func pickResult(_ entry: Entry, in pane: BrowseStore, tree: TreeStore) {
        (pane.mode == .seedbox ? sourceSearch : search).dismiss()
        // Always the CONTAINING folder, for a folder result as much as a file:
        // "show me where this is" is the question search answers, and opening a
        // folder answers a different one. The item is selected on arrival, so what
        // you searched for is the thing highlighted.
        let parent = (entry.path as NSString).deletingLastPathComponent
        revealPath = entry.path
        Task {
            await pane.go(to: parent, revealing: entry.path)
            tree.refresh(parent)
        }
    }

    /// What ⌘⌫ acts on: whatever is selected, or the only active transfer when there
    /// is exactly one.
    ///
    /// Resolved here rather than by assigning to `selectedTransfer`, which is what it
    /// used to do. Writing it into the selection meant the row rendered as selected,
    /// and with a single transfer running that is a permanently blue row nobody
    /// clicked. Nothing is ambiguous about one transfer, so the shortcut can still
    /// find it without the app claiming it is highlighted.
    private var cancelTarget: Int? {
        if let selectedTransfer { return selectedTransfer }
        return store.active.count == 1 ? store.active[0].id : nil
    }

    /// Everything the menu bar validates against, as one Equatable value so a single
    /// onChange keeps all four in step.
    private var menuFlags: MenuFlags {
        var f = MenuFlags()
        f.canSend = canSend
        f.canGoUp = (activePane == .seedbox ? seedbox : dest).canGoUp
        f.hasSelectedTransfer = cancelTarget != nil
        if case .live = store.status { f.isLive = true }
        return f
    }

    private func trySend() {
        // ⌘↩ with nothing selected used to return silently from enqueue's guard —
        // no toast, no sheet, nothing. Same precedent as the ⌘⌫ handler above.
        guard !seedbox.selectedEntries.isEmpty else {
            store.show(seedbox.selection.isEmpty
                       ? "Select something on the left first, then press ⌘↩"
                       : "Everything selected is hidden by the filter", isError: false)
            return
        }
        enqueue(seedbox.selectedEntries)
    }

    /// The one path every "add to queue" goes through: the Send button, ⌘↩, the file
    /// list's context menu and the tree's.
    /// `as` renames the item on arrival. It is applied at ENQUEUE, as the job's
    /// destination name, not as a rename afterwards.
    ///
    /// That is deliberate and it is the safer of the two. Setting the name up front
    /// means the conflict check runs against the name the file will actually have,
    /// so a clash is caught before anything moves. Transferring first and renaming
    /// after would discover the clash only once the bytes had landed — a failed
    /// rename at the end of a 40GB copy, with the file sitting under the wrong name.
    /// rclone writes straight to the final name either way, so the end state is
    /// identical.
    private func enqueue(_ sources: [Entry], as destName: String? = nil) {
        guard !sources.isEmpty else { return }
        guard dest.path != "/queue", dest.path.hasPrefix("/queue/") else {
            store.show("Pick a destination folder first — /queue itself is the list of volumes",
                       isError: true)
            return
        }
        let destPath = dest.path
        // One action that adds MORE than one item queues them in name order, so
        // Episode 2 transfers before Episode 10 whatever order the pane happened to
        // hand them over in — the pane's own order is the relay's listing order, which
        // is plain lexicographic and puts Episode 10 first.
        //
        // Deliberately scoped to a multi-item add. A single add has nothing to order,
        // and two separate adds keep their own arrival order rather than the queue
        // being silently re-sorted behind the user. Name order specifically, not
        // whichever column the table happens to be sorted by.
        let ordered = sources.count > 1
            ? sources.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            : sources
        // A fresh Send starts asking again: "always use this action" is scoped to one
        // send, exactly like FileZilla's "Apply to current queue only".
        conflictPolicy = nil
        Task {
            // POST /v1/jobs takes one src per call, so N selected items are N calls,
            // each through the relay's own validate_request gate.
            for src in ordered {
                // Nil policy means "ask": the relay scans the destination and answers
                // 409 rather than silently overwriting.
                let report = await store.send(src: src.path, destDir: destPath,
                                              onConflict: conflictPolicy,
                                              destName: destName)
                if let report {
                    // Park the rest of the selection behind the sheet: answering it
                    // resumes them with whatever was chosen.
                    conflict = PendingConflict(
                        src: src.path, destDir: destPath, report: report,
                        remaining: Array(ordered.drop(while: { $0.path != src.path }).dropFirst()))
                    return
                }
            }
            tab = .queued
        }
    }

    /// Applies the sheet's answer to the item that tripped it, then continues with
    /// whatever was left of the selection.
    private func resolve(_ pending: PendingConflict,
                         action: ConflictAction, newName: String) async {
        // Skip is NOT short-circuited here. FileZilla's "Skip file" skips the
        // clashing FILE, not the whole transfer -- and for a release folder where
        // only some files collide, the rest must still go. Sending it to the relay
        // as --ignore-existing reproduces that; returning early would silently drop
        // every non-conflicting file in the directory.
        await store.send(src: pending.src, destDir: pending.destDir,
                         onConflict: action,
                         destName: action == .rename ? newName : nil)
        for src in pending.remaining {
            let report = await store.send(src: src.path, destDir: pending.destDir,
                                          onConflict: conflictPolicy)
            if let report {
                conflict = PendingConflict(
                    src: src.path, destDir: pending.destDir, report: report,
                    remaining: Array(pending.remaining
                        .drop(while: { $0.path != src.path }).dropFirst()))
                return
            }
        }
        tab = .queued
    }

    /// Asks the relay what is actually there before showing the sheet, so the
    /// confirmation can state the size and file count rather than just a name.
    /// For a multi-item delete the totals are summed across the selection — the
    /// number that makes someone stop and check is the combined one.
    private func beginDelete(_ items: [Entry], in pane: BrowseStore, tree: TreeStore) {
        guard !items.isEmpty else { return }
        actionPane = pane; actionTree = tree
        deleteStat = nil
        deleting = PendingDelete(items: items)
        Task {
            var files = 0, bytes: Int64 = 0
            for e in items {
                guard let s = await store.statFor(e.path) else { continue }
                files += s.files
                bytes += s.bytes
            }
            deleteStat = StatResult(path: items[0].path,
                                    isDir: items.count > 1 ? true : items[0].isDir,
                                    files: files, bytes: bytes)
        }
    }

    /// Synchronous, unlike beginDelete: everything the sheet needs is already in the
    /// listing we are looking at.
    ///
    /// `dest.entries` and not `visibleEntries` — a row hidden by the pane's filter
    /// still occupies its name on disk, so filtering here would miss real clashes.
    private func beginBulkRename(_ items: [Entry], in pane: BrowseStore, tree: TreeStore) {
        guard items.count > 1 else { return }
        actionPane = pane; actionTree = tree
        bulkRenaming = PendingBulkRename(
            items: items,
            existingNames: Set(pane.entries.map(\.name)),
            truncated: pane.truncatedTotal != nil)
    }

    /// Arm a NAS item for replacement. Nothing is queued and nothing is deleted
    /// here — this only says "the next thing you pick on the left replaces this".
    private func beginReplace(_ entry: Entry) {
        replacing = entry
        replaceStat = nil
        confirmingReplace = false
        Task { replaceStat = await store.statFor(entry.path) }
        store.show("Replacing \(entry.name) — pick one item on the left", isError: false)
    }

    private func cancelReplace() {
        replacing = nil
        replaceStat = nil
        replaceSource = nil
        replaceSourceStat = nil
        confirmingReplace = false
    }

    /// Only one source, and only while something is armed.
    private var canReplace: Bool {
        replacing != nil && seedbox.selectedEntries.count == 1
    }

    private func confirmReplace() {
        guard canReplace, let source = seedbox.selectedEntries.first else { return }
        confirmReplace(with: source)
    }

    /// The seedbox pane's own "Replace X" menu item, which passes the row that was
    /// right-clicked — not the selection, which may be something else entirely.
    private func confirmReplace(with source: Entry) {
        guard replacing != nil else { return }
        replaceSource = source
        replaceSourceStat = nil
        confirmingReplace = true
        Task { replaceSourceStat = await store.statFor(source.path) }
    }

    /// Queue the copy, carrying the "and then delete that" instruction with it.
    ///
    /// Not `enqueue(_:as:)`: that lands things in `dest.path`, and a replacement has
    /// to land in the ARMED item's own folder, which may not be where the right pane
    /// is pointed. `overwrite` because the default policy asks, and a replace has
    /// already been confirmed once.
    private func sendReplacement() {
        guard let target = replacing, let source = replaceSource else { return }
        let destDir = (target.path as NSString).deletingLastPathComponent
        let oldPath = target.path
        cancelReplace()
        Task {
            _ = await store.send(src: source.path, destDir: destDir,
                                 onConflict: .overwrite, replace: oldPath)
            tab = .queued
            await dest.reload()
        }
    }

    private func beginNewFolder(_ parent: String) {
        newFolderName = ""
        newFolderParent = parent
    }

    private func beginRename(_ entry: Entry, in pane: BrowseStore, tree: TreeStore) {
        actionPane = pane; actionTree = tree
        renameDraft = entry.name
        renaming = entry
    }

    /// Short label for the destination, used in the context-menu wording.
    private var destinationLabel: String {
        guard dest.path.hasPrefix("/queue/") else { return "" }
        return String(dest.path.dropFirst("/queue/".count))
    }

    private func refreshAll() async {
        await store.refreshStatus()
        guard case .live = store.status else { return }
        await store.loadTargets()
        await seedbox.reload()
        await dest.reload()
        await store.poll(force: true)
    }

    private func retry() async {
        await store.start()
        if case .live = store.status {
            await seedbox.restoreOrFallback()
            await dest.restoreOrFallback()
        }
    }

    private func centered<C: View>(@ViewBuilder _ c: () -> C) -> some View {
        VStack(spacing: 10) { c() }.frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct TopBar: View {
    @ObservedObject var store: RelayStore
    let onSettings: () -> Void
    let onRefresh: () -> Void

    var body: some View {
        ZStack(alignment: .bottom) {
            Theme.barFill
            WindowDragArea()
            HStack(spacing: 10) {
                Color.clear.frame(width: Theme.trafficLightGutter, height: 1)
                // The mark rather than the word: at this size the name adds nothing
                // the window title and the Dock do not already say, and the chrome
                // reads quieter without it. Tinted to the same weight as the buttons
                // to its right so it blends into the bar instead of sitting on it.
                if let mark = Theme.markTemplate {
                    Image(nsImage: mark)
                        .resizable()
                        .renderingMode(.template)
                        .interpolation(.high)
                        .frame(width: 17, height: 17)
                        .foregroundStyle(Color.primary.opacity(0.55))
                        .accessibilityLabel("Shuttle")
                }
                Text("Shuttle")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.primary.opacity(0.85))
                    .fixedSize()
                Spacer()
                statusPill
                ChromeButton(symbol: "arrow.clockwise", help: "Refresh (⌘R)", action: onRefresh)
                ChromeButton(symbol: "gearshape", help: "Relay settings (⌘,)", action: onSettings)
                Color.clear.frame(width: 4, height: 1)
            }
            // Centred in the BAR, not on the traffic lights, which left ~12pt of
            // dead space underneath and read as top-heavy.
            //
            // maxHeight is required, not optional: the enclosing ZStack aligns
            // .bottom (the loading bar hangs off the bar's lower edge), so a row
            // with no height of its own drops to the bottom instead of centring.
            .frame(maxHeight: .infinity)
        }
        .frame(height: Theme.barHeight)
    }

    private var statusPill: some View {
        HStack(spacing: 6) {
            Circle().fill(tint.color).frame(width: 7, height: 7)
            Text(label)
                .font(.system(size: 11.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(0.78))
        }
        .padding(.horizontal, 9).frame(height: 22)
        .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
            .fill(tint == .busy ? Theme.accentSoft : Theme.pillFill))
        .help(helpText)
    }

    private var tint: StatusTint {
        switch store.status {
        case .probing: return .idle
        case .live: return store.active.isEmpty ? .good : .busy
        case .offline: return .bad
        }
    }

    private var label: String {
        switch store.status {
        case .probing: return "Connecting"
        case .live: return store.active.isEmpty ? "Idle" : "Transferring"
        case .offline(.unauthorized): return "Token"
        case .offline: return "Offline"
        }
    }

    private var helpText: String {
        switch store.status {
        case .probing: return "Reaching the relay"
        case .live: return "Relay reachable at \(store.baseURL)"
        case .offline(.unauthorized): return "The relay rejected the token"
        case .offline(.unreachable(let why)): return why
        }
    }
}

private struct OfflineView: View {
    let reason: RelayStore.Reason
    let base: String
    let onRetry: () -> Void
    let onSettings: () -> Void

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: reason == .unauthorized
                  ? "key.slash" : "antenna.radiowaves.left.and.right.slash")
                .font(.system(size: 38, weight: .light))
                .foregroundStyle(.tertiary)
            Text(reason == .unauthorized ? "The relay rejected the token" : "Can't reach the relay")
                .font(.system(size: 17, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 420)
            Text(base)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
            HStack(spacing: 10) {
                Button("Try Again", action: onRetry).keyboardShortcut(.defaultAction)
                Button("Relay Settings…", action: onSettings)
            }
            .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var detail: String {
        switch reason {
        case .unauthorized:
            return "Paste the relay's API token in Settings. It is RELAY_API_TOKEN in "
                 + "the NAS .env, at ~/seedbox-ftp-relay/.env."
        case .unreachable(let why):
            return "\(why). The relay only listens on the tailnet, so Tailscale has to be up."
        }
    }
}

private struct SettingsSheet: View {
    @ObservedObject var store: RelayStore
    let close: () -> Void

    @State private var base = ""
    @State private var token = ""
    @State private var loaded = false
    @State private var concurrent = 1
    @State private var sbProtocol: SeedboxProtocol = .ftps
    @State private var sbHost = ""
    @State private var sbPort = "21"
    @State private var sbUser = ""
    @State private var sbPassword = ""
    @State private var sbRoot = "/"
    @State private var sbTesting = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Relay Settings").font(.system(size: 15, weight: .semibold))
            Text("Shuttle drives the relay on the NAS. Transfers run entirely between the "
                 + "seedbox and the NAS — nothing passes through this Mac.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 5)

            Divider().padding(.vertical, 16)

            Text("Address").font(.system(size: 12, weight: .medium))
            TextField("", text: $base)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text("Tailnet only. Plain HTTP is fine — the link is WireGuard-encrypted.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 3)

            Text("API token").font(.system(size: 12, weight: .medium)).padding(.top, 14)
            SecureField("", text: $token)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
            Text(tokenBlurb)
                .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 16)

            HStack(spacing: 8) {
                Text("Seedbox").font(.system(size: 12, weight: .medium))
                Circle()
                    .fill(store.seedbox.configured ? Color(nsColor: .systemGreen)
                                                   : Color(nsColor: .systemOrange))
                    .frame(width: 7, height: 7)
                Text(store.seedbox.configured ? "connected" : "not configured yet")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
            }
            Text("The NAS connects to the seedbox directly and copies server-to-server. "
                 + "These credentials are stored on the NAS, never on this Mac.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 3)

            HStack(spacing: 8) {
                Picker("", selection: $sbProtocol) {
                    ForEach(SeedboxProtocol.allCases) { p in Text(p.label).tag(p) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: sbProtocol) { _, p in sbPort = String(p.defaultPort) }
                TextField("host.example.com", text: $sbHost)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                TextField("port", text: $sbPort)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 62)
            }
            .padding(.top, 8)

            HStack(spacing: 8) {
                TextField("username", text: $sbUser)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                SecureField(store.seedbox.hasPassword ? "password (unchanged)" : "password",
                            text: $sbPassword)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            .padding(.top, 6)

            HStack(spacing: 8) {
                Text("Remote path").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("/", text: $sbRoot)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            .padding(.top, 6)
            Text("The directory on the seedbox to browse from. Leave as / unless your "
                 + "provider drops you somewhere other than your downloads folder.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true).padding(.top, 3)

            HStack(spacing: 8) {
                Button(sbTesting ? "Testing…" : "Test & Save Seedbox") {
                    sbTesting = true
                    Task {
                        _ = await store.saveSeedbox(
                            protocolName: sbProtocol.rawValue,
                            host: sbHost.trimmingCharacters(in: .whitespaces),
                            port: Int(sbPort) ?? sbProtocol.defaultPort,
                            user: sbUser.trimmingCharacters(in: .whitespaces),
                            password: sbPassword, root: sbRoot.isEmpty ? "/" : sbRoot)
                        sbPassword = ""
                        sbTesting = false
                    }
                }
                .disabled(sbTesting || sbHost.isEmpty || sbUser.isEmpty
                          || (!store.seedbox.hasPassword && sbPassword.isEmpty))
                if sbTesting { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.top, 10)
            Text("Saving tests the connection from the NAS before it is trusted.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.top, 3)

            Divider().padding(.vertical, 16)

            Text("Simultaneous transfers").font(.system(size: 12, weight: .medium))
            HStack(spacing: 10) {
                Stepper(value: $concurrent, in: 1...max(1, store.maxConcurrentCeiling)) {
                    Text("\(concurrent)")
                        .font(.system(size: 12, design: .monospaced))
                        .frame(minWidth: 18, alignment: .leading)
                }
                .fixedSize()
                Text("of \(store.maxConcurrentCeiling) max")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                Spacer()
            }
            Text("How many copies the NAS runs at once. Raising this does not "
                 + "necessarily go faster — the seedbox link is usually the limit, and "
                 + "parallel copies mostly divide it. Lowering it takes effect as "
                 + "running transfers finish; nothing is interrupted.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary).padding(.top, 3)
                .fixedSize(horizontal: false, vertical: true)

            Divider().padding(.vertical, 16)

            HStack {
                Spacer()
                Button("Cancel", action: close).keyboardShortcut(.cancelAction)
                Button("Save & Test") {
                    store.baseURL = base
                    Task {
                        if !token.isEmpty { await store.saveToken(token) }
                        else { await store.refreshStatus() }
                        if concurrent != store.maxConcurrent {
                            await store.setMaxConcurrent(concurrent)
                        }
                        close()
                    }
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 470)
        .onAppear {
            guard !loaded else { return }
            loaded = true
            base = store.baseURL
            concurrent = store.maxConcurrent
            // Seed from whatever the relay reports, so the form shows the live
            // configuration rather than blanks. The password is never sent back.
            sbProtocol = SeedboxProtocol(rawValue: store.seedbox.protocolName) ?? .ftps
            sbHost = store.seedbox.host
            sbPort = String(store.seedbox.port)
            sbUser = store.seedbox.user
            sbRoot = store.seedbox.root
            Task { await store.loadSeedbox() }
        }
        .onChange(of: store.seedbox) { _, c in
            guard !c.host.isEmpty, sbHost.isEmpty else { return }
            sbProtocol = SeedboxProtocol(rawValue: c.protocolName) ?? .ftps
            sbHost = c.host; sbPort = String(c.port); sbUser = c.user; sbRoot = c.root
        }
    }

    private var tokenBlurb: String {
        TokenStore.current == nil
            ? "RELAY_API_TOKEN from the NAS .env. Saved to a private file in Application Support, readable only by you."
            : "A token is saved. Leave blank to keep it; type a new one to replace it."
    }
}


/// Rename an item that has landed on the NAS.
private struct RenameSheet: View {
    let entry: Entry
    @Binding var name: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    @FocusState private var focused: Bool

    private var trimmed: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var valid: Bool {
        !trimmed.isEmpty && trimmed != "." && trimmed != ".."
            && !trimmed.contains("/") && trimmed != entry.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Rename").font(.system(size: 15, weight: .semibold))
            Text(entry.path)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
                .padding(.top, 4)

            TextField("", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($focused)
                .onSubmit { if valid { onConfirm(trimmed) } }
                .padding(.top, 14)

            Text("If a transfer is still writing here, the rename is applied the moment "
                 + "it finishes — it will not interrupt the download or lose its place.")
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.top, 6)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Rename") { onConfirm(trimmed) }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!valid)
            }
            .padding(.top, 18)
        }
        .padding(22)
        .frame(width: 430)
        .onAppear { focused = true }
    }
}


/// One unanswered conflict, plus the selection still waiting behind it.
struct PendingConflict: Identifiable {
    let src: String
    let destDir: String
    let report: ConflictReport
    let remaining: [Entry]
    var id: String { src }
}


/// One pending delete: the whole selection, so the sheet can total it.
struct PendingDelete: Identifiable {
    let items: [Entry]
    var id: String { items.map(\.path).joined(separator: "\u{0000}") }
}


/// One pending bulk rename: the selection in pane order, plus the snapshot of names
/// already in that folder that the preview checks against.
struct PendingBulkRename: Identifiable {
    let items: [Entry]
    let existingNames: Set<String>
    let truncated: Bool
    var id: String { items.map(\.path).joined(separator: "\u{0000}") }
}


/// Groups the menu-bar and active-pane observers into a SINGLE modifier.
///
/// Not tidiness: RootView's body is one long modifier chain, and adding five more
/// `.onChange`s to it directly tipped the type checker past its budget — "unable to
/// type-check this expression in reasonable time". One modifier costs the chain one
/// slot no matter how many observers hang off it.
private struct MenuBridge: ViewModifier {
    let flags: MenuFlags
    let sourceSelection: Set<String>
    let sourcePath: String
    let destSelection: Set<String>
    let destPath: String
    @Binding var activePane: BrowseStore.Mode
    let onFind: () -> Void

    func body(content: Content) -> some View {
        content
            // Keeps the AppKit menu honest. Derived from what SwiftUI just recomputed,
            // so there is no second source of truth to drift.
            .onChange(of: flags) { _, f in MenuState.shared.flags = f }
            .onChange(of: sourceSelection) { _, _ in activePane = .seedbox }
            .onChange(of: sourcePath) { _, _ in activePane = .seedbox }
            .onChange(of: destSelection) { _, _ in activePane = .destinations }
            .onChange(of: destPath) { _, _ in activePane = .destinations }
            .onReceive(NotificationCenter.default.publisher(for: .shuttleFind)) { _ in
                onFind()
            }
    }
}
