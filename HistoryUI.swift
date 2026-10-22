// HistoryUI.swift — the History window: a sidebar of days and library sections,
// an event timeline with video, AI search and summaries, 24/7 recordings with a
// day scrubber, familiar faces, and "Ask about your home".
import SwiftUI
import AVFoundation
import FoundationModels

struct ChatLine: Identifiable, Hashable {
    let id = UUID()
    let fromUser: Bool
    let text: String
}

@MainActor
final class HistoryUIModel: ObservableObject {
    enum Section: Hashable { case day(String), recordings, faces, ask }
    @Published var section: Section = .day(HistoryStore.dayKey(Date()))
    @Published var query = ""
    @Published var results: [Visit]?
    @Published var searchedFor = ""
    @Published var searching = false
    @Published var selectedVisit: String?
    @Published var summarizing = false
    @Published var chat: [ChatLine] = []
    @Published var draft = ""
    @Published var asking = false
    @Published var recordingsDay = Date()
    @Published var windowClosed = 0          // bumps when the History window closes
    var chatSession: LanguageModelSession?

    func show(_ v: Visit) {
        results = nil
        query = ""
        section = .day(HistoryStore.dayKey(v.time))
        selectedVisit = v.id
    }
}

private let timeOnly: DateFormatter = { let f = DateFormatter(); f.timeStyle = .short; return f }()
private let dayTitle: DateFormatter = { let f = DateFormatter(); f.dateFormat = "EEEE, MMMM d"; return f }()
private let shortDay: DateFormatter = { let f = DateFormatter(); f.dateFormat = "MMM d"; return f }()
private let dayParse: DateFormatter = { let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; return f }()

private func prettyDay(_ key: String) -> String {
    guard let d = dayParse.date(from: key) else { return key }
    if Calendar.current.isDateInToday(d) { return "Today" }
    if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
    return dayTitle.string(from: d)
}

private func sidebarDay(_ key: String) -> String {
    guard let d = dayParse.date(from: key) else { return key }
    if Calendar.current.isDateInToday(d) { return "Today" }
    if Calendar.current.isDateInYesterday(d) { return "Yesterday" }
    if let days = Calendar.current.dateComponents([.day], from: d, to: Date()).day, days < 7 {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f.string(from: d)
    }
    return shortDay.string(from: d)
}

private func longDay(_ key: String) -> String {
    guard let d = dayParse.date(from: key) else { return key }
    return dayTitle.string(from: d)
}

// MARK: - Window

