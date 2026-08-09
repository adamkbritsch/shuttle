import Foundation

/// The relay's bearer token.
///
/// **Deliberately NOT in the Keychain.** It was, and it was the single worst thing
/// about using this app: macOS put up a modal
/// "Shuttle wants to access key com.britsch.shuttle.api — enter the login
/// keychain password" dialog that BLOCKED startup, and it came back over and over.
///
/// The cause is that a Keychain ACL is bound to the app's code signature. This app is
/// built by a hand-rolled `swiftc` + hand-assembled bundle with no Apple developer
/// identity, so every rebuild is a fresh binary; switching from ad-hoc to a stable
/// self-signed certificate fixed the *designated requirement* but not the prompt,
/// because a self-signed cert that carries no trust setting does not satisfy the ACL
/// check either. Short of paying for a Developer ID, that dialog cannot be made to
/// stay away — and being asked for the login password on every launch is far worse
/// than the thing the Keychain was protecting against.
///
/// So the token lives in a 0600 file in Application Support instead. What that costs,
/// stated plainly: any process running as this user can read it, whereas the Keychain
/// would have gated it per-application. What it is protecting is a bearer token for a
/// service that only listens on this tailnet, and the same token already sits in
/// plaintext in `.env` on the NAS. For that specific secret this is the right trade;
/// for a password or a payment credential it would not be.
enum TokenStore {
    private static let lock = NSLock()
    private static var cached: String?
    private static var primed = false

    private static var supportDir: URL {
        FileManager.default.urls(for: .applicationSupportDirectory,
                                 in: .userDomainMask)[0]
            .appendingPathComponent("Shuttle", isDirectory: true)
    }

    private static var fileURL: URL { supportDir.appendingPathComponent("token") }

    /// Where the relay's address is published for other tools on this Mac.
    private static var relayFileURL: URL { supportDir.appendingPathComponent("relay.json") }

    /// Publish the relay's base URL beside the token, so a companion app can find
    /// the relay without being configured separately.
    ///
    /// Same 0600/0700 treatment as the token: it is not a secret in the way the
    /// token is, but it sits in the same directory and anything reading one reads
    /// the other, so there is no reason to make it looser. Written whenever the
    /// address is saved OR merely confirmed to work, since a build with a baked-in
    /// default never goes through the save path at all.
    static func publishRelayBase(_ base: String) {
        let trimmed = base.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        let fm = FileManager.default
        try? fm.createDirectory(at: supportDir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        guard let body = try? JSONSerialization.data(
                withJSONObject: ["base_url": trimmed],
                // withoutEscapingSlashes: valid JSON either way, but a URL written
                // as http:\/\/host is unreadable in a file someone may open by hand.
                options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
        else { return }
        // Rewriting an identical file would churn its mtime on every launch, which
        // a watcher on the other side would see as a change.
        if let existing = try? Data(contentsOf: relayFileURL),
           (try? JSONSerialization.jsonObject(with: existing)) as? [String: String]
               == ["base_url": trimmed] {
            return
        }
        fm.createFile(atPath: relayFileURL.path, contents: body,
                      attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600],
                              ofItemAtPath: relayFileURL.path)
    }

    /// Kept for API compatibility with the Keychain version; nothing consults it now.
    private(set) static var lastReadStatus: OSStatus = 0

    static var current: String? {
        lock.lock(); defer { lock.unlock() }
        return cached
    }

    static var isPrimed: Bool {
        lock.lock(); defer { lock.unlock() }
        return primed
    }

    /// Reads are a single small file read, so unlike the Keychain version this needs
    /// no off-main-thread coalescing — but the async shape is kept so callers and the
    /// launch sequence are unchanged.
    static func withToken(_ completion: @escaping (String?) -> Void) {
        let v = load()
        DispatchQueue.main.async { completion(v) }
    }

    static func token() async -> String? { load() }

    static func prime() { _ = load() }

    private static func load() -> String? {
        lock.lock()
        if primed { let v = cached; lock.unlock(); return v }
        lock.unlock()

        let value = (try? String(contentsOf: fileURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        lock.lock()
        cached = (value?.isEmpty ?? true) ? nil : value
        primed = true
        let v = cached
        lock.unlock()
        return v
    }

    static func save(_ token: String) {
        let t = token.trimmingCharacters(in: .whitespacesAndNewlines)
        lock.lock()
        cached = t.isEmpty ? nil : t
        primed = true
        lock.unlock()

        let url = fileURL
        let dir = url.deletingLastPathComponent()
        let fm = FileManager.default
        // 0700 on the directory and 0600 on the file: this is the whole protection,
        // so create them with those modes rather than fixing them afterwards.
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true,
                                attributes: [.posixPermissions: 0o700])
        if t.isEmpty {
            try? fm.removeItem(at: url)
            return
        }
        fm.createFile(atPath: url.path, contents: Data(t.utf8),
                      attributes: [.posixPermissions: 0o600])
        try? fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Provision once from the environment instead of typing it into a sheet:
    ///     RELAY_SEED_TOKEN=… open -a Shuttle
    static func seedFromEnvironmentIfEmpty() {
        guard load() == nil,
              let seed = ProcessInfo.processInfo.environment["RELAY_SEED_TOKEN"],
              !seed.isEmpty else { return }
        save(seed)
        unsetenv("RELAY_SEED_TOKEN")
    }
}
