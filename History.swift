// History.swift — stores 24/7 recordings (rolling, size-capped), each visit at the
// door (with its thumbnail, description and protected video), and daily summaries.
import Cocoa
import AVFoundation

struct Visit: Codable, Identifiable, Hashable {
    var id: String
    var time: Date
    var endTime: Date
    var kinds: [String]              // "Doorbell ring", "Person", "Motion", "Sound", …
    var headline: String?
    var details: String?
    var tags: [String] = []          // e.g. "1 person", "Package", "Dog", "UPS", "Knocking"
    var people: Int = 0
    var faceIds: [String] = []
    var names: [String] = []
    var sounds: [String] = []
    var package: Bool = false
    var thumbnail: String?           // file name in Thumbnails/
    var clips: [String] = []         // file names in Event Clips/
    var analyzed: Bool = false
    var noVideo: String?             // why there's no recording of this visit, if there isn't one

    init(id: String, time: Date, endTime: Date, kinds: [String]) {
        self.id = id; self.time = time; self.endTime = endTime; self.kinds = kinds
    }

    // Tolerates index files written by older or newer versions (missing fields get defaults).
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        time = try c.decode(Date.self, forKey: .time)
        endTime = try c.decodeIfPresent(Date.self, forKey: .endTime) ?? time
        kinds = try c.decodeIfPresent([String].self, forKey: .kinds) ?? []
        headline = try c.decodeIfPresent(String.self, forKey: .headline)
        details = try c.decodeIfPresent(String.self, forKey: .details)
        tags = try c.decodeIfPresent([String].self, forKey: .tags) ?? []
        people = try c.decodeIfPresent(Int.self, forKey: .people) ?? 0
        faceIds = try c.decodeIfPresent([String].self, forKey: .faceIds) ?? []
        names = try c.decodeIfPresent([String].self, forKey: .names) ?? []
        sounds = try c.decodeIfPresent([String].self, forKey: .sounds) ?? []
        package = try c.decodeIfPresent(Bool.self, forKey: .package) ?? false
        thumbnail = try c.decodeIfPresent(String.self, forKey: .thumbnail)
        clips = try c.decodeIfPresent([String].self, forKey: .clips) ?? []
        analyzed = try c.decodeIfPresent(Bool.self, forKey: .analyzed) ?? false
        noVideo = try c.decodeIfPresent(String.self, forKey: .noVideo)
    }

    var mainKind: String {
        if kinds.contains("Doorbell ring") { return "Doorbell ring" }
        if package { return "Package" }
        if kinds.contains("Person") { return "Person" }
        return kinds.first ?? "Motion"
    }
    var title: String { headline ?? defaultTitle }
    var defaultTitle: String {
        if !names.isEmpty { return names.joined(separator: " & ") + (kinds.contains("Doorbell ring") ? " rang the doorbell" : " at the door") }
        switch mainKind {
        case "Doorbell ring": return "Someone rang the doorbell"
        case "Package": return "Package at the door"
        case "Person": return "Person at the door"
        case "Sound": return sounds.first.map { "Sound: \($0)" } ?? "Sound detected"
        default: return mainKind + " at the front door"
        }
    }
}

struct DaySummary: Codable {
    var day: String       // yyyy-MM-dd
    var text: String
    var created: Date
}

// A stretch of footage joined into one timeline, with a way back from player time to clock time.
struct Playback {
    struct Piece { let start: Date; let offset: Double; let duration: Double }
    let player: AVPlayer
    let pieces: [Piece]
    var end: Date? { pieces.last.map { $0.start.addingTimeInterval($0.duration) } }
    func date(at t: Double) -> Date? {
        for p in pieces where t < p.offset + p.duration { return p.start.addingTimeInterval(max(0, t - p.offset)) }
        return end
    }
}

struct Segment: Hashable {
    let url: URL
    let start: Date
    let end: Date
    let kept: Bool
    let bytes: Int64
}

@MainActor
final class HistoryStore: ObservableObject {
    @Published private(set) var visits: [Visit] = []          // newest first
    @Published private(set) var summaries: [String: DaySummary] = [:]
    @Published private(set) var usedBytes: Int64 = 0
    @Published private(set) var oldestFootage: Date?

    private(set) var segments: [Segment] = []                 // oldest first
    let defaults = UserDefaults.standard

    // Called when a new visit opens, or an existing one changes.
    var onVisitCreated: ((Visit) -> Void)?
    // Called after each recording file lands (for sound analysis).
    var onSegmentSaved: ((Segment) -> Void)?

    // MARK: Places on disk

