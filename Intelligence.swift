// Intelligence.swift — everything "smart", all on this Mac:
// Vision (people, faces, objects, animals, text), a familiar-faces library,
// SoundAnalysis (knocks, barking, glass breaking, smoke alarms…), and Apple's
// on-device language model for descriptions, search, daily summaries and chat.
import Cocoa
import Vision
import SoundAnalysis
import FoundationModels

// MARK: - What a frame shows

struct FrameFacts: Sendable {
    var people = 0
    var faces: [CGImage] = []
    var labels: [String: Float] = [:]     // interesting Vision labels → confidence
    var animals: [String] = []
    var text: [String] = []

    var hasBox: Bool {
        ["cardboard_box", "carton", "envelope", "paper_bag", "bag"].contains { (labels[$0] ?? 0) > 0.25 }
    }
    var vehicles: [String] {
        // Plain cars are left out: parked cars on the street are in nearly every frame.
        let map = ["van": "van", "truck": "truck", "semi_truck": "truck", "police_car": "police car",
                   "firetruck": "fire truck", "bicycle": "bicycle"]
        return Array(Set(map.compactMap { (labels[$0.key] ?? 0) > 0.3 ? $0.value : nil })).sorted()
    }
    var courier: String? {
        let names = ["amazon", "ups", "fedex", "usps", "canada post", "purolator", "dhl", "uber eats", "doordash",
                     "skip", "instacart", "intelcom", "gls", "postes canada"]
        let joined = text.joined(separator: " ").lowercased()
        return names.first { joined.range(of: "\\b\($0)\\b", options: .regularExpression) != nil }
    }
}

enum VisionAnalyzer {
    static let interesting: Set<String> = [
        "cardboard_box", "carton", "envelope", "paper_bag", "bag", "mailbox", "van", "truck", "semi_truck", "car",
        "police_car", "firetruck", "bicycle", "vehicle", "dog", "cat", "bird", "people", "porch", "umbrella", "stroller",
    ]

    static func analyze(_ image: CGImage) -> FrameFacts {
        var facts = FrameFacts()
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        let humans = VNDetectHumanRectanglesRequest()
        humans.upperBodyOnly = false
        let faces = VNDetectFaceRectanglesRequest()
        let classify = VNClassifyImageRequest()
        let animals = VNRecognizeAnimalsRequest()
        let text = VNRecognizeTextRequest()
        text.recognitionLevel = .fast
        text.usesLanguageCorrection = false
        try? handler.perform([humans, faces, classify, animals, text])

        facts.people = (humans.results ?? []).filter { $0.confidence > 0.5 }.count
        for obs in (classify.results ?? []) where obs.confidence > 0.15 && interesting.contains(obs.identifier) {
            facts.labels[obs.identifier] = obs.confidence
        }
        facts.animals = Array(Set((animals.results ?? []).compactMap { $0.labels.first?.identifier.lowercased() })).sorted()
        facts.text = (text.results ?? []).compactMap { $0.topCandidates(1).first?.string }.filter { $0.count >= 2 }

        let w = CGFloat(image.width), h = CGFloat(image.height)
        for f in (faces.results ?? []).sorted(by: { $0.boundingBox.width > $1.boundingBox.width }).prefix(3) {
            let bb = f.boundingBox
            var r = CGRect(x: bb.minX * w, y: (1 - bb.maxY) * h, width: bb.width * w, height: bb.height * h)
            guard r.width >= 36, r.height >= 36 else { continue }
            r = r.insetBy(dx: -r.width * 0.25, dy: -r.height * 0.25).intersection(CGRect(x: 0, y: 0, width: w, height: h))
            if let crop = image.cropping(to: r.integral) { facts.faces.append(crop) }
        }
        if facts.people == 0 && !facts.faces.isEmpty { facts.people = facts.faces.count }
        return facts
    }

    static func featurePrint(_ image: CGImage) -> VNFeaturePrintObservation? {
        let req = VNGenerateImageFeaturePrintRequest()
        try? VNImageRequestHandler(cgImage: image, options: [:]).perform([req])
        return req.results?.first
    }
}

// MARK: - Familiar faces

struct FaceSample: Codable, Identifiable, Hashable {
    var id: String
    var personId: String?
    var visitId: String
    var time: Date
    var image: String          // file name in Faces/
    var printData: Data        // archived VNFeaturePrintObservation
}

