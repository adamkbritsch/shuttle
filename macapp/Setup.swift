import SwiftUI

/// Everything a fresh install has to be told, in one place, with a live check
/// beside each thing.
///
/// The design rule throughout: a control that can fail says so where it is, not in
/// a toast that has already gone by the time you look. Every group owns a
/// `CheckState` and a detail line, and every failed call writes its message into
/// that line rather than returning silently.

/// What a single check currently knows.
enum CheckState: Equatable {
    case unknown
    case checking
    case ok(String)
    case warn(String)
    case fail(String)

    var detail: String {
        switch self {
        case .unknown:  return "not checked yet"
        case .checking: return "checking…"
        case .ok(let s), .warn(let s), .fail(let s): return s
        }
    }
    var passes: Bool { if case .ok = self { return true }; return false }
    var color: Color {
        switch self {
        case .unknown:  return .secondary.opacity(0.5)
        case .checking: return Color(nsColor: .systemBlue)
        case .ok:       return Color(nsColor: .systemGreen)
        case .warn:     return Color(nsColor: .systemOrange)
        case .fail:     return Color(nsColor: .systemRed)
        }
    }
}

/// Runs the checks and holds their results.
@MainActor
final class SetupModel: ObservableObject {
    @Published var relay: CheckState = .unknown
    @Published var seedbox: CheckState = .unknown
    @Published var deployment: CheckState = .unknown
    @Published var destinations: CheckState = .unknown

    /// Auto-discovery progress, so a sweep that takes a few seconds does not look
    /// like a hang.
    @Published var discovering = false
    @Published var discovered: [String] = []
    @Published var discoveryNote = ""

    private let store: RelayStore
    init(store: RelayStore) { self.store = store }

    /// Everything green? The Setup section stays open until this is true, and the
    /// "Finish setup" card on the main view is shown while it is false.
    ///
    /// Deployment and destinations are deliberately NOT included: the first is a
    /// human checklist whose only real test is the relay answering (which the relay
    /// check already covers), and the second is informational.
    var complete: Bool { relay.passes && seedbox.passes }

    // ---------- relay ----------

    /// `/healthz` then an authenticated `/v1/targets`, which is exactly the pair a
    /// caller needs to distinguish "nothing there" from "there but rejecting me".
    func checkRelay() async {
        relay = .checking
        let base = store.baseURL.trimmingCharacters(in: .whitespaces)
        guard !base.isEmpty else {
            relay = .fail("No address yet — find one below, or type it in")
            return
        }
        guard let probe = await RelayAPI.healthz(base) else {
            relay = .fail("No relay answered at \(base)")
            return
        }
        guard TokenStore.current != nil else {
            relay = .warn("Found \(probe) — needs the API token")
            return
        }
        switch await store.api.targets() {
        case .targets:
            relay = .ok("Connected to \(probe)")
            await store.refreshStatus()
            await store.loadTargets()
        case .unauthorized:
            relay = .fail("Relay answered, but refused the token")
        case .unreachable(let why):
            relay = .fail(why)
        }
    }

    /// Probe for a relay on this network.
    ///
    /// Candidates, cheapest and likeliest first: whatever is already configured,
    /// the usual NAS `.local` names, then every address on this Mac's own /24. The
    /// sweep is what makes it work for someone who has never typed an address, and
    /// it is bounded — one short GET per host, 64 at a time.
    func discover() async {
        discovering = true
        discovered = []
        discoveryNote = "Looking for a relay on this network…"
        defer { discovering = false }

        var candidates: [String] = []
        let saved = store.baseURL.trimmingCharacters(in: .whitespaces)
        if !saved.isEmpty { candidates.append(saved) }
        candidates += ["nas.local", "ugreen.local", "synology.local", "truenas.local"]
            .map { "http://\($0):8789" }
        candidates += Self.localSubnetHosts().map { "http://\($0):8789" }

        var seen = Set<String>()
        let unique = candidates.filter { seen.insert($0).inserted }

        var hits: [String] = []
        await withTaskGroup(of: (String, String?).self) { group in
            var running = 0
            var index = 0
            while index < unique.count || running > 0 {
                while running < 64, index < unique.count {
                    let url = unique[index]; index += 1; running += 1
                    group.addTask { (url, await RelayAPI.healthz(url, timeout: 1.5)) }
                }
                if let (url, found) = await group.next() {
                    running -= 1
                    if found != nil { hits.append(url) }
                }
            }
        }
        discovered = hits
        discoveryNote = hits.isEmpty
            ? "No relay found. Check it is running on the NAS, then enter the address by hand."
            : "Found \(hits.count) relay\(hits.count == 1 ? "" : "s")."
    }

