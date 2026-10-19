// Doorman — a menu bar app for a Google Nest doorbell: instant alerts, a floating
// live view, 24/7 recording and on-device intelligence (see README.md).
import Cocoa
import WebKit
import ServiceManagement
import Network
import SwiftUI
import UserNotifications
import CoreMediaIO
import CoreAudio

// MARK: - Direct live stream (Nest API, WebRTC)

// A tiny local page that plays the doorbell's live stream straight from the Nest API.
// The app relays the connection offer/answer to Google; no Google Home page involved.
let nestPlayerHTML = """
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;height:100%;background:#000;overflow:hidden;cursor:default}
video{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain;background:#000}
#msg{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;color:#8a8a8a;font:13px -apple-system,system-ui}
</style></head><body>
<video id="v" autoplay playsinline muted></video>
<div id="msg">Connecting to your doorbell…</div>
<script>
(function () {
  var v = document.getElementById('v'), msg = document.getElementById('msg');
  function post(m) { try { window.webkit.messageHandlers.nestStream.postMessage(m); } catch (e) {} }
  function reportSize() {
    if (v.videoWidth && v.videoHeight) {
      try { window.webkit.messageHandlers.pipAspect.postMessage({ w: v.videoWidth, h: v.videoHeight }); } catch (e) {}
    }
  }
  var pc = new RTCPeerConnection({ bundlePolicy: 'max-bundle' });
  pc.addTransceiver('audio', { direction: 'recvonly' });
  pc.addTransceiver('video', { direction: 'recvonly' });
  pc.createDataChannel('dataSendChannel');
  var stream = new MediaStream();
  pc.ontrack = function (e) { stream.addTrack(e.track); v.srcObject = stream; };
  v.addEventListener('playing', function () { msg.style.display = 'none'; post({ kind: 'playing' }); });
  v.addEventListener('loadedmetadata', reportSize);
  v.addEventListener('resize', reportSize);
  pc.onconnectionstatechange = function () {
    if (pc.connectionState === 'failed') post({ kind: 'failed', error: 'connection failed' });
  };
  window.setAnswer = function (sdp) {
    pc.setRemoteDescription({ type: 'answer', sdp: sdp })
      .catch(function (e) { post({ kind: 'failed', error: String(e) }); });
  };
  window.showMessage = function (t) { msg.textContent = t; msg.style.display = 'flex'; };
  window.closeStream = function () { try { pc.close(); } catch (e) {} };
  pc.createOffer().then(function (o) { return pc.setLocalDescription(o); }).then(function () {
    var sent = false;
    function send() { if (!sent) { sent = true; post({ kind: 'offer', sdp: pc.localDescription.sdp }); } }
    if (pc.iceGatheringState === 'complete') { send(); return; }
    pc.onicegatheringstatechange = function () { if (pc.iceGatheringState === 'complete') send(); };
    setTimeout(send, 1500);
  }).catch(function (e) { post({ kind: 'failed', error: String(e) }); });
})();
</script></body></html>
"""

// Finds the biggest video on the page and stretches it to fill the window,
// hiding everything else. Does nothing until a video actually appears, so
// sign-in pages look normal.
let videoOnlyScriptTemplate = """
(function () {
  if (location.hostname === 'localhost') return;   // our own Nest player needs no help
  if (window.__pip) { window.__pip.set(__ENABLED__); return; }
  var enabled = __ENABLED__, target = null, styleEl = null, coverEl = null, lastSize = '';
  var CSS =
    'html,body{background:#000 !important;overflow:hidden !important}' +
    'body *{visibility:hidden !important}' +
    // Neutralise anything around the video that would trap or crop it.
    '[data-pip-ancestor]{transform:none !important;filter:none !important;' +
    'perspective:none !important;contain:none !important;will-change:auto !important;' +
    'backdrop-filter:none !important;-webkit-backdrop-filter:none !important;' +
    'clip-path:none !important;-webkit-mask:none !important;mask:none !important;' +
    'overflow:visible !important;opacity:1 !important}' +
    'html[data-pip-ancestor],body[data-pip-ancestor]{overflow:hidden !important}' +
    '[data-pip-target]{visibility:visible !important;position:fixed !important;' +
    'top:0 !important;left:0 !important;right:auto !important;bottom:auto !important;' +
    'width:100vw !important;height:100vh !important;' +
    'min-width:0 !important;min-height:0 !important;' +
    'max-width:none !important;max-height:none !important;margin:0 !important;' +
    'padding:0 !important;border:0 !important;border-radius:0 !important;' +
    'object-fit:contain !important;object-position:center !important;' +
    'transform:none !important;clip-path:none !important;' +
    'z-index:2147483647 !important;background:#000 !important}';

  function biggest(selector) {
    var best = null, bestArea = 40000;
    document.querySelectorAll(selector).forEach(function (el) {
      var r = el.getBoundingClientRect(), a = r.width * r.height;
      if (a > bestArea) { bestArea = a; best = el; }
    });
    return best;
  }
  function report(w, h) {
    var key = w + 'x' + h;
    if (key === lastSize) return;
    lastSize = key;
    try { window.webkit.messageHandlers.pipAspect.postMessage({ w: w, h: h }); } catch (e) {}
  }
  function release() {
    if (styleEl) { styleEl.remove(); styleEl = null; }
    if (coverEl) { coverEl.remove(); coverEl = null; }
    document.querySelectorAll('[data-pip-ancestor]').forEach(function (el) {
      el.removeAttribute('data-pip-ancestor');
    });
    if (target) target.removeAttribute('data-pip-target');
    target = null;
  }
  function markAncestors(el) {
    for (var p = el.parentElement; p; p = p.parentElement) p.setAttribute('data-pip-ancestor', '');
  }
  function tick() {
    if (!enabled) return;
    if (!target || !target.isConnected) {
      release();
      target = biggest('video') || biggest('canvas');
      if (!target) {
        // Keep Google's page (and its pop-up notices) hidden until the video shows up.
        if (location.hostname === 'home.google.com' && (!coverEl || !coverEl.isConnected)) {
          coverEl = document.createElement('style');
          coverEl.textContent = 'html,body{background:#000 !important}body{visibility:hidden !important}';
          (document.head || document.documentElement).appendChild(coverEl);
        }
        return;
      }
      target.setAttribute('data-pip-target', '');
      markAncestors(target);
    }
    if (!styleEl || !styleEl.isConnected) {
      styleEl = document.createElement('style');
      styleEl.textContent = CSS;
      (document.head || document.documentElement).appendChild(styleEl);
    }
    var w = target.videoWidth || target.width || 0;
    var h = target.videoHeight || target.height || 0;
    if (w > 0 && h > 0) report(w, h);
  }
  window.__pip = {
    set: function (v) {
      enabled = v;
      if (!v) { release(); report(0, 0); } else { lastSize = ''; tick(); }
    }
  };
  setInterval(tick, 1000);
  tick();
})();
"""

// A see-through strip across the top of the window. Drag it to move the window,
// double-click it to zoom. It fades in a soft shadow while the pointer is over the window.
final class DragBar: NSView {
    private let shade = CAGradientLayer()

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        shade.colors = [NSColor.black.withAlphaComponent(0.55).cgColor, NSColor.clear.cgColor]
        shade.startPoint = CGPoint(x: 0.5, y: 1)   // dark at the top edge…
        shade.endPoint = CGPoint(x: 0.5, y: 0)     // …fading out downward
        layer?.addSublayer(shade)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        shade.frame = bounds
        CATransaction.commit()
    }

    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    // Move the window ourselves so dragging works the same whether or not
    // the app is in front.
    private var grabPoint: NSPoint?
    private var grabFrame: NSRect = .zero

    private func screenPoint(_ event: NSEvent) -> NSPoint? {
        guard let window else { return nil }
        return window.convertPoint(toScreen: event.locationInWindow)
    }
    override func mouseDown(with event: NSEvent) {
        if event.clickCount == 2 { window?.performZoom(nil); return }
        grabPoint = screenPoint(event)
        grabFrame = window?.frame ?? .zero
        NSCursor.closedHand.push()
    }
    override func mouseDragged(with event: NSEvent) {
        guard let start = grabPoint, let now = screenPoint(event), let window else { return }
        window.setFrameOrigin(NSPoint(x: grabFrame.minX + now.x - start.x,
                                      y: grabFrame.minY + now.y - start.y))
    }
    override func mouseUp(with event: NSEvent) {
        if grabPoint != nil { NSCursor.pop() }
        grabPoint = nil
    }
    override func resetCursorRects() { addCursorRect(bounds, cursor: .openHand) }
}

// A button that works on the first click, even when the app isn't in front.
final class FirstClickButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

// Small floating controls at the bottom of the live view: sound, talk, snapshot.
final class ControlBar: NSView {
    let sound = FirstClickButton()
    let talk = FirstClickButton()
    let snapshot = FirstClickButton()
    var onSound: (() -> Void)?
    var onTalk: (() -> Void)?
    var onSnapshot: (() -> Void)?

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 156, height: 46))
        appearance = NSAppearance(named: .darkAqua)

        let stack = NSStackView(views: [sound, talk, snapshot])
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.distribution = .equalSpacing
        stack.edgeInsets = NSEdgeInsets(top: 5, left: 12, bottom: 5, right: 12)
        stack.frame = bounds
        let glass = makeGlass(cornerRadius: 23, content: stack)
        glass.frame = bounds
        glass.autoresizingMask = [.width, .height]
        addSubview(glass)
        shadow = {
            let s = NSShadow()
            s.shadowColor = NSColor.black.withAlphaComponent(0.3)
            s.shadowBlurRadius = 10
            s.shadowOffset = NSSize(width: 0, height: -2)
            return s
        }()
        for b in [sound, talk, snapshot] {
            b.isBordered = false
            b.imagePosition = .imageOnly
            b.contentTintColor = .white
            b.target = self
            b.translatesAutoresizingMaskIntoConstraints = false
            b.widthAnchor.constraint(equalToConstant: 38).isActive = true
            b.heightAnchor.constraint(equalToConstant: 36).isActive = true
        }
        sound.action = #selector(tappedSound)
        talk.action = #selector(tappedTalk)
        snapshot.action = #selector(tappedSnapshot)
        update(muted: true, talk: .off)
        setSnapshotDone(false)
    }
    required init?(coder: NSCoder) { fatalError("not used") }

    enum TalkState { case off, starting, on }

    private func symbol(_ name: String, _ label: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: label)?
            .withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: 16, weight: .medium))
    }

    func update(muted: Bool, talk state: TalkState) {
        sound.image = symbol(muted ? "speaker.slash.fill" : "speaker.wave.2.fill",
                             muted ? "Turn sound on" : "Turn sound off")
        sound.toolTip = muted ? "Turn sound on" : "Turn sound off"
        switch state {
        case .off:
            talk.image = symbol("mic.fill", "Talk through the doorbell")
            talk.contentTintColor = .white
            talk.toolTip = "Talk through the doorbell"
        case .starting:
            talk.image = symbol("mic.badge.plus", "Starting to talk…")
            talk.contentTintColor = .systemOrange
            talk.toolTip = "Starting… (allow the microphone if asked)"
        case .on:
            talk.image = symbol("mic.fill", "Stop talking")
            talk.contentTintColor = .systemRed
            talk.toolTip = "You're live at the door. Click to stop talking"
        }
    }

    func setSnapshotDone(_ done: Bool) {
        snapshot.image = symbol(done ? "checkmark.circle.fill" : "camera.fill",
                                done ? "Snapshot saved" : "Save a snapshot")
        snapshot.contentTintColor = done ? .systemGreen : .white
        snapshot.toolTip = done ? "Saved to Pictures ▸ Doorman" : "Save a snapshot to Pictures"
    }

    @objc private func tappedSound() { onSound?() }
    @objc private func tappedTalk() { onTalk?() }
    @objc private func tappedSnapshot() { onSnapshot?() }
}

