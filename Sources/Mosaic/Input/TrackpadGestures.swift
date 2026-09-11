import AppKit
import CMultitouch

/// Native trackpad gestures via the raw MultitouchSupport stream (NSEvent can't see gestures
/// globally). A 3-finger swipe fires one of four directions; the dominant axis wins. Only 3-finger
/// frames reach the main thread (cheap); a time gap between them resets the gesture. Opt-in.
final class TrackpadGestures {
    static let shared = TrackpadGestures()

    var onSwipeLeft: (() -> Void)?    // 3 fingers moving left
    var onSwipeRight: (() -> Void)?   // 3 fingers moving right
    var onSwipeUp: (() -> Void)?      // 3 fingers moving away from the user
    var onSwipeDown: (() -> Void)?    // 3 fingers moving toward the user

    // While set and returning true (exposé open): a 2-finger swipe navigates the grid — horizontal
    // for columns, vertical for rows. `onExposeNav(colDir, rowDir)` gets exactly one axis non-zero.
    var isExposeNavActive: (() -> Bool)?
    var onExposeNav: ((_ colDir: Int, _ rowDir: Int) -> Void)?   // col: -1 left/+1 right, row: -1 up/+1 down

    private var started = false
    private var startX: Float?, startY: Float = 0
    private var lastX: Float = 0, lastY: Float = 0
    private var velX: Float = 0, velY: Float = 0   // EMA of per-axis velocity (normalized units / sec)
    private var fired = false
    private var lastFrame = DispatchTime.now()

    // Snappy trigger: a deliberate flick fires almost immediately; a slower, committed swipe fires
    // a bit later on distance alone. This is what makes it feel reactive instead of "heavy".
    private let distThreshold: Float = 0.09   // committed swipe: fraction of trackpad width
    private let flickDist: Float = 0.035      // minimal travel to accept a flick
    private let flickVel: Float = 1.1         // normalized units/sec that count as a flick
    private let gapReset = 0.15               // seconds between 3-finger frames that starts a new gesture

    // Scroll event-tap: swallows the phantom scroll a 3-finger swipe emits (macOS does this when
    // native 3-finger gestures are off) so no app reacts to it — IINA seeking on horizontal, a page
    // scrolling under a swipe-up-to-exposé, etc. Normal 2-finger scroll never triggers it. It also
    // repurposes 2-finger horizontal scroll into column nav while the exposé is open.
    private var scrollTap: CFMachPort?
    private var scrollSource: CFRunLoopSource?

    // 2-finger → grid-nav state (main-thread only: the tap runs on the main run loop). One grid move
    // per physical swipe (latched), momentum ignored, so it doesn't race through cells.
    private var accumX: Double = 0, accumY: Double = 0
    private var navFired = false
    private let navStep: Double = 45   // px of swipe for one grid move

    @discardableResult
    func start() -> Bool {
        guard !started else { return true }
        // @convention(c): no captures — routes through the singleton. Runs on MT's own thread.
        let cb: CMTFrameCallback = { xs, ys, count in
            guard count == 3, let xs, let ys else { return }   // only the gesture we care about hits main
            let ax = (xs[0] + xs[1] + xs[2]) / 3
            let ay = (ys[0] + ys[1] + ys[2]) / 3
            DispatchQueue.main.async { TrackpadGestures.shared.process(avgX: ax, avgY: ay) }
        }
        started = cmt_start(cb)
        if started { installScrollTap() }
        NSLog("Mosaic: trackpad gestures \(started ? "active (MultitouchSupport)" : "unavailable")")
        return started
    }

    func stop() {
        cmt_stop()
        removeScrollTap()
        started = false
    }