struct HistoryView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var faces: FaceLibrary
    @ObservedObject var model: HistoryUIModel
    let intel: Intelligence

    private var dayKeys: [String] {
        let today = HistoryStore.dayKey(Date())
        return history.days.contains(today) ? history.days : [today] + history.days
    }

    var body: some View {
        NavigationSplitView {
            List(selection: Binding<HistoryUIModel.Section?>(
                get: { model.results == nil ? model.section : nil },
                set: { if let s = $0 { model.section = s; model.results = nil; model.query = "" } })) {
                Section("Activity") {
                    ForEach(dayKeys, id: \.self) { day in
                        let n = history.visits(on: day).count
                        Label(sidebarDay(day), systemImage: day == HistoryStore.dayKey(Date()) ? "clock" : "calendar")
                            .badge(n)
                            .tag(HistoryUIModel.Section.day(day))
                    }
                }
                Section("Library") {
                    Label("Recordings", systemImage: "video").tag(HistoryUIModel.Section.recordings)
                    Label("Familiar Faces", systemImage: "person.crop.square").tag(HistoryUIModel.Section.faces)
                    Label {
                        Text("Ask")
                    } icon: {
                        Image(systemName: "sparkles").foregroundStyle(AIStyle.linear)
                    }
                    .tag(HistoryUIModel.Section.ask)
                }
            }
            .listStyle(.sidebar)
            .navigationSplitViewColumnWidth(min: 180, ideal: 210, max: 280)
        } detail: {
            Group {
                if model.results != nil {
                    EventsView(history: history, faces: faces, model: model, intel: intel, day: nil)
                } else {
                    switch model.section {
                    case .day(let d): EventsView(history: history, faces: faces, model: model, intel: intel, day: d)
                    case .recordings: RecordingsView(history: history, model: model)
                    case .faces: FacesView(faces: faces, history: history)
                    case .ask: AskView(model: model, intel: intel)
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationSubtitle(subtitle)
        .background(WindowTitle(title: title, subtitle: subtitle))
        .searchable(text: $model.query, placement: .toolbar, prompt: "Search activity")
        .onSubmit(of: .search) { runSearch() }
        .onChange(of: model.query) { q in
            if q.trimmingCharacters(in: .whitespaces).isEmpty && model.results != nil { model.results = nil }
        }
        .frame(minWidth: 940, minHeight: 600)
    }

    private var title: String {
        if model.results != nil { return "Search" }
        switch model.section {
        case .day(let d): return sidebarDay(d)
        case .recordings: return "Recordings"
        case .faces: return "Familiar Faces"
        case .ask: return "Ask"
        }
    }

    private var subtitle: String {
        if let r = model.results { return "\(r.count) result\(r.count == 1 ? "" : "s")" }
        switch model.section {
        case .day(let d):
            let n = history.visits(on: d).count
            return longDay(d) + " · " + (n == 0 ? "No events" : "\(n) event\(n == 1 ? "" : "s")")
        case .recordings:
            let used = ByteCountFormatter.string(fromByteCount: history.usedBytes, countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: history.capBytes, countStyle: .file)
            return "\(used) of \(cap)"
        case .faces: return faces.people.isEmpty ? "No one named yet" : "\(faces.people.count) \(faces.people.count == 1 ? "person" : "people")"
        case .ask: return "Apple Intelligence · on this Mac"
        }
    }

    private func runSearch() {
        let q = model.query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { model.results = nil; return }
        model.searching = true
        model.searchedFor = q
        model.selectedVisit = nil
        model.results = []
        Task {
            let r = await intel.search(q)
            model.results = r
            model.searching = false
        }
    }
}

// MARK: - Events

struct EventsView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var faces: FaceLibrary
    @ObservedObject var model: HistoryUIModel
    let intel: Intelligence
    let day: String?            // nil = search results

    var body: some View {
        HSplitView {
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    if let day {
                        SummaryCard(history: history, model: model, intel: intel, day: day)
                        let vs = history.visits(on: day)
                        if vs.isEmpty {
                            EmptyState(symbol: "door.left.hand.closed", title: "All Quiet",
                                       message: "Nothing happened at the front door this day.")
                                .frame(height: 260)
                        } else {
                            Timeline(visits: vs, showDay: false, history: history, model: model)
                        }
                    } else if model.searching {
                        HStack(spacing: 10) {
                            ProgressView().controlSize(.small)
                            AIGlyph(size: 13)
                            Text("Searching for “\(model.searchedFor)”…").foregroundStyle(.secondary)
                        }
                        .padding(.top, 8)
                    } else if let r = model.results {
                        if r.isEmpty {
                            EmptyState(symbol: "magnifyingglass", title: "No Results",
                                       message: "Nothing matched “\(model.searchedFor)”. Try words like “packages this week” or a person's name.")
                                .frame(height: 300)
                        } else {
                            Timeline(visits: r, showDay: true, history: history, model: model)
                        }
                    }
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minWidth: 380, idealWidth: 560, maxWidth: .infinity)

            Group {
                if let id = model.selectedVisit, let v = history.visit(id) {
                    VisitDetail(visit: v, history: history, faces: faces) { delete(v.id) }
                        .id(v.id)      // a fresh player for every event, so the last one's video can't linger
                } else {
                    EmptyState(symbol: "play.rectangle", title: "No Event Selected",
                               message: "Choose an event to watch what happened.")
                }
            }
            .frame(minWidth: 360, idealWidth: 420, maxWidth: .infinity)
            .background(Color.primary.opacity(0.015))
        }
    }

    private func delete(_ id: String) {
        if model.selectedVisit == id { model.selectedVisit = nil }
        model.results?.removeAll { $0.id == id }
        history.delete(id)
    }
}

struct SummaryCard: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var model: HistoryUIModel
    let intel: Intelligence
    let day: String

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 7) {
                AIGlyph(size: 14)
                Text("Summary").font(.headline)
                Spacer()
                if model.summarizing {
                    ProgressView().controlSize(.small)
                } else {
                    Button { refresh() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help(history.summaries[day] == nil ? "Summarize this day" : "Refresh the summary")
                }
            }
            if let s = history.summaries[day] {
                Text(s.text).font(.body).fixedSize(horizontal: false, vertical: true).textSelection(.enabled)
            } else if history.visits(on: day).isEmpty {
                Text("Nothing to summarize yet.").foregroundStyle(.secondary)
            } else {
                Button("Summarize this day") { refresh() }.buttonStyle(.link)
            }
        }
        .padding(16)
        .background(AICardBackground())
    }

    private func refresh() {
        model.summarizing = true
        let d = day
        Task { _ = await intel.summarize(day: d); model.summarizing = false }
    }
}

struct Timeline: View {
    let visits: [Visit]
    let showDay: Bool
    @ObservedObject var history: HistoryStore
    @ObservedObject var model: HistoryUIModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(Array(visits.enumerated()), id: \.element.id) { i, v in
                TimelineRow(visit: v, thumb: history.thumbnailURL(v),
                            selected: model.selectedVisit == v.id,
                            showDay: showDay, isLast: i == visits.count - 1)
                    .onTapGesture { withAnimation(.easeOut(duration: 0.15)) { model.selectedVisit = v.id } }
                    .contextMenu {
                        if let clip = history.clipURL(v) {
                            Button("Show Clip in Finder") { NSWorkspace.shared.activateFileViewerSelecting([clip]) }
                        }
                        Divider()
                        Button("Delete Event", role: .destructive) {
                            if model.selectedVisit == v.id { model.selectedVisit = nil }
                            model.results?.removeAll { $0.id == v.id }
                            history.delete(v.id)
                        }
                    }
            }
        }
    }
}