struct KnownPerson: Codable, Identifiable, Hashable {
    var id: String
    var name: String
}

@MainActor
final class FaceLibrary: ObservableObject {
    @Published private(set) var samples: [FaceSample] = []     // newest first
    @Published private(set) var people: [KnownPerson] = []
    var onChange: (() -> Void)?

    // Smaller = stricter. Image feature prints of the same face usually sit well below this.
    let threshold: Float = 0.55
    private var prints: [String: VNFeaturePrintObservation] = [:]

    static let dir: URL = {
        let d = HistoryStore.dataDir.appendingPathComponent("Faces", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()
    private var fileURL: URL { HistoryStore.dataDir.appendingPathComponent("faces.json") }

    private struct Saved: Codable { var samples: [FaceSample]; var people: [KnownPerson] }

    init() {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        if let d = try? Data(contentsOf: fileURL), let s = try? dec.decode(Saved.self, from: d) {
            samples = s.samples
            people = s.people
        }
        for s in samples { prints[s.id] = Self.unarchive(s.printData) }
    }

    private func save() {
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        if let d = try? enc.encode(Saved(samples: samples, people: people)) { try? d.write(to: fileURL, options: .atomic) }
        onChange?()
    }

    private static func unarchive(_ d: Data) -> VNFeaturePrintObservation? {
        try? NSKeyedUnarchiver.unarchivedObject(ofClass: VNFeaturePrintObservation.self, from: d)
    }

    func name(of personId: String?) -> String? {
        guard let personId else { return nil }
        return people.first { $0.id == personId }?.name
    }
    func nameForSample(_ id: String) -> String? { name(of: samples.first { $0.id == id }?.personId) }
    func imageURL(_ s: FaceSample) -> URL { Self.dir.appendingPathComponent(s.image) }

    private func distance(_ a: VNFeaturePrintObservation, _ b: VNFeaturePrintObservation) -> Float {
        var d: Float = .greatestFiniteMagnitude
        try? a.computeDistance(&d, to: b)
        return d
    }

    // Adds a face seen during a visit; returns its id and the person it matches, if any.
    func add(face: CGImage, print: VNFeaturePrintObservation, visitId: String, time: Date) -> (id: String, personId: String?) {
        var best: (String?, Float) = (nil, threshold)
        for s in samples where s.personId != nil {
            if let p = prints[s.id] {
                let d = distance(print, p)
                if d < best.1 { best = (s.personId, d) }
            }
        }
        let id = UUID().uuidString
        let file = id + ".jpg"
        if let data = NSBitmapImageRep(cgImage: face).representation(using: .jpeg, properties: [.compressionFactor: 0.85]) {
            try? data.write(to: Self.dir.appendingPathComponent(file))
        }
        let archived = (try? NSKeyedArchiver.archivedData(withRootObject: print, requiringSecureCoding: true)) ?? Data()
        samples.insert(FaceSample(id: id, personId: best.0, visitId: visitId, time: time, image: file, printData: archived), at: 0)
        prints[id] = print
        trim()
        save()
        return (id, best.0)
    }

    // Keeps at most 40 examples per person and 300 unnamed faces.
    private func trim() {
        var perPerson: [String: Int] = [:]
        var unnamed = 0
        var keep: [FaceSample] = []
        for s in samples {
            if let p = s.personId {
                perPerson[p, default: 0] += 1
                if perPerson[p]! <= 40 { keep.append(s) } else { drop(s) }
            } else {
                unnamed += 1
                if unnamed <= 300 { keep.append(s) } else { drop(s) }
            }
        }
        samples = keep
    }

    private func drop(_ s: FaceSample) {
        try? FileManager.default.removeItem(at: imageURL(s))
        prints[s.id] = nil
    }

    // Names a face; similar unnamed faces get the same name automatically.
    func assign(sampleId: String, toName rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, let i = samples.firstIndex(where: { $0.id == sampleId }) else { return }
        let person: KnownPerson
        if let existing = people.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            person = existing
        } else {
            person = KnownPerson(id: UUID().uuidString, name: name)
            people.append(person)
            people.sort { $0.name < $1.name }
        }
        samples[i].personId = person.id
        if let p = prints[sampleId] {
            for j in samples.indices where samples[j].personId == nil {
                if let q = prints[samples[j].id], distance(p, q) < threshold { samples[j].personId = person.id }
            }
        }
        save()
    }

    func unassign(sampleId: String) {
        guard let i = samples.firstIndex(where: { $0.id == sampleId }) else { return }
        samples[i].personId = nil
        save()
    }

    func remove(sampleId: String) {
        guard let s = samples.first(where: { $0.id == sampleId }) else { return }
        drop(s)
        samples.removeAll { $0.id == sampleId }
        save()
    }

    func rename(personId: String, to name: String) {
        guard let i = people.firstIndex(where: { $0.id == personId }), !name.isEmpty else { return }
        people[i].name = name
        save()
    }

    func forget(personId: String) {
        people.removeAll { $0.id == personId }
        for i in samples.indices where samples[i].personId == personId { samples[i].personId = nil }
        save()
    }

    func samples(of personId: String) -> [FaceSample] { samples.filter { $0.personId == personId } }

    // Unnamed faces grouped by likeness, so you can name someone once.
    func unnamedGroups(limit: Int = 24) -> [[FaceSample]] {
        var groups: [[FaceSample]] = []
        for s in samples where s.personId == nil {
            guard let p = prints[s.id] else { continue }
            if let gi = groups.firstIndex(where: { g in prints[g[0].id].map { distance(p, $0) < threshold } ?? false }) {
                groups[gi].append(s)
            } else if groups.count < limit {
                groups.append([s])
            }
        }
        return groups
    }
}

// MARK: - Sounds

final class SoundCollector: NSObject, SNResultsObserving {
    var hits: [(label: String, at: Double, confidence: Double)] = []
    func request(_ request: SNRequest, didProduce result: SNResult) {
        guard let r = result as? SNClassificationResult else { return }
        for c in r.classifications.prefix(3) where c.confidence > 0.55 {
            hits.append((c.identifier, r.timeRange.start.seconds, c.confidence))
        }
    }
}

enum SoundDetector {
    // Friendly names for the sounds we care about.
    static let names: [String: String] = [
        "knock": "Knocking", "door_bell": "Doorbell chime", "dog_bark": "Dog barking", "dog": "Dog barking",
        "dog_growl": "Dog growling", "glass_breaking": "Glass breaking", "smoke_detector": "Smoke alarm",
        "screaming": "Screaming", "shout": "Shouting", "children_shouting": "Children shouting",
        "siren": "Siren", "police_siren": "Siren", "ambulance_siren": "Siren", "fire_engine_siren": "Siren",
        "car_horn": "Car horn", "speech": "Talking", "baby_crying": "Baby crying", "gunshot_gunfire": "Gunshot",
        "door_slam": "Door slam",
    ]
    static let alarming: Set<String> = ["Glass breaking", "Smoke alarm", "Screaming", "Gunshot"]

