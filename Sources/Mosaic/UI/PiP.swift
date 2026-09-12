import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import ScreenCaptureKit

/// Floating picture-in-picture of any managed window — a live SCStream of the (possibly parked)
/// source window rendered into our own always-on-top panel. Because the panel is ours (not an AX
/// window) we can move/snap/resize it smoothly. The source app keeps playing off-screen, so audio
/// continues on its own; we only mirror the picture. Needs Screen Recording (same grant as the
/// exposé thumbnails). Controls: close, return-to-window, play/pause (system media key).
@available(macOS 13.0, *)
final class PiP: NSObject, SCStreamDelegate, SCStreamOutput {
    static let shared = PiP()

    private var panel: PiPPanel?
    private var stream: SCStream?
    private var sourceID: CGWindowID?
    private var sourcePID: pid_t?
    private var onReturn: (() -> Void)?
    private var sizedToSource = false
    private let queue = DispatchQueue(label: "fr.rgouttiere.mosaic.pip")

    /// Fired whenever the PiP stops for any reason (close, return, error). Set once by the window
    /// manager to tear down the source's letterbox cover.
    var onStop: (() -> Void)?

    // Global+local mouse monitors: focus the (otherwise non-activating) panel when it's clicked, so
    // Space reaches it. The panel is freely draggable via isMovableByWindowBackground.
    private var monitors: [Any] = []

    var isActive: Bool { panel != nil }

    /// Toggle PiP for a window: start it, or stop if it's already mirroring this same window.
    func toggle(windowID: CGWindowID, pid: pid_t, onReturn: @escaping () -> Void) {
        if isActive, sourceID == windowID { stop(); return }
        stop()
        sourceID = windowID
        sourcePID = pid
        self.onReturn = onReturn
        showPanel()
        installMouseMonitors()
        Task { await startStream(windowID) }
    }

    func stop() {
        if let s = stream { s.stopCapture { _ in } }
        stream = nil
        if let p = panel {   // fade out, then drop it (panel = nil now so isActive is false immediately)
            NSAnimationContext.runAnimationGroup({ ctx in ctx.duration = 0.14; p.animator().alphaValue = 0 },
                                                 completionHandler: { p.orderOut(nil) })
        }
        panel = nil
        sourceID = nil
        sourcePID = nil
        onReturn = nil
        sizedToSource = false
        for m in monitors { NSEvent.removeMonitor(m) }
        monitors = []
        onStop?()
    }

