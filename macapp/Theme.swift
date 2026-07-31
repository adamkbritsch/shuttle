import AppKit
import SwiftUI

/// Chrome constants and the small shared controls.
///
/// One place for the chrome metrics so the whole window stays internally
/// consistent: same bar height, same pill geometry, same opacities throughout.
enum Theme {
    /// The content row inside is centred on the MEASURED traffic-light position, not
    /// on this height, so the alignment holds even though the bar is a fixed size.
    static let barHeight: CGFloat = 44

    /// Distance from the window's top edge to the CENTRE of the traffic lights,
    /// measured from the real buttons at launch rather than assumed.
    ///
    /// Hardcoding it is how the bar ended up with its content sitting ~15pt BELOW the
    /// close button: `safeAreaRegions = []` puts SwiftUI's origin at the true window
    /// top, but AppKit still places the buttons at its own offset, and the two do not
    /// agree. The seed is a sane fallback for the frame before measurement lands.
    static var trafficLightCenterY: CGFloat = 13

    /// The titlebar is hidden and the content is full-size, so the traffic lights sit
    /// over our own bar — this reserves their space, and then some.
    ///
    /// It clears the three buttons AND leaves a real gap after them. The lights end
    /// around 67pt, so this is comfortably clear of the green one while still
    /// reading as part of the same row. Note the `HStack` spacing lands the first
    /// item 10pt further right again.
    ///
    /// It was 115 while the bar led with the word rather than the mark: a wordmark
    /// starting that close to the lights read as crowded, where a 17pt icon does
    /// not.
    static let trafficLightGutter: CGFloat = 96

    static let hairline = Color.primary.opacity(0.09)
    static let pillFill = Color.primary.opacity(0.06)
    static let pillFillHover = Color.primary.opacity(0.11)

    // MARK: - FileZilla palette
    //
    // Sampled from FileZilla 3.69.6 running on this machine (screen capture, dominant
    // colour per region) rather than eyeballed:
    //   list background #0D0D0D · column header #0E0E0E · queue pane #1E1E1E
    //   tab strip #1F1F1F · path field #373534 · row text #828282 · folder #F8D24B
    //
    // Taken as DYNAMIC colours, not literals. FileZilla's values are what its dark
    // appearance resolves to; hardcoding them would leave the app unreadable in light
    // mode, and the rest of this app is deliberately appearance-adaptive. The dark
    // side is FileZilla's measured colour; the light side is its counterpart.

    static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        })
    }

    private static func hex(_ v: UInt32) -> NSColor {
        NSColor(srgbRed: Double((v >> 16) & 0xFF) / 255.0,
                green: Double((v >> 8) & 0xFF) / 255.0,
                blue: Double(v & 0xFF) / 255.0, alpha: 1)
    }

    /// The file lists and trees: near-black in dark, plain white in light, exactly as
    /// FileZilla resolves in each appearance.
    static let listFill = dynamic(dark: hex(0x0D0D0D), light: hex(0xFFFFFF))
    /// The chrome around the lists — path bars, status lines, the queue pane.
    static let cardFill = dynamic(dark: hex(0x1E1E1E), light: hex(0xF2F2F2))
    /// The column-header strip.
    static let headerFill = dynamic(dark: hex(0x0E0E0E), light: hex(0xF7F7F7))
    /// FileZilla's gold folder, its single most recognisable visual signature.
    /// Deepened in light mode so it still reads against white.
    static let folderGold = dynamic(dark: hex(0xF8D24B), light: hex(0xD79A17))
    /// The plain document icon beside a file.
    static let fileGrey = dynamic(dark: hex(0x9E9D9D), light: hex(0x7A7A7A))

    // MARK: - Accent, derived from the app icon
    //
    // Read off the icon's own values rather than picked by eye: its tile runs
    // #1C3D5E (hue 210.2, S 0.70, V 0.37) into an indigo #0A0B28 (hue 238.2), and
    // the capsule is a pale #C7D9F5.
    //
    // Those literal colours are unusable as UI accents -- the tile is far too dark
    // to register as an interactive tint on a near-black list, and the capsule is
    // too pale to read on white. So the HUE is what carries over; only saturation
    // and value are retuned, per appearance. Same family as the icon, legible in
    // both modes.
    static let accent = dynamic(dark: hex(0x5397DB), light: hex(0x1E5894))
    /// Filled accent backgrounds: the selected tree row, the status pill.
    static let accentSoft = dynamic(dark: hex(0x22374C), light: hex(0xBDD7F2))
    /// The icon's second stop. Mirrors the gradient: blue for work in flight,
    /// indigo for work merely waiting.
    static let accentIndigo = dynamic(dark: hex(0x6E72C4), light: hex(0x4A4E96))

    // 700, not 620: six stacked regions (bar 44 + tree 60 + list 120 + status 20 +
    // send bar 46 + queue 90 + dividers) only fit in 620 by pinning every one of
    // them to its minimum.
    static let minWindow = NSSize(width: 940, height: 700)
    static let defaultWindow = NSSize(width: 1240, height: 820)

    // Divider geometry. These are SEEDS for a first launch, not frames — every
    // divider's real position is restored from UserDefaults after that.
    static let queueSeed: CGFloat = 224
    static let queueMin: CGFloat = 90
    static let treeSeed: CGFloat = 150
    static let treeMin: CGFloat = 60
    static let listMin: CGFloat = 120
    static let browseMin: CGFloat = 220
    static let paneMinWidth: CGFloat = 330
    static let statusLineHeight: CGFloat = 20
    /// A 1pt hairline is impossible to grab, so the divider claims 3pt either side.
    static let dividerHitSlop: CGFloat = 3

    /// Holding priority decides which pane absorbs a window resize: the LOWER
    /// priority grows. Measured, and the opposite of what reads naturally.
    ///   equal (250/250) -> gravity 0.5, panes share growth
    ///   tree 251 / list 250 -> the list absorbs, the tree holds its height
    ///   browse 250 / queue 260 -> browse absorbs, the queue holds 224
    enum Hold {
        static let absorbs = NSLayoutConstraint.Priority(250)
        static let holds = NSLayoutConstraint.Priority(251)
        static let holdsFirmly = NSLayoutConstraint.Priority(260)
    }

    /// The capsule from the app icon, flat and rotated, loaded as a TEMPLATE image.
    /// Template means macOS discards its colour and paints it with whatever
    /// foreground style the view sets, which is the whole point here: the mark has
    /// to sit in the chrome at the same weight as the other controls rather than
    /// arriving as a bright blue sticker.
    static let markTemplate: NSImage? = {
        guard let url = Bundle.main.url(forResource: "MarkTemplate", withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        img.isTemplate = true
        return img
    }()

    /// What the top bar paints instead of a live-blur material.
    ///
    /// Not guessed: the dark value is what `.headerView` actually resolved to over
    /// this window, sampled from a screenshot of the previous build. The bar is
    /// therefore the same colour it always was, minus the per-frame blend.
    static let barFill = dynamic(dark: hex(0x1F1F20), light: hex(0xECECEC))

    static let splitKeys = ["main.rows", "main.browse", "source.split", "dest.split"]
}