    // How sure the classifier must be, and how many separate moments it must hear the
    // sound, before we believe it. Street noise easily fools it at lower settings.
    static func rule(for name: String) -> (confidence: Double, hits: Int) {
        if alarming.contains(name) { return (0.85, 3) }
        if name == "Knocking" || name == "Dog barking" || name == "Doorbell chime" { return (0.75, 2) }
        return (0.6, 1)
    }

    // Returns (friendly label, seconds into the file) for notable sounds.
    static func analyze(_ url: URL) -> [(String, Double)] {
        guard let analyzer = try? SNAudioFileAnalyzer(url: url),
              let request = try? SNClassifySoundRequest(classifierIdentifier: .version1) else { return [] }
        let collector = SoundCollector()
        guard (try? analyzer.add(request, withObserver: collector)) != nil else { return [] }
        analyzer.analyze()
        var byName: [String: [(at: Double, confidence: Double)]] = [:]
        for h in collector.hits {
            guard let name = names[h.label], h.confidence >= rule(for: name).confidence else { continue }
            byName[name, default: []].append((h.at, h.confidence))
        }
        var out: [(String, Double)] = []
        for (name, hits) in byName where hits.count >= rule(for: name).hits {
            out.append((name, hits.map(\.at).min() ?? 0))
        }
        return out
    }
}

// MARK: - Apple's on-device language model

@Generable
struct VisitWriteUp {
    @Guide(description: "A notification title of at most 7 words, e.g. 'Someone is at the door' or 'Package delivered by UPS'. Use a person's name only if it is listed under Recognized people.")
    var headline: String
    @Guide(description: "One or two short, plain sentences describing the visit, using only the facts given")
    var description: String
}

@Generable
struct SearchSpec {
    @Guide(description: "Start of the search window as a number of days before today (0 = today). Use 60 if no time is mentioned.")
    var fromDaysAgo: Int
    @Guide(description: "End of the search window as a number of days before today (0 = today).")
    var toDaysAgo: Int
    @Guide(description: "Event types wanted, from: doorbell ring, person, motion, package, sound, animal, vehicle. Empty means any.")
    var kinds: [String]
    @Guide(description: "Names of specific people mentioned, if any")
    var people: [String]
    @Guide(description: "Other important words to look for, e.g. courier names, objects, sounds. Empty if none.")
    var keywords: [String]
    @Guide(description: "Part of the day: morning, afternoon, evening, night or any")
    var partOfDay: String
}

// Plain search filter used by the app (built from the AI's SearchSpec, or directly).
struct HistoryQuery {
    var fromDaysAgo = 60
    var toDaysAgo = 0
    var kinds: [String] = []
    var people: [String] = []
    var keywords: [String] = []
    var partOfDay = "any"