// The window's content: reports when the pointer enters or leaves the window.
final class HoverView: NSView {
    var onHover: ((Bool) -> Void)?
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
                                       options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }
    override func mouseEntered(with event: NSEvent) { onHover?(true) }
    override func mouseExited(with event: NSEvent) { onHover?(false) }
}

// MARK: - Watching for visitors


// Runs inside a hidden copy of the camera's event list. Live video is switched
// off there, so it costs almost no data. Google refreshes the list about every
// 30 seconds by itself; this script reports what the list contains.
let watcherScript = """
(function () {
  function Off() { throw new DOMException('Live video is off while watching', 'NotSupportedError'); }
  try { Object.defineProperty(window, 'RTCPeerConnection', { value: Off, configurable: false, writable: false }); } catch (e) {}
  try { Object.defineProperty(window, 'webkitRTCPeerConnection', { value: Off, configurable: false, writable: false }); } catch (e) {}

  // Make the page believe it is on screen, so it keeps refreshing.
  try {
    Object.defineProperty(Document.prototype, 'visibilityState', { get: function () { return 'visible'; }, configurable: true });
    Object.defineProperty(Document.prototype, 'hidden', { get: function () { return false; }, configurable: true });
    Object.defineProperty(Document.prototype, 'webkitVisibilityState', { get: function () { return 'visible'; }, configurable: true });
    Object.defineProperty(Document.prototype, 'webkitHidden', { get: function () { return false; }, configurable: true });
    Document.prototype.hasFocus = function () { return true; };
    document.addEventListener('visibilitychange', function (e) { e.stopImmediatePropagation(); }, true);
    window.addEventListener('blur', function (e) { e.stopImmediatePropagation(); }, true);
  } catch (e) {}

  function post(msg) { try { window.webkit.messageHandlers.doorbellWatch.postMessage(msg); } catch (e) {} }

  var open = XMLHttpRequest.prototype.open;
  XMLHttpRequest.prototype.open = function (method, url) {
    try { if (String(url).indexOf('ListTimelinePeriods') >= 0) post({ kind: 'poll' }); } catch (e) {}
    return open.apply(this, arguments);
  };

  var last = null;
  function scan() {
    var rows = document.querySelectorAll('a.event[data-time]');
    var items = [];
    for (var i = 0; i < rows.length && i < 20; i++) {
      items.push({ t: Number(rows[i].getAttribute('data-time')) || 0, label: rows[i].getAttribute('aria-label') || '' });
    }
    var key = JSON.stringify(items);
    if (key !== last) { last = key; post({ kind: 'events', items: items }); }
  }
  setInterval(scan, 2000);
  document.addEventListener('DOMContentLoaded', function () { post({ kind: 'loaded', host: location.host }); scan(); });
})();
"""

// MARK: - Instant alerts through Google's official Nest API

struct NestConfig: Decodable {
    let clientId: String
    let clientSecret: String
    let redirectUri: String
    let cloudProjectId: String
    let subscription: String
    let deviceAccessProjectId: String
    let googleHomeCameraURL: String?     // optional: your camera's page on home.google.com
}

// nest-config.json is copied into the app when it's built (see README.md).
let nestConfigFile: NestConfig? = {
    guard let url = Bundle.main.url(forResource: "nest-config", withExtension: "json"),
          let data = try? Data(contentsOf: url) else { return nil }
    return try? JSONDecoder().decode(NestConfig.self, from: data)
}()

// Your camera's page on home.google.com, e.g. https://home.google.com/u/0/home/…/cameras/list/…
// Optional. It powers Talk (through Google's page) and the slower backup event check.
let cameraPageURL: String? = {
    guard var s = nestConfigFile?.googleHomeCameraURL?.trimmingCharacters(in: .whitespacesAndNewlines), !s.isEmpty,
          !s.contains("YOUR-") else { return nil }
    if let q = s.firstIndex(of: "?") { s = String(s[..<q]) }
    while s.hasSuffix("/") { s.removeLast() }
    if s.hasSuffix("/events") { s.removeLast("/events".count) }
    return s
}()
let homeURL = URL(string: cameraPageURL.map { $0 + "?da=true" } ?? "https://home.google.com/")!
let eventsURL: URL? = cameraPageURL.flatMap { URL(string: $0 + "/events") }

// Keeps the long-lived Google sign-in in a private file only your account can read.
enum NestTokenStore {
    static var fileURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Doorman", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        return dir.appendingPathComponent("nest-token")
    }
    static func read() -> String? {
        guard let s = try? String(contentsOf: fileURL, encoding: .utf8) else { return nil }
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
    static func save(_ token: String) {
        FileManager.default.createFile(atPath: fileURL.path, contents: Data(token.utf8),
                                       attributes: [.posixPermissions: 0o600])
    }
    static func delete() { try? FileManager.default.removeItem(at: fileURL) }
}

enum NestError: Error {
    case notLinked
    case other(String)
}

@MainActor
final class NestLink {
    enum State: Equatable { case notConfigured, notLinked, linking, connecting, connected, problem(String) }

    var state: State = .notLinked { didSet { if state != oldValue { onChange?() } } }
    var lastCheck: Date?
    var deviceNames: [String] = []
    var cameraDevice: String?          // e.g. enterprises/…/devices/… (supports WebRTC live view)
    var onChange: (() -> Void)?
    var onEvent: ((String) -> Void)?

    private let config: NestConfig?
    private var accessToken: String?
    private var tokenExpiry = Date.distantPast
    private var listener: NWListener?
    private var expectedState = ""
    private var pulling = false
    private var listedDevices = false
    private var seen: [String: Date] = [:]
    private let session: URLSession = {
        let c = URLSessionConfiguration.default
        c.timeoutIntervalForRequest = 120
        c.timeoutIntervalForResource = 150
        return URLSession(configuration: c)
    }()

    init() {
        if let url = Bundle.main.url(forResource: "nest-config", withExtension: "json"),
           let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(NestConfig.self, from: data) {
            config = cfg
        } else {
            config = nil
        }
    }

    func start() {
        if config == nil { state = .notConfigured; return }
        if NestTokenStore.read() != nil { state = .connecting; startPulling() } else { state = .notLinked }
    }

    var isConnected: Bool { state == .connected }

    // MARK: Linking (one-time Google sign-in in your browser)

    func link() {
        guard let cfg = config else { return }
        stopListener()
        expectedState = UUID().uuidString
        do {
            let params = NWParameters.tcp
            params.requiredInterfaceType = .loopback
            params.allowLocalEndpointReuse = true
            let l = try NWListener(using: params, on: 8765)
            l.newConnectionHandler = { [weak self] conn in
                Task { @MainActor in self?.handle(conn) }
            }
            l.start(queue: .main)
            listener = l
        } catch {
            state = .problem("Couldn't listen for the sign-in reply")
            return
        }
        var comps = URLComponents(string: "https://nestservices.google.com/partnerconnections/\(cfg.deviceAccessProjectId)/auth")!
        comps.queryItems = [
            URLQueryItem(name: "redirect_uri", value: cfg.redirectUri),
            URLQueryItem(name: "access_type", value: "offline"),
            URLQueryItem(name: "prompt", value: "consent"),
            URLQueryItem(name: "client_id", value: cfg.clientId),
            URLQueryItem(name: "response_type", value: "code"),
            URLQueryItem(name: "scope", value: "https://www.googleapis.com/auth/sdm.service https://www.googleapis.com/auth/pubsub"),
            URLQueryItem(name: "state", value: expectedState),
        ]
        state = .linking
        NSWorkspace.shared.open(comps.url!)
    }

    func cancelLink() {
        stopListener()
        state = NestTokenStore.read() == nil ? .notLinked : .connecting
    }

    func unlink() {
        pulling = false
        stopListener()
        NestTokenStore.delete()
        accessToken = nil
        listedDevices = false
        state = .notLinked
    }