    /// This Mac's own IPv4 /24s, so the sweep looks where the NAS actually is
    /// rather than at a guessed range. Link-local and loopback are skipped.
    private nonisolated static func localSubnetHosts() -> [String] {
        var out: [String] = []
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0, let first = head else { return [] }
        defer { freeifaddrs(head) }

        var prefixes = Set<String>()
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            guard let addr = ptr.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host,
                              socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0
            else { continue }
            let ip = String(cString: host)
            guard !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") else { continue }
            let parts = ip.split(separator: ".")
            guard parts.count == 4 else { continue }
            prefixes.insert(parts.prefix(3).joined(separator: "."))
        }
        // Two /24s is already 508 probes; more than that is someone with a lot of
        // interfaces up and is not worth the wait.
        for prefix in prefixes.sorted().prefix(2) {
            out += (1...254).map { "\(prefix).\($0)" }
        }
        return out
    }

    // ---------- seedbox ----------

    /// A real listing, not a ping: the credentials are only proven by the relay
    /// actually reaching the seedbox with them.
    func checkSeedbox() async {
        seedbox = .checking
        await store.loadSeedbox()
        guard store.seedbox.configured else {
            seedbox = .warn("Not configured yet — transfers need it")
            return
        }
        switch await store.api.browse("/seedbox/downloads", limit: 1) {
        case .listing(let l):
            seedbox = .ok("\(store.seedbox.user)@\(store.seedbox.host) — listing works "
                          + "(\(l.total) item\(l.total == 1 ? "" : "s"))")
        case .refused(let why):   seedbox = .fail(why)
        case .unauthorized:       seedbox = .fail("The relay refused the token")
        case .unreachable(let why): seedbox = .fail(why)
        }
    }

    // ---------- deployment + destinations ----------

    func checkDeployment() async {
        deployment = .checking
        let base = store.baseURL.trimmingCharacters(in: .whitespaces)
        if !base.isEmpty, let found = await RelayAPI.healthz(base) {
            deployment = .ok("Relay is running — \(found)")
        } else {
            deployment = .warn("No relay answering yet")
        }
    }

    func checkDestinations() async {
        destinations = .checking
        switch await store.api.targets() {
        case .targets(let t):
            // Go through loadTargets rather than assigning: it is the one place that
            // also feeds the backends, which is what FreeSpaceLabel reads.
            await store.loadTargets()
            destinations = t.isEmpty
                ? .warn("The relay reports no drop targets — add volumes in its compose file")
                : .ok(t.map(\.name).joined(separator: ", "))
        case .unauthorized:       destinations = .fail("The relay refused the token")
        case .unreachable(let why): destinations = .fail(why)
        }
    }

    func checkAll() async {
        await checkRelay()
        await checkDeployment()
        await checkSeedbox()
        await checkDestinations()
    }
}


/// A dot, a name, and one line saying what the check found.
struct CheckRow: View {
    let title: String
    let state: CheckState

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Circle().fill(state.color).frame(width: 7, height: 7)
                .padding(.top, 3)
            Text(title).font(.system(size: 12, weight: .medium))
            Text(state.detail)
                .font(.system(size: 10.5))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
    }
}


/// One shell command with a copy button. The command is selectable as well as
/// copyable, because a value you cannot see is a value you cannot check.
struct CopyRow: View {
    let command: String
    @State private var copied = false

    var body: some View {
        HStack(spacing: 6) {
            Text(command)
                .font(.system(size: 10.5, design: .monospaced))
                .textSelection(.enabled)
                .padding(.horizontal, 7).padding(.vertical, 5)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 5).fill(Theme.pillFill))
            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(command, forType: .string)
                copied = true
                Task {
                    try? await Task.sleep(nanoseconds: 1_500_000_000)
                    copied = false
                }
            } label: {
                Image(systemName: copied ? "checkmark" : "doc.on.doc")
                    .font(.system(size: 10.5))
            }
            .buttonStyle(.plain)
            .foregroundStyle(copied ? Color(nsColor: .systemGreen) : .secondary)
            .help("Copy")
        }
    }
}


/// The banner on the main view while setup is unfinished.
struct SetupCard: View {
    let missing: String
    let open: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "wrench.and.screwdriver.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color(nsColor: .systemOrange))
            VStack(alignment: .leading, spacing: 1) {
                Text("Finish setting up Shuttle")
                    .font(.system(size: 12, weight: .semibold))
                Text(missing)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button("Open Setup", action: open)
        }
        .padding(.horizontal, 12).padding(.vertical, 9)
        .background(Color(nsColor: .systemOrange).opacity(0.10))
        .overlay(alignment: .bottom) { Divider().overlay(Theme.hairline) }
    }
}


/// The Setup surface: every field a fresh install needs, in required-first order,
/// each with the check that proves it works.
///
/// Auto-expanded until `model.complete`, collapsed after — the panel should be
/// impossible to miss on day one and out of the way on day two.
struct SetupSection: View {
    @ObservedObject var store: RelayStore
    @ObservedObject var model: SetupModel
    @Binding var base: String
    @Binding var token: String