    init(fromDaysAgo: Int = 60, toDaysAgo: Int = 0, kinds: [String] = [], people: [String] = [],
         keywords: [String] = [], partOfDay: String = "any") {
        self.fromDaysAgo = fromDaysAgo; self.toDaysAgo = toDaysAgo; self.kinds = kinds
        self.people = people; self.keywords = keywords; self.partOfDay = partOfDay
    }
    init(_ s: SearchSpec) {
        self.init(fromDaysAgo: s.fromDaysAgo, toDaysAgo: s.toDaysAgo, kinds: s.kinds, people: s.people,
                  keywords: s.keywords, partOfDay: s.partOfDay)
    }
}

func uniqued(_ items: [String]) -> [String] {
    var seen = Set<String>()
    return items.filter { seen.insert($0).inserted }
}

enum HomeAI {
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    static func todayContext() -> String {
        let f = DateFormatter()
        f.dateFormat = "EEEE, MMMM d, yyyy, h:mm a"
        return "Right now it is \(f.string(from: Date()))."
    }

    static func writeUp(facts: String) async -> VisitWriteUp? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
        You write short, friendly alerts about what a home's front-door camera saw. \
        Use only the facts given. Never invent names, objects, actions, dates or years. \
        Only use a person's name if it appears under "Recognized people"; otherwise say "someone" or "a person". \
        Don't state the date; the time is optional. If nobody is visible, say the porch looked clear. \
        If a named person is listed, use their name. Mention a package or courier only if the facts include one.
        """)
        return try? await session.respond(to: "Facts about this visit:\n" + facts, generating: VisitWriteUp.self).content
    }

    static func parseSearch(_ query: String) async -> SearchSpec? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
        You turn a question about a home's doorbell camera history into search filters. \(todayContext())
        """)
        return try? await session.respond(to: "Search: " + query, generating: SearchSpec.self).content
    }

    static func dailySummary(day: String, lines: [String]) async -> String? {
        guard isAvailable else { return nil }
        let session = LanguageModelSession(instructions: """
        You write a short daily recap (2 to 4 sentences) of what a home's front-door camera saw. \
        Be specific about times, deliveries, known people and anything unusual. Use only the events given. \
        Don't list every motion event; group similar ones (e.g. 'several cars passed in the afternoon').
        """)
        let prompt = "Events on \(day):\n" + lines.prefix(60).joined(separator: "\n")
        return try? await session.respond(to: prompt).content
    }
}

// Looks things up in the event history for the chat ("Ask about your home").
struct DoorHistoryTool: Tool {
    let name = "searchDoorHistory"
    let description = "Looks up front-door camera events (visitors, deliveries, doorbell rings, sounds) in a time range."

    @Generable
    struct Arguments {
        @Guide(description: "Start of the window in days before today (0 = today)")
        var fromDaysAgo: Int
        @Guide(description: "End of the window in days before today (0 = today)")
        var toDaysAgo: Int
        @Guide(description: "Optional words to match, e.g. a person's name, 'package', 'UPS', 'dog'. Empty for everything.")
        var keywords: [String]
    }

    let lookup: @Sendable (Int, Int, [String]) async -> [String]

    func call(arguments: Arguments) async throws -> String {
        let lines = await lookup(arguments.fromDaysAgo, arguments.toDaysAgo, arguments.keywords)
        if lines.isEmpty { return "No matching events." }
        return lines.prefix(30).joined(separator: "\n")
    }
}