    private func stopListener() {
        listener?.cancel()
        listener = nil
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: .main)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 32768) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { conn.cancel(); return }
                let text = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
                let parts = (text.components(separatedBy: "\r\n").first ?? "").split(separator: " ")
                guard parts.count >= 2,
                      let comps = URLComponents(string: "http://localhost" + parts[1]),
                      comps.path == "/callback" else {
                    self.reply(conn, status: "404 Not Found", body: "")
                    return
                }
                let item = { (name: String) in comps.queryItems?.first(where: { $0.name == name })?.value }
                let code = item("code")
                let ok = code != nil && item("state") == self.expectedState
                self.reply(conn, status: "200 OK", body: Self.page(ok: ok))
                self.stopListener()
                if ok, let code {
                    await self.exchange(code)
                } else {
                    self.state = .problem(item("error") == "access_denied" ? "Sign-in was cancelled" : "Sign-in didn't complete")
                }
            }
        }
    }

    private func reply(_ conn: NWConnection, status: String, body: String) {
        let bytes = Data(body.utf8)
        let head = "HTTP/1.1 \(status)\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(bytes.count)\r\nConnection: close\r\n\r\n"
        conn.send(content: Data(head.utf8) + bytes, completion: .contentProcessed { _ in conn.cancel() })
    }

    private static func page(ok: Bool) -> String {
        let title = ok ? "Doorman is connected" : "Doorman couldn't connect"
        let note = ok ? "Doorman will now pop up the moment someone rings or is seen. You can close this tab."
                      : "Something went wrong. Try “Connect Nest” again from the bell menu."
        return "<!doctype html><meta charset=utf-8><title>\(title)</title><body style=\"font:16px -apple-system,system-ui;max-width:420px;margin:15vh auto;padding:0 16px;color:#222\"><h2>\(title)</h2><p>\(note)</p></body>"
    }

    // MARK: Google requests

    private func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        let s = fields.map { "\($0.key)=\($0.value.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")" }
            .joined(separator: "&")
        return Data(s.utf8)
    }

    private func tokenRequest(_ fields: [String: String]) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = formBody(fields)
        let (data, _) = try await session.data(for: req)
        return (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
    }

    private func exchange(_ code: String) async {
        guard let cfg = config else { return }
        state = .connecting
        do {
            let json = try await tokenRequest([
                "code": code, "client_id": cfg.clientId, "client_secret": cfg.clientSecret,
                "redirect_uri": cfg.redirectUri, "grant_type": "authorization_code",
            ])
            guard let refresh = json["refresh_token"] as? String else {
                state = .problem((json["error_description"] as? String) ?? "Google didn't return a sign-in")
                return
            }
            NestTokenStore.save(refresh)
            if let access = json["access_token"] as? String {
                accessToken = access
                tokenExpiry = Date().addingTimeInterval(((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600) - 60)
            }
            listedDevices = false
            startPulling()
        } catch {
            state = .problem("Couldn't reach Google")
        }
    }

    private func token() async throws -> String {
        if let t = accessToken, Date() < tokenExpiry { return t }
        guard let cfg = config, let refresh = NestTokenStore.read() else { throw NestError.notLinked }
        let json = try await tokenRequest([
            "refresh_token": refresh, "client_id": cfg.clientId, "client_secret": cfg.clientSecret,
            "grant_type": "refresh_token",
        ])
        if let t = json["access_token"] as? String {
            accessToken = t
            tokenExpiry = Date().addingTimeInterval(((json["expires_in"] as? NSNumber)?.doubleValue ?? 3600) - 60)
            return t
        }
        if (json["error"] as? String) == "invalid_grant" {
            NestTokenStore.delete()
            throw NestError.notLinked
        }
        throw NestError.other((json["error_description"] as? String) ?? "Couldn't refresh the Google sign-in")
    }

    private func call(_ url: String, body: [String: Any]? = nil) async throws -> [String: Any] {
        var req = URLRequest(url: URL(string: url)!)
        req.httpMethod = body == nil ? "GET" : "POST"
        req.setValue("Bearer \(try await token())", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let (data, resp) = try await session.data(for: req)
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        let json = (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
        if status == 401 { accessToken = nil }
        if status >= 400 {
            let message = ((json["error"] as? [String: Any])?["message"] as? String) ?? "HTTP \(status)"
            throw NestError.other(message)
        }
        return json
    }

    // Google only starts sending events after the device list has been read once.
    private func listDevices() async throws {
        guard let cfg = config else { return }
        let json = try await call("https://smartdevicemanagement.googleapis.com/v1/enterprises/\(cfg.deviceAccessProjectId)/devices")
        let devices = json["devices"] as? [[String: Any]] ?? []
        deviceNames = devices.compactMap { d in
            let traits = d["traits"] as? [String: Any]
            let custom = (traits?["sdm.devices.traits.Info"] as? [String: Any])?["customName"] as? String
            let room = ((d["parentRelations"] as? [[String: Any]])?.first)?["displayName"] as? String
            return (custom?.isEmpty == false ? custom : room) ?? (d["type"] as? String)
        }
        let cameras = devices.filter { d in
            let live = (d["traits"] as? [String: Any])?["sdm.devices.traits.CameraLiveStream"] as? [String: Any]
            return (live?["supportedProtocols"] as? [String] ?? []).contains("WEB_RTC")
        }
        let doorbell = cameras.first { ($0["type"] as? String ?? "").hasSuffix("DOORBELL") } ?? cameras.first
        cameraDevice = doorbell?["name"] as? String
        listedDevices = true
    }

    // MARK: Live stream commands

    private func command(_ name: String, _ params: [String: Any]) async throws -> [String: Any] {
        guard let device = cameraDevice else { throw NestError.other("No camera found") }
        let json = try await call("https://smartdevicemanagement.googleapis.com/v1/\(device):executeCommand",
                                  body: ["command": "sdm.devices.commands.CameraLiveStream." + name, "params": params])
        return json["results"] as? [String: Any] ?? [:]
    }

    func startStream(offer: String) async throws -> (answer: String, session: String, expires: Date) {
        let r = try await command("GenerateWebRtcStream", ["offerSdp": offer])
        guard let answer = r["answerSdp"] as? String, let session = r["mediaSessionId"] as? String else {
            throw NestError.other("Google didn't start the stream")
        }
        let expires = (r["expiresAt"] as? String).flatMap(Self.parseDate) ?? Date().addingTimeInterval(300)
        return (answer, session, expires)
    }

    func extendStream(_ session: String) async throws -> (session: String, expires: Date) {
        let r = try await command("ExtendWebRtcStream", ["mediaSessionId": session])
        let newSession = r["mediaSessionId"] as? String ?? session
        let expires = (r["expiresAt"] as? String).flatMap(Self.parseDate) ?? Date().addingTimeInterval(300)
        return (newSession, expires)
    }

    func stopStream(_ session: String) async {
        _ = try? await command("StopWebRtcStream", ["mediaSessionId": session])
    }

    // MARK: Event feed

    func startPulling() {
        guard !pulling, config != nil else { return }
        pulling = true
        Task { await pullLoop() }
    }

    // After sleep, try again straight away instead of waiting out a back-off.
    func kick() {
        if pulling { wakeUp = true } else if NestTokenStore.read() != nil { startPulling() }
    }
    private var wakeUp = false

    private func pullLoop() async {
        guard let cfg = config else { return }
        var delay: Double = 2
        while pulling {
            let started = Date()
            do {
                if !listedDevices { try await listDevices() }
                let json = try await call("https://pubsub.googleapis.com/v1/\(cfg.subscription):pull",
                                          body: ["maxMessages": 20])
                lastCheck = Date()
                if state != .connected { state = .connected } else { onChange?() }
                delay = 2
                var acks: [String] = []
                for m in json["receivedMessages"] as? [[String: Any]] ?? [] {
                    if let id = m["ackId"] as? String { acks.append(id) }
                    if let msg = m["message"] as? [String: Any] { handle(message: msg) }
                }
                if !acks.isEmpty {
                    _ = try? await call("https://pubsub.googleapis.com/v1/\(cfg.subscription):acknowledge",
                                        body: ["ackIds": acks])
                }
                // Google normally holds the request open until something happens;
                // if it answered instantly with nothing, pause briefly.
                if acks.isEmpty && Date().timeIntervalSince(started) < 1 {
                    try? await Task.sleep(nanoseconds: 2_000_000_000)
                }
            } catch NestError.notLinked {
                pulling = false
                accessToken = nil
                state = .notLinked
                return
            } catch NestError.other(let message) {
                state = .problem(message)
                await backOff(&delay)
            } catch {
                state = .problem("Can't reach Google (offline?)")
                await backOff(&delay)
            }
        }
    }

    private func backOff(_ delay: inout Double) async {
        let wait = delay
        delay = min(delay * 2, 60)
        var waited = 0.0
        while waited < wait && !wakeUp && pulling {
            try? await Task.sleep(nanoseconds: 500_000_000)
            waited += 0.5
        }
        if wakeUp { wakeUp = false; delay = 2 }
    }

    private func handle(message msg: [String: Any]) {
        guard let b64 = msg["data"] as? String,
              let data = Data(base64Encoded: b64),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let update = json["resourceUpdate"] as? [String: Any],
              let events = update["events"] as? [String: Any] else { return }

        // Ignore anything stale (e.g. delivered after the Mac was asleep).
        if let ts = json["timestamp"] as? String, let when = Self.parseDate(ts),
           Date().timeIntervalSince(when) > 120 { return }

        let thread = (json["eventThreadId"] as? String) ?? (json["eventId"] as? String) ?? UUID().uuidString
        for key in events.keys {
            let kind: String
            if key.hasSuffix("DoorbellChime.Chime") { kind = "Doorbell ring" }
            else if key.hasSuffix("CameraPerson.Person") { kind = "Person" }
            else if key.hasSuffix("CameraMotion.Motion") { kind = "Motion" }
            else if key.hasSuffix("CameraSound.Sound") { kind = "Sound" }
            else { continue }
            let id = thread + "|" + kind
            if seen[id] != nil { continue }      // one pop-up per visit, not per update
            seen[id] = Date()
            onEvent?(kind)
        }
        seen = seen.filter { Date().timeIntervalSince($0.value) < 3600 }
    }

    private static func parseDate(_ s: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: s) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: s)
    }
}

// MARK: - Are you on a call?

// True while any camera or the default microphone is in use by any app
// (Zoom, Meet, FaceTime, Teams…), which is a good sign you're in a meeting.
enum CallDetector {
    static func isOnCall() -> Bool { cameraInUse() || microphoneInUse() }

    static func cameraInUse() -> Bool {
        var addr = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        let system = CMIOObjectID(kCMIOObjectSystemObject)
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(system, &addr, 0, nil, &size) == 0, size > 0 else { return false }
        var ids = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(system, &addr, 0, nil, size, &used, &ids) == 0 else { return false }
        for id in ids {
            var running: UInt32 = 0
            var runningUsed: UInt32 = 0
            var a = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeWildcard),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementWildcard))
            if CMIOObjectGetPropertyData(id, &a, 0, nil, UInt32(MemoryLayout<UInt32>.size), &runningUsed, &running) == 0,
               running != 0 { return true }
        }
        return false
    }

    static func microphoneInUse() -> Bool {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultInputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &device) == noErr,
              device != 0 else { return false }
        var running: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        addr.mSelector = kAudioDevicePropertyDeviceIsRunningSomewhere
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &running) == noErr else { return false }
        return running != 0
    }
}

