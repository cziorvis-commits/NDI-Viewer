import Foundation
import CoreVideo

enum StreamQuality: String {
    case thumb, medium, full, native

    var code: UInt8 {
        switch self { case .thumb: return 0; case .medium: return 1; case .full: return 2; case .native: return 3 }
    }
    /// Thumbnails use NDI's low-bandwidth proxy; everything else pulls full bandwidth.
    var usesHighBandwidth: Bool { self != .thumb }
}

struct Subscription: Hashable {
    let source: String
    let quality: StreamQuality
}

struct SourceStats {
    var width = 0, height = 0
    var nominalFPS: Double = 0
    var measuredFPS: Double = 0
    var progressive = true
    var totalFrames: Int64 = 0
    var droppedFrames: Int64 = 0
    var connections = 0
    var audioChannels = 0
    var audioSampleRate = 0
    var lastFrameAge: Double = 0

    var json: [String: Any] {
        ["w": width, "h": height, "fps": nominalFPS, "mfps": measuredFPS, "prog": progressive,
         "frames": totalFrames, "dropped": droppedFrames, "conns": connections,
         "ach": audioChannels, "asr": audioSampleRate, "age": lastFrameAge]
    }
}

struct AudioChunk {
    let sampleRate: Int
    let frames: Int
    let planar: [[Float]]
    var channels: Int { planar.count }
}

protocol StreamConsumer: AnyObject {
    func isReady(_ sub: Subscription) -> Bool
    func deliverJPEG(_ data: Data, sub: Subscription)
    func deliverPixelBuffer(_ pb: CVPixelBuffer, source: String)
    func deliverAudio(_ chunk: AudioChunk, source: String)
    func deliverLevels(_ peaks: [Float], source: String)
    func deliverStats(_ stats: SourceStats, source: String)
}

extension StreamConsumer {
    func deliverJPEG(_ data: Data, sub: Subscription) {}
    func deliverPixelBuffer(_ pb: CVPixelBuffer, source: String) {}
    func deliverAudio(_ chunk: AudioChunk, source: String) {}
    func deliverLevels(_ peaks: [Float], source: String) {}
    func deliverStats(_ stats: SourceStats, source: String) {}
}

struct ReceiverKey: Hashable {
    let source: String
    let high: Bool
}

/// Owns every NDI receiver. A receiver exists only while at least one consumer needs it,
/// and lingers for a short grace period so scrolling/back-and-forth doesn't reconnect.
final class ReceiverHub {
    static let shared = ReceiverHub()