    private func installScrollTap() {
        guard scrollTap == nil else { return }
        let mask = CGEventMask(1 << CGEventType.scrollWheel.rawValue)
        guard let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap,
                                        options: .defaultTap, eventsOfInterest: mask,
                                        callback: scrollTapCallback, userInfo: nil) else {
            NSLog("Mosaic: scroll tap could not be created (Accessibility not granted?)")
            return
        }
        scrollTap = t
        scrollSource = CFMachPortCreateRunLoopSource(nil, t, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), scrollSource, .commonModes)
        CGEvent.tapEnable(tap: t, enable: true)
    }

    private func removeScrollTap() {
        if let t = scrollTap { CGEvent.tapEnable(tap: t, enable: false) }
        if let s = scrollSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), s, .commonModes) }
        scrollTap = nil; scrollSource = nil
    }

    fileprivate func reEnableScrollTap() { if let t = scrollTap { CGEvent.tapEnable(tap: t, enable: true) } }

    /// A 2-finger scroll while the exposé is open → one grid move per swipe, dominant axis wins
    /// (horizontal = columns, vertical = rows). Always consumes the event (nothing scrolls behind).
    /// Natural scrolling reports fingers-right/up as negative delta, so those map to +col / -row.
    fileprivate func handleExposeScroll(_ event: CGEvent) -> Bool {
        // Momentum tail: swallow, but never navigate — otherwise a flick races through cells.
        if event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0 { accumX = 0; accumY = 0; return true }
        let dx = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis2)   // horizontal
        let dy = event.getDoubleValueField(.scrollWheelEventPointDeltaAxis1)   // vertical
        let phase = event.getIntegerValueField(.scrollWheelEventScrollPhase)
        if phase == 1 { accumX = 0; accumY = 0; navFired = false }   // kCGScrollPhaseBegan → new swipe
        accumX += dx; accumY += dy
        let fire = { [self] in
            if abs(accumX) >= abs(accumY) { onExposeNav?(accumX < 0 ? 1 : -1, 0) }   // fingers right → col +1
            else { onExposeNav?(0, accumY < 0 ? 1 : -1) }                            // fingers up → row up
        }
        if phase != 0 {                                    // trackpad (phased): one move per swipe
            if !navFired && max(abs(accumX), abs(accumY)) > navStep { navFired = true; fire() }
        } else {                                           // non-phased (mouse wheel): step-continuous
            while max(abs(accumX), abs(accumY)) > navStep {
                fire()
                if abs(accumX) >= abs(accumY) { accumX -= accumX > 0 ? navStep : -navStep }
                else { accumY -= accumY > 0 ? navStep : -navStep }
            }
        }
        return true
    }

    private func process(avgX: Float, avgY: Float) {
        let now = DispatchTime.now()
        let dt = Double(now.uptimeNanoseconds &- lastFrame.uptimeNanoseconds) / 1e9
        lastFrame = now
        if dt > gapReset || startX == nil {   // new 3-finger gesture
            startX = avgX; startY = avgY; lastX = avgX; lastY = avgY
            velX = 0; velY = 0; fired = false; return
        }
        if dt > 0 {                           // EMA-smoothed per-axis velocity
            velX = velX * 0.6 + (avgX - lastX) / Float(dt) * 0.4
            velY = velY * 0.6 + (avgY - lastY) / Float(dt) * 0.4
        }
        lastX = avgX; lastY = avgY
        guard !fired, let sx = startX else { return }
        let dx = avgX - sx, dy = avgY - startY
        // The bigger displacement picks the axis; MT y grows away from the user (up).
        if abs(dx) >= abs(dy) {
            if abs(dx) > distThreshold || (abs(dx) > flickDist && abs(velX) > flickVel) {
                fired = true
                (dx < 0 ? onSwipeLeft : onSwipeRight)?()
            }
        } else {
            if abs(dy) > distThreshold || (abs(dy) > flickDist && abs(velY) > flickVel) {
                fired = true
                (dy > 0 ? onSwipeUp : onSwipeDown)?()
            }
        }
    }
}

private let scrollTapCallback: CGEventTapCallBack = { _, type, event, _ in
    let me = TrackpadGestures.shared
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        me.reEnableScrollTap()
        return Unmanaged.passUnretained(event)
    }
    let threeFinger = cmt_three_finger_active(0.2)
    if me.isExposeNavActive?() == true {          // exposé open
        if threeFinger { return nil }             // 3-finger drives nav (MT recognizer); eat its phantom scroll
        if me.handleExposeScroll(event) { return nil }   // 2-finger → grid nav
        return Unmanaged.passUnretained(event)
    }
    // Outside the exposé: swallow the phantom scroll a 3-finger swipe emits (either axis). Normal
    // 2-finger scroll never sets the flag, so it always passes through.
    if threeFinger { return nil }
    return Unmanaged.passUnretained(event)
}
