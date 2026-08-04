import AppKit
import SwiftUI

// Top-level code, so this file must be named main.swift. No @main / SwiftUI App:
// both sibling apps drive AppKit directly, which keeps full control of the window
// and the menu bar.
let app = NSApplication.shared
let appDelegate = AppDelegate()
app.delegate = appDelegate
app.setActivationPolicy(.regular)
app.run()

final class AppDelegate: NSObject, NSApplicationDelegate {
    static let frameAutosaveName = "ShuttleMainWindow"
    var window: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Lets the token be provisioned once via the environment instead of ever
        // being written into the binary. Also primes the Keychain cache, which is the
        // whole mitigation for the multi-second first SecItemCopyMatching after an
        // ad-hoc rebuild changes the code identity.
        TokenStore.seedFromEnvironmentIfEmpty()
        TokenStore.prime()
        buildMenu()

        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Theme.defaultWindow),
            styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        window.title = "Shuttle"
        // The top bar is drawn in SwiftUI, so the real titlebar only supplies the
        // traffic lights and the drag/zoom behaviour.
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.minSize = Theme.minWindow
        window.tabbingMode = .disallowed
        // An empty unified toolbar exists purely for its geometry: it gives the
        // window a taller titlebar and moves the traffic lights down with it, so the
        // top bar's content is not jammed against the window edge. Nothing is ever
        // added to it, and the baseline separator would draw a second rule under our
        // own hairline.
        let toolbar = NSToolbar(identifier: "ShuttleChrome")
        toolbar.showsBaselineSeparator = false
        window.toolbar = toolbar
        // .unifiedCompact, not .unified: both move the traffic lights off the window
        // edge, but .unified gives a ~52pt titlebar and made the top bar far taller
        // than it needs to be.
        window.toolbarStyle = .unifiedCompact
        // Measure where AppKit actually put the traffic lights, so the top bar lines
        // its content up with them instead of guessing. This MUST happen after the
        // toolbar is attached and laid out -- the toolbar is what makes the titlebar
        // taller, and measuring first reads the old, higher position and leaves the
        // bar's content floating above the buttons. NSView is bottom-left origin,
        // hence height - midY for a distance from the top.
        window.layoutIfNeeded()
        if let close = window.standardWindowButton(.closeButton),
           let frameView = close.superview {
            let fromTop = frameView.bounds.height - close.frame.midY
            if fromTop > 4, fromTop < 60 { Theme.trafficLightCenterY = fromTop }
        }

        let host = NSHostingView(rootView: RootView())
        // Without this the hidden titlebar's safe-area inset is applied to the root,
        // leaving a ~28pt strip of bare window above our 44pt bar with the traffic
        // lights floating in it -- and Theme.trafficLightGutter then reserves
        // horizontal space for nothing. Measured, not guessed.
        host.safeAreaRegions = []
        window.contentView = host

        window.setFrameAutosaveName(Self.frameAutosaveName)
        // setFrameAutosaveName alone leaves a fresh install at the origin; probing the
        // autosave key is how we tell "no saved frame" from "saved at 0,0".
        if UserDefaults.standard.string(forKey: "NSWindow Frame \(Self.frameAutosaveName)") == nil {
            window.center()
        }

        window.delegate = self
        window.makeKeyAndOrderFront(nil)
        clampToScreen(window)
        self.window = window
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Guards against re-entering the clamp from the resize it performs itself.
    private var clamping = false

    /// Refuses any frame taller or wider than the display, and drags a window that
    /// has ended up off the bottom back on screen.
    ///
    /// macOS window tiling keeps an "untiled" frame to restore when a window leaves
    /// its tile, and Shuttle's had grown to 865x1668 -- far past this 1084pt screen.
    /// Losing the relay perturbs the window enough to untile it, so it snapped to
    /// that stored size: measured 865x1014 -> 865x1353 with the origin at y=-269,
    /// i.e. hanging hundreds of points below the display. Nothing in the app asked
    /// for that size, so the app declines it. Cheap, and it also covers a saved
    /// frame from a larger display.
    fileprivate func clampToScreen(_ window: NSWindow) {
        guard !clamping, let vis = (window.screen ?? NSScreen.main)?.visibleFrame else { return }
        let old = window.frame
        var f = old
        f.size.height = min(f.size.height, vis.height)
        f.size.width  = min(f.size.width,  vis.width)
        f.origin.y = max(vis.minY, min(f.origin.y, vis.maxY - f.size.height))
        f.origin.x = max(vis.minX, min(f.origin.x, vis.maxX - f.size.width))
        guard abs(f.size.height - old.size.height) > 1 || abs(f.size.width - old.size.width) > 1
           || abs(f.origin.y - old.origin.y) > 1 || abs(f.origin.x - old.origin.x) > 1 else { return }
        clamping = true
        window.setFrame(f, display: true)
        clamping = false
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }
    func applicationSupportsSecureRestorableState(_ app: NSApplication) -> Bool { true }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { window?.makeKeyAndOrderFront(nil) }
        return true
    }

    // MARK: - Menu

    private func buildMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Shuttle",
                        action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Relay Settings…", action: #selector(openSettings), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Shuttle", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Shuttle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        // Edit — required for ⌘C/⌘V. Without it, pasting the token from a password
        // manager into Settings silently does nothing.
        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        edit.addItem(.separator())
        // Find lives in Edit by macOS convention. One plain item, not a Find
        // submenu: Find Next/Previous would advertise behaviour that does not exist.
        let find = NSMenuItem(title: "Find on the NAS…", action: #selector(findOnNAS),
                              keyEquivalent: "f")
        find.target = self
        edit.addItem(find)
        editItem.submenu = edit
        main.addItem(editItem)

        let transferItem = NSMenuItem()
        let transfer = NSMenu(title: "Transfer")
        for (title, key, mods, sel) in [
            ("Send to NAS", "\r", NSEvent.ModifierFlags.command, #selector(sendToNAS)),
            ("Enclosing Folder", NSString(format: "%C", 0xF700) as String, [.command], #selector(goUp)),
            ("Refresh", "r", [.command], #selector(refresh)),
            ("Stop Transfer", String(UnicodeScalar(NSDeleteCharacter)!), [.command], #selector(stopTransfer)),
        ] as [(String, String, NSEvent.ModifierFlags, Selector)] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: key)
            mi.keyEquivalentModifierMask = mods
            mi.target = self
            transfer.addItem(mi)
        }
        transferItem.submenu = transfer
        main.addItem(transferItem)

        let viewItem = NSMenuItem()
        let view = NSMenu(title: "View")
        for (title, sel) in [("Source Directory Tree", #selector(toggleSourceTree)),
                             ("Destination Directory Tree", #selector(toggleDestTree)),
                             ("Transfer Queue", #selector(toggleQueue))] as [(String, Selector)] {
            let mi = NSMenuItem(title: title, action: sel, keyEquivalent: "")
            mi.target = self
            view.addItem(mi)
        }
        view.addItem(.separator())
        let reset = NSMenuItem(title: "Reset Layout", action: #selector(resetLayout), keyEquivalent: "")
        reset.target = self
        view.addItem(reset)
        viewItem.submenu = view
        main.addItem(viewItem)

        let windowItem = NSMenuItem()
        let win = NSMenu(title: "Window")
        win.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        win.addItem(withTitle: "Zoom", action: #selector(NSWindow.performZoom(_:)), keyEquivalent: "")
        windowItem.submenu = win
        main.addItem(windowItem)
        NSApp.windowsMenu = win

        NSApp.mainMenu = main
    }

    /// AppKit asks before drawing each item. Without this every custom item is
    /// permanently enabled, which is how ⌘⌫ stayed black with nothing transferring
    /// and ⌘↩ stayed black with nothing selected.
    ///
    /// The View-menu toggles and Reset Layout are deliberately absent: they are
    /// always meaningful, so falling through to `true` is correct for them.
    /// `assumeIsolated` rather than marking this @MainActor: menu validation is an
    /// informal AppKit protocol, and AppKit only ever calls it on the main thread.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        MainActor.assumeIsolated {
            switch item.action {
            case #selector(sendToNAS):    return MenuState.shared.flags.canSend
            case #selector(goUp):         return MenuState.shared.flags.canGoUp
            case #selector(refresh):      return MenuState.shared.flags.isLive
        // Same rule as Refresh: searching an unreachable relay is pointless. Note
        // the `default: return true` below means a forgotten case ships permanently
        // enabled, which is exactly the bug this whole method was added to fix.
        case #selector(findOnNAS):    return MenuState.shared.flags.isLive
            case #selector(stopTransfer): return MenuState.shared.flags.hasSelectedTransfer
            default:                      return true
            }
        }
    }

    // Menu commands are posted as notifications so the AppKit menu bar and the
    // SwiftUI tree stay decoupled.
    @objc private func openSettings() { NotificationCenter.default.post(name: .shuttleSettings, object: nil) }
    @objc func refresh() { NotificationCenter.default.post(name: .shuttleRefresh, object: nil) }
    @objc func findOnNAS() { NotificationCenter.default.post(name: .shuttleFind, object: nil) }
    @objc func sendToNAS() { NotificationCenter.default.post(name: .shuttleSend, object: nil) }
    @objc func goUp() { NotificationCenter.default.post(name: .shuttleUp, object: nil) }
    @objc func stopTransfer() { NotificationCenter.default.post(name: .shuttleCancel, object: nil) }
    @objc private func toggleSourceTree() { NotificationCenter.default.post(name: .shuttleToggleSourceTree, object: nil) }
    @objc private func toggleDestTree() { NotificationCenter.default.post(name: .shuttleToggleDestTree, object: nil) }
    @objc private func toggleQueue() { NotificationCenter.default.post(name: .shuttleToggleQueue, object: nil) }
    @objc private func resetLayout() { NotificationCenter.default.post(name: .shuttleResetLayout, object: nil) }
}

extension AppDelegate: NSWindowDelegate {
    // didResize, not willResize: willResize only sees user-driven drags, and the
    // frame change that matters here is macOS restoring an untiled frame
    // programmatically, which never asks.
    func windowDidResize(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        clampToScreen(w)
    }

    func windowDidChangeScreen(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        clampToScreen(w)
    }
}

