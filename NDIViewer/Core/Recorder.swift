import Foundation
import AVFoundation
import CoreMedia
import CoreVideo

extension Notification.Name {
    static let recordingsChanged = Notification.Name("NDIViewerRecordingsChanged")
    /// object: the finished file URL (nil on failure); userInfo["error"]: String on failure.
    static let recordingFinished = Notification.Name("NDIViewerRecordingFinished")
}

struct Microphone {
    let id: String
    let name: String
    var json: [String: Any] { ["id": id, "name": name] }
}

/// Records one NDI source to an H.264/AAC MP4. Video comes from the hub's native pixel buffers;
/// audio comes from the source itself, a local microphone, or nothing. Everything is stamped on the host clock.
final class Recorder: NSObject, StreamConsumer, AVCaptureAudioDataOutputSampleBufferDelegate {
    let source: String
    let url: URL
    let startedAt = Date()

    private let maxHeight: Int
    private let bitrate: Int
    private let micID: String
    private let writeQueue = DispatchQueue(label: "ndi.recorder")

    // writeQueue
    private var writer: AVAssetWriter?
    private var videoInput: AVAssetWriterInput?
    private var audioInput: AVAssetWriterInput?
    private var adaptor: AVAssetWriterInputPixelBufferAdaptor?
    private var sessionStart: CMTime?
    private var lastVideoPTS = CMTime.invalid
    private var finishing = false
    private var failure: String?
    private var ndiAudioFormat: CMAudioFormatDescription?
    private var ndiAudioRate = 0
    private var nextNDIAudioPTS = CMTime.invalid

    private var usesNDIAudio: Bool { micID == "ndi" }
    private var hasAudio: Bool { usesNDIAudio || capture != nil }

    private var capture: AVCaptureSession?

    init(source: String, url: URL, settings: SettingsValues) {
        self.source = source
        self.url = url
        maxHeight = settings.recordHeight
        bitrate = settings.recordBitrateKbps * 1000
        micID = settings.recordMic
    }

    func start() {
        if !micID.isEmpty && !usesNDIAudio { startMic() }
        ReceiverHub.shared.setSubscriptions(self, [Subscription(source: source, quality: .native)],
                                            audio: usesNDIAudio ? source : nil)
    }

    /// Stops capture and finalizes the file. `completion` runs on an arbitrary queue.
    func stop(completion: @escaping (URL?, String?) -> Void) {
        ReceiverHub.shared.remove(self)
        capture?.stopRunning()
        capture = nil
        writeQueue.async { [self] in
            finishing = true
            guard let writer, writer.status == .writing else {
                writer?.cancelWriting()
                try? FileManager.default.removeItem(at: url)
                completion(nil, failure ?? "No video was received from the source")
                return
            }
            videoInput?.markAsFinished()
            audioInput?.markAsFinished()
            if lastVideoPTS.isValid { writer.endSession(atSourceTime: lastVideoPTS) }
            writer.finishWriting { [self] in
                if writer.status == .completed { completion(url, nil) }
                else { completion(nil, writer.error?.localizedDescription ?? "Recording failed") }
            }
        }
    }

    // MARK: Microphone

    private func startMic() {
        let device = micID == "default"
            ? AVCaptureDevice.default(for: .audio)
            : AVCaptureDevice(uniqueID: micID)
        guard let device, let input = try? AVCaptureDeviceInput(device: device) else {
            NSLog("Recorder: microphone \(micID) unavailable, recording without audio")
            return
        }
        let session = AVCaptureSession()
        let output = AVCaptureAudioDataOutput()
        // Deliver 48 kHz stereo float so the AAC encoder never has to guess the layout.
        output.audioSettings = [
            AVFormatIDKey: kAudioFormatLinearPCM,
            AVSampleRateKey: 48_000,
            AVNumberOfChannelsKey: 2,
            AVLinearPCMBitDepthKey: 32,
            AVLinearPCMIsFloatKey: true,
            AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false,
        ]
        output.setSampleBufferDelegate(self, queue: writeQueue)
        guard session.canAddInput(input), session.canAddOutput(output) else { return }
        session.addInput(input)
        session.addOutput(output)
        capture = session
        session.startRunning()
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard !finishing, let start = sessionStart, let audioInput, audioInput.isReadyForMoreMediaData,
              let clock = capture?.synchronizationClock else { return }
        let pts = CMSyncConvertTime(CMSampleBufferGetPresentationTimeStamp(sampleBuffer),
                                    from: clock, to: CMClockGetHostTimeClock())
        guard pts >= start else { return }
        var timing = CMSampleTimingInfo(duration: CMSampleBufferGetDuration(sampleBuffer),
                                        presentationTimeStamp: pts, decodeTimeStamp: .invalid)
        var retimed: CMSampleBuffer?
        CMSampleBufferCreateCopyWithNewTiming(allocator: nil, sampleBuffer: sampleBuffer, sampleTimingEntryCount: 1,
                                              sampleTimingArray: &timing, sampleBufferOut: &retimed)
        if let retimed { audioInput.append(retimed) }
    }

