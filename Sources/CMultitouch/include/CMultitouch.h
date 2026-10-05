#ifndef CMULTITOUCH_H
#define CMULTITOUCH_H

#include <stdbool.h>

// Per-frame callback: parallel arrays of finger positions (normalized 0..1, origin bottom-left)
// and the number of fingers currently on the trackpad. Fired on MultitouchSupport's own thread —
// the Swift side hops to main.
typedef void (*CMTFrameCallback)(const float *xs, const float *ys, int count);

// Load the private MultitouchSupport framework (dlopen), enumerate devices, and start streaming
// frames to `cb`. Returns true if the framework + at least one device were found. Idempotent-ish:
// call once. On unsupported systems it returns false and does nothing (no crash).
bool cmt_start(CMTFrameCallback cb);

// Unregister the callback and stop every device that still runs. The device references are kept
// (never released): see the comment in cmt_stop.
void cmt_stop(void);

// Devices currently registered (0 after cmt_stop or a failed cmt_start).
int cmt_device_count(void);

// Seconds since the last frame from any registered device (huge if none ever came).
double cmt_seconds_since_frame(void);

// Register the currently listed devices WITHOUT stopping or unregistering the old ones.
bool cmt_reregister_without_stop(CMTFrameCallback cb);

// True if >=3 fingers were on the trackpad within the last `graceSeconds` (covers the momentum
// tail after lift). Lets the scroll event-tap swallow the phantom scroll a 3-finger swipe emits.
// Thread-safe to call from an event-tap callback.
bool cmt_three_finger_active(double graceSeconds);

#endif