    private func installMouseMonitors() {
        let down: (NSEvent) -> Void = { [weak self] _ in
            guard let self, let p = self.panel, p.frame.contains(NSEvent.mouseLocation) else { return }
            NSApp.activate(ignoringOtherApps: true)   // so a subsequent Space reaches the panel
            p.makeKeyAndOrderFront(nil)
        }
        monitors = [
            NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { down($0); return $0 },
            NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown, handler: down),
        ].compactMap { $0 }
    }

    // MARK: - Panel

    private func showPanel() {
        let p = PiPPanel(contentRect: NSRect(x: 0, y: 0, width: 480, height: 270))
        panel = p
        p.controls.closeAction = { [weak self] in self?.stop() }
        p.controls.returnAction = { [weak self] in let r = self?.onReturn; self?.stop(); r?() }
        p.controls.playPauseAction = { PiP.sendPlayPause() }
        p.controls.volumeAction = { [weak self] dir in self?.sendVolumeToPlayer(up: dir > 0) }
        // Top-left corner on show.
        if let scr = NSScreen.main {
            let m: CGFloat = 16
            p.setFrameOrigin(NSPoint(x: scr.visibleFrame.minX + m,
                                     y: scr.visibleFrame.maxY - p.frame.height - m))
        }
        // Entrance: fade + a subtle scale-in (0.93 → 1.0) around the panel's centre. In place.
        p.alphaValue = 0
        p.orderFrontRegardless()
        if !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion, let layer = p.contentView?.layer {
            let c = CGPoint(x: layer.bounds.midX, y: layer.bounds.midY)
            func scaled(_ s: CGFloat) -> CATransform3D {
                var t = CATransform3DTranslate(CATransform3DIdentity, c.x, c.y, 0)
                t = CATransform3DScale(t, s, s, 1)
                return CATransform3DTranslate(t, -c.x, -c.y, 0)
            }
            let a = CABasicAnimation(keyPath: "transform")
            a.fromValue = scaled(0.93); a.toValue = scaled(1.0); a.duration = 0.18
            a.timingFunction = CAMediaTimingFunction(name: .easeOut)
            layer.add(a, forKey: "pipIn")
            NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; p.animator().alphaValue = 1 }
        } else {
            p.alphaValue = 1
        }
    }

    // MARK: - Stream

    private func startStream(_ id: CGWindowID) async {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            guard let win = content.windows.first(where: { $0.windowID == id }) else {
                NSLog("Mosaic: PiP source window \(id) not shareable"); await MainActor.run { self.stop() }; return
            }
            let filter = SCContentFilter(desktopIndependentWindow: win)
            let cfg = SCStreamConfiguration()
            let w = max(2, Int(win.frame.width)), h = max(2, Int(win.frame.height))
            cfg.width = w; cfg.height = h
            cfg.minimumFrameInterval = CMTime(value: 1, timescale: 30)   // 30 fps is plenty for PiP
            cfg.pixelFormat = kCVPixelFormatType_32BGRA
            cfg.showsCursor = false
            cfg.queueDepth = 5
            let s = SCStream(filter: filter, configuration: cfg, delegate: self)
            try s.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
            try await s.startCapture()
            self.stream = s
        } catch {
            NSLog("Mosaic: PiP stream failed: \(error)")
            await MainActor.run { self.stop() }
        }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attach = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let raw = attach.first?[.status] as? Int, SCFrameStatus(rawValue: raw) == .complete else { return }
        DispatchQueue.main.async { [weak self] in self?.render(sampleBuffer) }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        NSLog("Mosaic: PiP stream stopped: \(error)")
        DispatchQueue.main.async { [weak self] in self?.stop() }
    }

    private func render(_ sampleBuffer: CMSampleBuffer) {
        guard let panel else { return }
        if !sizedToSource, let px = CMSampleBufferGetImageBuffer(sampleBuffer) {
            sizedToSource = true
            let w = CVPixelBufferGetWidth(px), h = CVPixelBufferGetHeight(px)
            if w > 0, h > 0 { panel.applySourceAspect(CGFloat(w), CGFloat(h)) }
        }
        panel.enqueue(sampleBuffer)
    }

    // MARK: - Playback control

    /// Change the *player's* volume (not the system's) by posting Up/Down arrow keys straight to the
    /// source app — IINA/mpv map those to volume, and postToPid reaches it even while it's parked.
    private func sendVolumeToPlayer(up: Bool) {
        guard let pid = sourcePID else { return }
        let key: CGKeyCode = up ? 126 : 125   // ↑ / ↓
        let src = CGEventSource(stateID: .hidSystemState)
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: true)?.postToPid(pid)
        CGEvent(keyboardEventSource: src, virtualKey: key, keyDown: false)?.postToPid(pid)
    }

    // System media key: 16 = play/pause (NX_KEYTYPE_PLAY) — goes to the "now playing" app.
    static func sendPlayPause() { sendMediaKey(16) }

    private static func sendMediaKey(_ code: Int) {
        for down in [true, false] {
            let data1 = (code << 16) | ((down ? 0xA : 0xB) << 8)
            guard let ev = NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: [],
                                              timestamp: 0, windowNumber: 0, context: nil,
                                              subtype: 8, data1: data1, data2: -1) else { continue }
            ev.cgEvent?.post(tap: .cghidEventTap)
        }
    }
}


// MARK: - Panel + content

@available(macOS 13.0, *)
final class PiPPanel: NSPanel {
    let controls = PiPControls()
    private let videoLayer = AVSampleBufferDisplayLayer()

    init(contentRect: NSRect) {
        super.init(contentRect: contentRect, styleMask: [.borderless, .resizable, .nonactivatingPanel],
                   backing: .buffered, defer: false)
        isFloatingPanel = true
        level = NSWindow.Level(rawValue: NSWindow.Level.floating.rawValue + 1)   // above the source's letterbox cover
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        becomesKeyOnlyIfNeeded = true
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        contentAspectRatio = NSSize(width: 16, height: 9)
        minSize = NSSize(width: 200, height: 112)

        let host = NSView(frame: contentRect)
        host.wantsLayer = true
        host.layer?.cornerRadius = 10
        host.layer?.masksToBounds = true
        host.layer?.borderWidth = 1
        host.layer?.borderColor = Palette.accent.withAlphaComponent(0.55).cgColor
        videoLayer.frame = host.bounds
        videoLayer.videoGravity = .resizeAspectFill
        videoLayer.autoresizingMask = [.layerWidthSizable, .layerHeightSizable]
        host.layer?.addSublayer(videoLayer)
        host.addSubview(controls)
        controls.frame = host.bounds
        controls.autoresizingMask = [.width, .height]
        contentView = host
    }