struct TimelineRow: View {
    let visit: Visit
    let thumb: URL?
    let selected: Bool
    let showDay: Bool
    let isLast: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 1) {
                Text(timeOnly.string(from: visit.time))
                    .font(.callout.weight(.medium).monospacedDigit())
                if showDay {
                    Text(sidebarDay(HistoryStore.dayKey(visit.time))).font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(width: 72, alignment: .trailing)
            .padding(.top, 14)

            ZStack(alignment: .top) {
                Rectangle()
                    .fill(Color.secondary.opacity(0.22))
                    .frame(width: 2)
                    .frame(maxHeight: isLast ? 24 : .infinity, alignment: .top)
                KindBadge(visit: visit, size: 26).padding(.top, 10)
            }
            .frame(width: 26)
            .frame(maxHeight: .infinity, alignment: .top)

            HStack(alignment: .top, spacing: 12) {
                Thumb(url: thumb, width: 92, radius: 10)
                VStack(alignment: .leading, spacing: 4) {
                    Text(visit.title).font(.headline).lineLimit(2)
                    if let d = visit.details {
                        Text(d).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                    }
                    if !visit.tags.isEmpty {
                        TagChips(tags: visit.tags, names: visit.names, limit: 4).padding(.top, 2)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(10)
            .background(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .fill(selected ? Color.accentColor.opacity(0.16) : Color.primary.opacity(0.035))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 14, style: .continuous)
                    .strokeBorder(selected ? Color.accentColor.opacity(0.55) : Color.primary.opacity(0.05), lineWidth: 1)
            )
            .padding(.bottom, 12)
        }
        .contentShape(Rectangle())
    }
}

struct VisitDetail: View {
    let visit: Visit
    @ObservedObject var history: HistoryStore
    @ObservedObject var faces: FaceLibrary
    var onDelete: () -> Void
    @State private var player: AVPlayer?
    @State private var playback: Playback?
    @StateObject private var controls = PlayerModel()
    @State private var loading = false
    @State private var loadedFor = ""
    @State private var naming: String?
    @State private var nameText = ""
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                ZStack {
                    Color.black
                    if let player {
                        PlayerView(player: player)
                    } else {
                        if let url = history.thumbnailURL(visit), let img = ImageCache.shared.image(url) {
                            Image(nsImage: img).resizable().aspectRatio(contentMode: .fill).opacity(0.85)
                        }
                        if loading {
                            VStack(spacing: 8) {
                                ProgressView().controlSize(.small)
                                if waitingForSave {
                                    Text("Saving the video…").font(.caption).foregroundStyle(.white.opacity(0.8))
                                }
                            }
                        } else {
                            Label(visit.noVideo ?? "No video for this event",
                                  systemImage: (visit.noVideo ?? "").contains("asleep") ? "moon.zzz.fill" : "video.slash")
                                .font(.caption.weight(.medium))
                                .multilineTextAlignment(.center)
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.ultraThinMaterial, in: Capsule())
                                .frame(maxHeight: .infinity, alignment: .bottom).padding(10)
                        }
                    }
                }
                .aspectRatio(1, contentMode: .fit)
                .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
                .shadow(color: .black.opacity(0.2), radius: 8, y: 3)

                if player != nil {
                    PlayerControls(model: controls, clock: { t in playback?.date(at: t) })
                }

                HStack(spacing: 8) {
                    KindBadge(visit: visit, size: 22)
                    Text(EventStyle.label(visit)).font(.subheadline.weight(.medium)).foregroundStyle(EventStyle.color(visit))
                    Spacer()
                    Text(prettyDay(HistoryStore.dayKey(visit.time)) + ", " + timeOnly.string(from: visit.time))
                        .font(.subheadline).foregroundStyle(.secondary)
                }

                Text(visit.title).font(.title2.weight(.bold)).fixedSize(horizontal: false, vertical: true)
                if let d = visit.details {
                    Text(d).font(.body).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
                if !visit.tags.isEmpty { TagChips(tags: visit.tags, names: visit.names, limit: 12) }

                let shown = visit.faceIds.compactMap { id in faces.samples.first { $0.id == id } }
                if !shown.isEmpty {
                    Text("People").font(.headline).padding(.top, 6)
                    HStack(alignment: .top, spacing: 16) {
                        ForEach(shown) { s in
                            VStack(spacing: 6) {
                                FaceCircle(url: faces.imageURL(s), size: 58)
                                if let n = faces.name(of: s.personId) {
                                    Menu(n) { Button("Not \(n)") { faces.unassign(sampleId: s.id) } }
                                        .menuStyle(.borderlessButton).fixedSize().font(.callout)
                                } else {
                                    Button("Add Name") { naming = s.id; nameText = "" }
                                        .buttonStyle(.link).font(.callout)
                                }
                            }
                            .popover(isPresented: Binding(get: { naming == s.id }, set: { if !$0 { naming = nil } })) {
                                NameFacePopover(faces: faces, sampleId: s.id, text: $nameText) { naming = nil }
                            }
                        }
                    }
                }

                Divider().padding(.top, 6)
                HStack {
                    if let clip = history.clipURL(visit) {
                        Button { NSWorkspace.shared.activateFileViewerSelecting([clip]) } label: {
                            Label("Show in Finder", systemImage: "folder")
                        }
                    }
                    Spacer()
                    Button(role: .destructive) { confirmDelete = true } label: {
                        Label("Delete", systemImage: "trash")
                    }
                    .foregroundStyle(.red)
                }
                .buttonStyle(.borderless)
                .confirmationDialog("Delete this event?", isPresented: $confirmDelete) {
                    Button("Delete Event", role: .destructive) { onDelete() }
                } message: {
                    Text("Its clip and thumbnail are removed from this Mac.")
                }
            }
            .padding(20)
        }
        .onAppear { load() }
        .onChange(of: visit.id) { _ in load() }
        .onChange(of: visit.clips) { _ in if player == nil { loadedFor = ""; load() } }
        .onChange(of: visit.noVideo) { _ in if player == nil { loadedFor = ""; load() } }
        .onReceive(history.$usedBytes) { _ in if player == nil && waitingForSave { loadedFor = ""; load() } }
        .onDisappear { player?.pause() }
    }

    @State private var waitingForSave = false

    private func load() {
        let key = visit.id + "\(visit.clips.count)"
        guard loadedFor != key else { return }
        player?.pause()
        player = nil
        playback = nil
        controls.attach(nil)
        loadedFor = key
        let v = visit
        // Only show video that actually covers the moment of the visit.
        guard v.noVideo == nil, history.hasFootage(at: v.time) else {
            // A brand-new visit: its minute of video is still being written.
            waitingForSave = v.noVideo == nil && Date().timeIntervalSince(v.time) < 120
            loading = waitingForSave
            return
        }
        waitingForSave = false
        loading = true
        Task {
            var pb = await history.playback(from: v.time, to: v.endTime.addingTimeInterval(30), lead: 5)
            if let p = pb, !p.pieces.contains(where: { $0.start <= v.time && v.time < $0.start.addingTimeInterval($0.duration) + 2 }) {
                p.player.pause()
                pb = nil
            }
            if loadedFor == key && visit.id == v.id {
                playback = pb
                player = pb?.player
                controls.attach(pb?.player)
                loading = false
            }
        }
    }
}

