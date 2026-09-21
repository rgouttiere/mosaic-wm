#!/usr/bin/env python3
"""What do Mosaic's parked workspaces actually cost?

v2 parks a workspace by pushing its windows off-screen on the SAME macOS Space. That raises
a question v1 never had: in v1 macOS genuinely occluded the other Spaces, so their apps
throttled. Here, nothing obviously tells an app it is out of sight — worse, the AX clamp
leaves ~40px of every parked window on screen, so `kCGWindowIsOnscreen` stays true for all
of them. If the apps kept rendering, the emulated model would cost a CPU tax that grows
with every workspace.

Measured 2026-09-21 (3 monitors, Safari under a requestAnimationFrame canvas load):

    phase          frames/s   app %core   WindowServer %core
    shown              68.8        0.5%                53.3%
    parked              0.1        0.0%                37.8%
    reshown            40.8        0.3%                48.9%

So macOS DOES occlude a parked window — the browser stops servicing rAF, ~700x fewer
frames — and the emulated model carries no per-workspace rendering tax. Re-run `ab` after
any change to how parking places windows; the frame rate is the load-bearing number.

Usage:
    scripts/parkcost.py sample [window_seconds] [rounds]   # passive: every managed app, by state
    scripts/parkcost.py ab                                 # controlled: one app, shown vs parked

Measurement notes, each earned the hard way:
  * The metric is a CPU-TIME DELTA over a fixed window, never an instantaneous %CPU, which
    aliases against whatever the app happens to be doing at that instant. Several short
    windows, median reported, so one co-scheduled spike can't carry a state.
  * Helper processes do the drawing. Electron renderers and Safari's WebContent live outside
    the app bundle, so matching only the bundle path reads ~0 for the process burning a core.
  * `proc_pid_rusage` is refused for WindowServer (it runs as _windowserver), and `top` prints
    a long-lived process's TIME as HH:MM:SS — ONE SECOND of resolution. Give it windows of a
    minute, or the delta is pure quantisation.
  * App names in the layout dump can carry invisible format characters (WhatsApp's starts with
    U+200E), which match no process on earth until stripped.
  * Every wait is a deadline poll. On a loaded machine no fixed sleep is long enough.
"""
import ctypes, json, re, statistics, subprocess, sys, threading, time, unicodedata
from http.server import BaseHTTPRequestHandler, HTTPServer

libproc = ctypes.CDLL("/usr/lib/libproc.dylib")
DUMP = "/tmp/mosaic-dump.txt"
AB_PHASE = 45.0          # long enough that WindowServer's 1s resolution isn't the signal
AB_WORKSPACE = 2         # the test window is parked/unparked by flipping this workspace


# --- CPU sampling ----------------------------------------------------------------------

def cpu_ns(pid):
    """User+system CPU nanoseconds for pid. The rusage_info_v0 layout (uuid[16], user_time,
    system_time, ...) is the prefix of every later version, so flavor 0 stays valid."""
    buf = (ctypes.c_uint8 * 256)()
    if libproc.proc_pid_rusage(ctypes.c_int(pid), ctypes.c_int(0), ctypes.byref(buf)) != 0:
        return cpu_ns_top(pid)          # not ours to read — fall back
    user, system = ctypes.cast(ctypes.byref(buf, 16), ctypes.POINTER(ctypes.c_uint64))[0:2]
    return user + system


def cpu_ns_top(pid):
    """CPU nanoseconds via top, for processes rusage refuses. Only good to one second for a
    long-lived process (see the module docstring)."""
    out = subprocess.run(["top", "-l", "1", "-pid", str(pid), "-stats", "time"],
                         capture_output=True, text=True).stdout
    for line in reversed(out.splitlines()):
        m = re.fullmatch(r"\s*(?:(\d+):)?(\d+):(\d+)(?:\.(\d+))?\s*", line)
        if m:
            h, mi, sec, cc = m.groups()
            total = int(mi) * 60 + int(sec) + (int(cc) / 100.0 if cc else 0.0)
            return int((total + (int(h) * 3600 if h else 0)) * 1e9)
    return None


def sum_cpu(pids):
    return sum(x for x in (cpu_ns(p) for p in pids) if x)


def processes():
    out = subprocess.run(["ps", "-Ao", "pid=,args="], capture_output=True, text=True).stdout
    procs = {}
    for line in out.splitlines():
        pid, _, args = line.strip().partition(" ")
        try:
            procs[int(pid)] = args
        except ValueError:
            pass
    return procs


def windowserver_pids():
    return [p for p, a in processes().items() if "Resources/WindowServer" in a]


# --- layout dump -----------------------------------------------------------------------

def clean(name):
    return "".join(c for c in name if unicodedata.category(c) != "Cf").strip()


