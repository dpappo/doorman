// Style.swift — shared look: event colours and symbols, the Apple Intelligence
// gradient, thumbnails, chips, empty states and the glass pieces of the live view.
import SwiftUI
import AppKit
import AVKit

// MARK: - Event kinds

enum EventStyle {
    static func kind(_ v: Visit) -> String {
        if !v.names.isEmpty && v.mainKind != "Doorbell ring" && !v.package { return "Known person" }
        return v.mainKind
    }

    static func symbol(_ v: Visit) -> String { symbol(kind: kind(v)) }
    static func color(_ v: Visit) -> Color { Color(nsColor: nsColor(kind: kind(v))) }

    static func symbol(kind: String) -> String {
        switch kind {
        case "Doorbell ring": return "bell.fill"
        case "Package": return "shippingbox.fill"
        case "Person": return "figure.stand"
        case "Known person": return "person.crop.circle.fill"
        case "Sound": return "waveform"
        case "Vehicle": return "car.fill"
        case "Animal": return "pawprint.fill"
        case "Test visit": return "sparkle.magnifyingglass"
        default: return "figure.walk.motion"
        }
    }

    static func nsColor(kind: String) -> NSColor {
        switch kind {
        case "Doorbell ring": return .systemOrange
        case "Package": return .systemBrown
        case "Person": return .systemBlue
        case "Known person": return .systemGreen
        case "Sound": return .systemPurple
        case "Vehicle": return .systemTeal
        case "Animal": return .systemMint
        case "Test visit": return .systemIndigo
        default: return .systemGray
        }
    }

    static func label(_ v: Visit) -> String {
        switch kind(v) {
        case "Doorbell ring": return "Doorbell"
        case "Known person": return v.names.joined(separator: " & ")
        case "Test visit": return "Test"
        default: return kind(v)
        }
    }
}

struct KindBadge: View {
    let visit: Visit
    var size: CGFloat = 26
    var body: some View {
        ZStack {
            Circle().fill(EventStyle.color(visit).gradient)
            Image(systemName: EventStyle.symbol(visit))
                .font(.system(size: size * 0.46, weight: .semibold))
                .foregroundStyle(.white)
        }
        .frame(width: size, height: size)
        .shadow(color: EventStyle.color(visit).opacity(0.35), radius: 3, y: 1)
    }
}

// MARK: - Apple Intelligence look

enum AIStyle {
    static let colors: [Color] = [
        Color(red: 0.03, green: 0.58, blue: 1.0),
        Color(red: 0.79, green: 0.35, blue: 0.87),
        Color(red: 1.0, green: 0.18, blue: 0.33),
        Color(red: 1.0, green: 0.56, blue: 0.02),
    ]
    static var linear: LinearGradient { LinearGradient(colors: colors, startPoint: .topLeading, endPoint: .bottomTrailing) }
    static var angular: AngularGradient { AngularGradient(colors: colors + [colors[0]], center: .center) }
}

struct AIGlyph: View {
    var size: CGFloat = 15
    var body: some View {
        Image(systemName: "sparkles")
            .font(.system(size: size, weight: .semibold))
            .foregroundStyle(AIStyle.linear)
    }
}

struct AICardBackground: View {
    var radius: CGFloat = 16
    var body: some View {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
            .fill(Color.primary.opacity(0.035))
            .overlay(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .strokeBorder(AIStyle.angular, lineWidth: 1.2)
                    .opacity(0.75)
            )
    }
}

// MARK: - Images

final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSURL, NSImage>()
    func image(_ url: URL) -> NSImage? {
        if let i = cache.object(forKey: url as NSURL) { return i }
        guard let i = NSImage(contentsOf: url) else { return nil }
        cache.setObject(i, forKey: url as NSURL)
        return i
    }
    func forget(_ url: URL) { cache.removeObject(forKey: url as NSURL) }
}

struct Thumb: View {
    let url: URL?
    var width: CGFloat = 80
    var height: CGFloat? = nil
    var radius: CGFloat = 10
    var body: some View {
        Group {
            if let url, let img = ImageCache.shared.image(url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    LinearGradient(colors: [Color.secondary.opacity(0.18), Color.secondary.opacity(0.08)],
                                   startPoint: .top, endPoint: .bottom)
                    Image(systemName: "video.slash").foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: width, height: height ?? width)
        .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: radius, style: .continuous).strokeBorder(Color.primary.opacity(0.08)))
    }
}

