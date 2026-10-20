import Foundation

extension Notification.Name {
    static let settingsChanged = Notification.Name("NDIViewerSettingsChanged")
}

struct SettingsValues: Codable, Equatable {
    var galleryIdleMinutes: Double = 5
    var fullIdleMinutes: Double = 3
    var remoteFullCap: Int = 2          // 0 = unlimited
    var thumbFPS: Double = 6
    var mediumFPS: Double = 12
    var fullFPS: Double = 25
    var fullMaxWidth: Int = 1280
    var jpegQuality: Double = 0.7
    var extraIPs: String = ""
    var port: Int = 8080
    var popoverSize: String = "medium"
    var recordHeight: Int = 1080        // output is fitted inside this height, never upscaled
    var recordBitrateKbps: Int = 5000
    var recordMic: String = ""          // "" = no audio, "ndi" = the source's own audio, "default" = system default mic, else a device uniqueID

    init() {}

    // Tolerant decoding so new fields never wipe saved settings.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = SettingsValues()
        galleryIdleMinutes = (try? c.decodeIfPresent(Double.self, forKey: .galleryIdleMinutes)) ?? d.galleryIdleMinutes
        fullIdleMinutes = (try? c.decodeIfPresent(Double.self, forKey: .fullIdleMinutes)) ?? d.fullIdleMinutes
        remoteFullCap = (try? c.decodeIfPresent(Int.self, forKey: .remoteFullCap)) ?? d.remoteFullCap
        thumbFPS = (try? c.decodeIfPresent(Double.self, forKey: .thumbFPS)) ?? d.thumbFPS
        mediumFPS = (try? c.decodeIfPresent(Double.self, forKey: .mediumFPS)) ?? d.mediumFPS
        fullFPS = (try? c.decodeIfPresent(Double.self, forKey: .fullFPS)) ?? d.fullFPS
        fullMaxWidth = (try? c.decodeIfPresent(Int.self, forKey: .fullMaxWidth)) ?? d.fullMaxWidth
        jpegQuality = (try? c.decodeIfPresent(Double.self, forKey: .jpegQuality)) ?? d.jpegQuality
        extraIPs = (try? c.decodeIfPresent(String.self, forKey: .extraIPs)) ?? d.extraIPs
        port = (try? c.decodeIfPresent(Int.self, forKey: .port)) ?? d.port
        popoverSize = (try? c.decodeIfPresent(String.self, forKey: .popoverSize)) ?? d.popoverSize
        recordHeight = (try? c.decodeIfPresent(Int.self, forKey: .recordHeight)) ?? d.recordHeight
        recordBitrateKbps = (try? c.decodeIfPresent(Int.self, forKey: .recordBitrateKbps)) ?? d.recordBitrateKbps
        recordMic = (try? c.decodeIfPresent(String.self, forKey: .recordMic)) ?? d.recordMic
    }

    mutating func clamp() {
        galleryIdleMinutes = min(max(galleryIdleMinutes, 0.5), 240)
        fullIdleMinutes = min(max(fullIdleMinutes, 0.5), 240)
        remoteFullCap = min(max(remoteFullCap, 0), 50)
        thumbFPS = min(max(thumbFPS, 1), 30)
        mediumFPS = min(max(mediumFPS, 1), 30)
        fullFPS = min(max(fullFPS, 1), 60)
        fullMaxWidth = min(max(fullMaxWidth, 640), 3840)
        jpegQuality = min(max(jpegQuality, 0.3), 0.95)
        port = min(max(port, 1024), 65000)
        if !["small", "medium", "large"].contains(popoverSize) { popoverSize = "medium" }
        recordHeight = min(max(recordHeight, 360), 2160)
        recordBitrateKbps = min(max(recordBitrateKbps, 500), 100_000)
    }
}

final class AppSettings {
    static let shared = AppSettings()

    private let lock = NSLock()
    private var current: SettingsValues
    private let key = "settings.v1"

    private init() {
        if let data = UserDefaults.standard.data(forKey: key),
           let v = try? JSONDecoder().decode(SettingsValues.self, from: data) {
            current = v
        } else {
            current = SettingsValues()
        }
        current.clamp()
    }

    var values: SettingsValues {
        lock.lock(); defer { lock.unlock() }
        return current
    }

    func update(_ change: (inout SettingsValues) -> Void) {
        lock.lock()
        change(&current)
        current.clamp()
        let v = current
        lock.unlock()
        if let data = try? JSONEncoder().encode(v) {
            UserDefaults.standard.set(data, forKey: key)
        }
        NotificationCenter.default.post(name: .settingsChanged, object: nil)
    }

    /// Merge a partial JSON dictionary (from the web settings panel) into the settings.
    func merge(json: [String: Any]) {
        update { v in
            guard let base = try? JSONEncoder().encode(v),
                  var dict = (try? JSONSerialization.jsonObject(with: base)) as? [String: Any] else { return }
            for (k, value) in json where dict[k] != nil { dict[k] = value }
            if let merged = try? JSONSerialization.data(withJSONObject: dict),
               let nv = try? JSONDecoder().decode(SettingsValues.self, from: merged) {
                v = nv
            }
        }
    }

    var json: [String: Any] {
        guard let data = try? JSONEncoder().encode(values),
              let dict = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        return dict
    }
}
