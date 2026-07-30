import AppKit
import SwiftUI

// ============================================================================
// SplitTree — FileZilla-grade nested, draggable, persisted dividers for a
// SwiftUI-on-AppKit app with no Xcode project.
//
// The whole split hierarchy is built in AppKit (nested NSSplitViewControllers).
// Only the leaves are SwiftUI, each in its own NSHostingView. There is exactly
// ONE SwiftUI -> AppKit boundary, so SwiftUI never has to parent a child view
// controller (which is the fragile part of NSViewControllerRepresentable inside
// a plain NSHostingView).
// ============================================================================

// MARK: - Axis

/// AppKit's naming is inverted: a split view whose dividers run up-and-down
/// (`isVertical == true`) arranges its panes left-to-right. This wrapper names
/// the arrangement, not the divider.
enum SplitAxis {
    /// Panes side by side, vertical dividers. `NSSplitView.isVertical == true`.
    case columns
    /// Panes stacked, horizontal dividers. `NSSplitView.isVertical == false`.
    case rows

    var isVertical: Bool { self == .columns }
}

// MARK: - Layout description

/// Everything `NSSplitViewItem` can be told about one pane.
struct SplitPaneSpec {
    /// Width for `.columns`, height for `.rows`. `nil` leaves it unspecified.
    var minThickness: CGFloat?
    var maxThickness: CGFloat?
    /// Enables drag-past-the-minimum and double-click-the-divider collapsing.
    var canCollapse: Bool = false
    /// Lowest priority absorbs a window resize first. Keep below
    /// `NSLayoutConstraint.Priority.dragThatCannotResizeWindow` (490).
    var holdingPriority: NSLayoutConstraint.Priority = .defaultLow
    /// The ratio a double-click on a neighbouring divider snaps back to, and the
    /// size used when entering full screen.
    var preferredFraction: CGFloat?
    /// Caps growth from *automatic* sizing (window resize, full screen) without
    /// capping what a drag can do.
    var automaticMaxThickness: CGFloat?
    var startsCollapsed: Bool = false
    /// First-launch thickness, used ONLY when nothing is stored yet. AppKit does
    /// not seed a fresh split from `preferredThicknessFraction`; with unequal
    /// holding priorities it hands the low-priority pane everything and clamps
    /// the rest to their minimums. This is the only way to get a sane cold start.
    var seedThickness: CGFloat?

    init(min: CGFloat? = nil,
         max: CGFloat? = nil,
         canCollapse: Bool = false,
         holdingPriority: NSLayoutConstraint.Priority = .defaultLow,
         preferredFraction: CGFloat? = nil,
         automaticMax: CGFloat? = nil,
         startsCollapsed: Bool = false,
         seed: CGFloat? = nil) {
        self.minThickness = min
        self.maxThickness = max
        self.canCollapse = canCollapse
        self.holdingPriority = holdingPriority
        self.preferredFraction = preferredFraction
        self.automaticMaxThickness = automaticMax
        self.startsCollapsed = startsCollapsed
        self.seedThickness = seed
    }
}

/// A child of a split: its constraints plus what goes inside it. The child can
/// itself be another split, which is how nesting works.
struct SplitChild {
    var spec: SplitPaneSpec
    var node: SplitNode

    init(_ spec: SplitPaneSpec = SplitPaneSpec(), _ node: SplitNode) {
        self.spec = spec
        self.node = node
    }

    /// Convenience for a SwiftUI leaf.
    init<V: View>(_ spec: SplitPaneSpec = SplitPaneSpec(), @ViewBuilder view: () -> V) {
        self.spec = spec
        self.node = .leaf(AnyView(view()))
    }
}

indirect enum SplitNode {
    case leaf(AnyView)
    /// `key` is the UserDefaults suffix this split's divider positions persist under.
    case split(axis: SplitAxis, key: String, children: [SplitChild])
}

// MARK: - The split view subclass

