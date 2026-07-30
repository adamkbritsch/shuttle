import Foundation

/// Wire types for the relay's /v1 API.
///
/// `.convertFromSnakeCase` on the decoder means the JSON stays snake_case (matching
/// the Python side and the README) while Swift stays camelCase, with no CodingKeys.
enum Wire {
    static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        return d
    }()
}

struct Health: Decodable, Equatable {
    let ok: Bool
    let api: Int
    let jobsActive: Int
}

struct Entry: Decodable, Identifiable, Equatable {
    let name: String
    let path: String
    let isDir: Bool
    let size: Int64?
    let mtime: Double?

    var id: String { path }
    // The symbol lives on the model, not in the view — the house convention, so the
    // icon and the label can never disagree.
    var symbol: String { isDir ? "folder.fill" : "doc.fill" }

    /// The tree carries only paths and names, so it synthesises an Entry to hand to
    /// the enqueue callback. Decodable's implicit memberwise init is not accessible
    /// from another file, hence this one.
    init(name: String, path: String, isDir: Bool, size: Int64?, mtime: Double?) {
        self.name = name; self.path = path; self.isDir = isDir
        self.size = size; self.mtime = mtime
    }
}

struct Listing: Decodable, Equatable {
    let path: String
    let parent: String?
    let entries: [Entry]
    let total: Int
    let offset: Int
    let limit: Int
    let truncated: Bool
}

struct Target: Decodable, Identifiable, Equatable {
    let name: String
    let path: String
    let freeBytes: Int64?
    let isTestTarget: Bool
    let exists: Bool

    var id: String { path }
    var symbol: String { isTestTarget ? "testtube.2" : "externaldrive.fill" }
    var detail: String {
        // _scratch is the stack's own data/test bind, so its free space is the docker
        // volume's rather than a media volume's. Say so instead of implying otherwise.
        if isTestTarget { return "test target" }
        guard let freeBytes else { return "" }
        return "\(humanBytes(freeBytes)) free"
    }
}

enum JobKind: String, Equatable {
    case queued, running, done, failed, cancelled, dismissed, unknown
}

struct Job: Decodable, Identifiable, Equatable {
    let id: Int
    let state: String
    let isDir: Bool
    let src: String
    let destDir: String
    let destName: String
    let bytesDone: Int64
    let bytesTotal: Int64
    let percent: Double
    let speed: Double
    let eta: Int
    let filesDone: Int
    let filesTotal: Int
    let error: String?
    let destPreexisted: Bool
    let createdAt: Double?
    let updatedAt: Double?
    let finishedAt: Double?

    var kind: JobKind { JobKind(rawValue: state) ?? .unknown }
    var isActive: Bool { kind == .queued || kind == .running }

    var symbol: String {
        switch kind {
        case .queued:    return "clock"
        case .running:   return "arrow.down.circle"
        case .done:      return "checkmark.circle.fill"
        case .failed:    return "exclamationmark.triangle.fill"
        case .cancelled: return "xmark.circle"
        default:         return "circle"
        }
    }

    var tint: StatusTint {
        switch kind {
        case .queued:    return .idle
        case .running:   return .busy
        case .done:      return .good
        case .failed:    return .bad
        case .cancelled: return .warn
        default:         return .idle
        }
    }

    /// Deliberately mirrors render.py's phrasing, so this app and an FTP listing of
    /// the same job read identically when you compare them while debugging.
    var progressText: String {
        switch kind {
        case .queued:
            return "Queued"
        case .running:
            var bits = [String(format: "%.1f%%", percent),
                        "\(humanBytes(bytesDone)) of \(humanBytes(bytesTotal))"]
            if speed > 0 { bits.append("\(humanBytes(Int64(speed)))/s") }
            bits.append("ETA \(humanETA(eta))")
            if filesTotal > 1 { bits.append("file \(filesDone) of \(filesTotal)") }
            return bits.joined(separator: "  ·  ")
        case .done:
            return "Copied \(humanBytes(bytesDone))"
        case .failed:
            return error ?? "Failed"
        case .cancelled:
            return "Cancelled at \(humanBytes(bytesDone))"
        default:
            return state.capitalized
        }
    }

    /// The virtual path the copy landed at, for the row's secondary line.
    var destPath: String { destDir + "/" + destName }
}

struct JobsPage: Decodable, Equatable {
    let active: [Job]
    let recent: [Job]
    let rev: String?
}

struct TargetsPage: Decodable, Equatable { let targets: [Target] }

