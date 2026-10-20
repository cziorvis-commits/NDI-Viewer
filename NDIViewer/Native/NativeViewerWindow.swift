import AppKit
import AVFoundation
import CoreMedia
import SwiftUI
import Combine

/// Observable state for the native viewer's overlay.
final class NativeViewerModel: ObservableObject {
    let source: String
    let label: String
    let host: String
    let ip: String
    @Published var stats: SourceStats?
    @Published var levels: [Float] = []
    @Published var audioOn = false
    @Published var showStats = true
    @Published var pinned = false
    @Published var showControls = true
    @Published var recording = false

    init(source: String, ip: String) {
        self.source = source
        let parts = NDISource.split(source)
        label = parts.label
        host = parts.host
        self.ip = ip
    }
}

/// Receives full-quality frames from the hub and renders them on the GPU via AVSampleBufferDisplayLayer.
final class NativeConsumer: StreamConsumer {
    let displayLayer = AVSampleBufferDisplayLayer()
    private weak var model: NativeViewerModel?
    private let renderQueue = DispatchQueue(label: "native.render")
    private let audio = AudioOut()
    private var formatDesc: CMVideoFormatDescription?
    private var lastLevels: CFAbsoluteTime = 0
    private let lock = NSLock()
    private var audioEnabled = false

    init(model: NativeViewerModel) {
        self.model = model
        displayLayer.videoGravity = .resizeAspect
        displayLayer.backgroundColor = NSColor.black.cgColor
    }

    func setAudio(_ on: Bool) {
        lock.lock(); audioEnabled = on; lock.unlock()
        if !on { audio.stop() }
    }

    func isReady(_ sub: Subscription) -> Bool { true }

    func deliverPixelBuffer(_ pb: CVPixelBuffer, source: String) {
        renderQueue.async { [self] in
            if formatDesc == nil || !CMVideoFormatDescriptionMatchesImageBuffer(formatDesc!, imageBuffer: pb) {
                var fd: CMVideoFormatDescription?
                CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pb, formatDescriptionOut: &fd)
                formatDesc = fd
            }
            guard let fd = formatDesc else { return }
            var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
                                            decodeTimeStamp: .invalid)
            var sb: CMSampleBuffer?
            CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pb, formatDescription: fd,
                                                     sampleTiming: &timing, sampleBufferOut: &sb)
            guard let sb else { return }
            if let attachments = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
               CFArrayGetCount(attachments) > 0 {
                let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
                CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                     Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
            }
            let renderer = displayLayer.sampleBufferRenderer
            if renderer.status == .failed { renderer.flush() }
            renderer.enqueue(sb)
        }
    }

    func deliverAudio(_ chunk: AudioChunk, source: String) {
        lock.lock(); let on = audioEnabled; lock.unlock()
        if on { audio.play(chunk) }
    }

    func deliverLevels(_ peaks: [Float], source: String) {
        let now = CFAbsoluteTimeGetCurrent()
        guard now - lastLevels > 1.0 / 20.0 else { return }
        lastLevels = now
        DispatchQueue.main.async { [weak model] in model?.levels = peaks }
    }

    func deliverStats(_ stats: SourceStats, source: String) {
        DispatchQueue.main.async { [weak model] in model?.stats = stats }
    }

    func shutdown() {
        audio.stop()
        renderQueue.async { [displayLayer] in displayLayer.sampleBufferRenderer.flush(removingDisplayedImage: true, completionHandler: nil) }
    }
}

/// Plays NDI float-planar audio through AVAudioEngine, dropping chunks if it falls behind.
final class AudioOut {
    private let lock = NSLock()
    private var engine: AVAudioEngine?
    private var player: AVAudioPlayerNode?
    private var format: AVAudioFormat?
    private var queued = 0