final class SLSplitView: NSSplitView {
    /// Extra points of grab area either side of the drawn hairline. The line
    /// stays 1pt; only the hit region and the resize cursor grow.
    var hitSlop: CGFloat = 3
    /// Called after every layout pass, which is where divider restore is driven
    /// from — it does not depend on NSViewController appearance callbacks firing.
    var onLayout: (() -> Void)?

    /// Without this, the click that activates an inactive window is swallowed and
    /// the drag needs a second click.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    /// Optional. NSSplitView's own thin-divider colour is already adaptive
    /// (`System thinSplitViewDividerColor`); this only swaps it for the same
    /// `separatorColor` the app's own hairlines use, so every 1pt line matches.
    override var dividerColor: NSColor { .separatorColor }

    override func layout() {
        super.layout()
        onLayout?()
    }
}

// MARK: - The split controller

/// One level of the tree. Owns its own divider persistence (see `Saved`), a
/// widened divider hit region, and programmatic collapse.
final class SLSplitViewController: NSSplitViewController {
    private let axis: SplitAxis
    let storeKey: String
    private let hitSlop: CGFloat
    private let defaults: UserDefaults

    private var restored = false
    private var suppressSave = false
    private var restoreAttempts = 0
    private var restorePending = false
    private var programmaticChange = false
    private var lastPersisted: Saved?
    /// Cold-start thicknesses, in item order. nil entries are left to AppKit.
    var seeds: [CGFloat?] = []
    /// Cold-start collapse flags, in item order.
    var seedCollapsed: [Bool] = []

    init(axis: SplitAxis,
         storeKey: String,
         hitSlop: CGFloat = 3,
         defaults: UserDefaults = .standard) {
        self.axis = axis
        self.storeKey = storeKey
        self.hitSlop = hitSlop
        self.defaults = defaults
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("SLSplitViewController is code-only") }

    // MARK: View