struct VerifyResult: Decodable, Equatable {
    struct Side: Decodable, Equatable {
        let path: String
        let files: Int?
        let bytes: Int64?
        let exists: Bool
    }
    let id: Int
    let state: String
    let src: Side
    let dest: Side
    let filesMatch: Bool
    let bytesMatch: Bool

    var summary: String {
        guard let sf = src.files, let df = dest.files else { return "Could not walk both sides" }
        let b = dest.bytes.map { humanBytes($0) } ?? "?"
        return "\(df) of \(sf) files  ·  \(b)  ·  \(filesMatch && bytesMatch ? "match" : "MISMATCH")"
    }
    var ok: Bool { filesMatch && bytesMatch }
}

struct APIError: Decodable, Equatable { let error: String }


struct RelaySettings: Decodable, Equatable {
    let maxConcurrent: Int
    let maxConcurrentCeiling: Int
}


// MARK: - Conflicts

/// One destination file that already exists under the same relative path.
struct Conflict: Decodable, Equatable, Identifiable {
    let path: String
    let srcSize: Int64
    let srcMtime: Double
    let destSize: Int64
    let destMtime: Double

    var id: String { path }

    enum CodingKeys: String, CodingKey {
        case path
        case srcSize = "src_size"
        case srcMtime = "src_mtime"
        case destSize = "dest_size"
        case destMtime = "dest_mtime"
    }
}

/// The relay's 409 body: it refused the enqueue and is asking what to do.
struct ConflictReport: Decodable, Equatable {
    let destName: String
    let conflicts: [Conflict]
    let truncated: Bool

    enum CodingKeys: String, CodingKey {
        case destName = "dest_name"
        case conflicts, truncated
    }
}

/// FileZilla's "Target file already exists" actions, minus the two this relay
/// cannot honestly implement. Raw values are the relay's `on_conflict` wire values.
///
/// "Resume file transfer" is absent on purpose: rclone restarts an interrupted
/// file from zero rather than resuming, so the option would be a button that lies.
enum ConflictAction: String, CaseIterable, Identifiable {
    case overwrite
    case overwriteNewer         = "overwrite_newer"
    case overwriteSize          = "overwrite_size"
    case overwriteSizeOrNewer   = "overwrite_size_or_newer"
    case rename
    case skip

    var id: String { rawValue }

    var label: String {
        switch self {
        case .overwrite:             return "Overwrite file"
        case .overwriteNewer:        return "Overwrite file if source file is newer"
        case .overwriteSize:         return "Overwrite file if size differs"
        case .overwriteSizeOrNewer:  return "Overwrite file if size differs or source file is newer"
        case .rename:                return "Rename file…"
        case .skip:                  return "Skip file"
        }
    }

    var detail: String {
        switch self {
        case .overwrite:            return "Always replaces the destination, even when the two are identical."
        case .overwriteNewer:       return "Compares timestamps only."
        case .overwriteSize:        return "Compares sizes only."
        case .overwriteSizeOrNewer: return "The usual choice: replaces anything that differs, keeps a newer destination."
        case .rename:               return "Keeps the destination file and sends this one under a new name."
        case .skip:                 return "Leaves the destination alone and transfers nothing."
        }
    }
}


// MARK: - Seedbox connection

/// The NAS's own connection to the seedbox. Credentials live on the NAS, never on
/// this Mac and never in the repo: the relay stores them 0600 in its data dir and
/// hands them to rclone as RCLONE_CONFIG_SEEDBOX_* so no rclone.conf is needed.
struct SeedboxConfig: Decodable, Equatable {
    var protocolName: String
    var host: String
    var port: Int
    var user: String
    var hasPassword: Bool
    var root: String
    var configured: Bool

    enum CodingKeys: String, CodingKey {
        case protocolName = "protocol"
        case host, port, user, root, configured
        case hasPassword = "has_password"
    }

    static let empty = SeedboxConfig(protocolName: "ftps", host: "", port: 21,
                                     user: "", hasPassword: false, root: "/",
                                     configured: false)
}

struct SeedboxProbe: Decodable, Equatable {
    let entries: Int
    let directories: Int
    let files: Int
}

struct SeedboxSaveResponse: Decodable, Equatable {
    let seedbox: SeedboxConfig
    let ok: Bool
    let probe: SeedboxProbe?
}

/// rclone's backends, named the way a seedbox provider names them.
enum SeedboxProtocol: String, CaseIterable, Identifiable {
    case ftps, ftp, sftp
    var id: String { rawValue }
    var label: String {
        switch self {
        case .ftps: return "FTPS (explicit TLS)"
        case .ftp:  return "FTP (plain)"
        case .sftp: return "SFTP"
        }
    }
    var defaultPort: Int { self == .sftp ? 22 : 21 }
}