/// Status colors, semantic rather than literal so both appearances read correctly.
enum StatusTint {
    case good, busy, warn, bad, idle

    var color: Color {
        switch self {
        case .good: return Color(nsColor: .systemGreen)
        case .busy: return Theme.accent
        case .warn: return Color(nsColor: .systemOrange)
        case .bad:  return Color(nsColor: .systemRed)
        case .idle: return Color.secondary
        }
    }
}

/// Native blurred material.
///
/// Still here for anything that genuinely sits over changing content, but the top
/// bar no longer uses it: NSVisualEffectView blends live, every frame the window
/// composites, and the bar sits on an opaque window background where there is
/// nothing behind it to show through. That is continuous GPU work for a result
/// indistinguishable from a flat fill.
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .headerView

    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = material
        v.blendingMode = .withinWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ v: NSVisualEffectView, context: Context) {
        v.material = material
    }
}

/// Makes an area behave like titlebar: drag to move, double-click to zoom.
struct WindowDragArea: NSViewRepresentable {
    final class Dragging: NSView {
        override var mouseDownCanMoveWindow: Bool { true }
        // Without this, the click that activates an inactive window is swallowed.
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
        override func mouseDown(with event: NSEvent) {
            if event.clickCount == 2 { window?.performZoom(nil) }
            super.mouseDown(with: event)
        }
    }

    func makeNSView(context: Context) -> NSView { Dragging() }
    func updateNSView(_ v: NSView, context: Context) {}
}

/// Bezel-less icon button: transparent until hover.
struct ChromeButton: View {
    let symbol: String
    let help: String
    var enabled: Bool = true
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12.5, weight: .medium))
                .foregroundStyle(Color.primary.opacity(enabled ? 0.72 : 0.28))
                .frame(width: 26, height: 22)
                .background(
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(hovering && enabled ? Theme.pillFillHover : .clear)
                )
                .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .onHover { hovering = $0 }
        .help(help)
    }
}

/// 1024-based sizes, matching render.py's `human()` on the NAS, so a number in this
/// app and the same number in an FTP listing read identically.
func humanBytes(_ n: Int64) -> String {
    let units = ["B", "K", "M", "G", "T"]
    var v = Double(n)
    var i = 0
    while v >= 1024 && i < units.count - 1 { v /= 1024; i += 1 }
    return i == 0 ? "\(Int(v))B" : String(format: "%.1f%@", v, units[i])
}

func humanETA(_ seconds: Int) -> String {
    if seconds <= 0 { return "--" }
    if seconds < 60 { return "\(seconds)s" }
    let m = seconds / 60, s = seconds % 60
    if m < 60 { return s > 0 ? "\(m)m\(s)s" : "\(m)m" }
    let h = m / 60
    return "\(h)h\(m % 60)m"
}

// Menu commands are posted as notifications so the AppKit menu bar and the SwiftUI
// tree stay decoupled — neither has to hold a reference to the other.
extension Notification.Name {
    static let shuttleSettings = Notification.Name("shuttle.settings")
    static let shuttleRefresh = Notification.Name("shuttle.refresh")
    static let shuttleSend = Notification.Name("shuttle.send")
    static let shuttleUp = Notification.Name("shuttle.up")
    static let shuttleCancel = Notification.Name("shuttle.cancel")
    // View menu, mirroring FileZilla's pane toggles.
    static let shuttleToggleSourceTree = Notification.Name("shuttle.toggleSourceTree")
    static let shuttleToggleDestTree = Notification.Name("shuttle.toggleDestTree")
    static let shuttleToggleQueue = Notification.Name("shuttle.toggleQueue")
    static let shuttleResetLayout = Notification.Name("shuttle.resetLayout")
}