    @State private var expanded = true
    @State private var settledOnce = false
    @State private var savingToken = false
    @State private var tokenNote = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            if expanded {
                VStack(alignment: .leading, spacing: 18) {
                    relayGroup
                    Divider()
                    seedboxGroup
                    Divider()
                    deploymentGroup
                    Divider()
                    destinationsGroup
                }
                .padding(.top, 14)
            }
        }
        .task {
            await model.checkAll()
            // Collapse only if it was already finished when opened. Collapsing the
            // moment the last check passes would yank the panel shut under someone
            // who is still reading it.
            if model.complete, !settledOnce { expanded = false }
            settledOnce = true
            if store.baseURL.trimmingCharacters(in: .whitespaces).isEmpty {
                await model.discover()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: model.complete ? "checkmark.seal.fill" : "wrench.and.screwdriver.fill")
                .font(.system(size: 12))
                .foregroundStyle(model.complete ? Color(nsColor: .systemGreen)
                                                : Color(nsColor: .systemOrange))
            Text("Setup").font(.system(size: 13, weight: .semibold))
            Text(model.complete ? "everything checks out" : "needs attention")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
            Spacer()
            Button(expanded ? "Hide" : "Show") { expanded.toggle() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.accent)
            Button {
                Task { await model.checkAll() }
            } label: {
                Image(systemName: "arrow.clockwise").font(.system(size: 11))
            }
            .buttonStyle(.plain).foregroundStyle(.secondary)
            .help("Re-run every check")
        }
    }

    // ---------- a) relay ----------

    private var relayGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            CheckRow(title: "1. Relay connection", state: model.relay)
            Text("Shuttle drives a small service on the NAS. Everything else depends "
                 + "on this one working.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            TextField("http://nas.local:8789", text: $base)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12, design: .monospaced))

            HStack(spacing: 8) {
                SecureField(TokenStore.current == nil ? "API token"
                                                     : "token saved — type to replace",
                            text: $token)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                if TokenStore.current != nil {
                    Button("Clear") {
                        TokenStore.save("")
                        token = ""
                        tokenNote = "Token cleared."
                        Task {
                            await store.saveToken("")
                            await model.checkRelay()
                        }
                    }
                    .help("Forget the saved token")
                }
            }
            Text("RELAY_API_TOKEN from the relay's .env on the NAS. Kept in a "
                 + "private file in Application Support, readable only by you.")
                .font(.system(size: 10, design: .default))
                .foregroundStyle(.tertiary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Button("Save & Test") {
                    savingToken = true
                    tokenNote = ""
                    Task {
                        store.baseURL = base.trimmingCharacters(in: .whitespaces)
                        if !token.isEmpty {
                            await store.saveToken(token)
                            token = ""
                        }
                        await model.checkRelay()
                        await model.checkDeployment()
                        await model.checkDestinations()
                        savingToken = false
                    }
                }
                .disabled(savingToken)
                Button(model.discovering ? "Searching…" : "Find my relay") {
                    Task {
                        await model.discover()
                        // One unambiguous hit is not a choice, so take it.
                        if model.discovered.count == 1 { base = model.discovered[0] }
                    }
                }
                .disabled(model.discovering)
                if savingToken || model.discovering { ProgressView().controlSize(.small) }
                Spacer()
            }

            if !tokenNote.isEmpty {
                Text(tokenNote).font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            if !model.discoveryNote.isEmpty {
                Text(model.discoveryNote)
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
            }
            ForEach(model.discovered, id: \.self) { found in
                HStack(spacing: 6) {
                    Image(systemName: "dot.radiowaves.left.and.right")
                        .font(.system(size: 10)).foregroundStyle(Theme.accent)
                    Text(found).font(.system(size: 10.5, design: .monospaced))
                    Button("Use this") { base = found }
                        .buttonStyle(.plain).font(.system(size: 10.5))
                        .foregroundStyle(Theme.accent)
                    Spacer()
                }
            }
        }
    }

    // ---------- b) seedbox ----------

    private var seedboxGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            CheckRow(title: "2. Remote server", state: model.seedbox)
            Text("The credentials the RELAY uses to reach your seedbox. They are "
                 + "stored on the NAS and never sent back to this Mac — this app only "
                 + "ever learns whether a password is set, never what it is.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SeedboxForm(store: store, model: model)
        }
    }

    // ---------- c) deployment ----------

    private var deploymentGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            CheckRow(title: "3. Relay on the NAS", state: model.deployment)
            Text("This part cannot be done from here — the relay is a container on "
                 + "the NAS, so these are the steps to run there. The check above "
                 + "turns green once it answers.")
                .font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            step(1, "Copy the relay onto the NAS and enter its folder.")
            CopyRow(command: "git clone https://github.com/adamkbritsch/shuttle.git && cd shuttle/relay")
            step(2, "Create .env and fill in these keys. Nothing here has a default — "
                    + "pick your own token, and point the binds at your tailnet address.")
            CopyRow(command: "cp .env.example .env && $EDITOR .env")
            Text("Keys to set: RELAY_API_TOKEN, RELAY_API_BIND, FTP_BIND_ADDR, PUID, PGID")
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.tertiary)
            step(3, "Start it.")
            CopyRow(command: "docker compose up -d")
            step(4, "Check it is answering, then press Re-check.")
            CopyRow(command: "curl -s http://localhost:8789/healthz")

            HStack(spacing: 8) {
                Button("Re-check") { Task { await model.checkDeployment(); await model.checkRelay() } }
                if case .checking = model.deployment { ProgressView().controlSize(.small) }
                Spacer()
            }
            .padding(.top, 2)
        }
    }

    private func step(_ n: Int, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("\(n).").font(.system(size: 10.5, weight: .semibold))
                .foregroundStyle(.secondary)
            Text(text).font(.system(size: 10.5)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.top, 4)
    }

    // ---------- d) destinations ----------

    private var destinationsGroup: some View {
        VStack(alignment: .leading, spacing: 7) {
            CheckRow(title: "4. Destinations", state: model.destinations)
            if store.targets.isEmpty {
                Text("These are the volumes transfers can land in. The relay builds "
                     + "the list from the volumes mounted into it, so an empty list "
                     + "means its compose file needs them added.")
                    .font(.system(size: 10.5)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(store.targets) { t in
                    HStack(spacing: 6) {
                        Image(systemName: t.symbol).font(.system(size: 10))
                            .foregroundStyle(Theme.folderGold)
                        Text(t.name).font(.system(size: 11, weight: .medium))
                        Text(t.detail).font(.system(size: 10)).foregroundStyle(.tertiary)
                        Spacer()
                    }
                }
            }
        }
    }
}


