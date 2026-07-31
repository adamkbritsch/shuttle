import Foundation

/// Bulk rename: the name transform, the collision analysis, and the order the
/// renames have to run in.
///
/// Deliberately pure Foundation with no view code and no network, so the whole
/// thing is testable on its own and the sheet is only a renderer of `BulkRenamePlan`.
///
/// Two things here are not obvious and are the reason this file exists at all:
///
/// * **Order matters.** Renumbering `Ep 01…Ep 05` to start at 2 makes the first row
///   want `Ep 02`, a name another selected file still holds. The relay's
///   `validate_rename` refuses that (`os.path.exists(dest)`), so a naive in-order
///   loop fails four of five. `plan.steps` is ordered so a target is never a name
///   still held by something that has yet to move.
/// * **The relay cannot see the batch.** It validates one rename at a time and has
///   no idea two of them collide with each other. That check has to happen here.
enum BulkRenameOp: String, CaseIterable, Identifiable {
    case findReplace, affix, number

    var id: String { rawValue }

    var label: String {
        switch self {
        case .findReplace: return "Find & Replace"
        case .affix:       return "Add Prefix or Suffix"
        case .number:      return "Sequential Numbering"
        }
    }

    var detail: String {
        switch self {
        case .findReplace: return "Replace text wherever it appears in the name."
        case .affix:       return "Insert text before the name, after it, or both."
        case .number:      return "Number the items in the order shown in the list."
        }
    }
}

struct BulkRenameSpec: Equatable {
    var op: BulkRenameOp = .findReplace

    var find = ""
    var replace = ""
    var ignoreCase = false

    var prefix = ""
    var suffix = ""

    /// Must contain `{n}`; the sheet disables Apply until it does.
    var pattern = "{n}"
    var start = 1
    var pad = 2
}

struct BulkRenameRow: Identifiable, Equatable {
    /// Why this row cannot be applied. Nil means it is fine.
    enum Issue: Equatable {
        /// Not a usable filename at all. Mirrors the relay's own name check.
        case invalid
        /// Another row in this batch proposes the same name.
        case duplicate
        /// Something already in this folder holds that name and is not moving.
        case occupied(String)
        /// Would have to trade names with another selected item.
        case swap(String)
    }

    let entry: Entry
    let newName: String
    let issue: Issue?

    var id: String { entry.path }
    var changed: Bool { newName != entry.name }

    var reason: String? {
        switch issue {
        case .none:                return nil
        case .invalid:             return "not a usable name"
        case .duplicate:           return "two items would share this name"
        case .occupied(let who):   return "\(who) already has this name"
        case .swap(let who):       return "would have to swap names with \(who) — "
                                        + "sort the list the other way, or rename in two passes"
        }
    }
}

/// One rename to send, in execution order.
struct BulkRenameStep: Equatable {
    let path: String
    let newName: String
}

struct BulkRenamePlan: Equatable {
    /// Every selected item in the order the pane is drawing them, for display.
    let rows: [BulkRenameRow]
    /// Only the rows that actually change, ordered so each one can succeed.
    let steps: [BulkRenameStep]

    var changedCount: Int { rows.filter(\.changed).count }
    var blocked: Bool { rows.contains { $0.issue != nil } }
    var canApply: Bool { !blocked && !steps.isEmpty }

