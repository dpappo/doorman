// SettingsUI.swift — a standard Mac Settings window with toolbar tabs:
// General, Alerts, Recording, Intelligence and Nest.
import SwiftUI
import AppKit

final class SettingsModel: ObservableObject {
    @Published var connectionTitle = ""
    @Published var connectionDetail = ""
    @Published var connectionHealth = 0          // 0 off, 1 working on it, 2 good, 3 problem
    @Published var nestLinked = false
    @Published var nestAvailable = true
    @Published var lastEvent = ""
    @Published var loginEnabled = false
    @Published var storageText = ""
    @Published var recordingText = ""
    @Published var usedBytes: Int64 = 0
    @Published var capBytes: Int64 = 1
    @Published var aiAvailable = true
    var connect: () -> Void = {}
    var disconnect: () -> Void = {}
    var sendTest: () -> Void = {}
    var openHistory: () -> Void = {}
    var setLogin: (Bool) -> Void = { _ in }
}

private func minutesBinding(_ minutes: Binding<Int>) -> Binding<Date> {
    Binding(
        get: { Calendar.current.startOfDay(for: Date()).addingTimeInterval(Double(minutes.wrappedValue) * 60) },
        set: {
            let c = Calendar.current.dateComponents([.hour, .minute], from: $0)
            minutes.wrappedValue = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        })
}

// Title and a smaller explanation under it, the way System Settings labels rows.
private struct RowLabel: View {
    let title: String
    let detail: String?
    init(_ title: String, _ detail: String? = nil) { self.title = title; self.detail = detail }
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
            if let detail { Text(detail).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true) }
        }
    }
}

// MARK: - Panes

struct GeneralPane: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("videoOnly") private var videoOnly = true
    @AppStorage("keepOnTop") private var keepOnTop = true
    @AppStorage("directStream") private var directStream = true

    var body: some View {
        Form {
            Section("Live View") {
                Toggle(isOn: $videoOnly) { RowLabel("Show only the video", "Hides the title bar and page around the picture.") }
                Toggle("Keep on top of other windows", isOn: $keepOnTop)
                Toggle(isOn: $directStream) {
                    RowLabel("Use the fast direct stream", "Video straight from the Nest API. Turn off to use the Google Home page, which has Talk.")
                }
            }
            Section {
                Toggle("Open Doorman at login", isOn: Binding(get: { model.loginEnabled }, set: { model.setLogin($0) }))
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 560, height: 274)
    }
}