    func enqueue(_ sb: CMSampleBuffer) {
        if #available(macOS 14.0, *), videoLayer.sampleBufferRenderer.status == .failed {
            videoLayer.sampleBufferRenderer.flush()
        } else if videoLayer.status == .failed {
            videoLayer.flush()
        }
        setDisplayImmediately(sb)
        videoLayer.enqueue(sb)
    }

    /// Match the panel's aspect (and a sane starting size) to the real source dimensions.
    func applySourceAspect(_ w: CGFloat, _ h: CGFloat) {
        contentAspectRatio = NSSize(width: w, height: h)
        let targetW: CGFloat = 480
        let targetH = (targetW * h / w).rounded()
        guard let scr = screen ?? NSScreen.main else { return }
        let m: CGFloat = 16
        let origin = NSPoint(x: scr.visibleFrame.minX + m, y: scr.visibleFrame.maxY - targetH - m)   // top-left
        setFrame(NSRect(origin: origin, size: NSSize(width: targetW, height: targetH)), display: true, animate: false)
    }

    /// Tell the display layer to show each frame at once — SCStream timestamps don't share the
    /// layer's clock, so without this the video can stall waiting on a timeline that never advances.
    private func setDisplayImmediately(_ sb: CMSampleBuffer) {
        guard let arr = CMSampleBufferGetSampleAttachmentsArray(sb, createIfNecessary: true),
              CFArrayGetCount(arr) > 0 else { return }
        let dict = unsafeBitCast(CFArrayGetValueAtIndex(arr, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(dict,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
    }

    override var canBecomeKey: Bool { true }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 49 { PiP.sendPlayPause() }   // Space → play/pause
        else { super.keyDown(with: event) }
    }
}

/// Hover-reveal controls: a frosted pill with close / return / play-pause. Fades in on mouse-enter,
/// out on leave — an in-place fade, no travelling motion.
@available(macOS 13.0, *)
final class PiPControls: NSView {
    var closeAction: (() -> Void)?
    var returnAction: (() -> Void)?
    var playPauseAction: (() -> Void)?
    var volumeAction: ((Int) -> Void)?   // +1 up / -1 down

    private let pill = NSVisualEffectView()
    private var tracking: NSTrackingArea?
    private var scrollAccum: CGFloat = 0

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        pill.material = .hudWindow
        pill.blendingMode = .withinWindow
        pill.state = .active
        pill.wantsLayer = true
        pill.layer?.cornerRadius = 12
        pill.alphaValue = 0
        addSubview(pill)

        let stack = NSStackView(views: [
            button("arrow.up.left.and.arrow.down.right", action: #selector(doReturn)),
            button("playpause.fill", action: #selector(doPlayPause)),
            button("xmark", action: #selector(doClose)),
        ])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        pill.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: pill.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: pill.centerYAnchor),
            pill.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: 28),
            pill.heightAnchor.constraint(equalTo: stack.heightAnchor, constant: 16),
        ])
    }
    required init?(coder: NSCoder) { nil }

    private func button(_ symbol: String, action: Selector) -> NSButton {
        let b = NSButton()
        b.bezelStyle = .regularSquare
        b.isBordered = false
        b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
            .withSymbolConfiguration(.init(pointSize: 15, weight: .semibold))
        b.contentTintColor = .white
        b.target = self
        b.action = action
        b.translatesAutoresizingMaskIntoConstraints = false
        return b
    }

    override func layout() {
        super.layout()
        pill.frame = NSRect(x: bounds.midX - 60, y: bounds.midY - 20, width: 120, height: 40)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let t = tracking { removeTrackingArea(t) }
        let t = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: self)
        addTrackingArea(t); tracking = t
    }
    override func mouseEntered(with event: NSEvent) { fade(to: 1) }
    override func mouseExited(with event: NSEvent) { fade(to: 0) }

    // Right-click → play/pause; scroll → volume. (Left-click is left to the window's background drag,
    // so we don't override mouseDown here.)
    override func rightMouseDown(with event: NSEvent) { playPauseAction?() }
    override func scrollWheel(with event: NSEvent) {
        scrollAccum += event.scrollingDeltaY
        let step: CGFloat = 6
        while abs(scrollAccum) >= step {
            volumeAction?(scrollAccum > 0 ? 1 : -1)
            scrollAccum -= scrollAccum > 0 ? step : -step
        }
    }

    // Free drag from anywhere but the buttons (they get the click first). Manual drag so it's
    // reliable on a non-activating panel — drop it wherever, no snapping.
    private var dragMouseStart: NSPoint?
    private var dragWinStart: NSPoint?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }   // drag on first click
    override func mouseDown(with event: NSEvent) {
        dragMouseStart = NSEvent.mouseLocation
        dragWinStart = window?.frame.origin
    }
    override func mouseDragged(with event: NSEvent) {
        guard let ms = dragMouseStart, let ws = dragWinStart, let win = window else { return }
        let now = NSEvent.mouseLocation
        win.setFrameOrigin(NSPoint(x: ws.x + (now.x - ms.x), y: ws.y + (now.y - ms.y)))
    }
    override func mouseUp(with event: NSEvent) { dragMouseStart = nil }
    private func fade(to a: CGFloat) {
        NSAnimationContext.runAnimationGroup { ctx in ctx.duration = 0.18; pill.animator().alphaValue = a }
    }

    @objc private func doClose() { closeAction?() }
    @objc private func doReturn() { returnAction?() }
    @objc private func doPlayPause() { playPauseAction?() }
}