struct NameFacePopover: View {
    @ObservedObject var faces: FaceLibrary
    let sampleId: String
    @Binding var text: String
    var done: () -> Void
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Who is this?").font(.headline)
            TextField("Name", text: $text).textFieldStyle(.roundedBorder).onSubmit { save() }.frame(width: 220)
            if !faces.people.isEmpty {
                FlowLayout(spacing: 6) {
                    ForEach(faces.people) { p in
                        Button(p.name) { text = p.name; save() }.buttonStyle(.bordered).controlSize(.small)
                    }
                }
                .frame(width: 220, alignment: .leading)
            }
            HStack {
                Button("Not a Face", role: .destructive) { faces.remove(sampleId: sampleId); done() }
                Spacer()
                Button("Save") { save() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(16)
    }
    private func save() {
        guard !text.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        faces.assign(sampleId: sampleId, toName: text)
        done()
    }
}

// MARK: - 24/7 recordings

@MainActor
final class ScrubController: ObservableObject {
    @Published var playback: Playback?
    @Published var playhead: Date?
    @Published var loading = false
    @Published var note: String?
    weak var history: HistoryStore?
    private var observer: Any?
    private var endObserver: NSObjectProtocol?
    private var generation = 0

    func load(at date: Date, play: Bool) {
        guard let history else { return }
        generation += 1
        let gen = generation
        loading = true
        note = nil
        playhead = date
        Task {
            let pb = await history.playback(from: date, to: date.addingTimeInterval(3600), lead: 0)
            guard gen == self.generation else { return }
            self.loading = false
            guard let pb else {
                self.note = "No footage at \(timeOnly.string(from: date))"
                return
            }
            self.attach(pb, play: play)
        }
    }

