import AppKit
import CMultitouch

/// Native trackpad gestures via the raw MultitouchSupport stream (NSEvent can't see gestures
/// globally). First gesture: a 3-finger horizontal swipe → workspace prev/next. Only 3-finger
/// frames reach the main thread (cheap); a time gap between them resets the gesture. Opt-in.
final class TrackpadGestures {
    static let shared = TrackpadGestures()

    var onSwipeLeft: (() -> Void)?    // 3 fingers moving left
    var onSwipeRight: (() -> Void)?   // 3 fingers moving right

    private var started = false
    private var startX: Float?
    private var lastX: Float?
    private var vel: Float = 0            // EMA of horizontal velocity (normalized units / sec)
    private var fired = false
    private var lastFrame = DispatchTime.now()

    // Snappy trigger: a deliberate flick fires almost immediately; a slower, committed swipe fires
    // a bit later on distance alone. This is what makes it feel reactive instead of "heavy".
    private let distThreshold: Float = 0.09   // committed swipe: fraction of trackpad width
    private let flickDist: Float = 0.035      // minimal travel to accept a flick
    private let flickVel: Float = 1.1         // normalized units/sec that count as a flick
    private let gapReset = 0.15               // seconds between 3-finger frames that starts a new gesture

    // Scroll event-tap: swallows the phantom horizontal scroll that a 3-finger swipe emits (macOS
    // does this when native 3-finger gestures are off), so apps like IINA don't read it as a seek.
    private var scrollTap: CFMachPort?
    private var scrollSource: CFRunLoopSource?

    @discardableResult
    func start() -> Bool {
        guard !started else { return true }
        // @convention(c): no captures — routes through the singleton. Runs on MT's own thread.
        let cb: CMTFrameCallback = { xs, _, count in
            guard count == 3, let xs else { return }   // only the gesture we care about hits main
            let avg = (xs[0] + xs[1] + xs[2]) / 3
            DispatchQueue.main.async { TrackpadGestures.shared.process(avgX: avg) }
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

    private func process(avgX: Float) {
        let now = DispatchTime.now()
        let dt = Double(now.uptimeNanoseconds &- lastFrame.uptimeNanoseconds) / 1e9
        lastFrame = now
        if dt > gapReset || startX == nil {   // new 3-finger gesture
            startX = avgX; lastX = avgX; vel = 0; fired = false; return
        }
        if dt > 0, let lx = lastX {           // EMA-smoothed horizontal velocity
            let inst = (avgX - lx) / Float(dt)
            vel = vel * 0.6 + inst * 0.4
        }
        lastX = avgX
        guard !fired, let s = startX else { return }
        let dx = avgX - s
        let flick = abs(dx) > flickDist && abs(vel) > flickVel
        if abs(dx) > distThreshold || flick {
            fired = true
            (dx < 0 ? onSwipeLeft : onSwipeRight)?()
        }
    }
}

private let scrollTapCallback: CGEventTapCallBack = { _, type, event, _ in
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        TrackpadGestures.shared.reEnableScrollTap()
        return Unmanaged.passUnretained(event)
    }
    // Only while a 3-finger swipe is (or was just) in progress, and only for horizontal-dominant
    // scroll — vertical scrolling is never touched, so normal 2-finger scroll passes through.
    if cmt_three_finger_active(0.2) {
        let dx = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2)   // horizontal
        let dy = event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1)   // vertical
        if abs(dx) >= abs(dy) { return nil }   // swallow the phantom seek
    }
    return Unmanaged.passUnretained(event)
}
