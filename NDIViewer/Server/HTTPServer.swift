import Foundation
import Network
import CryptoKit

struct HTTPRequest {
    let method: String
    let path: String
    let query: [String: String]
    let headers: [String: String]   // lowercased keys
    let remoteHost: String
}

struct HTTPResponse {
    var status: Int = 200
    var contentType = "text/plain; charset=utf-8"
    var body = Data()
    var headers: [String: String] = [:]

    static func notFound() -> HTTPResponse { HTTPResponse(status: 404, body: Data("Not found".utf8)) }
}

/// Minimal HTTP/1.1 + WebSocket server on Network.framework.
final class HTTPServer {
    var router: ((HTTPRequest) -> HTTPResponse)?
    var onWebSocket: ((WebSocketConnection, HTTPRequest) -> Void)?

    private var listener: NWListener?
    let queue = DispatchQueue(label: "http.server")
    private(set) var port: Int = 0

    /// Binds the first free port in port...port+10. Returns the bound port.
    func start(preferredPort: Int) throws -> Int {
        var chosen: Int?
        for p in preferredPort...(preferredPort + 10) where NetUtil.isPortFree(p) { chosen = p; break }
        guard let chosen, let nwPort = NWEndpoint.Port(rawValue: UInt16(chosen)) else {
            throw NSError(domain: "NDIViewer", code: 1, userInfo: [NSLocalizedDescriptionKey: "No free port near \(preferredPort)"])
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let l = try NWListener(using: params, on: nwPort)
        l.newConnectionHandler = { [weak self] conn in
            guard let self else { conn.cancel(); return }
            HTTPConnection(conn: conn, server: self).start()
        }
        l.stateUpdateHandler = { state in
            if case .failed(let e) = state { NSLog("HTTP listener failed: \(e)") }
        }
        l.start(queue: queue)
        listener = l
        port = chosen
        return chosen
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    static func hostString(_ endpoint: NWEndpoint) -> String {
        guard case .hostPort(let host, _) = endpoint else { return "" }
        var s: String
        switch host {
        case .ipv4(let a): s = "\(a)"
        case .ipv6(let a): s = "\(a)"
        case .name(let n, _): s = n
        @unknown default: s = "\(host)"
        }
        if let pct = s.firstIndex(of: "%") { s = String(s[..<pct]) }
        if s.hasPrefix("::ffff:") { s = String(s.dropFirst(7)) }
        return s
    }
}

private final class HTTPConnection {
    private let conn: NWConnection
    private weak var server: HTTPServer?
    private var buffer = Data()
    private var keepSelf: HTTPConnection?

    init(conn: NWConnection, server: HTTPServer) {
        self.conn = conn
        self.server = server
    }

    func start() {
        keepSelf = self
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.keepSelf = nil
            default: break
            }
        }
        conn.start(queue: server?.queue ?? .main)
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            if let r = self.buffer.range(of: Data("\r\n\r\n".utf8)) {
                let head = self.buffer.subdata(in: self.buffer.startIndex..<r.lowerBound)
                let rest = self.buffer.subdata(in: r.upperBound..<self.buffer.endIndex)
                self.handle(head: head, leftover: rest)
                return
            }
            if isComplete || error != nil || self.buffer.count > 65536 {
                self.conn.cancel()
                return
            }
            self.receive()
        }
    }

    private func handle(head: Data, leftover: Data) {
        guard let server, let text = String(data: head, encoding: .utf8) else { conn.cancel(); return }
        let lines = text.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ") ?? []
        guard parts.count >= 2 else { conn.cancel(); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let c = line.firstIndex(of: ":") else { continue }
            headers[line[..<c].trimmingCharacters(in: .whitespaces).lowercased()] =
                line[line.index(after: c)...].trimmingCharacters(in: .whitespaces)
        }
        let target = String(parts[1])
        let comps = URLComponents(string: target)
        var query: [String: String] = [:]
        comps?.queryItems?.forEach { query[$0.name] = $0.value ?? "" }
        let req = HTTPRequest(method: String(parts[0]), path: comps?.path ?? target, query: query,
                              headers: headers, remoteHost: HTTPServer.hostString(conn.endpoint))

        if headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] {
            let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
            let resp = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
            let ws = WebSocketConnection(conn: conn, queue: server.queue, leftover: leftover, remoteHost: req.remoteHost)
            conn.send(content: Data(resp.utf8), completion: .contentProcessed { _ in })
            keepSelf = nil
            server.onWebSocket?(ws, req)
            ws.start()
            return
        }

        let resp = req.method == "GET" || req.method == "HEAD" ? (server.router?(req) ?? .notFound())
                                                                 : HTTPResponse(status: 405)
        var out = "HTTP/1.1 \(resp.status) \(Self.reason(resp.status))\r\n"
        out += "Content-Type: \(resp.contentType)\r\nContent-Length: \(resp.body.count)\r\nConnection: close\r\n"
        for (k, v) in resp.headers { out += "\(k): \(v)\r\n" }
        out += "\r\n"
        var data = Data(out.utf8)
        if req.method != "HEAD" { data.append(resp.body) }
        conn.send(content: data, completion: .contentProcessed { [weak self] _ in self?.conn.cancel() })
    }

    private static func reason(_ s: Int) -> String {
        switch s { case 200: return "OK"; case 404: return "Not Found"; case 405: return "Method Not Allowed"; default: return "Status" }
    }
}

