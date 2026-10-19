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
    let thumb: URL?
    let lastLine: String?
    var body: some View {
        HStack(spacing: 12) {
            if let thumb {
                Thumb(url: thumb, width: 52, radius: 10)
            } else {
                ZStack {
                    RoundedRectangle(cornerRadius: 11, style: .continuous)
                        .fill(LinearGradient(colors: [Color(nsColor: .systemOrange), Color(nsColor: .systemRed)],
                                             startPoint: .top, endPoint: .bottom))
                    Image(systemName: "bell.fill").font(.system(size: 22, weight: .semibold)).foregroundStyle(.white)
                }
                .frame(width: 52, height: 52)
            }
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
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(width: 300, alignment: .leading)
    }
}

// MARK: - Video

// AppKit's player view, with the standard floating controls.
struct PlayerView: NSViewRepresentable {
    let player: AVPlayer
    func makeNSView(context: Context) -> AVPlayerView {
        let v = AVPlayerView()
        v.player = player
        v.controlsStyle = .floating
        v.videoGravity = .resizeAspect
        v.showsFullScreenToggleButton = true
        v.allowsPictureInPicturePlayback = true
        return v
    }
    func updateNSView(_ v: AVPlayerView, context: Context) {
        if v.player !== player { v.player = player }
    }
}