// Keeps the most useful of several frames and merges what Vision saw in all of them.
struct FrameAccumulator {
    var best: (CGImage, FrameFacts)?
    var merged = FrameFacts()
    mutating func add(_ frame: CGImage) async {
        let facts = await Task.detached(priority: .userInitiated) { VisionAnalyzer.analyze(frame) }.value
        DebugLog.write("visit facts: people=\(facts.people) faces=\(facts.faces.count) labels=\(facts.labels.keys.sorted().prefix(8))")
        merged.people = max(merged.people, facts.people)
        for (k, c) in facts.labels { merged.labels[k] = max(merged.labels[k] ?? 0, c) }
        merged.animals = Array(Set(merged.animals + facts.animals)).sorted()
        merged.text += facts.text
        merged.faces += facts.faces
        let score = facts.faces.count * 3 + facts.people
        if best == nil || score > (best!.1.faces.count * 3 + best!.1.people) { best = (frame, facts) }
    }
}

// MARK: - Coordinator

@MainActor
final class Intelligence: ObservableObject {
    let history: HistoryStore
    let faces: FaceLibrary
    let engine: CameraEngine
    let defaults = UserDefaults.standard

    // App hooks
    var notify: ((String, String, String, String?) -> Void)?  // title, body, action, visit id
    var onVisitUpdated: ((Visit) -> Void)?
    var wantsDescriptiveNotification: ((String) -> Bool)?    // visitId → still waiting for a description?

    private var baseline: (image: CGImage, at: Date)?
    private var lastBaselineTry = Date.distantPast
    private var lastSummaryDay: String?

    init(history: HistoryStore, faces: FaceLibrary, engine: CameraEngine) {
        self.history = history
        self.faces = faces
        self.engine = engine
        lastSummaryDay = defaults.string(forKey: "lastSummaryDay")
        history.onVisitCreated = { [weak self] v in self?.analyze(visitId: v.id) }
        history.onSegmentSaved = { [weak self] s in self?.listen(to: s) }
        faces.onChange = { [weak self] in
            guard let self else { return }
            self.history.refreshNames { self.faces.nameForSample($0) }
        }
    }

    private var aiOn: Bool { defaults.object(forKey: "aiDescriptions") as? Bool ?? true }
    private var facesOn: Bool { defaults.object(forKey: "familiarFaces") as? Bool ?? true }
    private var packageAlertsOn: Bool { defaults.object(forKey: "packageAlerts") as? Bool ?? true }
    private var soundAlertsOn: Bool { defaults.object(forKey: "soundAlerts") as? Bool ?? true }

    // MARK: Visit analysis

    // Was the Mac asleep at this moment? (Set by the app.)
    var wasAsleep: ((Date) -> Bool)?

    func analyze(visitId: String) {
        Task {
            guard let v = history.visit(visitId) else { return }
            // If the camera stream is (re)connecting, give it a moment.
            for _ in 0..<20 where !engine.isReady && Date().timeIntervalSince(v.time) < 15 {
                try? await Task.sleep(nanoseconds: 500_000_000)
            }
            // The live picture only shows the visit if we're looking right away. Otherwise
            // (a late event, or the stream was down) use the recording of that moment.
            if !engine.isReady || Date().timeIntervalSince(v.time) > 15 {
                await analyzeFromRecording(visitId: visitId)
                return
            }
            var acc = FrameAccumulator()
            for delay in [0.8, 2.5, 2.5] {
                try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
                guard let frame = await engine.captureFrame(maxSide: 1280) else {
                    DebugLog.write("visit frame: none (engine ready=\(engine.isReady))")
                    continue
                }
                await acc.add(frame)
            }
            await finish(visitId: visitId, best: acc.best?.0, facts: acc.merged)
            // A minute later, check whether something was left on the porch.
            try? await Task.sleep(nanoseconds: 60_000_000_000)
            await checkForPackage(visitId: visitId)
        }
    }

