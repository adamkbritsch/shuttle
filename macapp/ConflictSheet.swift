import SwiftUI

/// FileZilla's "Target file already exists" dialog.
///
/// Modelled on the real one: it shows the source and the target side by side with
/// name, size and date so the two can actually be compared, then a list of actions,
/// then the two checkboxes that stop it asking again.
///
/// Two of FileZilla's seven actions are deliberately missing:
///
/// * **Resume file transfer** — rclone restarts an interrupted file from zero rather
///   than resuming (the relay's own `_cleanup_partial` says so), so offering it would
///   be a button that lies about what happens.
/// * **Ask for action** — that is what this sheet IS.
///
/// The rest map exactly onto rclone flags, resolved on the NAS: `--ignore-times`,
/// `--update --ignore-size`, `--size-only`, `--update`, `--ignore-existing`.
struct ConflictSheet: View {
    let report: ConflictReport
    /// The item being sent, for the "source" column.
    let sourceName: String
    let destinationPath: String
    let onCancel: () -> Void
    let onConfirm: (ConflictAction, _ applyToAll: Bool, _ newName: String) -> Void

    @State private var action: ConflictAction = .overwriteSizeOrNewer
    @State private var applyToAll = true
    @State private var newName: String = ""

    private var first: Conflict? { report.conflicts.first }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            comparison
            Divider().overlay(Theme.hairline)
            actions
            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 560)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 26))
                .foregroundStyle(Color(nsColor: .systemOrange))
            VStack(alignment: .leading, spacing: 3) {
                Text("Target file already exists")
                    .font(.system(size: 15, weight: .semibold))
                Text(summary)
                    .font(.system(size: 11.5))
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 18).padding(.vertical, 15)
    }

    private var summary: String {
        let n = report.conflicts.count
        let more = report.truncated ? " (at least)" : ""
        if n == 1 {
            return "1 file\(more) in \(destinationPath) already has this name."
        }
        return "\(n) files\(more) in \(destinationPath) already have the same names."
    }

    // MARK: - Source vs target

    private var comparison: some View {
        HStack(alignment: .top, spacing: 0) {
            column(title: "Source",
                   name: first?.path ?? sourceName,
                   size: first?.srcSize,
                   mtime: first?.srcMtime)
            Divider().frame(height: 62).overlay(Theme.hairline)
            column(title: "Target",
                   name: first?.path ?? sourceName,
                   size: first?.destSize,
                   mtime: first?.destMtime)
        }
        .padding(.vertical, 13)
        .background(Theme.cardFill)
    }

    private func column(title: String, name: String, size: Int64?, mtime: Double?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title.uppercased())
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(name)
                .font(.system(size: 11.5, design: .monospaced))
                .lineLimit(1).truncationMode(.middle)
            Text(detail(size: size, mtime: mtime))
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 18)
    }

    private func detail(size: Int64?, mtime: Double?) -> String {
        guard let size, let mtime, mtime > 0 else { return "—" }
        let d = Date(timeIntervalSince1970: mtime)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return "\(humanBytes(size))   \(f.string(from: d))"
    }

    // MARK: - Actions

    private var actions: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text("Action").font(.system(size: 11, weight: .semibold)).foregroundStyle(.secondary)
            ForEach(ConflictAction.allCases) { a in
                Button {
                    action = a
                    if a == .rename, newName.isEmpty { newName = report.destName }
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: action == a ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(action == a ? Theme.accent : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(a.label).font(.system(size: 12))
                            Text(a.detail).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if action == .rename {
                TextField("New name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .padding(.leading, 20).padding(.top, 2)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            Toggle("Always use this action for the rest of this send", isOn: $applyToAll)
                .font(.system(size: 11.5))
                .toggleStyle(.checkbox)
            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.cancelAction)
                Button("Continue") {
                    onConfirm(action, applyToAll,
                              newName.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .tint(Theme.accent)
                .disabled(action == .rename &&
                          newName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }
}

/// Confirmation for an irreversible delete.
///
/// It asks the relay what is actually there first, so the sheet can say "47 files ·
/// 22.4 GB" rather than just a name — the size is the thing that makes someone stop
/// and check. Until that answer arrives the destructive button stays disabled, so a
/// reflexive Return cannot fire before the stakes are on screen.
struct DeleteSheet: View {
    let items: [Entry]
    /// Totals across every selected item, summed from the relay. Nil until it
    /// answers.
    let stat: StatResult?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "trash")
                    .font(.system(size: 24))
                    .foregroundStyle(Color(nsColor: .systemRed))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2).truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text((items.first.map { ($0.path as NSString).deletingLastPathComponent } ?? ""))
                        .font(.system(size: 10.5, design: .monospaced))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1).truncationMode(.head)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 14)

            Divider().overlay(Theme.hairline)

            HStack(spacing: 10) {
                Text("This cannot be undone.")
                    .font(.system(size: 11)).foregroundStyle(.secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Delete", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: .systemRed))
                    .disabled(stat == nil)
            }
            .padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 460)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var title: String {
        if items.count == 1, let e = items.first {
            return "Delete \u{201C}\(e.name)\u{201D}?"
        }
        return "Delete \(items.count) items?"
    }

    private var detail: String {
        guard let stat else { return "Checking what is there\u{2026}" }
        let f = stat.files == 1 ? "1 file" : "\(stat.files) files"
        // A single plain file needs no file count -- "1 file · 6.2G" reads oddly
        // when the thing being deleted IS that file.
        if items.count == 1, !stat.isDir { return humanBytes(stat.bytes) }
        return "\(f) \u{00B7} \(humanBytes(stat.bytes))"
    }
}

/// Creates a folder on the NAS side. The relay rejects a name with a slash or a
/// dot-dot in it, so this only has to stop the obviously empty case.
struct NewFolderSheet: View {
    let parent: String
    @Binding var name: String
    let onCancel: () -> Void
    let onConfirm: (String) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 5) {
                Text("New Folder").font(.system(size: 15, weight: .semibold))
                Text("in \(parent)")
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)

            TextField("Folder name", text: $name)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { submit() }
                .padding(.horizontal, 20)

            HStack(spacing: 10) {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Create") { submit() }
                    .buttonStyle(.borderedProminent).tint(Theme.accent)
                    .disabled(trimmed.isEmpty)
            }
            .padding(.horizontal, 20).padding(.vertical, 16)
        }
        .frame(width: 420)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }
    private func submit() { if !trimmed.isEmpty { onConfirm(trimmed) } }
}