struct FaceCircle: View {
    let url: URL?
    var size: CGFloat = 88
    var body: some View {
        Group {
            if let url, let img = ImageCache.shared.image(url) {
                Image(nsImage: img).resizable().aspectRatio(contentMode: .fill)
            } else {
                ZStack {
                    Color.secondary.opacity(0.15)
                    Image(systemName: "person.fill").font(.system(size: size * 0.4)).foregroundStyle(.tertiary)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .overlay(Circle().strokeBorder(Color.primary.opacity(0.1)))
        .shadow(color: .black.opacity(0.18), radius: 4, y: 2)
    }
}

// MARK: - Chips

struct Chip: View {
    let text: String
    var symbol: String? = nil
    var tint: Color = .secondary
    var body: some View {
        HStack(spacing: 4) {
            if let symbol { Image(systemName: symbol).font(.system(size: 9, weight: .bold)) }
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.horizontal, 8).padding(.vertical, 3)
        .foregroundStyle(tint == .secondary ? Color.secondary : tint)
        .background(Capsule().fill((tint == .secondary ? Color.secondary : tint).opacity(0.14)))
    }
}

enum ChipStyle {
    static func style(_ tag: String, names: [String]) -> (String?, Color) {
        let t = tag.lowercased()
        if names.contains(tag) { return ("person.fill", .green) }
        if t.contains("package") { return ("shippingbox.fill", .brown) }
        if t.contains("person") || t.contains("people") { return ("person.2.fill", .blue) }
        if ["amazon", "ups", "fedex", "usps", "canada post", "purolator", "dhl", "intelcom"].contains(t) { return ("box.truck.fill", .brown) }
        if ["van", "truck", "car", "vehicle", "bicycle", "police car", "fire truck"].contains(t) { return ("car.fill", .teal) }
        if ["dog", "cat", "bird", "animal"].contains(t) { return ("pawprint.fill", .mint) }
        if ["knocking", "doorbell", "dog barking", "glass breaking", "smoke alarm", "screaming", "shouting", "siren", "speech", "talking"].contains(t) {
            return ("waveform", .purple)
        }
        return (nil, .secondary)
    }
}

struct TagChips: View {
    let tags: [String]
    var names: [String] = []
    var limit = 6
    var body: some View {
        FlowLayout(spacing: 5) {
            ForEach(tags.prefix(limit), id: \.self) { t in
                let s = ChipStyle.style(t, names: names)
                Chip(text: t, symbol: s.0, tint: s.1)
            }
        }
    }
}

// Lays children out left to right, wrapping onto new lines.
struct FlowLayout: Layout {
    var spacing: CGFloat = 6
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > 0 && x + sz.width > maxW { x = 0; y += lineH + spacing; lineH = 0 }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
            widest = max(widest, x - spacing)
        }
        return CGSize(width: min(widest, maxW), height: y + lineH)
    }
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, lineH: CGFloat = 0
        for s in subviews {
            let sz = s.sizeThatFits(.unspecified)
            if x > bounds.minX && x + sz.width > bounds.maxX { x = bounds.minX; y += lineH + spacing; lineH = 0 }
            s.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}

// MARK: - Empty states

struct EmptyState: View {
    let symbol: String
    let title: String
    var message: String? = nil
    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tertiary)
                .padding(.bottom, 4)
            Text(title).font(.title3.weight(.semibold))
            if let message {
                Text(message).font(.callout).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center).frame(maxWidth: 320)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

// MARK: - Glass (live view, AppKit)

// A rounded piece of glass: Liquid Glass on macOS 26, a dark HUD blur before that.
func makeGlass(cornerRadius: CGFloat, content: NSView) -> NSView {
    if #available(macOS 26.0, *) {
        let g = NSGlassEffectView(frame: content.frame)
        g.cornerRadius = cornerRadius
        g.contentView = content
        g.appearance = NSAppearance(named: .darkAqua)
        return g
    }
    let fx = NSVisualEffectView(frame: content.frame)
    fx.material = .hudWindow
    fx.blendingMode = .withinWindow
    fx.state = .active
    fx.appearance = NSAppearance(named: .vibrantDark)
    fx.wantsLayer = true
    fx.layer?.cornerRadius = cornerRadius
    fx.layer?.cornerCurve = .continuous
    fx.layer?.masksToBounds = true
    content.frame = fx.bounds
    content.autoresizingMask = [.width, .height]
    fx.addSubview(content)
    return fx
}

// The AI's one-line description of the latest visit, floating at the top of the live view.
final class CaptionPill: NSView {
    private let label = NSTextField(labelWithString: "")
    private let icon = NSImageView()
    private var glass: NSView!
    private let inner = NSView()

