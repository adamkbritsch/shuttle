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
    let entry: Entry
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
                    Text("Delete \u{201C}\(entry.name)\u{201D}?")
                        .font(.system(size: 15, weight: .semibold))
                        .lineLimit(2).truncationMode(.middle)
                    Text(detail)
                        .font(.system(size: 11.5))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Text((entry.path as NSString).deletingLastPathComponent)
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

    private var detail: String {
        guard let stat else { return "Checking what is there\u{2026}" }
        if !stat.isDir { return humanBytes(stat.bytes) }
        let f = stat.files == 1 ? "1 file" : "\(stat.files) files"
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