/// Bulk rename: pick an operation, watch the preview, apply.
///
/// The preview is the feature. Every selected item shows old → new live as the
/// fields change, and anything that would fail is flagged before a single request
/// goes out — because the relay validates one rename at a time and genuinely cannot
/// know that two of them collide with each other.
///
/// Apply stays disabled while any row is flagged. That is the user's chosen policy:
/// nothing runs half-done.
struct BulkRenameSheet: View {
    let items: [Entry]
    /// Every name currently in this directory, from the UNFILTERED listing — a row
    /// hidden by the pane's filter still occupies its name on disk.
    let existingNames: Set<String>
    /// The listing was capped, so `existingNames` is incomplete and the "already
    /// taken" check cannot be trusted to be exhaustive.
    let listingTruncated: Bool
    let onCancel: () -> Void
    let onApply: (BulkRenamePlan) -> Void

    @State private var spec = BulkRenameSpec()

    private var plan: BulkRenamePlan {
        BulkRenamePlan.make(items: items, spec: spec, existingNames: existingNames)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().overlay(Theme.hairline)
            operations
            Divider().overlay(Theme.hairline)
            preview
            Divider().overlay(Theme.hairline)
            footer
        }
        .frame(width: 620)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Rename \(items.count) items")
                .font(.system(size: 15, weight: .semibold))
            Text(items.first.map { ($0.path as NSString).deletingLastPathComponent } ?? "")
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.tertiary)
                .lineLimit(1).truncationMode(.head)
        }
        .padding(.horizontal, 18).padding(.top, 16).padding(.bottom, 13)
    }

    // MARK: - Operation picker

    private var operations: some View {
        VStack(alignment: .leading, spacing: 7) {
            ForEach(BulkRenameOp.allCases) { op in
                Button { spec.op = op } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: spec.op == op ? "largecircle.fill.circle" : "circle")
                            .font(.system(size: 12))
                            .foregroundStyle(spec.op == op ? Theme.accent : Color.secondary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(op.label).font(.system(size: 12))
                            Text(op.detail).font(.system(size: 10.5)).foregroundStyle(.tertiary)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            fields.padding(.leading, 20).padding(.top, 3)
        }
        .padding(.horizontal, 18).padding(.vertical, 13)
    }

    @ViewBuilder
    private var fields: some View {
        switch spec.op {
        case .findReplace:
            HStack(spacing: 8) {
                labelled("Find", TextField("", text: $spec.find))
                labelled("Replace with", TextField("", text: $spec.replace))
            }
            Toggle("Ignore case", isOn: $spec.ignoreCase)
                .font(.system(size: 11)).toggleStyle(.checkbox).padding(.top, 4)

        case .affix:
            HStack(spacing: 8) {
                labelled("Prefix", TextField("", text: $spec.prefix))
                labelled("Suffix", TextField("", text: $spec.suffix))
            }
            Text("The suffix goes before the extension, so the file still opens.")
                .font(.system(size: 10.5)).foregroundStyle(.tertiary).padding(.top, 3)

        case .number:
            HStack(spacing: 8) {
                labelled("Pattern", TextField("", text: $spec.pattern))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Start").font(.system(size: 10)).foregroundStyle(.secondary)
                    Stepper(value: $spec.start, in: 0...9999) {
                        Text("\(spec.start)").font(.system(size: 11, design: .monospaced))
                    }.fixedSize()
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text("Digits").font(.system(size: 10)).foregroundStyle(.secondary)
                    Stepper(value: $spec.pad, in: 0...6) {
                        Text("\(spec.pad)").font(.system(size: 11, design: .monospaced))
                    }.fixedSize()
                }
            }
            Text(spec.pattern.contains("{n}")
                 ? "Numbered in the order shown in the list."
                 : "The pattern must contain {n}.")
                .font(.system(size: 10.5))
                .foregroundStyle(spec.pattern.contains("{n}")
                                 ? Color.secondary : Color(nsColor: .systemOrange))
                .padding(.top, 3)
        }
    }

    private func labelled(_ title: String, _ field: TextField<Text>) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.system(size: 10)).foregroundStyle(.secondary)
            field
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 11.5, design: .monospaced))
        }
    }

    // MARK: - Preview

    private var preview: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 0) {
                ForEach(plan.rows) { row in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 6) {
                            Text(row.entry.name)
                                .foregroundStyle(.secondary)
                                .lineLimit(1).truncationMode(.middle)
                            Image(systemName: "arrow.right")
                                .font(.system(size: 8, weight: .semibold))
                                .foregroundStyle(.tertiary)
                            Text(row.changed ? row.newName : "unchanged")
                                .foregroundStyle(colour(for: row))
                                .lineLimit(1).truncationMode(.middle)
                            Spacer(minLength: 0)
                        }
                        .font(.system(size: 11, design: .monospaced))
                        if let reason = row.reason {
                            Text(reason)
                                .font(.system(size: 10))
                                .foregroundStyle(Color(nsColor: .systemRed))
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 18).padding(.vertical, 4)
                }
            }
            .padding(.vertical, 6)
        }
        .frame(height: 236)
        .background(Theme.listFill)
    }

    private func colour(for row: BulkRenameRow) -> Color {
        if row.issue != nil { return Color(nsColor: .systemRed) }
        return row.changed ? Color.primary : Color.secondary.opacity(0.6)
    }

    // MARK: - Footer

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if listingTruncated {
                Text("This folder has more items than Shuttle listed, so a clash with "
                     + "something further down cannot be checked here.")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Color(nsColor: .systemOrange))
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 10) {
                Text(status)
                    .font(.system(size: 11))
                    .foregroundStyle(plan.blocked ? Color(nsColor: .systemRed) : .secondary)
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Apply") { onApply(plan) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!plan.canApply)
            }
        }
        .padding(.horizontal, 18).padding(.vertical, 14)
    }

    private var status: String {
        let flagged = plan.rows.filter { $0.issue != nil }.count
        if flagged > 0 {
            return flagged == 1 ? "1 name collides" : "\(flagged) names collide"
        }
        if plan.changedCount == 0 { return "Nothing would change" }
        return "\(plan.changedCount) of \(items.count) will change"
    }
}