    override func loadView() {
        let sv = SLSplitView()
        sv.isVertical = axis.isVertical
        sv.dividerStyle = .thin
        sv.hitSlop = hitSlop
        // Restore is driven from the split view's own layout pass rather than
        // NSViewController.viewDidLayout: NSSplitViewController does not override
        // viewDidLayout, and this hook fires whether or not the controller is in
        // a view-controller hierarchy.
        sv.onLayout = { [weak self] in self?.restoreIfNeeded() }
        // Documented hook: assigning `splitView` before the view loads swaps in
        // a subclass. It has to happen before super.loadView().
        splitView = sv
        super.loadView()
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(splitViewDidResize(_:)),
            name: NSSplitView.didResizeSubviewsNotification,
            object: splitView
        )
    }

    // MARK: Fat divider

    /// NSSplitViewController implements this delegate method itself
    /// (NS_REQUIRES_SUPER), so the override has to call super and then widen.
    override func splitView(_ splitView: NSSplitView,
                            effectiveRect proposedEffectiveRect: NSRect,
                            forDrawnRect drawnRect: NSRect,
                            ofDividerAt dividerIndex: Int) -> NSRect {
        var r = super.splitView(splitView,
                               effectiveRect: proposedEffectiveRect,
                               forDrawnRect: drawnRect,
                               ofDividerAt: dividerIndex)
        if splitView.isVertical {
            r.origin.x -= hitSlop
            r.size.width += hitSlop * 2
        } else {
            r.origin.y -= hitSlop
            r.size.height += hitSlop * 2
        }
        return r
    }

    // MARK: Persistence

    /// Absolute pane thicknesses in points, the same thing native
    /// `autosaveName` stores and the same thing FileZilla stores. Combined with
    /// the window's own `setFrameAutosaveName`, that reproduces the exact layout
    /// on the next launch. Fractions were tried first and are worse: with
    /// `holdingPriority` doing its job a window resize deliberately changes the
    /// ratio, so a ratio is not the thing to remember.
    private struct Saved: Codable, Equatable {
        var thicknesses: [Double]
        var collapsed: [Bool]
    }

    private var defaultsKey: String { "SplitLayout.\(storeKey)" }

    private var thickness: CGFloat {
        axis.isVertical ? splitView.bounds.width : splitView.bounds.height
    }

    private func usableThickness(_ total: CGFloat, _ n: Int) -> CGFloat {
        total - splitView.dividerThickness * CGFloat(n - 1)
    }

    private func loadSaved() -> Saved? {
        guard let data = defaults.data(forKey: defaultsKey),
              let saved = try? JSONDecoder().decode(Saved.self, from: data),
              saved.thicknesses.count == splitViewItems.count,
              saved.collapsed.count == splitViewItems.count
        else { return nil }
        return saved
    }

    private func currentThicknesses() -> [Double] {
        splitViewItems.map { item in
            let f = item.viewController.view.frame
            return Double(max(0, axis.isVertical ? f.width : f.height))
        }
    }

    /// Resolves `seeds` against the live thickness: nil entries share whatever is
    /// left over, so a seeded pane keeps its exact point size and the rest flex.
    private func seededThicknesses() -> [Double] {
        let n = splitViewItems.count
        let room = Double(usableThickness(thickness, n))
        var out = [Double](repeating: 0, count: n)
        var fixed = 0.0
        var free: [Int] = []
        for i in 0..<n {
            if i < seeds.count, let s = seeds[i] { out[i] = Double(s); fixed += Double(s) }
            else { free.append(i) }
        }
        if !free.isEmpty {
            let each = max(0, (room - fixed) / Double(free.count))
            for i in free { out[i] = each }
        }
        return out
    }

    private func restoreIfNeeded() {
        guard !restored else { return }
        let n = splitViewItems.count
        guard n > 1 else { restored = true; return }
        // A degenerate bounds means the first real layout has not happened yet.
        // Restoring into it clamps every pane to its minimum, which is the single
        // most common way "persisted dividers" appear not to work.
        guard thickness > 1 else { return }
        if let saved = loadSaved() { scheduleRestore(saved); return }
        // Nothing stored: seed the cold start, then treat it as restored. It is
        // NOT persisted -- only a real drag writes, so a user who never touches a
        // divider keeps getting the seeded default if we later change it.
        guard seeds.contains(where: { $0 != nil }) else { restored = true; return }
        let seeded = Saved(thicknesses: seededThicknesses(), collapsed: seedCollapsed)
        scheduleRestore(seeded)
    }

    /// setPosition() behaves as if the user dragged, so when the split view's own
    /// bounds changed in the same layout pass its proportional redistribution runs
    /// *after* ours and silently undoes it. Applying on the next runloop turn and
    /// then verifying is what makes the restore actually stick.
    ///
    /// `restorePending` matters: restoreIfNeeded() runs on every layout pass until
    /// the restore lands, and a nested split lays out several times while its
    /// parent settles. Without the flag each pass queued another apply and the
    /// retry budget was spent before any of them had run.
    private func scheduleRestore(_ saved: Saved) {
        guard !restorePending else { return }
        restorePending = true
        DispatchQueue.main.async { [weak self] in self?.performRestore(saved) }
    }

    /// The pane AppKit itself would grow or shrink on a resize: the LOWEST holding
    /// priority wins, and ties go to the first, matching NSSplitView's own rule.
    private func absorbingIndex() -> Int? {
        guard !splitViewItems.isEmpty else { return nil }
        var best = 0
        for (i, item) in splitViewItems.enumerated()
        where item.holdingPriority.rawValue < splitViewItems[best].holdingPriority.rawValue {
            best = i
        }
        return best
    }

    private func minThickness(_ i: Int) -> Double {
        let m = splitViewItems[i].minimumThickness
        return m == NSSplitViewItem.unspecifiedDimension ? 0 : Double(m)
    }

    /// Saved thicknesses are absolute points, so they only add up in a window the
    /// same size as the one they were saved in. Restoring into any other height left
    /// the difference to whichever pane happened to be LAST, because apply() pins the
    /// leading dividers and the trailing pane silently takes the remainder. That is
    /// how a disconnect that grew the window by 339pt handed the transfers pane the
    /// lot. Give the difference to the pane holdingPriority nominates instead, which
    /// is the same pane a live window resize would have grown.
    private func reconcile(_ saved: Saved) -> Saved {
        var t = saved.thicknesses
        let room = Double(usableThickness(thickness, splitViewItems.count))
        var delta = room - t.reduce(0, +)
        guard abs(delta) > 0.5, let absorber = absorbingIndex() else { return saved }

        let want = max(minThickness(absorber), t[absorber] + delta)
        delta -= (want - t[absorber])
        t[absorber] = want
        // Whatever the absorber could not take (its minimum got in the way) is spread
        // over the rest, so the total still matches the room actually available.
        if abs(delta) > 0.5 {
            let others = (0..<t.count).filter { $0 != absorber }
            if !others.isEmpty {
                let share = delta / Double(others.count)
                for i in others { t[i] = max(minThickness(i), t[i] + share) }
            }
        }
        return Saved(thicknesses: t, collapsed: saved.collapsed)
    }

    private func performRestore(_ saved: Saved) {
        restorePending = false
        guard !restored, thickness > 1 else { return }

        restoreAttempts += 1
        // Reconcile against the CURRENT thickness every attempt: an early pass can
        // run before the window has settled, so the room available is still moving.
        let target = reconcile(saved)
        apply(target)

        // A perfect match is impossible when the window is now smaller than the
        // saved layout needs; stop retrying instead of spinning.
        let needed = target.thicknesses.reduce(0, +)
        let room = Double(usableThickness(thickness, splitViewItems.count))
        if matches(target) || needed > room + 1 || restoreAttempts >= 5 {
            restored = true
        } else {
            // Pass the ORIGINAL saved layout, not the reconciled one, so the next
            // attempt re-reconciles against whatever the thickness is by then.
            scheduleRestore(saved)
        }
    }

    private func apply(_ saved: Saved) {
        suppressSave = true
        defer { suppressSave = false }

        // Positions first. setPosition() behaves like a drag, and a drag
        // UNCOLLAPSES the pane it touches, so assigning isCollapsed before this
        // silently threw the collapsed state away.
        let n = splitViewItems.count
        let dt = splitView.dividerThickness
        var acc: CGFloat = 0
        for i in 0..<(n - 1) {
            acc += CGFloat(saved.thicknesses[i])
            splitView.setPosition(acc + dt * CGFloat(i), ofDividerAt: i)
        }
        for (i, item) in splitViewItems.enumerated() where item.canCollapse {
            item.isCollapsed = saved.collapsed[i]
        }
        splitView.layoutSubtreeIfNeeded()
    }

    private func matches(_ saved: Saved) -> Bool {
        guard splitViewItems.map({ $0.isCollapsed }) == saved.collapsed else { return false }
        let now = currentThicknesses()
        guard now.count == saved.thicknesses.count else { return false }
        for (a, b) in zip(now, saved.thicknesses) where abs(a - b) > 1.5 { return false }
        return true
    }

    // MARK: Saving

    /// Only a real user gesture or an explicit command may change what is stored.
    /// A plain window resize must not: `holdingPriority` intentionally reshuffles
    /// thicknesses, and a restore that got clamped by a too-small window would
    /// otherwise overwrite a perfectly good saved layout with the clamped values.
    /// During a divider drag AppKit is inside its own mouse-tracking loop, so
    /// NSApp.currentEvent is a mouse event — that is the signal.
    private var isUserGesture: Bool {
        switch NSApp?.currentEvent?.type {
        case .leftMouseDown, .leftMouseDragged, .leftMouseUp: return true
        default: return false
        }
    }

    @objc private func splitViewDidResize(_ note: Notification) {
        guard restored, !suppressSave else { return }
        guard programmaticChange || isUserGesture else { return }
        persist()
    }

    private func persist() {
        guard splitViewItems.count > 1, thickness > 1 else { return }
        let thicknesses = currentThicknesses()
        let sum = thicknesses.reduce(0, +)
        let room = Double(usableThickness(thickness, splitViewItems.count))
        // Two-sided sanity check. Mid-resize the split view's own bounds update
        // before its subviews' frames do, so one pass can report thicknesses that
        // sum to far more or far less than the space available.
        guard abs(sum - room) < 2 else { return }

        let saved = Saved(thicknesses: thicknesses, collapsed: splitViewItems.map { $0.isCollapsed })
        guard saved != lastPersisted else { return }
        lastPersisted = saved
        if let data = try? JSONEncoder().encode(saved) {
            defaults.set(data, forKey: defaultsKey)
        }
    }

    /// Wraps a change that should be persisted even though no mouse is down.
    private func asProgrammaticChange(_ body: () -> Void) {
        programmaticChange = true
        body()
        splitView.layoutSubtreeIfNeeded()
        persist()
        programmaticChange = false
    }

    /// Moves a divider and remembers it, for a "reset layout" command or a
    /// keyboard shortcut.
    func setDividerPosition(_ position: CGFloat, at index: Int) {
        asProgrammaticChange { splitView.setPosition(position, ofDividerAt: index) }
    }

    // MARK: Programmatic collapse

    func setCollapsed(_ collapsed: Bool, at index: Int, animated: Bool = true) {
        guard splitViewItems.indices.contains(index) else { return }
        let item = splitViewItems[index]
        asProgrammaticChange {
            if animated {
                (item.animator() as NSSplitViewItem).isCollapsed = collapsed
            } else {
                item.isCollapsed = collapsed
            }
        }
    }

    func toggleCollapsed(at index: Int, animated: Bool = true) {
        guard splitViewItems.indices.contains(index) else { return }
        setCollapsed(!splitViewItems[index].isCollapsed, at: index, animated: animated)
    }
}