    private struct Entry {
        weak var consumer: StreamConsumer?
        var subs: Set<Subscription>
        var audio: String?
    }

    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]
    private var receivers: [ReceiverKey: Receiver] = [:]
    private var teardown: [ReceiverKey: DispatchWorkItem] = [:]
    private var urls: [String: String] = [:]
    private var latest: [String: (data: Data, time: CFAbsoluteTime)] = [:]
    private var grabs: [String: [UUID: (Data?) -> Void]] = [:]
    private let timerQueue = DispatchQueue(label: "ndi.hub.timers")
    private let graceSeconds = 5.0

    // MARK: Subscriptions

    func setSubscriptions(_ consumer: StreamConsumer, _ subs: Set<Subscription>, audio: String?) {
        lock.lock()
        let id = ObjectIdentifier(consumer)
        if subs.isEmpty && audio == nil {
            entries[id] = nil
        } else {
            entries[id] = Entry(consumer: consumer, subs: subs, audio: audio)
        }
        reconcileLocked()
        lock.unlock()
    }

    func remove(_ consumer: StreamConsumer) {
        setSubscriptions(consumer, [], audio: nil)
    }

    func updateKnownSources(_ list: [NDISource]) {
        lock.lock()
        for s in list { urls[s.name] = s.url }
        lock.unlock()
    }

    func url(for source: String) -> String? {
        lock.lock(); defer { lock.unlock() }
        return urls[source]
    }

    var activeReceiverCount: Int {
        lock.lock(); defer { lock.unlock() }
        return receivers.count
    }

    func stopAll() {
        lock.lock()
        entries.removeAll()
        grabs.removeAll()
        teardown.values.forEach { $0.cancel() }
        teardown.removeAll()
        let all = Array(receivers.values)
        receivers.removeAll()
        lock.unlock()
        all.forEach { $0.stop() }
    }

    // MARK: Lookups used by receiver threads

    func consumers(_ sub: Subscription) -> [StreamConsumer] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.compactMap { $0.subs.contains(sub) ? $0.consumer : nil }
    }

    func audioConsumers(_ source: String) -> [StreamConsumer] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.compactMap { $0.audio == source ? $0.consumer : nil }
    }

    /// Consumers watching a source in a full view (stats + meters go to these).
    func monitorConsumers(_ source: String) -> [StreamConsumer] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.compactMap { e in
            e.subs.contains { $0.source == source && ($0.quality == .full || $0.quality == .native) }
                ? e.consumer : nil
        }
    }

    func ownsAudio(_ key: ReceiverKey) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return key.high || receivers[ReceiverKey(source: key.source, high: true)] == nil
    }

    // MARK: Snapshots

    func storeLatest(_ data: Data, source: String) {
        lock.lock()
        latest[source] = (data, CFAbsoluteTimeGetCurrent())
        lock.unlock()
    }

    func latestJPEG(_ source: String, maxAge: Double) -> Data? {
        lock.lock(); defer { lock.unlock() }
        guard let l = latest[source], CFAbsoluteTimeGetCurrent() - l.time <= maxAge else { return nil }
        return l.data
    }

    /// Grabs one frame from a source, spinning up a low-bandwidth receiver if needed.
    func grabFrame(_ source: String, timeout: Double, completion: @escaping (Data?) -> Void) {
        if let recent = latestJPEG(source, maxAge: 5) { completion(recent); return }
        let id = UUID()
        lock.lock()
        grabs[source, default: [:]][id] = completion
        reconcileLocked()
        lock.unlock()
        timerQueue.asyncAfter(deadline: .now() + timeout) { [weak self] in
            guard let self else { return }
            self.lock.lock()
            let cb = self.grabs[source]?.removeValue(forKey: id)
            if self.grabs[source]?.isEmpty == true { self.grabs[source] = nil }
            self.reconcileLocked()
            self.lock.unlock()
            cb?(nil)
        }
    }

    func hasGrabs(_ source: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return !(grabs[source]?.isEmpty ?? true)
    }

    func takeGrabs(_ source: String) -> [(Data?) -> Void] {
        lock.lock()
        let cbs = grabs.removeValue(forKey: source).map { Array($0.values) } ?? []
        if !cbs.isEmpty { reconcileLocked() }
        lock.unlock()
        return cbs
    }

    // MARK: Receiver lifecycle

    private func neededKeysLocked() -> Set<ReceiverKey> {
        entries = entries.filter { $0.value.consumer != nil }
        var keys = Set<ReceiverKey>()
        for e in entries.values {
            for s in e.subs { keys.insert(ReceiverKey(source: s.source, high: s.quality.usesHighBandwidth)) }
        }
        for e in entries.values {
            if let a = e.audio, !keys.contains(where: { $0.source == a }) {
                keys.insert(ReceiverKey(source: a, high: true))
            }
        }
        for (src, g) in grabs where !g.isEmpty && !keys.contains(where: { $0.source == src }) {
            keys.insert(ReceiverKey(source: src, high: false))
        }
        return keys
    }

    private func reconcileLocked() {
        let needed = neededKeysLocked()
        for k in needed {
            teardown.removeValue(forKey: k)?.cancel()
            if receivers[k] == nil {
                let r = Receiver(key: k, hub: self)
                receivers[k] = r
                r.start()
            }
        }
        for k in receivers.keys where !needed.contains(k) && teardown[k] == nil {
            let work = DispatchWorkItem { [weak self] in self?.finishTeardown(k) }
            teardown[k] = work
            timerQueue.asyncAfter(deadline: .now() + graceSeconds, execute: work)
        }
    }

    private func finishTeardown(_ k: ReceiverKey) {
        lock.lock()
        teardown[k] = nil
        var r: Receiver?
        if !neededKeysLocked().contains(k) { r = receivers.removeValue(forKey: k) }
        lock.unlock()
        r?.stop()
    }
}