/// Confirming a replace: what goes, what arrives, and when the old one dies.
///
/// Modelled on DeleteSheet, including the stat-gated confirm button — the stakes
/// are a deletion, so the button stays disabled until the sizes are on screen and
/// a reflexive Return cannot fire before they are.
struct ReplaceSheet: View {
    let target: Entry            // the NAS item being replaced
    let source: Entry            // the seedbox item replacing it
    let targetStat: StatResult?
    let sourceStat: StatResult?
    let onCancel: () -> Void
    let onConfirm: () -> Void

    /// Same name on both sides means the copy lands ON the old item, so there is
    /// nothing left to delete afterwards. Worth saying out loud, because "and the
    /// old one is deleted" would be actively misleading here.
    private var inPlace: Bool { target.name == source.name }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(inPlace ? "Replace in place?" : "Replace this item?")
                .font(.system(size: 15, weight: .semibold))

            VStack(alignment: .leading, spacing: 10) {
                line("Replacing", target, targetStat, .secondary)
                line("With", source, sourceStat, .primary)
            }

            Text(inPlace
                 ? "Both are called “\(target.name)”, so the new copy overwrites it "
                   + "where it stands. Nothing is deleted afterwards."
                 : "The new copy is transferred first. “\(target.name)” is deleted "
                   + "only once it has landed and been checked — if the copy fails "
                   + "or comes up short, both are kept.")
                .font(.system(size: 11.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(inPlace ? "Overwrite" : "Replace", action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(Color(nsColor: .systemRed))
                    .disabled(targetStat == nil)
            }
        }
        .padding(18)
        .frame(width: 460)
    }

