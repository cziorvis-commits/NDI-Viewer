import Foundation

enum NDILib {
    /// NDIlib_initialize is called once, lazily.
    static let isReady: Bool = {
        guard NDIlib_is_supported_CPU() else { return false }
        return NDIlib_initialize()
    }()

    static var version: String {
        guard let v = NDIlib_version() else { return "unknown" }
        return String(cString: v)
    }
}

struct NDISource: Hashable {
    let name: String   // "MACHINE (Source Name)"
    let url: String    // usually "ip:port"

    var host: String { Self.split(name).host }
    var label: String { Self.split(name).label }
    var ip: String { Self.ip(fromURL: url) }

    /// Sources on this Mac report a loopback address; show the Mac's LAN address instead.
    var displayIP: String {
        let raw = ip
        guard raw == "127.0.0.1" || raw == "::1" || raw == "localhost" else { return raw }
        return NetUtil.lanIPv4().first ?? raw
    }

    var json: [String: Any] {
        ["name": name, "host": host, "label": label, "ip": displayIP, "url": url]
    }

    static func split(_ name: String) -> (host: String, label: String) {
        guard name.hasSuffix(")"), let open = name.firstIndex(of: "(") else { return (name, name) }
        let host = name[..<open].trimmingCharacters(in: .whitespaces)
        let label = name[name.index(after: open)..<name.index(before: name.endIndex)]
        return (host.isEmpty ? name : host, String(label))
    }

    static func ip(fromURL url: String) -> String {
        var s = url
        if let r = s.range(of: "://") { s = String(s[r.upperBound...]) }
        if s.hasPrefix("["), let close = s.firstIndex(of: "]") {
            return String(s[s.index(after: s.startIndex)..<close])
        }
        if let colon = s.lastIndex(of: ":"), s.filter({ $0 == ":" }).count == 1 {
            return String(s[..<colon])
        }
        return s
    }
}

/// Runs an NDI finder on its own thread while started. Recreated when the extra-IP list changes.
final class SourceFinder {
    var onChange: (([NDISource]) -> Void)?

    private let lock = NSLock()
    private var generation = 0
    private var running = false
    private var extraIPs = ""
    private var current: [NDISource] = []

    var sources: [NDISource] {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    var isRunning: Bool {
        lock.lock(); defer { lock.unlock() }
        return running
    }

    func start(extraIPs ips: String) {
        lock.lock()
        if running && ips == extraIPs { lock.unlock(); return }
        generation += 1
        running = true
        extraIPs = ips
        let gen = generation
        lock.unlock()

        let t = Thread { [weak self] in self?.run(generation: gen, extraIPs: ips) }
        t.name = "ndi.finder"
        t.qualityOfService = .utility
        t.start()
    }

    func stop() {
        lock.lock()
        generation += 1
        running = false
        current = []
        lock.unlock()
        onChange?([])
    }

    private func isCurrent(_ gen: Int) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return gen == generation
    }

    private func run(generation gen: Int, extraIPs ips: String) {
        guard NDILib.isReady else { return }
        var settings = NDIlib_find_create_t(show_local_sources: true, p_groups: nil, p_extra_ips: nil)
        let finder: NDIlib_find_instance_t? = ips.isEmpty
            ? NDIlib_find_create_v2(&settings)
            : ips.withCString { p -> NDIlib_find_instance_t? in
                settings.p_extra_ips = p
                return NDIlib_find_create_v2(&settings)
            }
        guard let finder else { return }
        defer { NDIlib_find_destroy(finder) }

        var last: [NDISource]? = nil
        while isCurrent(gen) {
            _ = NDIlib_find_wait_for_sources(finder, 1000)
            guard isCurrent(gen) else { break }
            var count: UInt32 = 0
            var list: [NDISource] = []
            if let p = NDIlib_find_get_current_sources(finder, &count) {
                for i in 0..<Int(count) {
                    let s = p[i]
                    let name = s.p_ndi_name.map { String(cString: $0) } ?? ""
                    let url = s.p_url_address.map { String(cString: $0) } ?? ""
                    if !name.isEmpty { list.append(NDISource(name: name, url: url)) }
                }
            }
            list.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
            if list != last {
                last = list
                lock.lock()
                let stillCurrent = gen == generation
                if stillCurrent { current = list }
                lock.unlock()
                if stillCurrent { onChange?(list) }
            }
        }
    }
}
