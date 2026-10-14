import Foundation
import Darwin

/// Finds machines running NDI by probing the NDI messaging port (TCP 5960) on every address in a set of subnets.
/// Hosts that answer are handed to the finder as extra IPs, which also finds sources on other subnets
/// and on networks where mDNS is blocked.
final class NetworkScanner {
    static let ndiPort: UInt16 = 5960
    static let maxHosts = 4096

    struct Progress {
        var done: Int
        var total: Int
        var found: [String]
    }

    private let lock = NSLock()
    private var cancelled = false

    func cancel() {
        lock.lock(); cancelled = true; lock.unlock()
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    /// Blocking. Calls `progress` after every batch; returns the hosts that accepted a connection.
    func run(_ hosts: [String], progress: (Progress) -> Void) -> [String] {
        let addrs = hosts.compactMap(Self.parse)
        var found: [String] = []
        var done = 0
        let batch = 64
        var i = 0
        while i < addrs.count, !isCancelled {
            let chunk = Array(addrs[i..<min(i + batch, addrs.count)])
            found += Self.probe(chunk, port: Self.ndiPort, timeoutMs: 600).map(Self.format)
            i += chunk.count
            done = i
            progress(Progress(done: done, total: addrs.count, found: found))
        }
        return found
    }

    // MARK: Targets

    /// Every host address in this Mac's IPv4 subnets (wider than /22 is narrowed to the /24 around the Mac)
    /// plus the ranges in `spec`. The Mac's own addresses are left out.
    static func targets(spec: String) -> (hosts: [String], invalid: [String]) {
        var ranges: [ClosedRange<UInt32>] = []
        var own = Set<UInt32>()
        for (ip, mask) in localSubnets() {
            own.insert(ip)
            ranges.append(hostRange(ip: ip, prefix: max(mask, 22)))
        }
        var invalid: [String] = []
        for token in spec.split(whereSeparator: { $0 == "," || $0 == " " || $0 == "\n" || $0 == ";" }) {
            if let r = parseRange(String(token)) { ranges.append(r) } else { invalid.append(String(token)) }
        }
        var seen = Set<UInt32>()
        var out: [String] = []
        for r in ranges {
            for a in r where !own.contains(a) && seen.insert(a).inserted {
                out.append(format(a))
                if out.count >= maxHosts { return (out, invalid) }
            }
        }
        return (out, invalid)
    }

    /// Accepts "10.0.5.0/24", "10.0.5.10-80", "10.0.5.10-10.0.6.20", or a single address
    /// (a single address scans its /24, since that is what people usually mean by it).
    static func parseRange(_ s: String) -> ClosedRange<UInt32>? {
        if let slash = s.firstIndex(of: "/") {
            guard let ip = parse(String(s[..<slash])), let p = Int(s[s.index(after: slash)...]), (20...32).contains(p) else { return nil }
            return hostRange(ip: ip, prefix: p)
        }
        if let dash = s.firstIndex(of: "-") {
            guard let a = parse(String(s[..<dash])) else { return nil }
            let rest = String(s[s.index(after: dash)...])
            let b: UInt32
            if let full = parse(rest) { b = full }
            else if let last = UInt32(rest), last <= 255 { b = (a & 0xFFFF_FF00) | last }
            else { return nil }
            guard a <= b, b - a < UInt32(maxHosts) else { return nil }
            return a...b
        }
        guard let ip = parse(s) else { return nil }
        return hostRange(ip: ip, prefix: 24)
    }

    private static func hostRange(ip: UInt32, prefix: Int) -> ClosedRange<UInt32> {
        if prefix >= 31 { return ip...ip }
        let mask: UInt32 = ~0 << UInt32(32 - prefix)
        let net = ip & mask
        return (net + 1)...((net | ~mask) - 1)
    }

    /// (address, prefix length) for each up, non-loopback, non-link-local IPv4 interface.
    private static func localSubnets() -> [(UInt32, Int)] {
        var result: [(UInt32, Int)] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let ifa = ptr.pointee
            guard let addr = ifa.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET), let mask = ifa.ifa_netmask else { continue }
            let flags = Int32(ifa.ifa_flags)
            guard flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            let ip = addr.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            let m = mask.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { UInt32(bigEndian: $0.pointee.sin_addr.s_addr) }
            if ip >> 16 == 0xA9FE { continue }   // 169.254/16
            result.append((ip, m.nonzeroBitCount))
        }
        return result
    }

    // MARK: Probe

    /// Non-blocking connect to every address at once, then waits up to `timeoutMs` for them to finish.
    private static func probe(_ addrs: [UInt32], port: UInt16, timeoutMs: Int) -> [UInt32] {
        var fds: [pollfd] = []
        var targets: [UInt32] = []
        var open: [UInt32] = []
        defer { for p in fds where p.fd >= 0 { close(p.fd) } }

        for a in addrs {
            let fd = socket(AF_INET, SOCK_STREAM, 0)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
            var on: Int32 = 1
            setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
            var sa = sockaddr_in()
            sa.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            sa.sin_family = sa_family_t(AF_INET)
            sa.sin_port = in_port_t(port.bigEndian)
            sa.sin_addr.s_addr = a.bigEndian
            let r = withUnsafePointer(to: &sa) {
                $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
            }
            if r == 0 { open.append(a); close(fd); continue }
            guard errno == EINPROGRESS else { close(fd); continue }
            fds.append(pollfd(fd: fd, events: Int16(POLLOUT), revents: 0))
            targets.append(a)
        }

        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        var pending = fds.count
        while pending > 0 {
            let left = Int32(deadline.timeIntervalSinceNow * 1000)
            guard left > 0 else { break }
            let n = poll(&fds, nfds_t(fds.count), left)
            if n < 0 { if errno == EINTR { continue } else { break } }
            if n == 0 { break }
            for i in fds.indices where fds[i].fd >= 0 && fds[i].revents != 0 {
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fds[i].fd, SOL_SOCKET, SO_ERROR, &err, &len)
                if err == 0 { open.append(targets[i]) }
                close(fds[i].fd)
                fds[i].fd = -1
                pending -= 1
            }
        }
        return open.sorted()
    }

    // MARK: Addresses

    static func parse(_ s: String) -> UInt32? {
        var a = in_addr()
        guard inet_pton(AF_INET, s, &a) == 1 else { return nil }
        return UInt32(bigEndian: a.s_addr)
    }

    static func format(_ a: UInt32) -> String {
        "\(a >> 24).\(a >> 16 & 0xFF).\(a >> 8 & 0xFF).\(a & 0xFF)"
    }
}