    private func line(_ label: String, _ entry: Entry,
                      _ stat: StatResult?, _ tint: Color) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label)
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(.tertiary)
            HStack(spacing: 6) {
                Image(systemName: entry.symbol)
                    .font(.system(size: 11.5))
                    .foregroundStyle(entry.isDir ? Theme.folderGold : Theme.fileGrey)
                Text(entry.name)
                    .font(.system(size: 12.5, weight: .medium))
                    .foregroundStyle(tint)
                    .lineLimit(1).truncationMode(.middle)
            }
            Text(detail(entry, stat))
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)
        }
    }

    private func detail(_ entry: Entry, _ stat: StatResult?) -> String {
        let parent = (entry.path as NSString).deletingLastPathComponent
        guard let stat else { return parent }
        let what = stat.files == 1 ? "1 file" : "\(stat.files) files"
        return "\(what) · \(humanBytes(stat.bytes))  —  \(parent)"
    }
}

/// Pick where things go: browse to a folder, or make one.
///
/// It navigates rather than only listing, because the useful destination is
/// often NOT in the current directory — moving a file up so it sits beside the
/// folder it was in is the obvious case, and a flat list of children cannot
/// express it. Hence "Move Here", which targets whatever directory is on screen.
///
/// Bounded by the drop target: the relay refuses a move across volumes (os.rename
/// would fail with EXDEV), so Up stops at the volume root rather than offering a
/// destination that is guaranteed to be rejected.
struct MoveToFolderSheet: View {
    let items: [Entry]
    /// The directory being browsed, and its folders. Both are owned by the caller
    /// because loading them is an async listing.
    let path: String
    let folders: [Entry]
    let loading: Bool
    /// Where the items are now — "Move Here" is pointless while browsing it.
    let origin: String
    @Binding var newName: String
    @Binding var chosen: String?
    let onNavigate: (String) -> Void
    let onCancel: () -> Void
    let onConfirm: () -> Void

    @FocusState private var focused: Bool

    private var trimmed: String { newName.trimmingCharacters(in: .whitespacesAndNewlines) }

    /// The same rules RenameSheet enforces, rather than a round trip to find out.
    private var newNameValid: Bool {
        !trimmed.isEmpty && trimmed != "." && trimmed != ".."
            && !trimmed.contains("/")
    }

    /// Up stops at the volume: /queue/MediaVolume3 is as far as a move can go.
    private var parent: String? {
        let up = (path as NSString).deletingLastPathComponent
        guard up.hasPrefix("/queue/"), up != "/queue" else { return nil }
        return up
    }

    private var movingHere: Bool { chosen == nil && trimmed.isEmpty }
    private var canConfirm: Bool {
        if chosen != nil { return true }
        if newNameValid { return true }
        // "Move Here" is only an action somewhere else.
        return path != origin
    }

    private var joinsExisting: Bool {
        chosen == nil && !trimmed.isEmpty && folders.contains { $0.name == trimmed }
    }

