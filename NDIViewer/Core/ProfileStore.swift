import Foundation

struct ProfileSource: Codable {
    var name: String
    var host: String
    var label: String
    var ip: String
    var url: String
    var snapshot: String?
}

struct StageProfile: Codable {
    var id: String
    var name: String
    var createdAt: Date
    var updatedAt: Date
    var sources: [ProfileSource]

    var json: [String: Any] {
        let v = Int(updatedAt.timeIntervalSince1970)
        return [
            "id": id, "name": name,
            "createdAt": createdAt.timeIntervalSince1970 * 1000,
            "updatedAt": updatedAt.timeIntervalSince1970 * 1000,
            "sources": sources.map { s -> [String: Any] in
                var d: [String: Any] = ["name": s.name, "host": s.host, "label": s.label, "ip": s.ip, "url": s.url]
                if let snap = s.snapshot { d["snapshot"] = "/snap/\(snap)?v=\(v)" }
                return d
            },
        ]
    }

    /// IPs used as NDI "extra IPs" so a saved stage is found even across subnets.
    var ips: [String] { sources.map(\.ip).filter { !$0.isEmpty } }
}

/// Saved stages live in ~/Library/Application Support/NDIViewer. Not thread-safe: use from the server queue.
final class ProfileStore {
    let directory: URL
    let snapshotDirectory: URL
    private let file: URL
    private(set) var profiles: [StageProfile] = []

    init() {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("NDIViewer", isDirectory: true)
        directory = base
        snapshotDirectory = base.appendingPathComponent("snapshots", isDirectory: true)
        file = base.appendingPathComponent("profiles.json")
        try? FileManager.default.createDirectory(at: snapshotDirectory, withIntermediateDirectories: true)
        load()
    }

    private func load() {
        guard let data = try? Data(contentsOf: file) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        profiles = (try? dec.decode([StageProfile].self, from: data)) ?? []
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? enc.encode(profiles) { try? data.write(to: file, options: .atomic) }
    }

    func profile(_ id: String) -> StageProfile? { profiles.first { $0.id == id } }

    @discardableResult
    func create(name: String, sources: [NDISource]) -> StageProfile {
        let now = Date()
        let p = StageProfile(id: Self.newID(), name: name, createdAt: now, updatedAt: now,
                             sources: sources.map { ProfileSource(name: $0.name, host: $0.host, label: $0.label,
                                                                  ip: $0.displayIP, url: $0.url, snapshot: nil) })
        profiles.insert(p, at: 0)
        save()
        return p
    }

    /// Replaces the source list with what's live now, keeping existing snapshots for sources still present.
    func refresh(id: String, sources: [NDISource]) -> StageProfile? {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return nil }
        let old = Dictionary(profiles[i].sources.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
        profiles[i].sources = sources.map {
            ProfileSource(name: $0.name, host: $0.host, label: $0.label, ip: $0.displayIP, url: $0.url,
                          snapshot: old[$0.name]?.snapshot)
        }
        profiles[i].updatedAt = Date()
        save()
        return profiles[i]
    }

    func rename(id: String, to name: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        profiles[i].name = name
        save()
    }

    func delete(id: String) {
        guard let i = profiles.firstIndex(where: { $0.id == id }) else { return }
        for s in profiles[i].sources { if let f = s.snapshot { try? FileManager.default.removeItem(at: snapshotDirectory.appendingPathComponent(f)) } }
        profiles.remove(at: i)
        save()
    }

    func setSnapshot(id: String, source: String, jpeg: Data) {
        guard let i = profiles.firstIndex(where: { $0.id == id }),
              let j = profiles[i].sources.firstIndex(where: { $0.name == source }) else { return }
        let fileName = profiles[i].sources[j].snapshot ?? "\(id)-\(Self.newID()).jpg"
        try? jpeg.write(to: snapshotDirectory.appendingPathComponent(fileName), options: .atomic)
        profiles[i].sources[j].snapshot = fileName
        profiles[i].updatedAt = Date()
        save()
    }

    func snapshotFile(named name: String) -> URL? {
        guard name.range(of: "^[A-Za-z0-9_-]+\\.jpg$", options: .regularExpression) != nil else { return nil }
        return snapshotDirectory.appendingPathComponent(name)
    }

    static func newID() -> String {
        String(UUID().uuidString.replacingOccurrences(of: "-", with: "").prefix(12)).lowercased()
    }
}