    override init(frame: NSRect) {
        super.init(frame: frame)
        label.font = .systemFont(ofSize: 12.5, weight: .semibold)
        label.textColor = .white
        label.lineBreakMode = .byTruncatingTail
        label.cell?.truncatesLastVisibleLine = true
        icon.image = NSImage(systemSymbolName: "sparkles", accessibilityDescription: nil)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 11, weight: .bold))
        icon.contentTintColor = .white
        inner.addSubview(icon)
        inner.addSubview(label)
        inner.frame = bounds
        glass = makeGlass(cornerRadius: 15, content: inner)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        alphaValue = 0
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    // Sizes itself to the text and centres at the top of `container`.
    func show(_ text: String, in container: NSView, top: CGFloat) {
        label.stringValue = text
        let textW = ceil(label.attributedStringValue.size().width)
        let w = min(textW + 50, container.bounds.width - 24)
        let h: CGFloat = 30
        frame = NSRect(x: (container.bounds.width - w) / 2, y: container.bounds.height - top - h, width: w, height: h)
        inner.frame = NSRect(x: 0, y: 0, width: w, height: h)
        icon.frame = NSRect(x: 13, y: (h - 14) / 2, width: 14, height: 14)
        label.frame = NSRect(x: 32, y: (h - 17) / 2, width: w - 32 - 14, height: 17)
        autoresizingMask = [.minXMargin, .maxXMargin, .minYMargin]
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; animator().alphaValue = 1 }
    }

    func hide() {
        NSAnimationContext.runAnimationGroup { $0.duration = 0.35; animator().alphaValue = 0 }
    }
}

// MARK: - Menu bar

// Rounded thumbnail for menu items.
func roundedMenuImage(_ url: URL?, size: CGFloat = 34) -> NSImage? {
    guard let url, let src = ImageCache.shared.image(url) else { return nil }
    let img = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        NSBezierPath(roundedRect: rect, xRadius: 7, yRadius: 7).addClip()
        let s = src.size
        let side = min(s.width, s.height)
        let from = NSRect(x: (s.width - side) / 2, y: (s.height - side) / 2, width: side, height: side)
        src.draw(in: rect, from: from, operation: .copy, fraction: 1)
        return true
    }
    return img
}

struct MenuHeader: View {
    let title: String
    let detail: String
    let statusColor: Color
    let lastLine: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.system(size: 13, weight: .semibold))
            HStack(spacing: 5) {
                Circle().fill(statusColor).frame(width: 7, height: 7)
                Text(detail).font(.system(size: 11)).foregroundStyle(.secondary)
            }
            if let lastLine {
                Text(lastLine).font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(1)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 8)
        .padding(.bottom, 7)
        .frame(width: MenuLive.width, alignment: .leading)
    }
}

enum MenuLive {
    static let width: CGFloat = 300
    static let inset: CGFloat = 6
}

// Drawn over the live picture at the top of the menu.
struct MenuLiveOverlay: View {
    let live: Bool
    var body: some View {
        VStack {
            HStack {
                if live {
                    HStack(spacing: 4) {
                        Circle().fill(Color.red).frame(width: 6, height: 6)
                        Text("LIVE").font(.system(size: 10, weight: .bold)).tracking(0.4)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 7).padding(.vertical, 3)
                    .background(.black.opacity(0.45), in: Capsule())
                }
                Spacer()
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(.white)
                    .frame(width: 22, height: 22)
                    .background(.black.opacity(0.45), in: Circle())
            }
            Spacer()
        }
        .padding(8)
    }
}