def dump():
    """Force a fresh layout dump and parse it. Returns (rows, focused)."""
    import os
    before = os.path.getmtime(DUMP) if os.path.exists(DUMP) else 0
    subprocess.run(["mosaic", "dump-layout"], check=False)
    deadline = time.time() + 5
    while time.time() < deadline:
        if os.path.exists(DUMP) and os.path.getmtime(DUMP) > before:
            break
        time.sleep(0.05)
    rows, ws, state = [], None, None
    text = open(DUMP).read()
    for line in text.splitlines():
        m = re.match(r"WORKSPACE (\d+) \[(SHOWN|PARKED)\]", line)
        if m:
            ws, state = int(m.group(1)), m.group(2)
            continue
        if line.lstrip().startswith(("•", "▸")):
            continue                     # tree rendering, not a window row
        m = re.match(r"\s{4}(\S.*?)\s+wid=(\d+)", line)
        if m and ws:
            rows.append({"app": clean(m.group(1)), "wid": m.group(2), "ws": ws, "state": state})
    m = re.search(r"^focused: (\S+) wid=(\d+)", text, re.M)
    return rows, ((m.group(1), m.group(2)) if m else None)


def wait_for(pred, timeout, what):
    deadline = time.time() + timeout
    while time.time() < deadline:
        value = pred()
        if value:
            return value
        time.sleep(0.25)
    sys.exit("TIMEOUT waiting for: %s" % what)


# --- mode: passive sample --------------------------------------------------------------

def mode_sample(argv):
    window = float(argv[0]) if argv else 6.0
    rounds = int(argv[1]) if len(argv) > 1 else 5
    procs = processes()
    rows, _ = dump()

    apps, targets, labels = {}, {}, {}
    for row in rows:
        apps.setdefault(row["app"], (row["ws"], row["state"]))
    for app, (ws, state) in sorted(apps.items()):
        pids = [p for p, a in procs.items() if "/%s.app/" % app in a]
        if not pids:
            print("  (skipped %s — no process matched its bundle)" % app, file=sys.stderr)
            continue
        key = "%s [ws%s %s]" % (app, ws, state)
        targets[key], labels[key] = pids, (state, len(pids))
    if windowserver_pids():
        targets["WindowServer [reference]"] = windowserver_pids()
        labels["WindowServer [reference]"] = ("REF", 1)

    print("%d windows of %.0fs, median reported (~%.0fs total).\n"
          % (rounds, window, rounds * window))
    runs = []
    for i in range(rounds):
        before = {k: sum_cpu(v) for k, v in targets.items()}
        start = time.time()
        time.sleep(window)
        elapsed = time.time() - start
        after = {k: sum_cpu(v) for k, v in targets.items()}
        runs.append({k: (after[k] - before[k]) / 1e9 / elapsed for k in targets})
        print("  window %d/%d" % (i + 1, rounds), file=sys.stderr)

    print("%-34s %6s  %9s  %9s" % ("target", "procs", "CPU %core", "state"))
    print("-" * 66)
    order = {"PARKED": 0, "SHOWN": 1, "REF": 2}
    for key in sorted(targets, key=lambda k: (order[labels[k][0]], k)):
        med = statistics.median(r[key] for r in runs)
        state, nproc = labels[key]
        print("%-34s %6d  %8.2f%%  %9s" % (key, nproc, med * 100, state))


# --- mode: controlled A/B ---------------------------------------------------------------

PAGE = """<!doctype html><meta charset=utf-8><title>mosaic-parkbench</title>
<style>html,body{margin:0;background:#111;overflow:hidden}canvas{display:block}</style>
<canvas id=c></canvas><script>
const c=document.getElementById('c'),x=c.getContext('2d');
c.width=1200;c.height=800;
const P=[...Array(1500)].map(()=>({x:Math.random()*1200,y:Math.random()*800,
  vx:(Math.random()-.5)*4,vy:(Math.random()-.5)*4,h:Math.random()*360}));
let n=0;
function frame(){
  n++;
  x.fillStyle='#111';x.fillRect(0,0,1200,800);
  for(const p of P){p.x=(p.x+p.vx+1200)%1200;p.y=(p.y+p.vy+800)%800;
    x.fillStyle='hsl('+p.h+',70%,60%)';x.fillRect(p.x,p.y,6,6);}
  requestAnimationFrame(frame);
}
requestAnimationFrame(frame);
setInterval(()=>{new Image().src='/report?f='+n+'&_='+Date.now();},1000);
</script>"""

frames = []      # (server time, frames since page load)


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path.startswith("/report"):
            m = re.search(r"[?&]f=(\d+)", self.path)
            if m:
                frames.append((time.time(), int(m.group(1))))
            self.send_response(204)
            self.end_headers()
            return
        body = PAGE.encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass


