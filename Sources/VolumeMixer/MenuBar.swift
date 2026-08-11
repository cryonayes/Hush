import AppKit
import SwiftUI

/// SwiftUI's `MenuBarExtra` routes every click to the same place, so the status
/// item is plain AppKit: left click opens the sliders, right click opens the menu.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let model = MixerModel()
    private var statusItem: NSStatusItem!

    private lazy var popover: NSPopover = {
        let hosting = NSHostingController(rootView: MixerView(model: model))
        // Without this the hosting view reports no intrinsic size, so the popover
        // anchors off a zero rect and lands somewhere arbitrary on screen.
        hosting.sizingOptions = [.preferredContentSize]

        let popover = NSPopover()
        popover.behavior = .transient
        popover.contentViewController = hosting
        return popover
    }()

    private lazy var menu: NSMenu = {
        let menu = NSMenu()
        let login = NSMenuItem(title: "Launch at Login",
                               action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Volume Mixer",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
        return menu
    }()

    func applicationDidFinishLaunching(_ notification: Notification) {
        Settings.enableLaunchAtLoginOnce()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        // Vertical faders match the app icon and read as a mixer, not as "settings".
        statusItem.button?.image = NSImage(systemSymbolName: "slider.vertical.3",
                                           accessibilityDescription: "Volume Mixer")
        statusItem.button?.target = self
        statusItem.button?.action = #selector(statusItemClicked)
        statusItem.button?.sendAction(on: [.leftMouseUp, .rightMouseUp])
    }

    @objc private func statusItemClicked() {
        if NSApp.currentEvent?.type == .rightMouseUp {
            menu.items.first?.state = Settings.launchAtLogin ? .on : .off
            // Attaching the menu and re-clicking is how AppKit pops a menu from a
            // status item that otherwise handles its own clicks.
            statusItem.menu = menu
            statusItem.button?.performClick(nil)
            statusItem.menu = nil
        } else if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            model.refresh()   // don't show a list up to 3s stale
            // .minY is "below" in the button's unflipped coordinates — .maxY aims
            // the popover up into the menu bar.
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            NSApp.activate(ignoringOtherApps: true)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    @objc private func toggleLaunchAtLogin() {
        Settings.launchAtLogin.toggle()
    }
}