    // Looks at the saved video from the moment of the visit.
    private func analyzeFromRecording(visitId: String) async {
        guard let v = history.visit(visitId) else { return }
        // The minute of video covering the visit may still be being saved; wait for it.
        var waited = 0.0
        while !history.hasFootage(at: v.time.addingTimeInterval(2)) && waited < 100
                && Date().timeIntervalSince(v.time) < 150 {
            try? await Task.sleep(nanoseconds: 5_000_000_000)
            waited += 5
        }
        guard history.hasFootage(at: v.time.addingTimeInterval(2)) else {
            let reason = (wasAsleep?(v.time) ?? false)
                ? "Your Mac was asleep, so Doorman couldn't record this visit."
                : "Doorman wasn't recording at that moment, so there's no video of this visit."
            DebugLog.write("visit \(v.time): no footage (\(reason))")
            history.update(visitId) { $0.noVideo = reason; $0.analyzed = true }
            if let updated = history.visit(visitId) { onVisitUpdated?(updated) }
            return
        }
        var acc = FrameAccumulator()
        for offset in [1.0, 3.0, 5.0, 8.0] {
            guard let frame = await history.frame(at: v.time.addingTimeInterval(offset)) else { continue }
            await acc.add(frame)
        }
        DebugLog.write("visit \(v.time): analyzed from recording, people=\(acc.merged.people)")
        await finish(visitId: visitId, best: acc.best?.0, facts: acc.merged)
    }

    private func finish(visitId: String, best: CGImage?, facts: FrameFacts) async {
        guard history.visit(visitId) != nil else { return }
        var thumbName: String?
        if let img = best { thumbName = history.saveThumbnail(img, for: visitId) }

        // Familiar faces
        var faceIds: [String] = [], names: [String] = []
        if facesOn {
            for crop in facts.faces.prefix(4) {
                guard let print = await Task.detached(priority: .userInitiated, operation: { VisionAnalyzer.featurePrint(crop) }).value else { continue }
                let r = faces.add(face: crop, print: print, visitId: visitId, time: Date())
                faceIds.append(r.id)
                if let n = faces.name(of: r.personId) { names.append(n) }
            }
        }
        names = Array(Set(names)).sorted()

        var tags: [String] = []
        if facts.people > 0 { tags.append(facts.people == 1 ? "1 person" : "\(facts.people) people") }
        tags += names
        if let c = facts.courier { tags.append(c.capitalized) }
        if facts.hasBox { tags.append("Package") }
        tags += facts.vehicles.map { $0.capitalized }
        tags += facts.animals.map { $0.capitalized }

        history.update(visitId) { v in
            if let t = thumbName { v.thumbnail = t }
            v.people = max(v.people, facts.people)
            v.faceIds += faceIds
            v.names = Array(Set(v.names + names)).sorted()
            v.package = v.package || facts.hasBox
            v.tags = uniqued(v.tags + tags)
            v.analyzed = true
        }
        await describe(visitId: visitId, facts: facts, names: names)
    }