    static let dataDir: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doorman/History", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let thumbsDir: URL = sub(dataDir, "Thumbnails")
    static let videoRoot: URL = {
        let d = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doorman", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    static let recordingsDir: URL = sub(videoRoot, "Recordings")
    static let clipsDir: URL = sub(videoRoot, "Event Clips")

    private static func sub(_ base: URL, _ name: String) -> URL {
        let d = base.appendingPathComponent(name, isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }

    private var indexURL: URL { Self.dataDir.appendingPathComponent("visits.json") }
    private var summariesURL: URL { Self.dataDir.appendingPathComponent("summaries.json") }

    // MARK: Settings

    var capBytes: Int64 {
        let gb = defaults.object(forKey: "storageGB") as? Double ?? 10
        return Int64(max(1, gb) * 1_000_000_000)
    }
    var historyDays: Int { defaults.object(forKey: "historyDays") as? Int ?? 60 }

    // MARK: Load / save

    init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: indexURL), let v = try? dec.decode([Visit].self, from: d) {
            visits = v.sorted { $0.time > $1.time }
        }
        if let d = try? Data(contentsOf: summariesURL), let s = try? dec.decode([String: DaySummary].self, from: d) {
            summaries = s
        }
        scanSegments()
        pruneOldVisits()
        enforceCap()
    }