    // MARK: NDI source audio

    func deliverAudio(_ chunk: AudioChunk, source: String) {
        let now = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.async { [self] in appendNDIAudio(chunk, arrival: now) }
    }

    /// Writes NDI float-planar audio as interleaved stereo. Timestamps run on continuously from the
    /// first chunk so the AAC track has no gaps, and resync to the host clock if they drift.
    private func appendNDIAudio(_ chunk: AudioChunk, arrival: CMTime) {
        guard !finishing, let start = sessionStart, let audioInput, audioInput.isReadyForMoreMediaData,
              chunk.channels > 0, chunk.frames > 0, chunk.sampleRate > 0 else { return }
        if ndiAudioFormat == nil || ndiAudioRate != chunk.sampleRate {
            var asbd = AudioStreamBasicDescription(
                mSampleRate: Double(chunk.sampleRate), mFormatID: kAudioFormatLinearPCM,
                mFormatFlags: kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked,
                mBytesPerPacket: 8, mFramesPerPacket: 1, mBytesPerFrame: 8, mChannelsPerFrame: 2,
                mBitsPerChannel: 32, mReserved: 0)
            var fd: CMAudioFormatDescription?
            CMAudioFormatDescriptionCreate(allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil,
                                           magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &fd)
            ndiAudioFormat = fd
            ndiAudioRate = chunk.sampleRate
            nextNDIAudioPTS = .invalid
        }
        guard let format = ndiAudioFormat else { return }

        let duration = CMTime(value: CMTimeValue(chunk.frames), timescale: CMTimeScale(chunk.sampleRate))
        let estimated = CMTimeSubtract(arrival, duration)
        var pts = nextNDIAudioPTS
        if !pts.isValid || abs(CMTimeGetSeconds(CMTimeSubtract(pts, estimated))) > 0.1 {
            pts = CMTimeConvertScale(estimated, timescale: CMTimeScale(chunk.sampleRate), method: .roundHalfAwayFromZero)
        }
        nextNDIAudioPTS = CMTimeAdd(pts, duration)
        guard pts >= start else { return }

        // Mono is duplicated to both channels; anything past stereo is dropped.
        let left = chunk.planar[0], right = chunk.planar[min(1, chunk.channels - 1)]
        var pcm = [Float](repeating: 0, count: chunk.frames * 2)
        for i in 0..<chunk.frames {
            pcm[i * 2] = left[i]
            pcm[i * 2 + 1] = right[i]
        }
        let bytes = pcm.count * MemoryLayout<Float>.size
        var block: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: nil, memoryBlock: nil, blockLength: bytes,
                                                 blockAllocator: nil, customBlockSource: nil, offsetToData: 0,
                                                 dataLength: bytes, flags: 0, blockBufferOut: &block) == noErr,
              let block else { return }
        pcm.withUnsafeBytes { _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                                               offsetIntoDestination: 0, dataLength: bytes) }
        var sb: CMSampleBuffer?
        CMAudioSampleBufferCreateReadyWithPacketDescriptions(allocator: nil, dataBuffer: block, formatDescription: format,
                                                             sampleCount: chunk.frames, presentationTimeStamp: pts,
                                                             packetDescriptions: nil, sampleBufferOut: &sb)
        if let sb { audioInput.append(sb) }
    }

    // MARK: StreamConsumer

    func isReady(_ sub: Subscription) -> Bool { true }

    func deliverPixelBuffer(_ pb: CVPixelBuffer, source: String) {
        let pts = CMClockGetTime(CMClockGetHostTimeClock())
        writeQueue.async { [self] in
            guard !finishing else { return }
            if writer == nil { setupWriter(width: CVPixelBufferGetWidth(pb), height: CVPixelBufferGetHeight(pb), at: pts) }
            guard let writer, writer.status == .writing, let videoInput, let adaptor else {
                if let writer, writer.status == .failed, failure == nil {
                    failure = writer.error?.localizedDescription ?? "Writer failed"
                    NSLog("Recorder: \(failure!)")
                }
                return
            }
            // Drop frames the encoder can't take rather than queueing them up.
            guard videoInput.isReadyForMoreMediaData, !lastVideoPTS.isValid || pts > lastVideoPTS else { return }
            if adaptor.append(pb, withPresentationTime: pts) { lastVideoPTS = pts }
        }
    }

    private func setupWriter(width: Int, height: Int, at start: CMTime) {
        // Fit inside the target height, keep the source aspect, never upscale, keep dimensions even.
        let outH = min(height, maxHeight) & ~1
        let outW = max(2, Int((Double(width) * Double(outH) / Double(height)).rounded()) & ~1)
        do {
            try? FileManager.default.removeItem(at: url)
            let w = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let video = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: outW,
                AVVideoHeightKey: outH,
                AVVideoScalingModeKey: AVVideoScalingModeResizeAspect,
                AVVideoCompressionPropertiesKey: [
                    AVVideoAverageBitRateKey: bitrate,
                    AVVideoProfileLevelKey: AVVideoProfileLevelH264HighAutoLevel,
                    AVVideoMaxKeyFrameIntervalDurationKey: 2,
                    AVVideoAllowFrameReorderingKey: false,
                ] as [String: Any],
            ])
            video.expectsMediaDataInRealTime = true
            let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: video, sourcePixelBufferAttributes: nil)
            guard w.canAdd(video) else { throw RecorderError("Can't add video track") }
            w.add(video)
            if hasAudio {
                let audio = AVAssetWriterInput(mediaType: .audio, outputSettings: [
                    AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000,
                    AVNumberOfChannelsKey: 2,
                    AVEncoderBitRateKey: 192_000,
                ])
                audio.expectsMediaDataInRealTime = true
                if w.canAdd(audio) { w.add(audio); audioInput = audio }
            }
            guard w.startWriting() else { throw w.error ?? RecorderError("Couldn't start writing") }
            w.startSession(atSourceTime: start)
            writer = w; videoInput = video; self.adaptor = adaptor; sessionStart = start
        } catch {
            failure = error.localizedDescription
            NSLog("Recorder: \(error)")
            finishing = true
        }
    }
}