    func play(_ chunk: AudioChunk) {
        lock.lock(); defer { lock.unlock() }
        let ch = min(chunk.channels, 2)
        guard ch > 0 else { return }
        if format == nil || format!.sampleRate != Double(chunk.sampleRate) || format!.channelCount != AVAudioChannelCount(ch) {
            stopLocked()
            guard let f = AVAudioFormat(standardFormatWithSampleRate: Double(chunk.sampleRate), channels: AVAudioChannelCount(ch)) else { return }
            let e = AVAudioEngine(), p = AVAudioPlayerNode()
            e.attach(p)
            e.connect(p, to: e.mainMixerNode, format: f)
            do { try e.start() } catch { return }
            p.play()
            engine = e; player = p; format = f; queued = 0
        }
        guard let player, let format, queued < 8,
              let buf = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(chunk.frames)),
              let dst = buf.floatChannelData else { return }
        buf.frameLength = AVAudioFrameCount(chunk.frames)
        for c in 0..<ch {
            chunk.planar[c].withUnsafeBufferPointer { src in
                dst[c].update(from: src.baseAddress!, count: chunk.frames)
            }
        }
        queued += 1
        player.scheduleBuffer(buf) { [weak self] in
            guard let self else { return }
            self.lock.lock(); self.queued -= 1; self.lock.unlock()
        }
    }

    func stop() {
        lock.lock(); stopLocked(); lock.unlock()
    }

    private func stopLocked() {
        player?.stop()
        engine?.stop()
        engine = nil; player = nil; format = nil; queued = 0
    }
}

final class VideoHostView: NSView {
    init(layer videoLayer: CALayer) {
        super.init(frame: .zero)
        wantsLayer = true
        layer = CALayer()
        layer?.backgroundColor = NSColor.black.cgColor
        videoLayer.frame = bounds
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        layer?.addSublayer(videoLayer)
    }
    required init?(coder: NSCoder) { fatalError() }
}

struct VideoLayerView: NSViewRepresentable {
    let videoLayer: CALayer
    func makeNSView(context: Context) -> VideoHostView { VideoHostView(layer: videoLayer) }
    func updateNSView(_ nsView: VideoHostView, context: Context) {}
}

struct NativeViewerView: View {
    @ObservedObject var model: NativeViewerModel
    let videoLayer: CALayer
    let onAudio: (Bool) -> Void
    let onPin: (Bool) -> Void
    let onRecord: () -> Void

    var body: some View {
        ZStack {
            Color.black
            VideoLayerView(videoLayer: videoLayer)
            if model.stats.map({ $0.connections == 0 || $0.lastFrameAge > 3 }) ?? true {
                Text(model.stats == nil ? "Connecting…" : "No video")
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(.white.opacity(0.7))
                    .padding(.horizontal, 12).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
            }
            VStack(spacing: 0) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(model.label).font(.system(size: 13, weight: .semibold))
                        Text("\(model.host) · \(model.ip.isEmpty ? "—" : model.ip)")
                            .font(.system(size: 11, design: .monospaced)).opacity(0.75)
                    }
                    Spacer()
                    HStack(spacing: 6) {
                        overlayButton(model.recording ? "stop.circle.fill" : "record.circle", help: model.recording ? "Stop recording" : "Record",
                                      tint: model.recording ? .red : nil, action: onRecord)
                        overlayButton(model.audioOn ? "speaker.wave.2.fill" : "speaker.slash", help: "Audio") {
                            model.audioOn.toggle(); onAudio(model.audioOn)
                        }
                        overlayButton("chart.bar.xaxis", help: "Stats", active: model.showStats) { model.showStats.toggle() }
                        overlayButton(model.pinned ? "pin.fill" : "pin", help: "Keep on top", active: model.pinned) {
                            model.pinned.toggle(); onPin(model.pinned)
                        }
                    }
                }
                .padding(10)
                .background(LinearGradient(colors: [.black.opacity(0.65), .clear], startPoint: .top, endPoint: .bottom))
                .opacity(model.showControls || model.recording ? 1 : 0)
                Spacer()
                HStack(alignment: .bottom) {
                    if model.showStats, let s = model.stats { statsView(s) }
                    Spacer()
                }
                .padding(10)
            }
            .foregroundStyle(.white)
            HStack { Spacer(); meters.padding(.trailing, 8).padding(.vertical, 56) }
        }
        .onHover { inside in withAnimation(.easeOut(duration: 0.2)) { model.showControls = inside } }
    }

    private func overlayButton(_ symbol: String, help: String, active: Bool = false, tint: Color? = nil,
                               action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(tint ?? .white)
                .frame(width: 28, height: 24)
                .background(active ? Color.white.opacity(0.25) : Color.white.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .help(help)
    }

    private func statsView(_ s: SourceStats) -> some View {
        let fps = s.nominalFPS > 0 ? String(format: "%.2f%@", s.nominalFPS, s.progressive ? "p" : "i") : "—"
        return VStack(alignment: .leading, spacing: 2) {
            Text("\(s.width)×\(s.height) · \(fps) · \(String(format: "%.1f", s.measuredFPS)) fps")
            Text("Dropped \(s.droppedFrames) / \(s.totalFrames) · Connections \(s.connections)")
            if s.audioChannels > 0 { Text("Audio \(s.audioChannels) ch · \(s.audioSampleRate / 1000) kHz") }
        }
        .font(.system(size: 11, design: .monospaced))
        .padding(8)
        .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
    }

    private var meters: some View {
        HStack(alignment: .bottom, spacing: 3) {
            ForEach(Array(model.levels.prefix(8).enumerated()), id: \.offset) { _, peak in
                GeometryReader { geo in
                    let db = 20 * log10(max(peak, 0.000_001))
                    let frac = CGFloat(max(0, min(1, (db + 60) / 60)))
                    ZStack(alignment: .bottom) {
                        RoundedRectangle(cornerRadius: 2).fill(.white.opacity(0.12))
                        RoundedRectangle(cornerRadius: 2)
                            .fill(db > -3 ? Color.red : db > -12 ? Color.yellow : Color.green)
                            .frame(height: geo.size.height * frac)
                    }
                }
                .frame(width: 5)
            }
        }
        .frame(maxHeight: 220)
    }
}