/// One NDI receiver on its own capture thread.
final class Receiver {
    let key: ReceiverKey
    private weak var hub: ReceiverHub?
    private let stopLock = NSLock()
    private var stopped = false

    private var nextDue: [StreamQuality: CFAbsoluteTime] = [:]
    private var lastLevels: CFAbsoluteTime = 0
    private var stats = SourceStats()
    private var lastStatsTime = CFAbsoluteTimeGetCurrent()
    private var lastStatsFrames: Int64 = 0
    private var lastFrameTime: CFAbsoluteTime = 0
    private let pixelMaker = PixelBufferMaker()

    init(key: ReceiverKey, hub: ReceiverHub) {
        self.key = key
        self.hub = hub
    }

    func start() {
        let t = Thread { [self] in run() }
        t.name = "ndi.recv.\(key.high ? "hi" : "lo")"
        t.qualityOfService = .userInitiated
        t.start()
    }

    func stop() {
        stopLock.lock(); stopped = true; stopLock.unlock()
    }

    private var isStopped: Bool {
        stopLock.lock(); defer { stopLock.unlock() }
        return stopped
    }

    private func run() {
        guard NDILib.isReady, let hub else { return }
        let source = key.source
        let url = hub.url(for: source) ?? ""
        let recvName = "NDI-Viewer (\(key.high ? "monitor" : "preview"))"

        var create = NDIlib_recv_create_v3_t()
        create.color_format = NDIlib_recv_color_format_BGRX_BGRA
        create.bandwidth = key.high ? NDIlib_recv_bandwidth_highest : NDIlib_recv_bandwidth_lowest
        create.allow_video_fields = false

        let recv: NDIlib_recv_instance_t? = source.withCString { pName in
            url.withCString { pURL in
                recvName.withCString { pRecv in
                    create.source_to_connect_to.p_ndi_name = pName
                    if !url.isEmpty { create.source_to_connect_to.p_url_address = pURL }
                    create.p_ndi_recv_name = pRecv
                    return NDIlib_recv_create_v3(&create)
                }
            }
        }
        guard let recv else { return }
        defer { NDIlib_recv_destroy(recv) }

        while !isStopped {
            var video = NDIlib_video_frame_v2_t()
            var audio = NDIlib_audio_frame_v2_t()
            let type = NDIlib_recv_capture_v2(recv, &video, &audio, nil, 200)
            if type == NDIlib_frame_type_video {
                handleVideo(video)
                NDIlib_recv_free_video_v2(recv, &video)
            } else if type == NDIlib_frame_type_audio {
                handleAudio(audio)
                NDIlib_recv_free_audio_v2(recv, &audio)
            }
            let now = CFAbsoluteTimeGetCurrent()
            if now - lastStatsTime >= 1.0 { publishStats(recv, now: now) }
        }
    }

    private func targetWidth(_ q: StreamQuality, _ s: SettingsValues) -> Int {
        switch q {
        case .thumb: return 480
        case .medium: return 960
        case .full, .native: return s.fullMaxWidth
        }
    }

    private func fps(_ q: StreamQuality, _ s: SettingsValues) -> Double {
        switch q {
        case .thumb: return s.thumbFPS
        case .medium: return s.mediumFPS
        case .full, .native: return s.fullFPS
        }
    }