struct AlertsPane: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("popMode") private var popMode = "people"
    @AppStorage("hideAfter") private var hideAfter: Double = 60
    @AppStorage("playSound") private var playSound = true
    @AppStorage("prewarm") private var prewarm = true
    @AppStorage("busyAction") private var busyAction = "notify"
    @AppStorage("quietEnabled") private var quietEnabled = false
    @AppStorage("quietStart") private var quietStart = 22 * 60
    @AppStorage("quietEnd") private var quietEnd = 7 * 60
    @AppStorage("quietAction") private var quietAction = "notify"
    @AppStorage("healthAlerts") private var healthAlerts = true

    var body: some View {
        Form {
            Section {
                Picker("Pop up the live view for", selection: $popMode) {
                    Text("Doorbell rings and people").tag("people")
                    Text("All activity").tag("everything")
                    Divider()
                    Text("Nothing (paused)").tag("off")
                }
                Picker("Hide it after", selection: $hideAfter) {
                    Text("30 seconds").tag(30.0)
                    Text("1 minute").tag(60.0)
                    Text("2 minutes").tag(120.0)
                    Text("5 minutes").tag(300.0)
                }
                Toggle("Play a sound", isOn: $playSound)
                Toggle(isOn: $prewarm) {
                    RowLabel("Get the video ready on motion", "So it's already playing when someone rings.")
                }
            }
            Section {
                Picker(selection: $busyAction) {
                    Text("Pop up as usual").tag("popup")
                    Text("Send a notification").tag("notify")
                    Text("Stay silent").tag("silent")
                } label: {
                    RowLabel("When you're on a call", "Your camera or microphone is in use.")
                }
                Toggle("Quiet hours", isOn: $quietEnabled.animation())
                if quietEnabled {
                    HStack {
                        Text("From")
                        Spacer()
                        DatePicker("", selection: minutesBinding($quietStart), displayedComponents: .hourAndMinute).labelsHidden()
                        Text("to")
                        DatePicker("", selection: minutesBinding($quietEnd), displayedComponents: .hourAndMinute).labelsHidden()
                    }
                    Picker("During quiet hours", selection: $quietAction) {
                        Text("Send a notification").tag("notify")
                        Text("Stay silent").tag("silent")
                    }
                }
            } header: {
                Text("When You're Busy")
            }
            Section {
                Toggle("Warn me if alerts stop working", isOn: $healthAlerts)
                LabeledContent {
                    Button("Send Test Alert") { model.sendTest() }
                } label: {
                    RowLabel("Test your settings", "Pretends someone is at the door.")
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(!quietEnabled)
        .frame(width: 560, height: quietEnabled ? 512 : 436)
    }
}

struct RecordingPane: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("record247") private var record247 = true
    @AppStorage("storageGB") private var storageGB: Double = 10
    @AppStorage("historyDays") private var historyDays = 60

    var body: some View {
        Form {
            Section {
                Toggle(isOn: $record247) {
                    HStack(spacing: 10) {
                        Image(systemName: "record.circle.fill").font(.system(size: 20))
                            .foregroundStyle(record247 ? Color.red : Color.secondary)
                        RowLabel("Record 24/7", model.recordingText)
                    }
                }
            }
            Section("Storage") {
                VStack(alignment: .leading, spacing: 6) {
                    ProgressView(value: Double(min(model.usedBytes, model.capBytes)), total: Double(max(model.capBytes, 1)))
                    Text(model.storageText).font(.callout).foregroundStyle(.secondary)
                }
                .padding(.vertical, 2)
                Picker("Storage limit", selection: $storageGB) {
                    Text("5 GB").tag(5.0)
                    Text("10 GB").tag(10.0)
                    Text("20 GB").tag(20.0)
                    Text("50 GB").tag(50.0)
                    Text("100 GB").tag(100.0)
                    Text("250 GB").tag(250.0)
                }
                Picker("Keep event history for", selection: $historyDays) {
                    Text("30 days").tag(30)
                    Text("60 days").tag(60)
                    Text("90 days").tag(90)
                }
            }
            Section {
                HStack {
                    Button("Show Recordings in Finder") { NSWorkspace.shared.open(HistoryStore.videoRoot) }
                    Spacer()
                    Button("Open History…") { model.openHistory() }
                }
            } footer: {
                Text("About 3 GB of footage a day. When the limit is reached, the oldest 24/7 footage is overwritten first; event clips are kept for the history period while space allows.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 560, height: 384)
    }
}

struct IntelligencePane: View {
    @ObservedObject var model: SettingsModel
    @AppStorage("aiDescriptions") private var aiDescriptions = true
    @AppStorage("familiarFaces") private var familiarFaces = true
    @AppStorage("packageAlerts") private var packageAlerts = true
    @AppStorage("soundAlerts") private var soundAlerts = true
    @AppStorage("dailySummary") private var dailySummary = true
    @AppStorage("summaryTime") private var summaryTime = 20 * 60

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous).fill(AIStyle.angular)
                        Image(systemName: "sparkles").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Apple Intelligence").font(.headline)
                        Text(model.aiAvailable
                             ? "Descriptions, search, summaries and Ask all run on this Mac. Nothing is sent to the cloud."
                             : "Apple Intelligence isn't available right now. Basic descriptions are used instead.")
                            .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .padding(.vertical, 4)
            }
            Section {
                Toggle(isOn: $aiDescriptions) { RowLabel("Descriptive alerts", "“A courier dropped off a package” instead of “Person at the door”.") }
                Toggle(isOn: $familiarFaces) { RowLabel("Recognize familiar faces", "Name people in History › Familiar Faces.") }
                Toggle(isOn: $packageAlerts) { RowLabel("Package alerts", "When something is left at the door.") }
                Toggle(isOn: $soundAlerts) { RowLabel("Sound alerts", "Glass breaking, smoke alarms or screaming.") }
            }
            Section {
                Toggle("Daily summary", isOn: $dailySummary.animation())
                if dailySummary {
                    DatePicker("Send it at", selection: minutesBinding($summaryTime), displayedComponents: .hourAndMinute)
                }
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 560, height: dailySummary ? 428 : 390)
    }
}

struct NestPane: View {
    @ObservedObject var model: SettingsModel

    private var dot: Color {
        switch model.connectionHealth {
        case 2: return .green
        case 1: return .orange
        case 3: return .red
        default: return .secondary
        }
    }

    var body: some View {
        Form {
            Section {
                HStack(spacing: 14) {
                    ZStack {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(LinearGradient(colors: [Color(nsColor: .systemOrange), Color(nsColor: .systemRed)],
                                                 startPoint: .top, endPoint: .bottom))
                        Image(systemName: "bell.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                    }
                    .frame(width: 48, height: 48)
                    VStack(alignment: .leading, spacing: 3) {
                        Text(model.connectionTitle).font(.headline)
                        HStack(spacing: 6) {
                            Circle().fill(dot).frame(width: 8, height: 8)
                            Text(model.connectionDetail).font(.callout).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if model.nestAvailable {
                        if model.nestLinked {
                            Button("Disconnect") { model.disconnect() }
                        } else {
                            Button("Connect…") { model.connect() }.buttonStyle(.borderedProminent)
                        }
                    }
                }
                .padding(.vertical, 4)
                if !model.lastEvent.isEmpty {
                    LabeledContent("Last event", value: model.lastEvent)
                }
            } footer: {
                Text("Doorman talks to Google's official Nest API for instant alerts and video. Google may ask you to reconnect every 7 days while the app's Google project is in testing.")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .scrollDisabled(true)
        .frame(width: 560, height: model.lastEvent.isEmpty ? 160 : 196)
    }
}

// MARK: - Window

final class SettingsTabController: NSTabViewController {
    // `alwaysActive` draws the panes as if the window were in front (for README pictures).
    private var alwaysActive = false

    init(model: SettingsModel, alwaysActive: Bool = false) {
        self.alwaysActive = alwaysActive
        super.init(nibName: nil, bundle: nil)
        tabStyle = .toolbar
        transitionOptions = [.crossfade, .allowUserInteraction]
        add(GeneralPane(model: model), "General", "gearshape")
        add(AlertsPane(model: model), "Alerts", "bell.badge")
        add(RecordingPane(model: model), "Recording", "record.circle")
        add(IntelligencePane(model: model), "Intelligence", "sparkles")
        add(NestPane(model: model), "Nest", "video.doorbell", fallback: "house")
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    private func add<V: View>(_ view: V, _ label: String, _ symbol: String, fallback: String? = nil) {
        let host = alwaysActive
            ? NSHostingController(rootView: AnyView(view.environment(\.controlActiveState, .key)))
            : NSHostingController(rootView: AnyView(view))
        host.sizingOptions = [.preferredContentSize]
        host.title = label
        let item = NSTabViewItem(viewController: host)
        item.label = label
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: label)
            ?? fallback.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: label) }
        addTabViewItem(item)
    }

    override func viewDidAppear() {
        super.viewDidAppear()
        fitWindow(animated: false)
    }

    override func tabView(_ tabView: NSTabView, didSelect tabViewItem: NSTabViewItem?) {
        super.tabView(tabView, didSelect: tabViewItem)
        fitWindow(animated: true)
    }

    override func preferredContentSizeDidChange(for viewController: NSViewController) {
        super.preferredContentSizeDidChange(for: viewController)
        if viewController === tabViewItems[selectedTabViewItemIndex].viewController { fitWindow(animated: true) }
    }

    // Grows or shrinks the window to the selected pane, keeping its top edge in place.
    private func fitWindow(animated: Bool) {
        guard let window = view.window,
              let vc = tabViewItems[selectedTabViewItemIndex].viewController else { return }
        var size = vc.preferredContentSize
        if size.width < 10 || size.height < 10 { size = vc.view.fittingSize }
        guard size.width > 10, size.height > 10 else { return }
        let content = window.contentRect(forFrameRect: window.frame)
        guard abs(content.height - size.height) > 1 || abs(content.width - size.width) > 1 else { return }
        var frame = window.frameRect(forContentRect: NSRect(origin: content.origin, size: size))
        frame.origin.y = window.frame.maxY - frame.height
        window.setFrame(frame, display: true, animate: animated && window.isVisible)
    }
}
