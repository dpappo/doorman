// Shortcuts.swift — keyboard shortcuts that work from any app, and the control
// in Settings for changing them.
import Cocoa
import Carbon.HIToolbox
import SwiftUI

struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var modifiers: UInt          // NSEvent.ModifierFlags
    var key: String              // what's printed on the key, e.g. "D"

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    var display: String {
        var s = ""
        if flags.contains(.control) { s += "⌃" }
        if flags.contains(.option) { s += "⌥" }
        if flags.contains(.shift) { s += "⇧" }
        if flags.contains(.command) { s += "⌘" }
        return s + key
    }

    var carbonModifiers: UInt32 {
        var m = 0
        if flags.contains(.command) { m |= cmdKey }
        if flags.contains(.option) { m |= optionKey }
        if flags.contains(.control) { m |= controlKey }
        if flags.contains(.shift) { m |= shiftKey }
        return UInt32(m)
    }

    // Why this can't be used as an everywhere shortcut, or nil if it's fine.
    var problem: String? {
        let held = [NSEvent.ModifierFlags.control, .option, .command].filter { flags.contains($0) }.count
        if held < 2 { return "Use at least two of ⌃ ⌥ ⌘, so it won't clash with other apps or typing." }
        return nil
    }

    // For showing next to a menu item; nil for keys a menu can't show.
    var menuKeyEquivalent: String? {
        if let special = Self.menuKeys[keyCode] { return special }
        return key.count == 1 ? key.lowercased() : nil
    }

    static func from(_ event: NSEvent) -> Shortcut {
        let flags = event.modifierFlags.intersection([.command, .option, .control, .shift])
        let code = UInt32(event.keyCode)
        let name = keyNames[code] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return Shortcut(keyCode: code, modifiers: flags.rawValue, key: name)
    }

    private static let keyNames: [UInt32: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 117: "⌦", 123: "←", 124: "→", 125: "↓", 126: "↑",
        115: "↖", 119: "↘", 116: "⇞", 121: "⇟",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]

    private static let menuKeys: [UInt32: String] = {
        func k(_ c: Int) -> String { String(UnicodeScalar(UInt16(c)).map(Character.init) ?? " ") }
        var m: [UInt32: String] = [49: " ", 36: "\r", 48: "\t",
                                   123: k(NSLeftArrowFunctionKey), 124: k(NSRightArrowFunctionKey),
                                   125: k(NSDownArrowFunctionKey), 126: k(NSUpArrowFunctionKey)]
        let fKeys: [UInt32] = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111]
        for (i, code) in fKeys.enumerated() { m[code] = k(NSF1FunctionKey + i) }
        return m
    }()
}

enum ShortcutAction: String, CaseIterable, Identifiable {
    case liveView, history
    var id: String { rawValue }

    var title: String {
        switch self {
        case .liveView: return "Show or hide Live View"
        case .history: return "Open History"
        }
    }

    // ⌃⌥⌘ plus a letter: almost nothing else on a Mac uses all three.
    var defaultShortcut: Shortcut {
        let all = NSEvent.ModifierFlags([.control, .option, .command]).rawValue
        switch self {
        case .liveView: return Shortcut(keyCode: UInt32(kVK_ANSI_D), modifiers: all, key: "D")
        case .history: return Shortcut(keyCode: UInt32(kVK_ANSI_H), modifiers: all, key: "H")
        }
    }
}

// Registers the shortcuts with macOS so they work whichever app is in front.
// (This kind of shortcut doesn't need any special permission.)
@MainActor
final class HotKeys: ObservableObject {
    static let shared = HotKeys()

    @Published private(set) var shortcuts: [ShortcutAction: Shortcut] = [:]
    @Published private(set) var taken: Set<ShortcutAction> = []      // another app already has it
    var perform: (ShortcutAction) -> Void = { _ in }
    var changed: () -> Void = {}

    private var refs: [ShortcutAction: EventHotKeyRef] = [:]
    private var handlerInstalled = false
    private var paused = false

    private func storageKey(_ a: ShortcutAction) -> String { "shortcut." + a.rawValue }

    func load() {
        let d = UserDefaults.standard
        for a in ShortcutAction.allCases {
            if let data = d.data(forKey: storageKey(a)), let s = try? JSONDecoder().decode(Shortcut.self, from: data) {
                shortcuts[a] = s
            } else if d.string(forKey: storageKey(a)) == "none" {
                shortcuts[a] = nil
            } else {
                shortcuts[a] = a.defaultShortcut
            }
        }
        installHandler()
        registerAll()
    }