    static func make(items: [Entry], spec: BulkRenameSpec,
                     existingNames: Set<String>) -> BulkRenamePlan {
        // 1. Propose a name for every item, numbered by position in the pane.
        let proposed: [(entry: Entry, newName: String)] = items.enumerated().map {
            ($0.element, BulkRename.apply(spec, to: $0.element.name,
                                          isDir: $0.element.isDir, index: $0.offset))
        }

        // 2. Names currently held by something that IS moving. Those free up during
        //    the batch, so wanting one is an ORDERING problem rather than a conflict.
        //
        //    The tempting test — "is the occupier part of the selection?" — is wrong.
        //    A selected file whose own name does not change still holds it: select A
        //    and B, replace a string that only appears in A, and A wanting to become
        //    B must still be refused.
        let movingNames = Set(proposed.filter { $0.newName != $0.entry.name }
                                      .map(\.entry.name))

        // 3. How many changing rows want each name, for the duplicate test. Only
        //    changing rows count: an unchanged row "wanting" its own name is not a
        //    clash, it is a no-op.
        var wanted: [String: Int] = [:]
        for p in proposed where p.newName != p.entry.name {
            wanted[p.newName, default: 0] += 1
        }

        var issues: [String: BulkRenameRow.Issue] = [:]   // keyed by path
        for p in proposed where p.newName != p.entry.name {
            if !BulkRename.isValidName(p.newName) {
                issues[p.entry.path] = .invalid
            } else if (wanted[p.newName] ?? 0) > 1 {
                issues[p.entry.path] = .duplicate
            } else if existingNames.contains(p.newName), !movingNames.contains(p.newName) {
                issues[p.entry.path] = .occupied(p.newName)
            }
        }

        // 4. Order what is left. A step may only run once nothing still holds its
        //    target, so repeatedly emit whatever is unblocked and release the name it
        //    vacates. Names are unique in a directory, so each step waits on at most
        //    one other -- this is Kahn's algorithm without needing an explicit graph.
        var pending = proposed.filter { $0.newName != $0.entry.name
                                        && issues[$0.entry.path] == nil }
        var held = Set(pending.map(\.entry.name))
        var steps: [BulkRenameStep] = []

        while !pending.isEmpty {
            let ready = pending.filter { !held.contains($0.newName) }
            if ready.isEmpty { break }        // everything left is in a cycle
            for r in ready {
                steps.append(BulkRenameStep(path: r.entry.path, newName: r.newName))
                held.remove(r.entry.name)
            }
            let done = Set(ready.map(\.entry.path))
            pending.removeAll { done.contains($0.entry.path) }
        }

        // 5. Whatever could never be emitted is a true cycle (A wants B's name while
        //    B wants A's). Renaming through a temporary name could resolve it, but a
        //    failure part-way would strand a file under a synthetic name with no way
        //    back, so these are refused instead. The user's fix is to re-sort.
        for r in pending {
            let blocker = pending.first { $0.entry.name == r.newName }?.entry.name
                ?? r.newName
            issues[r.entry.path] = .swap(blocker)
        }

        let rows = proposed.map {
            BulkRenameRow(entry: $0.entry, newName: $0.newName,
                          issue: issues[$0.entry.path])
        }
        return BulkRenamePlan(rows: rows, steps: steps)
    }
}

enum BulkRename {

    /// Mirrors the relay's own check in `guards.validate_rename`, so the preview
    /// blocks exactly what the server would refuse. Deliberately does NOT trim: the
    /// preview has to show literally what will be sent.
    static func isValidName(_ name: String) -> Bool {
        guard !name.isEmpty, name != ".", name != ".." else { return false }
        guard !name.contains("/") else { return false }
        return !name.unicodeScalars.contains { $0.value < 32 }
    }

    /// Splits a filename into the part that gets edited and the extension that does
    /// not.
    ///
    /// Directories are never split. `Some.Film.2024.2160p.BluRay-GROUP` has a
    /// "path extension" of `BluRay-GROUP` as far as Foundation is concerned, and
    /// treating that as an extension would drop a suffix into the middle of the name.
    static func split(_ name: String, isDir: Bool) -> (stem: String, ext: String) {
        guard !isDir else { return (name, "") }
        let ext = (name as NSString).pathExtension
        guard !ext.isEmpty else { return (name, "") }
        let stem = (name as NSString).deletingPathExtension
        // A dotfile such as `.env` reads as all-extension; leave it whole.
        guard !stem.isEmpty else { return (name, "") }
        return (stem, "." + ext)
    }

    /// `index` is the item's position in the pane, which is what numbering counts.
    static func apply(_ spec: BulkRenameSpec, to name: String,
                      isDir: Bool, index: Int) -> String {
        let (stem, ext) = split(name, isDir: isDir)

        switch spec.op {
        case .findReplace:
            guard !spec.find.isEmpty else { return name }
            // Literal, not regular expression: `replacingOccurrences` only treats the
            // pattern as a regex when told to, and it is never told to here. That is
            // what keeps "no regex" a structural guarantee rather than a convention.
            let options: String.CompareOptions = spec.ignoreCase ? [.caseInsensitive] : []
            let newStem = stem.replacingOccurrences(of: spec.find, with: spec.replace,
                                                    options: options)
            return newStem + ext

        case .affix:
            guard !spec.prefix.isEmpty || !spec.suffix.isEmpty else { return name }
            // The suffix lands before the extension, which is the only placement that
            // leaves the file openable.
            return spec.prefix + stem + spec.suffix + ext

        case .number:
            guard spec.pattern.contains("{n}") else { return name }
            let n = spec.start + index
            let digits = spec.pad > 1 ? String(format: "%0\(spec.pad)d", n) : String(n)
            return spec.pattern.replacingOccurrences(of: "{n}", with: digits) + ext
        }
    }
}