// MARK: - Leaf controller

/// Accepts the first click so a pane is usable the moment the window activates,
/// matching what WindowDragArea already does for the top bar.
final class SLHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

final class SLPaneController: NSViewController {
    let host: SLHostingView<AnyView>

    init(_ root: AnyView) {
        host = SLHostingView(rootView: root)
        super.init(nibName: nil, bundle: nil)
    }

    required init?(coder: NSCoder) { fatalError("SLPaneController is code-only") }

    override func loadView() {
        // The split view is inside the window's full-size content view. Opting
        // the leaves out of safe-area participation keeps a pane from ever
        // acquiring a phantom top inset from the hidden titlebar.
        if #available(macOS 13.3, *) { host.safeAreaRegions = [] }
        host.translatesAutoresizingMaskIntoConstraints = true
        host.autoresizingMask = [.width, .height]
        view = host
    }
}

// MARK: - Builder

enum SplitBuilder {
    static func controller(for node: SplitNode, hitSlop: CGFloat) -> NSViewController {
        switch node {
        case .leaf(let v):
            return SLPaneController(v)

        case .split(let axis, let key, let children):
            let vc = SLSplitViewController(axis: axis, storeKey: key, hitSlop: hitSlop)
            for child in children {
                let childVC = controller(for: child.node, hitSlop: hitSlop)
                let item = NSSplitViewItem(viewController: childVC)
                apply(child.spec, to: item)
                vc.addSplitViewItem(item)
                vc.seeds.append(child.spec.seedThickness)
                vc.seedCollapsed.append(child.spec.startsCollapsed)
            }
            return vc
        }
    }

