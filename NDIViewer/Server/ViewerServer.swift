import Foundation

/// Glues the web clients, the NDI finder/receivers, and saved stage profiles together.
/// Everything here runs on `queue` unless noted.
final class ViewerServer {
    static let shared = ViewerServer()

    let queue = DispatchQueue(label: "viewer.server")
    let hub = ReceiverHub.shared
    let finder = SourceFinder()
    let profiles = ProfileStore()
    private let http = HTTPServer()

    private(set) var port = 0
    private var sessions: [String: ClientSession] = [:]
    private var nativeViewers = 0
    private var finderStop: DispatchWorkItem?
    private var timer: DispatchSourceTimer?
    private var webRoot: URL?
    private var qrCache: (String, Data)?
    private var viewersDirty = false

    /// Called on the main thread: (active viewers, remote viewers watching).
    var onPresenceChange: ((Int, Int) -> Void)?

    private init() {}

    // MARK: Lifecycle

    func start() throws {
        webRoot = Bundle.main.resourceURL?.appendingPathComponent("Web", isDirectory: true)
        http.router = { [weak self] req in self?.route(req) ?? .notFound() }
        http.onWebSocket = { [weak self] ws, req in self?.queue.async { self?.accept(ws, req) } }
        port = try http.start(preferredPort: AppSettings.shared.values.port)

        finder.onChange = { [weak self] list in
            guard let self else { return }
            self.hub.updateKnownSources(list)
            self.queue.async { self.broadcastSources(list) }
        }

        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 5, repeating: 5)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t