/// RFC 6455 server-side connection. Callbacks arrive on the server queue; sends are thread-safe.
final class WebSocketConnection {
    var onText: ((String) -> Void)?
    var onBinary: ((Data) -> Void)?
    var onClose: (() -> Void)?

    let remoteHost: String
    private let conn: NWConnection
    private let queue: DispatchQueue
    private var buffer: Data
    private var fragments = Data()
    private var fragmentOpcode: UInt8 = 0

    private let lock = NSLock()
    private var closed = false
    private var pending = 0

    init(conn: NWConnection, queue: DispatchQueue, leftover: Data, remoteHost: String) {
        self.conn = conn
        self.queue = queue
        self.buffer = leftover
        self.remoteHost = remoteHost
    }

    /// Bytes handed to the network but not yet sent — used for backpressure.
    var pendingBytes: Int {
        lock.lock(); defer { lock.unlock() }
        return pending
    }

    var isClosed: Bool {
        lock.lock(); defer { lock.unlock() }
        return closed
    }

    func start() {
        conn.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        process()
        receive()
    }

    private func receive() {
        conn.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data { self.buffer.append(data) }
            self.process()
            if self.isClosed { return }
            if isComplete || error != nil { self.close(); return }
            self.receive()
        }
    }

    private func process() {
        while true {
            let b = [UInt8](buffer.prefix(14))
            guard b.count >= 2 else { return }
            let fin = b[0] & 0x80 != 0
            let opcode = b[0] & 0x0F
            let masked = b[1] & 0x80 != 0
            var len = Int(b[1] & 0x7F)
            var idx = 2
            if len == 126 {
                guard b.count >= 4 else { return }
                len = Int(b[2]) << 8 | Int(b[3]); idx = 4
            } else if len == 127 {
                guard b.count >= 10 else { return }
                len = 0
                for i in 2..<10 { len = len << 8 | Int(b[i]) }
                idx = 10
            }
            guard len < 16 << 20 else { close(); return }
            let maskLen = masked ? 4 : 0
            guard buffer.count >= idx + maskLen + len else { return }
            let all = [UInt8](buffer.prefix(idx + maskLen + len))
            var payload = [UInt8](all[(idx + maskLen)...])
            if masked {
                let mask = Array(all[idx..<(idx + 4)])
                for i in 0..<payload.count { payload[i] ^= mask[i & 3] }
            }
            buffer = Data(buffer.dropFirst(idx + maskLen + len))

            switch opcode {
            case 0x0:
                fragments.append(contentsOf: payload)
                if fin { dispatch(opcode: fragmentOpcode, payload: fragments); fragments = Data() }
            case 0x1, 0x2:
                if fin { dispatch(opcode: opcode, payload: Data(payload)) }
                else { fragmentOpcode = opcode; fragments = Data(payload) }
            case 0x8:
                send(opcode: 0x8, payload: Data())
                close()
                return
            case 0x9:
                send(opcode: 0xA, payload: Data(payload))
            default:
                break
            }
        }
    }

    private func dispatch(opcode: UInt8, payload: Data) {
        if opcode == 0x1 { onText?(String(decoding: payload, as: UTF8.self)) } else { onBinary?(payload) }
    }

    func sendText(_ s: String) { send(opcode: 0x1, payload: Data(s.utf8)) }
    func sendBinary(_ d: Data) { send(opcode: 0x2, payload: d) }

    func sendJSON(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj) else { return }
        send(opcode: 0x1, payload: data)
    }

    private func send(opcode: UInt8, payload: Data) {
        var frame = Data(capacity: payload.count + 10)
        frame.append(0x80 | opcode)
        let n = payload.count
        if n < 126 {
            frame.append(UInt8(n))
        } else if n < 65536 {
            frame.append(126); frame.append(UInt8(n >> 8)); frame.append(UInt8(n & 0xFF))
        } else {
            frame.append(127)
            for i in (0..<8).reversed() { frame.append(UInt8((n >> (i * 8)) & 0xFF)) }
        }
        frame.append(payload)
        let size = frame.count
        lock.lock()
        if closed { lock.unlock(); return }
        pending += size
        lock.unlock()
        conn.send(content: frame, completion: .contentProcessed { [weak self] _ in
            guard let self else { return }
            self.lock.lock(); self.pending -= size; self.lock.unlock()
        })
    }

    func close() {
        lock.lock()
        if closed { lock.unlock(); return }
        closed = true
        lock.unlock()
        conn.cancel()
        queue.async { [weak self] in self?.onClose?(); self?.onClose = nil }
    }
}
