import AppKit
import ServiceManagement
import WebKit

@main
final class AppDelegate: NSObject, NSApplicationDelegate, NSPopoverDelegate, WKScriptMessageHandler, WKNavigationDelegate {
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        app.run()
    }

    private var statusItem: NSStatusItem!
    private let popover = NSPopover()
    private var webView: WKWebView!
    private var viewers: [String: NativeViewerController] = [:]
    private var pageLoaded = false
    private let server = ViewerServer.shared
    private var lastRemote = 0

    private static let popoverSizes: [String: NSSize] = [
        "small": NSSize(width: 640, height: 460),
        "medium": NSSize(width: 860, height: 600),
        "large": NSSize(width: 1180, height: 780),
    ]

    func applicationDidFinishLaunching(_ notification: Notification) {
        if !NDILib.isReady {
            let alert = NSAlert()
            alert.messageText = "NDI runtime unavailable"
            alert.informativeText = "libndi failed to initialize. Check that the NDI SDK is installed."
            alert.runModal()
        }
        do {
            try server.start()
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't start the viewer server"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = NSImage(systemSymbolName: "rectangle.grid.2x2", accessibilityDescription: "NDI-Viewer")
            button.image?.isTemplate = true
            button.target = self
            button.action = #selector(statusClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.toolTip = "NDI-Viewer"
        }
        server.onPresenceChange = { [weak self] active, remote in
            self?.lastRemote = remote
            self?.updateStatusIcon()
        }
        NotificationCenter.default.addObserver(forName: .recordingsChanged, object: nil, queue: .main) { [weak self] _ in
            self?.updateStatusIcon()
        }

        configureLoginItemOnFirstRun()
        setupWebView()
        popover.behavior = .transient
        popover.animates = true
        popover.delegate = self
        let vc = NSViewController()
        vc.view = webView
        popover.contentViewController = vc
        applyPopoverSize()
    }

    func applicationWillTerminate(_ notification: Notification) {
        RecordingManager.shared.stopAll(timeout: 5)
        server.shutdown()
    }

    // MARK: Web view

    private func setupWebView() {
        let config = WKWebViewConfiguration()
        config.userContentController.add(self, name: "ndi")
        config.websiteDataStore = .default()
        webView = WKWebView(frame: NSRect(origin: .zero, size: NSSize(width: 860, height: 600)), configuration: config)
        webView.setValue(false, forKey: "drawsBackground")
        webView.underPageBackgroundColor = .black
        webView.navigationDelegate = self
        webView.allowsMagnification = false
        #if DEBUG
        if #available(macOS 13.3, *) { webView.isInspectable = true }
        #endif
    }

    private func loadPageIfNeeded() {
        guard !pageLoaded, server.port > 0, let url = URL(string: server.localURL + "?host=popover") else { return }
        pageLoaded = true
        webView.load(URLRequest(url: url))
    }

    private func setWebVisible(_ visible: Bool) {
        webView.evaluateJavaScript("window.NDIHost && window.NDIHost.setVisible(\(visible))", completionHandler: nil)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        setWebVisible(popover.isShown)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) { pageLoaded = false }
    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) { pageLoaded = false }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let action = body["action"] as? String else { return }
        switch action {
        case "detach":
            guard let source = body["source"] as? String else { return }
            popover.performClose(nil)
            openNativeViewer(source: source, ip: (body["ip"] as? String) ?? "")
        case "openBrowser":
            popover.performClose(nil)
            if let url = URL(string: server.localURL) { NSWorkspace.shared.open(url) }
        case "openURL":
            if let s = body["url"] as? String, let url = URL(string: s) { NSWorkspace.shared.open(url) }
        case "copy":
            if let text = body["text"] as? String {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
            }
        case "popoverSize":
            if let size = body["size"] as? String {
                AppSettings.shared.update { $0.popoverSize = size }
                applyPopoverSize()
            }
        case "quit":
            NSApp.terminate(nil)
        default:
            break
        }
    }

    // MARK: Status item

    @objc private func statusClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            showMenu()
        } else {
            togglePopover()
        }
    }

    private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else if let button = statusItem.button {
            loadPageIfNeeded()
            NSApp.activate(ignoringOtherApps: true)
            popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
            popover.contentViewController?.view.window?.makeKey()
        }
    }

    func popoverWillShow(_ notification: Notification) { setWebVisible(true) }
    func popoverDidClose(_ notification: Notification) { setWebVisible(false) }

    private func applyPopoverSize() {
        let size = Self.popoverSizes[AppSettings.shared.values.popoverSize] ?? Self.popoverSizes["medium"]!
        popover.contentSize = size
    }

    private func showMenu() {
        let menu = NSMenu()
        menu.addItem(withTitle: "Open Viewer", action: #selector(openFromMenu), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open in Browser", action: #selector(openInBrowser), keyEquivalent: "").target = self
        let lan = server.lanURLs.first
        let copy = menu.addItem(withTitle: lan.map { "Copy Phone Link (\($0))" } ?? "Copy Phone Link", action: #selector(copyPhoneURL), keyEquivalent: "")
        copy.target = self
        copy.isEnabled = lan != nil

        let sizeItem = NSMenuItem(title: "Popover Size", action: nil, keyEquivalent: "")
        let sizeMenu = NSMenu()
        for (key, title) in [("small", "Small"), ("medium", "Medium"), ("large", "Large")] {
            let item = sizeMenu.addItem(withTitle: title, action: #selector(setSize(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = key
            item.state = AppSettings.shared.values.popoverSize == key ? .on : .off
        }
        sizeItem.submenu = sizeMenu
        menu.addItem(sizeItem)

        menu.addItem(withTitle: "Open Recordings Folder", action: #selector(openRecordings), keyEquivalent: "").target = self

        let login = menu.addItem(withTitle: "Launch at Login", action: #selector(toggleLoginItem), keyEquivalent: "")
        login.target = self
        login.state = SMAppService.mainApp.status == .enabled ? .on : .off

        menu.addItem(.separator())
        let info = menu.addItem(withTitle: "NDI \(NDILib.version.split(separator: " ").last ?? "") · port \(server.port)", action: nil, keyEquivalent: "")
        info.isEnabled = false
        menu.addItem(withTitle: "Quit NDI-Viewer", action: #selector(quit), keyEquivalent: "q").target = self

        statusItem.menu = menu
        statusItem.button?.performClick(nil)
        statusItem.menu = nil
    }

    @objc private func openFromMenu() { togglePopover() }
    @objc private func openInBrowser() { if let url = URL(string: server.localURL) { NSWorkspace.shared.open(url) } }
    @objc private func copyPhoneURL() {
        guard let url = server.lanURLs.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(url, forType: .string)
    }
    @objc private func setSize(_ item: NSMenuItem) {
        guard let key = item.representedObject as? String else { return }
        AppSettings.shared.update { $0.popoverSize = key }
        applyPopoverSize()
    }
    @objc private func openRecordings() {
        let folder = RecordingManager.folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        NSWorkspace.shared.open(folder)
    }
    @objc private func quit() { NSApp.terminate(nil) }

    // MARK: Launch at login

    /// Registers as a login item once; after that the menu toggle is the source of truth.
    private func configureLoginItemOnFirstRun() {
        let key = "loginItemConfigured"
        guard !UserDefaults.standard.bool(forKey: key) else { return }
        do {
            try SMAppService.mainApp.register()
            UserDefaults.standard.set(true, forKey: key)
        } catch {
            NSLog("Launch at login registration failed: \(error)")
        }
    }

    @objc private func toggleLoginItem() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
            UserDefaults.standard.set(true, forKey: "loginItemConfigured")
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Launch at Login"
            alert.informativeText = error.localizedDescription
            alert.runModal()
        }
    }

    private func updateStatusIcon() {
        let remote = lastRemote
        let recording = RecordingManager.shared.activeCount
        let symbol = recording > 0 ? "record.circle" : remote > 0 ? "rectangle.grid.2x2.fill" : "rectangle.grid.2x2"
        statusItem.button?.image = NSImage(systemSymbolName: symbol, accessibilityDescription: "NDI-Viewer")
        statusItem.button?.image?.isTemplate = true
        var tip = ["NDI-Viewer"]
        if recording > 0 { tip.append("recording \(recording) source\(recording == 1 ? "" : "s")") }
        if remote > 0 { tip.append("\(remote) remote viewer\(remote == 1 ? "" : "s")") }
        statusItem.button?.toolTip = tip.joined(separator: " — ")
    }

    // MARK: Native viewers

    private func openNativeViewer(source: String, ip: String) {
        if let existing = viewers[source] { existing.focus(); return }
        let c = NativeViewerController(source: source, ip: ip)
        c.onClose = { [weak self] c in self?.viewers[c.source] = nil }
        viewers[source] = c
        c.show()
    }
}
