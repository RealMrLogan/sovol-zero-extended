#!/usr/bin/env python3
# sovol-zero-extended config page backend. Runs on the printer as the sovol user, on localhost only;
# nginx serves it at /extended/ after Moonraker's /access/user check (same trust as Mainsail).
import json, os, re, subprocess, sys, time
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

HERE = os.path.dirname(os.path.abspath(__file__))
STATE = os.path.dirname(HERE)                     # ~/zero-extended
XORG = "/etc/X11/xorg.conf.d/01-dbbian-defaults.conf"   # Sovol's X config: fbdev rotation + touch matrix
KS_LOG = os.path.expanduser("~/printer_data/logs/KlipperScreen.log")

# orientation as seen by someone facing the screen; Sovol ships "UD" as its landscape
ORIENTATIONS = {
    "landscape":         ("UD",     "-1 0 1 0 -1 1 0 0 1"),
    "portrait":          ("CCW",    "0 -1 1 1 0 0 0 0 1"),
    "landscape-flipped": ("normal", "1 0 0 0 1 0 0 0 1"),   # fbdev has no "normal": unknown = unrotated
    "portrait-flipped":  ("CW",     "0 1 0 -1 0 1 0 0 1"),
}
ROTATE_RE = re.compile(r'(Option\s+"Rotate"\s+")([^"]*)(")')
MATRIX_RE = re.compile(r'("CalibrationMatrix"\s+")([^"]*)(")')


def get_orientation():
    m = ROTATE_RE.search(open(XORG).read())
    rotate = m.group(2) if m else "normal"
    return next((k for k, (r, _) in ORIENTATIONS.items() if r == rotate), "landscape-flipped")


def set_orientation(value):
    rotate, matrix = ORIENTATIONS[value]
    src = open(XORG).read()
    if not ROTATE_RE.search(src) or not MATRIX_RE.search(src):
        raise RuntimeError("%s has no Rotate/CalibrationMatrix lines to change" % XORG)
    src = ROTATE_RE.sub(lambda m: m.group(1) + rotate + m.group(3), src)
    src = MATRIX_RE.sub(lambda m: m.group(1) + matrix + m.group(3), src)
    subprocess.run(["sudo", "-n", "tee", XORG], input=src.encode(), stdout=subprocess.DEVNULL, check=True)
    try:
        start = os.path.getsize(KS_LOG)
    except OSError:
        start = 0
    subprocess.run(["sudo", "-n", "systemctl", "restart", "KlipperScreen"], check=True)  # restarts X too
    w, h = wait_for_screen(start)
    if (h > w) != value.startswith("portrait"):
        raise RuntimeError("the screen came back at %dx%d" % (w, h))


def wait_for_screen(start, timeout=45):
    """Wait for KlipperScreen to log its screen size after a restart: the UI is up from then on."""
    deadline = time.time() + timeout
    while time.time() < deadline:
        time.sleep(1)
        try:
            with open(KS_LOG, "rb") as f:
                f.seek(start if os.path.getsize(KS_LOG) >= start else 0)   # log rotated: read it all
                m = re.findall(rb"Screen resolution: (\d+)x(\d+)", f.read())
        except OSError:
            continue
        if m:
            return int(m[-1][0]), int(m[-1][1])
    raise RuntimeError("the screen did not come back within %d s" % timeout)


# Each setting: label, choices (value -> label), get(), set(value). New options are new entries here.
SETTINGS = {
    "orientation": {
        "label": "Screen orientation",
        "help": "Rotates the touchscreen and its touch input. The screen restarts to apply it.",
        "choices": {"landscape": "Landscape", "portrait": "Portrait",
                    "landscape-flipped": "Landscape (flipped)", "portrait-flipped": "Portrait (flipped)"},
        "get": get_orientation,
        "set": set_orientation,
    },
}


def status():
    try:
        manifest = json.load(open(os.path.join(STATE, "manifest.json")))
    except OSError:
        manifest = {}
    return {"version": manifest.get("version", "unknown"),
            "boards": {b: v.get("version") for b, v in manifest.get("boards", {}).items()}}


class Handler(BaseHTTPRequestHandler):
    def send(self, code, body, ctype="application/json"):
        data = body if isinstance(body, bytes) else json.dumps(body).encode()
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self.send(200, open(os.path.join(HERE, "index.html"), "rb").read(), "text/html; charset=utf-8")
        elif self.path == "/api/settings":
            out = {}
            for key, s in SETTINGS.items():
                try:
                    value, error = s["get"](), None
                except Exception as e:
                    value, error = None, str(e)
                out[key] = {"label": s["label"], "help": s["help"], "choices": s["choices"],
                            "value": value, "error": error}
            self.send(200, {"status": status(), "settings": out})
        else:
            self.send(404, {"error": "not found"})

    def do_POST(self):
        m = re.fullmatch(r"/api/settings/([a-z-]+)", self.path)
        s = SETTINGS.get(m.group(1)) if m else None
        if not s:
            return self.send(404, {"error": "no such setting"})
        try:
            value = json.loads(self.rfile.read(int(self.headers.get("Content-Length", 0))))["value"]
        except (ValueError, KeyError, TypeError):
            return self.send(400, {"error": "expected {\"value\": ...}"})
        if value not in s["choices"]:            # trust boundary: only known values reach set()
            return self.send(400, {"error": "invalid value"})
        try:
            s["set"](value)
        except Exception as e:
            return self.send(500, {"error": str(e)})
        self.send(200, {"value": s["get"]()})

    def log_message(self, fmt, *args):
        sys.stderr.write("%s\n" % (fmt % args))


if __name__ == "__main__":
    port = int(sys.argv[1]) if len(sys.argv) > 1 else 7130
    ThreadingHTTPServer(("127.0.0.1", port), Handler).serve_forever()