    private func attach(_ pb: Playback, play: Bool) {
        detach()
        playback = pb
        playhead = pb.date(at: pb.player.currentTime().seconds)
        observer = pb.player.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.5, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated { self?.playhead = pb.date(at: t.seconds) }
        }
        endObserver = NotificationCenter.default.addObserver(forName: .AVPlayerItemDidPlayToEndTime,
                                                             object: pb.player.currentItem, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let end = pb.end, let history = self.history,
                      !history.segments(from: end.addingTimeInterval(1), to: end.addingTimeInterval(600)).isEmpty else { return }
                self.load(at: end.addingTimeInterval(1), play: true)
            }
        }
        if play { pb.player.play() }
    }

    func detach() {
        if let o = observer { playback?.player.removeTimeObserver(o) }
        observer = nil
        if let e = endObserver { NotificationCenter.default.removeObserver(e) }
        endObserver = nil
        playback?.player.pause()
        playback = nil
    }
}

struct RecordingsView: View {
    @ObservedObject var history: HistoryStore
    @ObservedObject var model: HistoryUIModel
    @StateObject private var scrub = ScrubController()
    @StateObject private var recControls = PlayerModel()

    private var dayStart: Date { Calendar.current.startOfDay(for: model.recordingsDay) }
    private var isToday: Bool { Calendar.current.isDateInToday(model.recordingsDay) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 10) {
                Text(isToday ? "Today" : dayTitle.string(from: model.recordingsDay)).font(.title2.weight(.bold))
                Spacer()
                ControlGroup {
                    Button { shiftDay(-1) } label: { Image(systemName: "chevron.left") }.help("Previous day")
                    Button { shiftDay(1) } label: { Image(systemName: "chevron.right") }.help("Next day").disabled(isToday)
                }
                .fixedSize()
                DatePicker("", selection: $model.recordingsDay, in: ...Date(), displayedComponents: .date)
                    .datePickerStyle(.field).labelsHidden().fixedSize()
                Button("Today") { model.recordingsDay = Date() }.disabled(isToday)
            }

            ZStack {
                RoundedRectangle(cornerRadius: 16, style: .continuous).fill(Color.black)
                if let pb = scrub.playback {
                    PlayerView(player: pb.player)
                        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
                } else if scrub.loading {
                    ProgressView().controlSize(.regular).tint(.white)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "video.slash").font(.system(size: 36, weight: .light))
                        Text(scrub.note ?? (hasFootage ? "Click the timeline to watch" : "No recordings this day"))
                            .font(.callout)
                    }
                    .foregroundStyle(.white.opacity(0.6))
                }
                if let ph = scrub.playhead, scrub.playback != nil {
                    Text(timeWithSeconds(ph))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, 9).padding(.vertical, 4)
                        .background(.ultraThinMaterial, in: Capsule())
                        .environment(\.colorScheme, .dark)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                        .padding(12)
                        .allowsHitTesting(false)
                }
            }
            .aspectRatio(1, contentMode: .fit)
            .frame(maxWidth: .infinity)
            .shadow(color: .black.opacity(0.2), radius: 10, y: 4)

            PlayerControls(model: recControls, clock: { t in scrub.playback?.date(at: t) })
                .onReceive(scrub.$playback) { pb in recControls.attach(pb?.player) }

            DayScrubber(dayStart: dayStart, ranges: ranges, markers: markers, playhead: scrub.playhead) { date in
                scrub.load(at: date, play: true)
            }

            HStack(spacing: 10) {
                Image(systemName: "internaldrive").foregroundStyle(.secondary)
                ProgressView(value: Double(min(history.usedBytes, history.capBytes)), total: Double(max(history.capBytes, 1)))
                    .frame(width: 140)
                let used = ByteCountFormatter.string(fromByteCount: history.usedBytes, countStyle: .file)
                let cap = ByteCountFormatter.string(fromByteCount: history.capBytes, countStyle: .file)
                Text("\(used) of \(cap)").font(.callout.monospacedDigit())
                if let oldest = history.oldestFootage {
                    Text("· Oldest footage \(HistoryStore.timeFormatter.string(from: oldest))")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button { NSWorkspace.shared.open(HistoryStore.videoRoot) } label: {
                    Label("Show in Finder", systemImage: "folder")
                }
                .buttonStyle(.borderless)
            }
        }
        .padding(24)
        .onAppear { scrub.history = history; loadDefault() }
        .onChange(of: model.recordingsDay) { _ in loadDefault() }
        .onChange(of: model.windowClosed) { _ in scrub.playback?.player.pause() }
        .onDisappear { scrub.detach() }
    }

    private var hasFootage: Bool { !history.segments(from: dayStart, to: dayStart.addingTimeInterval(86400)).isEmpty }

    // Footage as fractions of the day, joined where files run back to back.
    private var ranges: [(Double, Double)] {
        var out: [(Double, Double)] = []
        for s in history.segments(from: dayStart, to: dayStart.addingTimeInterval(86400)) {
            let a = max(0, s.start.timeIntervalSince(dayStart) / 86400)
            let b = min(1, s.end.timeIntervalSince(dayStart) / 86400)
            if let last = out.last, a - last.1 < 10.0 / 86400 { out[out.count - 1].1 = b } else { out.append((a, b)) }
        }
        return out
    }

    private var markers: [(Double, Color)] {
        history.visits(on: HistoryStore.dayKey(dayStart)).map {
            ($0.time.timeIntervalSince(dayStart) / 86400, EventStyle.color($0))
        }
    }

    private func shiftDay(_ n: Int) {
        if let d = Calendar.current.date(byAdding: .day, value: n, to: model.recordingsDay), d <= Date() {
            model.recordingsDay = d
        }
    }

    private func loadDefault() {
        let segs = history.segments(from: dayStart, to: dayStart.addingTimeInterval(86400))
        guard let last = segs.last else { scrub.detach(); scrub.playhead = nil; return }
        // Today: the last few minutes. Other days: the last hour of footage.
        let start = isToday ? max(segs[0].start, last.end.addingTimeInterval(-300)) : max(segs[0].start, last.end.addingTimeInterval(-3600))
        scrub.load(at: start, play: false)
    }

    private func timeWithSeconds(_ d: Date) -> String {
        let f = DateFormatter(); f.dateFormat = "h:mm:ss a"; return f.string(from: d)
    }
}

