import AppKit
import Combine
import SwiftUI
import VeltoCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, NSWindowDelegate {
    let monitor = Monitor()
    private let router = MenuRouter()
    private let notifier = Notifier()
    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var mainWindow: NSWindow?
    private let navigation = MainNavigation()
    private var subscriptions = Set<AnyCancellable>()
    private var clock: Timer?
    private let network = NetworkGate()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = Theme.menuBarColorImage
        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.target = self
        statusItem.button?.action = #selector(togglePopover)

        let actions = MenuActions(
            refresh: { [weak self] in self?.monitor.refresh() },
            settings: { [weak self] add in self?.popover.performClose(nil); self?.showWindow(.settings, addSource: add) },
            open: { [weak self] url in self?.popover.performClose(nil); NSWorkspace.shared.open(url) },
            quit: { NSApp.terminate(nil) })
        // A system popover: the arrow, the material (Liquid Glass on macOS 26), Esc and outside-click
        // dismissal all come from AppKit, so it behaves like every other menu-bar extra.
        let hosting = NSHostingController(rootView: MenuView(monitor: monitor, router: router, actions: actions))
        hosting.sizingOptions = .preferredContentSize
        popover.contentViewController = hosting
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self

        monitor.$snapshot.sink { [weak self] snapshot in self?.updateStatusItem(snapshot) }.store(in: &subscriptions)
        monitor.onNewAlerts = { [weak self] alerts in self?.notifier.post(alerts) }
        monitor.onResolvedAlerts = { [weak self] alerts in self?.notifier.postResolved(alerts) }
        notifier.onOpen = { [weak self] id in self?.showPopover(on: .source(id)) }
        notifier.onSnooze = { [weak self] sourceID, alertID, name, until in
            guard let self else { return }
            let alert = monitor.snapshot.sources.first { $0.id == sourceID }?.alerts.first { $0.id == alertID }
                ?? Alert(id: alertID, name: name, severity: .none)
            monitor.snooze(alert, in: sourceID, scope: .alert, until: until)
        }
        notifier.start()
        // Staleness depends on the clock, not only on new data, so the title is re-evaluated regularly.
        clock = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            Task { @MainActor in self.map { $0.updateStatusItem($0.monitor.snapshot) } }
        }
        DistributedNotificationCenter.default().addObserver(forName: Store.refreshNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.monitor.refresh() }
        }
        // Waking from sleep: the cached state is old, check now instead of waiting for the timer.
        NSWorkspace.shared.notificationCenter.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.monitor.refresh() }
        }

        network.onChange = { [weak self] in self?.monitor.networkChanged() }
        network.start()
        monitor.start()
        if monitor.config.sources.isEmpty || !monitor.importNotes.isEmpty || monitor.configError != nil {
            let add = monitor.config.sources.isEmpty && monitor.configError == nil
            showWindow(add ? .sources : .settings, addSource: add)
        }
    }

    /// Opening the app from Finder, Spotlight or the Dock shows the main window.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showWindow(nil, addSource: false)
        return false
    }

    @objc private func togglePopover() {
        if popover.isShown { popover.performClose(nil) } else { showPopover(on: .root) }
    }

    private func showPopover(on route: MenuRoute) {
        guard let button = statusItem.button else { return }
        router.go(route, animated: popover.isShown)
        guard !popover.isShown else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        // Keyboard shortcuts (⌘R, ⌘, and ←) need the popover to be key.
        NSApp.activate(ignoringOtherApps: true)
        popover.contentViewController?.view.window?.makeKey()
        button.highlight(true)
    }

    @objc private func openSettings() { showWindow(.settings, addSource: false) }
    @objc private func checkNow() { monitor.refresh() }

    func popoverDidClose(_ notification: Notification) {
        statusItem.button?.highlight(false)
        router.go(.root, animated: false)
    }

    private func updateStatusItem(_ snapshot: Snapshot) {
        let status = Status(snapshot: snapshot)
        guard let button = statusItem.button else { return }
        let text = status.compact
        // Digits stay monospaced so the item doesn't jitter as the count changes.
        button.attributedTitle = NSAttributedString(string: text.isEmpty ? "" : " " + text, attributes: [
            .font: NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium),
            .baselineOffset: 0.5,
        ])
        button.toolTip = "Velto · \(status.headline)\n\(status.detail())"
        button.setAccessibilityLabel("Velto, \(status.headline)")
        // Stale or unreachable dims the mark: the number shown is not current.
        button.appearsDisabled = status.health == .stale || status.health == .offline
    }

    /// Shows the main window, on `pane` if given. While it is open Velto is a regular app with a Dock
    /// icon and menu bar, like any windowed Mac app; closing it returns Velto to the menu bar only.
    func showWindow(_ pane: Pane?, addSource: Bool) {
        if mainWindow == nil {
            let actions = MainWindowActions(
                showMenu: { [weak self] in self?.showPopover(on: .root) },
                open: { NSWorkspace.shared.open($0) })
            let hosting = NSHostingController(rootView: MainView(monitor: monitor, navigation: navigation, notifier: notifier, actions: actions))
            let window = NSWindow(contentViewController: hosting)
            // Hidden in the glass title bar, but still what the Window menu and Mission Control show.
            navigation.$pane.sink { [weak window] pane in window?.title = (pane ?? .overview).title }.store(in: &subscriptions)
            Glass.configure(window)
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(NSSize(width: 1080, height: 760))
            window.center()
            window.setFrameAutosaveName("VeltoMain")
            mainWindow = window
        }
        if let pane { navigation.pane = pane }
        if addSource { navigation.addSource(in: monitor) }
        NSApp.setActivationPolicy(.regular)
        mainWindow?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func windowWillClose(_ notification: Notification) {
        guard (notification.object as? NSWindow) === mainWindow else { return }
        NSApp.setActivationPolicy(.accessory)
    }

    /// A menu-bar app shows no menu bar, but its windows still get ⌘Q, ⌘W and the edit shortcuts only
    /// through main-menu key equivalents. Without this, pasting a URL into Settings does nothing.
    private func installMainMenu() {
        let app = NSMenu(title: "Velto")
        app.addItem(withTitle: "About Velto", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        app.addItem(.separator())
        app.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        app.addItem(withTitle: "Check Now", action: #selector(checkNow), keyEquivalent: "r").target = self
        app.addItem(.separator())
        app.addItem(withTitle: "Hide Velto", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        app.addItem(withTitle: "Quit Velto", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        NSApp.windowsMenu = window
        let main = NSMenu()
        for submenu in [app, edit, window] {
            let item = NSMenuItem()
            item.submenu = submenu
            main.addItem(item)
        }
        NSApp.mainMenu = main
    }
}