private struct RecorderError: LocalizedError {
    let errorDescription: String?
    init(_ message: String) { errorDescription = message }
}

/// Tracks the active recordings (at most one per source).
final class RecordingManager {
    static let shared = RecordingManager()

    private let lock = NSLock()
    private var recorders: [String: Recorder] = [:]

    static var folder: URL {
        FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NDI-Viewer", isDirectory: true)
    }

    static func microphones() -> [Microphone] {
        AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified)
            .devices.map { Microphone(id: $0.uniqueID, name: $0.localizedName) }
    }

    func isRecording(_ source: String) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return recorders[source] != nil
    }

    var json: [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return recorders.values.map { ["s": $0.source, "since": $0.startedAt.timeIntervalSince1970 * 1000] }
    }

    var activeCount: Int {
        lock.lock(); defer { lock.unlock() }
        return recorders.count
    }

    func toggle(_ source: String) {
        isRecording(source) ? stop(source) : start(source)
    }

    func start(_ source: String) {
        let settings = AppSettings.shared.values
        let begin = { [self] in
            lock.lock()
            guard recorders[source] == nil else { lock.unlock(); return }
            let r = Recorder(source: source, url: Self.fileURL(for: source), settings: settings)
            recorders[source] = r
            lock.unlock()
            r.start()
            NotificationCenter.default.post(name: .recordingsChanged, object: nil)
        }
        guard !settings.recordMic.isEmpty, settings.recordMic != "ndi", AVCaptureDevice.authorizationStatus(for: .audio) == .notDetermined else {
            begin(); return
        }
        AVCaptureDevice.requestAccess(for: .audio) { _ in begin() }
    }

    func stop(_ source: String) {
        lock.lock()
        let r = recorders.removeValue(forKey: source)
        lock.unlock()
        guard let r else { return }
        NotificationCenter.default.post(name: .recordingsChanged, object: nil)
        r.stop { url, error in
            NotificationCenter.default.post(name: .recordingFinished, object: url,
                                            userInfo: error.map { ["error": $0, "source": source] } ?? ["source": source])
        }
    }

    /// Finalizes every recording, waiting up to `timeout` seconds. Used at quit so files stay playable.
    func stopAll(timeout: Double) {
        lock.lock()
        let all = Array(recorders.values)
        recorders.removeAll()
        lock.unlock()
        let group = DispatchGroup()
        for r in all {
            group.enter()
            r.stop { _, _ in group.leave() }
        }
        _ = group.wait(timeout: .now() + timeout)
    }

    private static func fileURL(for source: String) -> URL {
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH-mm-ss"
        let label = NDISource.split(source).label
            .components(separatedBy: CharacterSet(charactersIn: "/:\\")).joined(separator: "-")
        return folder.appendingPathComponent("\(label) \(f.string(from: Date())).mp4")
    }
}