struct DayScrubber: View {
    let dayStart: Date
    let ranges: [(Double, Double)]
    let markers: [(Double, Color)]
    let playhead: Date?
    var onPick: (Date) -> Void
    @State private var hover: Double?

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { geo in
                let w = geo.size.width
                ZStack(alignment: .topLeading) {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .fill(Color.primary.opacity(0.07))
                        .frame(height: 30).offset(y: 8)
                    ForEach(Array(ranges.enumerated()), id: \.offset) { _, r in
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.accentColor.opacity(0.55))
                            .frame(width: max(2, (r.1 - r.0) * w), height: 30)
                            .offset(x: r.0 * w, y: 8)
                    }
                    ForEach(Array(markers.enumerated()), id: \.offset) { _, m in
                        Circle().fill(m.1).frame(width: 7, height: 7)
                            .overlay(Circle().strokeBorder(Color.white.opacity(0.8), lineWidth: 1))
                            .offset(x: m.0 * w - 3.5, y: 0)
                    }
                    if let ph = playhead {
                        let f = ph.timeIntervalSince(dayStart) / 86400
                        Capsule().fill(Color.white)
                            .frame(width: 3, height: 40)
                            .shadow(color: .black.opacity(0.45), radius: 2)
                            .offset(x: f * w - 1.5, y: 3)
                    }
                    if let h = hover {
                        Text(timeOnly.string(from: dayStart.addingTimeInterval(h * 86400)))
                            .font(.caption2.weight(.semibold).monospacedDigit())
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(Capsule().fill(Color(nsColor: .windowBackgroundColor)).shadow(radius: 1))
                            .fixedSize()
                            .offset(x: min(max(0, h * w - 28), w - 60), y: -16)
                            .allowsHitTesting(false)
                    }
                }
                .contentShape(Rectangle())
                .onContinuousHover { phase in
                    switch phase {
                    case .active(let p): hover = min(max(0, p.x / w), 1)
                    case .ended: hover = nil
                    }
                }
                .gesture(DragGesture(minimumDistance: 0).onEnded { v in
                    let f = min(max(0, v.location.x / w), 0.9999)
                    onPick(dayStart.addingTimeInterval(f * 86400))
                })
            }
            .frame(height: 46)

            HStack(spacing: 0) {
                ForEach([0, 3, 6, 9, 12, 15, 18, 21], id: \.self) { h in
                    Text(hourLabel(h)).font(.caption2).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func hourLabel(_ h: Int) -> String {
        switch h { case 0: return "12 AM"; case 12: return "12 PM"; default: return h < 12 ? "\(h) AM" : "\(h - 12) PM" }
    }
}

// MARK: - Faces

struct FacesView: View {
    @ObservedObject var faces: FaceLibrary
    @ObservedObject var history: HistoryStore
    @State private var naming: String?
    @State private var text = ""
    @State private var renaming: String?

    private let columns = [GridItem(.adaptive(minimum: 128), spacing: 18, alignment: .top)]

    var body: some View {
        let groups = faces.unnamedGroups()
        if faces.people.isEmpty && groups.isEmpty {
            EmptyState(symbol: "person.crop.circle.badge.questionmark", title: "No Faces Yet",
                       message: "When someone comes to the door, their face shows up here so you can name them. Face data never leaves this Mac.")
        } else {
            ScrollView {
                VStack(alignment: .leading, spacing: 30) {
                    if !faces.people.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            Text("People").font(.title3.weight(.semibold))
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                                ForEach(faces.people) { p in
                                    let ss = faces.samples(of: p.id)
                                    VStack(spacing: 8) {
                                        FaceCircle(url: ss.first.map { faces.imageURL($0) }, size: 96)
                                        VStack(spacing: 2) {
                                            Text(p.name).font(.headline)
                                            Text("Seen \(ss.count) time\(ss.count == 1 ? "" : "s")")
                                                .font(.caption).foregroundStyle(.secondary)
                                        }
                                    }
                                    .frame(maxWidth: .infinity)
                                    .contentShape(Rectangle())
                                    .contextMenu {
                                        Button("Rename…") { renaming = p.id; text = p.name }
                                        Divider()
                                        Button("Forget \(p.name)", role: .destructive) { faces.forget(personId: p.id) }
                                    }
                                    .popover(isPresented: Binding(get: { renaming == p.id }, set: { if !$0 { renaming = nil } })) {
                                        VStack(alignment: .leading, spacing: 10) {
                                            Text("Rename").font(.headline)
                                            TextField("Name", text: $text).textFieldStyle(.roundedBorder).frame(width: 200)
                                                .onSubmit { faces.rename(personId: p.id, to: text); renaming = nil }
                                            HStack { Spacer(); Button("Save") { faces.rename(personId: p.id, to: text); renaming = nil }.keyboardShortcut(.defaultAction) }
                                        }
                                        .padding(16)
                                    }
                                }
                            }
                        }
                    }

                    if !groups.isEmpty {
                        VStack(alignment: .leading, spacing: 14) {
                            VStack(alignment: .leading, spacing: 3) {
                                Text("Who's This?").font(.title3.weight(.semibold))
                                Text("Name someone once and they'll be recognized in alerts, descriptions and search.")
                                    .font(.callout).foregroundStyle(.secondary)
                            }
                            LazyVGrid(columns: columns, alignment: .leading, spacing: 22) {
                                ForEach(groups, id: \.first!.id) { g in
                                    let s = g[0]
                                    VStack(spacing: 8) {
                                        FaceCircle(url: faces.imageURL(s), size: 96)
                                        Text("Seen \(g.count) time\(g.count == 1 ? "" : "s")").font(.caption).foregroundStyle(.secondary)
                                        Button("Add Name") { naming = s.id; text = "" }
                                            .buttonStyle(.bordered).controlSize(.small)
                                    }
                                    .frame(maxWidth: .infinity)
                                    .popover(isPresented: Binding(get: { naming == s.id }, set: { if !$0 { naming = nil } })) {
                                        NameFacePopover(faces: faces, sampleId: s.id, text: $text) { naming = nil }
                                    }
                                }
                            }
                        }
                    }
                }
                .padding(28)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

// MARK: - Ask about your home

struct AskView: View {
    @ObservedObject var model: HistoryUIModel
    let intel: Intelligence
    @FocusState private var focused: Bool

    private let suggestions: [(String, String)] = [
        ("person.2", "Who came to the door today?"),
        ("shippingbox", "Were there any deliveries this week?"),
        ("bell", "When did someone last ring the doorbell?"),
        ("moon.stars", "Was anyone here last night?"),
    ]

    var body: some View {
        VStack(spacing: 0) {
            if model.chat.isEmpty {
                VStack(spacing: 14) {
                    Spacer()
                    ZStack {
                        Circle().fill(AIStyle.angular).frame(width: 64, height: 64).blur(radius: 18).opacity(0.55)
                        AIGlyph(size: 38)
                    }
                    Text("Ask About Your Home").font(.title.weight(.bold))
                    Text(HomeAI.isAvailable
                         ? "Answers come from your doorbell history, using Apple Intelligence right on this Mac."
                         : "Apple Intelligence isn't available on this Mac right now, so this can't answer questions yet.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center).frame(maxWidth: 380)
                    LazyVGrid(columns: [GridItem(.fixed(250), spacing: 10), GridItem(.fixed(250), spacing: 10)], spacing: 10) {
                        ForEach(suggestions, id: \.1) { s in
                            Button { model.draft = s.1; send() } label: {
                                HStack(alignment: .top, spacing: 8) {
                                    Image(systemName: s.0).foregroundStyle(.secondary).frame(width: 18)
                                    Text(s.1).multilineTextAlignment(.leading).foregroundStyle(.primary)
                                    Spacer(minLength: 0)
                                }
                                .font(.callout)
                                .padding(12)
                                .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
                                .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.07)))
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.top, 8)
                    Spacer()
                }
                .frame(maxWidth: .infinity)
                .padding(24)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        VStack(alignment: .leading, spacing: 12) {
                            ForEach(model.chat) { line in
                                Bubble(line: line).id(line.id)
                            }
                            if model.asking { TypingBubble().id("typing") }
                        }
                        .padding(20)
                        .frame(maxWidth: 760)
                        .frame(maxWidth: .infinity)
                    }
                    .onChange(of: model.chat.count) { _ in
                        if let last = model.chat.last { withAnimation { proxy.scrollTo(last.id, anchor: .bottom) } }
                    }
                }
            }

            HStack(spacing: 10) {
                if !model.chat.isEmpty {
                    Button { model.chat = []; model.chatSession = nil } label: {
                        Image(systemName: "square.and.pencil").font(.system(size: 15))
                    }
                    .buttonStyle(.borderless)
                    .help("New chat")
                    .accessibilityLabel("New chat")
                }
                HStack(spacing: 8) {
                    AIGlyph(size: 13)
                    TextField("Ask about visitors, deliveries, sounds…", text: $model.draft)
                        .textFieldStyle(.plain)
                        .focused($focused)
                        .onSubmit { send() }
                    Button { send() } label: {
                        Image(systemName: "arrow.up.circle.fill")
                            .font(.system(size: 22))
                            .foregroundStyle(canSend ? Color.accentColor : Color.secondary.opacity(0.5))
                    }
                    .buttonStyle(.plain)
                    .disabled(!canSend)
                    .help("Send")
                    .accessibilityLabel("Send")
                }
                .padding(.leading, 14).padding(.trailing, 6).padding(.vertical, 6)
                .background(Capsule().fill(Color.primary.opacity(0.05)))
                .overlay(Capsule().strokeBorder(focused ? AnyShapeStyle(AIStyle.angular) : AnyShapeStyle(Color.primary.opacity(0.1)), lineWidth: focused ? 1.5 : 1))
                .frame(maxWidth: 680)
            }
            .frame(maxWidth: .infinity)
            .padding(.horizontal, 20)
            .padding(.vertical, 14)
        }
        .onAppear { focused = true }
    }

    private var canSend: Bool { !model.asking && !model.draft.trimmingCharacters(in: .whitespaces).isEmpty }

    private func send() {
        let q = model.draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty, !model.asking else { return }
        model.draft = ""
        withAnimation(.easeOut(duration: 0.2)) { model.chat.append(ChatLine(fromUser: true, text: q)) }
        guard HomeAI.isAvailable else {
            model.chat.append(ChatLine(fromUser: false, text: "Apple Intelligence isn't available right now."))
            return
        }
        model.asking = true
        Task {
            var answer = "Sorry, I couldn't work that out."
            for attempt in 0..<2 {
                if model.chatSession == nil || attempt == 1 { model.chatSession = intel.makeChatSession() }
                do {
                    answer = try await model.chatSession!.respond(to: q).content
                    break
                } catch {
                    answer = "Sorry, I couldn't work that out."
                }
            }
            withAnimation(.easeOut(duration: 0.2)) {
                model.chat.append(ChatLine(fromUser: false, text: answer))
                model.asking = false
            }
        }
    }
}