def webkit_pids():
    """Safari and its WebContent renderers — the renderer lives in WebKit.framework, NOT
    under Safari.app, so the bundle alone misses the process doing the drawing."""
    return {p for p, a in processes().items()
            if "/Safari.app/" in a or "WebKit.WebContent" in a}


def ab_measure(label, pids, ws_pids):
    app0, ws0 = sum_cpu(pids), sum_cpu(ws_pids)
    frames0 = frames[-1][1] if frames else 0
    start = time.time()
    time.sleep(AB_PHASE)
    elapsed = time.time() - start
    app1, ws1 = sum_cpu(pids), sum_cpu(ws_pids)
    frames1 = frames[-1][1] if frames else 0
    return {"phase": label,
            "fps": (frames1 - frames0) / elapsed,
            "app_pct": (app1 - app0) / 1e9 / elapsed * 100,
            "ws_pct": (ws1 - ws0) / 1e9 / elapsed * 100 if ws_pids else None}


def mode_ab(_argv):
    import socket
    sock = socket.socket()
    sock.bind(("127.0.0.1", 0))
    port = sock.getsockname()[1]
    sock.close()
    threading.Thread(target=HTTPServer(("127.0.0.1", port), Handler).serve_forever,
                     daemon=True).start()
    url = "http://127.0.0.1:%d/" % port
    print("load server on %s" % url, flush=True)

    # Safari, because it is the browser least likely to already be in the layout — the test
    # window must be identifiable without guessing, since we are about to MOVE it.
    was_running = subprocess.run(["pgrep", "-x", "Safari"], capture_output=True).returncode == 0
    before_pids = webkit_pids()
    before_wids = {r["wid"] for r in dump()[0]}

    subprocess.run(["open", "-a", "Safari", url], check=True)
    new = wait_for(lambda: [r for r in dump()[0]
                            if r["app"] == "Safari" and r["wid"] not in before_wids],
                   30, "the Safari window to appear in the layout")
    leaf = new[0]
    print("test window: wid=%s, tiled into ws%s" % (leaf["wid"], leaf["ws"]), flush=True)

    _, focused = dump()
    if not focused or focused[1] != leaf["wid"]:
        sys.exit("ABORT: the test window does not hold focus (focus=%s) — refusing to move "
                 "an arbitrary window." % (focused,))

    if leaf["ws"] != AB_WORKSPACE:
        subprocess.run(["mosaic", "move-to-%d" % AB_WORKSPACE], check=False)
        wait_for(lambda: any(r["wid"] == leaf["wid"] and r["ws"] == AB_WORKSPACE
                             for r in dump()[0]), 15, "the test window to join the workspace")
    subprocess.run(["mosaic", "workspace-%d" % AB_WORKSPACE], check=False)
    wait_for(lambda: any(r["wid"] == leaf["wid"] and r["state"] == "SHOWN" for r in dump()[0]),
             15, "the workspace to be shown")

    pids = webkit_pids() - before_pids
    ws_pids = windowserver_pids()
    wait_for(lambda: len(frames) >= 2, 20, "the page to start reporting frames")

    results = []
    for label, action in (("shown", None),
                          ("parked", "workspace-1"),
                          ("reshown", "workspace-%d" % AB_WORKSPACE)):
        if action:
            want = "PARKED" if label == "parked" else "SHOWN"
            subprocess.run(["mosaic", action], check=False)
            wait_for(lambda: any(r["wid"] == leaf["wid"] and r["state"] == want
                                 for r in dump()[0]), 15, "the workspace to become %s" % want)
        print("phase %s (%.0fs)" % (label, AB_PHASE), flush=True)
        results.append(ab_measure(label, pids, ws_pids))

    subprocess.run(["mosaic", "workspace-1"], check=False)
    if not was_running:
        subprocess.run(["osascript", "-e", 'tell application "Safari" to quit'], check=False)

    print("\n%-12s %10s %13s %12s" % ("phase", "frames/s", "app %core", "WS %core"))
    print("-" * 50)
    for r in results:
        print("%-12s %10.1f %12.1f%% %11s" % (r["phase"], r["fps"], r["app_pct"],
              ("%.1f%%" % r["ws_pct"]) if r["ws_pct"] is not None else "n/a"))
    print("\nA parked window that keeps its frame rate means macOS is NOT occluding it.")
    return results


if __name__ == "__main__":
    mode = sys.argv[1] if len(sys.argv) > 1 else "sample"
    if mode == "sample":
        mode_sample(sys.argv[2:])
    elif mode == "ab":
        mode_ab(sys.argv[2:])
    else:
        sys.exit(__doc__)