enum PopMode: String { case people, everything, off }

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSWindowDelegate, NSMenuDelegate,
                         WKUIDelegate, WKNavigationDelegate, WKScriptMessageHandler,
                         UNUserNotificationCenterDelegate {
    let defaults = UserDefaults.standard

    // Live view window
    var window: NSWindow!
    var webView: WKWebView!
    var dragBar: DragBar!
    var pointerInside = false
    var liveLoaded = false
    var shownByEvent = false
    var hideDeadline: Date?
    static let dragBarHeight: CGFloat = 32

    // Background watcher
    var watcher: WKWebView!
    var watcherLoadedAt = Date()
    var lastCheck: Date?
    var lastSeen = Date().timeIntervalSince1970 * 1000   // only events after launch can pop up
    var latestEvent: (kind: String, time: Date)?
    var needsSignIn = false
    var watcherPaused = false        // the web watcher rests while the Nest API is connected
    let nest = NestLink()
    var history: HistoryStore!
    var faces: FaceLibrary!
    var engine: CameraEngine!
    var intel: Intelligence!
    var historyWindow: NSWindow?
    let historyModel = HistoryUIModel()
    var liveUsesEngine = false
    var pendingDescriptive = Set<String>()
    var caption: CaptionPill!
    var captionUntil: Date?
    var ticks = 0

    // Menu bar
    var statusItem: NSStatusItem!
    let statusMenu = NSMenu()
    var appStatusItem: NSMenuItem!
    var videoOnlyItem: NSMenuItem!
    var onTopItem: NSMenuItem!
    var activity: NSObjectProtocol?

    // Settings window and newer behaviours
    var settingsWindow: NSWindow?
    let settingsModel = SettingsModel()
    var appliedVideoOnly = true
    var prewarmUntil: Date?
    var usingDirectStream = false
    var streamSession: String?
    var streamExpires: Date?
    var extendingStream = false
    var controlBar: ControlBar!
    var liveMuted = true
    var talkState: ControlBar.TalkState = .off
    var pendingTalk = false
    var unhealthySince: Date?
    var warnedUnhealthy = false
    var lastNestState: NestLink.State = .notConfigured

    // MARK: Settings

    var videoOnly: Bool {
        get { defaults.object(forKey: "videoOnly") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "videoOnly") }
    }
    var keepOnTop: Bool {
        get { defaults.object(forKey: "keepOnTop") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "keepOnTop") }
    }
    var popMode: PopMode {
        get { PopMode(rawValue: defaults.string(forKey: "popMode") ?? "") ?? .people }
        set { defaults.set(newValue.rawValue, forKey: "popMode") }
    }
    var hideAfter: TimeInterval {
        get { let v = defaults.double(forKey: "hideAfter"); return v > 0 ? v : 60 }
        set { defaults.set(newValue, forKey: "hideAfter") }
    }
    var playSound: Bool {
        get { defaults.object(forKey: "playSound") as? Bool ?? true }
        set { defaults.set(newValue, forKey: "playSound") }
    }

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        migrateFromOldName()
        NSApp.setActivationPolicy(.accessory)   // menu bar only, no Dock icon
        // Stop macOS from putting the watcher to sleep while the app sits in the background.
        activity = ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep],
                                                         reason: "Watching the doorbell for visitors")
        buildViewer()
        buildWatcher()
        buildMainMenu()
        buildStatusItem()
        setUpLoginItemOnce()
        setUpPremium()
        nest.onChange = { [weak self] in self?.nestChanged() }
        nest.onEvent = { [weak self] kind in self?.handleNestEvent(kind) }
        nest.start()
        setUpSettings()

        _ = Timer.scheduledTimer(timeInterval: 1, target: self, selector: #selector(tick),
                             userInfo: nil, repeats: true)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake),
                                                          name: NSWorkspace.didWakeNotification, object: nil)
        refreshStatus()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    // Opening the app again (from Applications or Spotlight) shows the live view.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLive(activate: true)
        return false
    }

    // MARK: Live view window

    func buildViewer() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()                 // remembers your Google sign-in
        config.mediaTypesRequiringUserActionForPlayback = []  // let the live feed autoplay
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15" // look like Safari so Google allows sign-in
        config.preferences.isElementFullscreenEnabled = true
        installVideoOnlyScript(into: config.userContentController)
        config.userContentController.add(self, name: "pipAspect")
        config.userContentController.add(self, name: "nestStream")

        webView = WKWebView(frame: .zero, configuration: config)
        webView.uiDelegate = self
        webView.navigationDelegate = self
        webView.allowsMagnification = true

        window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 360),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Doorman"
        window.delegate = self

        let container = HoverView(frame: NSRect(x: 0, y: 0, width: 480, height: 360))
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        container.addSubview(webView)
        dragBar = DragBar(frame: NSRect(x: 0, y: container.bounds.height - Self.dragBarHeight,
                                        width: container.bounds.width, height: Self.dragBarHeight))
        dragBar.autoresizingMask = [.width, .minYMargin]
        container.addSubview(dragBar)
        controlBar = ControlBar()
        controlBar.frame.origin = NSPoint(x: (container.bounds.width - controlBar.frame.width) / 2, y: 12)
        controlBar.autoresizingMask = [.minXMargin, .maxXMargin, .maxYMargin]
        controlBar.alphaValue = 0
        controlBar.onSound = { [weak self] in self?.toggleSound() }
        controlBar.onTalk = { [weak self] in self?.toggleTalk() }
        controlBar.onSnapshot = { [weak self] in self?.saveSnapshot() }
        container.addSubview(controlBar)
        caption = CaptionPill(frame: NSRect(x: 0, y: 0, width: 200, height: 30))
        container.addSubview(caption)
        container.onHover = { [weak self] inside in
            self?.pointerInside = inside
            self?.updateOverlay(animated: true)
        }
        window.contentView = container
        window.minSize = NSSize(width: 160, height: 120)
        window.backgroundColor = .black
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary] // follow you across desktops
        window.center()
        window.setFrameAutosaveName("DoorbellPiPWindow")     // remembers size and position

        applyOnTop()
        applyWindowChrome()
    }

    // Uses the direct Nest stream when possible, otherwise the Google Home page.
    func loadLiveContent() {
        resetControls()
        if let engine, engine.isReady {
            usingDirectStream = false
            liveUsesEngine = true
            engine.attach(to: window.contentView!, below: dragBar)
            webView.isHidden = true
            liveLoaded = true
            if videoOnly, let s = engine.videoSize { lockAspect(width: s.width, height: s.height) }
            return
        }
        let preferDirect = defaults.object(forKey: "directStream") as? Bool ?? true
        if preferDirect && nest.isConnected && nest.cameraDevice != nil {
            usingDirectStream = true
            webView.loadHTMLString(nestPlayerHTML, baseURL: URL(string: "https://localhost/"))
        } else {
            usingDirectStream = false
            webView.load(URLRequest(url: homeURL))
        }
        liveLoaded = true
    }

    func unloadLiveContent() {
        if talkState != .off { pressGoogleTalk(expectOn: false, attempt: 0) }
        resetControls()
        if liveUsesEngine {
            engine.detach()
            liveUsesEngine = false
            webView.isHidden = false
            liveLoaded = false
            return
        }
        endDirectStream()
        webView.load(URLRequest(url: URL(string: "about:blank")!))
        liveLoaded = false
    }

    func endDirectStream() {
        if let session = streamSession {
            webView.evaluateJavaScript("window.closeStream && window.closeStream()", completionHandler: nil)
            Task { await nest.stopStream(session) }
        }
        streamSession = nil
        streamExpires = nil
        extendingStream = false
    }

    // If the direct stream can't start, quietly use the Google Home page instead.
    func fallBackToWebPage() {
        if liveUsesEngine {
            engine.detach()
            liveUsesEngine = false
        }
        webView.isHidden = false
        endDirectStream()
        usingDirectStream = false
        webView.load(URLRequest(url: homeURL))
        liveLoaded = true
    }

    func handleStreamMessage(_ body: [String: Any]) {
        guard usingDirectStream, let kind = body["kind"] as? String else { return }
        switch kind {
        case "offer":
            guard let sdp = body["sdp"] as? String else { return }
            Task {
                do {
                    let r = try await nest.startStream(offer: sdp)
                    guard self.usingDirectStream, self.liveLoaded else { await self.nest.stopStream(r.session); return }
                    self.streamSession = r.session
                    self.streamExpires = r.expires
                    let js = String(data: try JSONEncoder().encode(r.answer), encoding: .utf8) ?? "\"\""
                    self.webView.evaluateJavaScript("setAnswer(\(js))", completionHandler: nil)
                } catch {
                    self.fallBackToWebPage()
                }
            }
        case "failed":
            fallBackToWebPage()
        default:
            break
        }
    }

    // Nest streams last 5 minutes; renew shortly before they run out.
    func keepDirectStreamAlive() {
        guard usingDirectStream, liveLoaded, !extendingStream,
              let session = streamSession, let expires = streamExpires,
              Date() > expires.addingTimeInterval(-45) else { return }
        extendingStream = true
        Task {
            defer { self.extendingStream = false }
            do {
                let r = try await nest.extendStream(session)
                self.streamSession = r.session
                self.streamExpires = r.expires
            } catch {
                if self.window.isVisible { self.loadLiveContent() }   // start a fresh stream
            }
        }
    }

    // MARK: Live view controls

    func resetControls() {
        liveMuted = true
        talkState = .off
        pendingTalk = false
        controlBar?.update(muted: true, talk: .off)
        updateOverlay(animated: false)
    }

    func applyMute() {
        if liveUsesEngine {
            engine.setMuted(liveMuted)
            controlBar.update(muted: liveMuted, talk: talkState)
            return
        }
        let js = "document.querySelectorAll('video').forEach(function (v) { v.muted = \(liveMuted ? "true" : "false"); });"
        webView.evaluateJavaScript(js, completionHandler: nil)
        controlBar.update(muted: liveMuted, talk: talkState)
    }

    func toggleSound() {
        liveMuted.toggle()
        applyMute()
    }

    // Talking needs Google's own player (the Nest API stream is listen-only),
    // so the first press switches over quietly and switches its microphone on.
    func toggleTalk() {
        switch talkState {
        case .off:
            talkState = .starting
            controlBar.update(muted: liveMuted, talk: talkState)
            updateOverlay(animated: true)
            if usingDirectStream || !liveLoaded || liveUsesEngine {
                pendingTalk = true
                fallBackToWebPage()
                talkState = .starting
                controlBar.update(muted: liveMuted, talk: talkState)
                // Normally Talk switches on as soon as the video appears; this is a backstop.
                DispatchQueue.main.asyncAfter(deadline: .now() + 8) { [weak self] in
                    guard let self, self.pendingTalk else { return }
                    self.pendingTalk = false
                    self.pressGoogleTalk(expectOn: true, attempt: 0)
                }
            } else {
                pressGoogleTalk(expectOn: true, attempt: 0)
            }
        case .starting, .on:
            pendingTalk = false
            pressGoogleTalk(expectOn: false, attempt: 0)
            talkState = .off
            controlBar.update(muted: liveMuted, talk: .off)
            updateOverlay(animated: true)
        }
    }

    // Clicks Google's "Talk and Listen" button inside the page, then checks it took.
    func pressGoogleTalk(expectOn: Bool, attempt: Int) {
        let js = """
        (function () {
          var b = document.querySelector('button[aria-label="Talk and Listen"]');
          if (!b) return 'missing';
          var on = (b.innerText || '').indexOf('mic_off') < 0;
          if (on !== \(expectOn ? "true" : "false")) b.click();
          return 'clicked';
        })()
        """
        webView.evaluateJavaScript(js) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                if (result as? String) == "missing" {
                    if attempt < 15 && (self.talkState == .starting || !expectOn) {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                            self.pressGoogleTalk(expectOn: expectOn, attempt: attempt + 1)
                        }
                    } else if expectOn {
                        self.talkState = .off
                        self.controlBar.update(muted: self.liveMuted, talk: .off)
                        NSSound.beep()
                    }
                    return
                }
                if expectOn { self.confirmTalking(attempt: 0) }
            }
        }
    }

    func confirmTalking(attempt: Int) {
        let js = "(function(){var b=document.querySelector('button[aria-label=\"Talk and Listen\"]');return b?(b.innerText||''):'';})()"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
            guard let self, self.talkState == .starting else { return }
            self.webView.evaluateJavaScript(js) { result, _ in
                MainActor.assumeIsolated {
                    let text = (result as? String) ?? ""
                    if text.contains("mic") && !text.contains("mic_off") {
                        self.talkState = .on
                        self.liveMuted = false            // Talk and Listen plays their voice too
                        self.controlBar.update(muted: false, talk: .on)
                    } else if attempt < 8 {
                        self.confirmTalking(attempt: attempt + 1)
                    } else {
                        self.talkState = .off
                        self.controlBar.update(muted: self.liveMuted, talk: .off)
                        NSSound.beep()
                    }
                    self.updateOverlay(animated: true)
                }
            }
        }
    }

    // Saves the current frame as a JPEG in Pictures ▸ Doorman.
    func saveSnapshot() {
        let js = """
        (function () {
          var best = null, area = 0;
          document.querySelectorAll('video').forEach(function (v) {
            var a = v.videoWidth * v.videoHeight; if (a > area) { area = a; best = v; }
          });
          if (!best) return '';
          var c = document.createElement('canvas');
          c.width = best.videoWidth; c.height = best.videoHeight;
          c.getContext('2d').drawImage(best, 0, 0);
          return c.toDataURL('image/jpeg', 0.92);
        })()
        """
        let target: WKWebView = liveUsesEngine ? engine.webView : webView
        target.evaluateJavaScript(js) { [weak self] result, _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard let url = result as? String, let comma = url.firstIndex(of: ","),
                      let data = Data(base64Encoded: String(url[url.index(after: comma)...])) else {
                    NSSound.beep()
                    return
                }
                let dir = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
                    .appendingPathComponent("Doorman", isDirectory: true)
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let f = DateFormatter()
                f.dateFormat = "yyyy-MM-dd 'at' h.mm.ss a"
                let file = dir.appendingPathComponent("Doorbell \(f.string(from: Date())).jpg")
                do {
                    try data.write(to: file)
                    NSSound(named: "Tink")?.play()
                    self.controlBar.setSnapshotDone(true)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 2) { self.controlBar.setSnapshotDone(false) }
                } catch {
                    NSSound.beep()
                }
            }
        }
    }

    func showLive(activate: Bool) {
        prewarmUntil = nil
        // A window shrunk to a sliver (or never sized) gets a sensible size near the top right.
        if window.frame.width < 200 || window.frame.height < 160, let vf = NSScreen.main?.visibleFrame {
            window.setFrame(NSRect(x: vf.maxX - 420 - 20, y: vf.maxY - 420 - 20, width: 420, height: 420), display: false)
        }
        if !liveLoaded { loadLiveContent() }
        keepOnScreen()
        window.orderFrontRegardless()
        if activate {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
        refreshStatus()
    }

    // Hides the window and stops the stream, so nothing downloads while it's away.
    func stopLive() {
        window.orderOut(nil)
        unloadLiveContent()
        shownByEvent = false
        hideDeadline = nil
        refreshStatus()
    }

    // The close button hides the window instead of quitting; the app keeps watching.
    func windowShouldClose(_ sender: NSWindow) -> Bool {
        stopLive()
        return false
    }

    @objc func toggleLive(_ sender: Any?) {
        if window.isVisible {
            stopLive()
        } else {
            shownByEvent = false
            showLive(activate: true)
        }
    }

    // MARK: Pop-ups

    func wants(_ kind: String) -> Bool {
        switch popMode {
        case .off: return false
        case .everything: return true
        case .people:
            return kind.range(of: "person|face|package|ring|doorbell|press|visitor|knock",
                              options: [.regularExpression, .caseInsensitive]) != nil
        }
    }

    func popUp(for kind: String) {
        hideDeadline = Date().addingTimeInterval(hideAfter)
        if !window.isVisible { shownByEvent = true }   // a window you opened yourself stays open
        showLive(activate: false)                      // appears without taking over your keyboard
        if playSound { NSSound(named: "Glass")?.play() }
    }

    @objc func testPopUp(_ sender: Any?) { popUp(for: "Test") }

    // MARK: Alert rules (calls, quiet hours, notifications)

    enum AlertAction: String { case popup, notify, silent }

    var inQuietHours: Bool {
        guard defaults.bool(forKey: "quietEnabled") else { return false }
        let start = defaults.object(forKey: "quietStart") as? Int ?? 22 * 60
        let end = defaults.object(forKey: "quietEnd") as? Int ?? 7 * 60
        let c = Calendar.current.dateComponents([.hour, .minute], from: Date())
        let now = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start <= end ? (now >= start && now < end) : (now >= start || now < end)
    }

    // Decides how a visitor should be announced right now.
    func currentAction() -> AlertAction {
        if inQuietHours {
            return AlertAction(rawValue: defaults.string(forKey: "quietAction") ?? "") ?? .notify
        }
        let busy = AlertAction(rawValue: defaults.string(forKey: "busyAction") ?? "") ?? .notify
        if busy != .popup && !window.isVisible && CallDetector.isOnCall() { return busy }
        return .popup
    }

    func alert(for kind: String, visitId: String? = nil) {
        switch currentAction() {
        case .popup:
            popUp(for: kind)
        case .notify:
            // Wait a few seconds for an on-device description, then fall back to a plain alert.
            if let visitId, engine?.isReady == true, defaults.object(forKey: "aiDescriptions") as? Bool ?? true {
                pendingDescriptive.insert(visitId)
                DispatchQueue.main.asyncAfter(deadline: .now() + 12) { [weak self] in
                    guard let self, self.pendingDescriptive.remove(visitId) != nil else { return }
                    self.notifyWithSnapshot(title: kind == "Doorbell ring" ? "Someone rang the doorbell" : "\(kind) at the front door",
                                            body: "Click to see the live view.", action: "live", visitId: visitId)
                }
                return
            }
            let title: String
            switch kind {
            case "Doorbell ring": title = "Someone rang the doorbell"
            case "Test": title = "Test alert from Doorman"
            default: title = "\(kind) at the front door"
            }
            notifyWithSnapshot(title: title, body: "Click to see the live view.", action: "live", visitId: visitId)
        case .silent:
            break
        }
    }

    @objc func sendTestAlert(_ sender: Any?) { alert(for: "Test") }

    // Starts loading the live view out of sight, so it's ready if a ring follows.
    func prewarm() {
        if engine?.isReady == true { return }          // the always-on stream is already instant
        guard defaults.object(forKey: "prewarm") as? Bool ?? true,
              popMode != .off, !liveLoaded, currentAction() == .popup else { return }
        loadLiveContent()
        prewarmUntil = Date().addingTimeInterval(90)
    }

    func setUpNotifications() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    }

    func notify(title: String, body: String, action: String, visitId: String? = nil, image: URL? = nil) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        if playSound { content.sound = .default }
        content.userInfo = ["action": action, "visit": visitId ?? ""]
        content.threadIdentifier = "doorbell"
        // A picture of the door. The system takes ownership of the file, so hand it a copy.
        var picture = image
        if picture == nil, let visitId, let v = history?.visit(visitId) { picture = history.thumbnailURL(v) }
        if let picture, FileManager.default.fileExists(atPath: picture.path) {
            let copy = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
            if (try? FileManager.default.copyItem(at: picture, to: copy)) != nil,
               let att = try? UNNotificationAttachment(identifier: "snapshot", url: copy, options: nil) {
                content.attachments = [att]
            }
        }
        UNUserNotificationCenter.current().add(
            UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }

    // Notifies with the visit's thumbnail, or a fresh frame from the camera.
    func notifyWithSnapshot(title: String, body: String, action: String, visitId: String?) {
        if let visitId, let v = history?.visit(visitId), v.thumbnail != nil {
            notify(title: title, body: body, action: action, visitId: visitId)
            return
        }
        guard let engine, engine.isReady else {
            notify(title: title, body: body, action: action, visitId: visitId)
            return
        }
        Task { @MainActor in
            var url: URL?
            if let frame = await engine.captureFrame(maxSide: 1024),
               let jpg = NSBitmapImageRep(cgImage: frame).representation(using: .jpeg, properties: [.compressionFactor: 0.8]) {
                let u = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".jpg")
                if (try? jpg.write(to: u)) != nil { url = u }
            }
            self.notify(title: title, body: body, action: action, visitId: visitId, image: url)
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let action = response.notification.request.content.userInfo["action"] as? String ?? "live"
        let visitId = response.notification.request.content.userInfo["visit"] as? String ?? ""
        DispatchQueue.main.async {
            MainActor.assumeIsolated {
                switch action {
                case "reconnect": self.nest.link()
                case "signin": self.signIn(nil)
                case "history":
                    if let v = self.history.visit(visitId) { self.historyModel.show(v) }
                    self.openHistory(nil)
                default:
                    self.shownByEvent = false
                    self.showLive(activate: true)
                }
            }
        }
        completionHandler()
    }

    // Warns once if neither the Nest feed nor the web watcher has checked in for 5 minutes.
    func checkAlertHealth() {
        guard defaults.object(forKey: "healthAlerts") as? Bool ?? true, popMode != .off else {
            unhealthySince = nil
            return
        }
        let last = watcherPaused ? nest.lastCheck : lastCheck
        let healthy = last.map { Date().timeIntervalSince($0) < 300 } ?? false
        if healthy {
            unhealthySince = nil
            warnedUnhealthy = false
            return
        }
        if unhealthySince == nil { unhealthySince = Date() }
        if !warnedUnhealthy, let since = unhealthySince, Date().timeIntervalSince(since) > 300 {
            warnedUnhealthy = true
            if needsSignIn && !watcherPaused {
                notify(title: "Doorbell alerts aren't working",
                       body: "Google Home needs you to sign in again. Click to sign in.", action: "signin")
            } else {
                notify(title: "Doorbell alerts aren't working",
                       body: "Doorman can't reach Google right now. It will keep retrying.", action: "live")
            }
        }
    }

    // MARK: Settings window

    func setUpSettings() {
        setUpNotifications()
        appliedVideoOnly = videoOnly
        lastNestState = nest.state
        settingsModel.connect = { [weak self] in self?.nest.link() }
        settingsModel.disconnect = { [weak self] in self?.disconnectNest(nil) }
        settingsModel.sendTest = { [weak self] in self?.sendTestAlert(nil) }
        settingsModel.setLogin = { [weak self] on in
            do {
                if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch { NSSound.beep() }
            self?.updateSettingsModel()
        }
        NotificationCenter.default.addObserver(self, selector: #selector(defaultsChanged),
                                               name: UserDefaults.didChangeNotification, object: nil)
        updateSettingsModel()
    }

    // Settings changed (from the window or a menu): apply them straight away.
    @objc func defaultsChanged() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            if self.window.level != (self.keepOnTop ? .floating : .normal) { self.applyOnTop() }
            self.applyVideoOnly()
            self.updateEngine()
            let gb = self.defaults.object(forKey: "storageGB") as? Double ?? 10
            if gb != self.appliedStorageGB { self.appliedStorageGB = gb; self.history?.enforceCap() }
            let days = self.defaults.object(forKey: "historyDays") as? Int ?? 60
            if days != self.appliedHistoryDays { self.appliedHistoryDays = days; self.history?.pruneOldVisits() }
            self.refreshStatus()
        }
    }

    func updateSettingsModel() {
        let m = settingsModel
        if let history {
            let used = ByteCountFormatter.string(fromByteCount: history.usedBytes, countStyle: .file)
            let cap = ByteCountFormatter.string(fromByteCount: history.capBytes, countStyle: .file)
            var t = "\(used) of \(cap) used"
            if let oldest = history.oldestFootage {
                let hours = Int(Date().timeIntervalSince(oldest) / 3600)
                let mins = Int(Date().timeIntervalSince(oldest) / 60)
                if hours >= 48 { t += " · \(hours / 24) days of footage" }
                else if hours >= 1 { t += " · \(hours) hour\(hours == 1 ? "" : "s") of footage" }
                else { t += " · \(max(mins, 0)) minutes of footage" }
            }
            m.storageText = t
            m.usedBytes = history.usedBytes
            m.capBytes = history.capBytes
        }
        m.aiAvailable = HomeAI.isAvailable
        if let engine, engine.running, engine.isReady, engine.recordingEnabled {
            m.recordingText = "Saving continuous video from your doorbell"
        } else {
            m.recordingText = recordingStatus
        }
        m.openHistory = { [weak self] in self?.openHistory(nil) }
        m.loginEnabled = SMAppService.mainApp.status == .enabled
        m.nestAvailable = nest.state != .notConfigured
        m.nestLinked = !(nest.state == .notLinked || nest.state == .notConfigured)
        switch nest.state {
        case .connected:
            let names = nest.deviceNames.joined(separator: ", ")
            m.connectionTitle = names.isEmpty ? "Google Nest" : names
            m.connectionDetail = "Connected · instant alerts on"
            m.connectionHealth = 2
        case .connecting:
            m.connectionTitle = "Google Nest"
            m.connectionDetail = "Connecting…"
            m.connectionHealth = 1
        case .linking:
            m.connectionTitle = "Google Nest"
            m.connectionDetail = "Finish signing in to Google in your browser"
            m.connectionHealth = 1
        case .problem(let message):
            m.connectionTitle = "Google Nest"
            m.connectionDetail = message
            m.connectionHealth = 3
        case .notLinked:
            m.connectionTitle = "Google Nest"
            m.connectionDetail = "Not connected · using the slower Google Home page check"
            m.connectionHealth = 0
        case .notConfigured:
            m.connectionTitle = "Google Nest"
            m.connectionDetail = "Not set up · using the Google Home page check"
            m.connectionHealth = 0
        }
        if let e = latestEvent { m.lastEvent = "\(e.kind), \(timeString(e.time))" } else { m.lastEvent = "" }
    }

    @objc func openSettings(_ sender: Any?) {
        updateSettingsModel()
        if settingsWindow == nil {
            let tabs = SettingsTabController(model: settingsModel)
            let w = NSWindow(contentViewController: tabs)
            w.styleMask = [.titled, .closable]
            w.toolbarStyle = .preference
            w.isReleasedWhenClosed = false
            w.center()
            settingsWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    @objc func tick() {
        ticks += 1
        // Auto-hide a pop-up once things go quiet, unless you're looking at it.
        if shownByEvent, window.isVisible {
            if window.isKeyWindow {
                shownByEvent = false                    // you clicked it, so it stays until you close it
            } else if pointerInside {
                hideDeadline = Date().addingTimeInterval(15)
            } else if let deadline = hideDeadline, Date() > deadline {
                stopLive()
            }
        }
        // A pre-loaded live view that nobody needed: unload it again.
        if let until = prewarmUntil, Date() > until {
            prewarmUntil = nil
            if !window.isVisible && liveLoaded { unloadLiveContent() }
        }
        keepDirectStreamAlive()
        engine?.tick()
        if let until = captionUntil, Date() > until {
            captionUntil = nil
            caption.hide()
        }
        if ticks % 30 == 0 {
            checkWatcherHealth()
            checkAlertHealth()
        }
        if ticks % 60 == 0 { intel?.tick() }
        if ticks % 3 == 0, let dir = defaults.string(forKey: "snapshotDir") {
            defaults.removeObject(forKey: "snapshotDir")
            Task { await self.makeSnapshots(into: dir) }
        }
        if ticks % 3600 == 0 { history?.pruneOldVisits() }
        if ticks % 10 == 0 && settingsWindow?.isVisible == true { updateSettingsModel() }
    }

    // MARK: Watcher

    func buildWatcher() {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()
        config.mediaTypesRequiringUserActionForPlayback = .all   // never play clips in the background
        config.applicationNameForUserAgent = "Version/18.0 Safari/605.1.15"
        if #available(macOS 14.0, *) { config.preferences.inactiveSchedulingPolicy = .none }
        config.userContentController.addUserScript(WKUserScript(source: watcherScript,
                                                                injectionTime: .atDocumentStart,
                                                                forMainFrameOnly: true))
        config.userContentController.add(self, name: "doorbellWatch")
        watcher = WKWebView(frame: NSRect(x: 0, y: 0, width: 1280, height: 900), configuration: config)
        watcher.navigationDelegate = self
        reloadWatcher()
    }

    func reloadWatcher() {
        watcherLoadedAt = Date()
        guard let eventsURL else { return }      // no camera page set up: rely on the Nest API alone
        watcher.load(URLRequest(url: eventsURL))
    }

    @objc func checkNow(_ sender: Any?) {
        if watcherPaused { nest.kick() } else { reloadWatcher() }
    }

    @objc func didWake() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 5) { [weak self] in
            guard let self else { return }
            self.nest.kick()
            if !self.watcherPaused { self.reloadWatcher() }
        }
    }

    // MARK: Nest API

    // While the official Nest connection works, the slower web-page watcher rests.
    // If the connection drops, the web watcher takes over again.
    func nestChanged() {
        if lastNestState == .connected && nest.state == .notLinked {
            notify(title: "Instant doorbell alerts paused",
                   body: "Google's sign-in expired. Click to reconnect (takes a few seconds).", action: "reconnect")
        }
        lastNestState = nest.state
        updateEngine()
        if nest.isConnected && !watcherPaused {
            watcherPaused = true
            needsSignIn = false
            watcher.load(URLRequest(url: URL(string: "about:blank")!))
        } else if !nest.isConnected && watcherPaused && nest.state != .connecting {
            watcherPaused = false
            reloadWatcher()
        }
        refreshStatus()
    }

    // MARK: Premium features (24/7 recording, history, on-device intelligence)

    var appliedStorageGB: Double = 10
    var appliedHistoryDays = 60

    func setUpPremium() {
        history = HistoryStore()
        faces = FaceLibrary()
        engine = CameraEngine(nest: nest, history: history)
        intel = Intelligence(history: history, faces: faces, engine: engine)
        appliedStorageGB = defaults.object(forKey: "storageGB") as? Double ?? 10
        appliedHistoryDays = defaults.object(forKey: "historyDays") as? Int ?? 60
        history.refreshNames { [weak self] in self?.faces.nameForSample($0) }
        engine.onAspect = { [weak self] w, h in
            guard let self, self.liveUsesEngine, self.videoOnly else { return }
            self.lockAspect(width: w, height: h)
        }
        engine.onStateChange = { [weak self] in self?.refreshStatus() }
        intel.notify = { [weak self] title, body, action, visitId in
            self?.notify(title: title, body: body, action: action, visitId: visitId)
        }
        intel.wantsDescriptiveNotification = { [weak self] id in self?.pendingDescriptive.remove(id) != nil }
        intel.onVisitUpdated = { [weak self] v in self?.showCaption(for: v) }
    }

    var recordingStatus: String {
        guard let engine, engine.running else { return "Recording is off" }
        if !engine.isReady { return engine.lastError.map { "Reconnecting… (\($0))" } ?? "Connecting to your doorbell…" }
        let used = ByteCountFormatter.string(fromByteCount: history.usedBytes, countStyle: .file)
        let cap = ByteCountFormatter.string(fromByteCount: history.capBytes, countStyle: .file)
        return engine.recordingEnabled ? "Recording 24/7 · \(used) of \(cap)" : "Live stream ready"
    }

    // 24/7 recording runs whenever Nest is connected and recording is switched on.
    func updateEngine() {
        guard let engine else { return }
        let want = defaults.object(forKey: "record247") as? Bool ?? true
        if want && nest.isConnected && nest.cameraDevice != nil {
            if !engine.running { engine.start(record: true) }
        } else if !want || nest.state == .notLinked || nest.state == .notConfigured {
            if engine.running {
                if liveUsesEngine { stopLive() }
                engine.stop()
            }
        }
    }

    // Shows the AI's headline on the live view for a little while.
    func showCaption(for v: Visit) {
        guard window.isVisible, let latest = history.visits.first, latest.id == v.id else { return }
        guard let container = window.contentView else { return }
        caption.show(v.title, in: container, top: Self.dragBarHeight + 6)
        captionUntil = Date().addingTimeInterval(20)
    }

    // A window that always draws as the frontmost one (used only for README pictures).
    final class SnapshotWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var isMainWindow: Bool { true }
    }

    // Saves pictures of the app's windows for the README. Started by
    // `defaults write com.dan.doorbellpip snapshotDir /path/to/folder`.
    func makeSnapshots(into dir: String) async {
        let out = URL(fileURLWithPath: dir, isDirectory: true)
        try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        func pause(_ s: Double) async { try? await Task.sleep(nanoseconds: UInt64(s * 1_000_000_000)) }
        // Always saved at Retina (2x) resolution, whatever screen the window is on.
        func save(_ w: NSWindow?, _ name: String) {
            guard let w, let view = w.contentView?.superview else { return }
            let b = view.bounds
            guard let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(b.width * 2), pixelsHigh: Int(b.height * 2),
                                             bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                             colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
            rep.size = b.size
            view.cacheDisplay(in: b, to: rep)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent(name + ".png"))
        }
        await pause(1)
        if window.isVisible { stopLive() }
        // A private, always-"active" copy of Settings, off screen, so the pictures show
        // the window as it looks in front (blue switches) even if you're busy in another app.
        let tabs = SettingsTabController(model: settingsModel, alwaysActive: true)
        let shotWindow = SnapshotWindow(contentViewController: tabs)
        shotWindow.styleMask = [.titled, .closable]
        shotWindow.toolbarStyle = .preference
        shotWindow.isReleasedWhenClosed = false
        shotWindow.setFrameOrigin(NSPoint(x: -20000, y: -20000))
        NSApp.activate(ignoringOtherApps: true)
        shotWindow.makeKeyAndOrderFront(nil)
        await pause(0.8)
        let names = ["settings-general", "settings-alerts", "settings-recording", "settings-intelligence", "settings-nest"]
        for (i, n) in names.enumerated() {
            tabs.selectedTabViewItemIndex = i
            await pause(0.6)
            save(shotWindow, n)
        }
        shotWindow.orderOut(nil)
        settingsWindow?.orderOut(nil)
        historyModel.results = nil
        historyModel.chat = []
        historyModel.section = .ask
        openHistory(nil)
        await pause(1.5)
        save(historyWindow, "ask-empty")
        historyModel.section = .faces
        await pause(1)
        save(historyWindow, "faces")
        historyModel.section = .ask
        let q = "Was anyone at the door today?"
        historyModel.chat.append(ChatLine(fromUser: true, text: q))
        let session = intel.makeChatSession()
        let a = (try? await session.respond(to: q).content) ?? "Sorry, I couldn't work that out."
        historyModel.chat.append(ChatLine(fromUser: false, text: a))
        await pause(1.5)
        save(historyWindow, "ask-chat")
        historyModel.chat = []
        try? "done".write(to: out.appendingPathComponent("done.txt"), atomically: true, encoding: .utf8)
    }

    // Runs the full visit pipeline on what the camera sees right now.
    @objc func testVisitAnalysis(_ sender: Any?) {
        history.recordEvent(kind: "Test visit")
    }

    @objc func openHistory(_ sender: Any?) {
        if historyWindow == nil {
            let view = HistoryView(history: history, faces: faces, model: historyModel, intel: intel)
            let host = NSHostingController(rootView: view)
            if #available(macOS 14.0, *) { host.sceneBridgingOptions = [.toolbars, .title] }
            let w = NSWindow(contentViewController: host)
            w.styleMask = [.titled, .closable, .resizable, .miniaturizable, .fullSizeContentView]
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            w.setContentSize(NSSize(width: 1240, height: 780))
            w.setFrameAutosaveName("DoorbellHistoryWindow")
            w.center()
            historyWindow = w
        }
        NSApp.activate(ignoringOtherApps: true)
        historyWindow?.makeKeyAndOrderFront(nil)
        // SwiftUI fills in the window title on its next update; prompt one.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.historyModel.objectWillChange.send() }
    }

    func handleNestEvent(_ kind: String) {
        latestEvent = (kind, Date())
        if kind == "Doorbell ring" { ringMenuBarBell() }
        let r = history.recordEvent(kind: kind)
        if wants(kind) { alert(for: kind, visitId: r.visit.id) } else { prewarm() }
        refreshStatus()
    }

    @objc func connectNest(_ sender: Any?) { nest.link() }
    @objc func cancelNest(_ sender: Any?) { nest.cancelLink() }
    @objc func disconnectNest(_ sender: Any?) {
        nest.unlink()
        nestChanged()
    }

    // If the page stops refreshing (network drop, Google hiccup), load it again.
    func checkWatcherHealth() {
        if needsSignIn || watcherPaused { refreshStatus(); return }
        let lastSign = max(lastCheck ?? .distantPast, watcherLoadedAt)
        let stale = Date().timeIntervalSince(lastSign) > 150
        let old = Date().timeIntervalSince(watcherLoadedAt) > 30 * 60
        if stale || old { reloadWatcher() }
        refreshStatus()
    }

    func kindOf(_ label: String) -> String {
        // "5:12 PM, Person · Activity or animal seen, 13 seconds, October 18" -> "Person"
        let parts = label.components(separatedBy: ", ")
        let kind = parts.count > 1 ? parts[1] : label
        return kind.components(separatedBy: " · ").first ?? kind
    }

    func handleEvents(_ items: [[String: Any]]) {
        let parsed: [(time: Double, label: String)] = items.compactMap {
            guard let t = ($0["t"] as? NSNumber)?.doubleValue, t > 0 else { return nil }
            return (t, ($0["label"] as? String) ?? "")
        }
        guard let newest = parsed.max(by: { $0.time < $1.time }) else { return }
        lastCheck = Date()
        needsSignIn = false
        latestEvent = (kindOf(newest.label), Date(timeIntervalSince1970: newest.time / 1000))

        let now = Date().timeIntervalSince1970 * 1000
        let fresh = parsed.filter { $0.time > lastSeen && now - $0.time < 5 * 60 * 1000 }
        lastSeen = max(lastSeen, newest.time)
        for e in fresh.sorted(by: { $0.time < $1.time }) {
            history.recordEvent(kind: kindOf(e.label), at: Date(timeIntervalSince1970: e.time / 1000))
        }
        if let hit = fresh.filter({ wants(kindOf($0.label)) }).max(by: { $0.time < $1.time }) {
            alert(for: kindOf(hit.label))
        }
        refreshStatus()
    }

    func userContentController(_ userContentController: WKUserContentController,
                               didReceive message: WKScriptMessage) {
        switch message.name {
        case "doorbellWatch":
            if watcherPaused { return }
            guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
            switch kind {
            case "poll":
                lastCheck = Date()
                refreshStatus()
            case "loaded":
                needsSignIn = (body["host"] as? String) != "home.google.com"
                refreshStatus()
            case "events":
                handleEvents(body["items"] as? [[String: Any]] ?? [])
            default: break
            }
        case "nestStream":
            if let body = message.body as? [String: Any] { handleStreamMessage(body) }
        case "pipAspect":
            if liveLoaded {
                if !liveMuted { applyMute() }
                if pendingTalk && !usingDirectStream {
                    pendingTalk = false
                    pressGoogleTalk(expectOn: true, attempt: 0)
                }
            }
            guard let body = message.body as? [String: Any],
                  let w = (body["w"] as? NSNumber)?.doubleValue,
                  let h = (body["h"] as? NSNumber)?.doubleValue,
                  videoOnly, w > 0, h > 0 else {
                unlockAspect()
                return
            }
            lockAspect(width: w, height: h)
        default: break
        }
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        let host = webView.url?.host ?? ""
        if webView === watcher {
            if watcherPaused { return }
            if host != "home.google.com" { needsSignIn = true; refreshStatus() }
        } else if needsSignIn && host == "home.google.com" {
            reloadWatcher()   // you just signed in through the live view
        }
    }

    @objc func signIn(_ sender: Any?) {
        shownByEvent = false
        showLive(activate: true)
    }

    // MARK: Status

    func timeString(_ date: Date) -> String {
        let f = DateFormatter()
        f.timeStyle = .short
        f.dateStyle = Calendar.current.isDateInToday(date) ? .none : .short
        return f.string(from: date)
    }

    var statusTitle: String {
        if needsSignIn && !watcherPaused { return "Sign in needed" }
        if popMode == .off { return "Paused" }
        if window?.isVisible == true { return "Showing live view" }
        return nest.isConnected ? "Watching your front door · instant alerts" : "Watching your front door"
    }

    var statusDetail: String {
        var bits: [String] = []
        if let e = latestEvent { bits.append("Last event: \(e.kind), \(timeString(e.time))") }
        let checked = watcherPaused ? nest.lastCheck : lastCheck
        if let c = checked { bits.append("Checked \(timeString(c))") } else { bits.append("Starting…") }
        return bits.joined(separator: " · ")
    }

    var ringingUntil: Date?
    var ringFrame = false
    var ringTimer: Timer?

    private func symbol(_ names: String...) -> NSImage? {
        for n in names {
            if let i = NSImage(systemSymbolName: n, accessibilityDescription: "Doorman") { return i }
        }
        return nil
    }

    func refreshStatus() {
        guard let button = statusItem?.button else { return }
        let image: NSImage?
        if (needsSignIn && !watcherPaused) || popMode == .off { image = symbol("bell.slash") }
        else if let r = ringingUntil, Date() < r { image = symbol(ringFrame ? "bell.and.waves.left.and.right.fill" : "bell.fill") }
        else if window?.isVisible == true { image = symbol("video.doorbell.fill", "bell.fill") }
        else { image = symbol("video.doorbell", "bell") }
        image?.isTemplate = true
        button.image = image
        button.toolTip = "Doorman — \(statusTitle)\n\(statusDetail)"
        appStatusItem?.title = "\(statusTitle) — \(statusDetail)"
        if settingsWindow?.isVisible == true { updateSettingsModel() }
    }

    // The menu bar bell rings for a few seconds when someone presses the doorbell.
    func ringMenuBarBell() {
        ringingUntil = Date().addingTimeInterval(8)
        ringTimer?.invalidate()
        ringTimer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] t in
            MainActor.assumeIsolated {
                guard let self else { t.invalidate(); return }
                self.ringFrame.toggle()
                if let r = self.ringingUntil, Date() >= r {
                    t.invalidate()
                    self.ringingUntil = nil
                }
                self.refreshStatus()
            }
        }
    }

    // MARK: Menu bar icon

    func buildStatusItem() {
        // On a crowded menu bar, new icons land behind the camera notch. Start ours
        // near the right-hand side instead (you can still ⌘-drag it anywhere).
        let positionKey = "NSStatusItem Preferred Position DoorbellBell"
        if defaults.object(forKey: positionKey) == nil { defaults.set(300.0, forKey: positionKey) }
        defaults.set(true, forKey: "NSStatusItem Visible DoorbellBell")
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        statusItem.autosaveName = "DoorbellBell"
        statusItem.isVisible = true
        statusMenu.delegate = self
        statusItem.menu = statusMenu
        refreshStatus()
    }

    var menuHeadline: String {
        if needsSignIn && !watcherPaused { return "Sign in needed" }
        if popMode == .off { return "Alerts paused" }
        if window?.isVisible == true { return "Showing your front door" }
        return "Watching your front door"
    }

    var menuStatusLine: (String, Color) {
        var bits: [String] = []
        let color: Color
        switch nest.state {
        case .connected: bits.append("Instant alerts"); color = .green
        case .connecting, .linking: bits.append("Connecting…"); color = .orange
        case .problem: bits.append("Nest needs attention"); color = .red
        case .notLinked, .notConfigured: bits.append("Page check"); color = needsSignIn ? .red : .yellow
        }
        if engine?.running == true { bits.append(engine.isReady ? "Recording 24/7" : "Starting recording…") }
        return (bits.joined(separator: " · "), popMode == .off ? .secondary : color)
    }

    func menuSymbol(_ name: String) -> NSImage? {
        NSImage(systemSymbolName: name, accessibilityDescription: nil)
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        guard menu === statusMenu else { return }
        menu.removeAllItems()

        // Header: what the app is doing, and the last thing it saw.
        let latest = history?.visits.first
        let status = menuStatusLine
        let header = NSMenuItem()
        let hv = NSHostingView(rootView: MenuHeader(
            title: menuHeadline, detail: status.0, statusColor: status.1,
            thumb: latest.flatMap { history.thumbnailURL($0) },
            lastLine: latest.map { "\($0.title) · \(timeString($0.time))" }))
        hv.frame = NSRect(origin: .zero, size: hv.fittingSize)
        header.view = hv
        menu.addItem(header)
        menu.addItem(.separator())

        // Things that need you.
        var needs = false
        if needsSignIn && !watcherPaused {
            let i = item("Sign In to Google Home…", #selector(signIn(_:))); i.image = menuSymbol("person.crop.circle.badge.exclamationmark")
            menu.addItem(i); needs = true
        }
        switch nest.state {
        case .notLinked:
            let i = item("Connect Nest for Instant Alerts…", #selector(connectNest(_:))); i.image = menuSymbol("bolt.fill")
            menu.addItem(i); needs = true
        case .linking:
            menu.addItem(note("Finish signing in to Google in your browser…"))
            menu.addItem(item("Cancel Connecting", #selector(cancelNest(_:)))); needs = true
        case .problem(let message):
            menu.addItem(note(message))
            let i = item("Reconnect Nest…", #selector(connectNest(_:))); i.image = menuSymbol("arrow.clockwise")
            menu.addItem(i); needs = true
        default: break
        }
        if needs { menu.addItem(.separator()) }

        // Recent visits.
        if let recent = history?.visits.prefix(3), !recent.isEmpty {
            if #available(macOS 14.0, *) { menu.addItem(.sectionHeader(title: "Recent")) } else { menu.addItem(note("Recent")) }
            for v in recent {
                let i = item(v.title, #selector(openVisit(_:)))
                i.representedObject = v.id
                i.image = roundedMenuImage(history.thumbnailURL(v)) ?? menuSymbol(EventStyle.symbol(v))
                if #available(macOS 14.4, *) { i.subtitle = timeString(v.time) + " · " + EventStyle.label(v) }
                else { i.toolTip = timeString(v.time) }
                menu.addItem(i)
            }
            menu.addItem(.separator())
        }

        let live = item(window.isVisible ? "Hide Live View" : "Show Live View", #selector(toggleLive(_:)))
        live.image = menuSymbol(window.isVisible ? "video.slash" : "video")
        live.keyEquivalent = "l"
        menu.addItem(live)
        let hist = item("History…", #selector(openHistory(_:)))
        hist.image = menuSymbol("clock.arrow.circlepath")
        hist.keyEquivalent = "y"
        menu.addItem(hist)
        menu.addItem(.separator())

        let popItem = NSMenuItem(title: "Pop Up For", action: nil, keyEquivalent: "")
        popItem.image = menuSymbol(popMode == .off ? "bell.slash" : "bell.badge")
        let popMenu = NSMenu()
        let modes: [(String, PopMode)] = [("Doorbell Rings & People", .people),
                                          ("All Activity", .everything),
                                          ("Nothing (Pause Alerts)", .off)]
        for (label, mode) in modes {
            if mode == .off { popMenu.addItem(.separator()) }
            let i = item(label, #selector(choosePopMode(_:)))
            i.representedObject = mode.rawValue
            i.state = popMode == mode ? .on : .off
            popMenu.addItem(i)
        }
        popItem.submenu = popMenu
        menu.addItem(popItem)

        let trouble = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        trouble.image = menuSymbol("stethoscope")
        let tm = NSMenu()
        tm.addItem(item("Test Pop-Up", #selector(testPopUp(_:))))
        tm.addItem(item("Send Test Notification", #selector(sendTestAlert(_:))))
        tm.addItem(item("Analyze the Door Now", #selector(testVisitAnalysis(_:))))
        tm.addItem(item("Check for Events Now", #selector(checkNow(_:))))
        if nest.state != .notLinked && nest.state != .notConfigured {
            tm.addItem(.separator())
            tm.addItem(item("Disconnect Nest", #selector(disconnectNest(_:))))
        }
        trouble.submenu = tm
        menu.addItem(trouble)
        menu.addItem(.separator())

        let settings = item("Settings…", #selector(openSettings(_:)))
        settings.image = menuSymbol("gearshape")
        settings.keyEquivalent = ","
        menu.addItem(settings)
        let quit = NSMenuItem(title: "Quit Doorman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.image = menuSymbol("power")
        menu.addItem(quit)
    }

    @objc func openVisit(_ sender: NSMenuItem) {
        guard let id = sender.representedObject as? String, let v = history.visit(id) else { return }
        historyModel.show(v)
        openHistory(nil)
    }

    func note(_ title: String) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        i.isEnabled = false
        return i
    }

    func item(_ title: String, _ action: Selector) -> NSMenuItem {
        let i = NSMenuItem(title: title, action: action, keyEquivalent: "")
        i.target = self
        return i
    }

    @objc func choosePopMode(_ sender: NSMenuItem) {
        if let raw = sender.representedObject as? String, let mode = PopMode(rawValue: raw) { popMode = mode }
        refreshStatus()
    }
    @objc func chooseHideAfter(_ sender: NSMenuItem) {
        if let secs = sender.representedObject as? Double { hideAfter = secs }
    }
    @objc func toggleSound(_ sender: Any?) { playSound.toggle() }

    // MARK: Open at login

    // The app used to be called "Doorbell PiP". Its folders move to the new name once,
    // so recordings, history, faces and the Google sign-in carry over.
    func migrateFromOldName() {
        let fm = FileManager.default
        let places: [FileManager.SearchPathDirectory] = [.applicationSupportDirectory, .moviesDirectory, .picturesDirectory]
        for place in places {
            guard let base = fm.urls(for: place, in: .userDomainMask).first else { continue }
            let old = base.appendingPathComponent("Doorbell PiP", isDirectory: true)
            let new = base.appendingPathComponent("Doorman", isDirectory: true)
            if fm.fileExists(atPath: old.path) && !fm.fileExists(atPath: new.path) {
                try? fm.moveItem(at: old, to: new)
            }
        }
        // The login item belonged to the old app, so register the renamed one.
        if defaults.bool(forKey: "loginItemSetUp") && !defaults.bool(forKey: "loginItemRenamed") {
            defaults.set(true, forKey: "loginItemRenamed")
            try? SMAppService.mainApp.register()
        }
    }

    // Turned on once, the first time the app runs; switch it off from the menu.
    func setUpLoginItemOnce() {
        guard !defaults.bool(forKey: "loginItemSetUp") else { return }
        defaults.set(true, forKey: "loginItemSetUp")
        defaults.set(true, forKey: "loginItemRenamed")
        try? SMAppService.mainApp.register()
    }

    @objc func toggleLogin(_ sender: Any?) {
        do {
            if SMAppService.mainApp.status == .enabled { try SMAppService.mainApp.unregister() }
            else { try SMAppService.mainApp.register() }
        } catch { NSSound.beep() }
    }

    // MARK: Video-only mode

    func scriptSource() -> String {
        videoOnlyScriptTemplate.replacingOccurrences(of: "__ENABLED__", with: videoOnly ? "true" : "false")
    }

    func installVideoOnlyScript(into controller: WKUserContentController) {
        controller.removeAllUserScripts()
        controller.addUserScript(WKUserScript(source: scriptSource(),
                                              injectionTime: .atDocumentEnd,
                                              forMainFrameOnly: false))
    }

    @objc func toggleVideoOnly(_ sender: Any?) {
        videoOnly.toggle()
        applyVideoOnly()
    }

    func applyVideoOnly() {
        guard videoOnly != appliedVideoOnly else { return }
        appliedVideoOnly = videoOnly
        installVideoOnlyScript(into: webView.configuration.userContentController)
        webView.evaluateJavaScript(scriptSource(), completionHandler: nil)
        applyWindowChrome()
        if !videoOnly { unlockAspect() }
        videoOnlyItem.state = videoOnly ? .on : .off
    }

    // In video-only mode the title bar turns transparent so the picture fills the window.
    func applyWindowChrome() {
        if videoOnly {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
        } else {
            window.styleMask.remove(.fullSizeContentView)
            window.titlebarAppearsTransparent = false
            window.titleVisibility = .visible
        }
        updateOverlay(animated: false)
    }

    // In video-only mode the drag strip and the window buttons only show while
    // the pointer is over the window, so the picture stays clean otherwise.
    func updateOverlay(animated: Bool) {
        let buttons = window.standardWindowButton(.closeButton)?.superview
        dragBar.isHidden = !videoOnly
        let alpha: CGFloat = (!videoOnly || pointerInside) ? 1 : 0
        // Keep the controls up while talking, so "stop" is always one click away.
        let controlsAlpha: CGFloat = (pointerInside || talkState != .off) ? 1 : 0
        if animated {
            NSAnimationContext.runAnimationGroup { ctx in
                ctx.duration = 0.2
                dragBar.animator().alphaValue = alpha
                buttons?.animator().alphaValue = alpha
                controlBar?.animator().alphaValue = controlsAlpha
            }
        } else {
            dragBar.alphaValue = alpha
            buttons?.alphaValue = alpha
            controlBar?.alphaValue = controlsAlpha
        }
    }

    // MARK: Window shape follows the camera

    func lockAspect(width w: Double, height h: Double) {
        window.contentAspectRatio = NSSize(width: w, height: h)
        let frame = window.frame
        var newWidth = frame.width
        var newHeight = newWidth * h / w
        if let visible = window.screen?.visibleFrame ?? NSScreen.main?.visibleFrame,
           newHeight > visible.height * 0.9 {
            newHeight = visible.height * 0.9
            newWidth = newHeight * w / h
        }
        if abs(newHeight - frame.height) < 1 && abs(newWidth - frame.width) < 1 { return }
        let newFrame = NSRect(x: frame.minX, y: frame.maxY - newHeight, width: newWidth, height: newHeight)
        window.setFrame(onScreen(newFrame), display: true, animate: window.isVisible)
    }

    // Nudges a window frame so all of it sits on the screen, above the Dock.
    func onScreen(_ rect: NSRect) -> NSRect {
        guard let visible = (window.screen ?? NSScreen.main)?.visibleFrame else { return rect }
        var f = rect
        f.origin.x = min(max(f.minX, visible.minX), max(visible.minX, visible.maxX - f.width))
        f.origin.y = min(max(f.minY, visible.minY), max(visible.minY, visible.maxY - f.height))
        return f
    }

    func keepOnScreen() {
        let fixed = onScreen(window.frame)
        if fixed != window.frame { window.setFrame(fixed, display: true) }
    }

    func unlockAspect() {
        // Setting resize increments clears any aspect-ratio lock.
        window.contentResizeIncrements = NSSize(width: 1, height: 1)
    }

    // MARK: Keep on top

    @objc func toggleOnTop(_ sender: Any?) {
        keepOnTop.toggle()
        applyOnTop()
    }

    func applyOnTop() {
        window.level = keepOnTop ? .floating : .normal
        onTopItem?.state = keepOnTop ? .on : .off
    }

    // MARK: Other actions

    @objc func reloadPage(_ sender: Any?) {
        if liveLoaded && !liveUsesEngine { endDirectStream(); loadLiveContent() }
    }
    // Opens the full Google Home page (e.g. to use Talk), instead of the direct stream.
    @objc func goHome(_ sender: Any?) { fallBackToWebPage() }

    // MARK: Web view delegates

    // Google sign-in sometimes opens pop-ups; show them in the same window.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil { webView.load(navigationAction.request) }
        return nil
    }

    // Lets the doorbell's talk button ask for the microphone (macOS will prompt you).
    func webView(_ webView: WKWebView, requestMediaCapturePermissionFor origin: WKSecurityOrigin,
                 initiatedByFrame frame: WKFrameInfo, type: WKMediaCaptureType,
                 decisionHandler: @escaping (WKPermissionDecision) -> Void) {
        decisionHandler(origin.host.hasSuffix("google.com") ? .grant : .prompt)
    }

    // MARK: Keyboard shortcuts (work while the live view is in front)

    func buildMainMenu() {
        let main = NSMenu()

        let appItem = NSMenuItem(); main.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Doorman", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Settings…", action: #selector(openSettings(_:)), keyEquivalent: ",").target = self
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Show or Hide Live View", action: #selector(toggleLive(_:)), keyEquivalent: "l").target = self
        appMenu.addItem(withTitle: "History…", action: #selector(openHistory(_:)), keyEquivalent: "y").target = self
        let troubleItem = NSMenuItem(title: "Troubleshooting", action: nil, keyEquivalent: "")
        let troubleMenu = NSMenu(title: "Troubleshooting")
        troubleMenu.addItem(withTitle: "Test Pop-Up", action: #selector(testPopUp(_:)), keyEquivalent: "").target = self
        troubleMenu.addItem(withTitle: "Send Test Notification", action: #selector(sendTestAlert(_:)), keyEquivalent: "").target = self
        troubleMenu.addItem(withTitle: "Analyze the Door Now", action: #selector(testVisitAnalysis(_:)), keyEquivalent: "").target = self
        troubleMenu.addItem(withTitle: "Connect Nest…", action: #selector(connectNest(_:)), keyEquivalent: "").target = self
        troubleItem.submenu = troubleMenu
        appMenu.addItem(troubleItem)
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide Doorman", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        appMenu.addItem(withTitle: "Quit Doorman", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu

        // Needed so copy/paste works when typing your Google password.
        let editItem = NSMenuItem(); main.addItem(editItem)
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        editMenu.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "Z")
        editMenu.addItem(.separator())
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu

        let viewItem = NSMenuItem(); main.addItem(viewItem)
        let viewMenu = NSMenu(title: "View")
        videoOnlyItem = viewMenu.addItem(withTitle: "Video Only", action: #selector(toggleVideoOnly(_:)), keyEquivalent: "e")
        videoOnlyItem.target = self
        videoOnlyItem.state = videoOnly ? .on : .off
        onTopItem = viewMenu.addItem(withTitle: "Keep on Top", action: #selector(toggleOnTop(_:)), keyEquivalent: "t")
        onTopItem.target = self
        onTopItem.state = keepOnTop ? .on : .off
        viewMenu.addItem(.separator())
        viewMenu.addItem(withTitle: "Reload", action: #selector(reloadPage(_:)), keyEquivalent: "r").target = self
        viewMenu.addItem(withTitle: "Back to Doorbell", action: #selector(goHome(_:)), keyEquivalent: "d").target = self
        viewItem.submenu = viewMenu

        let windowItem = NSMenuItem(); main.addItem(windowItem)
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = windowMenu
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = main
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = AppDelegate()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