    private var confirmLabel: String {
        if chosen != nil { return "Move" }
        if newNameValid { return joinsExisting ? "Move" : "Create and Move" }
        return "Move Here"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(items.count == 1
                 ? "Move “\(items[0].name)”"
                 : "Move \(items.count) items")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(1).truncationMode(.middle)

            HStack(spacing: 7) {
                Button {
                    if let parent { onNavigate(parent) }
                } label: {
                    Image(systemName: "chevron.up").font(.system(size: 11, weight: .semibold))
                }
                .buttonStyle(.plain)
                .disabled(parent == nil)
                .foregroundStyle(parent == nil ? Color.secondary.opacity(0.4) : Theme.accent)
                .help("Enclosing folder")
                Text(path)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.head)
                Spacer(minLength: 0)
                if loading { ProgressView().controlSize(.small).scaleEffect(0.6) }
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if folders.isEmpty && !loading {
                        Text("No folders here")
                            .font(.system(size: 11.5)).foregroundStyle(.tertiary)
                            .padding(.horizontal, 8).padding(.vertical, 6)
                    }
                    ForEach(folders) { folder in
                        HStack(spacing: 0) {
                            pick(folder.name, picked: chosen == folder.path) {
                                chosen = folder.path
                                focused = false
                            }
                            // Separate from selecting it: one says "put them in
                            // there", the other says "look inside".
                            Button { onNavigate(folder.path) } label: {
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 9, weight: .semibold))
                                    .foregroundStyle(.tertiary)
                                    .padding(.horizontal, 8).padding(.vertical, 5)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Look inside")
                        }
                    }
                }
            }
            .frame(height: 164)
            .background(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Theme.listFill))
            .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1))

            VStack(alignment: .leading, spacing: 5) {
                pick("New folder here", picked: chosen == nil && !trimmed.isEmpty) {
                    chosen = nil
                    focused = true
                }
                TextField("Folder name", text: $newName)
                    .textFieldStyle(.roundedBorder)
                    .focused($focused)
                    .onSubmit { if canConfirm { onConfirm() } }
                    .onChange(of: newName) { _, _ in if !newName.isEmpty { chosen = nil } }
                    .padding(.leading, 20)
                if joinsExisting {
                    Text("That folder already exists — these will be added to it.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(Color(nsColor: .systemOrange))
                        .padding(.leading, 20)
                }
                if movingHere && path == origin {
                    Text("They are already here — browse elsewhere, or name a new folder.")
                        .font(.system(size: 10.5))
                        .foregroundStyle(.tertiary)
                        .padding(.leading, 20)
                }
            }

            HStack {
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button(confirmLabel, action: onConfirm)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!canConfirm)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 480)
    }

    private func pick(_ label: String, picked: Bool,
                      action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 7) {
                Image(systemName: picked ? "largecircle.fill.circle" : "circle")
                    .font(.system(size: 11))
                    .foregroundStyle(picked ? Theme.accent : Color.secondary.opacity(0.6))
                Image(systemName: "folder.fill")
                    .font(.system(size: 10.5))
                    .foregroundStyle(Theme.folderGold)
                Text(label)
                    .font(.system(size: 12))
                    .lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 8).padding(.vertical, 4)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// One item could not move because the name is taken. Two answers only.
///
/// Deliberately NOT the full ConflictAction set: overwrite_newer, overwrite_size
/// and the rest are rclone flags for a TRANSFER. A local move is one rename with
/// no gradations, so offering them would describe behaviour that does not exist.
struct MoveClashSheet: View {
    let name: String
    let folder: String
    @Binding var rename: String
    let onCancel: () -> Void
    let onOverwrite: () -> Void
    let onRename: () -> Void

    private var trimmed: String { rename.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var renameValid: Bool {
        !trimmed.isEmpty && trimmed != name && trimmed != "." && trimmed != ".."
            && !trimmed.contains("/")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("“\(name)” is already in that folder")
                .font(.system(size: 15, weight: .semibold))
                .lineLimit(2)
            Text(folder)
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1).truncationMode(.head)

            TextField("Move it in as…", text: $rename)
                .textFieldStyle(.roundedBorder)
                .onSubmit { if renameValid { onRename() } }

            HStack {
                Button("Replace", action: onOverwrite)
                    .tint(Color(nsColor: .systemRed))
                Spacer()
                Button("Cancel", action: onCancel).keyboardShortcut(.cancelAction)
                Button("Move In As…", action: onRename)
                    .buttonStyle(.borderedProminent)
                    .tint(Theme.accent)
                    .disabled(!renameValid)
            }
        }
        .padding(18)
        .frame(width: 440)
    }
}
