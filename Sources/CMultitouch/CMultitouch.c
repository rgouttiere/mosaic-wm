#include "CMultitouch.h"
#include <dlfcn.h>
#include <CoreFoundation/CoreFoundation.h>
#include <mach/mach_time.h>

// MultitouchSupport's per-touch struct. This layout is the long-standing reverse-engineered one
// (fingermgmt / Middleclick / BetterTouchTool all use it); only the leading fields — up through
// `normalized` — matter to us, and they've been stable for years. Keeping it here in C means the
// fragile bit never leaks into Swift.
typedef struct { float x, y; } MTPoint;
typedef struct { MTPoint pos, vel; } MTReadout;
typedef struct {
    int frame;
    double timestamp;
    int identifier;
    int state;
    int foo3, foo4;
    MTReadout normalized;   // position (0..1) + velocity — the part we read
    float size;
    int zero1;
    float angle, majorAxis, minorAxis;
    MTReadout mm;           // absolute (mm)
    int zero2[2];
    float unk;
} MTTouch;

typedef void *MTDeviceRef;
typedef int (*MTContactCallbackFunction)(int device, MTTouch *touches, int numTouches, double ts, int frame);
typedef CFMutableArrayRef (*MTDeviceCreateListFn)(void);
typedef void (*MTRegisterFn)(MTDeviceRef, MTContactCallbackFunction);
typedef void (*MTDeviceStartFn)(MTDeviceRef, int);
typedef void (*MTDeviceStopFn)(MTDeviceRef);
typedef void (*MTUnregisterFn)(MTDeviceRef, MTContactCallbackFunction);
typedef bool (*MTDevicePredicateFn)(MTDeviceRef);

static CMTFrameCallback g_cb = NULL;
static MTDeviceRef g_devices[16];
static int g_deviceCount = 0;
static MTDeviceStopFn g_stop = NULL;
static MTUnregisterFn g_unreg = NULL;
static MTDevicePredicateFn g_isRunning = NULL;   // optional guards, NULL when the symbol is gone
static MTDevicePredicateFn g_isAlive = NULL;

// Last time (mach ticks) at least 3 fingers were on the pad. Used to suppress the phantom scroll
// that macOS emits from a 3-finger swipe when native 3-finger gestures are off (else IINA & co.
// read it as a horizontal seek). volatile: written on the MT thread, read on the event-tap thread.
static volatile uint64_t g_last3 = 0;
static mach_timebase_info_data_t g_tb = {0, 0};

static int contact_cb(int device, MTTouch *touches, int numTouches, double ts, int frame) {
    (void)device; (void)ts; (void)frame;
    if (numTouches >= 3) g_last3 = mach_absolute_time();
    if (!g_cb) return 0;
    float xs[32], ys[32];
    int n = numTouches < 32 ? numTouches : 32;
    if (n < 0) n = 0;
    for (int i = 0; i < n; i++) {
        xs[i] = touches[i].normalized.pos.x;
        ys[i] = touches[i].normalized.pos.y;
    }
    g_cb(xs, ys, n);
    return 0;
}

bool cmt_three_finger_active(double graceSeconds) {
    uint64_t last = g_last3;
    if (last == 0) return false;
    if (g_tb.denom == 0) mach_timebase_info(&g_tb);
    uint64_t now = mach_absolute_time();
    if (now <= last) return true;   // still down (updated this instant)
    double elapsed = (double)(now - last) * g_tb.numer / g_tb.denom / 1e9;
    return elapsed < graceSeconds;
}

bool cmt_start(CMTFrameCallback cb) {
    void *h = dlopen("/System/Library/PrivateFrameworks/MultitouchSupport.framework/MultitouchSupport", RTLD_LAZY);
    if (!h) return false;
    MTDeviceCreateListFn createList = (MTDeviceCreateListFn)dlsym(h, "MTDeviceCreateList");
    MTRegisterFn reg = (MTRegisterFn)dlsym(h, "MTRegisterContactFrameCallback");
    MTDeviceStartFn start = (MTDeviceStartFn)dlsym(h, "MTDeviceStart");
    g_stop = (MTDeviceStopFn)dlsym(h, "MTDeviceStop");
    g_unreg = (MTUnregisterFn)dlsym(h, "MTUnregisterContactFrameCallback");
    g_isRunning = (MTDevicePredicateFn)dlsym(h, "MTDeviceIsRunning");
    g_isAlive = (MTDevicePredicateFn)dlsym(h, "MTDeviceIsAlive");
    if (!createList || !reg || !start) return false;

    g_cb = cb;
    CFMutableArrayRef list = createList();
    if (!list) { g_cb = NULL; return false; }
    CFIndex count = CFArrayGetCount(list);
    for (CFIndex i = 0; i < count && g_deviceCount < 16; i++) {
        MTDeviceRef dev = (MTDeviceRef)CFArrayGetValueAtIndex(list, i);
        /* OWN a reference. Releasing the list below drops the only one we had; what remains is a
           single reference that is not ours (retain count 1 after start, measured), held inside
           MultitouchSupport. That is fine until the framework lets go of it: when a device vanished
           across a sleep, its thread releases that last reference on exit — and if cmt_stop's
           MTDeviceStop had just run, the dealloc path (__MTDeviceRelease) calls MTDeviceStop AGAIN
           on the already-stopped device and reads a CFMachPort that is now NULL. SIGSEGV on
           MultitouchSupport's own thread, 20 ms after the wake event, with the rest of Mosaic idle
           (crash of 2026-10-01 02:22). With our retain the count cannot reach zero behind our back. */
        CFRetain(dev);
        reg(dev, contact_cb);
        start(dev, 0);
        g_devices[g_deviceCount++] = dev;
    }
    CFRelease(list);
    if (g_deviceCount == 0) { g_cb = NULL; return false; }
    return true;
}

void cmt_stop(void) {
    /* Drop the callback, then stop the feed — cmt_start can be called again (a wake re-registers
       the devices), and registering a second time without unregistering would leave the frame
       callback installed twice on the same device.

       Stop ONLY a device that still runs. MTDeviceStop does not tolerate a second call (see the
       retain above), and a device whose hardware vanished across a sleep — a Bluetooth trackpad
       that dropped, a hub re-enumerating — has already been stopped by the framework itself.
       Without the symbol we fall back to stopping unconditionally, as before.

       The references are deliberately NEVER released: the framework's thread releases its own
       some time after the stop, and ours must still be there when it does, or the dealloc path
       above runs. One leaked MTDevice per device per wake is nothing. */
    for (int i = 0; i < g_deviceCount; i++) {
        MTDeviceRef dev = g_devices[i];
        if (g_unreg) g_unreg(dev, contact_cb);
        bool alive = g_isAlive ? g_isAlive(dev) : true;
        bool running = g_isRunning ? g_isRunning(dev) : true;
        if (g_stop && alive && running) g_stop(dev);
    }
    g_deviceCount = 0;
    g_cb = NULL;
}

int cmt_device_count(void) { return g_deviceCount; }