    private static func apply(_ spec: SplitPaneSpec, to item: NSSplitViewItem) {
        item.minimumThickness = spec.minThickness ?? NSSplitViewItem.unspecifiedDimension
        item.maximumThickness = spec.maxThickness ?? NSSplitViewItem.unspecifiedDimension
        item.preferredThicknessFraction = spec.preferredFraction ?? NSSplitViewItem.unspecifiedDimension
        item.automaticMaximumThickness = spec.automaticMaxThickness ?? NSSplitViewItem.unspecifiedDimension
        item.canCollapse = spec.canCollapse
        item.holdingPriority = spec.holdingPriority
        if spec.startsCollapsed { item.isCollapsed = true }
    }

    static func leaves(of node: SplitNode, into out: inout [AnyView]) {
        switch node {
        case .leaf(let v):
            out.append(v)
        case .split(_, _, let children):
            for c in children { leaves(of: c.node, into: &out) }
        }
    }

    static func hostingViews(of vc: NSViewController, into out: inout [SLHostingView<AnyView>]) {
        if let pane = vc as? SLPaneController {
            out.append(pane.host)
            return
        }
        if let split = vc as? SLSplitViewController {
            for item in split.splitViewItems { hostingViews(of: item.viewController, into: &out) }
        }
    }
}