final class NativeViewerController: NSObject, NSWindowDelegate {
    let source: String
    private let window: NSWindow
    private let model: NativeViewerModel
    private let consumer: NativeConsumer
    var onClose: ((NativeViewerController) -> Void)?
    private var aspectSet = false
    private var statsObserver: Any?
    private var recordingObserver: Any?

    init(source: String, ip: String) {
        self.source = source
        model = NativeViewerModel(source: source, ip: ip)
        consumer = NativeConsumer(model: model)
        window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 960, height: 540),
                          styleMask: [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView],
                          backing: .buffered, defer: false)
        super.init()
        window.title = model.label
        window.subtitle = model.host
        window.titlebarAppearsTransparent = true
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.contentAspectRatio = NSSize(width: 16, height: 9)
        window.collectionBehavior = [.fullScreenPrimary, .moveToActiveSpace]
        window.delegate = self
        let view = NativeViewerView(model: model, videoLayer: consumer.displayLayer,
                                    onAudio: { [weak self] on in self?.setAudio(on) },
                                    onPin: { [weak self] on in self?.window.level = on ? .floating : .normal },
                                    onRecord: { RecordingManager.shared.toggle(source) })
        window.contentView = NSHostingView(rootView: view)
        window.setFrameAutosaveName("NDIViewer.native.\(source)")
        if !window.setFrameUsingName("NDIViewer.native.\(source)") { window.center() }

        statsObserver = model.$stats.sink { [weak self] s in
            guard let self, let s, !self.aspectSet, s.width > 0, s.height > 0 else { return }
            self.aspectSet = true
            self.window.contentAspectRatio = NSSize(width: s.width, height: s.height)
        }
        model.recording = RecordingManager.shared.isRecording(source)
        recordingObserver = NotificationCenter.default.addObserver(forName: .recordingsChanged, object: nil, queue: .main) { [weak self] _ in
            guard let self else { return }
            self.model.recording = RecordingManager.shared.isRecording(self.source)
        }
    }

    func show() {
        ReceiverHub.shared.setSubscriptions(consumer, [Subscription(source: source, quality: .native)], audio: nil)
        ViewerServer.shared.nativeViewerOpened()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    func focus() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func setAudio(_ on: Bool) {
        consumer.setAudio(on)
        ReceiverHub.shared.setSubscriptions(consumer, [Subscription(source: source, quality: .native)], audio: on ? source : nil)
    }

    func windowWillClose(_ notification: Notification) {
        if let recordingObserver { NotificationCenter.default.removeObserver(recordingObserver) }
        ReceiverHub.shared.remove(consumer)
        consumer.shutdown()
        ViewerServer.shared.nativeViewerClosed()
        onClose?(self)
    }
}
