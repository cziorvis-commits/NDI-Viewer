import Foundation
import CoreVideo

/// One connected web viewer (the popover web view, a Mac browser tab, or a phone).
/// Fields marked "queue" are only touched on ViewerServer.queue; the rest are lock-protected
/// because receiver threads call isReady/deliver*.
final class ClientSession: StreamConsumer {
    enum State: Equatable {
        case active
        case hidden
        case held(String)   // "idle" | "host"

        var name: String {
            switch self { case .active: return "active"; case .hidden: return "hidden"; case .held(let r): return "held-\(r)" }
        }
    }

    let id = ProfileStore.newID()
    let ws: WebSocketConnection
    let ip: String
    let isLocal: Bool
    let connectedAt = Date()

    // queue
    var kind = "browser"
    var device = "Browser"
    var state: State = .active
    var requested: Set<Subscription> = []
    var requestedAudio: String?
    var lastActivity = Date()
    var lastSeen = Date()
    var capped = false
    var viewingProfile: String?

    var wantsFull: Bool { requested.contains { $0.quality == .full } }
    var fullSource: String? { requested.first { $0.quality == .full }?.source }
    var isActive: Bool { state == .active }
    var isPopover: Bool { isLocal && kind == "popover" }

    // lock
    private let lock = NSLock()
    private var deliverable: Set<Subscription> = []
    private var inflight: [Subscription: Int] = [:]
    private var audioSource: String?
    private var sentBytes = 0

    private let maxInflight = 2
    private let videoBackpressure = 3 << 20
    private let audioBackpressure = 1 << 20

    init(ws: WebSocketConnection, isLocal: Bool) {
        self.ws = ws
        self.ip = ws.remoteHost
        self.isLocal = isLocal
    }

    func setDeliverable(_ subs: Set<Subscription>, audio: String?) {
        lock.lock()
        deliverable = subs
        inflight = inflight.filter { subs.contains($0.key) }
        audioSource = audio
        lock.unlock()
    }

    func ack(_ sub: Subscription) {
        lock.lock()
        if let n = inflight[sub] { inflight[sub] = max(0, n - 1) }
        lock.unlock()
    }

    func takeSentBytes() -> Int {
        lock.lock(); defer { lock.unlock() }
        let n = sentBytes; sentBytes = 0
        return n
    }

    // MARK: StreamConsumer

    func isReady(_ sub: Subscription) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return deliverable.contains(sub) && inflight[sub, default: 0] < maxInflight
            && ws.pendingBytes < videoBackpressure
    }

    func deliverJPEG(_ data: Data, sub: Subscription) {
        let name = Data(sub.source.utf8)
        var msg = Data(capacity: 4 + name.count + data.count)
        msg.append(1)
        msg.append(sub.quality.code)
        msg.append(UInt8((name.count >> 8) & 0xFF)); msg.append(UInt8(name.count & 0xFF))
        msg.append(name)
        msg.append(data)
        lock.lock()
        guard deliverable.contains(sub) else { lock.unlock(); return }
        inflight[sub, default: 0] += 1
        sentBytes += msg.count
        lock.unlock()
        ws.sendBinary(msg)
    }

    func deliverAudio(_ chunk: AudioChunk, source: String) {
        lock.lock()
        let wanted = audioSource == source
        lock.unlock()
        guard wanted, ws.pendingBytes < audioBackpressure, chunk.frames > 0 else { return }
        let outCh = min(chunk.channels, 2)
        let name = Data(source.utf8)
        var msg = Data(capacity: 8 + name.count + chunk.frames * outCh * 2)
        msg.append(2)
        let sr = UInt32(chunk.sampleRate)
        msg.append(contentsOf: [UInt8(sr >> 24 & 0xFF), UInt8(sr >> 16 & 0xFF), UInt8(sr >> 8 & 0xFF), UInt8(sr & 0xFF)])
        msg.append(UInt8(outCh))
        msg.append(UInt8((name.count >> 8) & 0xFF)); msg.append(UInt8(name.count & 0xFF))
        msg.append(name)
        var pcm = [Int16](repeating: 0, count: chunk.frames * outCh)
        for c in 0..<outCh {
            let src = chunk.planar[c]
            for i in 0..<chunk.frames {
                let v = max(-1, min(1, src[i]))
                pcm[i * outCh + c] = Int16(v * 32767)
            }
        }
        pcm.withUnsafeBytes { msg.append(contentsOf: $0) }   // little-endian on Apple Silicon/Intel
        lock.lock(); sentBytes += msg.count; lock.unlock()
        ws.sendBinary(msg)
    }

    func deliverLevels(_ peaks: [Float], source: String) {
        guard ws.pendingBytes < videoBackpressure else { return }
        ws.sendJSON(["t": "levels", "s": source, "p": peaks.map { (Double($0) * 1000).rounded() / 1000 }])
    }

    func deliverStats(_ stats: SourceStats, source: String) {
        var j = stats.json
        j["t"] = "stats"
        j["s"] = source
        ws.sendJSON(j)
    }
}