// MARK: - SwiftUI entry point

/// Held by the SwiftUI view that owns the tree, so a menu item or a toolbar
/// button can collapse a pane. The tree is AppKit, so this is the bridge back.
final class SplitTreeHandle: ObservableObject {
    fileprivate weak var root: NSViewController?

    func split(_ key: String) -> SLSplitViewController? {
        SplitTree.split(named: key, in: root)
    }

    func isCollapsed(_ key: String, pane: Int) -> Bool {
        guard let s = split(key), s.splitViewItems.indices.contains(pane) else { return false }
        return s.splitViewItems[pane].isCollapsed
    }

    func toggle(_ key: String, pane: Int) {
        split(key)?.toggleCollapsed(at: pane)
        objectWillChange.send()
    }

    /// Forgets every stored divider position under these keys. Pair it with a
    /// "Reset Layout" menu item; it takes effect on the next launch.
    static func forgetLayout(keys: [String], defaults: UserDefaults = .standard) {
        for k in keys { defaults.removeObject(forKey: "SplitLayout.\(k)") }
    }
}

/// Drop this anywhere in a SwiftUI tree. The AppKit split hierarchy is built
/// once; later passes only push fresh root views into the leaves, so pane state
/// and scroll position survive.
struct SplitTree: NSViewRepresentable {
    let root: SplitNode
    var hitSlop: CGFloat = 3
    var handle: SplitTreeHandle? = nil

    final class Coordinator {
        var controller: NSViewController?
        var hosts: [SLHostingView<AnyView>] = []
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let container = NSView()
        let vc = SplitBuilder.controller(for: root, hitSlop: hitSlop)
        container.addSubview(vc.view)
        vc.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            vc.view.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            vc.view.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            vc.view.topAnchor.constraint(equalTo: container.topAnchor),
            vc.view.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        context.coordinator.controller = vc
        SplitBuilder.hostingViews(of: vc, into: &context.coordinator.hosts)
        handle?.root = vc
        return container
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        var fresh: [AnyView] = []
        SplitBuilder.leaves(of: root, into: &fresh)
        // Same count and same underlying concrete view types every pass, so
        // AnyView does not invalidate the panes' own @State.
        guard fresh.count == context.coordinator.hosts.count else { return }
        for (i, host) in context.coordinator.hosts.enumerated() {
            host.rootView = fresh[i]
        }
    }

    /// Reach the controller for a named split, to collapse a pane from a button.
    static func split(named key: String, in vc: NSViewController?) -> SLSplitViewController? {
        guard let s = vc as? SLSplitViewController else { return nil }
        if s.storeKey == key { return s }
        for item in s.splitViewItems {
            if let hit = split(named: key, in: item.viewController) { return hit }
        }
        return nil
    }
}