    private func handleVideo(_ f: NDIlib_video_frame_v2_t) {
        guard let hub else { return }
        let now = CFAbsoluteTimeGetCurrent()
        lastFrameTime = now
        stats.width = Int(f.xres); stats.height = Int(f.yres)
        stats.nominalFPS = f.frame_rate_D > 0 ? Double(f.frame_rate_N) / Double(f.frame_rate_D) : 0
        stats.progressive = f.frame_format_type == NDIlib_frame_format_type_progressive

        let settings = AppSettings.shared.values
        let source = key.source
        var encodedThisFrame: Data?
        let qualities: [StreamQuality] = key.high ? [.medium, .full, .native] : [.thumb]

        for q in qualities {
            let sub = Subscription(source: source, quality: q)
            let cons = hub.consumers(sub)
            if cons.isEmpty { continue }
            if q == .native {
                if let pb = pixelMaker.make(from: f) { cons.forEach { $0.deliverPixelBuffer(pb, source: source) } }
                continue
            }
            // Deadline scheduling keeps the average rate on target even when it doesn't divide the source rate.
            let interval = 1.0 / fps(q, settings)
            let due = nextDue[q] ?? 0
            if now < due - 0.004 { continue }
            let ready = cons.filter { $0.isReady(sub) }
            if ready.isEmpty { continue }
            guard let jpeg = FrameImaging.jpeg(from: f, maxWidth: targetWidth(q, settings), quality: settings.jpegQuality)
            else { continue }
            nextDue[q] = max(due + interval, now - interval)
            if q != .full || encodedThisFrame == nil { encodedThisFrame = jpeg }
            ready.forEach { $0.deliverJPEG(jpeg, sub: sub) }
        }

        if hub.hasGrabs(source) {
            let jpeg = encodedThisFrame ?? FrameImaging.jpeg(from: f, maxWidth: 640, quality: 0.75)
            hub.takeGrabs(source).forEach { $0(jpeg) }
            if let jpeg { hub.storeLatest(jpeg, source: source) }
        } else if let e = encodedThisFrame, !key.high || now - (hub.latestTime(source) ?? 0) > 2 {
            hub.storeLatest(e, source: source)
        }
    }

    private func handleAudio(_ a: NDIlib_audio_frame_v2_t) {
        guard let hub, let data = a.p_data, a.no_channels > 0, a.no_samples > 0 else { return }
        stats.audioChannels = Int(a.no_channels)
        stats.audioSampleRate = Int(a.sample_rate)
        guard hub.ownsAudio(key) else { return }

        let source = key.source
        let channels = Int(a.no_channels), frames = Int(a.no_samples)
        let strideFloats = Int(a.channel_stride_in_bytes) / MemoryLayout<Float>.size
        let now = CFAbsoluteTimeGetCurrent()

        if now - lastLevels >= 1.0 / 15.0 {
            let monitors = hub.monitorConsumers(source)
            if !monitors.isEmpty {
                lastLevels = now
                var peaks = [Float](repeating: 0, count: channels)
                for c in 0..<channels {
                    let p = data + c * strideFloats
                    var m: Float = 0
                    for i in 0..<frames { m = max(m, abs(p[i])) }
                    peaks[c] = m
                }
                monitors.forEach { $0.deliverLevels(peaks, source: source) }
            }
        }

        let listeners = hub.audioConsumers(source)
        if !listeners.isEmpty {
            var planar: [[Float]] = []
            planar.reserveCapacity(channels)
            for c in 0..<channels {
                planar.append(Array(UnsafeBufferPointer(start: data + c * strideFloats, count: frames)))
            }
            let chunk = AudioChunk(sampleRate: Int(a.sample_rate), frames: frames, planar: planar)
            listeners.forEach { $0.deliverAudio(chunk, source: source) }
        }
    }

    private func publishStats(_ recv: NDIlib_recv_instance_t, now: CFAbsoluteTime) {
        var total = NDIlib_recv_performance_t()
        var dropped = NDIlib_recv_performance_t()
        NDIlib_recv_get_performance(recv, &total, &dropped)
        let dt = now - lastStatsTime
        stats.measuredFPS = dt > 0 ? Double(total.video_frames - lastStatsFrames) / dt : 0
        stats.totalFrames = total.video_frames
        stats.droppedFrames = dropped.video_frames
        stats.connections = Int(NDIlib_recv_get_no_connections(recv))
        stats.lastFrameAge = lastFrameTime > 0 ? now - lastFrameTime : -1
        lastStatsFrames = total.video_frames
        lastStatsTime = now
        guard key.high, let hub else { return }
        let s = stats
        hub.monitorConsumers(key.source).forEach { $0.deliverStats(s, source: key.source) }
    }
}

extension ReceiverHub {
    func latestTime(_ source: String) -> CFAbsoluteTime? {
        lock.lock(); defer { lock.unlock() }
        return latest[source]?.time
    }
}