// Shown in place of the picture when there's nothing live to show.
struct MenuLivePlaceholder: View {
    let symbol: String
    let message: String
    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: symbol).font(.system(size: 24, weight: .regular))
            Text(message).font(.system(size: 11, weight: .medium)).multilineTextAlignment(.center)
        }
        .foregroundStyle(.white.opacity(0.7))
        .padding(.horizontal, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(LinearGradient(colors: [Color(white: 0.16), Color(white: 0.08)], startPoint: .top, endPoint: .bottom))
    }
}

// MARK: - Video

// AppKit's player view, with the standard floating controls.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .none          // our own controls sit below the picture
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}

// Keeps playback state in step with an AVPlayer for the controls below the video.
@MainActor
final class PlayerModel: ObservableObject {
    @Published var time: Double = 0
    @Published var duration: Double = 0
    @Published var playing = false
    @Published var muted = false
    @Published var scrubbing = false
    private(set) var player: AVPlayer?
    private var timeToken: Any?
    private var statusObserver: NSKeyValueObservation?

    func attach(_ p: AVPlayer?) {
        guard p !== player else { return }
        detach()
        player = p
        guard let p else { return }
        muted = p.isMuted
        timeToken = p.addPeriodicTimeObserver(forInterval: CMTime(seconds: 0.2, preferredTimescale: 600), queue: .main) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self, !self.scrubbing else { return }
                self.time = t.seconds.isFinite ? t.seconds : 0
                let d = p.currentItem?.duration.seconds ?? 0
                self.duration = d.isFinite ? d : 0
            }
        }
        statusObserver = p.observe(\.timeControlStatus, options: [.initial, .new]) { [weak self] p, _ in
            let on = p.timeControlStatus != .paused
            DispatchQueue.main.async { self?.playing = on }
        }
    }

    func detach() {
        if let t = timeToken { player?.removeTimeObserver(t) }
        timeToken = nil
        statusObserver = nil
        player = nil
        time = 0; duration = 0; playing = false
    }

    func togglePlay() {
        guard let p = player else { return }
        if p.timeControlStatus == .paused {
            if duration > 0 && time >= duration - 0.3 { seek(to: 0) }
            p.play()
        } else { p.pause() }
    }

    func seek(to t: Double) {
        time = t
        player?.seek(to: CMTime(seconds: max(0, t), preferredTimescale: 600), toleranceBefore: .zero, toleranceAfter: .zero)
    }

    func skip(_ by: Double) { seek(to: min(max(0, time + by), max(duration - 0.1, 0))) }

    func toggleMute() {
        guard let p = player else { return }
        p.isMuted.toggle()
        muted = p.isMuted
    }
}

// Play/pause, skip, a scrubber and sound — under the video, never over it.
struct PlayerControls: View {
    @ObservedObject var model: PlayerModel
    // Turns a position in the clip into the time of day it was filmed.
    var clock: ((Double) -> Date?)? = nil

    private static let clockFormat: DateFormatter = { let f = DateFormatter(); f.dateFormat = "h:mm:ss a"; return f }()

    private func mmss(_ s: Double) -> String {
        let t = Int(max(0, s).rounded())
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    var body: some View {
        HStack(spacing: 12) {
            Button { model.skip(-10) } label: { Image(systemName: "gobackward.10") }
                .help("Back 10 seconds")
            Button { model.togglePlay() } label: {
                Image(systemName: model.playing ? "pause.fill" : "play.fill").font(.system(size: 17)).frame(width: 20)
            }
            .help(model.playing ? "Pause" : "Play")
            Button { model.skip(10) } label: { Image(systemName: "goforward.10") }
                .help("Forward 10 seconds")

            Text(clock?(model.time).map { Self.clockFormat.string(from: $0) } ?? mmss(model.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: clock == nil ? 34 : 74, alignment: .leading)

            Slider(value: Binding(get: { min(model.time, max(model.duration, 0.01)) },
                                  set: { model.seek(to: $0) }),
                   in: 0...max(model.duration, 0.01)) { editing in
                model.scrubbing = editing
            }
            .controlSize(.small)

            Text("-" + mmss(model.duration - model.time))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(minWidth: 38, alignment: .trailing)

            Button { model.toggleMute() } label: {
                Image(systemName: model.muted ? "speaker.slash.fill" : "speaker.wave.2.fill").frame(width: 18)
            }
            .help(model.muted ? "Sound on" : "Mute")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 14, weight: .medium))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.primary.opacity(0.05)))
        .disabled(model.player == nil)
    }
}