    func shortcut(_ a: ShortcutAction) -> Shortcut? { shortcuts[a] }

    func set(_ s: Shortcut?, for a: ShortcutAction) {
        // One shortcut, one job: take it away from anything else that had it.
        if let s {
            for other in ShortcutAction.allCases where other != a && shortcuts[other] == s {
                shortcuts[other] = nil
                save(other)
            }
        }
        shortcuts[a] = s
        save(a)
        registerAll()
        changed()
    }

    func restoreDefaults() {
        for a in ShortcutAction.allCases {
            UserDefaults.standard.removeObject(forKey: storageKey(a))
            shortcuts[a] = a.defaultShortcut
        }
        registerAll()
        changed()
    }

    // While you're typing a new shortcut in Settings, the old ones shouldn't fire.
    func pause(_ on: Bool) {
        guard paused != on else { return }
        paused = on
        registerAll()
    }

    private func save(_ a: ShortcutAction) {
        if let s = shortcuts[a], let data = try? JSONEncoder().encode(s) {
            UserDefaults.standard.set(data, forKey: storageKey(a))
        } else {
            UserDefaults.standard.set("none", forKey: storageKey(a))
        }
    }

    private func registerAll() {
        for ref in refs.values { UnregisterEventHotKey(ref) }
        refs = [:]
        var failed: Set<ShortcutAction> = []
        if !paused {
            for (i, a) in ShortcutAction.allCases.enumerated() {
                guard let s = shortcuts[a] else { continue }
                var ref: EventHotKeyRef?
                let id = EventHotKeyID(signature: OSType(0x44524D4E), id: UInt32(i + 1))   // 'DRMN'
                let status = RegisterEventHotKey(s.keyCode, s.carbonModifiers, id, GetApplicationEventTarget(), 0, &ref)
                if status == noErr, let ref { refs[a] = ref } else { failed.insert(a) }
            }
        }
        if failed != taken { taken = failed }
    }

    private func installHandler() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            var id = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            let index = Int(id.id) - 1
            let all = ShortcutAction.allCases
            guard id.signature == OSType(0x44524D4E), index >= 0, index < all.count else { return OSStatus(eventNotHandledErr) }
            let action = all[index]
            DispatchQueue.main.async { MainActor.assumeIsolated { HotKeys.shared.perform(action) } }
            return noErr
        }, 1, &spec, nil, nil)
    }
}

// Shows a shortcut; click it, then press the keys you want.
struct ShortcutRecorder: View {
    let action: ShortcutAction
    @ObservedObject private var keys = HotKeys.shared
    @State private var recording = false
    @State private var monitor: Any?
    @State private var message: String?

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            HStack(spacing: 6) {
                Button(action: { recording ? stop() : start() }) {
                    Text(label)
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(recording ? Color.accentColor : (keys.shortcut(action) == nil ? .secondary : .primary))
                        .frame(minWidth: 104)
                }
                .help(recording ? "Press the keys you want. Esc cancels." : "Click to change")
                if keys.shortcut(action) != nil && !recording {
                    Button { keys.set(nil, for: action) } label: {
                        Image(systemName: "xmark.circle.fill").foregroundStyle(.tertiary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove this shortcut")
                }
            }
            if let message {
                Text(message).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            } else if keys.taken.contains(action) {
                Text("Another app is already using this shortcut.").font(.caption).foregroundStyle(.orange)
            }
        }
        .onDisappear { stop() }
    }

    private var label: String {
        if recording { return "Type shortcut…" }
        return keys.shortcut(action)?.display ?? "Record Shortcut"
    }

    private func start() {
        message = nil
        recording = true
        keys.pause(true)
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let mods = event.modifierFlags.intersection([.command, .option, .control])
            if event.keyCode == 53 && mods.isEmpty { stop(); return nil }                 // Esc: cancel
            if (event.keyCode == 51 || event.keyCode == 117) && mods.isEmpty {             // Delete: remove
                keys.set(nil, for: action); stop(); return nil
            }
            let s = Shortcut.from(event)
            if let problem = s.problem { message = problem; NSSound.beep(); return nil }
            message = nil
            keys.set(s, for: action)
            stop()
            return nil
        }
    }

    private func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        recording = false
        keys.pause(false)
    }
}