struct Bubble: View {
    let line: ChatLine
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            if line.fromUser { Spacer(minLength: 120) }
            else {
                ZStack { Circle().fill(Color.primary.opacity(0.06)); AIGlyph(size: 11) }.frame(width: 26, height: 26)
            }
            Text(line.text)
                .textSelection(.enabled)
                .font(.body)
                .padding(.horizontal, 14).padding(.vertical, 9)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(line.fromUser ? AnyShapeStyle(Color.accentColor.gradient) : AnyShapeStyle(Color.primary.opacity(0.07)))
                )
                .foregroundStyle(line.fromUser ? Color.white : Color.primary)
            if !line.fromUser { Spacer(minLength: 120) }
        }
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}

struct TypingBubble: View {
    var body: some View {
        HStack(alignment: .bottom, spacing: 8) {
            ZStack { Circle().fill(Color.primary.opacity(0.06)); AIGlyph(size: 11) }.frame(width: 26, height: 26)
            TimelineView(.animation(minimumInterval: 0.25)) { ctx in
                let step = Int(ctx.date.timeIntervalSinceReferenceDate * 4) % 3
                HStack(spacing: 4) {
                    ForEach(0..<3) { i in
                        Circle().fill(Color.secondary).frame(width: 7, height: 7).opacity(i == step ? 0.9 : 0.35)
                    }
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Color.primary.opacity(0.07)))
            }
            Spacer()
        }
    }
}

// Sets the window's title and subtitle from SwiftUI state.
struct WindowTitle: NSViewRepresentable {
    let title: String
    let subtitle: String
    final class TitleView: NSView {
        var title = "", subtitle = ""
        override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); apply() }
        func apply() {
            guard let w = window else { return }
            if w.title != title { w.title = title }
            if w.subtitle != subtitle { w.subtitle = subtitle }
        }
    }
    func makeNSView(context: Context) -> TitleView { TitleView() }
    func updateNSView(_ v: TitleView, context: Context) {
        v.title = title
        v.subtitle = subtitle
        v.apply()
    }
}