    private func factsText(_ v: Visit, facts: FrameFacts?, names: [String]) -> String {
        var lines: [String] = []
        lines.append("Time: " + HistoryStore.timeFormatter.string(from: v.time))
        lines.append("Camera events: " + v.kinds.joined(separator: ", "))
        let people = max(v.people, facts?.people ?? 0)
        lines.append("People visible: \(people)")
        if !names.isEmpty { lines.append("Recognized people: " + names.joined(separator: ", ")) }
        else if (facts?.faces.count ?? 0) > 0 { lines.append("Faces seen: not recognized") }
        if let f = facts {
            if let c = f.courier { lines.append("Courier text seen: \(c.uppercased())") }
            if f.hasBox { lines.append("A box, bag or envelope is visible") }
            if !f.vehicles.isEmpty { lines.append("Vehicles: " + f.vehicles.joined(separator: ", ")) }
            if !f.animals.isEmpty { lines.append("Animals: " + f.animals.joined(separator: ", ")) }
        }
        if v.package { lines.append("Package detected") }
        if !v.sounds.isEmpty { lines.append("Sounds heard: " + v.sounds.joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    private func describe(visitId: String, facts: FrameFacts?, names: [String]) async {
        guard let v = history.visit(visitId) else { return }
        var headline = v.defaultTitle
        var details: String?
        if aiOn, let w = await HomeAI.writeUp(facts: factsText(v, facts: facts, names: names)) {
            headline = w.headline
            details = w.description
        }
        history.update(visitId) { $0.headline = headline; if let d = details { $0.details = d } }
        if let updated = history.visit(visitId) {
            onVisitUpdated?(updated)
            if wantsDescriptiveNotification?(visitId) == true {
                notify?(headline, details ?? "Click to see the live view.", "live", visitId)
            }
        }
    }

    // MARK: Packages

    // Compares the porch before the visit with a minute after it.
    private func checkForPackage(visitId: String) async {
        guard let v = history.visit(visitId), v.people > 0 || v.kinds.contains("Person") || v.kinds.contains("Doorbell ring"),
              let after = await engine.captureFrame(maxSide: 1024) else { return }
        let afterFacts = await Task.detached(priority: .utility) { VisionAnalyzer.analyze(after) }.value
        var before: FrameFacts?
        if let b = baseline?.image, Date().timeIntervalSince(baseline!.at) < 30 * 60 {
            before = await Task.detached(priority: .utility) { VisionAnalyzer.analyze(b) }.value
        }
        let boxAfter = afterFacts.hasBox
        let boxBefore = before?.hasBox ?? false
        let courier = history.visit(visitId)?.tags.contains { ["Amazon", "Ups", "Fedex", "Usps", "Canada Post", "Purolator", "Dhl", "Intelcom"].contains($0) } ?? false
        guard boxAfter && (!boxBefore || courier) else { return }
        history.update(visitId) { v in
            v.package = true
            if !v.tags.contains("Package") { v.tags.append("Package") }
            if !v.tags.contains("Package left") { v.tags.append("Package left") }
        }
        if packageAlertsOn {
            notify?("Package at the door", "Something that looks like a package was left at your door.", "live", visitId)
        }
        await describe(visitId: visitId, facts: afterFacts, names: history.visit(visitId)?.names ?? [])
    }

    // A calm "before" picture of the porch, refreshed every few minutes when nothing's happening.
    func refreshBaseline() {
        guard engine.isReady, Date().timeIntervalSince(lastBaselineTry) > 180 else { return }
        let busy = history.visits.first.map { Date().timeIntervalSince($0.endTime) < 120 } ?? false
        guard !busy else { return }
        lastBaselineTry = Date()
        Task {
            if let img = await engine.captureFrame(maxSide: 1024) { baseline = (img, Date()) }
        }
    }

    // MARK: Sounds

    private func listen(to seg: Segment) {
        let url = seg.url
        Task {
            let hits = await Task.detached(priority: .utility) { SoundDetector.analyze(url) }.value
            guard !hits.isEmpty else { return }
            var byLabel: [String: Double] = [:]
            for (label, at) in hits where byLabel[label] == nil { byLabel[label] = at }
            for (label, at) in byLabel {
                let when = seg.start.addingTimeInterval(at)
                var visitId: String?
                // Attach to a visit happening at that time…
                if let v = history.visits.first(where: { when >= $0.time.addingTimeInterval(-15) && when <= $0.endTime.addingTimeInterval(45) }) {
                    visitId = v.id
                    history.update(v.id) { vv in
                        if !vv.sounds.contains(label) { vv.sounds.append(label) }
                        if !vv.tags.contains(label) { vv.tags.append(label) }
                    }
                } else if SoundDetector.alarming.contains(label) || label == "Knocking" {
                    // …or record it as its own event.
                    let r = history.recordEvent(kind: "Sound", at: when, analyze: false)
                    visitId = r.visit.id
                    history.update(r.visit.id) { vv in
                        if !vv.sounds.contains(label) { vv.sounds.append(label) }
                        if !vv.tags.contains(label) { vv.tags.append(label) }
                        vv.headline = label + " at the front door"
                    }
                }
                if SoundDetector.alarming.contains(label) && soundAlertsOn {
                    notify?("\(label) heard at the front door", "Your doorbell picked up what sounds like \(label.lowercased()). Click to look.", "live", visitId)
                }
            }
        }
    }

    // MARK: Search

    func search(_ query: String) async -> [Visit] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return [] }
        if let spec = await HomeAI.parseSearch(q) { return apply(HistoryQuery(spec)) }
        // Without the AI: plain word matching.
        let words = q.lowercased().split(separator: " ").map(String.init).filter { $0.count > 2 }
        return history.visits.filter { v in
            let hay = (v.title + " " + (v.details ?? "") + " " + v.tags.joined(separator: " ")).lowercased()
            return words.contains { hay.contains($0) }
        }
    }

    func apply(_ spec: HistoryQuery) -> [Visit] {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let lo = min(spec.fromDaysAgo, spec.toDaysAgo), hi = max(spec.fromDaysAgo, spec.toDaysAgo)
        let start = cal.date(byAdding: .day, value: -hi, to: today) ?? today
        let end = (cal.date(byAdding: .day, value: -lo, to: today) ?? today).addingTimeInterval(86400)
        let kinds = spec.kinds.map { $0.lowercased() }
        let people = spec.people.map { $0.lowercased() }
        let keywords = spec.keywords.map { $0.lowercased() }.filter { !$0.isEmpty }
        let part = spec.partOfDay.lowercased()
        return history.visits.filter { v in
            guard v.time >= start && v.time < end else { return false }
            let hour = cal.component(.hour, from: v.time)
            switch part {
            case "morning": if !(5..<12).contains(hour) { return false }
            case "afternoon": if !(12..<17).contains(hour) { return false }
            case "evening": if !(17..<22).contains(hour) { return false }
            case "night": if (5..<22).contains(hour) { return false }
            default: break
            }
            if !kinds.isEmpty {
                let ok = kinds.contains { k in
                    switch k {
                    case "doorbell ring", "ring", "doorbell": return v.kinds.contains("Doorbell ring")
                    case "person", "people": return v.kinds.contains("Person") || v.people > 0
                    case "package", "delivery": return v.package
                    case "sound": return !v.sounds.isEmpty
                    case "animal": return v.tags.contains { ["Dog", "Cat", "Bird"].contains($0) }
                    case "vehicle": return v.tags.contains { ["Car", "Van", "Truck", "Vehicle"].contains($0) } || v.kinds.contains("Vehicle")
                    case "motion": return true
                    default: return true
                    }
                }
                if !ok { return false }
            }
            if !people.isEmpty && !v.names.contains(where: { n in people.contains { n.lowercased().contains($0) } }) { return false }
            if !keywords.isEmpty {
                let hay = (v.title + " " + (v.details ?? "") + " " + v.tags.joined(separator: " ") + " " + v.sounds.joined(separator: " ")).lowercased()
                if !keywords.contains(where: { hay.contains($0) }) && kinds.isEmpty && people.isEmpty { return false }
            }
            return true
        }
    }

    // MARK: Daily summary

    func summarize(day: String) async -> String {
        let vs = history.visits(on: day).sorted { $0.time < $1.time }
        if vs.isEmpty {
            let text = "A quiet day — nothing happened at the front door."
            history.setSummary(text, for: day)
            return text
        }
        let lines = vs.map { history.line(for: $0) }
        let text = await HomeAI.dailySummary(day: day, lines: lines)
            ?? "\(vs.count) events at the front door, including \(vs.filter { $0.kinds.contains("Doorbell ring") }.count) doorbell rings."
        history.setSummary(text, for: day)
        return text
    }

    // Called every minute: daily recap at the chosen time.
    func tick() {
        refreshBaseline()
        guard defaults.object(forKey: "dailySummary") as? Bool ?? true else { return }
        let minutes = defaults.object(forKey: "summaryTime") as? Int ?? 20 * 60
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        let today = HistoryStore.dayKey(Date())
        guard now >= minutes, lastSummaryDay != today else { return }
        lastSummaryDay = today
        defaults.set(today, forKey: "lastSummaryDay")
        Task {
            let text = await summarize(day: today)
            notify?("Your front door today", text, "history", nil)
        }
    }

    // MARK: Ask about your home

    func lookup(fromDaysAgo: Int, toDaysAgo: Int, keywords: [String]) -> [String] {
        let spec = HistoryQuery(fromDaysAgo: fromDaysAgo, toDaysAgo: toDaysAgo, keywords: keywords)
        var found = apply(spec)
        if found.isEmpty && !keywords.isEmpty {
            found = apply(HistoryQuery(fromDaysAgo: fromDaysAgo, toDaysAgo: toDaysAgo, people: keywords))
        }
        return found.sorted { $0.time < $1.time }.map { history.line(for: $0) }
    }

    func makeChatSession() -> LanguageModelSession {
        let tool = DoorHistoryTool { from, to, words in
            await MainActor.run { self.lookup(fromDaysAgo: from, toDaysAgo: to, keywords: words) }
        }
        return LanguageModelSession(tools: [tool], instructions: """
        You answer questions about what happened at the user's front door, using the searchDoorHistory tool \
        to look up camera events. \(HomeAI.todayContext()) Answer briefly and specifically with times. \
        If the history doesn't contain the answer, say so. Never make up events.
        """)
    }
}