/// The remote-server credential form.
///
/// Split out because the parent's body was long enough to hit the type-checker's
/// budget, which fails the build with "unable to type-check this expression in
/// reasonable time" rather than anything that points at the cause.
private struct SeedboxForm: View {
    @ObservedObject var store: RelayStore
    @ObservedObject var model: SetupModel

    @State private var proto: SeedboxProtocol = .ftps
    @State private var host = ""
    @State private var port = "21"
    @State private var user = ""
    @State private var password = ""
    @State private var root = "/"
    @State private var busy = false
    @State private var note = ""
    @State private var seeded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Picker("", selection: $proto) {
                    ForEach(SeedboxProtocol.allCases) { p in Text(p.label).tag(p) }
                }
                .labelsHidden().fixedSize()
                .onChange(of: proto) { _, p in port = String(p.defaultPort) }
                TextField("host.example.com", text: $host)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                TextField("port", text: $port)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 62)
            }
            HStack(spacing: 8) {
                TextField("username", text: $user)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                SecureField(store.seedbox.hasPassword ? "password saved — type to replace"
                                                      : "password",
                            text: $password)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack(spacing: 8) {
                Text("Path").font(.system(size: 11)).foregroundStyle(.secondary)
                TextField("/", text: $root)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
            }
            HStack(spacing: 8) {
                Button(busy ? "Testing…" : "Save & Test") {
                    busy = true; note = ""
                    Task {
                        let ok = await store.saveSeedbox(
                            protocolName: proto.rawValue,
                            host: host.trimmingCharacters(in: .whitespaces),
                            port: Int(port) ?? proto.defaultPort,
                            user: user.trimmingCharacters(in: .whitespaces),
                            password: password,
                            root: root.isEmpty ? "/" : root)
                        password = ""          // never keep it around after sending
                        if !ok { note = "The relay could not connect with those details." }
                        await model.checkSeedbox()
                        busy = false
                    }
                }
                .disabled(busy || host.isEmpty || user.isEmpty
                          || (!store.seedbox.hasPassword && password.isEmpty))
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }
            if !note.isEmpty {
                Text(note).font(.system(size: 10.5))
                    .foregroundStyle(Color(nsColor: .systemRed))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .onAppear { seed(store.seedbox) }
        .onChange(of: store.seedbox) { _, c in seed(c) }
    }

    /// Fill from whatever the relay reports, so the form shows the live
    /// configuration. Only once, and never the password — that is not returned.
    private func seed(_ c: SeedboxConfig) {
        guard !seeded, !c.host.isEmpty else { return }
        seeded = true
        proto = SeedboxProtocol(rawValue: c.protocolName) ?? .ftps
        host = c.host; port = String(c.port); user = c.user; root = c.root
    }
}