    private var saveScheduled = false
    func save() {
        guard !saveScheduled else { return }
        saveScheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self else { return }
            self.saveScheduled = false
            let enc = JSONEncoder()
            enc.dateEncodingStrategy = .iso8601
            if let d = try? enc.encode(self.visits) { try? d.write(to: self.indexURL, options: .atomic) }
            if let d = try? enc.encode(self.summaries) { try? d.write(to: self.summariesURL, options: .atomic) }
        }
    }

    // MARK: Recordings

    // File names are "<start ms>-<duration ms>.mp4".
    private func parse(_ url: URL, kept: Bool) -> Segment? {
        let name = url.deletingPathExtension().lastPathComponent
        let parts = name.split(separator: "-")
        guard parts.count == 2, let s = Double(parts[0]), let d = Double(parts[1]) else { return nil }
        let size = Int64((try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0)
        return Segment(url: url, start: Date(timeIntervalSince1970: s / 1000),
                       end: Date(timeIntervalSince1970: (s + d) / 1000), kept: kept, bytes: size)
    }

    private func scanSegments() {
        var found: [Segment] = []
        let fm = FileManager.default
        for (dir, kept) in [(Self.recordingsDir, false), (Self.clipsDir, true)] {
            if let e = fm.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey]) {
                for case let url as URL in e where url.pathExtension == "mp4" {
                    if let seg = parse(url, kept: kept) { found.append(seg) }
                }
            }
        }
        segments = found.sorted { $0.start < $1.start }
        recount()
    }

    private func recount() {
        usedBytes = segments.reduce(0) { $0 + $1.bytes }
        oldestFootage = segments.first?.start
    }

    private static let dayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f
    }()
    static func dayKey(_ d: Date) -> String { dayFormatter.string(from: d) }

    func saveSegment(data: Data, start: Date, end: Date) {
        let dir = Self.recordingsDir.appendingPathComponent(Self.dayKey(start), isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let ms = Int64(start.timeIntervalSince1970 * 1000)
        let dur = Int64(max(1, end.timeIntervalSince(start)) * 1000)
        let url = dir.appendingPathComponent("\(ms)-\(dur).mp4")
        do { try data.write(to: url) } catch {
            DebugLog.write("saveSegment failed: \(error.localizedDescription) at \(url.path)")
            return
        }
        DebugLog.write("saved \(url.lastPathComponent) \(data.count) bytes")
        let seg = Segment(url: url, start: start, end: end, kept: false, bytes: Int64(data.count))
        segments.append(seg)
        segments.sort { $0.start < $1.start }
        recount()
        protectClipsForRecentVisits()
        enforceCap()
        if let s = segments.first(where: { $0.url.lastPathComponent == url.lastPathComponent }) {
            onSegmentSaved?(s)
        }
    }

    // Moves recordings that cover a visit into "Event Clips", so the rolling
    // 24/7 history doesn't overwrite them before the event history expires.
    private func protectClipsForRecentVisits() {
        let recent = visits.filter { Date().timeIntervalSince($0.endTime) < 15 * 60 }
        guard !recent.isEmpty else { return }
        var changed = false
        for v in recent {
            let from = v.time.addingTimeInterval(-10), to = v.endTime.addingTimeInterval(20)
            for seg in segments where !seg.kept && seg.end > from && seg.start < to {
                if let moved = keep(seg) { addClip(moved.url.lastPathComponent, to: v.id); changed = true }
            }
        }
        if changed { recount(); save() }
    }

    private func keep(_ seg: Segment) -> Segment? {
        let dest = Self.clipsDir.appendingPathComponent(seg.url.lastPathComponent)
        do { try FileManager.default.moveItem(at: seg.url, to: dest) } catch { return nil }
        let kept = Segment(url: dest, start: seg.start, end: seg.end, kept: true, bytes: seg.bytes)
        if let i = segments.firstIndex(of: seg) { segments[i] = kept }
        return kept
    }

    private func addClip(_ name: String, to visitId: String) {
        guard let i = visits.firstIndex(where: { $0.id == visitId }) else { return }
        if !visits[i].clips.contains(name) { visits[i].clips.append(name); visits[i].clips.sort() }
    }

    // Keeps total video under the storage limit: oldest 24/7 footage goes first,
    // then (only if still over) the oldest event clips.
    func enforceCap() {
        let cap = capBytes
        guard usedBytes > cap else { return }
        var total = usedBytes
        var removed = Set<URL>()
        for seg in segments where !seg.kept {
            if total <= cap { break }
            try? FileManager.default.removeItem(at: seg.url)
            removed.insert(seg.url)
            total -= seg.bytes
        }
        if total > cap {
            for seg in segments where seg.kept {
                if total <= cap { break }
                try? FileManager.default.removeItem(at: seg.url)
                removed.insert(seg.url)
                total -= seg.bytes
                for i in visits.indices { visits[i].clips.removeAll { $0 == seg.url.lastPathComponent } }
            }
            save()
        }
        segments.removeAll { removed.contains($0.url) }
        recount()
        // Remove empty day folders.
        if let days = try? FileManager.default.contentsOfDirectory(at: Self.recordingsDir, includingPropertiesForKeys: nil) {
            for d in days where (try? FileManager.default.contentsOfDirectory(atPath: d.path))?.isEmpty == true {
                try? FileManager.default.removeItem(at: d)
            }
        }
    }

    // Event history older than the chosen number of days is removed.
    func pruneOldVisits() {
        let cutoff = Date().addingTimeInterval(-Double(historyDays) * 86400)
        let old = visits.filter { $0.time < cutoff }
        guard !old.isEmpty else { return }
        for v in old {
            if let t = v.thumbnail { try? FileManager.default.removeItem(at: Self.thumbsDir.appendingPathComponent(t)) }
            for c in v.clips {
                let url = Self.clipsDir.appendingPathComponent(c)
                try? FileManager.default.removeItem(at: url)
                segments.removeAll { $0.url == url }
            }
        }
        visits.removeAll { $0.time < cutoff }
        recount()
        save()
    }

    func segments(from: Date, to: Date) -> [Segment] {
        segments.filter { $0.end > from && $0.start < to }
    }

    // Is there saved video of this moment?
    func hasFootage(at t: Date) -> Bool { !segments(from: t.addingTimeInterval(-2), to: t.addingTimeInterval(2)).isEmpty }

    // A still frame from the recordings at a given moment.
    func frame(at t: Date, maxSide: CGFloat = 1280) async -> CGImage? {
        guard let seg = segments(from: t, to: t.addingTimeInterval(0.5)).first else { return nil }
        let gen = AVAssetImageGenerator(asset: AVURLAsset(url: seg.url))
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: maxSide, height: maxSide)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)
        let at = CMTime(seconds: max(0, t.timeIntervalSince(seg.start)), preferredTimescale: 600)
        if #available(macOS 13.0, *) { return try? await gen.image(at: at).image }
        return try? gen.copyCGImage(at: at, actualTime: nil)
    }

    // A player for a stretch of footage, starting `lead` seconds before `from`.
    // The one-minute files are joined into a single timeline so the scrubber covers the whole stretch.
    func player(from: Date, to: Date, lead: TimeInterval = 5) async -> AVPlayer? {
        await playback(from: from, to: to, lead: lead)?.player
    }

    func playback(from: Date, to: Date, lead: TimeInterval = 0) async -> Playback? {
        let begin = from.addingTimeInterval(-lead)
        let segs = segments(from: begin, to: to)
        guard !segs.isEmpty else { return nil }
        var pieces: [Playback.Piece] = []
        var player: AVPlayer?
        if #available(macOS 15, *) {
            let comp = AVMutableComposition()
            for s in segs {
                let asset = AVURLAsset(url: s.url)
                guard let dur = try? await asset.load(.duration), dur.seconds > 0 else { continue }
                let at = comp.duration
                do {
                    try await comp.insertTimeRange(CMTimeRange(start: .zero, duration: dur), of: asset, at: at)
                    pieces.append(.init(start: s.start, offset: at.seconds, duration: dur.seconds))
                } catch { continue }
            }
            if comp.duration.seconds > 0 { player = AVPlayer(playerItem: AVPlayerItem(asset: comp)) }
        }
        if player == nil {
            pieces = [.init(start: segs[0].start, offset: 0, duration: segs[0].end.timeIntervalSince(segs[0].start))]
            player = AVQueuePlayer(items: segs.map { AVPlayerItem(url: $0.url) })
        }
        guard let player, let first = pieces.first else { return nil }
        players.add(player)
        var offset = (pieces.first { $0.start > begin } ?? first).offset
        if let p = pieces.last(where: { $0.start <= begin }), begin.timeIntervalSince(p.start) < p.duration - 0.5 {
            offset = p.offset + begin.timeIntervalSince(p.start)
        }
        await player.seek(to: CMTime(seconds: offset, preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
        return Playback(player: player, pieces: pieces)
    }

    // Every player handed out, so closing the History window can silence them all.
    private let players = NSHashTable<AVPlayer>.weakObjects()

    func stopAllPlayback() {
        for p in players.allObjects { p.pause() }
    }

    func clipURL(_ v: Visit) -> URL? { v.clips.first.map { Self.clipsDir.appendingPathComponent($0) } }

    // MARK: Visits

    // Joins events that belong to the same visit (motion → person → ring within a minute).
    @discardableResult
    func recordEvent(kind: String, at time: Date = Date(), analyze: Bool = true) -> (visit: Visit, isNew: Bool) {
        if let i = visits.firstIndex(where: { abs(time.timeIntervalSince($0.endTime)) < 60 && time >= $0.time.addingTimeInterval(-5) }) {
            if !visits[i].kinds.contains(kind) { visits[i].kinds.append(kind) }
            visits[i].endTime = max(visits[i].endTime, time)
            save()
            return (visits[i], false)
        }
        let v = Visit(id: UUID().uuidString, time: time, endTime: time, kinds: [kind])
        visits.insert(v, at: 0)
        visits.sort { $0.time > $1.time }      // events can arrive late (e.g. after the Mac wakes)
        protectClipsForRecentVisits()
        save()
        if analyze { onVisitCreated?(v) }
        return (v, true)
    }

    func visit(_ id: String) -> Visit? { visits.first { $0.id == id } }

    func delete(_ id: String) {
        guard let v = visit(id) else { return }
        if let t = v.thumbnail { try? FileManager.default.removeItem(at: Self.thumbsDir.appendingPathComponent(t)) }
        for c in v.clips {
            let url = Self.clipsDir.appendingPathComponent(c)
            // Another visit may share this clip.
            if !visits.contains(where: { $0.id != id && $0.clips.contains(c) }) {
                try? FileManager.default.removeItem(at: url)
                segments.removeAll { $0.url == url }
            }
        }
        visits.removeAll { $0.id == id }
        recount()
        save()
    }

    func update(_ id: String, _ change: (inout Visit) -> Void) {
        guard let i = visits.firstIndex(where: { $0.id == id }) else { return }
        change(&visits[i])
        save()
    }

    func saveThumbnail(_ image: CGImage, for id: String) -> String? {
        let name = id + ".jpg"
        let rep = NSBitmapImageRep(cgImage: image)
        guard let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.82]) else { return nil }
        do { try data.write(to: Self.thumbsDir.appendingPathComponent(name)) } catch { return nil }
        return name
    }

    func thumbnailURL(_ v: Visit) -> URL? { v.thumbnail.map { Self.thumbsDir.appendingPathComponent($0) } }

    func visits(on day: String) -> [Visit] { visits.filter { Self.dayKey($0.time) == day } }

    var days: [String] {
        var seen = Set<String>(), out: [String] = []
        for v in visits { let k = Self.dayKey(v.time); if seen.insert(k).inserted { out.append(k) } }
        let today = Self.dayKey(Date())
        if !seen.contains(today) { out.insert(today, at: 0) }
        return out
    }

    func setSummary(_ text: String, for day: String) {
        summaries[day] = DaySummary(day: day, text: text, created: Date())
        save()
    }

    // Names on visits follow the face library (after you name or rename someone).
    func refreshNames(_ nameForFace: (String) -> String?) {
        var changed = false
        for i in visits.indices {
            let names = Array(Set(visits[i].faceIds.compactMap(nameForFace))).sorted()
            if names != visits[i].names { visits[i].names = names; changed = true }
        }
        if changed { save() }
    }

    // MARK: Text for the AI

    static let timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "EEE MMM d, h:mm a"
        return f
    }()

    func line(for v: Visit) -> String {
        var bits = ["\(Self.timeFormatter.string(from: v.time)) — \(v.title)"]
        if let d = v.details, !d.isEmpty { bits.append(d) }
        if !v.tags.isEmpty { bits.append("[" + v.tags.joined(separator: ", ") + "]") }
        return bits.joined(separator: " ")
    }
}