        NotificationCenter.default.addObserver(forName: .settingsChanged, object: nil, queue: nil) { [weak self] _ in
            self?.queue.async { self?.settingsChanged() }
        }
    }

    func shutdown() {
        http.stop()
        finder.stop()
        hub.stopAll()
    }

    var localURL: String { "http://127.0.0.1:\(port)/" }
    var lanURLs: [String] { NetUtil.lanIPv4().map { "http://\($0):\(port)/" } }

    func nativeViewerOpened() { queue.async { self.nativeViewers += 1; self.updatePresence() } }
    func nativeViewerClosed() { queue.async { self.nativeViewers = max(0, self.nativeViewers - 1); self.updatePresence() } }

    // MARK: HTTP

    private func route(_ req: HTTPRequest) -> HTTPResponse {
        let path = req.path
        if path.hasPrefix("/snap/") {
            let name = String(path.dropFirst(6))
            var file: URL?
            queue.sync { file = profiles.snapshotFile(named: name) }
            guard let file, let data = try? Data(contentsOf: file) else { return .notFound() }
            return HTTPResponse(contentType: "image/jpeg", body: data, headers: ["Cache-Control": "max-age=31536000"])
        }
        if path == "/qr.png" {
            let url = lanURLs.first ?? localURL
            if qrCache?.0 != url, let png = NetUtil.qrPNG(url) { qrCache = (url, png) }
            guard let png = qrCache?.1 else { return .notFound() }
            return HTTPResponse(contentType: "image/png", body: png, headers: ["Cache-Control": "no-store"])
        }
        let file = path == "/" ? "index.html" : String(path.dropFirst())
        guard let root = webRoot,
              file.range(of: "^[A-Za-z0-9_.-]+$", options: .regularExpression) != nil, !file.hasPrefix("."),
              let data = try? Data(contentsOf: root.appendingPathComponent(file)) else { return .notFound() }
        let ext = (file as NSString).pathExtension.lowercased()
        let types = ["html": "text/html; charset=utf-8", "js": "text/javascript; charset=utf-8",
                     "css": "text/css; charset=utf-8", "svg": "image/svg+xml", "png": "image/png",
                     "json": "application/json", "webmanifest": "application/manifest+json"]
        return HTTPResponse(contentType: types[ext] ?? "application/octet-stream", body: data,
                            headers: ["Cache-Control": "no-cache"])
    }

    // MARK: Sessions

    private func isLocalHost(_ host: String) -> Bool {
        #if DEBUG
        // Lets remote-viewer rules (idle hold, cap) be tested from this Mac.
        if ProcessInfo.processInfo.environment["NDIVIEWER_ALL_REMOTE"] == "1" { return false }
        #endif
        return host == "127.0.0.1" || host == "::1" || host == "localhost" || NetUtil.lanIPv4().contains(host)
    }

    private func accept(_ ws: WebSocketConnection, _ req: HTTPRequest) {
        let s = ClientSession(ws: ws, isLocal: isLocalHost(ws.remoteHost))
        sessions[s.id] = s
        ws.onText = { [weak self, weak s] text in
            guard let self, let s else { return }
            guard let data = text.data(using: .utf8),
                  let msg = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let t = msg["t"] as? String else { return }
            self.queue.async { self.handle(t, msg, from: s) }
        }
        ws.onClose = { [weak self, weak s] in
            guard let self, let s else { return }
            self.queue.async { self.drop(s) }
        }
        var welcome: [String: Any] = [
            "t": "welcome", "id": s.id, "local": s.isLocal, "port": port,
            "urls": lanURLs, "ndi": NDILib.version, "ndiReady": NDILib.isReady,
        ]
        if s.isLocal { welcome["settings"] = AppSettings.shared.json }
        ws.sendJSON(welcome)
        ws.sendJSON(["t": "sources", "list": finder.sources.map(\.json)])
        ws.sendJSON(profilesMessage())
        updatePresence()
    }

    private func drop(_ s: ClientSession) {
        guard sessions.removeValue(forKey: s.id) != nil else { return }
        s.setDeliverable([], audio: nil)
        hub.remove(s)
        updatePresence()
    }

    private func handle(_ t: String, _ m: [String: Any], from s: ClientSession) {
        s.lastSeen = Date()
        switch t {
        case "hello":
            // Only a local client may claim to be the popover (which is exempt from idle hold).
            let kind = (m["kind"] as? String) ?? "browser"
            s.kind = kind == "popover" && !s.isLocal ? "browser" : kind
            s.device = String(((m["device"] as? String) ?? "Browser").prefix(60))
            markViewersDirty()

        case "ping":
            s.ws.sendJSON(["t": "pong"])

        case "activity":
            if s.isActive { s.lastActivity = Date() }

        case "subscribe":
            var subs = Set<Subscription>()
            for item in (m["subs"] as? [[String: Any]]) ?? [] {
                guard let src = item["s"] as? String, let qs = item["q"] as? String,
                      let q = StreamQuality(rawValue: qs), q != .native else { continue }
                subs.insert(Subscription(source: src, quality: q))
            }
            let hadFull = s.wantsFull
            s.requested = subs
            s.requestedAudio = m["audio"] as? String
            if s.wantsFull != hadFull { s.lastActivity = Date() }
            apply(s)
            markViewersDirty()

        case "ack":
            if let src = m["s"] as? String, let qs = m["q"] as? String, let q = StreamQuality(rawValue: qs) {
                s.ack(Subscription(source: src, quality: q))
            }

        case "visibility":
            let visible = (m["visible"] as? Bool) ?? true
            if !visible, s.state == .active {
                s.state = .hidden
            } else if visible, s.state == .hidden {
                s.state = .active
                s.lastActivity = Date()
            }
            apply(s)
            updatePresence()

        case "resume":
            s.state = .active
            s.lastActivity = Date()
            apply(s)
            s.ws.sendJSON(["t": "resumed"])
            updatePresence()

        case "viewProfile":
            s.viewingProfile = m["id"] as? String
            refreshFinder()

        case "saveProfile":
            let name = ((m["name"] as? String) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let p = profiles.create(name: name.isEmpty ? "Stage" : String(name.prefix(80)), sources: finder.sources)
            s.ws.sendJSON(["t": "profileSaved", "id": p.id])
            broadcastProfiles()
            captureSnapshots(for: p.id)

        case "refreshProfile":
            if let id = m["id"] as? String, profiles.refresh(id: id, sources: finder.sources) != nil {
                broadcastProfiles()
                captureSnapshots(for: id, force: true)
                s.ws.sendJSON(["t": "toast", "text": "Stage updated from live sources"])
            }

        case "renameProfile":
            if let id = m["id"] as? String, let name = m["name"] as? String, !name.isEmpty {
                profiles.rename(id: id, to: String(name.prefix(80)))
                broadcastProfiles()
            }

        case "deleteProfile":
            if let id = m["id"] as? String {
                profiles.delete(id: id)
                broadcastProfiles()
                refreshFinder()
            }

        // Host-only controls
        case "hold" where s.isLocal:
            let target = m["id"] as? String
            for other in sessions.values where !other.isPopover && (target == "all" || target == other.id) {
                hold(other, reason: "host")
            }

        case "settings" where s.isLocal:
            if let values = m["values"] as? [String: Any] { AppSettings.shared.merge(json: values) }

        default:
            break
        }
    }

    /// Pushes a session's effective subscriptions into the hub (enforcing hold + the remote full-quality cap).
    private func apply(_ s: ClientSession) {
        var effective = s.isActive ? s.requested : []
        let audio = s.isActive ? s.requestedAudio : nil
        let cap = AppSettings.shared.values.remoteFullCap
        let wasCapped = s.capped
        if !s.isLocal, cap > 0, let full = effective.first(where: { $0.quality == .full }) {
            let others = sessions.values.filter {
                $0 !== s && !$0.isLocal && $0.isActive && !$0.capped && $0.wantsFull
            }.count
            if others >= cap {
                effective.remove(full)
                effective.insert(Subscription(source: full.source, quality: .medium))
                if !wasCapped { s.ws.sendJSON(["t": "capped", "cap": cap]) }
                s.capped = true
            } else {
                s.capped = false
            }
        } else {
            s.capped = false
        }
        if wasCapped && !s.capped && s.wantsFull && s.isActive { s.ws.sendJSON(["t": "uncapped"]) }
        s.setDeliverable(effective, audio: audio)
        hub.setSubscriptions(s, effective, audio: audio)
    }

    private func hold(_ s: ClientSession, reason: String) {
        guard s.state != .held(reason) else { return }
        s.state = .held(reason)
        apply(s)
        s.ws.sendJSON(["t": "held", "reason": reason])
        updatePresence()
    }

    private func tick() {
        let now = Date()
        let settings = AppSettings.shared.values
        for s in Array(sessions.values) {
            if now.timeIntervalSince(s.lastSeen) > 35 {
                s.ws.close()
                drop(s)
                continue
            }
            // The popover sleeps when closed; every browser window (phone or Mac) gets the idle hold.
            guard !s.isPopover, s.isActive else { continue }
            let limit = (s.wantsFull ? settings.fullIdleMinutes : settings.galleryIdleMinutes) * 60
            if now.timeIntervalSince(s.lastActivity) > limit { hold(s, reason: "idle") }
        }
        // Re-check capped sessions in case a slot freed up.
        for s in sessions.values where s.capped && s.isActive { apply(s) }
        markViewersDirty()
        flushViewers()
    }

    // MARK: Presence (wake / sleep)

    private func updatePresence() {
        let active = sessions.values.filter(\.isActive).count + nativeViewers
        if active > 0 {
            finderStop?.cancel(); finderStop = nil
            refreshFinder()
        } else if finder.isRunning, finderStop == nil {
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.finderStop = nil
                if self.sessions.values.filter(\.isActive).count + self.nativeViewers == 0 { self.finder.stop() }
            }
            finderStop = work
            queue.asyncAfter(deadline: .now() + 10, execute: work)
        }
        let remote = sessions.values.filter { !$0.isLocal && $0.isActive }.count
        DispatchQueue.main.async { self.onPresenceChange?(active, remote) }
        markViewersDirty()
        flushViewers()
    }

    /// Starts/restarts the finder with settings IPs + IPs of stages that active viewers are looking at.
    private func refreshFinder() {
        let active = sessions.values.filter(\.isActive).count + nativeViewers
        guard active > 0 else { return }
        var ips = AppSettings.shared.values.extraIPs
            .split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" }).map(String.init)
        for s in sessions.values where s.isActive {
            if let id = s.viewingProfile, let p = profiles.profile(id) { ips += p.ips }
        }
        var seen = Set<String>()
        let joined = ips.filter { !$0.isEmpty && seen.insert($0).inserted }.joined(separator: ",")
        finder.start(extraIPs: joined)
    }

    private func settingsChanged() {
        for s in sessions.values where s.isLocal { s.ws.sendJSON(["t": "settings", "values": AppSettings.shared.json]) }
        for s in sessions.values { apply(s) }
        refreshFinder()
    }

    // MARK: Broadcasts

    private func broadcastSources(_ list: [NDISource]) {
        let msg: [String: Any] = ["t": "sources", "list": list.map(\.json)]
        for s in sessions.values { s.ws.sendJSON(msg) }
    }

    private func profilesMessage() -> [String: Any] {
        ["t": "profiles", "list": profiles.profiles.map(\.json)]
    }

    private func broadcastProfiles() {
        let msg = profilesMessage()
        for s in sessions.values { s.ws.sendJSON(msg) }
    }

    private func markViewersDirty() { viewersDirty = true }

    private func flushViewers() {
        guard viewersDirty else { return }
        viewersDirty = false
        let list: [[String: Any]] = sessions.values.sorted { $0.connectedAt < $1.connectedAt }.map { s in
            var watching = "Gallery"
            if let f = s.fullSource { watching = NDISource.split(f).label + (s.capped ? " (preview)" : "") }
            else if !s.requested.isEmpty { watching = "Gallery · \(s.requested.count) tiles" }
            return ["id": s.id, "ip": s.ip, "kind": s.kind, "device": s.device, "local": s.isLocal,
                    "state": s.state.name, "watching": watching, "kbps": s.takeSentBytes() * 8 / 5 / 1000,
                    "since": s.connectedAt.timeIntervalSince1970 * 1000]
        }
        let msg: [String: Any] = ["t": "viewers", "list": list, "receivers": hub.activeReceiverCount]
        for s in sessions.values where s.isLocal { s.ws.sendJSON(msg) }
    }

    // MARK: Snapshots

    private func captureSnapshots(for id: String, force: Bool = false) {
        guard let p = profiles.profile(id) else { return }
        for src in p.sources where force || src.snapshot == nil {
            hub.grabFrame(src.name, timeout: 4) { [weak self] jpeg in
                guard let self, let jpeg else { return }
                self.queue.async {
                    self.profiles.setSnapshot(id: id, source: src.name, jpeg: jpeg)
                    self.scheduleProfilesBroadcast()
                }
            }
        }
    }

    private var profilesBroadcastPending = false
    private func scheduleProfilesBroadcast() {
        guard !profilesBroadcastPending else { return }
        profilesBroadcastPending = true
        queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.profilesBroadcastPending = false
            self?.broadcastProfiles()
        }
    }
}
