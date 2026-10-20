// Engine.swift — keeps one live connection to the doorbell open all the time.
// It records the stream in one-minute files (24/7 history), grabs still frames for
// on-device analysis, and doubles as the instant live view.
import Cocoa
import WebKit

let enginePageTemplate = """
<!doctype html><html><head><meta charset="utf-8"><style>
html,body{margin:0;height:100%;background:#000;overflow:hidden;cursor:default}
video{position:fixed;inset:0;width:100vw;height:100vh;object-fit:contain;background:#000}
#msg{position:fixed;inset:0;display:flex;align-items:center;justify-content:center;color:#8a8a8a;font:13px -apple-system,system-ui}
</style></head><body>
<video id="v" autoplay playsinline muted></video>
<div id="msg">Connecting to your doorbell…</div>
<script>
(function () {
  var RECORD = __RECORD__, SEG_MS = __SEG_MS__, BITRATE = __BITRATE__;
  var v = document.getElementById('v'), msg = document.getElementById('msg');
  function post(m) { try { window.webkit.messageHandlers.engine.postMessage(m); } catch (e) {} }
  function reportSize() { if (v.videoWidth && v.videoHeight) post({ kind: 'size', w: v.videoWidth, h: v.videoHeight }); }

  var pc = new RTCPeerConnection({ bundlePolicy: 'max-bundle' });
  pc.addTransceiver('audio', { direction: 'recvonly' });
  pc.addTransceiver('video', { direction: 'recvonly' });
  pc.createDataChannel('dataSendChannel');
  var stream = new MediaStream(), recorder = null, recording = false, shown = false, started = false;
  pc.ontrack = function (e) { stream.addTrack(e.track); v.srcObject = stream; };
  // A playing video keeps the Mac's screen awake, so the stream is only put on screen
  // while the live view is open or a frame is being grabbed. Recording doesn't need it.
  function attachVideo() { if (v.srcObject !== stream) { v.srcObject = stream; } v.play().catch(function () {}); }
  function detachVideo() { if (v.srcObject) { v.pause(); v.srcObject = null; } }
  window.setDisplay = function (on) { shown = on; if (on) attachVideo(); else detachVideo(); };
  v.addEventListener('playing', function () {
    msg.style.display = 'none';
    if (started) return;
    started = true;
    setTimeout(function () { if (!shown) detachVideo(); }, 4000);
    post({ kind: 'playing' });
    post({ kind: 'debug', text: 'MediaRecorder=' + (typeof window.MediaRecorder) + ' type=' + pickType() +
      ' tracks=' + stream.getTracks().map(function (t) { return t.kind + ':' + t.readyState; }).join(',') });
    if (RECORD && !recording) { recording = true; setTimeout(nextSegment, 1500); }
  });
  v.addEventListener('loadedmetadata', reportSize);
  v.addEventListener('resize', reportSize);
  pc.onconnectionstatechange = function () {
    if (pc.connectionState === 'failed' || pc.connectionState === 'closed') post({ kind: 'failed', error: pc.connectionState });
  };

  function pickType() {
    var types = ['video/mp4;codecs=avc1,mp4a.40.2', 'video/mp4;codecs=avc1', 'video/mp4'];
    for (var i = 0; i < types.length; i++) {
      if (window.MediaRecorder && MediaRecorder.isTypeSupported(types[i])) return types[i];
    }
    return '';
  }

  // Records back-to-back segments; each finished file is handed to the app.
  function nextSegment() {
    if (!recording) return;
    if (!window.MediaRecorder) { post({ kind: 'recordError', error: 'MediaRecorder not available' }); recording = false; return; }
    var type = pickType(), chunks = [], started = Date.now(), r;
    try {
      var opts = { videoBitsPerSecond: BITRATE, audioBitsPerSecond: 32000 };
      if (type) opts.mimeType = type;
      r = new MediaRecorder(stream, opts);
    } catch (e) { post({ kind: 'recordError', error: String(e) }); recording = false; return; }
    recorder = r;
    r.ondataavailable = function (e) { if (e.data && e.data.size) chunks.push(e.data); };
    r.onstop = function () {
      var ended = Date.now();
      var blob = new Blob(chunks, { type: r.mimeType || type || 'video/mp4' });
      post({ kind: 'debug', text: 'segment stopped chunks=' + chunks.length + ' bytes=' + blob.size });
      if (!blob.size) return;
      var fr = new FileReader();
      fr.onload = function () {
        // The type itself contains a comma ("avc1,mp4a"), so split at the base64 marker.
        var s = String(fr.result), i = s.indexOf('base64,');
        post({ kind: 'segment', start: started, end: ended, mime: blob.type, data: i >= 0 ? s.slice(i + 7) : '' });
      };
      fr.readAsDataURL(blob);
    };
    r.onerror = function (e) { post({ kind: 'recordError', error: String((e && e.error) || e) }); };
    // Hand over data every second. Without a timeslice, WebKit's recorder stops taking
    // video after about 20 seconds (the picture froze while the sound carried on).
    r.start(1000);
    post({ kind: 'debug', text: 'recorder started state=' + r.state + ' mime=' + r.mimeType });
    // The next file starts a second before this one ends, so no moment falls between
    // two files; playback trims the overlap.
    setTimeout(nextSegment, SEG_MS - 1000);
    setTimeout(function () {
      try { if (r.state !== 'inactive') r.stop(); } catch (e) {}
    }, SEG_MS);
  }

  window.stopRecording = function () {
    recording = false;
    try { if (recorder && recorder.state !== 'inactive') recorder.stop(); } catch (e) {}
  };
  window.captureFrame = function (maxSide) {
    if (!v.videoWidth) return '';
    var s = Math.min(1, maxSide / Math.max(v.videoWidth, v.videoHeight));
    var c = document.createElement('canvas');
    c.width = Math.round(v.videoWidth * s); c.height = Math.round(v.videoHeight * s);
    c.getContext('2d').drawImage(v, 0, 0, c.width, c.height);
    return c.toDataURL('image/jpeg', 0.9);
  };
  window.grabFrame = async function (maxSide) {
    var temp = !v.srcObject;
    if (temp) {
      attachVideo();
      await new Promise(function (resolve) {
        var done = false;
        function finish() { if (!done) { done = true; resolve(); } }
        v.addEventListener('playing', finish, { once: true });
        setTimeout(finish, 2000);
      });
      await new Promise(function (r) { setTimeout(r, 200); });
    }
    var out = window.captureFrame(maxSide);
    if (temp && !shown) detachVideo();
    return out;
  };
  window.setMuted = function (m) { v.muted = m; };
  window.setAnswer = function (sdp) {
    pc.setRemoteDescription({ type: 'answer', sdp: sdp })
      .catch(function (e) { post({ kind: 'failed', error: String(e) }); });
  };
  window.closeStream = function () { window.stopRecording(); try { pc.close(); } catch (e) {} };

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

// A small diagnostic log: ~/Library/Application Support/Doorman/debug.log
enum DebugLog {
    static let url = HistoryStore.dataDir.deletingLastPathComponent().appendingPathComponent("debug.log")
    static func write(_ text: String) {
        let line = ISO8601DateFormatter().string(from: Date()) + " " + text + "\n"
        if let h = try? FileHandle(forWritingTo: url) {
            h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
        } else {
            try? Data(line.utf8).write(to: url)
        }
    }
}

@MainActor
final class CameraEngine: NSObject, WKScriptMessageHandler {
    let nest: NestLink
    let history: HistoryStore
    private(set) var webView: WKWebView!
    private let holder: NSWindow

    private(set) var running = false
    private(set) var streaming = false
    private(set) var recordingEnabled = true
    private(set) var attached = false
    private(set) var lastError: String?
    private var session: String?
    private var expires: Date?
    private var extending = false
    private var loadedAt = Date.distantPast
    private var lastSegmentAt: Date?
    private var restartAt: Date?
    private var failures = 0

    var onAspect: ((Double, Double) -> Void)?
    private(set) var videoSize: CGSize?
    var onStateChange: (() -> Void)?

    static let segmentSeconds = 60
    static let bitrate = 900_000      // ≈ 10 GB per day of footage

    init(nest: NestLink, history: HistoryStore) {
        self.nest = nest
        self.history = history
        // A tiny, transparent window keeps the stream "on screen" so macOS doesn't pause it.
        holder = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 4, height: 4),
                          styleMask: .borderless, backing: .buffered, defer: false)
        super.init()
        holder.isReleasedWhenClosed = false
        holder.alphaValue = 0.01          // effectively invisible, but still counts as on screen
        holder.ignoresMouseEvents = true
        holder.hasShadow = false
        holder.level = .floating
        holder.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle]

        let config = WKWebViewConfiguration()
        config.websiteDataStore = .nonPersistent()
        config.mediaTypesRequiringUserActionForPlayback = []
        if #available(macOS 14.0, *) { config.preferences.inactiveSchedulingPolicy = .none }
        config.userContentController.add(self, name: "engine")
        webView = WKWebView(frame: holder.contentView!.bounds, configuration: config)
        webView.autoresizingMask = [.width, .height]
        holder.contentView?.addSubview(webView)
    }

    var isReady: Bool { running && streaming }

    func start(record: Bool) {
        recordingEnabled = record
        guard !running else { return }
        running = true
        failures = 0
        if let vf = NSScreen.main?.visibleFrame {
            holder.setFrameOrigin(NSPoint(x: vf.minX, y: vf.maxY - 4))
        }
        holder.orderFrontRegardless()
        load()
    }

    func stop() {
        guard running else { return }
        running = false
        streaming = false
        restartAt = nil
        webView.evaluateJavaScript("window.closeStream && window.closeStream()", completionHandler: nil)
        stopSession()
        webView.loadHTMLString("<html><body style='background:#000'></body></html>", baseURL: nil)
        if !attached { holder.orderOut(nil) }
        onStateChange?()
    }

    private func load() {
        streaming = false
        loadedAt = Date()
        let html = enginePageTemplate
            .replacingOccurrences(of: "__RECORD__", with: recordingEnabled ? "true" : "false")
            .replacingOccurrences(of: "__SEG_MS__", with: String(Self.segmentSeconds * 1000))
            .replacingOccurrences(of: "__BITRATE__", with: String(Self.bitrate))
        webView.loadHTMLString(html, baseURL: URL(string: "https://localhost/"))
    }

    private func stopSession() {
        if let s = session { Task { await nest.stopStream(s) } }
        session = nil
        expires = nil
        extending = false
    }

    // Reconnect right away (e.g. after the Mac wakes, when the old stream is certainly gone).
    func restartNow(_ reason: String) {
        guard running else { return }
        DebugLog.write("engine restart: \(reason)")
        streaming = false
        stopSession()
        failures = 0
        restartAt = Date()
        onStateChange?()
    }

    private func restartSoon(_ reason: String) {
        guard running else { return }
        DebugLog.write("engine restart: \(reason)")
        lastError = reason
        streaming = false
        stopSession()
        failures += 1
        let delay = min(5.0 * pow(2.0, Double(min(failures, 5))), 120)
        restartAt = Date().addingTimeInterval(delay)
        onStateChange?()
    }

    // Called every second by the app.
    func tick() {
        guard running else { return }
        if let at = restartAt, Date() > at {
            restartAt = nil
            load()
            return
        }
        // Nothing playing a minute after loading: try again.
        if !streaming && restartAt == nil && Date().timeIntervalSince(loadedAt) > 60 {
            restartSoon("Stream didn't start")
            return
        }
        // Recording stalled (no new file for 3 minutes) while it should be running.
        if streaming, recordingEnabled, let last = lastSegmentAt, Date().timeIntervalSince(last) > 180 {
            lastSegmentAt = nil
            restartSoon("Recording stalled")
            return
        }
        // Nest streams last 5 minutes; renew shortly before they run out.
        if let s = session, let exp = expires, !extending, Date() > exp.addingTimeInterval(-45) {
            extending = true
            Task {
                defer { self.extending = false }
                do {
                    let r = try await nest.extendStream(s)
                    self.session = r.session
                    self.expires = r.expires
                } catch {
                    self.restartSoon("Couldn't extend the stream")
                }
            }
        }
    }

    // MARK: Live view

    func attach(to container: NSView, below sibling: NSView?) {
        webView.removeFromSuperview()
        webView.frame = container.bounds
        webView.autoresizingMask = [.width, .height]
        if let sibling { container.addSubview(webView, positioned: .below, relativeTo: sibling) }
        else { container.addSubview(webView) }
        attached = true
        webView.evaluateJavaScript("window.setDisplay && window.setDisplay(true)", completionHandler: nil)
        // Moving a playing video between windows can leave it blank until it redraws; nudge it.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.attached, let sv = self.webView.superview else { return }
            self.webView.frame = sv.bounds.insetBy(dx: 0, dy: 0.5)
            self.webView.frame = sv.bounds
            self.webView.evaluateJavaScript("(function(){var v=document.getElementById('v'); if (v) { v.play(); }})()", completionHandler: nil)
        }
    }

    func detach() {
        guard attached else { return }
        setMuted(true)
        webView.evaluateJavaScript("window.setDisplay && window.setDisplay(false)", completionHandler: nil)
        webView.removeFromSuperview()
        webView.frame = holder.contentView!.bounds
        holder.contentView?.addSubview(webView)
        attached = false
    }

    func setMuted(_ muted: Bool) {
        webView.evaluateJavaScript("window.setMuted && window.setMuted(\(muted ? "true" : "false"))", completionHandler: nil)
    }

    // A still frame from the live stream, scaled so its longest side is maxSide pixels.
    func captureFrame(maxSide: Int = 1280) async -> CGImage? {
        guard isReady else { return nil }
        let result: Any? = await withCheckedContinuation { cont in
            webView.callAsyncJavaScript("return window.grabFrame ? await window.grabFrame(m) : ''",
                                        arguments: ["m": maxSide], in: nil, in: .page) { r in
                cont.resume(returning: try? r.get())
            }
        }
        guard let url = result as? String, let comma = url.firstIndex(of: ","),
              let data = Data(base64Encoded: String(url[url.index(after: comma)...])),
              let src = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        return CGImageSourceCreateImageAtIndex(src, 0, nil)
    }

    // MARK: Messages from the page

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard let body = message.body as? [String: Any], let kind = body["kind"] as? String else { return }
        if kind != "segment" && kind != "size" {
            DebugLog.write("engine \(kind) \((body["text"] as? String) ?? (body["error"] as? String) ?? "")")
        }
        switch kind {
        case "debug":
            break
        case "offer":
            guard let sdp = body["sdp"] as? String else { return }
            Task {
                do {
                    let r = try await nest.startStream(offer: sdp)
                    guard self.running else { await self.nest.stopStream(r.session); return }
                    self.session = r.session
                    self.expires = r.expires
                    let js = String(data: try JSONEncoder().encode(r.answer), encoding: .utf8) ?? "\"\""
                    self.webView.evaluateJavaScript("setAnswer(\(js))", completionHandler: nil)
                } catch {
                    self.restartSoon("Google didn't start the stream")
                }
            }
        case "playing":
            if attached { webView.evaluateJavaScript("window.setDisplay && window.setDisplay(true)", completionHandler: nil) }
            streaming = true
            failures = 0
            lastError = nil
            lastSegmentAt = Date()
            onStateChange?()
        case "failed":
            restartSoon((body["error"] as? String) ?? "Connection failed")
        case "size":
            if let w = (body["w"] as? NSNumber)?.doubleValue, let h = (body["h"] as? NSNumber)?.doubleValue {
                videoSize = CGSize(width: w, height: h)
                onAspect?(w, h)
            }
        case "segment":
            lastSegmentAt = Date()
            DebugLog.write("engine segment b64=\((body["data"] as? String)?.count ?? -1)")
            guard let b64 = body["data"] as? String, let data = Data(base64Encoded: b64),
                  let start = (body["start"] as? NSNumber)?.doubleValue,
                  let end = (body["end"] as? NSNumber)?.doubleValue else {
                DebugLog.write("segment parse failed: data=\(body["data"] is String) start=\(String(describing: body["start"])) end=\(String(describing: body["end"]))")
                return
            }
            history.saveSegment(data: data,
                                start: Date(timeIntervalSince1970: start / 1000),
                                end: Date(timeIntervalSince1970: end / 1000))
        case "recordError":
            lastError = "Recording: " + ((body["error"] as? String) ?? "unknown error")
            onStateChange?()
        default:
            break
        }
    }
}
